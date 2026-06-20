// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IPair
/// @notice Interface for a Uniswap V2-style constant-product pool whose LP shares are
///         an ERC20 token (the ERC20/EIP-2612 surface is provided separately by the
///         OZ `ERC20` base contract that `Pair` will inherit, so it is not repeated here).
/// @dev invariant: reserve0 * reserve1 (k) never decreases after `swap` (after fees,
///      it strictly increases); `mint`/`burn` preserve the pool's per-share value.
///
/// Token assumptions: this pool only supports "well-behaved" ERC20 tokens — i.e. tokens
/// whose `transfer`/`transferFrom` deliver exactly the stated amount to the recipient.
/// Fee-on-transfer, rebasing, and ERC777-with-hooks tokens are NOT supported and will
/// cause reserve accounting to drift, potentially breaking the k-invariant.
interface IPair {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

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

    /// @notice Emitted when the lending pool integration is configured or disabled.
    event LendingPoolSet(address indexed pool, uint16 bufferBps);

    /// @notice Emitted when excess idle liquidity is swept into the lending pool.
    event Sweep(address indexed token, uint256 amount);

    /// @notice Emitted when liquidity is recalled from the lending pool to satisfy a withdrawal
    /// or swap.
    event Recall(address indexed token, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when any function restricted to `factory` is called by someone else.
    error Forbidden();

    /// @notice Thrown if `initialize` is called more than once.
    error AlreadyInitialized();

    /// @notice Thrown when `mint`/`burn`/`swap` would move zero liquidity/output.
    error InsufficientLiquidityMinted();

    /// @notice Thrown when `burn` would return zero of both tokens.
    error InsufficientLiquidityBurned();

    /// @notice Thrown when `swap` is called with both outputs zero.
    error InsufficientOutputAmount();

    /// @notice Thrown when a requested output exceeds the available reserve.
    error InsufficientLiquidity();

    /// @notice Thrown when `swap`'s recipient is one of the pair's own tokens.
    error InvalidTo();

    /// @notice Thrown when `swap` receives no input tokens (both inputs zero).
    error InsufficientInputAmount();

    /// @notice Thrown when the post-swap constant-product check fails (k would decrease).
    error K();

    /// @notice Thrown when a reserve value would overflow `uint112` on `_update`.
    error Overflow();

    /// @notice Thrown when `bufferBps` is outside the allowed [MIN_BUFFER_BPS, MAX_BUFFER_BPS]
    /// range.
    error InvalidBuffer();

    /// @notice Thrown when `burn` cannot recall enough liquidity from the lending pool.
    error LendingWithdrawFailed();

    /// @notice Thrown when `setLendingPool` cannot drain all supplied tokens before switching
    /// pools.
    error CannotRecall();

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice LP tokens permanently locked on first mint to prevent the
    ///         share-inflation / division-by-zero attack on an empty pool.
    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    // -------------------------------------------------------------------------
    // Immutables / state
    // -------------------------------------------------------------------------

    /// @notice The factory that deployed this pair.
    function factory() external view returns (address);

    /// @notice The first token of the pair, sorted by address.
    function token0() external view returns (address);

    /// @notice The second token of the pair, sorted by address.
    function token1() external view returns (address);

    /// @notice The lending pool this pair supplies idle liquidity to, or `address(0)` for AMM-only
    /// mode.
    function lendingPool() external view returns (address);

    /// @notice Minimum fraction of total reserves that must stay liquid in this contract (basis
    /// points).
    function bufferBps() external view returns (uint16);

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Current reserves and the timestamp of the last reserve update.
    /// @return reserve0 Total reserve of token0 (physical + supplied), as of `blockTimestampLast`.
    /// @return reserve1 Total reserve of token1 (physical + supplied), as of `blockTimestampLast`.
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

    /// @notice Returns the live balance the pair currently holds in the lending pool for
    ///         each token, read directly from `ILendingPool.supplyBalanceOf` (i.e. principal
    ///         plus any accrued interest, NOT a static principal cache).
    function suppliedReserves() external view returns (uint112 s0, uint112 s1);

    // -------------------------------------------------------------------------
    // Factory-only mutators
    // -------------------------------------------------------------------------

    /// @notice One-time initializer called by the factory immediately after deployment.
    /// @param token0_ Address of token0 (already sorted).
    /// @param token1_ Address of token1 (already sorted).
    function initialize(address token0_, address token1_) external;

    /// @notice Configures (or removes) the lending pool integration for this pair.
    /// @dev Only callable by the `factory`. Recalls all previously supplied tokens first.
    /// @param pool     Address of the `ILendingPool` to integrate with, or `address(0)` to
    ///                 disable.
    /// @param bufferBps_ Minimum liquid fraction to keep in the pair (basis points).
    ///                   Ignored when `pool == address(0)`.
    function setLendingPool(address pool, uint16 bufferBps_) external;

    // -------------------------------------------------------------------------
    // User-facing mutators
    // -------------------------------------------------------------------------

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
