import { useEffect, useMemo, useState } from "react";
import { parseUnits } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { LendingPoolAbi, TestTokenAbi } from "../abis";
import { CONTRACTS, TOKENS, type TokenInfo } from "../config/contracts";
import { useContractAction } from "../hooks/useContractAction";
import { useTokenAllowance, useTokenBalance } from "../hooks/useErc20";
import { borrowRateToApr, formatPercent, formatTokenAmount } from "../lib/format";
import { TxStatus } from "./TxStatus";

type Action = "supply" | "withdraw" | "borrow" | "repay";

const ACTIONS: { key: Action; label: string }[] = [
  { key: "supply", label: "Suprir" },
  { key: "withdraw", label: "Retirar" },
  { key: "borrow", label: "Emprestar" },
  { key: "repay", label: "Pagar dívida" },
];

export function LendingPanel() {
  const { address, isConnected } = useAccount();
  const [action, setAction] = useState<Action>("supply");
  const [tokenSymbol, setTokenSymbol] = useState<TokenInfo["symbol"]>(TOKENS.mUSDC.symbol);
  const [amountStr, setAmountStr] = useState("");

  const token = tokenSymbol === TOKENS.mUSDC.symbol ? TOKENS.mUSDC : TOKENS.mWETH;

  const approveAction = useContractAction();
  const txAction = useContractAction();

  const amount = useMemo(() => {
    if (!amountStr) return 0n;
    try {
      return parseUnits(amountStr, token.decimals);
    } catch {
      return 0n;
    }
  }, [amountStr, token.decimals]);

  const supplyBalanceQuery = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "supplyBalanceOf",
    args: address ? [address, token.address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const debtQuery = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "debtOf",
    args: address ? [address, token.address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const utilizationQuery = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "utilization",
    args: [token.address],
  });

  const borrowRateQuery = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "borrowRatePerSecond",
    args: [token.address],
  });

  const walletBalanceQuery = useTokenBalance(token.address, txAction.state.phase);
  const allowanceQuery = useTokenAllowance(token.address, CONTRACTS.lendingPool, approveAction.state.phase);

  useEffect(() => {
    if (txAction.state.phase === "success") {
      void supplyBalanceQuery.refetch();
      void debtQuery.refetch();
      void utilizationQuery.refetch();
      void borrowRateQuery.refetch();
      void walletBalanceQuery.refetch();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [txAction.state.phase]);

  const allowance = (allowanceQuery.data as bigint | undefined) ?? 0n;
  const needsApproval = (action === "supply" || action === "repay") && amount > 0n && allowance < amount;

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

    if (action === "supply") {
      txAction.writeContract({
        address: CONTRACTS.lendingPool,
        abi: LendingPoolAbi,
        functionName: "supply",
        args: [token.address, amount],
      });
    } else if (action === "withdraw") {
      txAction.writeContract({
        address: CONTRACTS.lendingPool,
        abi: LendingPoolAbi,
        functionName: "withdraw",
        args: [token.address, amount],
      });
    } else if (action === "borrow") {
      txAction.writeContract({
        address: CONTRACTS.lendingPool,
        abi: LendingPoolAbi,
        functionName: "borrow",
        args: [token.address, amount],
      });
    } else {
      txAction.writeContract({
        address: CONTRACTS.lendingPool,
        abi: LendingPoolAbi,
        functionName: "repay",
        args: [token.address, amount, address],
      });
    }
  }

  const supplyBalance = (supplyBalanceQuery.data as bigint | undefined) ?? 0n;
  const debt = (debtQuery.data as bigint | undefined) ?? 0n;
  const utilization = (utilizationQuery.data as bigint | undefined) ?? 0n;
  const borrowRate = (borrowRateQuery.data as bigint | undefined) ?? 0n;
  const borrowApr = borrowRateToApr(borrowRate);

  const walletBalance = (walletBalanceQuery.data as bigint | undefined) ?? 0n;

  const actionLabel = ACTIONS.find((a) => a.key === action)?.label ?? "Confirmar";

  return (
    <div className="rounded-xl border border-slate-700 bg-slate-900/60 p-4">
      <h2 className="text-lg font-semibold text-slate-100">Lending</h2>

      <div className="mt-3 grid grid-cols-2 gap-2 text-xs text-slate-300 sm:grid-cols-4">
        <Stat label="Sua posição suprida" value={`${formatTokenAmount(supplyBalance, token.decimals, 4)} ${token.symbol}`} />
        <Stat label="Sua dívida" value={`${formatTokenAmount(debt, token.decimals, 4)} ${token.symbol}`} />
        <Stat label="Utilização" value={formatPercent(Number(utilization) / 1e18)} />
        <Stat label="APR de empréstimo" value={formatPercent(borrowApr)} />
      </div>

      <div className="mt-4 flex flex-wrap gap-1">
        {ACTIONS.map((a) => (
          <button
            key={a.key}
            type="button"
            onClick={() => setAction(a.key)}
            className={`rounded px-2 py-1 text-xs ${
              action === a.key ? "bg-sky-600 text-white" : "bg-slate-800 text-slate-300"
            }`}
          >
            {a.label}
          </button>
        ))}
      </div>

      <div className="mt-3 rounded-lg border border-slate-700 bg-slate-800/60 p-3">
        <div className="flex items-center justify-between text-xs text-slate-400">
          <span>Quantidade</span>
          <span>Saldo na carteira: {formatTokenAmount(walletBalance, token.decimals, 4)}</span>
        </div>
        <div className="mt-1 flex items-center gap-2">
          <input
            inputMode="decimal"
            placeholder="0.0"
            value={amountStr}
            onChange={(e) => setAmountStr(e.target.value)}
            className="w-full bg-transparent text-xl font-medium text-slate-100 outline-none placeholder:text-slate-600"
          />
          <select
            value={tokenSymbol}
            onChange={(e) => setTokenSymbol(e.target.value as TokenInfo["symbol"])}
            className="rounded-md bg-slate-700 px-2 py-1 text-sm font-semibold text-slate-100"
          >
            <option value={TOKENS.mUSDC.symbol}>{TOKENS.mUSDC.symbol}</option>
            <option value={TOKENS.mWETH.symbol}>{TOKENS.mWETH.symbol}</option>
          </select>
        </div>
      </div>

      {!isConnected && <p className="mt-3 text-center text-sm text-slate-400">Conecte sua carteira para continuar.</p>}

      {isConnected && needsApproval && (
        <button
          type="button"
          onClick={handleApprove}
          disabled={approveAction.state.isBusy}
          className="mt-3 w-full rounded-lg bg-sky-600 py-2.5 font-semibold text-white transition hover:bg-sky-500 disabled:opacity-50"
        >
          {approveAction.state.isBusy ? "Aprovando..." : `Aprovar ${token.symbol}`}
        </button>
      )}

      {isConnected && !needsApproval && (
        <button
          type="button"
          onClick={handleSubmit}
          disabled={txAction.state.isBusy || amount === 0n}
          className="mt-3 w-full rounded-lg bg-emerald-600 py-2.5 font-semibold text-white transition hover:bg-emerald-500 disabled:opacity-50"
        >
          {txAction.state.isBusy ? `${actionLabel}...` : actionLabel}
        </button>
      )}

      <TxStatus state={approveAction.state} pendingLabel={`Aprovando ${token.symbol}`} successLabel="Aprovação confirmada." />
      <TxStatus state={txAction.state} pendingLabel={`Confirmando ${actionLabel.toLowerCase()}`} successLabel={`${actionLabel} concluído!`} />
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg bg-slate-800/60 p-2">
      <p className="text-slate-500">{label}</p>
      <p className="font-semibold text-slate-100">{value}</p>
    </div>
  );
}
