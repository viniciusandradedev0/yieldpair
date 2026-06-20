import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useState } from "react";
import { Dashboard } from "./components/Dashboard";
import { Faucet } from "./components/Faucet";
import { LendingPanel } from "./components/LendingPanel";
import { LiquidityPanel } from "./components/LiquidityPanel";
import { SwapPanel } from "./components/SwapPanel";
import { WrongNetworkBanner } from "./components/WrongNetworkBanner";

type Tab = "swap" | "liquidity" | "lending" | "dashboard";

const TABS: { key: Tab; label: string }[] = [
  { key: "swap", label: "Swap" },
  { key: "liquidity", label: "Liquidez" },
  { key: "lending", label: "Lending" },
  { key: "dashboard", label: "Painel" },
];

function App() {
  const [tab, setTab] = useState<Tab>("swap");

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100">
      <WrongNetworkBanner />

      <header className="flex items-center justify-between gap-4 border-b border-slate-800 px-4 py-3 sm:px-6">
        <div>
          <h1 className="text-base font-bold sm:text-lg">YieldPair</h1>
          <p className="text-[11px] text-slate-500">AMM + Lending · Sepolia testnet</p>
        </div>
        <ConnectButton showBalance={false} />
      </header>

      <main className="mx-auto flex max-w-3xl flex-col gap-4 px-4 py-6 sm:px-6">
        <Faucet />

        <nav className="flex gap-1 overflow-x-auto rounded-lg bg-slate-900/60 p-1 scrollbar-none">
          {TABS.map((t) => (
            <button
              key={t.key}
              type="button"
              onClick={() => setTab(t.key)}
              className={`flex-1 rounded-md px-3 py-2 text-sm font-medium transition ${
                tab === t.key
                  ? "bg-sky-600 text-white"
                  : "text-slate-300 hover:bg-slate-800"
              }`}
            >
              {t.label}
            </button>
          ))}
        </nav>

        {tab === "swap" && <SwapPanel />}
        {tab === "liquidity" && <LiquidityPanel />}
        {tab === "lending" && <LendingPanel />}
        {tab === "dashboard" && <Dashboard />}
      </main>

      <footer className="px-4 py-6 text-center text-[11px] text-slate-600">
        Apenas testnet (Sepolia). Não auditado. Não use em mainnet / com fundos reais.
      </footer>
    </div>
  );
}

export default App;
