// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IFactory } from "../../interfaces/IFactory.sol";
import { IPair } from "../../interfaces/IPair.sol";

/// @title AmmLibrary
/// @notice Pure constant-product (x*y=k) AMM math shared by `Pair` and `Router`:
///         token sorting, no-fee ratio quoting, the 0.30%-fee swap formulas, and
///         `Factory`-aware reserve/path lookups for multi-hop routing.
/// @dev invariant: `getAmountOut`/`getAmountIn` are inverses up to rounding, and that
///      rounding always favors the pool (never lets `k` decrease). `getAmountsOut`/
///      `getAmountsIn` chain these per-hop formulas along a `path`, so the same
///      rounding direction (against the user, in favor of the pool) holds for every
///      hop of a multi-hop trade.
library AmmLibrary {
    /// @notice Numerator of the swap fee multiplier (997 / 1000 == 0.30% fee).
    uint256 internal constant FEE_NUMERATOR = 997;

    /// @notice Denominator of the swap fee multiplier.
    uint256 internal constant FEE_DENOMINATOR = 1000;

    /// @notice Thrown when an amount that must be strictly positive is zero.
    error InsufficientAmount();

    /// @notice Thrown when one or both reserves are zero (empty/uninitialized pool).
    error InsufficientLiquidity();

    /// @notice Thrown when `tokenA == tokenB` in `sortTokens`.
    error IdenticalAddresses();

    /// @notice Thrown when the lower-sorted token address is `address(0)`.
    error ZeroAddress();

    /// @notice Thrown when `getAmountIn`'s requested `amountOut` is >= `reserveOut`
    ///         (the pool cannot pay out that much, regardless of input).
    error InsufficientOutputAmount();

    /// @notice Thrown when a multi-hop `path` has fewer than two tokens.
    error InvalidPath();

    /// @notice Thrown when `getReserves` is asked about a pair that has not been
    ///         created on `factory` yet.
    error PairDoesNotExist();

    /// @notice Babylonian-method integer square root.
    /// @dev Thin wrapper over OZ `Math.sqrt`, which rounds down (floor) — the
    ///      correct direction for `Pair.mint`'s first-deposit liquidity formula,
    ///      since under-minting LP shares favors the pool over the depositor.
    /// @param y The value to take the square root of.
    /// @return z `floor(sqrt(y))`.
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        return Math.sqrt(y);
    }

    /// @notice Sorts two token addresses into `(token0, token1)` with `token0 < token1`.
    /// @dev Reverts if the addresses are identical (would collapse the pair) or if the
    ///      lower address is zero (would make `token0 == address(0)`, an invalid pool).
    /// @param tokenA First token address (any order).
    /// @param tokenB Second token address (any order).
    /// @return token0 The lower of the two addresses.
    /// @return token1 The higher of the two addresses.
    function sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
    }

    /// @notice Given `amountA` of one asset, returns the equivalent `amountB` at the
    ///         current reserve ratio, with no fee applied.
    /// @dev Used by `Router.addLiquidity` to compute the optimal counterpart deposit.
    ///      Rounds down: `amountB = floor(amountA * reserveB / reserveA)`. Rounding
    ///      down here means the caller is quoted slightly less `tokenB` than the exact
    ///      ratio, so a depositor matching this quote can never be short on `tokenA`
    ///      due to rounding — i.e. it rounds against over-crediting the depositor.
    /// @param amountA Amount of the first asset.
    /// @param reserveA Reserve of the first asset.
    /// @param reserveB Reserve of the second asset.
    /// @return amountB Equivalent amount of the second asset.
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        internal
        pure
        returns (uint256 amountB)
    {
        if (amountA == 0) revert InsufficientAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    /// @notice Computes the output amount of an exact-in swap, after the 0.30% fee.
    /// @dev `amountOut = floor((amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997))`.
    ///      Rounds down: the swapper receives slightly less than the exact-fee formula
    ///      would give with infinite precision, which is the direction that keeps
    ///      `k` non-decreasing (rounds against the user, in favor of the pool).
    /// @param amountIn Amount of the input token sent to the pool.
    /// @param reserveIn Reserve of the input token before the swap.
    /// @param reserveOut Reserve of the output token before the swap.
    /// @return amountOut Amount of the output token the pool will send out.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * FEE_DENOMINATOR) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Computes the required input amount of an exact-out swap, after the 0.30% fee.
    /// @dev `amountIn = floor((reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997)) + 1`.
    ///      The trailing `+ 1` rounds UP, against the user (they pay slightly more than
    ///      the exact-fee formula), which is the direction that keeps `k` non-decreasing.
    /// @param amountOut Desired amount of the output token.
    /// @param reserveIn Reserve of the input token before the swap.
    /// @param reserveOut Reserve of the output token before the swap.
    /// @return amountIn Amount of the input token the caller must provide.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (amountOut >= reserveOut) revert InsufficientOutputAmount();

        uint256 numerator = reserveIn * amountOut * FEE_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * FEE_NUMERATOR;
        amountIn = (numerator / denominator) + 1;
    }

    /// @notice Fetches the reserves of `tokenA`/`tokenB` from `factory`, ordered to
    ///         match the `(tokenA, tokenB)` argument order regardless of how the
    ///         underlying `Pair` sorts `token0`/`token1`.
    /// @dev Reverts with `PairDoesNotExist` if `factory` has no pair for these tokens.
    /// @param factory Address of the `Factory` registry.
    /// @param tokenA Address of the first token (any order).
    /// @param tokenB Address of the second token (any order).
    /// @return reserveA Reserve of `tokenA` in the pair.
    /// @return reserveB Reserve of `tokenB` in the pair.
    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0,) = sortTokens(tokenA, tokenB);
        address pair = IFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairDoesNotExist();

        (uint112 reserve0, uint112 reserve1,) = IPair(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
    }

    /// @notice Computes all intermediate output amounts for an exact-in multi-hop swap.
    /// @dev `amounts[0] == amountIn`; for each hop `i`, `amounts[i+1] =
    ///      getAmountOut(amounts[i], reserveIn, reserveOut)`. Reverts with
    ///      `InvalidPath` if `path.length < 2`.
    /// @param factory Address of the `Factory` registry.
    /// @param amountIn Exact amount of `path[0]` to swap.
    /// @param path Ordered list of token addresses; each consecutive pair must have a pair.
    /// @return amounts Array of length `path.length`, `amounts[0] == amountIn` and
    ///         `amounts[i]` is the output of hop `i-1` for `i > 0`.
    function getAmountsOut(address factory, uint256 amountIn, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InvalidPath();

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; ++i) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    /// @notice Computes all intermediate input amounts for an exact-out multi-hop swap.
    /// @dev `amounts[amounts.length - 1] == amountOut`; walking the path backwards,
    ///      for each hop `i` (from the last to the first), `amounts[i] =
    ///      getAmountIn(amounts[i+1], reserveIn, reserveOut)`. Reverts with
    ///      `InvalidPath` if `path.length < 2`.
    /// @param factory Address of the `Factory` registry.
    /// @param amountOut Exact amount of `path[path.length - 1]` desired.
    /// @param path Ordered list of token addresses; each consecutive pair must have a pair.
    /// @return amounts Array of length `path.length`, `amounts[amounts.length - 1] ==
    ///         amountOut` and `amounts[i]` is the input required for hop `i` for
    ///         `i < amounts.length - 1`.
    function getAmountsIn(address factory, uint256 amountOut, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InvalidPath();

        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; --i) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}
