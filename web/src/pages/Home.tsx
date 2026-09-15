import { Link } from "react-router-dom";
import { useTiers } from "../lib/hooks";
import { eth } from "../lib/format";
import { MemberCard } from "../components/MemberCard";

const TIER_COPY: Record<string, string> = {
  "Founders 2026": "Fifty seats. Two bottle allocations this year, first call on every limited run, and a standing invitation to The Godbold. Next year, trade your Founders token in for the tier you want at a founder's price.",
  Sotolero: "Two bottle allocations a year — the Chihuahuan Desert Sotol release and one seasonal — plus first call on limited runs like Desert Rose and Desert Pechuga.",
  Godbold: "Everything in Sotolero, plus a barrel-select bottling each year, a private tasting for four at The Godbold, and invitations to distillery dinners.",
};

export default function Home() {
  const { tiers, isLoading } = useTiers();
  const yearOut = Math.floor(Date.now() / 1000) + 365 * 86400;

  return (
    <>
      <section className="hero grid-2">
        <div>
          <h1>
            A seat at
            <br />
            The Godbold.
          </h1>
          <p style={{ marginTop: "1.5rem" }}>
            We distill sotol, rum, gin, and Rio Grande liqueurs in Marfa, Texas. Membership gets you bottles set
            aside before they hit the shelf, releases that never leave the tasting room, and a standing welcome at
            320 W El Paso St.
          </p>
          <p>
            Your membership lives in your wallet as a token you own outright. Renew it yearly, trade it in for next
            year&apos;s tier, or pass it on — to another verified adult only; the contract won&apos;t let it go anywhere else.
          </p>
          <div className="row" style={{ marginTop: "1.5rem" }}>
            <Link to="/join" className="btn">
              Join the club
            </Link>
            <Link to="/members" className="btn ghost">
              I&apos;m a member
            </Link>
          </div>
        </div>
        <MemberCard tokenId={1n} tierName={tiers.find((t) => t.active)?.name ?? "Founders 2026"} expiresAt={yearOut} stamp />
      </section>

      <section className="section">
        <div className="section-head">
          <h2>Tiers</h2>
          <small>Priced in ETH · yearly renewal</small>
        </div>
        {isLoading && <p className="muted">Loading tiers from the chain…</p>}
        {!isLoading && tiers.length === 0 && (
          <p className="muted">Tiers are not published yet. Check back soon, or ask at the tasting room.</p>
        )}
        <div className="grid-2">
          {tiers.map((t) => (
            <article key={t.id} className="stack">
              <h3>{t.name}</h3>
              <dl className="notes">
                <div>
                  <dt>To join</dt>
                  <dd>{eth(t.mintPrice)}</dd>
                </div>
                <div>
                  <dt>To renew</dt>
                  <dd>{eth(t.renewalPrice)} / year</dd>
                </div>
                <div>
                  <dt>Spots</dt>
                  <dd>
                    {t.maxSupply - t.minted} of {t.maxSupply} left
                  </dd>
                </div>
                <div>
                  <dt>What you get</dt>
                  <dd>{TIER_COPY[t.name] ?? "Bottle allocations, member releases, and access at The Godbold."}</dd>
                </div>
              </dl>
              <div>
                {t.active ? (
                  <Link to={`/join?tier=${t.id}`} className="btn">Join as {t.name}</Link>
                ) : (
                  <span className="tag">
                    {t.rolloverFromMask
                      ? `Opens next year · trade in ${tiers.filter((x) => t.rolloverFromMask & (1 << x.id)).map((x) => x.name).join(" or ")}${t.rolloverPrice > 0n ? ` + ${eth(t.rolloverPrice)}` : ""}`
                      : "Not open"}
                  </span>
                )}
              </div>
            </article>
          ))}
        </div>
      </section>

      <section className="section grid-2">
        <div>
          <h2>How it works</h2>
        </div>
        <ol className="steps">
          <li>
            <div>
              <h4>Confirm you&apos;re 21 or older</h4>
              <p>Spirits law comes first. We check once, and never store your date of birth.</p>
            </div>
          </li>
          <li>
            <div>
              <h4>Link a wallet</h4>
              <p>
                Sign a message to prove the wallet is yours. No gas, no transaction. This is also how we confirm your
                membership later.
              </p>
            </div>
          </li>
          <li>
            <div>
              <h4>Join</h4>
              <p>Pay the tier price and the membership token lands in your wallet. It&apos;s good for one year.</p>
            </div>
          </li>
          <li>
            <div>
              <h4>Claim your bottles</h4>
              <p>
                When a release opens, claim it from your member page. We ship where the law allows, or hold it for
                pickup at The Godbold.
              </p>
            </div>
          </li>
          <li>
            <div>
              <h4>Trade in next year</h4>
              <p>
                When next year&apos;s tier opens, trade this year&apos;s token in to take your seat: the token is
                burned and you pay the trade-in price, which is less than joining cold. Any time left carries over.
              </p>
            </div>
          </li>
        </ol>
      </section>
    </>
  );
}
