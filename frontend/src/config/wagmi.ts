import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { http } from "wagmi";
import { TARGET_CHAIN } from "./chains";

// WalletConnect Cloud project id. Required by RainbowKit/WalletConnect at
// runtime to open the QR modal, but an empty string must NOT break the build
// or local dev — it only disables the WalletConnect connector's remote
// features until a real id is supplied.
//
// The real value is injected as an environment variable on Vercel in Passo
// 4.4; locally, copy `.env.example` to `.env.local` and fill it in.
const WALLETCONNECT_PROJECT_ID =
  (import.meta.env.VITE_WALLETCONNECT_PROJECT_ID as string | undefined)?.trim() || "";

if (!WALLETCONNECT_PROJECT_ID && import.meta.env.DEV) {
  console.warn(
    "[yieldpair] VITE_WALLETCONNECT_PROJECT_ID is not set — WalletConnect-based " +
      "wallets (mobile QR, etc.) won't work until you set it in frontend/.env.local. " +
      "Get a free project id at https://cloud.reown.com.",
  );
}

// Optional custom RPC for Sepolia (Alchemy/Infura/etc). Falls back to wagmi's
// default public transport when unset, which is fine for local dev but can
// rate-limit under heavier use.
const SEPOLIA_RPC_URL = (import.meta.env.VITE_SEPOLIA_RPC_URL as string | undefined)?.trim();

export const wagmiConfig = getDefaultConfig({
  appName: "YieldPair",
  projectId: WALLETCONNECT_PROJECT_ID || "00000000000000000000000000000000",
  chains: [TARGET_CHAIN],
  transports: {
    [TARGET_CHAIN.id]: SEPOLIA_RPC_URL ? http(SEPOLIA_RPC_URL) : http(),
  },
  ssr: false,
});
