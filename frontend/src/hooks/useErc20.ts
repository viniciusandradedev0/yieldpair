import { useEffect } from "react";
import { useAccount, useReadContract } from "wagmi";
import { TestTokenAbi } from "../abis";

/** Reads an ERC20 balance for the connected account, refetching when `refetchSignal` changes. */
export function useTokenBalance(token: `0x${string}` | undefined, refetchSignal?: unknown) {
  const { address } = useAccount();

  const query = useReadContract({
    address: token,
    abi: TestTokenAbi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(token && address) },
  });

  useEffect(() => {
    if (refetchSignal !== undefined) {
      void query.refetch();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refetchSignal]);

  return query;
}

/** Reads the allowance the connected account has granted to `spender` for `token`. */
export function useTokenAllowance(
  token: `0x${string}` | undefined,
  spender: `0x${string}` | undefined,
  refetchSignal?: unknown,
) {
  const { address } = useAccount();

  const query = useReadContract({
    address: token,
    abi: TestTokenAbi,
    functionName: "allowance",
    args: address && spender ? [address, spender] : undefined,
    query: { enabled: Boolean(token && address && spender) },
  });

  useEffect(() => {
    if (refetchSignal !== undefined) {
      void query.refetch();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refetchSignal]);

  return query;
}
