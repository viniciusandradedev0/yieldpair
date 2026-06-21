import { useAccount, useReadContract } from "wagmi";
import { LendingPoolAbi, PairAbi } from "../abis";
import { CONTRACTS, TOKENS } from "../config/contracts";
import { estimateSupplyApr, formatPercent, formatTokenAmount, interpretHealthFactor } from "../lib/format";

const STATUS_STYLES: Record<string, string> = {
  healthy: "text-emerald-400 border-emerald-500/40 bg-emerald-500/10",
  warning: "text-amber-400 border-amber-500/40 bg-amber-500/10",
  danger: "text-red-400 border-red-500/40 bg-red-500/10",
};

const STATUS_DESCRIPTION: Record<string, string> = {
  healthy: "Posição saudável.",
  warning: "Atenção: posição perto do limite de liquidação.",
  danger: "Risco de liquidação — considere repagar dívida ou adicionar colateral.",
};

export function Dashboard() {
  const { address, isConnected } = useAccount();

  const healthFactorQuery = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "healthFactor",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const suppliedReservesQuery = useReadContract({
    address: CONTRACTS.pair,
    abi: PairAbi,
    functionName: "suppliedReserves",
  });

  const utilizationUsdcQuery = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "utilization",
    args: [TOKENS.mUSDC.address],
  });
  const borrowRateUsdcQuery = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "borrowRatePerSecond",
    args: [TOKENS.mUSDC.address],
  });

  const utilizationWethQuery = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "utilization",
    args: [TOKENS.mWETH.address],
  });
  const borrowRateWethQuery = useReadContract({
    address: CONTRACTS.lendingPool,
    abi: LendingPoolAbi,
    functionName: "borrowRatePerSecond",
    args: [TOKENS.mWETH.address],
  });

  const healthFactorView = isConnected && healthFactorQuery.data !== undefined
    ? interpretHealthFactor(healthFactorQuery.data as bigint)
    : null;

  const [supplied0, supplied1] = (suppliedReservesQuery.data as
    | readonly [bigint, bigint]
    | undefined) ?? [0n, 0n];

  const supplyAprUsdc = estimateSupplyApr(
    (utilizationUsdcQuery.data as bigint | undefined) ?? 0n,
    (borrowRateUsdcQuery.data as bigint | undefined) ?? 0n,
  );
  const supplyAprWeth = estimateSupplyApr(
    (utilizationWethQuery.data as bigint | undefined) ?? 0n,
    (borrowRateWethQuery.data as bigint | undefined) ?? 0n,
  );

  return (
    <div className="rounded-xl border border-slate-700 bg-slate-900/60 p-4">
      <h2 className="text-lg font-semibold text-slate-100">Painel</h2>

      <div className="mt-4">
        <p className="text-xs uppercase tracking-wide text-slate-500">Health Factor</p>
        {!isConnected && <p className="mt-1 text-sm text-slate-400">Conecte sua carteira para ver sua posição.</p>}
        {isConnected && healthFactorView && (
          <div
            className={`mt-2 rounded-lg border p-3 ${STATUS_STYLES[healthFactorView.status]}`}
          >
            <p className="text-2xl font-bold">{healthFactorView.label}</p>
            <p className="mt-1 text-xs opacity-90">{STATUS_DESCRIPTION[healthFactorView.status]}</p>
          </div>
        )}
      </div>

      <div className="mt-4">
        <p className="text-xs uppercase tracking-wide text-slate-500">
          Liquidez ociosa suprida ao lending (yield para LPs)
        </p>
        <div className="mt-2 grid grid-cols-2 gap-2 text-sm">
          <StatCard
            label={TOKENS.mUSDC.symbol}
            value={`${formatTokenAmount(supplied0, TOKENS.mUSDC.decimals, 2)}`}
            sub={`APR estimada para suppliers: ${formatPercent(supplyAprUsdc)}`}
          />
          <StatCard
            label={TOKENS.mWETH.symbol}
            value={`${formatTokenAmount(supplied1, TOKENS.mWETH.decimals, 4)}`}
            sub={`APR estimada para suppliers: ${formatPercent(supplyAprWeth)}`}
          />
        </div>
        <p className="mt-2 text-xs text-slate-500">
          Yield estimado = utilização × taxa de empréstimo (anualizada). A reserva ociosa do par
          (acima do buffer configurado) é depositada automaticamente no LendingPool e rende juros
          além das taxas de swap.
        </p>
      </div>
    </div>
  );
}

function StatCard({ label, value, sub }: { label: string; value: string; sub: string }) {
  return (
    <div className="rounded-lg bg-slate-800/60 p-3">
      <p className="text-slate-500">{label}</p>
      <p className="text-lg font-semibold text-slate-100">{value}</p>
      <p className="mt-1 text-[11px] text-slate-500">{sub}</p>
    </div>
  );
}
