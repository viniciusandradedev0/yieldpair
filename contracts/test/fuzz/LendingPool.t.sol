// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { LendingPool } from "../../src/lending/LendingPool.sol";
import { MockOracle } from "../../src/oracle/MockOracle.sol";
import { TestToken } from "../../src/tokens/TestToken.sol";

/// @title LendingPoolFuzzTest
/// @notice Property-based tests for LendingPool.
///
/// Properties verified:
///   1. Solvency: pool token balance >= totalSupplied - totalBorrows (cash always non-negative).
///   2. debtOf grows monotonically with time when interest accrues.
///   3. repay never over-pays: debtOf drops to zero on full repay, never goes negative.
contract LendingPoolFuzzTest is Test {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant WAD = 1e18;

    // -------------------------------------------------------------------------
    // Contracts under test
    // -------------------------------------------------------------------------

    MockOracle internal oracle;
    LendingPool internal pool;
    TestToken internal tokenA; // collateral
    TestToken internal tokenB; // borrow asset

    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        oracle = new MockOracle(address(this));
        pool = new LendingPool(address(this), oracle);
        tokenA = new TestToken("Token A", "TKA", 0);
        tokenB = new TestToken("Token B", "TKB", 0);

        // Prices must be set before listing — healthFactor iterates all markets and
        // calls oracle.getPrice for each one.
        oracle.setPrice(address(tokenA), 1e18);
        oracle.setPrice(address(tokenB), 1e18);

        pool.listMarket(address(tokenA), 0.75e18);
        pool.listMarket(address(tokenB), 0.75e18);

        // Large initial mints to avoid transfer failures across fuzz runs.
        tokenA.mint(alice, type(uint128).max);
        tokenB.mint(alice, type(uint128).max);
        tokenA.mint(bob, type(uint128).max);
        tokenB.mint(bob, type(uint128).max);

        // Pre-approve the pool for all actors (max).
        vm.startPrank(alice);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // =========================================================================
    // Fuzz 1: Solvency after supply + borrow
    // =========================================================================

    /// @notice After any valid supply+borrow sequence the pool remains solvent:
    ///         balanceOf(pool, token) + totalBorrows >= totalSupplied for both tokens.
    ///
    /// @dev We verify via the `getMarket` getter added to LendingPool:
    ///      cash + totalBorrows >= totalSupplied
    ///      (the structural solvency invariant documented in LendingPool.sol).
    function testFuzz_solvency(uint256 supplyAmt, uint256 borrowAmt) public {
        // supplyAmt must be large enough that 74% of it is at least 1 wei.
        // Minimum: ceil(1 / 0.74) ≈ 2, so 2e6 guarantees maxBorrow >= 1e6.
        supplyAmt = bound(supplyAmt, 2e6, 1_000_000e18);
        // borrowAmt must respect the 0.75 CF: max = supplyAmt * 0.75.
        // Use 74% to stay safely below the boundary after any 1-wei rounding.
        // With supplyAmt >= 2e6, maxBorrow = floor(2e6 * 74/100) = 1_480_000 >= 1e6.
        borrowAmt = bound(borrowAmt, 1e6, (supplyAmt * 74) / 100);

        // Bob provides tokenB liquidity (enough to cover any borrow in the bounded range).
        vm.prank(bob);
        pool.supply(address(tokenB), supplyAmt);

        // Alice supplies tokenA as collateral.
        vm.prank(alice);
        pool.supply(address(tokenA), supplyAmt);

        // Alice borrows tokenB.
        vm.prank(alice);
        pool.borrow(address(tokenB), borrowAmt);

        // ── Solvency check for tokenA ──────────────────────────────────────
        {
            (uint256 totalBorrowsA, uint256 totalSuppliedA,,,,) = pool.getMarket(address(tokenA));
            uint256 cashA = tokenA.balanceOf(address(pool));
            assertGe(
                cashA + totalBorrowsA,
                totalSuppliedA,
                "tokenA: cash + borrows < supplied (insolvency)"
            );
        }

        // ── Solvency check for tokenB ──────────────────────────────────────
        {
            (uint256 totalBorrowsB, uint256 totalSuppliedB,,,,) = pool.getMarket(address(tokenB));
            uint256 cashB = tokenB.balanceOf(address(pool));
            assertGe(
                cashB + totalBorrowsB,
                totalSuppliedB,
                "tokenB: cash + borrows < supplied (insolvency)"
            );
        }

        // ── Per-user balance never exceeds pool cash + borrows ────────────
        uint256 aliceSupplyA = pool.supplyBalanceOf(alice, address(tokenA));
        uint256 bobSupplyB = pool.supplyBalanceOf(bob, address(tokenB));
        (, uint256 totalSuppliedA2,,,,) = pool.getMarket(address(tokenA));
        (, uint256 totalSuppliedB2,,,,) = pool.getMarket(address(tokenB));

        // supplyBalanceOf rounds DOWN, so it must never exceed totalSupplied.
        assertLe(aliceSupplyA, totalSuppliedA2, "alice's tokenA balance > totalSupplied");
        assertLe(bobSupplyB, totalSuppliedB2, "bob's tokenB balance > totalSupplied");
    }

    // =========================================================================
    // Fuzz 2: debtOf grows monotonically with time
    // =========================================================================

    /// @notice After time elapses, debtOf(alice, tokenB) >= original debt.
    function testFuzz_debtGrowsWithTime(uint256 borrowAmt, uint256 timeElapsed) public {
        borrowAmt = bound(borrowAmt, 1e6, 500e18);
        timeElapsed = bound(timeElapsed, 1, 365 days);

        // Bob provides liquidity.
        vm.prank(bob);
        pool.supply(address(tokenB), 1_000e18);

        // Alice supplies collateral and borrows.
        vm.prank(alice);
        pool.supply(address(tokenA), 1_000e18);
        vm.prank(alice);
        pool.borrow(address(tokenB), borrowAmt);

        uint256 debt1 = pool.debtOf(alice, address(tokenB));
        assertGe(debt1, borrowAmt, "debtOf should be >= borrow amount");

        // Time passes.
        vm.warp(block.timestamp + timeElapsed);
        pool.accrueInterest(address(tokenB));

        uint256 debt2 = pool.debtOf(alice, address(tokenB));
        // Debt must be non-decreasing (interest can only add, never subtract).
        assertGe(debt2, debt1, "debtOf decreased over time");
    }

    // =========================================================================
    // Fuzz 3: repay never over-pays (cap prevents pulling more than owed)
    // =========================================================================

    /// @notice Even when repayAmt > actual debt, the pool caps the pull at debtOf.
    ///         After repay the borrower's debtOf is 0 when repayAmt >= debt, and
    ///         strictly positive when repayAmt < debt.
    function testFuzz_repay_neverOverpays(uint256 borrowAmt, uint256 repayAmt) public {
        borrowAmt = bound(borrowAmt, 1e6, 500e18);
        // repayAmt can be anywhere from 1 up to 2x the borrow to test the overpay cap.
        repayAmt = bound(repayAmt, 1, borrowAmt * 2);

        // Bob provides liquidity.
        vm.prank(bob);
        pool.supply(address(tokenB), 1_000e18);

        // Alice supplies collateral and borrows.
        vm.prank(alice);
        pool.supply(address(tokenA), 1_000e18);
        vm.prank(alice);
        pool.borrow(address(tokenB), borrowAmt);

        uint256 debtBefore = pool.debtOf(alice, address(tokenB));
        assertGt(debtBefore, 0, "precondition: must have debt");

        // Bob repays on behalf of Alice (he has large balance and approved max).
        uint256 bobBalBefore = tokenB.balanceOf(bob);
        vm.prank(bob);
        pool.repay(address(tokenB), repayAmt, alice);
        uint256 bobBalAfter = tokenB.balanceOf(bob);

        uint256 debtAfter = pool.debtOf(alice, address(tokenB));
        uint256 actualPulled = bobBalBefore - bobBalAfter;

        // The amount pulled must never exceed the actual debt before repay.
        assertLe(actualPulled, debtBefore, "pulled more than debt (over-pay bug)");

        if (repayAmt >= debtBefore) {
            // Full or over-requested repay: debt should be zero.
            assertEq(debtAfter, 0, "debt not zeroed when repayAmt >= debtBefore");
        } else {
            // Partial repay: remaining debt is strictly positive.
            assertGt(debtAfter, 0, "debt was zeroed on a partial repay");
            // Remaining debt should be approximately debtBefore - repayAmt.
            assertApproxEqAbs(
                debtAfter, debtBefore - repayAmt, 1, "partial repay: remaining debt mismatch"
            );
        }
    }
}
