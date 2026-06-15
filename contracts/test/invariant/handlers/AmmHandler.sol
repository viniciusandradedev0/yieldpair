// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { Factory } from "../../../src/amm/Factory.sol";
import { Pair } from "../../../src/amm/Pair.sol";
import { Router } from "../../../src/amm/Router.sol";
import { AmmLibrary } from "../../../src/amm/libraries/AmmLibrary.sol";
import { TestToken } from "../../../src/tokens/TestToken.sol";

/// @title AmmHandler
/// @notice Handler for invariant testing of `Router`/`Pair`/`Factory`: exposes bounded
///         `addLiquidity`/`removeLiquidity`/`swap` entry points over a single
///         TestToken/TestToken pair, called by Foundry's invariant fuzzer in random
///         sequences with a small set of actors.
/// @dev All amounts are bounded to avoid degenerate reverts (e.g. zero amounts,
///      amounts that would overflow uint112 reserves) so that the vast majority of
///      calls succeed and meaningfully exercise the pool. `ghost_*` counters record
///      how many times each action actually executed, so the invariant test can
///      assert a minimum amount of real activity occurred.
contract AmmHandler is Test {
    Factory public factory;
    Router public router;
    TestToken public token0;
    TestToken public token1;
    Pair public pair;

    address[] public actors;

    uint256 public constant INITIAL_MINT = 1_000_000_000 ether;

    // Ghost counters, useful for sanity-checking the fuzzer actually exercised the
    // handler (and for debugging via `forge test -vvvv`).
    uint256 public ghost_addLiquidityCalls;
    uint256 public ghost_removeLiquidityCalls;
    uint256 public ghost_swapCalls;

    /// @notice Set to true if any single `swap` call is observed to decrease
    ///         `reserve0 * reserve1` (k). The invariant test asserts this stays
    ///         false for the entire random call sequence.
    bool public ghost_kDecreasedOnSwap;

    constructor(Factory factory_, Router router_, TestToken token0_, TestToken token1_) {
        factory = factory_;
        router = router_;

        // Ensure token0/token1 are stored in sorted order matching the Pair's own
        // token0/token1, purely for readability of reserve bookkeeping below (the
        // AMM math is symmetric either way).
        (address sortedToken0, address sortedToken1) =
            AmmLibrary.sortTokens(address(token0_), address(token1_));
        token0 = TestToken(sortedToken0);
        token1 = TestToken(sortedToken1);

        address pairAddr = factory.getPair(address(token0), address(token1));
        if (pairAddr == address(0)) {
            pairAddr = factory.createPair(address(token0), address(token1));
        }
        pair = Pair(pairAddr);

        // A small fixed set of actors that all approve the router up-front.
        for (uint256 i; i < 3; ++i) {
            address actor = address(uint160(uint256(keccak256(abi.encodePacked("actor", i)))));
            actors.push(actor);

            token0.mint(actor, INITIAL_MINT);
            token1.mint(actor, INITIAL_MINT);

            vm.startPrank(actor);
            token0.approve(address(router), type(uint256).max);
            token1.approve(address(router), type(uint256).max);
            pair.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Picks one of the fixed actors deterministically from a fuzzed seed.
    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @notice Adds liquidity at the pool's current ratio (or arbitrary amounts if
    ///         the pool is empty), bounded to keep reserves comfortably within
    ///         uint112 and to avoid the zero-liquidity-minted revert.
    function addLiquidity(uint256 actorSeed, uint256 amount0Desired, uint256 amount1Desired)
        external
    {
        address actor = _actor(actorSeed);

        (uint112 r0, uint112 r1,) = pair.getReserves();

        // Bound desired amounts to a sensible range. Each actor holds INITIAL_MINT of
        // each token, so cap deposits well below that and below uint112 headroom.
        amount0Desired = bound(amount0Desired, 1e6, 1_000_000 ether);
        amount1Desired = bound(amount1Desired, 1e6, 1_000_000 ether);

        // Guard against overflowing uint112 reserves (Pair._update reverts on
        // overflow, which would otherwise dominate the fuzz run once reserves grow).
        if (uint256(r0) + amount0Desired > type(uint112).max) return;
        if (uint256(r1) + amount1Desired > type(uint112).max) return;

        vm.prank(actor);
        try router.addLiquidity(
            address(token0),
            address(token1),
            amount0Desired,
            amount1Desired,
            0,
            0,
            actor,
            block.timestamp
        ) returns (
            uint256, uint256, uint256
        ) {
            ghost_addLiquidityCalls++;
        } catch {
            // InsufficientLiquidityMinted (deposit too small relative to reserves at
            // the current ratio) or similar — skip without failing the run.
        }
    }

    /// @notice Removes a bounded fraction of the calling actor's LP balance.
    function removeLiquidity(uint256 actorSeed, uint256 liquidityFraction) external {
        address actor = _actor(actorSeed);

        uint256 lpBalance = pair.balanceOf(actor);
        if (lpBalance == 0) return;

        // Burn between 1 wei and the actor's full balance.
        uint256 liquidity = bound(liquidityFraction, 1, lpBalance);

        vm.prank(actor);
        try router.removeLiquidity(
            address(token0), address(token1), liquidity, 0, 0, actor, block.timestamp
        ) returns (
            uint256, uint256
        ) {
            ghost_removeLiquidityCalls++;
        } catch {
            // InsufficientLiquidityBurned (liquidity too small to redeem any token) —
            // skip without failing the run.
        }
    }

    /// @notice Swaps a bounded amount of token0 -> token1 or token1 -> token0,
    ///         depending on `directionSeed`'s parity.
    function swap(uint256 actorSeed, uint256 directionSeed, uint256 amountIn) external {
        address actor = _actor(actorSeed);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return;

        bool zeroForOne = directionSeed % 2 == 0;
        (address tokenIn, address tokenOut, uint256 reserveIn) = zeroForOne
            ? (address(token0), address(token1), uint256(r0))
            : (address(token1), address(token0), uint256(r1));

        // Bound the input to at most the input-side reserve, so the trade never
        // moves the price by more than ~2x and amountOut stays well within reserves.
        amountIn = bound(amountIn, 1e6, reserveIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256 kBefore = uint256(r0) * uint256(r1);

        vm.prank(actor);
        try router.swapExactTokensForTokens(amountIn, 0, path, actor, block.timestamp) returns (
            uint256[] memory
        ) {
            ghost_swapCalls++;

            (uint112 r0After, uint112 r1After,) = pair.getReserves();
            uint256 kAfter = uint256(r0After) * uint256(r1After);
            if (kAfter < kBefore) {
                ghost_kDecreasedOnSwap = true;
            }
        } catch {
            // Reverts (e.g. K() at extreme ratios) are skipped without failing the run.
        }
    }
}
