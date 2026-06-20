import { sepolia } from "wagmi/chains";

/** Single network this dapp targets — YieldPair only deploys to Sepolia testnet. */
export const TARGET_CHAIN = sepolia;

export const TARGET_CHAIN_ID = TARGET_CHAIN.id;

export const BLOCK_EXPLORER_URL =
  TARGET_CHAIN.blockExplorers?.default.url ?? "https://sepolia.etherscan.io";

export function txUrl(hash: string): string {
  return `${BLOCK_EXPLORER_URL}/tx/${hash}`;
}

export function addressUrl(address: string): string {
  return `${BLOCK_EXPLORER_URL}/address/${address}`;
}
