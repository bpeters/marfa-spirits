import { useEffect, useState } from "react";
import { useAccount, usePublicClient, useReadContract, useWriteContract } from "wagmi";
import { parseEther } from "viem";
import { collection, doc, onSnapshot, orderBy, query, serverTimestamp, setDoc, updateDoc } from "firebase/firestore";
import { useAuth } from "../lib/auth";
import { db, type PerkDoc, type RedemptionDoc } from "../lib/firebase";
import { DEFAULT_ADMIN_ROLE, MANAGER_ROLE, membershipContract } from "../lib/contract";
import { usePerks, useTiers } from "../lib/hooks";
import { dateFromUnix, errorMessage, eth, shortAddress, tokenNo } from "../lib/format";
import { WalletButton } from "../components/WalletButton";

const STATUSES: RedemptionDoc["status"][] = ["pending", "ready", "shipped", "fulfilled", "cancelled"];

/**
 * Staff console. Two layers of access:
 *  - Anything on-chain (tiers, perks, pause, withdraw) needs the connected wallet to hold
 *    MANAGER_ROLE / DEFAULT_ADMIN_ROLE — the contract enforces it, the UI just hides what will fail.
 *  - Anything in Firestore (perk copy, fulfilment status) needs the `staff` custom claim, which the
 *    backend sets only after confirming the linked wallet holds MANAGER_ROLE.
 */
export default function Admin() {
  const { address, isConnected } = useAccount();
  const { claims } = useAuth();
  const isManager = useReadContract({ ...membershipContract, functionName: "hasRole", args: [MANAGER_ROLE, address ?? "0x0000000000000000000000000000000000000000"], query: { enabled: !!address } });
  const isAdmin = useReadContract({ ...membershipContract, functionName: "hasRole", args: [DEFAULT_ADMIN_ROLE, address ?? "0x0000000000000000000000000000000000000000"], query: { enabled: !!address } });

  if (!isConnected) {
    return (
      <section className="section" style={{ borderTop: 0 }}>
        <h1 style={{ fontSize: "var(--t-2xl)" }}>Staff</h1>
        <p style={{ marginTop: "1rem" }}>Connect a wallet that holds the manager role.</p>
        <WalletButton />
      </section>
    );
  }
  if (isManager.isLoading) return <section className="section" style={{ borderTop: 0 }}><p className="muted">Checking roles…</p></section>;
  if (!isManager.data) {
    return (
      <section className="section" style={{ borderTop: 0 }}>
        <h1 style={{ fontSize: "var(--t-2xl)" }}>Staff</h1>
        <p style={{ marginTop: "1rem" }}>{shortAddress(address)} doesn't hold the manager role on the contract.</p>
      </section>
    );
  }

  return (
    <>
      <section className="section" style={{ borderTop: 0 }}>
        <div className="section-head">
          <h1 style={{ fontSize: "var(--t-2xl)" }}>Staff</h1>
          <small>
            {shortAddress(address)} · manager{isAdmin.data ? " + admin" : ""}
            {!claims.staff && " · sign in and link this wallet on Join to edit fulfilment"}
          </small>
        </div>
        <ContractControls isAdmin={!!isAdmin.data} />
      </section>
      <section className="section grid-2">
        <TierManager />
        <PerkManager canEditCopy={!!claims.staff} />
      </section>
      <section className="section">
        <FulfilmentQueue canEdit={!!claims.staff} />
      </section>
    </>
  );
}

function useTx() {
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  async function send(label: string, fn: () => Promise<`0x${string}`>, after?: () => Promise<unknown>) {
    setBusy(label);
    setMsg(null);
    try {
      const hash = await fn();
      await publicClient!.waitForTransactionReceipt({ hash });
      await after?.();
      setMsg({ ok: true, text: `${label}: confirmed` });
    } catch (e) {
      setMsg({ ok: false, text: errorMessage(e) });
    } finally {
      setBusy(null);
    }
  }
  return { busy, msg, send, write: writeContractAsync };
}

