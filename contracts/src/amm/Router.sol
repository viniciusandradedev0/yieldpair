// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IFactory } from "../interfaces/IFactory.sol";
import { IPair } from "../interfaces/IPair.sol";
import { IRouter } from "../interfaces/IRouter.sol";
import { AmmLibrary } from "./libraries/AmmLibrary.sol";

/// @title Router
/// @notice Periphery contract that wraps `Factory`/`Pair` calls with deadline checks,
///         slippage protection, and multi-hop swap routing.
/// @dev invariant: the router never custodies tokens between calls — every external
///      function either fully completes its transfers (input tokens move directly
///      from `msg.sender` to the relevant `Pair`, and outputs move directly from the
///      last `Pair` to `to`) or reverts, leaving no dangling token balances here.
contract Router is IRouter {
    using SafeERC20 for IERC20;

    /// @inheritdoc IRouter
    address public immutable factory;

    /// @notice Thrown when `block.timestamp > deadline`.
    error Expired();

    /// @notice Thrown when the optimal `tokenA` amount in `addLiquidity` is below `amountAMin`.
    error InsufficientAAmount();

    /// @notice Thrown when the optimal `tokenB` amount in `addLiquidity` is below `amountBMin`.
    error InsufficientBAmount();

    /// @notice Thrown when the final output of a swap is below `amountOutMin`.
    error InsufficientOutputAmount();

    /// @notice Thrown when a swap `path` has fewer than two tokens.
    error InvalidPath();

    /// @notice Reverts with `Expired` if `block.timestamp > deadline`.
    /// @param deadline Unix timestamp after which the transaction must revert.
    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @param factory_ Address of the `Factory` this router routes liquidity/swaps through.
    constructor(address factory_) {
        factory = factory_;
    }

    /// @inheritdoc IRouter
    /// @dev Creates the `tokenA`/`tokenB` pair via `factory` if it does not yet exist.
    ///      The optimal deposit amounts are computed via `AmmLibrary.quote` against the
    ///      pair's current reserves: starting from `amountADesired`, if the
    ///      `tokenB`-equivalent at the current ratio fits within `amountBDesired`, that
    ///      pair `(amountADesired, amountBOptimal)` is used; otherwise the roles are
    ///      swapped and `(amountAOptimal, amountBDesired)` is used. Both branches are
    ///      checked against `amountAMin`/`amountBMin` for slippage protection. Input
    ///      tokens are pulled from `msg.sender` directly into the pair before calling
    ///      `mint`.
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        address pair = IFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = IFactory(factory).createPair(tokenA, tokenB);
        }

        (amountA, amountB) = _addLiquidityAmounts(
            pair, tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin
        );

        liquidity = _settleAddLiquidity(pair, tokenA, tokenB, amountA, amountB, to);
    }

    /// @dev Pulls `amountA` of `tokenA` and `amountB` of `tokenB` from `msg.sender`
    ///      into `pair`, then mints LP tokens to `to`. Split out from `addLiquidity`
    ///      purely to keep that function's stack within Solidity's limit.
    function _settleAddLiquidity(
        address pair,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        address to
    ) private returns (uint256 liquidity) {
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = IPair(pair).mint(to);
    }

    /// @inheritdoc IRouter
    /// @dev Transfers `liquidity` LP tokens from `msg.sender` to the pair, then calls
    ///      `burn`. The amounts returned by `burn` are ordered `(tokenA, tokenB)`
    ///      regardless of the pair's internal `token0`/`token1` sort order.
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = IFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert AmmLibrary.PairDoesNotExist();

        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = IPair(pair).burn(to);

        (address token0,) = AmmLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);

        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();
    }

    /// @inheritdoc IRouter
    /// @dev Pulls `amountIn` of `path[0]` from `msg.sender` directly into the first
    ///      pair, then iterates `IPair.swap` along `path`, sending each hop's output
    ///      directly to the next pair (or to `to` on the final hop).
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();

        amounts = AmmLibrary.getAmountsOut(factory, amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();

        address firstPair = IFactory(factory).getPair(path[0], path[1]);
        IERC20(path[0]).safeTransferFrom(msg.sender, firstPair, amounts[0]);

        _swap(amounts, path, to);
    }

    /// @dev Computes the optimal `(amountA, amountB)` deposit for `addLiquidity`
    ///      against `pair`'s current reserves, enforcing `amountAMin`/`amountBMin`.
    ///      For a freshly created (empty) pair, reserves are zero and the desired
    ///      amounts are used as-is.
    function _addLiquidityAmounts(
        address pair,
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) private view returns (uint256 amountA, uint256 amountB) {
        (uint256 reserveA, uint256 reserveB) = _pairReserves(pair, tokenA, tokenB);

        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = AmmLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                if (amountBOptimal < amountBMin) revert InsufficientBAmount();
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = AmmLibrary.quote(amountBDesired, reserveB, reserveA);
                // amountAOptimal <= amountADesired is guaranteed by the `quote` ratio.
                if (amountAOptimal < amountAMin) revert InsufficientAAmount();
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    /// @dev Reads `pair`'s reserves ordered to match `(tokenA, tokenB)`.
    function _pairReserves(address pair, address tokenA, address tokenB)
        private
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0,) = AmmLibrary.sortTokens(tokenA, tokenB);
        (uint112 reserve0, uint112 reserve1,) = IPair(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
    }

    /// @dev Executes each hop of `path`, calling `IPair.swap` with the precomputed
    ///      `amounts`. Output of hop `i` is sent to the pair for hop `i+1`, or to
    ///      `to` on the final hop.
    /// @param amounts Precomputed amounts from `AmmLibrary.getAmountsOut`, indexed in
    ///        lockstep with `path`.
    /// @param path Ordered list of token addresses.
    /// @param to Final recipient of `path[path.length - 1]`.
    function _swap(uint256[] memory amounts, address[] calldata path, address to) private {
        for (uint256 i; i < path.length - 1; ++i) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = AmmLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));

            address to_ = i < path.length - 2 ? IFactory(factory).getPair(output, path[i + 2]) : to;

            address pair = IFactory(factory).getPair(input, output);
            IPair(pair).swap(amount0Out, amount1Out, to_, new bytes(0));
        }
    }

    /// @inheritdoc IRouter
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        external
        pure
        returns (uint256 amountB)
    {
        return AmmLibrary.quote(amountA, reserveA, reserveB);
    }

    /// @inheritdoc IRouter
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut)
    {
        return AmmLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    /// @inheritdoc IRouter
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountIn)
    {
        return AmmLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    /// @inheritdoc IRouter
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        return AmmLibrary.getAmountsOut(factory, amountIn, path);
    }

    /// @inheritdoc IRouter
    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        return AmmLibrary.getAmountsIn(factory, amountOut, path);
    }
}
