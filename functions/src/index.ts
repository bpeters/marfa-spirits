import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { onRequest } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import { getAddress, isAddress, parseEventLogs, verifyMessage, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { randomBytes } from "node:crypto";

import { membershipAbi } from "../../shared/membershipAbi.js";
import { buildLinkMessage } from "../../shared/linkMessage.js";
import { chain, contract, contractAddress, isManager, publicClient, readMemberships } from "./chain.js";
import {
  CHAIN_ID,
  CONTRACT_ADDRESS,
  LINK_NONCE_TTL_MS,
  MIN_AGE,
  PUBLIC_BASE_URL,
  RPC_URL,
  SIGNER_PRIVATE_KEY,
  VOUCHER_TTL_SECONDS,
} from "./config.js";

initializeApp();
const db = getFirestore();
const auth = getAuth();

const chainParams = [CHAIN_ID, CONTRACT_ADDRESS, RPC_URL];
const callOpts = { region: "us-central1", enforceAppCheck: false } as const;

function requireUid(uid: string | undefined): string {
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return uid;
}

// ---------------------------------------------------------------------------
// Wallet linking (proves the member controls the wallet) + ownership sync
// ---------------------------------------------------------------------------

export const getLinkNonce = onCall({ ...callOpts }, async (req) => {
  const uid = requireUid(req.auth?.uid);
  const address = String(req.data?.address ?? "");
  if (!isAddress(address)) throw new HttpsError("invalid-argument", "Invalid wallet address.");

  const nonce = randomBytes(16).toString("hex");
  const issuedAt = new Date().toISOString();
  await db.collection("linkNonces").doc(uid).set({ nonce, issuedAt, address: getAddress(address) });

  return { message: buildLinkMessage({ address: getAddress(address), uid, nonce, issuedAt }) };
});

/**
 * Verifies the signed link message, binds the wallet to the account, then reads the chain to
 * record which memberships the wallet holds. Sets `member`/`staff` custom claims from chain state.
 */
export const linkWallet = onCall({ ...callOpts }, async (req) => {
  const uid = requireUid(req.auth?.uid);
  const address = String(req.data?.address ?? "");
  const signature = String(req.data?.signature ?? "") as Hex;
  if (!isAddress(address)) throw new HttpsError("invalid-argument", "Invalid wallet address.");
  const wallet = getAddress(address);

  const nonceSnap = await db.collection("linkNonces").doc(uid).get();
  const n = nonceSnap.data();
  if (!n || n.address !== wallet) throw new HttpsError("failed-precondition", "Request a link message first.");
  if (Date.now() - Date.parse(n.issuedAt) > LINK_NONCE_TTL_MS) {
    throw new HttpsError("deadline-exceeded", "Link request expired. Try again.");
  }

  const message = buildLinkMessage({ address: wallet, uid, nonce: n.nonce, issuedAt: n.issuedAt });
  const ok = await verifyMessage({ address: wallet, message, signature });
  if (!ok) throw new HttpsError("permission-denied", "Signature does not match this wallet.");

  // One wallet ↔ one account.
  const clash = await db.collection("users").where("wallet", "==", wallet).limit(1).get();
  if (!clash.empty && clash.docs[0].id !== uid) {
    throw new HttpsError("already-exists", "This wallet is linked to another account.");
  }

  await db.collection("linkNonces").doc(uid).delete();
  await db.collection("users").doc(uid).set(
    { wallet, walletLinkedAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp() },
    { merge: true },
  );

  return syncMembership(uid, wallet);
});

/** Re-checks on-chain ownership for the linked wallet. Call after mint, renew, or transfer. */
export const refreshMembership = onCall({ ...callOpts }, async (req) => {
  const uid = requireUid(req.auth?.uid);
  const user = (await db.collection("users").doc(uid).get()).data();
  if (!user?.wallet) throw new HttpsError("failed-precondition", "Link a wallet first.");
  return syncMembership(uid, user.wallet as Address);
});

async function syncMembership(uid: string, wallet: Address) {
  const [memberships, staff] = await Promise.all([readMemberships(wallet), isManager(wallet)]);
  const member = memberships.some((m) => m.active);

  await db.collection("users").doc(uid).set(
    { memberships, membershipSyncedAt: FieldValue.serverTimestamp(), isStaff: staff },
    { merge: true },
  );
  await auth.setCustomUserClaims(uid, { member, staff, wallet });
  logger.info("membership synced", { uid, wallet, count: memberships.length, member, staff });
  return { wallet, memberships, member, staff };
}

// ---------------------------------------------------------------------------
// Age verification
// ---------------------------------------------------------------------------

/**
 * Self-attested date-of-birth check. This is the minimum acceptable gate for a spirits brand and
 * is where a document-verification vendor (Persona, Veriff, Jumio, etc.) should be plugged in:
 * have the vendor webhook call into this same write path once its check passes.
 *
 * The DOB itself is not stored — only the verified flag, method, and timestamp.
 */
export const verifyAge = onCall({ ...callOpts }, async (req) => {
  const uid = requireUid(req.auth?.uid);
  const dob = String(req.data?.dateOfBirth ?? "");
  const attested = req.data?.attestation === true;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dob)) throw new HttpsError("invalid-argument", "Date of birth must be YYYY-MM-DD.");
  if (!attested) throw new HttpsError("invalid-argument", "You must confirm the information is accurate.");

  const birth = new Date(dob + "T00:00:00Z");
  if (Number.isNaN(birth.getTime())) throw new HttpsError("invalid-argument", "Invalid date.");
  const now = new Date();
  let age = now.getUTCFullYear() - birth.getUTCFullYear();
  const beforeBirthday =
    now.getUTCMonth() < birth.getUTCMonth() ||
    (now.getUTCMonth() === birth.getUTCMonth() && now.getUTCDate() < birth.getUTCDate());
  if (beforeBirthday) age -= 1;

  if (age < MIN_AGE) {
    await db.collection("ageVerifications").doc(uid).set({
      status: "rejected",
      method: "self-attestation",
      checkedAt: FieldValue.serverTimestamp(),
    });
    throw new HttpsError("permission-denied", `You must be ${MIN_AGE} or older to join.`);
  }

  await db.collection("ageVerifications").doc(uid).set({
    status: "verified",
    method: "self-attestation",
    verifiedAt: FieldValue.serverTimestamp(),
  });
  await db.collection("users").doc(uid).set(
    { ageVerified: true, ageVerifiedAt: FieldValue.serverTimestamp() },
    { merge: true },
  );
  return { ageVerified: true };
});