function ContractControls({ isAdmin }: { isAdmin: boolean }) {
  const paused = useReadContract({ ...membershipContract, functionName: "paused" });
  const payout = useReadContract({ ...membershipContract, functionName: "payoutAddress" });
  const publicClient = usePublicClient();
  const [balance, setBalance] = useState<bigint | null>(null);
  const { busy, msg, send, write } = useTx();

  useEffect(() => {
    publicClient?.getBalance({ address: membershipContract.address }).then(setBalance);
  }, [publicClient, msg]);

  return (
    <div className="stack">
      <dl className="notes">
        <div><dt>Contract</dt><dd><code>{membershipContract.address}</code></dd></div>
        <div><dt>Status</dt><dd>{paused.data ? <span className="tag filled">Paused</span> : <span className="tag">Live</span>}</dd></div>
        <div><dt>Balance</dt><dd>{balance !== null ? eth(balance) : "…"}</dd></div>
        <div><dt>Pays out to</dt><dd><code>{payout.data}</code></dd></div>
      </dl>
      <div className="row">
        {paused.data ? (
          <button className="btn" disabled={!isAdmin || busy !== null} onClick={() => send("Unpause", () => write({ ...membershipContract, functionName: "unpause" }), () => paused.refetch())}>
            Unpause (admin)
          </button>
        ) : (
          <button className="btn ghost" disabled={busy !== null} onClick={() => confirm("Pause all minting, renewals, claims and transfers?") && send("Pause", () => write({ ...membershipContract, functionName: "pause" }), () => paused.refetch())}>
            Emergency pause
          </button>
        )}
        <button className="btn" disabled={!isAdmin || busy !== null || !balance} onClick={() => send("Withdraw", () => write({ ...membershipContract, functionName: "withdraw" }))}>
          Withdraw to payout (admin)
        </button>
      </div>
      <WalletRegistry />
      {msg && <div className={`note${msg.ok ? "" : " error"}`}>{msg.text}</div>}
    </div>
  );
}

/** Staff override of the on-chain verified-wallet registry (in-person onboarding, revocations). */
function WalletRegistry() {
  const { busy, msg, send, write } = useTx();
  const publicClient = usePublicClient();
  const [addr, setAddr] = useState("");
  const [status, setStatus] = useState<boolean | null>(null);

  const valid = /^0x[a-fA-F0-9]{40}$/.test(addr.trim());
  async function lookup() {
    setStatus(null);
    const v = await publicClient!.readContract({ ...membershipContract, functionName: "isVerified", args: [addr.trim() as `0x${string}`] });
    setStatus(v);
  }
  const set = (verified: boolean) =>
    send(`${verified ? "Verify" : "Revoke"} ${addr.slice(0, 8)}…`, () => write({ ...membershipContract, functionName: "setWalletVerified", args: [addr.trim() as `0x${string}`, verified] }), lookup);

  return (
    <div className="stack" style={{ marginTop: "1rem" }}>
      <h4>Age-verified wallets</h4>
      <p className="muted">Only verified wallets can receive a membership. Members verify themselves on the site; use this for in-person onboarding or to revoke a wallet.</p>
      <div className="row">
        <input className="input" style={{ maxWidth: "28rem" }} placeholder="0x…" value={addr} onChange={(e) => { setAddr(e.target.value); setStatus(null); }} aria-label="Wallet address" />
        <button type="button" className="btn ghost small" disabled={!valid} onClick={lookup}>Look up</button>
        {status !== null && <span className={`tag${status ? " filled" : ""}`}>{status ? "Verified" : "Not verified"}</span>}
        {status === false && <button type="button" className="btn small" disabled={busy !== null} onClick={() => set(true)}>Verify (staff)</button>}
        {status === true && <button type="button" className="btn ghost small" disabled={busy !== null} onClick={() => confirm("Revoke? The wallet keeps its tokens but can no longer receive or trade in.") && set(false)}>Revoke</button>}
      </div>
      {msg && <div className={`note${msg.ok ? "" : " error"}`}>{msg.text}</div>}
    </div>
  );
}

