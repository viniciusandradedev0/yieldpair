/**
 * Pure formatting/number helpers shared by the dapp's screens. Kept free of
 * wagmi/viem runtime dependencies (besides plain bigint math) so they're
 * trivially unit-testable.
 */

const WAD = 10n ** 18n;

/** `type(uint256).max` — LendingPool's sentinel for "no debt / infinite health factor". */
export const UINT256_MAX = 2n ** 256n - 1n;

export type HealthStatus = "healthy" | "warning" | "danger";

export interface HealthFactorView {
  /** `Infinity` when the account has no debt (HF == type(uint256).max on-chain). */
  ratio: number;
  status: HealthStatus;
  label: string;
}

/**
 * Converts the raw 1e18-scaled `healthFactor()` return value into a UI-ready
 * view: a plain ratio, a traffic-light status, and a short label.
 *
 * - No debt (`type(uint256).max`) -> ∞, "healthy".
 * - HF >= 1.5 -> "healthy" (green)
 * - 1.0 <= HF < 1.5 -> "warning" (yellow)
 * - HF < 1.0 -> "danger" (red, liquidatable)
 */
export function interpretHealthFactor(raw: bigint): HealthFactorView {
  if (raw === UINT256_MAX) {
    return { ratio: Infinity, status: "healthy", label: "∞ (sem dívida)" };
  }

  const ratio = wadToNumber(raw);

  let status: HealthStatus;
  if (ratio >= 1.5) status = "healthy";
  else if (ratio >= 1.0) status = "warning";
  else status = "danger";

  return { ratio, status, label: ratio.toFixed(2) };
}

/** Converts a 1e18-fixed-point bigint to a JS number (loses precision beyond ~15 digits, fine for display). */
export function wadToNumber(value: bigint): number {
  // Keep 6 decimal digits of precision by scaling before the bigint->Number cast.
  const scaled = (value * 1_000_000n) / WAD;
  return Number(scaled) / 1_000_000;
}

/**
 * Annualizes a per-second borrow rate (1e18-scaled, e.g. from
 * `borrowRatePerSecond`) into an approximate APR, expressed as a plain
 * fraction (0.05 == 5%). Uses simple (non-compounded) annualization —
 * `ratePerSecond * secondsPerYear` — which is the standard approximation
 * used by most lending markets for display purposes.
 */
export function borrowRateToApr(ratePerSecondWad: bigint): number {
  const secondsPerYear = 365n * 24n * 60n * 60n;
  // Multiply in bigint space first — per-second rates are tiny (often < 1e-9
  // in WAD terms), so converting to a JS number before scaling up to a yearly
  // figure would lose all significant digits.
  return wadToNumber(ratePerSecondWad * secondsPerYear);
}

/**
 * Estimates the supply-side APR earned by liquidity providers/suppliers from
 * the utilization and borrow APR: `supplyApr = utilization * borrowApr`.
 * This mirrors the standard Aave-style relationship (ignoring reserve
 * factor, which this protocol does not carve out for suppliers).
 */
export function estimateSupplyApr(utilizationWad: bigint, borrowRatePerSecondWad: bigint): number {
  const utilization = wadToNumber(utilizationWad);
  const borrowApr = borrowRateToApr(borrowRatePerSecondWad);
  return utilization * borrowApr;
}

export function formatPercent(fraction: number, fractionDigits = 2): string {
  if (!Number.isFinite(fraction)) return "∞";
  return `${(fraction * 100).toFixed(fractionDigits)}%`;
}

export function formatTokenAmount(value: bigint, decimals: number, maxFractionDigits = 4): string {
  const divisor = 10n ** BigInt(decimals);
  const whole = value / divisor;
  const remainder = value % divisor;

  if (remainder === 0n) return whole.toString();

  const fractionStr = remainder.toString().padStart(decimals, "0").slice(0, maxFractionDigits);
  const trimmed = fractionStr.replace(/0+$/, "");
  return trimmed.length > 0 ? `${whole}.${trimmed}` : whole.toString();
}
