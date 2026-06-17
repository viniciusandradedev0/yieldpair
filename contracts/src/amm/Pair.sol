// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IPair } from "../interfaces/IPair.sol";
import { ILendingPool } from "../interfaces/ILendingPool.sol";

/// @title Pair
/// @notice Uniswap V2-style constant-product (x*y=k) pool with optional idle-liquidity
///         yield via an integrated `ILendingPool`. LP shares are minted as an ERC20 token
///         ("YieldPair LP" / "YP-LP").
///
/// @dev invariant: `totalReserve0 * totalReserve1` (k, in total-coordinate space, i.e.
///      physical + supplied) never decreases across `swap` — after the 0.30% fee it
///      strictly increases. All k-checks and TWAP accumulators operate in total-reserve
///      coordinates so the lending integration is invisible to external price consumers.
///
/// @dev invariant: the first `mint` permanently locks `MINIMUM_LIQUIDITY` LP shares to
///      a dead address (`DEAD`, since OZ v5's `ERC20._mint` reverts on `address(0)`),
///      so `totalSupply()` can never return to zero once liquidity has existed — this
///      removes the share-inflation / divide-by-zero attack on an empty pool for all
///      subsequent `mint`/`burn` calls.
///
/// @dev AMM-only compatibility: when `lendingPool == address(0)` (the default),
///      `supplied0 == supplied1 == 0` always, `getReserves()` returns the physical
///      reserves unchanged, and all lending helper functions return immediately —
///      behaviour is identical to the original Uniswap V2 Pair.
///
/// @dev The Pair trusts its caller (the Router) to have already transferred input
///      tokens to this contract before calling `mint`/`swap` — minted liquidity and
///      swap amounts are derived from the *delta* between current balances and the
///      previously stored reserves, not from any `amount` parameter.
contract Pair is ERC20, ReentrancyGuard, IPair {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @dev Fixed-point resolution for the UQ112x112 cumulative price accumulators.
    uint256 private constant Q112 = 2 ** 112;

    /// @inheritdoc IPair
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Address `MINIMUM_LIQUIDITY` LP shares are permanently locked to on the
    ///         first `mint`.
    /// @dev OZ v5's `ERC20._mint` reverts with `ERC20InvalidReceiver` if `account ==
    ///      address(0)` (unlike the original Uniswap V2 ERC20, which allowed it), so
    ///      the conventional `address(0)` burn-lock target is not usable here. This
    ///      well-known "dead address" (`0x...dEaD`) has no known private key, so
    ///      tokens sent here are unrecoverable — functionally equivalent to burning
    ///      to `address(0)` for the purpose of permanently locking `MINIMUM_LIQUIDITY`.
    address private constant DEAD = address(0xdEaD);

    /// @notice Minimum permitted buffer (5%) — ensures at least some liquidity stays liquid.
    uint16 public constant MIN_BUFFER_BPS = 500;

    /// @notice Maximum permitted buffer (100%) — disables sweeping entirely.
    uint16 public constant MAX_BUFFER_BPS = 10_000;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @inheritdoc IPair
    address public immutable factory;

    // -------------------------------------------------------------------------
    // Storage — token identities
    // -------------------------------------------------------------------------

    /// @inheritdoc IPair
    address public token0;

    /// @inheritdoc IPair
    address public token1;

    // -------------------------------------------------------------------------
    // Storage — AMM reserves (physical balances held by this contract)
    // -------------------------------------------------------------------------

    /// @dev Physical balance of token0 in this contract. Packed with reserve1 and
    ///      blockTimestampLast into one slot.
    uint112 private reserve0;

    /// @dev Physical balance of token1 in this contract. Packed with reserve0 and
    ///      blockTimestampLast into one slot.
    uint112 private reserve1;

    /// @dev Timestamp (mod 2**32) of the block in which reserves were last updated.
    uint32 private blockTimestampLast;

    // -------------------------------------------------------------------------
    // Storage — lending integration
    // -------------------------------------------------------------------------

    /// @inheritdoc IPair
    address public lendingPool;

    /// @inheritdoc IPair
    uint16 public bufferBps;

    /// @dev Principal of token0 currently supplied to `lendingPool` (NOT shares).
    ///      Packed with supplied1 into one slot.
    uint112 private supplied0;

    /// @dev Principal of token1 currently supplied to `lendingPool` (NOT shares).
    ///      Packed with supplied0 into one slot.
    uint112 private supplied1;

    // -------------------------------------------------------------------------
    // Storage — TWAP / fee accounting
    // -------------------------------------------------------------------------

    /// @inheritdoc IPair
    uint256 public price0CumulativeLast;

    /// @inheritdoc IPair
    uint256 public price1CumulativeLast;

    /// @inheritdoc IPair
    uint256 public kLast;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param factory_ Address of the `Factory` that will deploy and `initialize` this pair.
    constructor(address factory_) ERC20("YieldPair LP", "YP-LP") {
        factory = factory_;
    }

    // -------------------------------------------------------------------------
    // Factory-only mutators
    // -------------------------------------------------------------------------

    /// @inheritdoc IPair
    /// @dev Callable exactly once, only by `factory`, immediately after deployment.
    function initialize(address token0_, address token1_) external {
        if (msg.sender != factory) revert Forbidden();
        if (token0 != address(0) || token1 != address(0)) revert AlreadyInitialized();
        token0 = token0_;
        token1 = token1_;
    }

    /// @inheritdoc IPair
    /// @dev CEI: validation → recall all supplied funds (external) → state mutation.
    ///      `_recallAll` is called before updating `lendingPool`/`bufferBps` so the
    ///      old pool is still set during the withdrawal, satisfying CEI.
    function setLendingPool(address pool, uint16 bufferBps_) external {
        if (msg.sender != factory) revert Forbidden();
        if (pool != address(0) && (bufferBps_ < MIN_BUFFER_BPS || bufferBps_ > MAX_BUFFER_BPS)) {
            revert InvalidBuffer();
        }
        // Drain all supplied funds from the current lending pool before switching.
        _recallAll();
        lendingPool = pool;
        bufferBps = bufferBps_;
        emit LendingPoolSet(pool, bufferBps_);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IPair
    /// @dev Returns TOTAL reserves (physical + supplied). TWAP consumers and k-checks
    ///      always see the full economic reserve regardless of where funds physically sit.
    function getReserves()
        public
        view
        returns (uint112 reserve0_, uint112 reserve1_, uint32 blockTimestampLast_)
    {
        reserve0_ = reserve0 + supplied0;
        reserve1_ = reserve1 + supplied1;
        blockTimestampLast_ = blockTimestampLast;
    }

    /// @inheritdoc IPair
    function suppliedReserves() external view returns (uint112 s0, uint112 s1) {
        return (supplied0, supplied1);
    }

    // -------------------------------------------------------------------------
    // User-facing mutators
    // -------------------------------------------------------------------------

    /// @inheritdoc IPair
    /// @dev Liquidity is computed from the *delta* between current token balances and
    ///      the stored total reserves — the caller (Router) must transfer `token0`/`token1`
    ///      to this contract before calling `mint`.
    ///
    ///      First mint (empty pool): `liquidity = sqrt(amount0 * amount1) -
    ///      MINIMUM_LIQUIDITY`, and `MINIMUM_LIQUIDITY` LP shares are permanently
    ///      locked to `DEAD` — see contract-level invariant.
    ///
    ///      Subsequent mints: `liquidity = min(amount0 * totalSupply / totalReserve0,
    ///      amount1 * totalSupply / totalReserve1)`. Both divisions round down (floor),
    ///      which under-mints LP relative to the exact ratio — i.e. rounds against
    ///      the depositor and in favor of the pool. Taking the `min` of the two
    ///      forces deposits at the current ratio; any excess of the larger-ratio
    ///      token is simply absorbed into reserves as a gift to existing LPs.
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        // Read total reserves (physical + supplied) for delta and denominator.
        (uint112 totalReserve0_, uint112 totalReserve1_,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        // Delta of physical balance vs. total reserves gives the newly deposited amounts.
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;

        uint256 totalSupply_ = totalSupply();
        if (totalSupply_ == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(DEAD, MINIMUM_LIQUIDITY);
        } else {
            // Denominator uses totalReserve (physical + supplied) so the share price
            // is always consistent whether or not funds are in the lending pool.
            // Rounds DOWN — mints fewer LP tokens, rounding against the depositor.
            uint256 _totalReserve0 = uint256(totalReserve0_);
            uint256 _totalReserve1 = uint256(totalReserve1_);
            liquidity = Math.min(
                (amount0 * totalSupply_) / _totalReserve0, (amount1 * totalSupply_) / _totalReserve1
            );
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();

        _mint(to, liquidity);

        // _update records physical balance as reserve; totalReserve args drive TWAP.
        _update(balance0, balance1, totalReserve0_, totalReserve1_);
        kLast = uint256(reserve0 + supplied0) * (reserve1 + supplied1);

        // Sweep any idle liquidity above the buffer into the lending pool.
        if (lendingPool != address(0)) {
            _sweepExcess(token0, IERC20(token0).balanceOf(address(this)), reserve0 + supplied0);
            _sweepExcess(token1, IERC20(token1).balanceOf(address(this)), reserve1 + supplied1);
        }

        emit Mint(msg.sender, amount0, amount1);
    }

    /// @inheritdoc IPair
    /// @dev The caller (Router) must transfer the LP tokens to be burned to this
    ///      contract before calling `burn` — `liquidity` is read from this contract's
    ///      own LP balance.
    ///
    ///      `amount{0,1} = liquidity * totalReserve{0,1} / totalSupply`, rounded down
    ///      (floor): the withdrawer receives slightly less than the exact pro-rata
    ///      share, with the remainder staying in the pool — rounds against the user,
    ///      in favor of remaining LPs.
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        // Capture total reserves before any state change.
        (uint112 totalReserve0_, uint112 totalReserve1_,) = getReserves();
        address token0_ = token0;
        address token1_ = token1;
        uint256 liquidity = balanceOf(address(this));

        uint256 totalSupply_ = totalSupply();
        // Compute pro-rata amounts using TOTAL reserves (physical + supplied).
        // Rounds DOWN — the withdrawer receives slightly less; remainder stays in pool.
        amount0 = (liquidity * uint256(totalReserve0_)) / totalSupply_;
        amount1 = (liquidity * uint256(totalReserve1_)) / totalSupply_;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        // Checks complete; burn LP tokens (Effects).
        _burn(address(this), liquidity);

        // Ensure sufficient physical liquidity exists for each token, recalling from
        // the lending pool if necessary. This is an external call — occurs after
        // _burn (effects) but before safeTransfer (interactions), maintaining CEI
        // for the overall function. If either recall fails, revert with LendingWithdrawFailed.
        if (!_ensureLiquidity(token0_, amount0)) revert LendingWithdrawFailed();
        if (!_ensureLiquidity(token1_, amount1)) revert LendingWithdrawFailed();

        // Read physical balances after potential recalls.
        uint256 balance0 = IERC20(token0_).balanceOf(address(this)) - amount0;
        uint256 balance1 = IERC20(token1_).balanceOf(address(this)) - amount1;

        _update(balance0, balance1, totalReserve0_, totalReserve1_);
        kLast = uint256(reserve0 + supplied0) * (reserve1 + supplied1);

        // Interactions: transfer tokens to recipient.
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
    ///      The k-check `(total0*1000 - in0*3) * (total1*1000 - in1*3) >= r0*r1*1000^2`
    ///      simultaneously enforces the 0.30% fee on whichever token(s) were sent in
    ///      and guarantees `k` does not decrease (see `AmmLibrary` for the equivalent
    ///      `getAmountOut`/`getAmountIn` formulas used by the Router to size trades).
    ///      All arithmetic operates in total-reserve coordinates (physical + supplied).
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

        // Read TOTAL reserves (physical + supplied) — all swap math uses these.
        (uint112 totalReserve0_, uint112 totalReserve1_,) = getReserves();
        if (amount0Out >= totalReserve0_ || amount1Out >= totalReserve1_) {
            revert InsufficientLiquidity();
        }
        if (to == token0 || to == token1) revert InvalidTo();

        // Ensure physical liquidity is available before transferring out (Checks).
        // _ensureLiquidity is an external call that may recall from the lending pool,
        // but it only mutates `reserve_i`/`supplied_i` accounting — it must happen
        // before the safeTransfer (Interactions) below to satisfy CEI.
        if (amount0Out > 0) {
            if (!_ensureLiquidity(token0, amount0Out)) revert InsufficientLiquidity();
            IERC20(token0).safeTransfer(to, amount0Out);
        }
        if (amount1Out > 0) {
            if (!_ensureLiquidity(token1, amount1Out)) revert InsufficientLiquidity();
            IERC20(token1).safeTransfer(to, amount1Out);
        }

        // `data` is accepted for interface compatibility; flash-swap callbacks are
        // out of scope for this step (see dev note above).

        // Settle, update reserves, and sweep — split into a helper to avoid stack-too-deep.
        (uint256 amount0In, uint256 amount1In) =
            _finalizeSwap(amount0Out, amount1Out, totalReserve0_, totalReserve1_);

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @dev Reads post-output balances, runs the k-check, updates reserves, and sweeps.
    ///      Extracted from `swap` to keep the parent function's stack within the 16-slot limit.
    function _finalizeSwap(
        uint256 amount0Out,
        uint256 amount1Out,
        uint112 totalReserve0_,
        uint112 totalReserve1_
    ) private returns (uint256 amount0In, uint256 amount1In) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        (amount0In, amount1In) = _settleSwap(
            balance0 + supplied0,
            balance1 + supplied1,
            amount0Out,
            amount1Out,
            totalReserve0_,
            totalReserve1_
        );

        _update(balance0, balance1, totalReserve0_, totalReserve1_);

        if (lendingPool != address(0)) {
            _sweepExcess(token0, IERC20(token0).balanceOf(address(this)), reserve0 + supplied0);
            _sweepExcess(token1, IERC20(token1).balanceOf(address(this)), reserve1 + supplied1);
        }
    }

    /// @inheritdoc IPair
    /// @dev Sends any token balance in excess of the stored PHYSICAL reserves to `to`.
    ///      Useful for recovering tokens sent directly to the pair by mistake.
    ///      `supplied_i` tokens are NOT considered excess — they are intentionally absent.
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
    /// @dev Forces stored PHYSICAL reserves to match actual token balances.
    ///      `supplied_i` is NOT altered — it remains as the lending pool principal.
    ///      `Sync` emits with TOTAL reserves (physical + supplied) for consistency.
    function sync() external nonReentrant {
        (uint112 totalReserve0_, uint112 totalReserve1_,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        _update(balance0, balance1, totalReserve0_, totalReserve1_);
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /// @notice Updates the physical reserves, TWAP accumulators, and emits `Sync`.
    /// @dev Called at the end of every state-changing function with the pool's *current*
    ///      physical token balances (`balance0`/`balance1`) and the *previous* TOTAL
    ///      reserves (`reserve0_`/`reserve1_`, i.e. physical + supplied before this call),
    ///      which must be read before this function executes.
    ///
    ///      The cumulative-price update intentionally wraps on overflow: both the
    ///      `uint256` accumulators and the `uint32` timestamp are meant to overflow
    ///      (mod 2**256 / mod 2**32 respectively), and an off-chain TWAP consumer
    ///      computes deltas which are correct under modular arithmetic regardless of
    ///      wraparound. The block is therefore `unchecked` to allow this wrap without
    ///      reverting under Solidity 0.8's default overflow checks.
    ///
    ///      The Overflow check guards that the new physical balance fits in uint112.
    ///      Total reserves (balance + supplied) are not separately overflow-checked here
    ///      because they were read from uint112 fields before this call — they can only
    ///      shrink or grow by the same amount as the physical balance, and the physical
    ///      balance is capped by the uint112 check.
    ///
    /// @param balance0  This contract's current physical `token0` balance.
    /// @param balance1  This contract's current physical `token1` balance.
    /// @param reserve0_ TOTAL `token0` reserve (physical + supplied) before this update.
    /// @param reserve1_ TOTAL `token1` reserve (physical + supplied) before this update.
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

        // Record physical balance as the stored reserve.
        // Safe: the `Overflow()` check above guarantees both balances fit in uint112.
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve0 = uint112(balance0);
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve1 = uint112(balance1);

        // Emit Sync with TOTAL reserves (physical + supplied) so external consumers
        // always see the full economic reserve.
        emit Sync(reserve0 + supplied0, reserve1 + supplied1);
    }

    /// @dev Computes the input amounts implied by the total-balance/total-reserve delta and
    ///      enforces `InsufficientInputAmount` and the k-check in total-reserve coordinates.
    ///      Split out from `swap` purely to keep that function's stack within Solidity's limit.
    /// @param total0       token0 total (physical balance + supplied) after sending out amount0Out.
    /// @param total1       token1 total (physical balance + supplied) after sending out amount1Out.
    /// @param amount0Out   Amount of token0 already sent to `to`.
    /// @param amount1Out   Amount of token1 already sent to `to`.
    /// @param totalReserve0_ TOTAL token0 reserve before this swap.
    /// @param totalReserve1_ TOTAL token1 reserve before this swap.
    /// @return amount0In Amount of token0 the caller sent in (0 if none).
    /// @return amount1In Amount of token1 the caller sent in (0 if none).
    function _settleSwap(
        uint256 total0,
        uint256 total1,
        uint256 amount0Out,
        uint256 amount1Out,
        uint112 totalReserve0_,
        uint112 totalReserve1_
    ) private pure returns (uint256 amount0In, uint256 amount1In) {
        // Delta of input in total-reserve coordinates.
        amount0In =
            total0 > totalReserve0_ - amount0Out ? total0 - (totalReserve0_ - amount0Out) : 0;
        amount1In =
            total1 > totalReserve1_ - amount1Out ? total1 - (totalReserve1_ - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        // k-check in total-reserve coordinates.
        uint256 total0Adjusted = total0 * 1000 - amount0In * 3;
        uint256 total1Adjusted = total1 * 1000 - amount1In * 3;
        if (total0Adjusted * total1Adjusted < uint256(totalReserve0_) * totalReserve1_ * 1_000_000)
        {
            revert K();
        }
    }

    /// @dev Sweeps idle physical liquidity above the buffer threshold into the lending pool.
    ///      No-op when `lendingPool == address(0)` (checked by caller).
    ///
    ///      CEI: state mutations (`reserve_i -= excess`, `supplied_i += excess`) happen
    ///      AFTER `forceApprove` but BEFORE the `supply` call would be re-entered — however,
    ///      `supply` is not re-entrant here because:
    ///        1. The nonReentrant guard on the calling function prevents re-entry into Pair.
    ///        2. The state update is applied immediately after the external `supply` call
    ///           returns, within the same function context.
    ///      Rounding: `targetLiquid` rounds UP (ceiling) so the buffer is slightly
    ///      over-reserved — this rounds against deploying funds to yield, which is
    ///      conservative and safe for the pool.
    ///
    /// @param token          Token to sweep (token0 or token1).
    /// @param physicalBalance Current physical balance of `token` in this contract.
    /// @param totalReserve   Current total reserve of `token` (physical + supplied).
    function _sweepExcess(address token, uint256 physicalBalance, uint256 totalReserve) private {
        // targetLiquid = ceil(totalReserve * bufferBps / 10_000)
        // Rounds UP so buffer is slightly over-reserved (conservative).
        uint256 targetLiquid = (totalReserve * bufferBps + 9_999) / 10_000;
        if (physicalBalance <= targetLiquid) return;

        uint256 excess = physicalBalance - targetLiquid;

        // Approve and supply to lending pool.
        IERC20(token).forceApprove(lendingPool, excess);
        ILendingPool(lendingPool).supply(token, excess);

        // Update bookkeeping: move `excess` from physical reserve to supplied.
        if (token == token0) {
            reserve0 -= uint112(excess);
            supplied0 += uint112(excess);
        } else {
            reserve1 -= uint112(excess);
            supplied1 += uint112(excess);
        }
        emit Sweep(token, excess);
    }

    /// @dev Ensures at least `amountOut` of `token` is physically available in this
    ///      contract, recalling from the lending pool if necessary.
    ///      Returns `true` if liquidity was secured, `false` if the recall failed
    ///      (e.g. lending pool has insufficient cash).
    ///      No-op (returns true) when `lendingPool == address(0)`.
    ///
    ///      CEI note: bookkeeping (`reserve_i`, `supplied_i`) is updated inside the
    ///      `try` block immediately after the `withdraw` returns — the external call
    ///      and its state effects are atomic within this helper's execution.
    ///
    /// @param token     Token to ensure (token0 or token1).
    /// @param amountOut Amount that must be physically available.
    /// @return ok       True if `amountOut` is now physically available.
    function _ensureLiquidity(address token, uint256 amountOut) private returns (bool) {
        if (lendingPool == address(0)) return true;
        uint256 physical = IERC20(token).balanceOf(address(this));
        if (physical >= amountOut) return true;

        uint256 needed = amountOut - physical;
        try ILendingPool(lendingPool).withdraw(token, needed) {
            // Update bookkeeping: move `needed` from supplied back to physical reserve.
            if (token == token0) {
                reserve0 += uint112(needed);
                supplied0 -= uint112(needed);
            } else {
                reserve1 += uint112(needed);
                supplied1 -= uint112(needed);
            }
            emit Recall(token, needed);
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Recalls ALL supplied funds from the current lending pool.
    ///      Called by `setLendingPool` before switching or disabling the lending pool.
    ///      Reverts with `CannotRecall` if any withdrawal fails.
    ///      No-op when `lendingPool == address(0)` or no funds are supplied.
    function _recallAll() private {
        address pool = lendingPool;
        if (pool == address(0)) return;

        uint112 s0 = supplied0;
        uint112 s1 = supplied1;

        if (s0 > 0) {
            // External call: withdraw principal from lending pool.
            try ILendingPool(pool).withdraw(token0, s0) {
                reserve0 += s0;
                supplied0 = 0;
                emit Recall(token0, s0);
            } catch {
                revert CannotRecall();
            }
        }

        if (s1 > 0) {
            try ILendingPool(pool).withdraw(token1, s1) {
                reserve1 += s1;
                supplied1 = 0;
                emit Recall(token1, s1);
            } catch {
                revert CannotRecall();
            }
        }
    }
}
