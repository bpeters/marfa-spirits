import { dateFromUnix, tokenNo } from "../lib/format";

export function MemberCard({
  tokenId,
  tierName,
  expiresAt,
  stamp,
}: {
  tokenId: bigint | string;
  tierName: string;
  expiresAt: number | bigint;
  stamp?: boolean;
}) {
  const active = Number(expiresAt) * 1000 > Date.now();
  return (
    <div className={`card${active ? "" : " expired"}${stamp ? " stamp" : ""}`} role="img" aria-label={`Membership ${tokenNo(tokenId)}, ${tierName}, ${active ? "active" : "expired"}`}>
      <div className="card-top">
        <div>
          <div className="card-brand">Marfa Spirit Co.</div>
          <div>Membership · Marfa, Texas</div>
        </div>
        <div className="card-no">No. {tokenNo(tokenId)}</div>
      </div>
      <div className="card-tier">{tierName}</div>
      <div className="card-meta">
        <div>
          <span>Status</span>
          {active ? "Active" : "Expired"}
        </div>
        <div>
          <span>{active ? "Good through" : "Expired"}</span>
          {dateFromUnix(expiresAt)}
        </div>
        <div>
          <span>Distilled in</span>
          Marfa, TX
        </div>
      </div>
    </div>
  );
}
