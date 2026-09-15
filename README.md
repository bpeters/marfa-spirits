# Marfa Spirit Co. — Membership

An NFT-backed membership program for [Marfa Spirit Co.](https://www.themarfaspirit.com/), the Marfa, Texas
distillery behind Chihuahuan Desert Sotol, Desert Rose, Desert Pechuga, and the Rio Grande liqueurs.
Members hold an ERC-721 pass that entitles them to bottle allocations, member-only releases, merch, and
events at The Godbold tasting room.

```
contracts/   Solidity (Foundry) — MarfaSpiritMembership.sol + tests + deploy script
functions/   Firebase Cloud Functions (TypeScript, viem) — age gate, voucher signer, ownership sync, fulfilment
web/         React + Vite + wagmi + Firebase — public site, join flow, member page, staff verify + admin
shared/      ABI and message helpers shared by web/ and functions/
```

## How it works

1. **Sign in** (Firebase Auth) and **confirm 21+**. The date of birth is checked server-side and never stored.
2. **Link a wallet** by signing a message (no gas). The backend verifies the signature, then reads the chain
   to record which memberships that wallet holds and sets `member` / `staff` claims on the account.
3. **Join**: the backend issues a short-lived EIP-712 `MintVoucher` signed by a key holding `SIGNER_ROLE`.
   The contract only mints against a valid voucher — there is deliberately no open public mint, because
   perks deliver alcohol.
4. **Claim releases**: staff publish perks on-chain (tier eligibility, window, cap). Members call `redeem()`;
   the on-chain `PerkRedeemed` event is the source of truth. `recordRedemption` reads the receipt and creates
   the fulfilment record with the member's shipping address.
5. **Renew yearly** on-chain, or **trade in** for next year's tier: `rollover(tokenId, toTierId)` burns the
   current token and mints the new tier in one transaction, charging that tier's `rolloverPrice` on top of the
   burn (burn + payment). Unexpired time carries over; expired tokens can still be traded in during a grace period.
6. **Transfers are age-gated.** The contract keeps a verified-wallet registry; every mint and transfer must land
   in a verified wallet. Minting verifies the minter. A buyer or gift recipient verifies first (`verifyWallet`
   with a backend-signed `WalletVoucher`, issued only after the 21+ check). Staff can onboard or revoke wallets.

**Launch configuration** (`script/Deploy.s.sol`): one open tier, *Founders 2026*, capped at 50 (1 per wallet).
*Sotolero* and *Godbold* are defined but closed; they accept a Founders trade-in at a discounted price.

### Verifying that someone owns a membership

Three independent ways, all backed by live chain reads:

- **Account-level**: `linkWallet` / `refreshMembership` read `tokensOfOwner` + `membershipOf` and set a
  `member` custom claim. Firestore rules and any future gated content can key off that claim.
- **Live on the site**: the Members page reads the connected wallet's tokens directly from the contract.
- **In person** (`/verify`): a member signs a five-minute "membership pass" (QR + text). Staff paste it and
  the page recovers the signer, checks `ownerOf(tokenId)` matches, and shows tier + expiry. Staff can also
  look up any wallet address or membership number.

## Contract — `contracts/src/MarfaSpiritMembership.sol`

ERC-721 + Enumerable + ERC-2981, OpenZeppelin v5.1.

| Area | Design |
| --- | --- |
| Roles | `DEFAULT_ADMIN_ROLE` (treasury, unpause, freeze), `MANAGER_ROLE` (tiers, perks, pause), `SIGNER_ROLE` (vouchers) |
| Tiers | up to 8; price, renewal price, supply cap, per-wallet cap, open/closed |
| Mint | EIP-712 voucher `(to, tierId, nonce, deadline)`; caller must be `to`; exact payment; nonce burned |
| Membership | `expiresAt` per token, `membershipDuration` (default 365 d), `renew()` payable by anyone, `extendMembership()` for comps |
| Rollover | `rollover(tokenId, toTierId)` burns + mints; per-tier `rolloverFromMask` / `rolloverPrice`; `rolloverGracePeriod` after expiry; `canRollover()` view |
| Age-gated transfers | `isVerified` registry checked in `_update`; `verifyWallet(WalletVoucher)`; `setWalletVerified()` staff override/revoke |
| Perks | tier bitmask, start/end window, optional claim cap; one claim per (perk, token); `canRedeem()` view for UIs |
| Security | Checks-Effects-Interactions throughout; `nonReentrant` on `mint` and `withdraw`; `Pausable` (blocks mint/renew/redeem/transfers); withdraw only to an admin-set `payoutAddress`; plain ETH transfers rejected; custom errors; metadata freeze |

```bash
cd contracts
forge test              # 79 tests incl. reentrancy, replay, tamper, transfer gate, rollover, fuzz
forge coverage          # ~98% line coverage on the contract
./export-abi.sh         # regenerate shared/membershipAbi.ts after changes

# Deploy (see script/Deploy.s.sol for env vars)
ADMIN_ADDRESS=... SIGNER_ADDRESS=... PAYOUT_ADDRESS=... BASE_URI=https://<host>/metadata/ \
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
```

Use a multisig for `ADMIN_ADDRESS` in production. The `SIGNER_ADDRESS` must be the address of the
`SIGNER_PRIVATE_KEY` secret held by Cloud Functions — rotate it by granting a new signer and revoking the old.

## Backend — `functions/`

| Function | Purpose |
| --- | --- |
| `getLinkNonce`, `linkWallet` | wallet ownership proof → profile + on-chain membership sync + custom claims |
| `refreshMembership` | re-sync after mint / renew / transfer |
| `verifyAge` | 21+ gate (self-attestation; swap in Persona/Veriff/etc. at the marked spot) |
| `requestMintVoucher` | pre-flights tier state, signs EIP-712 voucher with `SIGNER_PRIVATE_KEY` |
| `requestWalletVoucher` | signs a `WalletVoucher` so a verified member's wallet can *receive* tokens (secondary / gifts) |
| `recordRedemption` | verifies the `redeem` tx on-chain and creates the fulfilment record |
| `metadata` (HTTP) | `tokenURI` target — builds ERC-721 JSON live from chain state |

```bash
cd functions && npm install && npm run build
firebase functions:secrets:set SIGNER_PRIVATE_KEY
firebase deploy --only functions   # prompts for CONTRACT_ADDRESS, CHAIN_ID, RPC_URL, PUBLIC_BASE_URL
```

Firestore rules (`firestore.rules`) let members edit only their own display name / shipping address; every
trusted field (age, wallet, memberships, vouchers, redemptions) is written solely by functions via the Admin
SDK. Staff access is a custom claim granted only when the linked wallet holds `MANAGER_ROLE` on-chain.

## Web — `web/`

```bash
cd web && npm install
cp .env.example .env.local   # fill in Firebase config, chain id, contract address
npm run dev
npm run build                # output in web/dist, served by Firebase Hosting
```

Pages: `/` (tiers, how it works) · `/join` (sign in → age → link wallet → mint) · `/members` (card, renew,
claim releases, shipping address, claim history) · `/verify` (member pass + staff check) · `/admin`
(tiers, releases, pause/withdraw, fulfilment queue — gated by on-chain roles).

Styling follows the brand site: monochrome, Jost uppercase titles, Anonymous Pro body. Supports light/dark.

## Local end-to-end

```bash
anvil                                                   # terminal 1
cd contracts && ADMIN_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  SIGNER_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
  PAYOUT_ADDRESS=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC BASE_URI=http://localhost/metadata/ \
  forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
firebase emulators:start                                 # terminal 2 (set SIGNER_PRIVATE_KEY in functions/.secret.local)
cd web && VITE_USE_EMULATORS=true VITE_CHAIN_ID=31337 npm run dev   # terminal 3
```

## Before mainnet

- Independent audit of the contract.
- Replace self-attested age verification with a document-verification vendor.
- Confirm shipping compliance per state (the fulfilment queue records "hold at The Godbold" when no address).
- Enable Firebase App Check on the callables (`enforceAppCheck: true` in `functions/src/index.ts`).
- Point `BASE_URI` at the deployed `metadata` function and upload tier artwork to `web/public/art/tier-N.png`.
