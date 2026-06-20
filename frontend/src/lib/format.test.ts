import { describe, expect, it } from "vitest";
import {
  UINT256_MAX,
  borrowRateToApr,
  estimateSupplyApr,
  formatPercent,
  formatTokenAmount,
  interpretHealthFactor,
  wadToNumber,
} from "./format";

describe("wadToNumber", () => {
  it("converts 1e18 to 1", () => {
    expect(wadToNumber(10n ** 18n)).toBe(1);
  });

  it("converts 1.5e18 to 1.5", () => {
    expect(wadToNumber(1_500_000_000_000_000_000n)).toBe(1.5);
  });

  it("converts 0 to 0", () => {
    expect(wadToNumber(0n)).toBe(0);
  });
});

describe("interpretHealthFactor", () => {
  it("treats type(uint256).max as infinite/healthy (no debt)", () => {
    const view = interpretHealthFactor(UINT256_MAX);
    expect(view.ratio).toBe(Infinity);
    expect(view.status).toBe("healthy");
    expect(view.label).toContain("∞");
  });

  it("is healthy at exactly 1.5", () => {
    const view = interpretHealthFactor(1_500_000_000_000_000_000n);
    expect(view.status).toBe("healthy");
    expect(view.ratio).toBeCloseTo(1.5);
  });

  it("is warning between 1.0 and 1.5", () => {
    const view = interpretHealthFactor(1_200_000_000_000_000_000n);
    expect(view.status).toBe("warning");
  });

  it("is healthy at exactly 1.0 boundary is warning (not danger)", () => {
    const view = interpretHealthFactor(10n ** 18n);
    expect(view.status).toBe("warning");
  });

  it("is danger below 1.0", () => {
    const view = interpretHealthFactor(900_000_000_000_000_000n);
    expect(view.status).toBe("danger");
  });

  it("is danger at 0 (fully underwater)", () => {
    const view = interpretHealthFactor(0n);
    expect(view.status).toBe("danger");
    expect(view.ratio).toBe(0);
  });
});

describe("borrowRateToApr", () => {
  it("annualizes a per-second rate", () => {
    // ~10% APR spread evenly per second: 0.10 / secondsPerYear, scaled to WAD.
    const secondsPerYear = 365 * 24 * 60 * 60;
    const targetApr = 0.1;
    const ratePerSecond = BigInt(Math.round((targetApr / secondsPerYear) * 1e18));
    const apr = borrowRateToApr(ratePerSecond);
    expect(apr).toBeCloseTo(targetApr, 2);
  });

  it("returns 0 for a 0 rate", () => {
    expect(borrowRateToApr(0n)).toBe(0);
  });
});

describe("estimateSupplyApr", () => {
  it("multiplies utilization by borrow APR", () => {
    const utilization = 500_000_000_000_000_000n; // 0.5 WAD == 50%
    const ratePerSecond = 1_000_000_000n;
    const supplyApr = estimateSupplyApr(utilization, ratePerSecond);
    const borrowApr = borrowRateToApr(ratePerSecond);
    expect(supplyApr).toBeCloseTo(0.5 * borrowApr, 6);
  });

  it("is 0 when utilization is 0", () => {
    expect(estimateSupplyApr(0n, 1_000_000_000n)).toBe(0);
  });
});

describe("formatPercent", () => {
  it("formats a fraction as a percent string", () => {
    expect(formatPercent(0.05)).toBe("5.00%");
  });

  it("formats Infinity as the infinity symbol", () => {
    expect(formatPercent(Infinity)).toBe("∞");
  });
});

describe("formatTokenAmount", () => {
  it("formats a whole-number amount with no fraction", () => {
    expect(formatTokenAmount(10n ** 18n, 18)).toBe("1");
  });

  it("formats a fractional amount, trimming trailing zeros", () => {
    // 1.5 tokens at 18 decimals
    expect(formatTokenAmount(1_500_000_000_000_000_000n, 18)).toBe("1.5");
  });

  it("truncates to the requested max fraction digits", () => {
    const value = 1_123_456_000_000_000_000n; // 1.123456
    expect(formatTokenAmount(value, 18, 2)).toBe("1.12");
  });

  it("formats 0 as 0", () => {
    expect(formatTokenAmount(0n, 18)).toBe("0");
  });

  it("respects non-18 decimals", () => {
    expect(formatTokenAmount(1_500_000n, 6)).toBe("1.5");
  });
});
