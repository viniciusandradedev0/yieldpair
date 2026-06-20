import { useCallback, useMemo } from "react";
import { useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { friendlyErrorMessage } from "../lib/errors";

export type TxPhase = "idle" | "awaiting-wallet" | "confirming" | "success" | "error";

export interface ContractActionState {
  phase: TxPhase;
  hash: `0x${string}` | undefined;
  error: string | null;
  isBusy: boolean;
}

/**
 * Thin wrapper around `useWriteContract` + `useWaitForTransactionReceipt`
 * that exposes a single `phase` covering the full lifecycle every write in
 * this dapp must show:
 *
 *   idle -> awaiting-wallet -> confirming -> success | error
 *
 * The transaction is only ever considered "done" once the receipt confirms
 * (`useWaitForTransactionReceipt`), never merely on send.
 */
export function useContractAction() {
  const {
    writeContract,
    writeContractAsync,
    data: hash,
    isPending: isAwaitingWallet,
    error: writeError,
    reset: resetWrite,
  } = useWriteContract();

  const {
    isLoading: isConfirming,
    isSuccess: isConfirmed,
    error: receiptError,
  } = useWaitForTransactionReceipt({ hash });

  const phase: TxPhase = useMemo(() => {
    if (writeError || receiptError) return "error";
    if (isAwaitingWallet) return "awaiting-wallet";
    if (hash && isConfirming) return "confirming";
    if (hash && isConfirmed) return "success";
    return "idle";
  }, [writeError, receiptError, isAwaitingWallet, hash, isConfirming, isConfirmed]);

  const error = writeError ?? receiptError;

  const reset = useCallback(() => {
    resetWrite();
  }, [resetWrite]);

  const state: ContractActionState = {
    phase,
    hash,
    error: error ? friendlyErrorMessage(error) : null,
    isBusy: phase === "awaiting-wallet" || phase === "confirming",
  };

  return { state, writeContract, writeContractAsync, reset };
}
