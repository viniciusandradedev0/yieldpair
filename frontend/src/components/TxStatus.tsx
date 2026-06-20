import { txUrl } from "../config/chains";
import type { ContractActionState } from "../hooks/useContractAction";

interface TxStatusProps {
  state: ContractActionState;
  /** Optional label shown for the pending state, e.g. "Aprovando mUSDC...". */
  pendingLabel?: string;
  /** Optional label shown on success, e.g. "Swap concluído!". */
  successLabel?: string;
}

/**
 * Renders the four-state transaction lifecycle UI shared by every write in
 * the dapp: aguardando carteira -> confirmando -> sucesso/erro, with a link
 * to Etherscan once a hash exists.
 */
export function TxStatus({ state, pendingLabel, successLabel }: TxStatusProps) {
  if (state.phase === "idle") return null;

  return (
    <div
      role="status"
      className="mt-3 flex flex-col gap-1 rounded-lg border border-slate-700 bg-slate-800/60 p-3 text-sm"
    >
      {state.phase === "awaiting-wallet" && (
        <p className="flex items-center gap-2 text-slate-300">
          <Spinner /> Aguardando confirmação na carteira...
        </p>
      )}

      {state.phase === "confirming" && (
        <p className="flex items-center gap-2 text-amber-300">
          <Spinner /> {pendingLabel ?? "Confirmando transação"}...
        </p>
      )}

      {state.phase === "success" && (
        <p className="text-emerald-400">{successLabel ?? "Transação confirmada."}</p>
      )}

      {state.phase === "error" && <p className="text-red-400">{state.error}</p>}

      {state.hash && (
        <a
          href={txUrl(state.hash)}
          target="_blank"
          rel="noreferrer"
          className="text-xs text-sky-400 underline underline-offset-2 hover:text-sky-300"
        >
          Ver no Etherscan ↗
        </a>
      )}
    </div>
  );
}

function Spinner() {
  return (
    <span
      aria-hidden="true"
      className="inline-block h-3 w-3 animate-spin rounded-full border-2 border-slate-500 border-t-transparent motion-reduce:animate-none"
    />
  );
}
