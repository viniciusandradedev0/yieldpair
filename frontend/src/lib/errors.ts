import { BaseError } from "viem";

/**
 * Maps an arbitrary error thrown by a wagmi write/read (most commonly a viem
 * `BaseError`) to a short, friendly message safe to show in the UI.
 *
 * Pure function — no wagmi/viem runtime calls, only structural inspection —
 * so it's trivial to unit test without mocking a wallet or provider.
 */
export function friendlyErrorMessage(error: unknown): string {
  if (error == null) return "Erro desconhecido.";

  if (error instanceof BaseError) {
    const short = error.shortMessage ?? error.message;
    return mapKnownMessage(short) ?? short;
  }

  if (error instanceof Error) {
    return mapKnownMessage(error.message) ?? error.message;
  }

  if (typeof error === "string") {
    return mapKnownMessage(error) ?? error;
  }

  return "Erro desconhecido. Tente novamente.";
}

/**
 * Recognizes a handful of very common substrings (rejection, insufficient
 * funds, allowance, etc.) and returns a localized, user-friendly message.
 * Returns `undefined` when nothing matches, so the caller can fall back to
 * the original (already-short) message.
 */
function mapKnownMessage(message: string): string | undefined {
  const lower = message.toLowerCase();

  if (lower.includes("user rejected") || lower.includes("user denied")) {
    return "Você rejeitou a transação na carteira.";
  }

  if (lower.includes("insufficient funds")) {
    return "Saldo insuficiente para cobrir o valor e/ou o gas da transação.";
  }

  if (lower.includes("insufficient allowance") || lower.includes("exceeds allowance")) {
    return "Allowance insuficiente — aprove o gasto do token antes de continuar.";
  }

  if (lower.includes("insufficientliquidity")) {
    return "Liquidez insuficiente no pool para concluir esta operação agora.";
  }

  if (lower.includes("insufficient_output_amount") || lower.includes("insufficientoutputamount")) {
    return "O preço se moveu além do slippage configurado. Tente novamente ou aumente a tolerância.";
  }

  if (lower.includes("expired") || lower.includes("deadline")) {
    return "A transação expirou (deadline). Tente novamente.";
  }

  if (lower.includes("healthfactor") || lower.includes("health factor")) {
    return "Essa operação deixaria sua posição abaixo do health factor mínimo.";
  }

  if (lower.includes("network changed") || lower.includes("chain mismatch")) {
    return "A rede da carteira mudou. Volte para Sepolia e tente novamente.";
  }

  if (lower.includes("nonce too low") || lower.includes("replacement transaction underpriced")) {
    return "Conflito de nonce/gas com outra transação pendente. Tente novamente em alguns segundos.";
  }

  if (lower.includes("intrinsic gas too low") || lower.includes("out of gas")) {
    return "Gas insuficiente para executar a transação.";
  }

  return undefined;
}
