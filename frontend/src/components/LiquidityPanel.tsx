import { useEffect, useMemo, useState } from "react";
import { parseUnits } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { PairAbi, RouterAbi, TestTokenAbi } from "../abis";
import { CONTRACTS, TOKENS } from "../config/contracts";
import { useContractAction } from "../hooks/useContractAction";
import { useTokenAllowance, useTokenBalance } from "../hooks/useErc20";
import { applySlippage, deadlineFromNow } from "../lib/swap";
import { formatTokenAmount } from "../lib/format";
import { TxStatus } from "./TxStatus";

const DEADLINE_MINUTES = 20;
const SLIPPAGE_BPS = 100; // 1% default for min-amounts on add/remove liquidity

type Mode = "add" | "remove";

export function LiquidityPanel() {
  const { address, isConnected } = useAccount();
  const [mode, setMode] = useState<Mode>("add");

  const [amountAStr, setAmountAStr] = useState("");
  const [amountBStr, setAmountBStr] = useState("");
  const [removeLiquidityStr, setRemoveLiquidityStr] = useState("");

  const tokenA = TOKENS.mUSDC;
  const tokenB = TOKENS.mWETH;

  const approveAAction = useContractAction();
  const approveBAction = useContractAction();
  const addAction = useContractAction();
  const removeAction = useContractAction();

  const reservesQuery = useReadContract({
    address: CONTRACTS.pair,
    abi: PairAbi,
    functionName: "getReserves",
  });

  const lpBalanceQuery = useReadContract({
    address: CONTRACTS.pair,
    abi: PairAbi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const balanceAQuery = useTokenBalance(tokenA.address, addAction.state.phase);
  const balanceBQuery = useTokenBalance(tokenB.address, addAction.state.phase);
  const allowanceAQuery = useTokenAllowance(tokenA.address, CONTRACTS.router, approveAAction.state.phase);
  const allowanceBQuery = useTokenAllowance(tokenB.address, CONTRACTS.router, approveBAction.state.phase);

  useEffect(() => {
    if (addAction.state.phase === "success" || removeAction.state.phase === "success") {
      void reservesQuery.refetch();
      void lpBalanceQuery.refetch();
      void balanceAQuery.refetch();
      void balanceBQuery.refetch();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [addAction.state.phase, removeAction.state.phase]);

  const amountA = useMemo(() => safeParseUnits(amountAStr, tokenA.decimals), [amountAStr, tokenA.decimals]);
  const amountB = useMemo(() => safeParseUnits(amountBStr, tokenB.decimals), [amountBStr, tokenB.decimals]);
  const removeLiquidity = useMemo(
    () => safeParseUnits(removeLiquidityStr, 18),
    [removeLiquidityStr],
  );

  const allowanceA = (allowanceAQuery.data as bigint | undefined) ?? 0n;
  const allowanceB = (allowanceBQuery.data as bigint | undefined) ?? 0n;
  const needsApprovalA = amountA > 0n && allowanceA < amountA;
  const needsApprovalB = amountB > 0n && allowanceB < amountB;

  function handleApprove(token: typeof tokenA, amount: bigint, action: typeof approveAAction) {
    action.reset();
    action.writeContract({
      address: token.address,
      abi: TestTokenAbi,
      functionName: "approve",
      args: [CONTRACTS.router, amount],
    });
  }

  function handleAddLiquidity() {
    if (!address || amountA === 0n || amountB === 0n) return;
    addAction.reset();
    addAction.writeContract({
      address: CONTRACTS.router,
      abi: RouterAbi,
      functionName: "addLiquidity",
      args: [
        tokenA.address,
        tokenB.address,
        amountA,
        amountB,
        applySlippage(amountA, SLIPPAGE_BPS),
        applySlippage(amountB, SLIPPAGE_BPS),
        address,
        deadlineFromNow(DEADLINE_MINUTES),
      ],
    });
  }

  function handleRemoveLiquidity() {
    if (!address || removeLiquidity === 0n) return;
    removeAction.reset();
    removeAction.writeContract({
      address: CONTRACTS.router,
      abi: RouterAbi,
      functionName: "removeLiquidity",
      args: [
        tokenA.address,
        tokenB.address,
        removeLiquidity,
        0n, // amountAMin — kept simple (0) since LP withdrawal is proportional and the
        0n, // amountBMin — pool can't be manipulated within the same tx by the user.
        address,
        deadlineFromNow(DEADLINE_MINUTES),
      ],
    });
  }

  const balanceA = (balanceAQuery.data as bigint | undefined) ?? 0n;
  const balanceB = (balanceBQuery.data as bigint | undefined) ?? 0n;
  const lpBalance = (lpBalanceQuery.data as bigint | undefined) ?? 0n;

  const [reserve0, reserve1] = (reservesQuery.data as
    | readonly [bigint, bigint, number]
    | undefined) ?? [0n, 0n, 0];

  return (
    <div className="rounded-xl border border-slate-700 bg-slate-900/60 p-4">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-slate-100">Liquidez</h2>
        <div className="flex gap-1 text-xs">
          <button
            type="button"
            onClick={() => setMode("add")}
            className={`rounded px-2 py-1 ${mode === "add" ? "bg-sky-600 text-white" : "bg-slate-800 text-slate-300"}`}
          >
            Adicionar
          </button>
          <button
            type="button"
            onClick={() => setMode("remove")}
            className={`rounded px-2 py-1 ${mode === "remove" ? "bg-sky-600 text-white" : "bg-slate-800 text-slate-300"}`}
          >
            Remover
          </button>
        </div>
      </div>

      <p className="mt-2 text-xs text-slate-400">
        Reservas do par: {formatTokenAmount(reserve0, 18, 2)} {tokenA.symbol} /{" "}
        {formatTokenAmount(reserve1, 18, 2)} {tokenB.symbol}
      </p>

      {mode === "add" ? (
        <div className="mt-4 flex flex-col gap-3">
          <AmountInput
            label={`Quantidade de ${tokenA.symbol}`}
            value={amountAStr}
            onChange={setAmountAStr}
            balance={balanceA}
            decimals={tokenA.decimals}
            symbol={tokenA.symbol}
          />
          <AmountInput
            label={`Quantidade de ${tokenB.symbol}`}
            value={amountBStr}
            onChange={setAmountBStr}
            balance={balanceB}
            decimals={tokenB.decimals}
            symbol={tokenB.symbol}
          />

          {!isConnected && <p className="text-center text-sm text-slate-400">Conecte sua carteira para continuar.</p>}

          {isConnected && needsApprovalA && (
            <ApproveButton
              label={`Aprovar ${tokenA.symbol}`}
              isBusy={approveAAction.state.isBusy}
              onClick={() => handleApprove(tokenA, amountA, approveAAction)}
            />
          )}
          {isConnected && needsApprovalB && (
            <ApproveButton
              label={`Aprovar ${tokenB.symbol}`}
              isBusy={approveBAction.state.isBusy}
              onClick={() => handleApprove(tokenB, amountB, approveBAction)}
            />
          )}
          {isConnected && !needsApprovalA && !needsApprovalB && (
            <button
              type="button"
              onClick={handleAddLiquidity}
              disabled={addAction.state.isBusy || amountA === 0n || amountB === 0n}
              className="rounded-lg bg-emerald-600 py-2.5 font-semibold text-white transition hover:bg-emerald-500 disabled:opacity-50"
            >
              {addAction.state.isBusy ? "Adicionando..." : "Adicionar liquidez"}
            </button>
          )}

          <TxStatus state={approveAAction.state} pendingLabel={`Aprovando ${tokenA.symbol}`} successLabel="Aprovação confirmada." />
          <TxStatus state={approveBAction.state} pendingLabel={`Aprovando ${tokenB.symbol}`} successLabel="Aprovação confirmada." />
          <TxStatus state={addAction.state} pendingLabel="Confirmando adição de liquidez" successLabel="Liquidez adicionada!" />
        </div>
      ) : (
        <div className="mt-4 flex flex-col gap-3">
          <AmountInput
            label="Quantidade de LP a remover"
            value={removeLiquidityStr}
            onChange={setRemoveLiquidityStr}
            balance={lpBalance}
            decimals={18}
            symbol="LP"
          />

          {!isConnected && <p className="text-center text-sm text-slate-400">Conecte sua carteira para continuar.</p>}

          {isConnected && (
            <button
              type="button"
              onClick={handleRemoveLiquidity}
              disabled={removeAction.state.isBusy || removeLiquidity === 0n || removeLiquidity > lpBalance}
              className="rounded-lg bg-red-600 py-2.5 font-semibold text-white transition hover:bg-red-500 disabled:opacity-50"
            >
              {removeAction.state.isBusy ? "Removendo..." : "Remover liquidez"}
            </button>
          )}

          <TxStatus state={removeAction.state} pendingLabel="Confirmando remoção de liquidez" successLabel="Liquidez removida!" />
        </div>
      )}
    </div>
  );
}

function safeParseUnits(value: string, decimals: number): bigint {
  if (!value) return 0n;
  try {
    return parseUnits(value, decimals);
  } catch {
    return 0n;
  }
}

function AmountInput({
  label,
  value,
  onChange,
  balance,
  decimals,
  symbol,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  balance: bigint;
  decimals: number;
  symbol: string;
}) {
  return (
    <div className="rounded-lg border border-slate-700 bg-slate-800/60 p-3">
      <div className="flex items-center justify-between text-xs text-slate-400">
        <span>{label}</span>
        <span>
          Saldo: {formatTokenAmount(balance, decimals, 4)} {symbol}
        </span>
      </div>
      <input
        inputMode="decimal"
        placeholder="0.0"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="mt-1 w-full bg-transparent text-xl font-medium text-slate-100 outline-none placeholder:text-slate-600"
      />
    </div>
  );
}

function ApproveButton({ label, isBusy, onClick }: { label: string; isBusy: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={isBusy}
      className="rounded-lg bg-sky-600 py-2.5 font-semibold text-white transition hover:bg-sky-500 disabled:opacity-50"
    >
      {isBusy ? "Aprovando..." : label}
    </button>
  );
}
