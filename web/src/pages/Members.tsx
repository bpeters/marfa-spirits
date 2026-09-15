import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useAccount, usePublicClient, useReadContract, useReadContracts, useWriteContract } from "wagmi";
import type { ContractFunctionParameters } from "viem";
import { collection, doc, onSnapshot, orderBy, query, serverTimestamp, setDoc, where } from "firebase/firestore";
import { useAuth } from "../lib/auth";
import { api, db, type PerkDoc, type RedemptionDoc, type Shipping } from "../lib/firebase";
import { membershipContract, REDEEM_REASONS, ROLLOVER_REASONS } from "../lib/contract";
import { usePerks, useTiers, useWalletTokens } from "../lib/hooks";
import { dateFromUnix, daysUntil, errorMessage, eth, shortAddress, tokenNo } from "../lib/format";
import { MemberCard } from "../components/MemberCard";
import { WalletButton } from "../components/WalletButton";

const STATUS_LABEL: Record<RedemptionDoc["status"], string> = {
  pending: "Received",
  ready: "Ready for pickup",
  shipped: "Shipped",
  fulfilled: "Delivered",
  cancelled: "Cancelled",
};

export default function Members() {
  const { user, profile, signIn, refreshClaims } = useAuth();
  const { address, isConnected } = useAccount();
  const { tiers } = useTiers();
  const { perks } = usePerks();
  const { tokens, isLoading, refetch } = useWalletTokens(address);
  const publicClient = usePublicClient();
  const { writeContractAsync } = useWriteContract();
  const verified = useReadContract({ ...membershipContract, functionName: "isVerified", args: [address ?? "0x0000000000000000000000000000000000000000"], query: { enabled: !!address } });

  const [picked, setPicked] = useState<bigint | null>(null);
  const selected = picked ?? tokens[0]?.tokenId ?? null;
  const setSelected = setPicked;
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [perkDocs, setPerkDocs] = useState<Record<string, PerkDoc>>({});
  const [claims, setClaims] = useState<(RedemptionDoc & { id: string })[]>([]);

  useEffect(() => onSnapshot(collection(db, "perks"), (s) => {
    const m: Record<string, PerkDoc> = {};
    s.forEach((d) => (m[d.id] = d.data() as PerkDoc));
    setPerkDocs(m);
  }), []);

  useEffect(() => {
    if (!user) return;
    const q = query(collection(db, "redemptions"), where("uid", "==", user.uid), orderBy("createdAt", "desc"));
    return onSnapshot(q, (s) => setClaims(s.docs.map((d) => ({ id: d.id, ...(d.data() as RedemptionDoc) }))));
  }, [user]);

  const token = tokens.find((t) => t.tokenId === selected);
  const tier = token ? tiers.find((t) => t.id === token.tierId) : undefined;

  // Eligibility for every perk against the selected token, straight from the contract.
  const eligibility = useReadContracts({
    contracts: perks.map((p) => ({ ...membershipContract, functionName: "canRedeem", args: [selected ?? 0n, BigInt(p.id)] })) as ContractFunctionParameters[],
    query: { enabled: selected !== null && perks.length > 0 },
  });
  const eligible = useMemo(
    () => (eligibility.data ?? []).map((r) => (r.status === "success" ? (r.result as unknown as readonly [boolean, string]) : ([false, ""] as const))),
    [eligibility.data],
  );

  // Next-year tiers this token can be traded into (burn old, mint new).
  const rolloverTargets = useMemo(
    () => (token ? tiers.filter((t) => t.rolloverFromMask & (1 << token.tierId)) : []),
    [tiers, token],
  );
  const rolloverChecks = useReadContracts({
    contracts: rolloverTargets.map((t) => ({ ...membershipContract, functionName: "canRollover", args: [selected ?? 0n, t.id] })) as ContractFunctionParameters[],
    query: { enabled: selected !== null && rolloverTargets.length > 0 },
  });
  const rolloverOk = useMemo(
    () => (rolloverChecks.data ?? []).map((r) => (r.status === "success" ? (r.result as unknown as readonly [boolean, string]) : ([false, ""] as const))),
    [rolloverChecks.data],
  );

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

  const renew = () =>
    run("renew", async () => {
      if (!token || !tier) return;
      const hash = await writeContractAsync({ ...membershipContract, functionName: "renew", args: [token.tokenId], value: tier.renewalPrice });
      await publicClient!.waitForTransactionReceipt({ hash });
      await refetch();
      if (user) {
        await api.refreshMembership();
        await refreshClaims();
      }
    });

  const rollover = (toTierId: number) =>
    run(`rollover-${toTierId}`, async () => {
      if (!token) return;
      const target = tiers.find((t) => t.id === toTierId)!;
      const sure = confirm(
        `Trade in membership No. ${tokenNo(token.tokenId)} for ${target.name}?\n\nYour current token is burned and a new ${target.name} token is minted to this wallet. This can't be undone.`,
      );
      if (!sure) return;
      const hash = await writeContractAsync({ ...membershipContract, functionName: "rollover", args: [token.tokenId, toTierId], value: target.rolloverPrice });
      await publicClient!.waitForTransactionReceipt({ hash });
      setPicked(null);
      await refetch();
      if (user) {
        await api.refreshMembership();
        await refreshClaims();
      }
    });

  const verifyWallet = () =>
    run("verify", async () => {
      if (!user) throw new Error("Sign in first.");
      if (!profile?.ageVerified) throw new Error("Confirm your age on the Join page first.");
      if (!profile?.wallet || profile.wallet.toLowerCase() !== address?.toLowerCase()) {
        throw new Error("Link this wallet on the Join page first.");
      }
      const { data } = await api.requestWalletVoucher();
      const hash = await writeContractAsync({
        ...membershipContract,
        functionName: "verifyWallet",
        args: [{ wallet: data.voucher.wallet, nonce: BigInt(data.voucher.nonce), deadline: BigInt(data.voucher.deadline) }, data.signature],
      });
      await publicClient!.waitForTransactionReceipt({ hash });
      await verified.refetch();
    });

  const redeem = (perkId: number) =>
    run(`redeem-${perkId}`, async () => {
      if (!token) return;
      if (!user) throw new Error("Sign in so we can record where to send it.");
      if (!profile?.shipping?.line1) throw new Error("Add a shipping address below first.");
      const hash = await writeContractAsync({ ...membershipContract, functionName: "redeem", args: [token.tokenId, BigInt(perkId)] });
      await publicClient!.waitForTransactionReceipt({ hash });
      await api.recordRedemption({ txHash: hash });
      await eligibility.refetch();
    });

  if (!isConnected) {
    return (
      <section className="section" style={{ borderTop: 0 }}>
        <h1 style={{ fontSize: "var(--t-2xl)" }}>Members</h1>
        <p style={{ marginTop: "1rem" }}>Connect the wallet that holds your membership. We read it straight from the chain.</p>
        <div className="row">
          <WalletButton />
          <Link to="/join" className="btn ghost">Not a member yet</Link>
        </div>
      </section>
    );
  }

  return (
    <>
      <section className="section grid-2" style={{ borderTop: 0 }}>
        <div className="stack">
          <h1 style={{ fontSize: "var(--t-2xl)" }}>Your membership</h1>
          {isLoading && <p className="muted">Reading {shortAddress(address)}…</p>}
          {!isLoading && tokens.length === 0 && (
            <div>
              <p>No membership found in {shortAddress(address)}.</p>
              <Link to="/join" className="btn">Join the club</Link>
            </div>
          )}
          {tokens.length > 1 && (
            <div className="row" role="radiogroup" aria-label="Membership">
              {tokens.map((t) => (
                <button key={String(t.tokenId)} role="radio" aria-checked={t.tokenId === selected} className={`btn small ${t.tokenId === selected ? "" : "ghost"}`} onClick={() => setSelected(t.tokenId)}>
                  No. {tokenNo(t.tokenId)}
                </button>
              ))}
            </div>
          )}
          {token && tier && (
            <dl className="notes">
              <div><dt>Tier</dt><dd>{tier.name}</dd></div>
              <div>
                <dt>{token.active ? "Good through" : "Expired"}</dt>
                <dd>
                  {dateFromUnix(token.expiresAt)}
                  {token.active && <span className="muted"> · {daysUntil(token.expiresAt)} days left</span>}
                </dd>
              </div>
              <div>
                <dt>Renew</dt>
                <dd>
                  <button className="btn small" onClick={renew} disabled={busy !== null}>
                    {busy === "renew" ? "Confirm in wallet…" : `Add a year for ${eth(tier.renewalPrice)}`}
                  </button>
                </dd>
              </div>
              <div>
                <dt>Prove it in person</dt>
                <dd><Link to="/verify">Show a membership pass at The Godbold</Link></dd>
              </div>
            </dl>
          )}
          {error && <div className="note error" role="alert">{error}</div>}
        </div>
        {token && tier && <MemberCard tokenId={token.tokenId} tierName={tier.name} expiresAt={token.expiresAt} />}
      </section>

      {verified.data === false && (
        <section className="section grid-2">
          <div>
            <h2>Receiving a membership</h2>
            <p style={{ marginTop: "1rem" }}>
              Memberships can only be sent to wallets we&apos;ve confirmed belong to someone 21 or older. Buying one
              second-hand, or being gifted one? Verify {shortAddress(address)} first, or the transfer will fail.
            </p>
          </div>
          <div className="stack">
            {!user && <button className="btn" onClick={signIn}>Sign in to verify</button>}
            {user && !profile?.ageVerified && <Link to="/join" className="btn">Confirm your age</Link>}
            {user && profile?.ageVerified && profile.wallet?.toLowerCase() !== address?.toLowerCase() && (
              <Link to="/join" className="btn">Link this wallet</Link>
            )}
            {user && profile?.ageVerified && profile.wallet?.toLowerCase() === address?.toLowerCase() && (
              <div>
                <button className="btn" onClick={verifyWallet} disabled={busy !== null}>
                  {busy === "verify" ? "Confirm in wallet…" : "Verify this wallet"}
                </button>
              </div>
            )}
            <small>Joining from this site verifies your wallet automatically — this step is only for receiving a token someone else holds.</small>
          </div>
        </section>
      )}

      {token && tier && rolloverTargets.length > 0 && (
        <section className="section grid-2">
          <div>
            <h2>Next year</h2>
            <p style={{ marginTop: "1rem" }}>
              Trade in your {tier.name} membership for next year&apos;s. Your current token is burned and the new one is
              minted in its place — any time you have left carries over, and your claim history stays on record.
            </p>
          </div>
          <div>
            {rolloverTargets.map((t, i) => {
              const [ok, reason] = rolloverOk[i] ?? [false, ""];
              return (
                <div className="perk" key={t.id}>
                  <div>
                    <h4>{t.name}</h4>
                    <p>
                      {t.rolloverPrice === 0n ? "Your current membership is the payment." : `${eth(t.rolloverPrice)} with your current membership.`}
                      {" "}{t.maxSupply - t.minted} of {t.maxSupply} left.
                    </p>
                  </div>
                  <div>
                    {ok ? (
                      <button className="btn" onClick={() => rollover(t.id)} disabled={busy !== null}>
                        {busy === `rollover-${t.id}` ? "Confirm in wallet…" : t.rolloverPrice === 0n ? "Trade in" : `Trade in for ${eth(t.rolloverPrice)}`}
                      </button>
                    ) : (
                      <span className="tag">{ROLLOVER_REASONS[reason] ?? "Unavailable"}</span>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </section>
      )}

      {token && (
        <section className="section">
          <div className="section-head">
            <h2>Releases &amp; perks</h2>
            {!user && <button className="btn ghost small" onClick={signIn}>Sign in to claim</button>}
          </div>
          {perks.length === 0 && <p className="muted">Nothing open right now. Members hear first when a release drops.</p>}
          {perks.map((p, i) => {
            const meta = perkDocs[String(p.id)];
            const [ok, reason] = eligible[i] ?? [false, ""];
            const claimedByMe = reason === "ALREADY_REDEEMED";
            return (
              <div className="perk" key={p.id}>
                <div>
                  <h4>{meta?.title ?? `Perk #${p.id}`}</h4>
                  <p>{meta?.description ?? p.uri}</p>
                  <small>
                    {p.endsAt ? `Through ${dateFromUnix(p.endsAt)}` : "Open-ended"}
                    {p.maxClaims > 0 && ` · ${p.maxClaims - p.claimed} of ${p.maxClaims} left`}
                  </small>
                </div>
                <div>
                  {ok ? (
                    <button className="btn" onClick={() => redeem(p.id)} disabled={busy !== null}>
                      {busy === `redeem-${p.id}` ? "Confirm in wallet…" : "Claim"}
                    </button>
                  ) : (
                    <span className={`tag${claimedByMe ? " filled" : ""}`}>{REDEEM_REASONS[reason] ?? "Unavailable"}</span>
                  )}
                </div>
              </div>
            );
          })}
        </section>
      )}

      {user && (
        <section className="section grid-2">
          <ShippingForm key={JSON.stringify(profile?.shipping ?? null)} uid={user.uid} initial={profile?.shipping} />
          <div>
            <h3 style={{ marginBottom: "1rem" }}>Your claims</h3>
            {claims.length === 0 && <p className="muted">Nothing claimed yet.</p>}
            {claims.length > 0 && (
              <div className="table-wrap">
                <table>
                  <thead><tr><th>Release</th><th>Membership</th><th>Status</th><th>Tracking</th></tr></thead>
                  <tbody>
                    {claims.map((c) => (
                      <tr key={c.id}>
                        <td>{perkDocs[c.perkId]?.title ?? `Perk #${c.perkId}`}</td>
                        <td>No. {tokenNo(c.tokenId)}</td>
                        <td>{STATUS_LABEL[c.status]}</td>
                        <td>{c.trackingNumber ?? "—"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </section>
      )}
    </>
  );
}

function ShippingForm({ uid, initial }: { uid: string; initial?: Shipping }) {
  const [form, setForm] = useState<Shipping>({ name: "", line1: "", line2: "", city: "", state: "TX", zip: "", country: "US", ...initial });
  const [saved, setSaved] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const set = (k: keyof Shipping) => (e: React.ChangeEvent<HTMLInputElement>) => {
    setSaved(false);
    setForm({ ...form, [k]: e.target.value });
  };

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    try {
      await setDoc(doc(db, "users", uid), { shipping: form, updatedAt: serverTimestamp() }, { merge: true });
      setSaved(true);
    } catch (ex) {
      setErr(errorMessage(ex));
    }
  }

  return (
    <form className="stack" onSubmit={save}>
      <h3>Where to send bottles</h3>
      <p className="muted">Used for every claim you make. We can only ship spirits to states that allow it; otherwise we hold bottles at The Godbold.</p>
      <div className="field"><label htmlFor="s-name">Full name</label><input id="s-name" className="input" required value={form.name} onChange={set("name")} /></div>
      <div className="field"><label htmlFor="s-l1">Street address</label><input id="s-l1" className="input" required value={form.line1} onChange={set("line1")} /></div>
      <div className="field"><label htmlFor="s-l2">Apt, suite (optional)</label><input id="s-l2" className="input" value={form.line2 ?? ""} onChange={set("line2")} /></div>
      <div className="grid-3">
        <div className="field"><label htmlFor="s-city">City</label><input id="s-city" className="input" required value={form.city} onChange={set("city")} /></div>
        <div className="field"><label htmlFor="s-state">State</label><input id="s-state" className="input" required value={form.state} onChange={set("state")} /></div>
        <div className="field"><label htmlFor="s-zip">ZIP</label><input id="s-zip" className="input" required value={form.zip} onChange={set("zip")} /></div>
      </div>
      <div className="row">
        <button className="btn" type="submit">Save address</button>
        {saved && <small>Saved.</small>}
        {err && <small role="alert">{err}</small>}
      </div>
    </form>
  );
}
