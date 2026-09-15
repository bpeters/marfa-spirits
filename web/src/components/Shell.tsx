import type { ReactNode } from "react";
import { Link, NavLink } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { WalletButton } from "./WalletButton";

export function Shell({ children }: { children: ReactNode }) {
  const { user, claims, signIn, signOut } = useAuth();
  return (
    <div className="wrap">
      <header className="site-header">
        <Link to="/" className="brand">
          Marfa Spirit Co.
        </Link>
        <nav className="nav" aria-label="Primary">
          <NavLink to="/join">Join</NavLink>
          <NavLink to="/members">Members</NavLink>
          <NavLink to="/verify">Verify</NavLink>
          {claims.staff && <NavLink to="/admin">Admin</NavLink>}
        </nav>
        <div className="row">
          <WalletButton />
          {user ? (
            <button className="btn ghost small" onClick={signOut}>
              Sign out
            </button>
          ) : (
            <button className="btn ghost small" onClick={signIn}>
              Sign in
            </button>
          )}
        </div>
      </header>
      <main id="main">{children}</main>
      <footer className="site-footer">
        <p>Marfa Spirit Co. · The Godbold, 320 W El Paso St, Marfa, Texas · (432) 426-6651</p>
        <p>Membership is for adults 21 and over. Please enjoy responsibly. Bottles ship only where permitted by law.</p>
      </footer>
    </div>
  );
}
