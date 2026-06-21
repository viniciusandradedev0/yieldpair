import { useState } from "react";
import { parseUnits } from "viem";
import { useAccount } from "wagmi";
import { TestTokenAbi } from "../abis";
import { TOKEN_LIST } from "../config/contracts";
import { useContractAction } from "../hooks/useContractAction";
import { TxStatus } from "./TxStatus";

const FAUCET_AMOUNTS: Record<string, string> = {
  mUSDC: "10000",
  mWETH: "5",
};

/**
 * Faucet card: lets the connected wallet mint test mUSDC/mWETH via
 * `TestToken.mint(address,uint256)`, which is intentionally unrestricted.
 */
export function Faucet() {
  const { address, isConnected } = useAccount();
  const { state, writeContract, reset } = useContractAction();
  const [mintingSymbol, setMintingSymbol] = useState<string | null>(null);

  function handleMint(tokenAddress: `0x${string}`, symbol: string, decimals: number) {
    if (!address) return;
    reset();
    setMintingSymbol(symbol);
    const amount = parseUnits(FAUCET_AMOUNTS[symbol] ?? "100", decimals);
    writeContract({
      address: tokenAddress,
      abi: TestTokenAbi,
      functionName: "mint",
      args: [address, amount],
    });
  }

  return (
    <div className="yp-card p-4">
      <h2 className="text-sm font-semibold text-slate-200">Faucet (testnet)</h2>
      <p className="mt-1 text-xs text-slate-400">
        Garanta mUSDC e mWETH de teste para usar o swap, a liquidez e o lending.
      </p>

      <div className="mt-3 flex flex-wrap gap-2">
        {TOKEN_LIST.map((token) => (
          <button
            key={token.address}
            type="button"
            disabled={!isConnected || state.isBusy}
            onClick={() => handleMint(token.address, token.symbol, token.decimals)}
            className="rounded-md bg-slate-700 px-3 py-1.5 text-sm font-medium text-slate-100 transition hover:bg-slate-600 disabled:opacity-50"
          >
            Receber {FAUCET_AMOUNTS[token.symbol] ?? "100"} {token.symbol}
          </button>
        ))}
      </div>

      {mintingSymbol && (
        <TxStatus
          state={state}
          pendingLabel={`Mintando ${mintingSymbol}`}
          successLabel={`${mintingSymbol} recebido na sua carteira!`}
        />
      )}
    </div>
  );
}
