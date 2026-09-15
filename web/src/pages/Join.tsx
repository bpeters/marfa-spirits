import { useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { useAccount, useSignMessage, useWriteContract, usePublicClient } from "wagmi";
import { decodeEventLog } from "viem";
import { useAuth } from "../lib/auth";
import { api } from "../lib/firebase";
import { membershipAbi, membershipContract } from "../lib/contract";
import { useTiers } from "../lib/hooks";
import { errorMessage, eth, shortAddress } from "../lib/format";
import { MemberCard } from "../components/MemberCard";
import { WalletButton } from "../components/WalletButton";

export default function Join() {
  const { user, profile, signIn, refreshClaims } = useAuth();
  const { address, isConnected } = useAccount();
  const { tiers } = useTiers();
  const [params] = useSearchParams();

  const [tierId, setTierId] = useState<number>(Number(params.get("tier") ?? 0));
  const [dob, setDob] = useState("");
  const [attest, setAttest] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [minted, setMinted] = useState<{ tokenId: bigint; tierName: string; expiresAt: number } | null>(null);

  const { signMessageAsync } = useSignMessage();
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();

  const ageDone = !!profile?.ageVerified;
  const linkedWallet = profile?.wallet;
  const walletDone = !!linkedWallet;
  const walletMatches = walletDone && address && linkedWallet?.toLowerCase() === address.toLowerCase();
  const tier = tiers.find((t) => t.id === tierId);

  async function run(label: string, fn: () => Promise<void>) {
    setBusy(label);
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(null);
    }
  }

  const verifyAge = () =>
    run("age", async () => {
      await api.verifyAge({ dateOfBirth: dob, attestation: attest });
    });

  const linkWallet = () =>
    run("link", async () => {
      if (!address) throw new Error("Connect a wallet first.");
      const { data } = await api.getLinkNonce({ address });
      const signature = await signMessageAsync({ message: data.message });
      await api.linkWallet({ address, signature });
      await refreshClaims();
    });

  const mint = () =>
    run("mint", async () => {
      if (!tier) throw new Error("Pick a tier.");
      if (!walletMatches) throw new Error(`Switch to your linked wallet ${shortAddress(linkedWallet)}.`);
      const { data } = await api.requestMintVoucher({ tierId: tier.id });
      const voucher = {
        to: data.voucher.to,
        tierId: data.voucher.tierId,
        nonce: BigInt(data.voucher.nonce),
        deadline: BigInt(data.voucher.deadline),
      };
      const hash = await writeContractAsync({
        ...membershipContract,
        functionName: "mint",
        args: [voucher, data.signature],
        value: BigInt(data.price),
      });
      const receipt = await publicClient!.waitForTransactionReceipt({ hash });
      for (const log of receipt.logs) {
        try {
          const ev = decodeEventLog({ abi: membershipAbi, data: log.data, topics: log.topics });
          if (ev.eventName === "MembershipMinted") {
            setMinted({ tokenId: ev.args.tokenId, tierName: data.tierName, expiresAt: Number(ev.args.expiresAt) });
          }
        } catch {
          /* not our event */
        }
      }
      await api.refreshMembership();
      await refreshClaims();
    });

  if (minted) {
    return (
      <section className="section grid-2" style={{ borderTop: 0 }}>
        <div>
          <h1 style={{ fontSize: "var(--t-2xl)" }}>Welcome to the club.</h1>
          <p style={{ marginTop: "1rem" }}>
            Membership No. {String(minted.tokenId).padStart(4, "0")} is in your wallet. Add a shipping address on your
            member page so we know where to send bottles.
          </p>
          <Link to="/members" className="btn">
            Go to my membership
          </Link>
        </div>
        <MemberCard tokenId={minted.tokenId} tierName={minted.tierName} expiresAt={minted.expiresAt} stamp />
      </section>
    );
  }

  return (
    <section className="section grid-2" style={{ borderTop: 0 }}>
      <div>
        <h1 style={{ fontSize: "var(--t-2xl)" }}>Join</h1>
        <p style={{ marginTop: "1rem" }}>
          Four short steps. Everything you sign before the last one is free — no gas until you actually join.
        </p>
        {error && (
          <div className="note error" role="alert">
            {error}
          </div>
        )}
      </div>

      <ol className="steps">
        {/* 1. Sign in */}
        <li className={user ? "done" : ""}>
          <div className="stack">
            <h4>Sign in</h4>
            {user ? (
              <p className="muted">Signed in as {user.email}</p>
            ) : (
              <div>
                <p>We use your account to keep your address and claim history.</p>
                <button className="btn" onClick={() => run("signin", signIn)} disabled={busy !== null}>
                  Sign in with Google
                </button>
              </div>
            )}
          </div>
        </li>

        {/* 2. Age */}
        <li className={ageDone ? "done" : !user ? "locked" : ""}>
          <div className="stack">
            <h4>Confirm you&apos;re 21 or older</h4>
            {ageDone ? (
              <p className="muted">Verified.</p>
            ) : user ? (
              <div className="stack">
                <div className="field">
                  <label htmlFor="dob">Date of birth</label>
                  <input id="dob" type="date" className="input" value={dob} onChange={(e) => setDob(e.target.value)} max={new Date().toISOString().slice(0, 10)} style={{ maxWidth: "16rem" }} />
                </div>
                <label className="checkbox">
                  <input type="checkbox" checked={attest} onChange={(e) => setAttest(e.target.checked)} />
                  <span>I confirm this is my date of birth and that I am legally allowed to buy spirits where I live.</span>
                </label>
                <div>
                  <button className="btn" onClick={verifyAge} disabled={busy !== null || !dob || !attest}>
                    {busy === "age" ? "Checking…" : "Confirm"}
                  </button>
                </div>
              </div>
            ) : (
              <p className="muted">Sign in first.</p>
            )}
          </div>
        </li>

        {/* 3. Wallet */}
        <li className={walletDone ? "done" : !ageDone ? "locked" : ""}>
          <div className="stack">
            <h4>Link a wallet</h4>
            {walletDone ? (
              <p className="muted">
                Linked to {shortAddress(linkedWallet)}.{" "}
                {!walletMatches && isConnected && "Your connected wallet is different — switch to the linked one to join."}
              </p>
            ) : ageDone ? (
              <div className="stack">
                <p>Connect, then sign a message so we know the wallet is yours. This is how we verify your membership from now on.</p>
                <div className="row">
                  <WalletButton />
                  {isConnected && (
                    <button className="btn" onClick={linkWallet} disabled={busy !== null}>
                      {busy === "link" ? "Waiting for signature…" : "Sign to link"}
                    </button>
                  )}
                </div>
              </div>
            ) : (
              <p className="muted">Confirm your age first.</p>
            )}
          </div>
        </li>

        {/* 4. Join */}
        <li className={!walletDone ? "locked" : ""}>
          <div className="stack">
            <h4>Choose a tier and join</h4>
            {walletDone ? (
              <div className="stack">
                <div className="row" role="radiogroup" aria-label="Tier">
                  {tiers.map((t) => (
                    <button
                      key={t.id}
                      role="radio"
                      aria-checked={t.id === tierId}
                      className={`btn small ${t.id === tierId ? "" : "ghost"}`}
                      onClick={() => setTierId(t.id)}
                      disabled={!t.active || t.minted >= t.maxSupply}
                    >
                      {t.name} · {eth(t.mintPrice)}
                    </button>
                  ))}
                </div>
                {tier && (
                  <p className="muted">
                    {tier.maxSupply - tier.minted} spots left · renews at {eth(tier.renewalPrice)} a year
                  </p>
                )}
                {!isConnected && <WalletButton />}
                <div>
                  <button className="btn" onClick={mint} disabled={busy !== null || !tier || !walletMatches}>
                    {busy === "mint" ? "Confirm in your wallet…" : tier ? `Join for ${eth(tier.mintPrice)}` : "Pick a tier"}
                  </button>
                </div>
              </div>
            ) : (
              <p className="muted">Link a wallet first.</p>
            )}
          </div>
        </li>
      </ol>
    </section>
  );
}
