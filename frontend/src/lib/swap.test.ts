import { describe, expect, it } from "vitest";
import { applySlippage, deadlineFromNow, estimatePriceImpact, quotePaired } from "./swap";

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

describe("quotePaired", () => {
  it("keeps the pool ratio (amountIn * reserveOut / reserveIn)", () => {
    // pool ~3001 mUSDC : 1 mWETH (the real Sepolia seed)
    const reserveUsdc = 3_000_500n * 10n ** 18n;
    const reserveWeth = 1_000n * 10n ** 18n;
    // 3001 mUSDC should pair with ~1 mWETH
    const out = quotePaired(3001n * 10n ** 18n, reserveUsdc, reserveWeth);
    expect(out).toBeGreaterThan(99n * 10n ** 16n); // > 0.99 mWETH
    expect(out).toBeLessThanOrEqual(101n * 10n ** 16n); // <= 1.01 mWETH
  });

  it("is symmetric back to the original ratio", () => {
    const reserveA = 4_000n * 10n ** 18n;
    const reserveB = 1_000n * 10n ** 18n;
    // 1:4 pool → 400 A pairs with 100 B
    expect(quotePaired(400n * 10n ** 18n, reserveA, reserveB)).toBe(100n * 10n ** 18n);
  });

  it("returns 0 for empty reserves or zero input", () => {
    expect(quotePaired(0n, 1n, 1n)).toBe(0n);
    expect(quotePaired(1n, 0n, 1n)).toBe(0n);
    expect(quotePaired(1n, 1n, 0n)).toBe(0n);
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
