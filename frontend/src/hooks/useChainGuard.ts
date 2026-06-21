import { useAccount, useSwitchChain } from "wagmi";
import { TARGET_CHAIN, TARGET_CHAIN_ID } from "../config/chains";

/**
 * Detects whether the connected wallet is on a different chain than the one
 * YieldPair is deployed to (Sepolia) and exposes a `switchToTargetChain`
 * action backed by `useSwitchChain`.
 */
export function useChainGuard() {
  const { isConnected, chainId } = useAccount();
  const { switchChain, isPending: isSwitching, error: switchError } = useSwitchChain();

  const isWrongNetwork = isConnected && chainId !== undefined && chainId !== TARGET_CHAIN_ID;

  function switchToTargetChain() {
    switchChain({ chainId: TARGET_CHAIN_ID });
  }

  return {
    isConnected,
    chainId,
    targetChain: TARGET_CHAIN,
    isWrongNetwork,
    isSwitching,
    switchError,
    switchToTargetChain,
  };
}
