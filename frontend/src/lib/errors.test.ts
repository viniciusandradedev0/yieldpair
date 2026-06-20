import { BaseError } from "viem";
import { describe, expect, it } from "vitest";
import { friendlyErrorMessage } from "./errors";

class FakeBaseError extends BaseError {
  constructor(shortMessage: string) {
    super(shortMessage, { name: "FakeBaseError" });
  }
}

describe("friendlyErrorMessage", () => {
  it("maps viem BaseError user-rejection to a friendly pt-BR message", () => {
    const err = new FakeBaseError("User rejected the request.");
    expect(friendlyErrorMessage(err)).toBe("Você rejeitou a transação na carteira.");
  });

  it("maps insufficient funds errors", () => {
    const err = new FakeBaseError("insufficient funds for gas * price + value");
    expect(friendlyErrorMessage(err)).toMatch(/saldo insuficiente/i);
  });

  it("maps insufficient allowance errors", () => {
    const err = new Error("ERC20: transfer amount exceeds allowance");
    expect(friendlyErrorMessage(err)).toMatch(/allowance/i);
  });

  it("maps custom InsufficientLiquidity revert", () => {
    const err = new Error("execution reverted: InsufficientLiquidity()");
    expect(friendlyErrorMessage(err)).toMatch(/liquidez insuficiente/i);
  });

  it("maps deadline/expired errors", () => {
    const err = new Error("Router: EXPIRED deadline");
    expect(friendlyErrorMessage(err)).toMatch(/expirou/i);
  });

  it("falls back to the original short message when nothing matches", () => {
    const err = new FakeBaseError("Some unrecognized contract revert");
    expect(friendlyErrorMessage(err)).toBe("Some unrecognized contract revert");
  });

  it("handles plain strings", () => {
    expect(friendlyErrorMessage("user rejected")).toMatch(/rejeitou/i);
  });

  it("handles null/undefined gracefully", () => {
    expect(friendlyErrorMessage(null)).toBe("Erro desconhecido.");
    expect(friendlyErrorMessage(undefined)).toBe("Erro desconhecido.");
  });

  it("handles unknown object shapes without throwing", () => {
    expect(friendlyErrorMessage({ weird: true })).toMatch(/erro desconhecido/i);
  });
});
