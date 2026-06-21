import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useState } from "react";
import { Dashboard } from "./components/Dashboard";
import { Faucet } from "./components/Faucet";
import { LendingPanel } from "./components/LendingPanel";
import { LiquidityPanel } from "./components/LiquidityPanel";
import { SwapPanel } from "./components/SwapPanel";
import { WrongNetworkBanner } from "./components/WrongNetworkBanner";

type Tab = "swap" | "liquidity" | "lending" | "dashboard";

const TABS: { key: Tab; label: string; icon: string }[] = [
  { key: "swap", label: "Swap", icon: "⇄" },
  { key: "liquidity", label: "Liquidez", icon: "◎" },
  { key: "lending", label: "Lending", icon: "🏦" },
  { key: "dashboard", label: "Painel", icon: "📊" },
];

// Swap/Liquidity are narrow forms; Lending/Dashboard use the full width.
const WIDE_TABS: Tab[] = ["lending", "dashboard"];

function App() {
  const [tab, setTab] = useState<Tab>("swap");
  const isWide = WIDE_TABS.includes(tab);

  return (
    <div className="min-h-screen text-slate-100">
      {/* ambient web3 background */}
      <div className="yp-bg">
        <div className="yp-orb left-[-6rem] top-[-4rem] h-72 w-72 bg-emerald-500/40" />
        <div className="yp-orb right-[-8rem] top-[6rem] h-80 w-80 bg-indigo-500/40" style={{ animationDelay: "-6s" }} />
        <div className="yp-orb bottom-[-6rem] left-1/3 h-72 w-72 bg-sky-500/30" style={{ animationDelay: "-10s" }} />
      </div>

      <WrongNetworkBanner />

      <header className="sticky top-0 z-20 border-b border-white/5 bg-slate-950/40 backdrop-blur-md">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-4 py-3 sm:px-6">
          <div className="flex items-center gap-2.5">
            <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-gradient-to-br from-emerald-400 to-indigo-500 text-lg font-black text-white shadow-lg shadow-emerald-500/20">
              Y
            </span>
            <div>
              <h1 className="text-base font-bold leading-none sm:text-lg">
                <span className="yp-gradient-text">YieldPair</span>
              </h1>
              <p className="mt-0.5 text-[11px] text-slate-400">AMM + Lending · Sepolia testnet</p>
            </div>
          </div>
          <ConnectButton showBalance={false} />
        </div>
      </header>

      <main className={`mx-auto flex flex-col gap-4 px-4 py-6 transition-[max-width] sm:px-6 ${isWide ? "max-w-6xl" : "max-w-xl"}`}>
        <Faucet />

        <nav className="flex gap-1 overflow-x-auto rounded-2xl border border-white/5 bg-slate-900/40 p-1 backdrop-blur scrollbar-none">
          {TABS.map((t) => (
            <button
              key={t.key}
              type="button"
              onClick={() => setTab(t.key)}
              className={`flex flex-1 items-center justify-center gap-1.5 whitespace-nowrap rounded-xl px-3 py-2 text-sm font-medium transition ${
                tab === t.key
                  ? "yp-btn-accent text-white shadow-lg shadow-indigo-500/20"
                  : "text-slate-300 hover:bg-white/5"
              }`}
            >
              <span aria-hidden className="text-xs opacity-90">{t.icon}</span>
              {t.label}
            </button>
          ))}
        </nav>

        {tab === "swap" && <SwapPanel />}
        {tab === "liquidity" && <LiquidityPanel />}
        {tab === "lending" && <LendingPanel />}
        {tab === "dashboard" && <Dashboard />}
      </main>

      <footer className="px-4 py-6 text-center text-[11px] text-slate-500">
        Apenas testnet (Sepolia). Não auditado. Não use em mainnet / com fundos reais.
      </footer>
    </div>
  );
}

export default App;
