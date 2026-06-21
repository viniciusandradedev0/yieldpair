import { describe, expect, it } from "vitest";
import { applySlippage, deadlineFromNow, estimatePriceImpact } from "./swap";

describe("applySlippage", () => {
  it("reduces the amount by the given bps, rounding down", () => {
    // 50 bps == 0.5%
    expect(applySlippage(1_000_000n, 50)).toBe(995_000n);
  });

  it("returns the same amount at 0 bps", () => {
    expect(applySlippage(1_000_000n, 0)).toBe(1_000_000n);
  });

  it("returns 0 at 10000 bps (100% slippage tolerance)", () => {
    expect(applySlippage(1_000_000n, 10_000)).toBe(0n);
  });

  it("throws for out-of-range bps", () => {
    expect(() => applySlippage(1_000n, -1)).toThrow();
    expect(() => applySlippage(1_000n, 10_001)).toThrow();
  });
});

describe("deadlineFromNow", () => {
  it("returns a unix timestamp roughly N minutes in the future", () => {
    const before = Math.floor(Date.now() / 1000);
    const deadline = deadlineFromNow(20);
    const expectedMin = BigInt(before + 20 * 60 - 2);
    const expectedMax = BigInt(before + 20 * 60 + 2);
    expect(deadline >= expectedMin && deadline <= expectedMax).toBe(true);
  });
});

describe("estimatePriceImpact", () => {
  it("is ~0 for a tiny trade against deep reserves", () => {
    const reserveIn = 1_000_000n * 10n ** 18n;
    const reserveOut = 1_000_000n * 10n ** 18n;
    const amountIn = 10n ** 18n; // 1 token in a 1M-token pool
    // out = in * reserveOut / (reserveIn + in), classic constant-product approx without fee
    const amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
    const impact = estimatePriceImpact(amountIn, amountOut, reserveIn, reserveOut);
    expect(impact).toBeLessThan(0.001);
  });

  it("is large for a trade that is a big fraction of reserves", () => {
    const reserveIn = 1_000n * 10n ** 18n;
    const reserveOut = 1_000n * 10n ** 18n;
    const amountIn = 500n * 10n ** 18n; // 50% of the pool
    const amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
    const impact = estimatePriceImpact(amountIn, amountOut, reserveIn, reserveOut);
    expect(impact).toBeGreaterThan(0.2);
  });

  it("returns 0 when reserves are empty", () => {
    expect(estimatePriceImpact(1n, 1n, 0n, 0n)).toBe(0);
  });
});
