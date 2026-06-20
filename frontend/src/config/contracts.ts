import { sepoliaDeployments } from "./deployments.sepolia";

/**
 * Contract addresses for the active deployment. Today YieldPair only targets
 * Sepolia, so this re-exports the generated deployment file with the
 * `0x${string}` typing wagmi/viem expect for addresses.
 */
export const CONTRACTS = {
  factory: sepoliaDeployments.factory as `0x${string}`,
  router: sepoliaDeployments.router as `0x${string}`,
  pair: sepoliaDeployments.pair as `0x${string}`,
  lendingPool: sepoliaDeployments.lendingPool as `0x${string}`,
  oracle: sepoliaDeployments.oracle as `0x${string}`,
  mUSDC: sepoliaDeployments.mUSDC as `0x${string}`,
  mWETH: sepoliaDeployments.mWETH as `0x${string}`,
} as const;

export const DEPLOYMENT_CHAIN_ID = sepoliaDeployments.chainId;

export interface TokenInfo {
  address: `0x${string}`;
  symbol: string;
  name: string;
  decimals: number;
}

export const TOKENS: Record<"mUSDC" | "mWETH", TokenInfo> = {
  mUSDC: {
    address: CONTRACTS.mUSDC,
    symbol: "mUSDC",
    name: "Mock USD Coin",
    decimals: 18,
  },
  mWETH: {
    address: CONTRACTS.mWETH,
    symbol: "mWETH",
    name: "Mock Wrapped Ether",
    decimals: 18,
  },
};

export const TOKEN_LIST = Object.values(TOKENS);

export function tokenByAddress(address: string): TokenInfo | undefined {
  const lower = address.toLowerCase();
  return TOKEN_LIST.find((t) => t.address.toLowerCase() === lower);
}
