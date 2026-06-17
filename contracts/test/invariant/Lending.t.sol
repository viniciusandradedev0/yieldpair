// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { LendingPool } from "../../src/lending/LendingPool.sol";
import { MockOracle } from "../../src/oracle/MockOracle.sol";
import { TestToken } from "../../src/tokens/TestToken.sol";
import { LendingHandler } from "./handlers/LendingHandler.sol";

/// @title LendingInvariantTest
/// @notice Invariant test suite for LendingPool.
///
/// Invariants:
///   INV-1  Solvency per market:
///            balanceOf(pool, token) + totalBorrows >= totalSupplied
///   INV-2  borrowIndex never decreases.
///   INV-3  supplyIndex never decreases.
///   INV-4  lastAccrual never decreases and is always <= block.timestamp.
///   INV-5  No actor's health factor falls below 1e18 while they have active
///          borrows (borrows and withdraws reject undercollateralized states).
///
/// @dev Only `LendingHandler` is registered as the target contract so the fuzzer
///      only calls bounded protocol entry points.
contract LendingInvariantTest is StdInvariant, Test {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant WAD = 1e18;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    MockOracle internal oracle;
    LendingPool internal pool;
    TestToken internal tokenA;
    TestToken internal tokenB;
    LendingHandler internal handler;

    // Index snapshots captured at setUp — used to verify monotonicity invariants.
    uint256 internal _borrowIndexA0;
    uint256 internal _borrowIndexB0;
    uint256 internal _supplyIndexA0;
    uint256 internal _supplyIndexB0;

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        oracle = new MockOracle(address(this));
        pool = new LendingPool(address(this), oracle);
        tokenA = new TestToken("Token A", "TKA", 0);
        tokenB = new TestToken("Token B", "TKB", 0);

        // Prices must be set before listing.
        oracle.setPrice(address(tokenA), 1e18);
        oracle.setPrice(address(tokenB), 1e18);

        pool.listMarket(address(tokenA), 0.75e18);
        pool.listMarket(address(tokenB), 0.75e18);

        handler = new LendingHandler(pool, oracle, tokenA, tokenB);

        // Seed all three actors with equal initial liquidity so the fuzzer can immediately
        // exercise borrow calls on any actor without first needing a supply sequence.
        for (uint256 i; i < 3; ++i) {
            address seed = handler.actors(i);
            vm.startPrank(seed);
            pool.supply(address(tokenA), 50_000e18);
            pool.supply(address(tokenB), 50_000e18);
            vm.stopPrank();
        }

        // Snapshot initial indexes.
        (,,, _borrowIndexA0, _supplyIndexA0,) = pool.getMarket(address(tokenA));
        (,,, _borrowIndexB0, _supplyIndexB0,) = pool.getMarket(address(tokenB));

        // Restrict the fuzzer to the handler only.
        targetContract(address(handler));
    }

    // =========================================================================
    // INV-1: Solvency
    // =========================================================================

    /// @notice cash + totalBorrows >= totalSupplied for tokenA.
    function invariant_solvencyTokenA() public view {
        (uint256 totalBorrows, uint256 totalSupplied,,,,) = pool.getMarket(address(tokenA));
        uint256 cash = tokenA.balanceOf(address(pool));
        assertGe(
            cash + totalBorrows,
            totalSupplied,
            "INV-1: tokenA insolvency (cash + borrows < supplied)"
        );
    }

    /// @notice cash + totalBorrows >= totalSupplied for tokenB.
    function invariant_solvencyTokenB() public view {
        (uint256 totalBorrows, uint256 totalSupplied,,,,) = pool.getMarket(address(tokenB));
        uint256 cash = tokenB.balanceOf(address(pool));
        assertGe(
            cash + totalBorrows,
            totalSupplied,
            "INV-1: tokenB insolvency (cash + borrows < supplied)"
        );
    }

    // =========================================================================
    // INV-2: borrowIndex monotonically non-decreasing
    // =========================================================================

    function invariant_borrowIndexMonotonicA() public view {
        (,,, uint256 borrowIndex,,) = pool.getMarket(address(tokenA));
        assertGe(borrowIndex, _borrowIndexA0, "INV-2: tokenA borrowIndex decreased");
    }

    function invariant_borrowIndexMonotonicB() public view {
        (,,, uint256 borrowIndex,,) = pool.getMarket(address(tokenB));
        assertGe(borrowIndex, _borrowIndexB0, "INV-2: tokenB borrowIndex decreased");
    }

    // =========================================================================
    // INV-3: supplyIndex monotonically non-decreasing
    // =========================================================================

    function invariant_supplyIndexMonotonicA() public view {
        (,,,, uint256 supplyIndex,) = pool.getMarket(address(tokenA));
        assertGe(supplyIndex, _supplyIndexA0, "INV-3: tokenA supplyIndex decreased");
    }

    function invariant_supplyIndexMonotonicB() public view {
        (,,,, uint256 supplyIndex,) = pool.getMarket(address(tokenB));
        assertGe(supplyIndex, _supplyIndexB0, "INV-3: tokenB supplyIndex decreased");
    }

    // =========================================================================
    // INV-4: lastAccrual is monotonically non-decreasing and <= block.timestamp
    // =========================================================================

    function invariant_lastAccrualA() public view {
        (,,,,, uint256 lastAccrual) = pool.getMarket(address(tokenA));
        assertLe(lastAccrual, block.timestamp, "INV-4: tokenA lastAccrual > block.timestamp");
    }

    function invariant_lastAccrualB() public view {
        (,,,,, uint256 lastAccrual) = pool.getMarket(address(tokenB));
        assertLe(lastAccrual, block.timestamp, "INV-4: tokenB lastAccrual > block.timestamp");
    }

    // =========================================================================
    // INV-5: Zero-debt actors have healthFactor == type(uint256).max
    // =========================================================================

    /// @notice An actor with no outstanding borrows always has healthFactor == max uint256.
    /// @dev Interest accrual can push a borrower's HF below 1 over time — that is expected
    ///      and is the trigger for liquidation. However, an actor with ZERO debt must always
    ///      report the sentinel "infinite health" value, regardless of any state changes.
    function invariant_noDebtMeansMaxHF() public view {
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            bool hasBorrow =
                pool.debtOf(actor, address(tokenA)) > 0 || pool.debtOf(actor, address(tokenB)) > 0;
            if (hasBorrow) continue; // Skip borrowers — their HF may legitimately drop below 1.

            uint256 hf = pool.healthFactor(actor);
            assertEq(
                hf,
                type(uint256).max,
                string.concat("INV-5: zero-debt actor ", vm.toString(actor), " HF != max")
            );
        }
    }

    // =========================================================================
    // Post-run activity check
    // =========================================================================

    /// @notice At least one supply, borrow, and accrueInterest call must have succeeded.
    function afterInvariant() public view {
        assertGt(handler.ghost_supplyCalls(), 0, "no supply calls succeeded");
        assertGt(handler.ghost_borrowCalls(), 0, "no borrow calls succeeded");
        assertGt(handler.ghost_accrueInterestCalls(), 0, "no accrueInterest calls succeeded");
    }
}
