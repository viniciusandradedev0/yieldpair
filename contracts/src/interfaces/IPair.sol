// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IPair
/// @notice Interface for a Uniswap V2-style constant-product pool whose LP shares are
///         an ERC20 token (the ERC20/EIP-2612 surface is provided separately by the
///         OZ `ERC20` base contract that `Pair` will inherit, so it is not repeated here).
/// @dev invariant: reserve0 * reserve1 (k) never decreases after `swap` (after fees,
///      it strictly increases); `mint`/`burn` preserve the pool's per-share value.
interface IPair {
    /// @notice Emitted when liquidity is minted to `sender`, crediting `amount0`/`amount1`.
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);

    /// @notice Emitted when liquidity is burned by `sender`, returning `amount0`/`amount1` to `to`.
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);

    /// @notice Emitted on every swap.
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    /// @notice Emitted whenever the stored reserves are synced to the actual token balances.
    event Sync(uint112 reserve0, uint112 reserve1);

    /// @notice LP tokens permanently locked on first mint to prevent the
    ///         share-inflation / division-by-zero attack on an empty pool.
    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    /// @notice The factory that deployed this pair.
    function factory() external view returns (address);

    /// @notice The first token of the pair, sorted by address.
    function token0() external view returns (address);

    /// @notice The second token of the pair, sorted by address.
    function token1() external view returns (address);

    /// @notice Current reserves and the timestamp of the last reserve update.
    /// @return reserve0 Reserve of token0, as of `blockTimestampLast`.
    /// @return reserve1 Reserve of token1, as of `blockTimestampLast`.
    /// @return blockTimestampLast Timestamp (mod 2**32) of the last reserve update.
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice Cumulative price of token1 in terms of token0, UQ112x112 fixed point,
    ///         accumulated over time for TWAP oracles.
    function price0CumulativeLast() external view returns (uint256);

    /// @notice Cumulative price of token0 in terms of token1, UQ112x112 fixed point,
    ///         accumulated over time for TWAP oracles.
    function price1CumulativeLast() external view returns (uint256);

    /// @notice reserve0 * reserve1, as of the most recent liquidity event (used for
    ///         protocol fee accounting on mint/burn).
    function kLast() external view returns (uint256);

    /// @notice One-time initializer called by the factory immediately after deployment.
    /// @param token0_ Address of token0 (already sorted).
    /// @param token1_ Address of token1 (already sorted).
    function initialize(address token0_, address token1_) external;

    /// @notice Mints LP tokens to `to` based on the tokens transferred to this
    ///         contract since the last call (balances vs. stored reserves).
    /// @param to Recipient of the minted LP tokens.
    /// @return liquidity Amount of LP tokens minted.
    function mint(address to) external returns (uint256 liquidity);

    /// @notice Burns the LP tokens held by this contract and sends the underlying
    ///         token0/token1 to `to`.
    /// @param to Recipient of the withdrawn tokens.
    /// @return amount0 Amount of token0 sent to `to`.
    /// @return amount1 Amount of token1 sent to `to`.
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Swaps tokens. The caller must have already transferred the input
    ///         token(s) to this contract before calling.
    /// @param amount0Out Amount of token0 to send to `to`.
    /// @param amount1Out Amount of token1 to send to `to`.
    /// @param to Recipient of the output tokens (and target of the optional flash callback).
    /// @param data If non-empty, triggers an `IUniswapV2Callee`-style flash-swap callback to `to`.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    /// @notice Forces the pool's balances to match the stored reserves by sending any
    ///         excess token balance to `to`.
    /// @param to Recipient of the skimmed excess tokens.
    function skim(address to) external;

    /// @notice Forces the stored reserves to match the pool's current token balances.
    function sync() external;
}
