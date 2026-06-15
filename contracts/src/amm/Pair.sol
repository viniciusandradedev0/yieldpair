// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IPair } from "../interfaces/IPair.sol";

/// @title Pair
/// @notice Uniswap V2-style constant-product (x*y=k) pool. LP shares are minted as an
///         ERC20 token ("YieldPair LP" / "YP-LP").
/// @dev invariant: `reserve0 * reserve1` (k) never decreases across `swap` — after the
///      0.30% fee it strictly increases. `_update` is the only place reserves change,
///      and it is always called with `balance0`/`balance1` read from the tokens
///      themselves, so stored reserves always reflect the pool's actual balances
///      immediately after any state-changing call returns.
/// @dev invariant: the first `mint` permanently locks `MINIMUM_LIQUIDITY` LP shares to
///      `address(0)`, so `totalSupply()` can never return to zero once liquidity has
///      existed — this removes the share-inflation / divide-by-zero attack on an
///      empty pool for all subsequent `mint`/`burn` calls.
/// @dev The Pair trusts its caller (the Router) to have already transferred input
///      tokens to this contract before calling `mint`/`swap` — minted liquidity and
///      swap amounts are derived from the *delta* between current balances and the
///      previously stored reserves, not from any `amount` parameter.
contract Pair is ERC20, ReentrancyGuard, IPair {
    using SafeERC20 for IERC20;

    /// @dev Fixed-point resolution for the UQ112x112 cumulative price accumulators.
    uint256 private constant Q112 = 2 ** 112;

    /// @inheritdoc IPair
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @inheritdoc IPair
    address public immutable factory;

    /// @inheritdoc IPair
    address public token0;

    /// @inheritdoc IPair
    address public token1;

    /// @dev Packed with `reserve1` and `blockTimestampLast` into a single storage slot.
    uint112 private reserve0;

    /// @dev Packed with `reserve0` and `blockTimestampLast` into a single storage slot.
    uint112 private reserve1;

    /// @dev Timestamp (mod 2**32) of the block in which reserves were last updated.
    uint32 private blockTimestampLast;

    /// @inheritdoc IPair
    uint256 public price0CumulativeLast;

    /// @inheritdoc IPair
    uint256 public price1CumulativeLast;

    /// @inheritdoc IPair
    uint256 public kLast;

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

    /// @param factory_ Address of the `Factory` that will deploy and `initialize` this pair.
    constructor(address factory_) ERC20("YieldPair LP", "YP-LP") {
        factory = factory_;
    }

    /// @inheritdoc IPair
    /// @dev Callable exactly once, only by `factory`, immediately after deployment.
    function initialize(address token0_, address token1_) external {
        if (msg.sender != factory) revert Forbidden();
        if (token0 != address(0) || token1 != address(0)) revert AlreadyInitialized();
        token0 = token0_;
        token1 = token1_;
    }

    /// @inheritdoc IPair
    function getReserves()
        public
        view
        returns (uint112 reserve0_, uint112 reserve1_, uint32 blockTimestampLast_)
    {
        reserve0_ = reserve0;
        reserve1_ = reserve1;
        blockTimestampLast_ = blockTimestampLast;
    }

    /// @notice Updates reserves and the TWAP price accumulators, then emits `Sync`.
    /// @dev Called at the end of every state-changing function with the pool's *current*
    ///      token balances (`balance0`/`balance1`) and the *previous* reserves
    ///      (`reserve0_`/`reserve1_`), which must be read before this function executes.
    ///      The cumulative-price update intentionally wraps on overflow: both the
    ///      `uint256` accumulators and the `uint32` timestamp are meant to overflow
    ///      (mod 2**256 / mod 2**32 respectively), and an off-chain TWAP consumer
    ///      computes deltas which are correct under modular arithmetic regardless of
    ///      wraparound. The block is therefore `unchecked` to allow this wrap without
    ///      reverting under Solidity 0.8's default overflow checks.
    /// @param balance0 This contract's current `token0` balance.
    /// @param balance1 This contract's current `token1` balance.
    /// @param reserve0_ The reserve of `token0` before this update.
    /// @param reserve1_ The reserve of `token1` before this update.
    function _update(uint256 balance0, uint256 balance1, uint112 reserve0_, uint112 reserve1_)
        private
    {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();

        unchecked {
            uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            if (timeElapsed != 0 && reserve0_ != 0 && reserve1_ != 0) {
                // UQ112x112 fixed-point: (reserveOther << 112) / reserveSelf, times
                // timeElapsed, accumulated. Wraps intentionally — see dev note above.
                // The division must happen before the `* timeElapsed` multiplication:
                // this is the instantaneous spot price in UQ112x112, which is then
                // weighted by the elapsed time — multiplying first would change the
                // fixed-point scale of the accumulator, not just its precision.
                // forge-lint: disable-next-line(divide-before-multiply)
                price0CumulativeLast += (uint256(reserve1_) * Q112 / reserve0_) * timeElapsed;
                // forge-lint: disable-next-line(divide-before-multiply)
                price1CumulativeLast += (uint256(reserve0_) * Q112 / reserve1_) * timeElapsed;
            }
            blockTimestampLast = blockTimestamp;
        }

        // Safe: the `Overflow()` check above guarantees both balances fit in uint112.
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve0 = uint112(balance0);
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve1 = uint112(balance1);

        emit Sync(reserve0, reserve1);
    }

    /// @inheritdoc IPair
    /// @dev Liquidity is computed from the *delta* between current token balances and
    ///      the stored reserves — the caller (Router) must transfer `token0`/`token1`
    ///      to this contract before calling `mint`.
    ///
    ///      First mint (empty pool): `liquidity = sqrt(amount0 * amount1) -
    ///      MINIMUM_LIQUIDITY`, and `MINIMUM_LIQUIDITY` LP shares are permanently
    ///      burned to `address(0)` — see contract-level invariant.
    ///
    ///      Subsequent mints: `liquidity = min(amount0 * totalSupply / reserve0,
    ///      amount1 * totalSupply / reserve1)`. Both divisions round down (floor),
    ///      which under-mints LP relative to the exact ratio — i.e. rounds against
    ///      the depositor and in favor of the pool. Taking the `min` of the two
    ///      forces deposits at the current ratio; any excess of the larger-ratio
    ///      token is simply absorbed into reserves as a gift to existing LPs.
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 reserve0_, uint112 reserve1_,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0_;
        uint256 amount1 = balance1 - reserve1_;

        uint256 totalSupply_ = totalSupply();
        if (totalSupply_ == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(
                (amount0 * totalSupply_) / reserve0_, (amount1 * totalSupply_) / reserve1_
            );
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();

        _mint(to, liquidity);

        _update(balance0, balance1, reserve0_, reserve1_);
        kLast = uint256(reserve0) * reserve1;

        emit Mint(msg.sender, amount0, amount1);
    }

    /// @inheritdoc IPair
    /// @dev The caller (Router) must transfer the LP tokens to be burned to this
    ///      contract before calling `burn` — `liquidity` is read from this contract's
    ///      own LP balance.
    ///
    ///      `amount{0,1} = liquidity * balance{0,1} / totalSupply`, rounded down
    ///      (floor): the withdrawer receives slightly less than the exact pro-rata
    ///      share, with the remainder staying in the pool — rounds against the user,
    ///      in favor of remaining LPs.
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint112 reserve0_, uint112 reserve1_,) = getReserves();
        address token0_ = token0;
        address token1_ = token1;
        uint256 balance0 = IERC20(token0_).balanceOf(address(this));
        uint256 balance1 = IERC20(token1_).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        uint256 totalSupply_ = totalSupply();
        amount0 = (liquidity * balance0) / totalSupply_;
        amount1 = (liquidity * balance1) / totalSupply_;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burn(address(this), liquidity);

        balance0 -= amount0;
        balance1 -= amount1;

        _update(balance0, balance1, reserve0_, reserve1_);
        kLast = uint256(reserve0) * reserve1;

        IERC20(token0_).safeTransfer(to, amount0);
        IERC20(token1_).safeTransfer(to, amount1);

        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @inheritdoc IPair
    /// @dev Optional flash-swap callback (`data.length > 0` invoking an
    ///      `IUniswapV2Callee`-style hook on `to` before the k-check) is OUT OF SCOPE
    ///      for this step and is intentionally NOT implemented — `data` is accepted
    ///      for interface compatibility but otherwise ignored.
    ///
    ///      The k-check `(b0*1000 - in0*3) * (b1*1000 - in1*3) >= r0*r1*1000^2`
    ///      simultaneously enforces the 0.30% fee on whichever token(s) were sent in
    ///      and guarantees `k` does not decrease (see `AmmLibrary` for the equivalent
    ///      `getAmountOut`/`getAmountIn` formulas used by the Router to size trades).
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata /* data */
    )
        external
        nonReentrant
    {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();

        (uint112 reserve0_, uint112 reserve1_,) = getReserves();
        if (amount0Out >= reserve0_ || amount1Out >= reserve1_) revert InsufficientLiquidity();
        if (to == token0 || to == token1) revert InvalidTo();

        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);

        // `data` is accepted for interface compatibility; flash-swap callbacks are
        // out of scope for this step (see dev note above).

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        (uint256 amount0In, uint256 amount1In) =
            _settleSwap(balance0, balance1, amount0Out, amount1Out, reserve0_, reserve1_);

        _update(balance0, balance1, reserve0_, reserve1_);

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @dev Computes the input amounts implied by the balance/reserve delta and
    ///      enforces `InsufficientInputAmount` and the k-check. Split out from `swap`
    ///      purely to keep that function's stack within Solidity's limit.
    /// @param balance0 This contract's `token0` balance after sending out `amount0Out`.
    /// @param balance1 This contract's `token1` balance after sending out `amount1Out`.
    /// @param amount0Out Amount of `token0` already sent to `to`.
    /// @param amount1Out Amount of `token1` already sent to `to`.
    /// @param reserve0_ The reserve of `token0` before this swap.
    /// @param reserve1_ The reserve of `token1` before this swap.
    /// @return amount0In Amount of `token0` the caller sent in (0 if none).
    /// @return amount1In Amount of `token1` the caller sent in (0 if none).
    function _settleSwap(
        uint256 balance0,
        uint256 balance1,
        uint256 amount0Out,
        uint256 amount1Out,
        uint112 reserve0_,
        uint112 reserve1_
    ) private pure returns (uint256 amount0In, uint256 amount1In) {
        amount0In = balance0 > reserve0_ - amount0Out ? balance0 - (reserve0_ - amount0Out) : 0;
        amount1In = balance1 > reserve1_ - amount1Out ? balance1 - (reserve1_ - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
        uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
        if (balance0Adjusted * balance1Adjusted < uint256(reserve0_) * reserve1_ * 1_000_000) {
            revert K();
        }
    }

    /// @inheritdoc IPair
    /// @dev Sends any token balance in excess of the stored reserves to `to`. Useful
    ///      for recovering tokens sent directly to the pair by mistake.
    function skim(address to) external nonReentrant {
        address token0_ = token0;
        address token1_ = token1;
        uint256 balance0 = IERC20(token0_).balanceOf(address(this));
        uint256 balance1 = IERC20(token1_).balanceOf(address(this));

        uint256 excess0 = balance0 - reserve0;
        uint256 excess1 = balance1 - reserve1;

        if (excess0 > 0) IERC20(token0_).safeTransfer(to, excess0);
        if (excess1 > 0) IERC20(token1_).safeTransfer(to, excess1);
    }

    /// @inheritdoc IPair
    /// @dev Forces stored reserves to match actual token balances (e.g. after a
    ///      rebasing token adjustment or direct transfer into the pair).
    function sync() external nonReentrant {
        (uint112 reserve0_, uint112 reserve1_,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        _update(balance0, balance1, reserve0_, reserve1_);
    }
}
