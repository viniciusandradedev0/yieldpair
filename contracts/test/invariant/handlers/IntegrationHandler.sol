// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Factory } from "../../../src/amm/Factory.sol";
import { Pair } from "../../../src/amm/Pair.sol";
import { IPair } from "../../../src/interfaces/IPair.sol";
import { TestToken } from "../../../src/tokens/TestToken.sol";
import { MockLendingPool } from "../../mocks/MockLendingPool.sol";

/// @title IntegrationHandler
/// @notice Invariant handler for Pair ↔ LendingPool integration.
///
/// @dev The handler exposes four bounded entry points:
///      `doMint`, `doSwap`, `doBurn`, `doFreeze`.
///      The invariant test targets only this handler so all randomised call
///      sequences exercise the protocol's real entry points.
///
///      KEY DESIGN DECISION: `doSwap` must atomically transfer tokens AND call
///      swap — a failed swap with a pre-transferred balance would leave tokens
///      in the pair that are not reflected in the reserves, breaking the
///      `totalReserve == physical + supplied` invariant (since it would manifest
///      as `physical > reserve - supplied`). To guarantee atomicity, the swap
///      sub-call is delegated to an internal helper called via `this.` so that
///      a revert in `pair.swap()` also reverts the `token.transfer()`.
///
///      Ghost counters record how many operations actually executed so the
///      post-run `afterInvariant` hook can assert meaningful activity.
contract IntegrationHandler is Test {
    // -------------------------------------------------------------------------
    // Fixture
    // -------------------------------------------------------------------------

    Factory public factory;
    Pair public pair;
    MockLendingPool public mockLP;
    TestToken public token0;
    TestToken public token1;

    address public lp;

    uint256 public constant INITIAL_MINT = 1_000_000_000 ether;

    // -------------------------------------------------------------------------
    // Ghost counters
    // -------------------------------------------------------------------------

    uint256 public ghost_mintCalls;
    uint256 public ghost_swapCalls;
    uint256 public ghost_burnCalls;
    uint256 public ghost_freezeToggleCalls;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        Factory factory_,
        Pair pair_,
        MockLendingPool mockLP_,
        TestToken token0_,
        TestToken token1_,
        address lp_
    ) {
        factory = factory_;
        pair = pair_;
        mockLP = mockLP_;
        token0 = token0_;
        token1 = token1_;
        lp = lp_;
    }

    // -------------------------------------------------------------------------
    // Handler functions
    // -------------------------------------------------------------------------

    /// @notice Add liquidity in random amounts bounded to [1, 10 ether].
    function doMint(uint256 amount0, uint256 amount1) external {
        amount0 = bound(amount0, 1, 10 ether);
        amount1 = bound(amount1, 1, 10 ether);

        // Guard against uint112 overflow.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (uint256(r0) + amount0 > type(uint112).max) return;
        if (uint256(r1) + amount1 > type(uint112).max) return;

        // Ensure lp has enough.
        if (token0.balanceOf(lp) < amount0 || token1.balanceOf(lp) < amount1) return;

        vm.startPrank(lp);
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
        vm.stopPrank();

        try pair.mint(lp) {
            ghost_mintCalls++;
        } catch {
            // InsufficientLiquidityMinted on extremely small deposits — skip.
            // NOTE: tokens are already in the pair; sync the reserves to absorb them
            // so the accounting invariant (physical == reserve - supplied) is maintained.
            pair.sync();
        }
    }

    /// @notice Swap token0 for token1 (or vice-versa) with a randomly-sized input.
    /// @dev Atomicity guarantee: the transfer and swap happen in a single sub-call
    ///      (`_execSwap`) which is invoked via `try this._execSwap(...)`. If the
    ///      Pair reverts inside `_execSwap`, the entire sub-call (including the
    ///      token transfer) reverts, so no orphaned balance lands in the pair.
    function doSwap(uint256 amountIn, uint256 directionSeed) external {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return;

        bool zeroForOne = directionSeed % 2 == 0;
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        // Bound input to at most 50% of the in-side reserve.
        amountIn = bound(amountIn, 1, reserveIn / 2 + 1);

        if (zeroForOne && token0.balanceOf(lp) < amountIn) return;
        if (!zeroForOne && token1.balanceOf(lp) < amountIn) return;

        uint256 amountInWithFee = amountIn * 997;
        uint256 amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
        if (amountOut == 0) return;

        // Delegate to an external helper so a Pair revert also reverts the transfer.
        try this._execSwap(amountIn, amountOut, zeroForOne) {
            ghost_swapCalls++;
        } catch {
            // InsufficientLiquidity (frozen pool) or K() — skip.
        }
    }

    /// @dev EXTERNAL so it can be called via `try this._execSwap(...)`.
    ///      Transfers the input token and calls pair.swap atomically.
    ///      MUST NOT be called directly by anyone other than `doSwap`.
    function _execSwap(uint256 amountIn, uint256 amountOut, bool zeroForOne) external {
        TestToken tokenIn = zeroForOne ? token0 : token1;

        vm.startPrank(lp);
        tokenIn.transfer(address(pair), amountIn);
        vm.stopPrank();

        uint256 amount0Out = zeroForOne ? 0 : amountOut;
        uint256 amount1Out = zeroForOne ? amountOut : 0;
        pair.swap(amount0Out, amount1Out, lp, "");
    }

    /// @notice Burn a random fraction of the LP's LP-token balance.
    function doBurn(uint256 lpFraction) external {
        uint256 lpBalance = pair.balanceOf(lp);
        if (lpBalance == 0) return;

        uint256 burnAmt = bound(lpFraction, 1, lpBalance);

        vm.startPrank(lp);
        pair.transfer(address(pair), burnAmt);
        vm.stopPrank();

        try pair.burn(lp) {
            ghost_burnCalls++;
        } catch {
            // LendingWithdrawFailed when frozen — sync reserves to restore accounting.
            // The LP tokens were burned by `_burn` (Effects) but tokens not transferred.
            // This partial execution means the pair's state may differ from our expectation.
            // Calling sync() is NOT the right fix here since burn has partial state changes.
            // Instead, absorb the LP tokens back: they are sitting in the pair. We just
            // accept the revert and the invariant engine will check consistency.
        }
    }

    /// @notice Toggle the lending pool's frozen state.
    function doFreeze() external {
        if (mockLP.frozen()) {
            mockLP.unfreeze();
        } else {
            mockLP.freeze();
        }
        ghost_freezeToggleCalls++;
    }
}