// ---------------------------------------------------------------------------
// Mint vouchers (EIP-712, signed by SIGNER_ROLE key)
// ---------------------------------------------------------------------------

export const requestMintVoucher = onCall(
  { ...callOpts, secrets: [SIGNER_PRIVATE_KEY] },
  async (req) => {
    const uid = requireUid(req.auth?.uid);
    const tierId = Number(req.data?.tierId);
    if (!Number.isInteger(tierId) || tierId < 0 || tierId > 7) {
      throw new HttpsError("invalid-argument", "Invalid tier.");
    }

    const user = (await db.collection("users").doc(uid).get()).data();
    if (!user?.ageVerified) throw new HttpsError("failed-precondition", "Verify your age first.");
    if (!user?.wallet) throw new HttpsError("failed-precondition", "Link a wallet first.");
    const to = user.wallet as Address;

    // Pre-flight the same checks the contract enforces so members get a clear error before paying gas.
    const client = publicClient();
    const c = contract();
    const tier = await client.readContract({ ...c, functionName: "getTier", args: [tierId] });
    if (!tier.active) throw new HttpsError("failed-precondition", "This tier is not open.");
    if (tier.minted >= tier.maxSupply) throw new HttpsError("resource-exhausted", "This tier is sold out.");
    const mintedByWallet = await client.readContract({
      ...c,
      functionName: "mintedPerWallet",
      args: [to, tierId],
    });
    if (mintedByWallet >= BigInt(tier.maxPerWallet)) {
      throw new HttpsError("resource-exhausted", "This wallet has reached the limit for this tier.");
    }

    const signer = privateKeyToAccount(SIGNER_PRIVATE_KEY.value() as Hex);
    const nonce = BigInt("0x" + randomBytes(32).toString("hex"));
    const deadline = BigInt(Math.floor(Date.now() / 1000) + VOUCHER_TTL_SECONDS);

    const signature = await signer.signTypedData({
      domain: {
        name: "Marfa Spirit Co. Membership",
        version: "1",
        chainId: chain().id,
        verifyingContract: contractAddress(),
      },
      types: {
        MintVoucher: [
          { name: "to", type: "address" },
          { name: "tierId", type: "uint8" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      primaryType: "MintVoucher",
      message: { to, tierId, nonce, deadline },
    });

    await db.collection("vouchers").doc(nonce.toString()).set({
      uid,
      wallet: to,
      kind: "mint",
      tierId,
      deadline: Number(deadline),
      issuedAt: FieldValue.serverTimestamp(),
      signer: signer.address,
    });

    return {
      voucher: { to, tierId, nonce: nonce.toString(), deadline: deadline.toString() },
      signature,
      price: tier.mintPrice.toString(),
      tierName: tier.name,
    };
  },
);

/**
 * Wallet-verification voucher. Lets an age-verified member's wallet RECEIVE membership tokens —
 * needed to buy one on a marketplace or accept a gift, since the contract rejects transfers to
 * unverified wallets. Joining (minting) verifies the wallet automatically.
 */
export const requestWalletVoucher = onCall(
  { ...callOpts, secrets: [SIGNER_PRIVATE_KEY] },
  async (req) => {
    const uid = requireUid(req.auth?.uid);
    const user = (await db.collection("users").doc(uid).get()).data();
    if (!user?.ageVerified) throw new HttpsError("failed-precondition", "Verify your age first.");
    if (!user?.wallet) throw new HttpsError("failed-precondition", "Link a wallet first.");
    const wallet = user.wallet as Address;

    const signer = privateKeyToAccount(SIGNER_PRIVATE_KEY.value() as Hex);
    const nonce = BigInt("0x" + randomBytes(32).toString("hex"));
    const deadline = BigInt(Math.floor(Date.now() / 1000) + VOUCHER_TTL_SECONDS);

    const signature = await signer.signTypedData({
      domain: {
        name: "Marfa Spirit Co. Membership",
        version: "1",
        chainId: chain().id,
        verifyingContract: contractAddress(),
      },
      types: {
        WalletVoucher: [
          { name: "wallet", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      primaryType: "WalletVoucher",
      message: { wallet, nonce, deadline },
    });

    await db.collection("vouchers").doc(nonce.toString()).set({
      uid,
      wallet,
      kind: "wallet",
      deadline: Number(deadline),
      issuedAt: FieldValue.serverTimestamp(),
      signer: signer.address,
    });

    return { voucher: { wallet, nonce: nonce.toString(), deadline: deadline.toString() }, signature };
  },
);

// ---------------------------------------------------------------------------
// Redemption records (fulfilment queue)
// ---------------------------------------------------------------------------

/**
 * The client calls this with the tx hash after `redeem()` confirms. We read the receipt from the
 * chain, so the client cannot fabricate a redemption — the on-chain event is the source of truth.
 */
export const recordRedemption = onCall({ ...callOpts }, async (req) => {
  const uid = requireUid(req.auth?.uid);
  const txHash = String(req.data?.txHash ?? "") as Hex;
  if (!/^0x[a-fA-F0-9]{64}$/.test(txHash)) throw new HttpsError("invalid-argument", "Invalid transaction hash.");

  const user = (await db.collection("users").doc(uid).get()).data();
  if (!user?.wallet) throw new HttpsError("failed-precondition", "Link a wallet first.");
  const wallet = getAddress(user.wallet);

  const client = publicClient();
  const receipt = await client.waitForTransactionReceipt({ hash: txHash, confirmations: 1, timeout: 60_000 });
  if (receipt.status !== "success") throw new HttpsError("failed-precondition", "Transaction reverted.");

  const logs = parseEventLogs({
    abi: membershipAbi,
    eventName: "PerkRedeemed",
    logs: receipt.logs.filter((l) => getAddress(l.address) === contractAddress()),
  });
  if (logs.length === 0) throw new HttpsError("not-found", "No redemption found in that transaction.");

  const created: string[] = [];
  for (const log of logs) {
    const { perkId, tokenId, member } = log.args;
    if (getAddress(member) !== wallet) continue; // someone else's redemption in the same tx

    const id = `${perkId}_${tokenId}`;
    const ref = db.collection("redemptions").doc(id);
    await db.runTransaction(async (tx) => {
      const existing = await tx.get(ref);
      if (existing.exists) return;
      tx.set(ref, {
        uid,
        wallet,
        perkId: perkId.toString(),
        tokenId: tokenId.toString(),
        txHash,
        blockNumber: Number(receipt.blockNumber),
        chainId: chain().id,
        status: "pending",
        shipping: user.shipping ?? null,
        contactEmail: user.email ?? req.auth?.token.email ?? null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      created.push(id);
    });
  }
  return { recorded: created };
});

// ---------------------------------------------------------------------------
// Token metadata (ERC-721 tokenURI target) — built live from chain state
// ---------------------------------------------------------------------------

export const metadata = onRequest(
  { region: "us-central1", cors: true },
  async (req, res) => {
    const match = /\/(\d+)\/?$/.exec(req.path);
    if (!match) {
      res.status(404).json({ error: "Expected /metadata/:tokenId" });
      return;
    }
    const tokenId = BigInt(match[1]);
    const client = publicClient();
    const c = contract();
    try {
      const m = await client.readContract({ ...c, functionName: "membershipOf", args: [tokenId] });
      const tier = await client.readContract({ ...c, functionName: "getTier", args: [m.tierId] });
      const expires = new Date(Number(m.expiresAt) * 1000);
      const active = Number(m.expiresAt) > Date.now() / 1000;
      const base = PUBLIC_BASE_URL.value() || `${req.protocol}://${req.get("host")}`;

      res.set("Cache-Control", "public, max-age=300");
      res.json({
        name: `Marfa Spirit Co. Membership #${tokenId} — ${tier.name}`,
        description:
          "A membership to Marfa Spirit Co., distillers of Chihuahuan Desert Sotol in Marfa, Texas. " +
          "Holders receive bottle allocations, member-only releases, and access at The Godbold.",
        image: `${base}/art/tier-${m.tierId}.png`,
        external_url: `${base}/members`,
        attributes: [
          { trait_type: "Tier", value: tier.name },
          { trait_type: "Status", value: active ? "Active" : "Expired" },
          { display_type: "date", trait_type: "Expires", value: Math.floor(expires.getTime() / 1000) },
        ],
      });
    } catch (err) {
      logger.warn("metadata lookup failed", { tokenId: tokenId.toString(), err: String(err) });
      res.status(404).json({ error: "Token not found" });
    }
  },
);

// Keep params referenced so the CLI prompts for them on deploy.
void chainParams;
