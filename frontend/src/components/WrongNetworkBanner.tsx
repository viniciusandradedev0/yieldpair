import { useChainGuard } from "../hooks/useChainGuard";

/** Shown app-wide whenever the connected wallet is on a chain other than Sepolia. */
export function WrongNetworkBanner() {
  const { isWrongNetwork, isSwitching, switchToTargetChain, targetChain } = useChainGuard();

  if (!isWrongNetwork) return null;

  return (
    <div className="flex flex-col items-center justify-between gap-2 bg-amber-500/15 px-4 py-2 text-sm text-amber-200 sm:flex-row">
      <span>
        Sua carteira está em outra rede. O YieldPair só funciona em{" "}
        <strong>{targetChain.name}</strong> (chainId {targetChain.id}).
      </span>
      <button
        type="button"
        onClick={switchToTargetChain}
        disabled={isSwitching}
        className="rounded-md bg-amber-500 px-3 py-1 font-medium text-slate-900 transition hover:bg-amber-400 disabled:opacity-60"
      >
        {isSwitching ? "Trocando..." : `Trocar para ${targetChain.name}`}
      </button>
    </div>
  );
}
