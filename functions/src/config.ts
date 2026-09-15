import { defineSecret, defineString, defineInt } from "firebase-functions/params";

/** Private key of the account holding SIGNER_ROLE on the contract. Set with
 *  `firebase functions:secrets:set SIGNER_PRIVATE_KEY`. Never ship this to the client. */
export const SIGNER_PRIVATE_KEY = defineSecret("SIGNER_PRIVATE_KEY");

export const CONTRACT_ADDRESS = defineString("CONTRACT_ADDRESS", {
  description: "Deployed MarfaSpiritMembership address",
});
export const CHAIN_ID = defineInt("CHAIN_ID", {
  description: "8453 = Base, 84532 = Base Sepolia, 1 = Ethereum, 11155111 = Sepolia, 31337 = Anvil",
  default: 84532,
});
export const RPC_URL = defineString("RPC_URL", {
  description: "JSON-RPC endpoint used by the backend (use a dedicated provider key in prod)",
});
export const PUBLIC_BASE_URL = defineString("PUBLIC_BASE_URL", {
  description: "Public site origin, used for metadata image URLs, e.g. https://members.themarfaspirit.com",
});

/** Vouchers are short-lived so a leaked one is useless after a few minutes. */
export const VOUCHER_TTL_SECONDS = 15 * 60;
/** Wallet-link nonces expire quickly too. */
export const LINK_NONCE_TTL_MS = 10 * 60 * 1000;
export const MIN_AGE = 21;
