import { useEffect, useMemo, useState } from "react";
import { parseUnits } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { PairAbi, RouterAbi } from "../abis";
import { CONTRACTS, TOKEN_LIST, type TokenInfo } from "../config/contracts";
import { useContractAction } from "../hooks/useContractAction";
import { useTokenAllowance, useTokenBalance } from "../hooks/useErc20";
import { formatTokenAmount } from "../lib/format";
import { applySlippage, deadlineFromNow, estimatePriceImpact, SLIPPAGE_PRESETS_BPS } from "../lib/swap";
import { TestTokenAbi } from "../abis";
import { TxStatus } from "./TxStatus";

const DEADLINE_MINUTES = 20;

export function SwapPanel() {
  const { address, isConnected } = useAccount();

  const [tokenInSymbol, setTokenInSymbol] = useState<TokenInfo["symbol"]>(TOKEN_LIST[0].symbol);
  const [tokenOutSymbol, setTokenOutSymbol] = useState<TokenInfo["symbol"]>(TOKEN_LIST[1].symbol);
  const [amountInStr, setAmountInStr] = useState("");
  const [slippageBps, setSlippageBps] = useState<number>(SLIPPAGE_PRESETS_BPS[1]);

  const tokenIn = TOKEN_LIST.find((t) => t.symbol === tokenInSymbol) ?? TOKEN_LIST[0];
  const tokenOut = TOKEN_LIST.find((t) => t.symbol === tokenOutSymbol) ?? TOKEN_LIST[1];

  const approveAction = useContractAction();
  const swapAction = useContractAction();

  const amountIn = useMemo(() => {
    if (!amountInStr) return 0n;
    try {
      return parseUnits(amountInStr, tokenIn.decimals);
    } catch {
      return 0n;
    }
  }, [amountInStr, tokenIn.decimals]);

  const path = useMemo(() => [tokenIn.address, tokenOut.address] as const, [tokenIn, tokenOut]);

  const quoteQuery = useReadContract({
    address: CONTRACTS.router,
    abi: RouterAbi,
    functionName: "getAmountsOut",
    args: [amountIn, [...path]],
    query: { enabled: amountIn > 0n },
  });

  const reservesQuery = useReadContract({
    address: CONTRACTS.pair,
    abi: PairAbi,
    functionName: "getReserves",
  });

  const balanceInQuery = useTokenBalance(tokenIn.address, swapAction.state.phase);
  const allowanceQuery = useTokenAllowance(tokenIn.address, CONTRACTS.router, approveAction.state.phase);

  // Refetch reads after a confirmed write — keyed on the tx phase signal, not on render.
  useEffect(() => {
    if (swapAction.state.phase === "success") {
      void quoteQuery.refetch();
      void reservesQuery.refetch();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [swapAction.state.phase]);

  const amountOut = (quoteQuery.data as readonly bigint[] | undefined)?.[1] ?? 0n;
  const amountOutMin = useMemo(() => applySlippage(amountOut, slippageBps), [amountOut, slippageBps]);

  const [reserve0, reserve1] = (reservesQuery.data as
    | readonly [bigint, bigint, number]
    | undefined) ?? [0n, 0n, 0];

  const pairToken0 = useReadContract({ address: CONTRACTS.pair, abi: PairAbi, functionName: "token0" });
  const isTokenInToken0 = (pairToken0.data as string | undefined)?.toLowerCase() === tokenIn.address.toLowerCase();
  const reserveIn = isTokenInToken0 ? reserve0 : reserve1;
  const reserveOut = isTokenInToken0 ? reserve1 : reserve0;

  const priceImpact = useMemo(
    () => estimatePriceImpact(amountIn, amountOut, reserveIn, reserveOut),
    [amountIn, amountOut, reserveIn, reserveOut],
  );

  const allowance = (allowanceQuery.data as bigint | undefined) ?? 0n;
  const needsApproval = amountIn > 0n && allowance < amountIn;

  function handleFlipTokens() {
    setTokenInSymbol(tokenOutSymbol);
    setTokenOutSymbol(tokenInSymbol);
    setAmountInStr("");
  }

  function handleApprove() {
    approveAction.reset();
    approveAction.writeContract({
      address: tokenIn.address,
      abi: TestTokenAbi,
      functionName: "approve",
      args: [CONTRACTS.router, amountIn],
    });
  }

  function handleSwap() {
    if (!address || amountIn === 0n) return;
    swapAction.reset();
    swapAction.writeContract({
      address: CONTRACTS.router,
      abi: RouterAbi,
      functionName: "swapExactTokensForTokens",
      args: [amountIn, amountOutMin, [...path], address, deadlineFromNow(DEADLINE_MINUTES)],
    });
  }

  const balanceIn = (balanceInQuery.data as bigint | undefined) ?? 0n;
  const insufficientBalance = amountIn > 0n && amountIn > balanceIn;

  return (
    <div className="yp-card p-4 sm:p-5">
      <h2 className="text-lg font-semibold text-slate-100">Swap</h2>

      <div className="mt-4 flex flex-col gap-3">
        <TokenAmountField
          label="Você paga"
          amount={amountInStr}
          onAmountChange={setAmountInStr}
          tokenSymbol={tokenInSymbol}
          onTokenChange={(symbol) => {
            setTokenInSymbol(symbol);
            if (symbol === tokenOutSymbol) setTokenOutSymbol(tokenIn.symbol);
          }}
          balance={balanceInQuery.data as bigint | undefined}
          decimals={tokenIn.decimals}
        />

        <div className="flex justify-center">
          <button
            type="button"
            onClick={handleFlipTokens}
            aria-label="Inverter tokens"
            className="rounded-full border border-slate-600 bg-slate-800 p-1.5 text-slate-300 transition hover:bg-slate-700"
          >
            ↓↑
          </button>
        </div>

        <TokenAmountField
          label="Você recebe (estimado)"
          amount={amountOut > 0n ? formatTokenAmount(amountOut, tokenOut.decimals, 6) : ""}
          tokenSymbol={tokenOutSymbol}
          onTokenChange={(symbol) => {
            setTokenOutSymbol(symbol);
            if (symbol === tokenInSymbol) setTokenInSymbol(tokenOut.symbol);
          }}
          readOnly
          decimals={tokenOut.decimals}
        />

        <div className="flex items-center justify-between text-xs text-slate-400">
          <span>Slippage</span>
          <div className="flex gap-1">
            {SLIPPAGE_PRESETS_BPS.map((bps) => (
              <button
                key={bps}
                type="button"
                onClick={() => setSlippageBps(bps)}
                className={`rounded px-2 py-1 ${
                  slippageBps === bps ? "bg-sky-600 text-white" : "bg-slate-800 hover:bg-slate-700"
                }`}
              >
                {(bps / 100).toFixed(2)}%
              </button>
            ))}
          </div>
        </div>

        {amountIn > 0n && (
          <div className="rounded-lg bg-slate-800/60 p-3 text-xs text-slate-400">
            <Row label="Mínimo recebido" value={`${formatTokenAmount(amountOutMin, tokenOut.decimals, 6)} ${tokenOut.symbol}`} />
            <Row
              label="Impacto de preço estimado"
              value={`${(priceImpact * 100).toFixed(2)}%`}
              warn={priceImpact > 0.03}
            />
            <Row label="Deadline" value={`${DEADLINE_MINUTES} min`} />
          </div>
        )}

        {!isConnected && (
          <p className="text-center text-sm text-slate-400">Conecte sua carteira para trocar tokens.</p>
        )}

        {isConnected && needsApproval && (
          <button
            type="button"
            onClick={handleApprove}
            disabled={approveAction.state.isBusy || amountIn === 0n}
            className="yp-btn-accent rounded-lg py-2.5 font-semibold text-white transition disabled:opacity-50"
          >
            {approveAction.state.isBusy ? "Aprovando..." : `Aprovar ${tokenIn.symbol}`}
          </button>
        )}

        {isConnected && !needsApproval && (
          <button
            type="button"
            onClick={handleSwap}
            disabled={swapAction.state.isBusy || amountIn === 0n || insufficientBalance}
            className="yp-btn-primary rounded-lg py-2.5 font-semibold text-white transition disabled:opacity-50"
          >
            {insufficientBalance ? "Saldo insuficiente" : swapAction.state.isBusy ? "Trocando..." : "Trocar"}
          </button>
        )}

        <TxStatus state={approveAction.state} pendingLabel={`Aprovando ${tokenIn.symbol}`} successLabel="Aprovação confirmada." />
        <TxStatus state={swapAction.state} pendingLabel="Confirmando swap" successLabel="Swap concluído!" />
      </div>
    </div>
  );
}

function Row({ label, value, warn }: { label: string; value: string; warn?: boolean }) {
  return (
    <div className="flex justify-between py-0.5">
      <span>{label}</span>
      <span className={warn ? "text-amber-400" : ""}>{value}</span>
    </div>
  );
}

interface TokenAmountFieldProps {
  label: string;
  amount: string;
  onAmountChange?: (value: string) => void;
  tokenSymbol: string;
  onTokenChange: (symbol: TokenInfo["symbol"]) => void;
  readOnly?: boolean;
  balance?: bigint;
  decimals: number;
}

function TokenAmountField({
  label,
  amount,
  onAmountChange,
  tokenSymbol,
  onTokenChange,
  readOnly,
  balance,
  decimals,
}: TokenAmountFieldProps) {
  return (
    <div className="rounded-lg border border-slate-700 bg-slate-800/60 p-3">
      <div className="flex items-center justify-between text-xs text-slate-400">
        <span>{label}</span>
        {balance !== undefined && <span>Saldo: {formatTokenAmount(balance, decimals, 4)}</span>}
      </div>
      <div className="mt-1 flex items-center gap-2">
        <input
          inputMode="decimal"
          placeholder="0.0"
          value={amount}
          readOnly={readOnly}
          onChange={(e) => onAmountChange?.(e.target.value)}
          className="w-full bg-transparent text-xl font-medium text-slate-100 outline-none placeholder:text-slate-600"
        />
        <select
          value={tokenSymbol}
          onChange={(e) => onTokenChange(e.target.value as TokenInfo["symbol"])}
          className="rounded-md bg-slate-700 px-2 py-1 text-sm font-semibold text-slate-100"
        >
          {TOKEN_LIST.map((t) => (
            <option key={t.symbol} value={t.symbol}>
              {t.symbol}
            </option>
          ))}
        </select>
      </div>
    </div>
  );
}