function TierManager() {
  const { tiers, refetch } = useTiers();
  const { busy, msg, send, write } = useTx();
  const [f, setF] = useState({ name: "", mintPrice: "0.05", renewalPrice: "0.03", maxSupply: "100", maxPerWallet: "2" });

  const create = (e: React.FormEvent) => {
    e.preventDefault();
    send("Create tier", () => write({ ...membershipContract, functionName: "createTier", args: [f.name, parseEther(f.mintPrice), parseEther(f.renewalPrice), Number(f.maxSupply), Number(f.maxPerWallet), true] }), () => refetch());
  };
  const toggle = (id: number) => {
    const t = tiers.find((x) => x.id === id)!;
    send(`${t.active ? "Close" : "Open"} ${t.name}`, () => write({ ...membershipContract, functionName: "updateTier", args: [id, t.mintPrice, t.renewalPrice, t.maxSupply, t.maxPerWallet, !t.active] }), () => refetch());
  };

  // Trade-in settings: which tiers can be burned to enter this one, and at what price.
  const [ro, setRo] = useState<{ tierId: number; mask: number; price: string } | null>(null);
  const saveRollover = (e: React.FormEvent) => {
    e.preventDefault();
    if (!ro) return;
    const t = tiers.find((x) => x.id === ro.tierId)!;
    send(`Trade-in settings for ${t.name}`, () => write({ ...membershipContract, functionName: "setTierRollover", args: [ro.tierId, ro.mask, parseEther(ro.price || "0")] }), async () => { await refetch(); setRo(null); });
  };

  return (
    <div className="stack">
      <h3>Tiers</h3>
      <div className="table-wrap">
        <table>
          <thead><tr><th>#</th><th>Name</th><th>Join</th><th>Renew</th><th>Minted</th><th>Per wallet</th><th>Trade-in from</th><th></th></tr></thead>
          <tbody>
            {tiers.map((t) => (
              <tr key={t.id}>
                <td>{t.id}</td><td>{t.name}{!t.active && <><br /><small>closed</small></>}</td><td>{eth(t.mintPrice)}</td><td>{eth(t.renewalPrice)}</td><td>{t.minted}/{t.maxSupply}</td><td>{t.maxPerWallet}</td>
                <td>
                  {t.rolloverFromMask ? `${tiers.filter((x) => t.rolloverFromMask & (1 << x.id)).map((x) => x.name).join(", ")} · ${t.rolloverPrice === 0n ? "free" : eth(t.rolloverPrice)}` : <span className="muted">—</span>}
                  <br /><button type="button" className="btn ghost small" style={{ marginTop: "0.25rem" }} onClick={() => setRo({ tierId: t.id, mask: t.rolloverFromMask, price: t.rolloverPrice === 0n ? "0" : (Number(t.rolloverPrice) / 1e18).toString() })}>Edit</button>
                </td>
                <td><button className="btn ghost small" disabled={busy !== null} onClick={() => toggle(t.id)}>{t.active ? "Close" : "Open"}</button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {ro && (
        <form className="stack note" onSubmit={saveRollover}>
          <h4>Trade-in into {tiers.find((x) => x.id === ro.tierId)?.name}</h4>
          <div className="field">
            <label>Accept a burned token from</label>
            <div className="row">
              {tiers.filter((x) => x.id !== ro.tierId).map((x) => (
                <label key={x.id} className="checkbox">
                  <input type="checkbox" checked={!!(ro.mask & (1 << x.id))} onChange={(e) => setRo({ ...ro, mask: e.target.checked ? ro.mask | (1 << x.id) : ro.mask & ~(1 << x.id) })} />
                  <span>{x.name}</span>
                </label>
              ))}
            </div>
          </div>
          <div className="field" style={{ maxWidth: "12rem" }}><label>Trade-in price (ETH, 0 = burn is the payment)</label><input className="input" value={ro.price} onChange={(e) => setRo({ ...ro, price: e.target.value })} /></div>
          <div className="row">
            <button className="btn" type="submit" disabled={busy !== null}>Save trade-in settings</button>
            <button className="btn ghost" type="button" onClick={() => setRo(null)}>Cancel</button>
          </div>
        </form>
      )}
      <form className="stack" onSubmit={create}>
        <h4>New tier</h4>
        <div className="field"><label>Name</label><input className="input" required value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></div>
        <div className="grid-3">
          <div className="field"><label>Join price (ETH)</label><input className="input" required value={f.mintPrice} onChange={(e) => setF({ ...f, mintPrice: e.target.value })} /></div>
          <div className="field"><label>Renewal (ETH)</label><input className="input" required value={f.renewalPrice} onChange={(e) => setF({ ...f, renewalPrice: e.target.value })} /></div>
          <div className="field"><label>Max supply</label><input className="input" type="number" min={1} required value={f.maxSupply} onChange={(e) => setF({ ...f, maxSupply: e.target.value })} /></div>
        </div>
        <div className="field" style={{ maxWidth: "10rem" }}><label>Max per wallet</label><input className="input" type="number" min={1} required value={f.maxPerWallet} onChange={(e) => setF({ ...f, maxPerWallet: e.target.value })} /></div>
        <div><button className="btn" type="submit" disabled={busy !== null}>Create tier</button></div>
      </form>
      {msg && <div className={`note${msg.ok ? "" : " error"}`}>{msg.text}</div>}
    </div>
  );
}

function PerkManager({ canEditCopy }: { canEditCopy: boolean }) {
  const { tiers } = useTiers();
  const { perks, refetch } = usePerks();
  const { busy, msg, send, write } = useTx();
  const [docs, setDocs] = useState<Record<string, PerkDoc>>({});
  const [f, setF] = useState({ title: "", description: "", kind: "bottle" as PerkDoc["kind"], tierMask: 0, startsAt: "", endsAt: "", maxClaims: "0" });

  useEffect(() => onSnapshot(collection(db, "perks"), (s) => {
    const m: Record<string, PerkDoc> = {};
    s.forEach((d) => (m[d.id] = d.data() as PerkDoc));
    setDocs(m);
  }), []);

  const toUnix = (v: string) => (v ? BigInt(Math.floor(new Date(v).getTime() / 1000)) : 0n);

  const create = (e: React.FormEvent) => {
    e.preventDefault();
    const nextId = perks.length; // perkIds are sequential; the tx reverts if not, and we re-read.
    send(
      "Create perk",
      () => write({ ...membershipContract, functionName: "createPerk", args: [f.tierMask, toUnix(f.startsAt), toUnix(f.endsAt), Number(f.maxClaims), `${location.origin}/perks/${nextId}`] }),
      async () => {
        await refetch();
        if (canEditCopy) {
          await setDoc(doc(db, "perks", String(nextId)), { title: f.title, description: f.description, kind: f.kind, updatedAt: serverTimestamp() });
        }
      },
    );
  };
  const toggle = (id: number) => {
    const p = perks.find((x) => x.id === id)!;
    send(`${p.active ? "Deactivate" : "Activate"} perk #${id}`, () => write({ ...membershipContract, functionName: "updatePerk", args: [BigInt(id), p.tierMask, BigInt(p.startsAt), BigInt(p.endsAt), p.maxClaims, !p.active, p.uri] }), () => refetch());
  };

  return (
    <div className="stack">
      <h3>Releases &amp; perks</h3>
      <div className="table-wrap">
        <table>
          <thead><tr><th>#</th><th>Title</th><th>Tiers</th><th>Window</th><th>Claimed</th><th></th></tr></thead>
          <tbody>
            {perks.map((p) => (
              <tr key={p.id}>
                <td>{p.id}</td>
                <td>{docs[String(p.id)]?.title ?? <span className="muted">(no copy yet)</span>}</td>
                <td>{tiers.filter((t) => p.tierMask & (1 << t.id)).map((t) => t.name).join(", ")}</td>
                <td>{dateFromUnix(p.startsAt)}{p.endsAt ? ` – ${dateFromUnix(p.endsAt)}` : " →"}</td>
                <td>{p.claimed}{p.maxClaims ? `/${p.maxClaims}` : ""}</td>
                <td><button className="btn ghost small" disabled={busy !== null} onClick={() => toggle(p.id)}>{p.active ? "Deactivate" : "Activate"}</button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <form className="stack" onSubmit={create}>
        <h4>New release</h4>
        <div className="field"><label>Title</label><input className="input" required value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} placeholder="Spring 2027 allocation — Desert Rose" /></div>
        <div className="field"><label>Description</label><input className="input" value={f.description} onChange={(e) => setF({ ...f, description: e.target.value })} placeholder="One 750ml bottle, shipped or held at The Godbold." /></div>
        <div className="grid-3">
          <div className="field">
            <label>Kind</label>
            <select className="input" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value as PerkDoc["kind"] })}>
              <option value="bottle">Bottle</option><option value="merch">Merch</option><option value="event">Event</option><option value="other">Other</option>
            </select>
          </div>
          <div className="field"><label>Opens</label><input className="input" type="datetime-local" value={f.startsAt} onChange={(e) => setF({ ...f, startsAt: e.target.value })} /></div>
          <div className="field"><label>Closes (optional)</label><input className="input" type="datetime-local" value={f.endsAt} onChange={(e) => setF({ ...f, endsAt: e.target.value })} /></div>
        </div>
        <div className="field">
          <label>Eligible tiers</label>
          <div className="row">
            {tiers.map((t) => (
              <label key={t.id} className="checkbox">
                <input type="checkbox" checked={!!(f.tierMask & (1 << t.id))} onChange={(e) => setF({ ...f, tierMask: e.target.checked ? f.tierMask | (1 << t.id) : f.tierMask & ~(1 << t.id) })} />
                <span>{t.name}</span>
              </label>
            ))}
          </div>
        </div>
        <div className="field" style={{ maxWidth: "12rem" }}><label>Max claims (0 = unlimited)</label><input className="input" type="number" min={0} value={f.maxClaims} onChange={(e) => setF({ ...f, maxClaims: e.target.value })} /></div>
        <div><button className="btn" type="submit" disabled={busy !== null || f.tierMask === 0}>Publish release</button></div>
        {!canEditCopy && <small>Sign in with a linked staff wallet to also save the title and description.</small>}
      </form>
      {msg && <div className={`note${msg.ok ? "" : " error"}`}>{msg.text}</div>}
    </div>
  );
}

function FulfilmentQueue({ canEdit }: { canEdit: boolean }) {
  const [rows, setRows] = useState<(RedemptionDoc & { id: string })[]>([]);
  const [docs, setDocs] = useState<Record<string, PerkDoc>>({});
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!canEdit) return;
    const q = query(collection(db, "redemptions"), orderBy("createdAt", "desc"));
    return onSnapshot(q, (s) => setRows(s.docs.map((d) => ({ id: d.id, ...(d.data() as RedemptionDoc) }))), (e) => setErr(e.message));
  }, [canEdit]);
  useEffect(() => onSnapshot(collection(db, "perks"), (s) => {
    const m: Record<string, PerkDoc> = {};
    s.forEach((d) => (m[d.id] = d.data() as PerkDoc));
    setDocs(m);
  }), []);

  async function update(id: string, patch: Partial<RedemptionDoc>) {
    setErr(null);
    try {
      await updateDoc(doc(db, "redemptions", id), { ...patch, updatedAt: serverTimestamp() });
    } catch (e) {
      setErr(errorMessage(e));
    }
  }

  if (!canEdit) return <p className="muted">Fulfilment queue needs the staff claim: sign in and link this wallet on the Join page.</p>;

  return (
    <div className="stack">
      <div className="section-head"><h2>Fulfilment</h2><small>{rows.filter((r) => r.status === "pending").length} waiting</small></div>
      {err && <div className="note error">{err}</div>}
      <div className="table-wrap">
        <table>
          <thead><tr><th>When</th><th>Release</th><th>Member</th><th>Ship to</th><th>Status</th><th>Tracking</th><th>Tx</th></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td>{r.createdAt ? dateFromUnix(r.createdAt.seconds) : "…"}</td>
                <td>{docs[r.perkId]?.title ?? `#${r.perkId}`}<br /><small>No. {tokenNo(r.tokenId)}</small></td>
                <td>{r.contactEmail ?? shortAddress(r.wallet)}<br /><small>{shortAddress(r.wallet)}</small></td>
                <td>{r.shipping ? `${r.shipping.name}, ${r.shipping.line1}${r.shipping.line2 ? ` ${r.shipping.line2}` : ""}, ${r.shipping.city} ${r.shipping.state} ${r.shipping.zip}` : <span className="muted">none — hold at Godbold</span>}</td>
                <td>
                  <select className="input" value={r.status} onChange={(e) => update(r.id, { status: e.target.value as RedemptionDoc["status"] })}>
                    {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
                  </select>
                </td>
                <td><input className="input" defaultValue={r.trackingNumber ?? ""} placeholder="Tracking #" onBlur={(e) => e.target.value !== (r.trackingNumber ?? "") && update(r.id, { trackingNumber: e.target.value })} /></td>
                <td><code>{r.txHash.slice(0, 10)}…</code></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
