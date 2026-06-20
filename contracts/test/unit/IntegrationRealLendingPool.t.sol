// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { Factory } from "../../src/amm/Factory.sol";
import { Router } from "../../src/amm/Router.sol";
import { Pair } from "../../src/amm/Pair.sol";
import { LendingPool } from "../../src/lending/LendingPool.sol";
import { MockOracle } from "../../src/oracle/MockOracle.sol";
import { TestToken } from "../../src/tokens/TestToken.sol";

/// @title IntegrationRealLendingPoolTest
/// @notice Closes the gap left by `test/unit/Integration.t.sol` and
///         `test/invariant/Integration.t.sol`: those suites only ever exercise the
///         Pair against `MockLendingPool`, a 1:1 mock whose `supplyBalanceOf` never
///         grows (no interest model). They can never reproduce the H-1 finding —
///         where the Pair cached a STATIC principal instead of reading the live,
///         interest-bearing balance from the lending pool.
///
/// @dev This suite wires the Pair to a REAL `LendingPool` (with a real linear
///      interest-rate model) and a real `MockOracle`, drives genuine utilization
///      via a third-party borrower, warps time, forces accrual, and asserts that:
///        1. The Pair's live supply balance in the LendingPool grows.
///        2. `Pair.getReserves()` reflects that growth with no new deposits.
///        3. `Pair.suppliedReserves()` reflects that growth and matches (1).
///        4. A large `burn` that must recall MORE than the originally-swept
///           principal does not revert (the exact H-1 failure mode) and the
///           burning LP receives proportionally more than they would have without
///           yield.
///        5. Disabling the lending pool (`_recallAll`) recovers the FULL live
///           balance (principal + yield), not just the original principal.
///
///      Split into per-step internal helpers purely to keep each function's stack
///      within Solidity's 16-local-variable limit (this contract intentionally
///      tracks many before/after values for an end-to-end scenario).
contract IntegrationRealLendingPoolTest is Test {
    // -------------------------------------------------------------------------
    // Contracts under test
    // -------------------------------------------------------------------------

    Factory internal factory;
    Router internal router;
    Pair internal pair;
    LendingPool internal lendingPool;
    MockOracle internal oracle;

    TestToken internal token0;
    TestToken internal token1;

    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------

    address internal lpProvider = makeAddr("lpProvider");
    address internal borrower = makeAddr("borrower");

    // -------------------------------------------------------------------------
    // Scenario constants
    // -------------------------------------------------------------------------

    uint16 internal constant BUFFER_BPS = 2000; // 20% buffer kept physical, 80% swept
    uint256 internal constant SEED_AMOUNT = 1000 ether; // both tokens, equal seed
    uint256 internal constant WARP_PERIOD = 180 days;

    /// @dev targetLiquid = ceil(SEED_AMOUNT * BUFFER_BPS / 10_000) == 200 ether.
    uint256 internal constant TARGET_LIQUID = (SEED_AMOUNT * BUFFER_BPS + 9999) / 10_000;
    /// @dev The principal swept to the lending pool on the first mint, per token (800 ether).
    uint256 internal constant SWEPT_PRINCIPAL = SEED_AMOUNT - TARGET_LIQUID;

    function setUp() public {
        factory = new Factory();
        router = new Router(address(factory));

        TestToken tokenA = new TestToken("Token A", "TKA", 0);
        TestToken tokenB = new TestToken("Token B", "TKB", 0);

        address pairAddr = factory.createPair(address(tokenA), address(tokenB));
        pair = Pair(pairAddr);

        // Resolve sorted token0/token1 from the pair itself.
        token0 = TestToken(pair.token0());
        token1 = TestToken(pair.token1());

        // Real oracle + real LendingPool, both markets listed before anything else.
        oracle = new MockOracle(address(this));
        oracle.setPrice(address(token0), 1e18); // $1.00
        oracle.setPrice(address(token1), 1e18); // $1.00

        lendingPool = new LendingPool(address(this), oracle);
        lendingPool.listMarket(address(token0), 0.8e18);
        lendingPool.listMarket(address(token1), 0.8e18);

        // Wire the Pair to the real LendingPool BEFORE seeding liquidity, so the
        // very first mint already sweeps excess into it.
        factory.setPairLendingPool(address(pair), address(lendingPool), BUFFER_BPS);

        // Fund actors.
        token0.mint(lpProvider, 10_000 ether);
        token1.mint(lpProvider, 10_000 ether);
        token0.mint(borrower, 10_000 ether);
        token1.mint(borrower, 10_000 ether);
    }

    // =========================================================================
    // Step helpers
    // =========================================================================

    /// @dev Seeds liquidity via the Router (sweeps on first mint) and checks the
    ///      initial post-sweep invariants.
    function _seedLiquidity() internal {
        vm.startPrank(lpProvider);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.addLiquidity(
            address(token0),
            address(token1),
            SEED_AMOUNT,
            SEED_AMOUNT,
            0,
            0,
            lpProvider,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        (uint112 s0Init, uint112 s1Init) = pair.suppliedReserves();
        assertEq(s0Init, SWEPT_PRINCIPAL, "initial supplied0 == swept principal");
        assertEq(s1Init, SWEPT_PRINCIPAL, "initial supplied1 == swept principal");

        assertEq(
            lendingPool.supplyBalanceOf(address(pair), address(token0)),
            SWEPT_PRINCIPAL,
            "pair's live supply balance == principal pre-yield"
        );
    }

    /// @dev Third-party borrower posts token1 collateral and borrows token0 from the
    ///      lending pool, creating 50% utilization on the token0 market.
    function _createUtilization() internal returns (uint256 borrowAmount) {
        borrowAmount = SWEPT_PRINCIPAL / 2; // 400 ether -> 50% utilization
        uint256 collateralAmount = 1000 ether; // HF = (1000*0.8)/400 = 2.0

        vm.startPrank(borrower);
        token1.approve(address(lendingPool), collateralAmount);
        lendingPool.supply(address(token1), collateralAmount);
        lendingPool.borrow(address(token0), borrowAmount);
        vm.stopPrank();

        assertEq(
            lendingPool.utilization(address(token0)),
            0.5e18,
            "token0 market utilization should be 50% after borrow"
        );
    }

    /// @dev Warps forward and forces accrual on the utilized market; returns the
    ///      yield credited to the pair's live supply balance on token0.
    function _warpAndAccrue(uint256 supplyBalance0Before) internal returns (uint256 yieldAmount) {
        vm.warp(block.timestamp + WARP_PERIOD);
        lendingPool.accrueInterest(address(token0));
        // token1's market has zero borrows -> accrual is a fast-path no-op.

        uint256 supplyBalance0After = lendingPool.supplyBalanceOf(address(pair), address(token0));
        assertGt(
            supplyBalance0After,
            supplyBalance0Before,
            "Assert1: pair's live supply balance for token0 must have grown from interest"
        );

        yieldAmount = supplyBalance0After - supplyBalance0Before;
        // Sanity bound: with a 2%-22% annual borrow rate range and 50% utilization
        // over 180 days, yield should be a small single-digit percentage of principal,
        // not negligible dust and not implausibly large.
        assertGt(yieldAmount, 0.01 ether, "Assert1: yield should be more than dust");
        assertLt(yieldAmount, SWEPT_PRINCIPAL / 10, "Assert1: yield should be < 10% of principal");

        // token1 must be unaffected (no borrows against it -> no accrual).
        assertEq(
            lendingPool.supplyBalanceOf(address(pair), address(token1)),
            SWEPT_PRINCIPAL,
            "Assert1(sanity): token1 supply balance unaffected (zero utilization there)"
        );
    }

    /// @dev The borrower repays their full debt so the LendingPool's token0 cash
    ///      returns to (principal + yield) — i.e. the entire live supply balance
    ///      becomes withdrawable again. Without this, `LendingPool.withdraw` would
    ///      revert `InsufficientCash` on Assert 4's large recall, since part of the
    ///      pool's token0 cash is legitimately on loan to the borrower. This step
    ///      isolates the property under test (recall surviving a live balance that
    ///      exceeds the original static principal) from a separate, expected
    ///      constraint (recall cannot exceed the pool's available cash).
    function _borrowerRepaysInFull() internal {
        uint256 debt = lendingPool.debtOf(borrower, address(token0));
        assertGt(debt, 0, "borrower must have outstanding debt to repay");

        vm.startPrank(borrower);
        token0.approve(address(lendingPool), debt);
        lendingPool.repay(address(token0), debt, borrower);
        vm.stopPrank();

        assertEq(
            lendingPool.debtOf(borrower, address(token0)), 0, "borrower debt must be fully repaid"
        );
    }

    /// @dev Assert 2 + 3: getReserves() and suppliedReserves() reflect the yield.
    function _assertReservesReflectYield(
        uint112 totalReserve0Before,
        uint112 totalReserve1Before,
        uint256 yieldAmount
    ) internal view {
        (uint112 totalReserve0After, uint112 totalReserve1After,) = pair.getReserves();
        assertEq(
            totalReserve0After,
            totalReserve0Before + yieldAmount,
            "Assert2: total reserve0 grew by exactly the yield amount"
        );
        assertGt(
            totalReserve0After,
            totalReserve0Before,
            "Assert2: total reserve0 strictly increased with no new deposits"
        );
        assertEq(
            totalReserve1After,
            totalReserve1Before,
            "Assert2(sanity): total reserve1 unchanged (no yield on that side)"
        );

        (uint112 s0After, uint112 s1After) = pair.suppliedReserves();
        assertEq(
            s0After,
            lendingPool.supplyBalanceOf(address(pair), address(token0)),
            "Assert3: suppliedReserves(token0) matches live supplyBalanceOf"
        );
        assertGt(s0After, SWEPT_PRINCIPAL, "Assert3: suppliedReserves(token0) > original principal");
        assertEq(s1After, SWEPT_PRINCIPAL, "Assert3(sanity): suppliedReserves(token1) unchanged");
    }

    /// @dev Assert 4: a burn requiring recall beyond the original swept principal
    ///      succeeds (the exact H-1 failure mode) and delivers the yield to the LP.
    /// @return remainingPrincipalOnlyBaseline0 The principal-only (no-yield) value of
    ///         the token0 position still attributable to the unburned LP shares —
    ///         used by Assert 5 as its baseline (since 99% of the position has
    ///         already been recalled by this point).
    function _assertBurnRecoversYield(uint112 totalReserve0Before, uint112 totalReserve0After)
        internal
        returns (uint256 remainingPrincipalOnlyBaseline0)
    {
        uint256 lpBalance = pair.balanceOf(lpProvider);
        // Burn 99% of the LP's shares — sized so the token0 amount owed exceeds
        // TARGET_LIQUID + SWEPT_PRINCIPAL (i.e. recall must dip into accrued yield).
        uint256 burnAmt = (lpBalance * 99) / 100;
        uint256 totalSupplyBeforeBurn = pair.totalSupply();

        // Independently compute the no-yield baseline amount0 the LP would have
        // received if supplyBalance0 had stayed flat at the original principal.
        uint256 expectedAmount0NoYield =
            (burnAmt * uint256(totalReserve0Before)) / totalSupplyBeforeBurn;
        uint256 expectedAmount0WithYield =
            (burnAmt * uint256(totalReserve0After)) / totalSupplyBeforeBurn;

        // Principal-only value of the 1% of LP shares that will remain AFTER this
        // burn — used by Assert 5 as its no-yield baseline.
        remainingPrincipalOnlyBaseline0 =
            (SWEPT_PRINCIPAL * (totalSupplyBeforeBurn - burnAmt)) / totalSupplyBeforeBurn;
        assertGt(
            expectedAmount0WithYield,
            expectedAmount0NoYield,
            "Assert4(sanity): yield-inclusive payout strictly exceeds no-yield payout"
        );

        // Confirm the recall really does need to dig past the original principal.
        uint256 physical0BeforeBurn = token0.balanceOf(address(pair));
        assertLt(
            physical0BeforeBurn + SWEPT_PRINCIPAL,
            expectedAmount0WithYield,
            "Assert4(setup): burn must require recalling beyond the original principal"
        );

        uint256 lpToken0Before = token0.balanceOf(lpProvider);

        vm.prank(lpProvider);
        pair.transfer(address(pair), burnAmt);
        // Must NOT revert — this is precisely the scenario H-1 could have broken:
        // recalling more than a stale static `supplied0` cache would have underflowed.
        (uint256 amount0Got, uint256 amount1Got) = pair.burn(lpProvider);

        assertEq(
            amount0Got,
            expectedAmount0WithYield,
            "Assert4: burn delivered the yield-inclusive amount0"
        );
        assertGt(
            amount0Got,
            expectedAmount0NoYield,
            "Assert4: LP received strictly more token0 than the no-yield baseline"
        );
        assertEq(
            token0.balanceOf(lpProvider),
            lpToken0Before + amount0Got,
            "Assert4: LP's token0 balance increased by exactly amount0Got"
        );
        assertGt(amount1Got, 0, "Assert4(sanity): burn also delivered token1");
    }

    /// @dev Assert 5: disabling the lending pool recovers 100% of the REMAINING live
    ///      balance (principal + yield on the ~1% of the position left after Assert
    ///      4's 99% burn), not just a stale principal-only figure.
    ///
    ///      Note: by this point Assert 4 has already burned 99% of the LP supply and
    ///      recalled the bulk of the position, so the remaining live balance on
    ///      token0 is only ~1% of the original 800-ether principal (~8 ether) plus
    ///      its pro-rata share of yield — NOT the full original 800-ether principal.
    ///      The baseline below is therefore the proportional principal-only amount
    ///      that would remain (`SWEPT_PRINCIPAL * remainingLpShare / originalLpSupply`),
    ///      not `SWEPT_PRINCIPAL` itself.
    function _assertRecallAllRecoversFullYield(uint256 principalOnlyBaseline0) internal {
        uint256 liveSupplyBalance0BeforeDisable =
            lendingPool.supplyBalanceOf(address(pair), address(token0));
        uint256 liveSupplyBalance1BeforeDisable =
            lendingPool.supplyBalanceOf(address(pair), address(token1));
        assertGt(
            liveSupplyBalance0BeforeDisable,
            0,
            "Assert5(setup): pair must still have a live supply balance on token0 pre-disable"
        );

        uint256 physical0BeforeDisable = token0.balanceOf(address(pair));
        uint256 physical1BeforeDisable = token1.balanceOf(address(pair));

        factory.setPairLendingPool(address(pair), address(0), 0);

        assertEq(pair.lendingPool(), address(0), "Assert5: lendingPool disabled");
        (uint112 s0Final, uint112 s1Final) = pair.suppliedReserves();
        assertEq(s0Final, 0, "Assert5: suppliedReserves(token0) == 0 after recallAll");
        assertEq(s1Final, 0, "Assert5: suppliedReserves(token1) == 0 after recallAll");

        assertEq(
            token0.balanceOf(address(pair)),
            physical0BeforeDisable + liveSupplyBalance0BeforeDisable,
            "Assert5: physical token0 grew by the FULL live balance (principal + yield)"
        );
        assertEq(
            token1.balanceOf(address(pair)),
            physical1BeforeDisable + liveSupplyBalance1BeforeDisable,
            "Assert5: physical token1 grew by its full live balance"
        );

        // Final sanity: the recovered token0 amount strictly exceeds the
        // principal-only baseline for the remaining position, proving the residual
        // yield (on the unburned 1%) was not orphaned either.
        assertGt(
            liveSupplyBalance0BeforeDisable,
            principalOnlyBaseline0,
            "Assert5: recovered amount exceeds the principal-only baseline (yield included)"
        );

        // LendingPool's own market accounting must show zero left for this pair.
        assertEq(
            lendingPool.supplyBalanceOf(address(pair), address(token0)),
            0,
            "Assert5: LendingPool-side balance for pair is fully drained (token0)"
        );
        assertEq(
            lendingPool.supplyBalanceOf(address(pair), address(token1)),
            0,
            "Assert5: LendingPool-side balance for pair is fully drained (token1)"
        );
    }

    // =========================================================================
    // Full scenario: seed -> borrow elsewhere -> warp -> accrue -> assert yield
    //                 reaches the Pair -> assert burn/recallAll recover it.
    // =========================================================================

    /// @notice End-to-end: Pair sweeps idle liquidity into a real, interest-bearing
    ///         LendingPool; a third-party borrower creates utilization; after a
    ///         180-day warp + accrual the Pair's live lending balance has grown,
    ///         `getReserves`/`suppliedReserves` reflect the growth, a large burn
    ///         that must recall MORE than the original swept principal succeeds
    ///         (the exact H-1 failure mode) and delivers the yield to the LP, and
    ///         disabling the lending pool recovers 100% of the live balance.
    function test_realLendingPool_yieldReachesPairAndSurvivesRecall() public {
        _seedLiquidity();

        uint256 supplyBalance0Before = lendingPool.supplyBalanceOf(address(pair), address(token0));
        (uint112 totalReserve0Before, uint112 totalReserve1Before,) = pair.getReserves();

        _createUtilization();

        uint256 yieldAmount = _warpAndAccrue(supplyBalance0Before);

        _assertReservesReflectYield(totalReserve0Before, totalReserve1Before, yieldAmount);

        // Free up the LendingPool's token0 cash (return it to principal + yield) so
        // Assert 4's large recall is limited only by the live supply balance, not by
        // an unrelated cash shortage from the borrower's still-outstanding loan.
        _borrowerRepaysInFull();

        (uint112 totalReserve0After,,) = pair.getReserves();
        uint256 remainingPrincipalOnlyBaseline0 =
            _assertBurnRecoversYield(totalReserve0Before, totalReserve0After);

        _assertRecallAllRecoversFullYield(remainingPrincipalOnlyBaseline0);
    }
}
