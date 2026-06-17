// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IRouter
/// @notice Interface for the periphery router that wraps `Pair`/`Factory` calls with
///         deadline checks, slippage protection (`*Min`/`*Max`), and multi-hop swap paths.
/// @dev invariant: the router never custodies tokens between calls — every external
///      function either fully completes its transfers or reverts (no dangling balances).
interface IRouter {
    /// @notice The `Factory` this router routes liquidity/swaps through.
    function factory() external view returns (address);

    /// @notice Adds liquidity to the `tokenA`/`tokenB` pair, creating it via the factory
    ///         if it does not yet exist.
    /// @param tokenA First token of the pair (any order).
    /// @param tokenB Second token of the pair (any order).
    /// @param amountADesired Maximum amount of `tokenA` the caller is willing to deposit.
    /// @param amountBDesired Maximum amount of `tokenB` the caller is willing to deposit.
    /// @param amountAMin Minimum amount of `tokenA` to deposit (slippage protection).
    /// @param amountBMin Minimum amount of `tokenB` to deposit (slippage protection).
    /// @param to Recipient of the minted LP tokens.
    /// @param deadline Unix timestamp after which the transaction reverts.
    /// @return amountA Actual amount of `tokenA` deposited.
    /// @return amountB Actual amount of `tokenB` deposited.
    /// @return liquidity Amount of LP tokens minted to `to`.
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Removes liquidity from the `tokenA`/`tokenB` pair.
    /// @param tokenA First token of the pair (any order).
    /// @param tokenB Second token of the pair (any order).
    /// @param liquidity Amount of LP tokens to burn.
    /// @param amountAMin Minimum amount of `tokenA` that must be received (slippage protection).
    /// @param amountBMin Minimum amount of `tokenB` that must be received (slippage protection).
    /// @param to Recipient of the withdrawn `tokenA`/`tokenB`.
    /// @param deadline Unix timestamp after which the transaction reverts.
    /// @return amountA Amount of `tokenA` sent to `to`.
    /// @return amountB Amount of `tokenB` sent to `to`.
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    /// @notice Swaps an exact amount of input tokens for as many output tokens as possible,
    ///         along the given multi-hop `path`.
    /// @param amountIn Exact amount of `path[0]` to swap.
    /// @param amountOutMin Minimum amount of `path[path.length - 1]` that must be received
    ///        (slippage protection).
    /// @param path Ordered list of token addresses; each consecutive pair must have a pair.
    /// @param to Recipient of the final output tokens.
    /// @param deadline Unix timestamp after which the transaction reverts.
    /// @return amounts The input and all intermediate/output amounts, `amounts[0] == amountIn`
    ///         and `amounts[amounts.length - 1]` is the amount received.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Given an amount of `tokenA`, returns the equivalent amount of `tokenB`
    ///         at the current reserve ratio (no fee applied).
    /// @param amountA Amount of `tokenA`.
    /// @param reserveA Reserve of `tokenA`.
    /// @param reserveB Reserve of `tokenB`.
    /// @return amountB Equivalent amount of `tokenB`.
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        external
        pure
        returns (uint256 amountB);

    /// @notice Computes the output amount for an exact-in swap, after the 0.30% fee.
    /// @param amountIn Exact amount of the input token.
    /// @param reserveIn Reserve of the input token.
    /// @param reserveOut Reserve of the output token.
    /// @return amountOut Amount of the output token received.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut);

    /// @notice Computes the required input amount for an exact-out swap, after the 0.30% fee.
    /// @param amountOut Exact amount of the output token desired.
    /// @param reserveIn Reserve of the input token.
    /// @param reserveOut Reserve of the output token.
    /// @return amountIn Amount of the input token required.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountIn);

    /// @notice Computes all intermediate amounts for an exact-in multi-hop swap.
    /// @param amountIn Exact amount of `path[0]`.
    /// @param path Ordered list of token addresses.
    /// @return amounts `amounts[0] == amountIn`; each subsequent entry is the output of
    ///         the corresponding hop.
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    /// @notice Computes all intermediate amounts for an exact-out multi-hop swap.
    /// @param amountOut Exact amount of `path[path.length - 1]` desired.
    /// @param path Ordered list of token addresses.
    /// @return amounts `amounts[amounts.length - 1] == amountOut`; each preceding entry
    ///         is the input required for the corresponding hop.
    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}
