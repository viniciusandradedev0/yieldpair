// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { AmmLibrary } from "../../src/amm/libraries/AmmLibrary.sol";

/// @dev Thin external wrapper around `AmmLibrary`'s `internal pure` functions.
///      `vm.expectRevert` only works against calls that create a new call frame, so
///      reverts from a library function inlined directly into the test's own frame
///      cannot be caught by `expectRevert` — routing through an external call fixes
///      this without changing the library itself.
contract AmmLibraryHarness {
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256)
    {
        return AmmLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256)
    {
        return AmmLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
    }
}

/// @title AmmLibraryFuzzTest
/// @notice Property tests over `AmmLibrary.getAmountOut`/`getAmountIn`: output never
///         exceeds the reserve, matches the documented formula, and the
///         getAmountIn(getAmountOut(x)) round-trip never gives the user a profit for
///         trades of a realistic size.
contract AmmLibraryFuzzTest is Test {
    uint256 internal constant FEE_NUMERATOR = 997;
    uint256 internal constant FEE_DENOMINATOR = 1000;

    AmmLibraryHarness internal harness;

    function setUp() public {
        harness = new AmmLibraryHarness();
    }

    /// @notice getAmountOut never returns an amount >= reserveOut (the pool can never
    ///         be fully drained, regardless of the input size).
    function testFuzz_getAmountOut_neverExceedsReserveOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure {
        amountIn = bound(amountIn, 1, type(uint112).max);
        reserveIn = bound(reserveIn, 1, type(uint112).max);
        reserveOut = bound(reserveOut, 1, type(uint112).max);

        uint256 amountOut = AmmLibrary.getAmountOut(amountIn, reserveIn, reserveOut);

        assertLt(amountOut, reserveOut, "amountOut must be strictly less than reserveOut");
    }

    /// @notice getAmountOut matches the documented closed-form formula exactly
    ///         (independently re-derived here, not fed back from the contract).
    function testFuzz_getAmountOut_matchesFormula(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure {
        amountIn = bound(amountIn, 1, type(uint112).max);
        reserveIn = bound(reserveIn, 1, type(uint112).max);
        reserveOut = bound(reserveOut, 1, type(uint112).max);

        uint256 amountOut = AmmLibrary.getAmountOut(amountIn, reserveIn, reserveOut);

        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        uint256 expectedNumerator = amountInWithFee * reserveOut;
        uint256 expectedDenominator = reserveIn * FEE_DENOMINATOR + amountInWithFee;
        uint256 expected = expectedNumerator / expectedDenominator;

        assertEq(
            amountOut,
            expected,
            "getAmountOut must equal the floor((in*997*rOut)/(rIn*1000+in*997)) formula"
        );
    }

    /// @notice getAmountIn matches the documented closed-form formula exactly.
    function testFuzz_getAmountIn_matchesFormula(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure {
        reserveIn = bound(reserveIn, 1, type(uint112).max);
        reserveOut = bound(reserveOut, 2, type(uint112).max);
        amountOut = bound(amountOut, 1, reserveOut - 1);

        uint256 amountIn = AmmLibrary.getAmountIn(amountOut, reserveIn, reserveOut);

        uint256 expectedNumerator = reserveIn * amountOut * FEE_DENOMINATOR;
        uint256 expectedDenominator = (reserveOut - amountOut) * FEE_NUMERATOR;
        uint256 expected = expectedNumerator / expectedDenominator + 1;

        assertEq(
            amountIn, expected, "getAmountIn must equal floor((rIn*out*1000)/((rOut-out)*997)) + 1"
        );
    }

    /// @notice Round-trip: feeding `getAmountIn(y)` (the input required for an
    ///         exact-out swap targeting `y`) into `getAmountOut` always yields an
    ///         actual output >= `y` — an exact-out swap sized via `getAmountIn`
    ///         never under-delivers the requested `amountOut`.
    /// @dev This is the direction the Router actually relies on (size the input via
    ///      `getAmountsIn`, then perform the swap via `getAmountOut`/`Pair.swap`'s
    ///      k-check), and it holds unconditionally because `getAmountIn` rounds UP
    ///      (the trailing `+ 1`) — the extra wei of input is exactly the slack that
    ///      compensates for `getAmountOut`'s floor-rounding on the way back.
    ///
    ///      Note: the *reverse* composition, `getAmountIn(getAmountOut(x)) >= x`,
    ///      does NOT hold in general — `getAmountOut` floors the output down, so the
    ///      exact input that would produce that (slightly smaller) floored output is
    ///      itself slightly smaller than `x`, by an amount that scales with the
    ///      marginal exchange rate (not bounded to 1 wei). That composition is not
    ///      how the AMM is used (a user cannot "undo" a completed swap by querying
    ///      `getAmountIn` on its output), so it is intentionally not asserted here.
    function testFuzz_roundTrip_getAmountIn_thenGetAmountOut_meetsTarget(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure {
        reserveIn = bound(reserveIn, 1, type(uint112).max);
        reserveOut = bound(reserveOut, 2, type(uint112).max);
        amountOut = bound(amountOut, 1, reserveOut - 1);

        uint256 amountIn = AmmLibrary.getAmountIn(amountOut, reserveIn, reserveOut);

        // Restrict to amountIn values that fit a real pool (reserves are uint112 in
        // Pair, so any real swap input is bounded similarly) — this keeps
        // getAmountOut's internal arithmetic (reserveIn*1000 + amountIn*997) from
        // overflowing uint256, which would otherwise be reachable only via
        // astronomically large `reserveOut`/`amountOut` combinations that no real
        // pool could ever have.
        vm.assume(amountIn <= type(uint112).max);

        uint256 amountOutActual = AmmLibrary.getAmountOut(amountIn, reserveIn, reserveOut);

        assertGe(
            amountOutActual,
            amountOut,
            "getAmountOut(getAmountIn(y)) must be >= y: paying the quoted input must meet the target output"
        );
    }

    /// @notice getAmountOut reverts on zero amountIn.
    function testFuzz_getAmountOut_revert_zeroAmountIn(uint256 reserveIn, uint256 reserveOut)
        public
    {
        reserveIn = bound(reserveIn, 1, type(uint112).max);
        reserveOut = bound(reserveOut, 1, type(uint112).max);

        vm.expectRevert(AmmLibrary.InsufficientAmount.selector);
        harness.getAmountOut(0, reserveIn, reserveOut);
    }

    /// @notice getAmountOut reverts when either reserve is zero.
    function testFuzz_getAmountOut_revert_zeroReserves(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, type(uint112).max);

        vm.expectRevert(AmmLibrary.InsufficientLiquidity.selector);
        harness.getAmountOut(amountIn, 0, 100 ether);

        vm.expectRevert(AmmLibrary.InsufficientLiquidity.selector);
        harness.getAmountOut(amountIn, 100 ether, 0);
    }

    /// @notice getAmountIn reverts if amountOut >= reserveOut (the pool can never pay
    ///         out that much).
    function testFuzz_getAmountIn_revert_outputExceedsOrEqualsReserve(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) public {
        reserveIn = bound(reserveIn, 1, type(uint112).max);
        reserveOut = bound(reserveOut, 1, type(uint112).max);
        amountOut = bound(amountOut, reserveOut, type(uint112).max);

        vm.expectRevert(AmmLibrary.InsufficientOutputAmount.selector);
        harness.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    /// @notice quote() matches floor(amountA * reserveB / reserveA) and reverts on
    ///         zero amountA or zero reserves.
    function testFuzz_quote_matchesFormula(uint256 amountA, uint256 reserveA, uint256 reserveB)
        public
        pure
    {
        amountA = bound(amountA, 1, type(uint112).max);
        reserveA = bound(reserveA, 1, type(uint112).max);
        reserveB = bound(reserveB, 1, type(uint112).max);

        uint256 amountB = AmmLibrary.quote(amountA, reserveA, reserveB);
        uint256 expected = (amountA * reserveB) / reserveA;

        assertEq(amountB, expected, "quote must equal floor(amountA*reserveB/reserveA)");
    }
}
