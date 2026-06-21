import { useEffect, useState } from "react";
import { formatUnits, parseUnits } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { LendingPoolAbi, TestTokenAbi } from "../abis";
import { CONTRACTS, TOKENS, type TokenInfo } from "../config/contracts";
import { useContractAction } from "../hooks/useContractAction";
import { useTokenAllowance } from "../hooks/useErc20";
import { borrowRateToApr, estimateSupplyApr, formatPercent, formatTokenAmount } from "../lib/format";
import { TokenIcon } from "./TokenIcon";
import { TxStatus } from "./TxStatus";

type Action = "supply" | "withdraw" | "borrow" | "repay";

const ACTION_LABEL: Record<Action, string> = {
  supply: "Fornecer",
  withdraw: "Retirar",
  borrow: "Emprestar",
  repay: "Pagar",
};

interface MarketData {
  token: TokenInfo;
  walletBalance: bigint;
  supplyBalance: bigint;
  debt: bigint;
  available: bigint;
  supplyApr: number;
  borrowApr: number;
  refetch: () => void;
}

/** All per-token lending reads for a single market, plus a refetch handle. */
function useMarketData(token: TokenInfo): MarketData {
  const { address } = useAccount();

  const supplyBalance = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "supplyBalanceOf",
    args: address ? [address, token.address] : undefined,
    query: { enabled: Boolean(address) },
  });
  const debt = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "debtOf",
    args: address ? [address, token.address] : undefined,
    query: { enabled: Boolean(address) },
  });
  const utilization = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "utilization",
    args: [token.address],
  });
  const borrowRate = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "borrowRatePerSecond",
    args: [token.address],
  });
  const market = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "getMarket",
    args: [token.address],
  });
  const wallet = useReadContract({
    address: token.address,
    abi: TestTokenAbi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const util = (utilization.data as bigint | undefined) ?? 0n;
  const rate = (borrowRate.data as bigint | undefined) ?? 0n;
  const m = market.data as readonly bigint[] | undefined;
  const totalBorrows = m?.[0] ?? 0n;
  const totalSupplied = m?.[1] ?? 0n;
  const available = totalSupplied > totalBorrows ? totalSupplied - totalBorrows : 0n;

  return {
    token,
    walletBalance: (wallet.data as bigint | undefined) ?? 0n,
    supplyBalance: (supplyBalance.data as bigint | undefined) ?? 0n,
    debt: (debt.data as bigint | undefined) ?? 0n,
    available,
    supplyApr: estimateSupplyApr(util, rate),
    borrowApr: borrowRateToApr(rate),
    refetch: () => {
      void supplyBalance.refetch();
      void debt.refetch();
      void utilization.refetch();
      void borrowRate.refetch();
      void market.refetch();
      void wallet.refetch();
    },
  };
}

export function LendingPanel() {
  const { isConnected } = useAccount();

  // One call per listed market. Add a useMarketData line here per new token.
  const usdc = useMarketData(TOKENS.mUSDC);
  const weth = useMarketData(TOKENS.mWETH);
  const markets: MarketData[] = [usdc, weth];

  const [modal, setModal] = useState<{ action: Action; market: MarketData } | null>(null);

  const refetchAll = () => markets.forEach((m) => m.refetch());

  const supplied = markets.filter((m) => m.supplyBalance > 0n);
  const borrowed = markets.filter((m) => m.debt > 0n);

  const open = (action: Action, market: MarketData) => setModal({ action, market });

  return (
    <div className="flex flex-col gap-4">
      <div className="grid gap-4 lg:grid-cols-2">
        {/* ---------------- SUPPLY column ---------------- */}
        <div className="flex flex-col gap-4">
          <Card title="Seus fornecimentos">
            {!isConnected ? (
              <Empty>Conecte a carteira para ver suas posições.</Empty>
            ) : supplied.length === 0 ? (
              <Empty>Nada fornecido ainda.</Empty>
            ) : (
              <div className="flex flex-col divide-y divide-white/5">
                {supplied.map((m) => (
                  <PositionRow
                    key={m.token.address}
                    token={m.token}
                    amount={formatTokenAmount(m.supplyBalance, m.token.decimals, 4)}
                    apr={m.supplyApr}
                    actionLabel="Retirar"
                    onAction={() => open("withdraw", m)}
                  />
                ))}
              </div>
            )}
          </Card>

          <Card title="Ativos para fornecer">
            <MarketTable
              head={["Ativo", "Saldo carteira", "APY", "Colateral"]}
              rows={markets.map((m) => (
                <AssetRow
                  key={m.token.address}
                  token={m.token}
                  middle={formatTokenAmount(m.walletBalance, m.token.decimals, 4)}
                  apr={m.supplyApr}
                  collateral={`${m.token.collateralFactorPct}%`}
                  actionLabel="Fornecer"
                  disabled={!isConnected}
                  onAction={() => open("supply", m)}
                />
              ))}
            />
          </Card>
        </div>

        {/* ---------------- BORROW column ---------------- */}
        <div className="flex flex-col gap-4">
          <Card title="Seus empréstimos">
            {!isConnected ? (
              <Empty>Conecte a carteira para ver suas posições.</Empty>
            ) : borrowed.length === 0 ? (
              <Empty>Nada emprestado ainda.</Empty>
            ) : (
              <div className="flex flex-col divide-y divide-white/5">
                {borrowed.map((m) => (
                  <PositionRow
                    key={m.token.address}
                    token={m.token}
                    amount={formatTokenAmount(m.debt, m.token.decimals, 4)}
                    apr={m.borrowApr}
                    aprTone="warn"
                    actionLabel="Pagar"
                    onAction={() => open("repay", m)}
                  />
                ))}
              </div>
            )}
          </Card>

          <Card title="Ativos para emprestar">
            <MarketTable
              head={["Ativo", "Disponível", "APY"]}
              rows={markets.map((m) => (
                <AssetRow
                  key={m.token.address}
                  token={m.token}
                  middle={formatTokenAmount(m.available, m.token.decimals, 2)}
                  apr={m.borrowApr}
                  aprTone="warn"
                  actionLabel="Emprestar"
                  disabled={!isConnected}
                  onAction={() => open("borrow", m)}
                />
              ))}
            />
          </Card>
        </div>
      </div>

      <p className="text-center text-xs text-slate-500">
        Os juros são acumulados por índice no LendingPool. A liquidez ociosa do par é suprida
        automaticamente aqui, então parte da "disponível" vem do próprio AMM rendendo aos LPs.
      </p>

      {modal && (
        <ActionModal
          action={modal.action}
          market={modal.market}
          onClose={() => setModal(null)}
          onSuccess={refetchAll}
        />
      )}
    </div>
  );
}

/* ------------------------------- pieces ------------------------------- */

function Card({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="yp-card p-4">
      <h2 className="text-sm font-semibold text-slate-200">{title}</h2>
      <div className="mt-3">{children}</div>
    </section>
  );
}

function Empty({ children }: { children: React.ReactNode }) {
  return <p className="py-4 text-center text-sm text-slate-500">{children}</p>;
}

function MarketTable({ head, rows }: { head: string[]; rows: React.ReactNode[] }) {
  return (
    <div>
      <div className="hidden px-2 pb-2 text-[11px] uppercase tracking-wide text-slate-500 sm:flex sm:items-center">
        <span className="flex-[1.4]">{head[0]}</span>
        <span className="flex-1 text-right">{head[1]}</span>
        <span className="flex-1 text-right">{head[2]}</span>
        {head[3] && <span className="flex-1 text-right">{head[3]}</span>}
        <span className="w-24" />
      </div>
      <div className="flex flex-col divide-y divide-white/5">{rows}</div>
    </div>
  );
}

function AssetRow({
  token,
  middle,
  apr,
  collateral,
  aprTone,
  actionLabel,
  disabled,
  onAction,
}: {
  token: TokenInfo;
  middle: string;
  apr: number;
  collateral?: string;
  aprTone?: "warn";
  actionLabel: string;
  disabled?: boolean;
  onAction: () => void;
}) {
  return (
    <div className="flex flex-wrap items-center gap-y-2 py-3 sm:flex-nowrap">
      <div className="flex flex-[1.4] items-center gap-2.5">
        <TokenIcon symbol={token.symbol} size={34} />
        <div className="leading-tight">
          <p className="text-sm font-semibold text-slate-100">{token.symbol}</p>
          <p className="text-[11px] text-slate-500">{token.name}</p>
        </div>
      </div>
      <div className="flex-1 text-right text-sm tabular-nums text-slate-200">{middle}</div>
      <div className={`flex-1 text-right text-sm font-medium tabular-nums ${aprTone === "warn" ? "text-amber-300" : "text-emerald-300"}`}>
        {formatPercent(apr)}
      </div>
      {collateral !== undefined && (
        <div className="flex-1 items-center justify-end gap-1 text-right text-xs text-slate-300">
          <span className="text-emerald-400">✓</span> {collateral}
        </div>
      )}
      <div className="flex w-full justify-end sm:w-24">
        <button
          type="button"
          disabled={disabled}
          onClick={onAction}
          className="yp-btn-accent rounded-lg px-4 py-1.5 text-sm font-semibold text-white transition disabled:opacity-40"
        >
          {actionLabel}
        </button>
      </div>
    </div>
  );
}

function PositionRow({
  token,
  amount,
  apr,
  aprTone,
  actionLabel,
  onAction,
}: {
  token: TokenInfo;
  amount: string;
  apr: number;
  aprTone?: "warn";
  actionLabel: string;
  onAction: () => void;
}) {
  return (
    <div className="flex items-center gap-2.5 py-3">
      <TokenIcon symbol={token.symbol} size={34} />
      <div className="flex-1 leading-tight">
        <p className="text-sm font-semibold text-slate-100">
          {amount} <span className="text-slate-400">{token.symbol}</span>
        </p>
        <p className={`text-[11px] ${aprTone === "warn" ? "text-amber-300/80" : "text-emerald-300/80"}`}>
          APY {formatPercent(apr)}
        </p>
      </div>
      <button
        type="button"
        onClick={onAction}
        className="rounded-lg border border-white/10 bg-white/5 px-4 py-1.5 text-sm font-medium text-slate-100 transition hover:bg-white/10"
      >
        {actionLabel}
      </button>
    </div>
  );
}

/* ------------------------------- modal ------------------------------- */

function ActionModal({
  action,
  market,
  onClose,
  onSuccess,
}: {
  action: Action;
  market: MarketData;
  onClose: () => void;
  onSuccess: () => void;
}) {
  const { address } = useAccount();
  const { token } = market;
  const [amountStr, setAmountStr] = useState("");

  const approveAction = useContractAction();
  const txAction = useContractAction();
  const allowanceQuery = useTokenAllowance(token.address, CONTRACTS.lendingPool, approveAction.state.phase);

  let amount = 0n;
  try {
    amount = amountStr ? parseUnits(amountStr, token.decimals) : 0n;
  } catch {
    amount = 0n;
  }

  const cap =
    action === "supply"
      ? market.walletBalance
      : action === "withdraw"
        ? market.supplyBalance
        : action === "repay"
          ? (market.debt < market.walletBalance ? market.debt : market.walletBalance)
          : market.available; // borrow

  const allowance = (allowanceQuery.data as bigint | undefined) ?? 0n;
  const needsApproval = (action === "supply" || action === "repay") && amount > 0n && allowance < amount;

  const done = txAction.state.phase === "success";

  // Refetch the market reads once the tx confirms (keep the modal open on success).
  useEffect(() => {
    if (done) onSuccess();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [done]);

  function handleApprove() {
    approveAction.reset();
    approveAction.writeContract({
      address: token.address,
      abi: TestTokenAbi,
      functionName: "approve",
      args: [CONTRACTS.lendingPool, amount],
    });
  }

  function handleSubmit() {
    if (!address || amount === 0n) return;
    txAction.reset();
    const common = { address: CONTRACTS.lendingPool, abi: LendingPoolAbi } as const;
    if (action === "supply") txAction.writeContract({ ...common, functionName: "supply", args: [token.address, amount] });
    else if (action === "withdraw") txAction.writeContract({ ...common, functionName: "withdraw", args: [token.address, amount] });
    else if (action === "borrow") txAction.writeContract({ ...common, functionName: "borrow", args: [token.address, amount] });
    else txAction.writeContract({ ...common, functionName: "repay", args: [token.address, amount, address] });
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/60 p-4 backdrop-blur-sm sm:items-center"
      onClick={onClose}
    >
      <div className="yp-card w-full max-w-sm p-5" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <TokenIcon symbol={token.symbol} size={28} />
            <h3 className="text-base font-semibold text-slate-100">
              {ACTION_LABEL[action]} {token.symbol}
            </h3>
          </div>
          <button type="button" onClick={onClose} aria-label="Fechar" className="rounded-md p-1 text-slate-400 hover:bg-white/10">
            ✕
          </button>
        </div>

        <div className="mt-4 rounded-xl border border-white/10 bg-slate-900/50 p-3">
          <div className="flex items-center justify-between text-xs text-slate-400">
            <span>Quantidade</span>
            <button
              type="button"
              onClick={() => setAmountStr(formatUnits(cap, token.decimals))}
              className="text-sky-300 hover:underline"
            >
              {capLabel(action)}: {formatTokenAmount(cap, token.decimals, 4)} · MÁX
            </button>
          </div>
          <input
            autoFocus
            inputMode="decimal"
            placeholder="0.0"
            value={amountStr}
            onChange={(e) => setAmountStr(e.target.value)}
            className="mt-1 w-full bg-transparent text-2xl font-medium text-slate-100 outline-none placeholder:text-slate-600"
          />
        </div>

        {amount > cap && cap > 0n && (
          <p className="mt-2 text-xs text-amber-300">Valor acima do {capLabel(action).toLowerCase()} disponível.</p>
        )}

        {needsApproval ? (
          <button
            type="button"
            onClick={handleApprove}
            disabled={approveAction.state.isBusy}
            className="yp-btn-accent mt-4 w-full rounded-xl py-2.5 font-semibold text-white transition disabled:opacity-50"
          >
            {approveAction.state.isBusy ? "Aprovando..." : `Aprovar ${token.symbol}`}
          </button>
        ) : (
          <button
            type="button"
            onClick={handleSubmit}
            disabled={txAction.state.isBusy || amount === 0n}
            className="yp-btn-primary mt-4 w-full rounded-xl py-2.5 font-semibold text-white transition disabled:opacity-50"
          >
            {txAction.state.isBusy ? `${ACTION_LABEL[action]}...` : ACTION_LABEL[action]}
          </button>
        )}

        <TxStatus state={approveAction.state} pendingLabel={`Aprovando ${token.symbol}`} successLabel="Aprovação confirmada." />
        <TxStatus
          state={txAction.state}
          pendingLabel={`Confirmando ${ACTION_LABEL[action].toLowerCase()}`}
          successLabel={`${ACTION_LABEL[action]} concluído!`}
        />

        {done && (
          <button
            type="button"
            onClick={onClose}
            className="mt-3 w-full rounded-xl border border-white/10 bg-white/5 py-2 text-sm font-medium text-slate-200 hover:bg-white/10"
          >
            Fechar
          </button>
        )}
      </div>
    </div>
  );
}

function capLabel(action: Action): string {
  if (action === "supply" || action === "repay") return "Saldo";
  if (action === "withdraw") return "Fornecido";
  return "Disponível";
}
