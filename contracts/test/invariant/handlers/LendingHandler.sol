// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { LendingPool } from "../../../src/lending/LendingPool.sol";
import { MockOracle } from "../../../src/oracle/MockOracle.sol";
import { TestToken } from "../../../src/tokens/TestToken.sol";

/// @title LendingHandler
/// @notice Bounded action handler for invariant-testing LendingPool.
///
/// @dev Three actors cycle through supply / withdraw / borrow / repay / warpTime
///      actions against tokenA and tokenB. All calls are wrapped in try/catch so
///      the fuzzer can explore arbitrary sequences without hard-reverting on
///      legitimate edge cases (undercollateralised borrow, insufficient cash, etc.).
///
///      Ghost variables track activity so the invariant suite can verify the fuzzer
///      exercised the system meaningfully.
///
/// @dev Prices are permanently set to $1 for both tokens; no liquidation is exercised
///      here so the "never-unhealthy" invariant is cleanly verifiable.
contract LendingHandler is Test {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant WAD = 1e18;
    uint256 internal constant INITIAL_MINT = 1_000_000_000e18;

    // -------------------------------------------------------------------------
    // Protocol references
    // -------------------------------------------------------------------------

    LendingPool public pool;
    MockOracle public oracle;
    TestToken public tokenA;
    TestToken public tokenB;

    // -------------------------------------------------------------------------
    // Fixed actor set
    // -------------------------------------------------------------------------

    address[] public actors;

    // -------------------------------------------------------------------------
    // Ghost variables
    // -------------------------------------------------------------------------

    uint256 public ghost_supplyCalls;
    uint256 public ghost_borrowCalls;
    uint256 public ghost_accrueInterestCalls;
    uint256 public ghost_withdrawCalls;
    uint256 public ghost_repayCalls;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(LendingPool pool_, MockOracle oracle_, TestToken tokenA_, TestToken tokenB_) {
        pool = pool_;
        oracle = oracle_;
        tokenA = tokenA_;
        tokenB = tokenB_;

        // Create three deterministic actors with large balances and max approvals.
        for (uint256 i; i < 3; ++i) {
            address actor =
                address(uint160(uint256(keccak256(abi.encodePacked("lendingActor", i)))));
            actors.push(actor);

            tokenA.mint(actor, INITIAL_MINT);
            tokenB.mint(actor, INITIAL_MINT);

            vm.startPrank(actor);
            tokenA.approve(address(pool), type(uint256).max);
            tokenB.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    // -------------------------------------------------------------------------
    // Actor selection
    // -------------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // -------------------------------------------------------------------------
    // Bounded actions
    // -------------------------------------------------------------------------

    /// @notice Supply `amount` of `tokenSeed ? tokenB : tokenA` on behalf of `actorSeed`.
    function supply(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        address token = tokenSeed % 2 == 0 ? address(tokenA) : address(tokenB);
        amount = bound(amount, 1, 1_000e18);

        vm.prank(actor);
        try pool.supply(token, amount) {
            ghost_supplyCalls++;
        } catch {
            // Absorb legitimate reverts (e.g. market not listed, zero amount after bound).
        }
    }

    /// @notice Withdraw up to the actor's current supply balance.
    function withdraw(uint256 actorSeed, uint256 tokenSeed, uint256 fraction) external {
        address actor = _actor(actorSeed);
        address token = tokenSeed % 2 == 0 ? address(tokenA) : address(tokenB);

        uint256 bal = pool.supplyBalanceOf(actor, token);
        if (bal == 0) return;

        uint256 amount = bound(fraction, 1, bal);

        vm.prank(actor);
        try pool.withdraw(token, amount) {
            ghost_withdrawCalls++;
        } catch {
            // Undercollateralized or InsufficientCash on partial withdrawal — skip.
        }
    }

    /// @notice Borrow an amount that keeps HF >= 1 (best-effort bounded).
    /// @dev We bound the borrow to 70% of the actor's collateral value to stay well
    ///      within the 75% CF limit. If the HF check still fails (e.g. the actor
    ///      has existing borrows), the try/catch absorbs the revert.
    function borrow(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        // Borrow the opposite token to the one used as collateral to keep things simple.
        address collateral = tokenSeed % 2 == 0 ? address(tokenA) : address(tokenB);
        address borrowToken = tokenSeed % 2 == 0 ? address(tokenB) : address(tokenA);

        uint256 colBal = pool.supplyBalanceOf(actor, collateral);
        if (colBal == 0) return;

        // Conservative bound: 70% of collateral value (CF is 75%).
        uint256 maxBorrow = (colBal * 70) / 100;
        if (maxBorrow == 0) return;

        amount = bound(amount, 1, maxBorrow);

        vm.prank(actor);
        try pool.borrow(borrowToken, amount) {
            ghost_borrowCalls++;
        } catch {
            // Undercollateralized (actor has too much existing debt) or InsufficientCash.
        }
    }

    /// @notice Repay up to the actor's full debt.
    function repay(uint256 actorSeed, uint256 tokenSeed, uint256 fraction) external {
        address actor = _actor(actorSeed);
        address token = tokenSeed % 2 == 0 ? address(tokenA) : address(tokenB);

        uint256 debt = pool.debtOf(actor, token);
        if (debt == 0) return;

        uint256 amount = bound(fraction, 1, debt);

        vm.prank(actor);
        try pool.repay(token, amount, actor) {
            ghost_repayCalls++;
        } catch {
            // Absorb any unexpected revert.
        }
    }

    /// @notice Advance time and accrue interest on both markets.
    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + seconds_);
        pool.accrueInterest(address(tokenA));
        pool.accrueInterest(address(tokenB));
        ghost_accrueInterestCalls++;
    }
}
