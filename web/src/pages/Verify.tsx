import { useState } from "react";
import { QRCodeSVG } from "qrcode.react";
import { useAccount, usePublicClient, useSignMessage } from "wagmi";
import { isAddress, recoverMessageAddress, getAddress } from "viem";
import { buildProofMessage, parseProofMessage, PROOF_TTL_MS } from "../../../shared/linkMessage";
import { membershipContract } from "../lib/contract";
import { useTiers, useWalletTokens } from "../lib/hooks";
import { dateFromUnix, errorMessage, shortAddress, tokenNo } from "../lib/format";
import { WalletButton } from "../components/WalletButton";

interface Result {
  ok: boolean;
  headline: string;
  rows: [string, string][];
}

/**
 * Two halves:
 *  - Members create a short-lived signed "pass" (QR + text) proving they control the wallet that
 *    holds a given token. Nothing is sent anywhere; the signature IS the proof.
 *  - Staff check a pass, a wallet address, or a token number against the chain. Every answer is a
 *    live read of `ownerOf` / `membershipOf`, so it cannot be spoofed by a screenshot.
 */
export default function Verify() {
  return (
    <>
      <MemberPass />
      <StaffCheck />
    </>
  );
}

function MemberPass() {
  const { address, isConnected } = useAccount();
  const { tokens } = useWalletTokens(address);
  const { tiers } = useTiers();
  const { signMessageAsync } = useSignMessage();
  const [pass, setPass] = useState<{ message: string; signature: string; tokenId: bigint } | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function makePass(tokenId: bigint) {
    setErr(null);
    try {
      const message = buildProofMessage({ address: address!, tokenId: tokenId.toString(), issuedAt: new Date().toISOString() });
      const signature = await signMessageAsync({ message });
      setPass({ message, signature, tokenId });
    } catch (e) {
      setErr(errorMessage(e));
    }
  }

  const payload = pass ? JSON.stringify({ m: pass.message, s: pass.signature }) : "";

  return (
    <section className="section grid-2" style={{ borderTop: 0 }}>
      <div className="stack">
        <h1 style={{ fontSize: "var(--t-2xl)" }}>Membership pass</h1>
        <p>
          At The Godbold, or picking up bottles? Sign a pass and show the code. It proves you hold the membership
          right now and expires after five minutes.
        </p>
        {!isConnected && <WalletButton />}
        {isConnected && tokens.length === 0 && <p className="muted">No membership in {shortAddress(address)}.</p>}
        <div className="row">
          {tokens.map((t) => (
            <button key={String(t.tokenId)} className="btn" onClick={() => makePass(t.tokenId)}>
              Sign pass for No. {tokenNo(t.tokenId)}
            </button>
          ))}
        </div>
        {err && <div className="note error" role="alert">{err}</div>}
      </div>
      {pass && (
        <div className="stack">
          <div className="qr">
            <QRCodeSVG value={payload} size={220} level="M" />
          </div>
          <small>
            No. {tokenNo(pass.tokenId)} · {tiers.find((t) => t.id === tokens.find((x) => x.tokenId === pass.tokenId)?.tierId)?.name}
          </small>
          <details>
            <summary>Text version</summary>
            <code style={{ fontSize: "var(--t-xs)" }}>{payload}</code>
          </details>
        </div>
      )}
    </section>
  );
}

