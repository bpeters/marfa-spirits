/** Message a member signs to prove control of a wallet (shared by web + functions). */
export function buildLinkMessage(params: { address: string; uid: string; nonce: string; issuedAt: string }) {
  return [
    "Marfa Spirit Co. Membership",
    "",
    "Sign to link this wallet to your member account.",
    "This request will not trigger a blockchain transaction or cost any gas.",
    "",
    `Wallet: ${params.address}`,
    `Account: ${params.uid}`,
    `Nonce: ${params.nonce}`,
    `Issued at: ${params.issuedAt}`,
  ].join("\n");
}

/** Message a member signs to prove membership in person (staff verify page). */
export function buildProofMessage(params: { address: string; tokenId: string; issuedAt: string }) {
  return [
    "Marfa Spirit Co. proof of membership",
    "",
    `Wallet: ${params.address}`,
    `Token: ${params.tokenId}`,
    `Issued at: ${params.issuedAt}`,
  ].join("\n");
}

export function parseProofMessage(message: string): { address: string; tokenId: string; issuedAt: string } | null {
  const wallet = /^Wallet: (0x[a-fA-F0-9]{40})$/m.exec(message)?.[1];
  const tokenId = /^Token: (\d+)$/m.exec(message)?.[1];
  const issuedAt = /^Issued at: (.+)$/m.exec(message)?.[1];
  if (!message.startsWith("Marfa Spirit Co. proof of membership") || !wallet || !tokenId || !issuedAt) return null;
  return { address: wallet, tokenId, issuedAt };
}

/** Proofs are valid for a short window so a screenshot cannot be reused. */
export const PROOF_TTL_MS = 5 * 60 * 1000;
