import { useAccount, useChainId, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { activeChain } from "../lib/wagmi";
import { shortAddress } from "../lib/format";

export function WalletButton() {
  const { address, isConnected } = useAccount();
  const { connectors, connect, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const chainId = useChainId();
  const { switchChain } = useSwitchChain();

  if (isConnected && address) {
    if (chainId !== activeChain.id) {
      return (
        <button className="btn small" onClick={() => switchChain({ chainId: activeChain.id })}>
          Switch to {activeChain.name}
        </button>
      );
    }
    return (
      <button className="btn ghost small" onClick={() => disconnect()} title={address}>
        {shortAddress(address)}
      </button>
    );
  }

  // Prefer the browser wallet if present; otherwise the first available connector.
  const preferred = connectors.find((c) => c.id === "injected") ?? connectors[0];
  return (
    <button className="btn small" disabled={isPending || !preferred} onClick={() => connect({ connector: preferred })}>
      {isPending ? "Connecting…" : "Connect wallet"}
    </button>
  );
}