function StaffCheck() {
  const publicClient = usePublicClient();
  const { tiers } = useTiers();
  const [input, setInput] = useState("");
  const [result, setResult] = useState<Result | null>(null);
  const [busy, setBusy] = useState(false);

  const tierName = (id: number) => tiers.find((t) => t.id === id)?.name ?? `Tier ${id}`;

  async function describeToken(tokenId: bigint, extraRows: [string, string][] = []): Promise<Result> {
    const owner = await publicClient!.readContract({ ...membershipContract, functionName: "ownerOf", args: [tokenId] });
    const m = await publicClient!.readContract({ ...membershipContract, functionName: "membershipOf", args: [tokenId] });
    const ownerVerified = await publicClient!.readContract({ ...membershipContract, functionName: "isVerified", args: [owner] });
    const active = Number(m.expiresAt) * 1000 > Date.now();
    return {
      ok: active,
      headline: active ? `No. ${tokenNo(tokenId)} is active` : `No. ${tokenNo(tokenId)} has expired`,
      rows: [
        ["Tier", tierName(m.tierId)],
        [active ? "Good through" : "Expired", dateFromUnix(m.expiresAt)],
        ["Held by", owner],
        ["Age-verified wallet", ownerVerified ? "Yes" : "No — revoked"],
        ...extraRows,
      ],
    };
  }

  async function check(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setResult(null);
    const raw = input.trim();
    try {
      // 1) A signed pass (JSON from the QR / text version).
      if (raw.startsWith("{")) {
        const { m, s } = JSON.parse(raw) as { m: string; s: `0x${string}` };
        const parsed = parseProofMessage(m);
        if (!parsed) throw new Error("That isn't a membership pass.");
        const age = Date.now() - Date.parse(parsed.issuedAt);
        if (Number.isNaN(age) || age > PROOF_TTL_MS) throw new Error("Pass expired. Ask them to sign a fresh one.");
        if (age < -60_000) throw new Error("Pass is dated in the future.");
        const signer = await recoverMessageAddress({ message: m, signature: s });
        if (getAddress(signer) !== getAddress(parsed.address)) throw new Error("Signature doesn't match the wallet on the pass.");
        const owner = await publicClient!.readContract({ ...membershipContract, functionName: "ownerOf", args: [BigInt(parsed.tokenId)] });
        if (getAddress(owner) !== getAddress(signer)) {
          setResult({ ok: false, headline: "This wallet no longer holds that membership", rows: [["Signed by", signer], ["Current holder", owner]] });
          return;
        }
        const r = await describeToken(BigInt(parsed.tokenId), [["Signed", `${Math.round(age / 1000)}s ago by the holder`]]);
        setResult(r);
        return;
      }
      // 2) A wallet address.
      if (isAddress(raw)) {
        const ids = await publicClient!.readContract({ ...membershipContract, functionName: "tokensOfOwner", args: [raw] });
        if (ids.length === 0) {
          const v = await publicClient!.readContract({ ...membershipContract, functionName: "isVerified", args: [raw] });
          setResult({ ok: false, headline: "No membership in this wallet", rows: [["Wallet", raw], ["Age-verified wallet", v ? "Yes — can receive a membership" : "No"]] });
          return;
        }
        const first = await describeToken(ids[0]);
        if (ids.length > 1) first.rows.push(["Also holds", ids.map((i) => `No. ${tokenNo(i)}`).join(", ")]);
        setResult(first);
        return;
      }
      // 3) A token number.
      if (/^\d+$/.test(raw)) {
        setResult(await describeToken(BigInt(raw)));
        return;
      }
      throw new Error("Enter a pass, a wallet address, or a membership number.");
    } catch (err) {
      setResult({ ok: false, headline: errorMessage(err), rows: [] });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="section grid-2">
      <div className="stack">
        <h2>Check a member</h2>
        <p>For staff. Paste a pass, a wallet address, or a membership number. The answer comes straight from the chain.</p>
        <form className="stack" onSubmit={check}>
          <textarea className="input" rows={4} value={input} onChange={(e) => setInput(e.target.value)} placeholder='{"m":"Marfa Spirit Co. proof…"}  or  0xabc…  or  0042' aria-label="Pass, wallet, or membership number" />
          <div>
            <button className="btn" type="submit" disabled={busy || !input.trim()}>{busy ? "Checking…" : "Check"}</button>
          </div>
        </form>
      </div>
      {result && (
        <div className="stack" aria-live="polite">
          <span className={`tag${result.ok ? " filled" : ""}`} style={{ alignSelf: "flex-start" }}>{result.ok ? "Active member" : "Not verified"}</span>
          <h3>{result.headline}</h3>
          {result.rows.length > 0 && (
            <dl className="notes">
              {result.rows.map(([k, v]) => (
                <div key={k}><dt>{k}</dt><dd><code>{v}</code></dd></div>
              ))}
            </dl>
          )}
        </div>
      )}
    </section>
  );
}
