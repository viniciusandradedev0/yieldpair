/**
 * Pure swap-math helpers (slippage, deadline, price impact). Mirrors the
 * on-chain `AmmLibrary` formulas so the UI can show accurate previews before
 * sending a transaction, but never the source of truth — `getAmountsOut` on
 * the Router is always queried for the actual quote.
 */

const BPS_DENOMINATOR = 10_000n;

/**
 * Applies a slippage tolerance (in basis points, e.g. 50 == 0.50%) to a
 * quoted output amount, rounding down — the contract-facing `amountOutMin`.
 */
export function applySlippage(amountOut: bigint, slippageBps: number): bigint {
  if (slippageBps < 0 || slippageBps > 10_000) {
    throw new Error("slippageBps must be between 0 and 10000");
  }
  const bps = BigInt(Math.round(slippageBps));
  return (amountOut * (BPS_DENOMINATOR - bps)) / BPS_DENOMINATOR;
}

/** Unix deadline (seconds) `minutesFromNow` minutes in the future. */
export function deadlineFromNow(minutesFromNow: number): bigint {
  const nowSeconds = Math.floor(Date.now() / 1000);
  return BigInt(nowSeconds + Math.round(minutesFromNow * 60));
}

/**
 * Estimated price impact of a swap, as a fraction (0.01 == 1%): the relative
 * difference between the pool's current spot price and the effective price
 * the trade executes at (`amountIn / amountOut` vs `reserveIn / reserveOut`).
 *
 * Returns 0 when reserves are empty (nothing to compare against).
 */
export function estimatePriceImpact(
  amountIn: bigint,
  amountOut: bigint,
  reserveIn: bigint,
  reserveOut: bigint,
): number {
  if (reserveIn === 0n || reserveOut === 0n || amountIn === 0n || amountOut === 0n) return 0;

  // Use a high fixed-point scale to keep bigint division precise before
  // converting to a JS number for display.
  const SCALE = 10n ** 18n;
  const spotPrice = (reserveOut * SCALE) / reserveIn; // out per in, scaled
  const execPrice = (amountOut * SCALE) / amountIn; // out per in, scaled

  if (spotPrice === 0n) return 0;

  const diff = spotPrice > execPrice ? spotPrice - execPrice : execPrice - spotPrice;
  const impactScaled = (diff * SCALE) / spotPrice;
  return Number(impactScaled) / Number(SCALE);
}

/** Common slippage presets shown in the swap UI, in basis points. */
export const SLIPPAGE_PRESETS_BPS = [10, 50, 100] as const;
