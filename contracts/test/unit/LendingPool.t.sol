// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { LendingPool } from "../../src/lending/LendingPool.sol";
import { ILendingPool } from "../../src/interfaces/ILendingPool.sol";
import { MockOracle } from "../../src/oracle/MockOracle.sol";
import { TestToken } from "../../src/tokens/TestToken.sol";

/// @title LendingPoolUnitTest
/// @notice Exhaustive unit tests for LendingPool: supply, withdraw, borrow, repay,
///         accrueInterest, liquidate, and edge cases.
///
/// @dev Key invariants exercised here:
///      - debtOf rounds UP; supplyBalanceOf rounds DOWN.
///      - accrueInterest is always called first (CEI).
///      - healthFactor iterates ALL listed markets and calls oracle.getPrice for each.
///        Therefore all listed tokens must have a price configured before any HF-dependent
///        operation.
///      - repay accepts type(uint256).max to clear debt without knowing the exact amount.
///      - withdraw only checks HF when the caller has active borrows (_hasBorrows).
contract LendingPoolUnitTest is Test {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant WAD = 1e18;

    // -------------------------------------------------------------------------
    // Contracts under test
    // -------------------------------------------------------------------------

    MockOracle internal oracle;
    LendingPool internal pool;
    TestToken internal tokenA; // used as collateral
    TestToken internal tokenB; // used as borrow asset

    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal liquidator = makeAddr("liquidator");

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        oracle = new MockOracle(address(this));
        pool = new LendingPool(address(this), oracle);
        tokenA = new TestToken("Token A", "TKA", 0);
        tokenB = new TestToken("Token B", "TKB", 0);

        // Prices MUST be set before listing because healthFactor iterates all listed markets
        // and calls oracle.getPrice for each one — listing without a price would cause reverts.
        oracle.setPrice(address(tokenA), 1e18); // $1
        oracle.setPrice(address(tokenB), 1e18); // $1

        pool.listMarket(address(tokenA), 0.75e18);
        pool.listMarket(address(tokenB), 0.75e18);

        // Seed balances for all actors.
        tokenA.mint(alice, 10_000e18);
        tokenB.mint(alice, 10_000e18);
        tokenA.mint(bob, 10_000e18);
        tokenB.mint(bob, 10_000e18);
        tokenA.mint(liquidator, 10_000e18);
        tokenB.mint(liquidator, 10_000e18);
    }

    // =========================================================================
    // supply
    // =========================================================================

    /// @notice First depositor gets shares proportional to amount; Supply event is emitted.
    function test_supply_mintsShares() public {
        uint256 amount = 1000e18;

        vm.startPrank(alice);
        tokenA.approve(address(pool), amount);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ILendingPool.Supply(alice, address(tokenA), amount, amount); // first deposit: shares == amount

        pool.supply(address(tokenA), amount);
        vm.stopPrank();

        // supplyBalanceOf rounds DOWN; on first deposit with supplyIndex == WAD the value is exact.
        uint256 bal = pool.supplyBalanceOf(alice, address(tokenA));
        // Allow up to 1 wei dust from rounding.
        assertApproxEqAbs(bal, amount, 1, "supplyBalanceOf mismatch after first deposit");
    }

    /// @notice supply(token, 0) reverts with ZeroAmount.
    function test_supply_revertsZeroAmount() public {
        vm.startPrank(alice);
        tokenA.approve(address(pool), 1);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.ZeroAmount.selector));
        pool.supply(address(tokenA), 0);
        vm.stopPrank();
    }

    /// @notice Second depositor's shares are proportional to their contribution.
    function test_supply_secondDepositor() public {
        uint256 amountA = 1000e18;
        uint256 amountB = 500e18;

        // Alice deposits first.
        vm.startPrank(alice);
        tokenA.approve(address(pool), amountA);
        pool.supply(address(tokenA), amountA);
        vm.stopPrank();

        // Bob deposits half as much.
        vm.startPrank(bob);
        tokenA.approve(address(pool), amountB);
        pool.supply(address(tokenA), amountB);
        vm.stopPrank();

        uint256 balA = pool.supplyBalanceOf(alice, address(tokenA));
        uint256 balB = pool.supplyBalanceOf(bob, address(tokenA));

        // Alice deposited 2x Bob, so her balance should be ~2x Bob's (±1 wei each).
        assertApproxEqAbs(balA, 2 * balB, 2, "Alice's balance should be ~2x Bob's");
        // Total supplied should match combined input.
        assertApproxEqAbs(balA + balB, amountA + amountB, 2, "total balance mismatch");
    }

    // =========================================================================
    // withdraw
    // =========================================================================

    /// @notice supply then withdraw returns approximately the deposited amount (≤1 wei dust).
    function test_withdraw_returnsTokens() public {
        uint256 amount = 1000e18;

        vm.startPrank(alice);
        tokenA.approve(address(pool), amount);
        pool.supply(address(tokenA), amount);

        uint256 balBefore = tokenA.balanceOf(alice);
        pool.withdraw(address(tokenA), amount);
        uint256 balAfter = tokenA.balanceOf(alice);
        vm.stopPrank();

        // User gets back at most `amount`; rounding may leave 1 wei less.
        assertApproxEqAbs(balAfter - balBefore, amount, 1, "withdraw amount mismatch");
    }

    /// @notice Withdrawing more than deposited reverts with InsufficientCash.
    function test_withdraw_revertsIfInsufficient() public {
        uint256 amount = 1000e18;

        vm.startPrank(alice);
        tokenA.approve(address(pool), amount);
        pool.supply(address(tokenA), amount);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientCash.selector));
        pool.withdraw(address(tokenA), amount + 1);
        vm.stopPrank();
    }

    /// @notice Withdrawing all collateral while having an active borrow reverts Undercollateralized.
    function test_withdraw_revertsIfUndercollateralized() public {
        // Alice supplies tokenA as collateral and borrows tokenB.
        // Bob provides liquidity for tokenB so the pool has cash.
        vm.startPrank(bob);
        tokenB.approve(address(pool), 5000e18);
        pool.supply(address(tokenB), 5000e18);
        vm.stopPrank();

        uint256 collateral = 1000e18;
        uint256 borrowAmt = 600e18; // 60% of 1000 * 0.75 CF = max 750 → 600 is valid

        vm.startPrank(alice);
        tokenA.approve(address(pool), collateral);
        pool.supply(address(tokenA), collateral);
        pool.borrow(address(tokenB), borrowAmt);

        // Trying to withdraw ALL collateral would violate HF.
        vm.expectRevert(abi.encodeWithSelector(LendingPool.Undercollateralized.selector));
        pool.withdraw(address(tokenA), collateral);
        vm.stopPrank();
    }

    // =========================================================================
    // borrow
    // =========================================================================

    /// @notice Standard successful borrow: Alice deposits collateral, borrows tokenB.
    function test_borrow_succeeds() public {
        // Bob supplies tokenB so there is cash.
        vm.startPrank(bob);
        tokenB.approve(address(pool), 5000e18);
        pool.supply(address(tokenB), 5000e18);
        vm.stopPrank();

        uint256 collateral = 1000e18;
        uint256 borrowAmt = 600e18;

        uint256 balBefore = tokenB.balanceOf(alice);

        vm.startPrank(alice);
        tokenA.approve(address(pool), collateral);
        pool.supply(address(tokenA), collateral);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ILendingPool.Borrow(alice, address(tokenB), borrowAmt);
        pool.borrow(address(tokenB), borrowAmt);
        vm.stopPrank();

        uint256 balAfter = tokenB.balanceOf(alice);
        assertEq(balAfter - balBefore, borrowAmt, "borrow did not transfer tokens");

        // debtOf should reflect the borrow (rounds UP, so >= borrowAmt).
        assertGe(pool.debtOf(alice, address(tokenB)), borrowAmt, "debtOf below borrow amount");
    }

    /// @notice Borrowing beyond CF limit reverts Undercollateralized.
    function test_borrow_revertsUndercollateralized() public {
        // Bob supplies tokenB.
        vm.startPrank(bob);
        tokenB.approve(address(pool), 5000e18);
        pool.supply(address(tokenB), 5000e18);
        vm.stopPrank();

        uint256 collateral = 100e18;
        uint256 borrowAmt = 200e18; // 200 > 100 * 0.75 = 75 → undercollateralized

        vm.startPrank(alice);
        tokenA.approve(address(pool), collateral);
        pool.supply(address(tokenA), collateral);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.Undercollateralized.selector));
        pool.borrow(address(tokenB), borrowAmt);
        vm.stopPrank();
    }

    /// @notice Borrowing when pool has no cash reverts InsufficientCash.
    function test_borrow_revertsInsufficientCash() public {
        // Nobody has supplied tokenB — pool has zero cash for it.
        uint256 collateral = 1000e18;

        vm.startPrank(alice);
        tokenA.approve(address(pool), collateral);
        pool.supply(address(tokenA), collateral);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientCash.selector));
        pool.borrow(address(tokenB), 1e18);
        vm.stopPrank();
    }

    // =========================================================================
    // repay
    // =========================================================================

    /// @notice Full repay zeros the debt.
    function test_repay_zerosDebt() public {
        _setupBorrow(alice, 600e18);

        uint256 debt = pool.debtOf(alice, address(tokenB));
        assertGt(debt, 0, "precondition: must have debt");

        vm.startPrank(alice);
        tokenB.approve(address(pool), debt);
        pool.repay(address(tokenB), debt, alice);
        vm.stopPrank();

        assertEq(pool.debtOf(alice, address(tokenB)), 0, "debt not zeroed after full repay");
    }

    /// @notice Partial repay leaves approximately half the debt.
    function test_repay_partial() public {
        _setupBorrow(alice, 600e18);

        uint256 debt = pool.debtOf(alice, address(tokenB));
        uint256 half = debt / 2;

        vm.startPrank(alice);
        tokenB.approve(address(pool), half);
        pool.repay(address(tokenB), half, alice);
        vm.stopPrank();

        uint256 remaining = pool.debtOf(alice, address(tokenB));
        // Remaining debt should be roughly half (allow 1 wei rounding).
        assertApproxEqAbs(remaining, debt - half, 1, "partial repay debt mismatch");
    }

    /// @notice repay(type(uint256).max) repays the full debt without revert.
    function test_repay_maxUint() public {
        _setupBorrow(alice, 600e18);

        // Confirm there is debt before repay.
        assertGt(pool.debtOf(alice, address(tokenB)), 0, "precondition: must have debt");

        vm.startPrank(alice);
        // Approve enough to cover any accrued interest up to 2x the original debt.
        tokenB.approve(address(pool), type(uint256).max);
        pool.repay(address(tokenB), type(uint256).max, alice);
        vm.stopPrank();

        assertEq(pool.debtOf(alice, address(tokenB)), 0, "debt not zeroed with max repay");
    }

    // =========================================================================
    // accrueInterest
    // =========================================================================

    /// @notice Interest accrues over time: debtOf after 365 days > original borrow.
    function test_accrueInterest_increasesDebt() public {
        uint256 borrowAmt = 500e18;
        _setupBorrow(alice, borrowAmt);

        uint256 debtBefore = pool.debtOf(alice, address(tokenB));

        vm.warp(block.timestamp + 365 days);
        pool.accrueInterest(address(tokenB));

        uint256 debtAfter = pool.debtOf(alice, address(tokenB));
        assertGt(debtAfter, debtBefore, "debt did not grow after 1 year");
    }

    /// @notice Calling accrueInterest twice in the same block is a no-op on the second call.
    function test_accrueInterest_noop_sameBlock() public {
        _setupBorrow(alice, 500e18);

        // Advance time so first call actually accrues.
        vm.warp(block.timestamp + 1 days);
        pool.accrueInterest(address(tokenB));

        (,,, uint256 borrowIndex1,,) = pool.getMarket(address(tokenB));

        // Second call in same block — dt == 0 → returns early.
        pool.accrueInterest(address(tokenB));

        (,,, uint256 borrowIndex2,,) = pool.getMarket(address(tokenB));

        assertEq(borrowIndex1, borrowIndex2, "borrowIndex changed on same-block double accrue");
    }

    /// @notice borrowIndex is monotonically non-decreasing across multiple accruals.
    function test_accrueInterest_borrowIndexMonotonic() public {
        _setupBorrow(alice, 500e18);

        (,,, uint256 idx0,,) = pool.getMarket(address(tokenB));

        vm.warp(block.timestamp + 30 days);
        pool.accrueInterest(address(tokenB));
        (,,, uint256 idx1,,) = pool.getMarket(address(tokenB));

        vm.warp(block.timestamp + 30 days);
        pool.accrueInterest(address(tokenB));
        (,,, uint256 idx2,,) = pool.getMarket(address(tokenB));

        assertGe(idx1, idx0, "borrowIndex decreased (step 1)");
        assertGe(idx2, idx1, "borrowIndex decreased (step 2)");
    }

    // =========================================================================
    // liquidation
    // =========================================================================

    /// @notice Successful liquidation: liquidator repays debt and receives collateral.
    function test_liquidate_succeeds() public {
        // Alice borrows near the CF limit.
        _setupBorrow(alice, 700e18); // 700 / (1000 * 0.75) = 93.3% utilization of CF

        // Drop tokenA price to 50 cents → HF = (1000 * 0.5 * 0.75) / 700 = 375/700 < 1
        oracle.setPrice(address(tokenA), 0.5e18);

        uint256 hfBefore = pool.healthFactor(alice);
        assertLt(hfBefore, WAD, "HF must be < 1 to liquidate");

        uint256 debt = pool.debtOf(alice, address(tokenB));
        uint256 maxRepay = (debt * 5) / 10; // 50% close factor

        uint256 liqBalBefore = pool.supplyBalanceOf(liquidator, address(tokenA));

        vm.startPrank(liquidator);
        tokenB.approve(address(pool), maxRepay);

        vm.expectEmit(true, true, false, false, address(pool));
        emit ILendingPool.Liquidate(
            liquidator, alice, address(tokenB), address(tokenA), maxRepay, 0
        );

        uint256 seizeAmt = pool.liquidate(alice, address(tokenB), address(tokenA), maxRepay);
        vm.stopPrank();

        assertGt(seizeAmt, 0, "liquidator must seize some collateral");

        // Liquidator received tokenA shares (expressed as balance).
        uint256 liqBalAfter = pool.supplyBalanceOf(liquidator, address(tokenA));
        assertGt(liqBalAfter, liqBalBefore, "liquidator did not receive collateral shares");

        // Seized amount includes the 8% bonus on the repaid value.
        // At $0.50 for tokenA and $1 for tokenB:
        // seizeValue = maxRepay * 1 * 1.08 → seizeAmount = seizeValue / 0.5 = seize * 2
        // We only verify that the transfer actually moved the correct amount of shares.
        assertApproxEqAbs(
            seizeAmt, liqBalAfter - liqBalBefore, 1, "seizeAmt vs transferred shares mismatch"
        );
    }

    /// @notice Liquidating a healthy position reverts HealthyPosition.
    function test_liquidate_revertsHealthyPosition() public {
        _setupBorrow(alice, 600e18);
        // Price unchanged — HF = (1000 * 1 * 0.75) / 600 = 1.25 > 1

        uint256 debt = pool.debtOf(alice, address(tokenB));
        uint256 repay = debt / 4;

        vm.startPrank(liquidator);
        tokenB.approve(address(pool), repay);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.HealthyPosition.selector));
        pool.liquidate(alice, address(tokenB), address(tokenA), repay);
        vm.stopPrank();
    }

    /// @notice Self-liquidation reverts SelfLiquidation.
    function test_liquidate_revertsSelfLiquidation() public {
        _setupBorrow(alice, 700e18);
        oracle.setPrice(address(tokenA), 0.5e18); // make position unhealthy

        uint256 debt = pool.debtOf(alice, address(tokenB));
        uint256 repay = debt / 4;

        vm.startPrank(alice);
        tokenB.approve(address(pool), repay);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.SelfLiquidation.selector));
        pool.liquidate(alice, address(tokenB), address(tokenA), repay);
        vm.stopPrank();
    }

    /// @notice Repaying more than 50% of debt in one call reverts RepayExceedsCloseFactor.
    function test_liquidate_revertsExceedsCloseFactor() public {
        _setupBorrow(alice, 700e18);
        oracle.setPrice(address(tokenA), 0.5e18);

        uint256 debt = pool.debtOf(alice, address(tokenB));
        // Attempt to repay 51% → exceeds close factor of 50%.
        uint256 tooMuch = (debt * 51) / 100;

        vm.startPrank(liquidator);
        tokenB.approve(address(pool), tooMuch);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.RepayExceedsCloseFactor.selector));
        pool.liquidate(alice, address(tokenB), address(tokenA), tooMuch);
        vm.stopPrank();
    }

    /// @notice After a partial liquidation (well below close factor) the borrower's HF improves.
    ///
    /// @dev With only a slight price drop the liquidation bonus (8%) and the amount
    ///      of seized collateral are small enough that repaying debt reduces the
    ///      debt/collateral ratio and genuinely improves the health factor.
    ///      Repaying the FULL close factor (50%) at a deeply-discounted collateral
    ///      price can worsen HF because the bonus seizure removes disproportionate
    ///      collateral — that is expected protocol behavior and not tested here.
    function test_liquidate_improvesHealth() public {
        // Setup: 1000 tokenA collateral, 700 tokenB borrow.
        // Drop price to $0.93 → HF = (1000 * 0.93 * 0.75) / 700 ≈ 0.996 < 1.
        _setupBorrow(alice, 700e18);
        oracle.setPrice(address(tokenA), 0.93e18);

        uint256 hfBefore = pool.healthFactor(alice);
        assertLt(hfBefore, WAD, "must be unhealthy before liquidation");

        // Repay only 25% of the debt — well within the 50% close factor.
        // seize ≈ (175 * 1 * 1.08) / 0.93 ≈ 203 tokenA
        // HF after ≈ ((1000 - 203) * 0.93 * 0.75) / (700 - 175) ≈ 1.06 > hfBefore.
        uint256 debt = pool.debtOf(alice, address(tokenB));
        uint256 repay = debt / 4; // 25%

        vm.startPrank(liquidator);
        tokenB.approve(address(pool), repay);
        pool.liquidate(alice, address(tokenB), address(tokenA), repay);
        vm.stopPrank();

        uint256 hfAfter = pool.healthFactor(alice);
        assertGt(hfAfter, hfBefore, "HF did not improve after partial liquidation");
    }

    // =========================================================================
    // Edge cases
    // =========================================================================

    /// @notice A user with no debt has healthFactor == type(uint256).max.
    function test_healthFactor_noDebt_returnsMaxUint() public {
        vm.startPrank(alice);
        tokenA.approve(address(pool), 1000e18);
        pool.supply(address(tokenA), 1000e18);
        vm.stopPrank();

        assertEq(pool.healthFactor(alice), type(uint256).max, "HF should be max with no debt");
    }

    /// @notice Listing the same token twice reverts MarketAlreadyListed.
    function test_listMarket_revertsAlreadyListed() public {
        vm.expectRevert(
            abi.encodeWithSelector(LendingPool.MarketAlreadyListed.selector, address(tokenA))
        );
        pool.listMarket(address(tokenA), 0.75e18);
    }

    /// @notice Listing with collateralFactor > WAD reverts InvalidCollateralFactor.
    function test_listMarket_revertsInvalidCF() public {
        TestToken tokenC = new TestToken("Token C", "TKC", 0);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InvalidCollateralFactor.selector));
        pool.listMarket(address(tokenC), WAD + 1);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Sets up a borrow of `borrowAmt` of tokenB by Alice, using 1000e18 tokenA as collateral.
    ///      Bob provides liquidity so the pool has sufficient cash.
    function _setupBorrow(address borrower, uint256 borrowAmt) internal {
        // Bob supplies tokenB for liquidity.
        vm.startPrank(bob);
        tokenB.approve(address(pool), 5000e18);
        pool.supply(address(tokenB), 5000e18);
        vm.stopPrank();

        vm.startPrank(borrower);
        tokenA.approve(address(pool), 1000e18);
        pool.supply(address(tokenA), 1000e18);
        pool.borrow(address(tokenB), borrowAmt);
        vm.stopPrank();
    }
}
