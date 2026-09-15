import { createPublicClient, http, getAddress, type Address, type Chain } from "viem";
import { base, baseSepolia, mainnet, sepolia, foundry } from "viem/chains";
import { membershipAbi } from "../../shared/membershipAbi.js";
import { CHAIN_ID, CONTRACT_ADDRESS, RPC_URL } from "./config.js";

const CHAINS: Record<number, Chain> = {
  [base.id]: base,
  [baseSepolia.id]: baseSepolia,
  [mainnet.id]: mainnet,
  [sepolia.id]: sepolia,
  [foundry.id]: foundry,
};

export function chain(): Chain {
  const c = CHAINS[CHAIN_ID.value()];
  if (!c) throw new Error(`Unsupported CHAIN_ID ${CHAIN_ID.value()}`);
  return c;
}

export function contractAddress(): Address {
  return getAddress(CONTRACT_ADDRESS.value());
}

export function publicClient() {
  return createPublicClient({ chain: chain(), transport: http(RPC_URL.value() || undefined) });
}

export const contract = () => ({ address: contractAddress(), abi: membershipAbi } as const);

export interface OnChainMembership {
  tokenId: string;
  tierId: number;
  tierName: string;
  expiresAt: number; // unix seconds
  active: boolean;
}

/** Authoritative read of everything a wallet holds. */
export async function readMemberships(wallet: Address): Promise<OnChainMembership[]> {
  const client = publicClient();
  const c = contract();
  const tokenIds = await client.readContract({ ...c, functionName: "tokensOfOwner", args: [wallet] });
  if (tokenIds.length === 0) return [];

  const tierCount = Number(await client.readContract({ ...c, functionName: "tierCount" }));
  const tierNames: string[] = [];
  for (let i = 0; i < tierCount; i++) {
    const t = await client.readContract({ ...c, functionName: "getTier", args: [i] });
    tierNames.push(t.name);
  }

  const now = Math.floor(Date.now() / 1000);
  const out: OnChainMembership[] = [];
  for (const id of tokenIds) {
    const m = await client.readContract({ ...c, functionName: "membershipOf", args: [id] });
    out.push({
      tokenId: id.toString(),
      tierId: m.tierId,
      tierName: tierNames[m.tierId] ?? `Tier ${m.tierId}`,
      expiresAt: Number(m.expiresAt),
      active: Number(m.expiresAt) > now,
    });
  }
  return out;
}

export async function isManager(wallet: Address): Promise<boolean> {
  const client = publicClient();
  const c = contract();
  const role = await client.readContract({ ...c, functionName: "MANAGER_ROLE" });
  return client.readContract({ ...c, functionName: "hasRole", args: [role, wallet] });
}
