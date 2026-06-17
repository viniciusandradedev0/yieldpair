// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Factory } from "../../src/amm/Factory.sol";
import { Pair } from "../../src/amm/Pair.sol";
import { Router } from "../../src/amm/Router.sol";
import { AmmLibrary } from "../../src/amm/libraries/AmmLibrary.sol";
import { IPair } from "../../src/interfaces/IPair.sol";
import { TestToken } from "../../src/tokens/TestToken.sol";

/// @title RouterTest
/// @notice Unit tests for `Router`: addLiquidity (first deposit and proportional
///         second deposit), removeLiquidity, swapExactTokensForTokens, and the
///         deadline/slippage/path revert paths.
contract RouterTest is Test {
    Factory internal factory;
    Router internal router;
    TestToken internal tokenA;
    TestToken internal tokenB;
    TestToken internal tokenC;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant INITIAL_BALANCE = 1_000_000 ether;

    function setUp() public {
        factory = new Factory();
        router = new Router(address(factory));

        tokenA = new TestToken("Token A", "TKA", 0);
        tokenB = new TestToken("Token B", "TKB", 0);
        tokenC = new TestToken("Token C", "TKC", 0);

        tokenA.mint(alice, INITIAL_BALANCE);
        tokenB.mint(alice, INITIAL_BALANCE);
        tokenC.mint(alice, INITIAL_BALANCE);
        tokenA.mint(bob, INITIAL_BALANCE);
        tokenB.mint(bob, INITIAL_BALANCE);
        tokenC.mint(bob, INITIAL_BALANCE);

        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // addLiquidity
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice First addLiquidity on a fresh pair uses the desired amounts as-is
    ///         (reserves are zero, so no ratio constraint applies).
    function test_addLiquidity_first_usesDesiredAmounts() public {
        uint256 amountADesired = 10 ether;
        uint256 amountBDesired = 40 ether;

        vm.prank(alice);
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            address(tokenA),
            address(tokenB),
            amountADesired,
            amountBDesired,
            0,
            0,
            alice,
            block.timestamp
        );

        assertEq(amountA, amountADesired, "first deposit uses amountADesired as-is");
        assertEq(amountB, amountBDesired, "first deposit uses amountBDesired as-is");

        uint256 expectedLiquidity = Math.sqrt(amountA * amountB) - 1000;
        assertEq(liquidity, expectedLiquidity, "liquidity == sqrt(a*b) - MINIMUM_LIQUIDITY");

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        assertEq(Pair(pairAddr).balanceOf(alice), liquidity, "alice received LP tokens");
    }

    /// @notice Second addLiquidity respects the optimal ratio derived from current
    ///         reserves: if amountBDesired exceeds the ratio-implied amount, only the
    ///         ratio-implied amount of B is taken (and vice-versa), each checked
    ///         against the *Min bounds.
    function test_addLiquidity_second_respectsOptimalRatioAndMins() public {
        // Alice seeds the pool at a 1:4 ratio (10 A : 40 B).
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 40 ether, 0, 0, alice, block.timestamp
        );

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        (uint112 r0, uint112 r1,) = Pair(pairAddr).getReserves();
        (address token0,) = AmmLibrary.sortTokens(address(tokenA), address(tokenB));
        (uint256 reserveA, uint256 reserveB) =
            address(tokenA) == token0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        // Bob desires 5 A and 100 B (way more B than the ratio needs).
        uint256 amountADesired = 5 ether;
        uint256 amountBDesired = 100 ether;

        uint256 amountBOptimal = AmmLibrary.quote(amountADesired, reserveA, reserveB);
        assertLe(
            amountBOptimal, amountBDesired, "B optimal should fit within desired B in this scenario"
        );

        vm.prank(bob);
        (uint256 amountA, uint256 amountB,) = router.addLiquidity(
            address(tokenA),
            address(tokenB),
            amountADesired,
            amountBDesired,
            0,
            0,
            bob,
            block.timestamp
        );

        assertEq(amountA, amountADesired, "amountA == amountADesired when B fits within desired");
        assertEq(amountB, amountBOptimal, "amountB == amountBOptimal (ratio-implied)");
        assertEq(amountB, amountADesired * 4, "ratio-implied B == 4x A at the 1:4 pool ratio");
    }

    /// @notice When amountBDesired is the binding constraint, the router instead
    ///         computes amountAOptimal from amountBDesired and uses (amountAOptimal,
    ///         amountBDesired), reverting if amountAOptimal < amountAMin.
    function test_addLiquidity_second_otherBranch_amountBDesiredBinding() public {
        // Seed pool at 1:4 ratio (10 A : 40 B).
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 40 ether, 0, 0, alice, block.timestamp
        );

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        (uint112 r0, uint112 r1,) = Pair(pairAddr).getReserves();
        (address token0,) = AmmLibrary.sortTokens(address(tokenA), address(tokenB));
        (uint256 reserveA, uint256 reserveB) =
            address(tokenA) == token0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        // Bob desires 100 A but only 50 B — B is the binding constraint
        // (amountBOptimal for 100 A would be 400 B > 50 B desired).
        uint256 amountADesired = 100 ether;
        uint256 amountBDesired = 50 ether;

        uint256 amountAOptimal = AmmLibrary.quote(amountBDesired, reserveB, reserveA);

        vm.prank(bob);
        (uint256 amountA, uint256 amountB,) = router.addLiquidity(
            address(tokenA),
            address(tokenB),
            amountADesired,
            amountBDesired,
            0,
            0,
            bob,
            block.timestamp
        );

        assertEq(amountB, amountBDesired, "amountB == amountBDesired when A is over-supplied");
        assertEq(amountA, amountAOptimal, "amountA == amountAOptimal (ratio-implied from B)");
        assertEq(
            amountA,
            amountBDesired / 4,
            "ratio-implied A == B * (10/40) == B/4 at the 1:4 pool ratio"
        );
    }

    /// @notice addLiquidity reverts with InsufficientBAmount if the ratio-implied B
    ///         falls below amountBMin.
    function test_addLiquidity_revert_insufficientBAmount() public {
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 40 ether, 0, 0, alice, block.timestamp
        );

        // Bob desires 5 A (ratio-implied B == 20) but sets amountBMin too high.
        vm.prank(bob);
        vm.expectRevert(Router.InsufficientBAmount.selector);
        router.addLiquidity(
            address(tokenA), address(tokenB), 5 ether, 100 ether, 0, 21 ether, bob, block.timestamp
        );
    }

    /// @notice addLiquidity reverts with InsufficientAAmount if the ratio-implied A
    ///         falls below amountAMin (the amountBDesired-binding branch).
    function test_addLiquidity_revert_insufficientAAmount() public {
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 40 ether, 0, 0, alice, block.timestamp
        );

        // Bob desires 100 A, 50 B -> amountAOptimal == 12.5 A, but amountAMin is set higher.
        vm.prank(bob);
        vm.expectRevert(Router.InsufficientAAmount.selector);
        router.addLiquidity(
            address(tokenA), address(tokenB), 100 ether, 50 ether, 13 ether, 0, bob, block.timestamp
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // removeLiquidity
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice removeLiquidity burns LP tokens and returns the underlying tokens
    ///         proportionally to the share of totalSupply burned.
    function test_removeLiquidity_returnsProportionalAmounts() public {
        vm.prank(alice);
        (,, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 40 ether, 0, 0, alice, block.timestamp
        );

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        Pair pair = Pair(pairAddr);

        uint256 burnAmount = liquidity / 2;
        (uint256 expectedAmountA, uint256 expectedAmountB) =
            _expectedRemoveAmounts(pair, burnAmount);

        vm.startPrank(alice);
        pair.approve(address(router), burnAmount);
        (uint256 amountA, uint256 amountB) = router.removeLiquidity(
            address(tokenA), address(tokenB), burnAmount, 0, 0, alice, block.timestamp
        );
        vm.stopPrank();

        assertEq(amountA, expectedAmountA, "amountA proportional to burned share");
        assertEq(amountB, expectedAmountB, "amountB proportional to burned share");
        assertEq(
            pair.balanceOf(alice),
            liquidity - burnAmount,
            "alice LP balance decreases by burned amount"
        );
    }

    /// @dev Computes the expected `(amountA, amountB)` for burning `burnAmount` LP
    ///      tokens from `pair`, independently of `removeLiquidity`'s own output.
    function _expectedRemoveAmounts(Pair pair, uint256 burnAmount)
        internal
        view
        returns (uint256 expectedAmountA, uint256 expectedAmountB)
    {
        uint256 totalSupplyBefore = pair.totalSupply();
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();

        uint256 expectedAmount0 = (burnAmount * uint256(r0Before)) / totalSupplyBefore;
        uint256 expectedAmount1 = (burnAmount * uint256(r1Before)) / totalSupplyBefore;

        (address token0,) = AmmLibrary.sortTokens(address(tokenA), address(tokenB));
        (expectedAmountA, expectedAmountB) = address(tokenA) == token0
            ? (expectedAmount0, expectedAmount1)
            : (expectedAmount1, expectedAmount0);
    }

    /// @notice removeLiquidity reverts with InsufficientAAmount/BAmount if the
    ///         returned amounts fall below the requested minimums.
    function test_removeLiquidity_revert_slippage() public {
        vm.prank(alice);
        (,, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 40 ether, 0, 0, alice, block.timestamp
        );

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        Pair pair = Pair(pairAddr);

        vm.startPrank(alice);
        pair.approve(address(router), liquidity);

        // Set amountAMin absurdly high so it can't possibly be satisfied.
        vm.expectRevert(Router.InsufficientAAmount.selector);
        router.removeLiquidity(
            address(tokenA),
            address(tokenB),
            liquidity,
            type(uint256).max,
            0,
            alice,
            block.timestamp
        );
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // swapExactTokensForTokens
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice swapExactTokensForTokens executes the swap and returns amounts
    ///         consistent with AmmLibrary's getAmountsOut, crediting `to` with the
    ///         final output.
    function test_swapExactTokensForTokens_executesSwap() public {
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 100 ether, 100 ether, 0, 0, alice, block.timestamp
        );

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 amountIn = 1 ether;
        uint256[] memory expectedAmounts = router.getAmountsOut(amountIn, path);

        uint256 bobBalanceBefore = tokenB.balanceOf(bob);
        uint256 aliceBalanceBeforeA = tokenA.balanceOf(alice);

        vm.prank(bob);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn, expectedAmounts[1], path, bob, block.timestamp
        );

        assertEq(amounts[0], amountIn, "amounts[0] == amountIn");
        assertEq(amounts[1], expectedAmounts[1], "amounts[1] matches getAmountsOut");
        assertEq(
            tokenB.balanceOf(bob),
            bobBalanceBefore + expectedAmounts[1],
            "bob receives the computed output"
        );

        // Sanity: alice's balance untouched (she's just the LP).
        assertEq(
            tokenA.balanceOf(alice),
            aliceBalanceBeforeA,
            "alice's tokenA balance unaffected by bob's swap"
        );
    }

    /// @notice swapExactTokensForTokens reverts with InsufficientOutputAmount if the
    ///         actual output would be below `amountOutMin` (slippage protection).
    function test_swapExactTokensForTokens_revert_insufficientOutputAmount() public {
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 100 ether, 100 ether, 0, 0, alice, block.timestamp
        );

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 amountIn = 1 ether;
        uint256[] memory expectedAmounts = router.getAmountsOut(amountIn, path);

        vm.prank(bob);
        vm.expectRevert(Router.InsufficientOutputAmount.selector);
        router.swapExactTokensForTokens(
            amountIn, expectedAmounts[1] + 1, path, bob, block.timestamp
        );
    }

    /// @notice swapExactTokensForTokens reverts with Expired if the deadline is in
    ///         the past.
    function test_swapExactTokensForTokens_revert_expired() public {
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 100 ether, 100 ether, 0, 0, alice, block.timestamp
        );

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        // Warp forward so block.timestamp > deadline (deadline == 0 is always in the past
        // once block.timestamp > 0, which is the default in Foundry).
        vm.warp(100);

        vm.prank(bob);
        vm.expectRevert(Router.Expired.selector);
        router.swapExactTokensForTokens(1 ether, 0, path, bob, 50);
    }

    /// @notice swapExactTokensForTokens reverts with InvalidPath if path.length < 2.
    function test_swapExactTokensForTokens_revert_invalidPath() public {
        address[] memory path = new address[](1);
        path[0] = address(tokenA);

        vm.prank(bob);
        vm.expectRevert(Router.InvalidPath.selector);
        router.swapExactTokensForTokens(1 ether, 0, path, bob, block.timestamp);
    }

    /// @notice Multi-hop swap (A -> B -> C) routes the output of the first hop
    ///         directly into the second pair and credits `to` with the final amount.
    function test_swapExactTokensForTokens_multiHop() public {
        vm.startPrank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 100 ether, 100 ether, 0, 0, alice, block.timestamp
        );
        router.addLiquidity(
            address(tokenB), address(tokenC), 100 ether, 100 ether, 0, 0, alice, block.timestamp
        );
        vm.stopPrank();

        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256 amountIn = 1 ether;
        uint256[] memory expectedAmounts = router.getAmountsOut(amountIn, path);

        uint256 bobBalanceBefore = tokenC.balanceOf(bob);

        vm.prank(bob);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn, expectedAmounts[2], path, bob, block.timestamp
        );

        assertEq(amounts[2], expectedAmounts[2], "final amount matches getAmountsOut");
        assertEq(
            tokenC.balanceOf(bob),
            bobBalanceBefore + expectedAmounts[2],
            "bob receives final hop output"
        );
    }
}
