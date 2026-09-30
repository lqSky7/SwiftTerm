"use client";

import Link from "next/link";
import { useEffect, useState } from "react";

import { currentAccount, type Account } from "@/auth/client";
import { Logo } from "@/components/logo";

/**
 * The chrome. Visually the same shape as aside-clone's navbar — a 56px bar, the mark on the left,
 * a centred link group, the account control on the right — but the mark is SwiftTerm's and the
 * whole bar is achromatic, matching the token set.
 */
export function Navbar() {
  const [account, setAccount] = useState<Account | null>(null);
  const [settled, setSettled] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void currentAccount().then((value) => {
      if (cancelled) return;
      setAccount(value);
      setSettled(true);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <nav className="sticky top-0 z-50 w-full border-b border-border/40 bg-background/95 backdrop-blur-md">
      <div className="mx-auto flex h-14 w-full max-w-6xl items-center justify-between px-4 sm:px-6 lg:px-12">
        <Link href="/" className="text-foreground transition-opacity hover:opacity-70">
          <Logo />
        </Link>

        <ul className="absolute left-1/2 hidden -translate-x-1/2 items-center gap-8 text-sm font-medium md:flex">
          <li>
            <Link
              href="/#how"
              className="py-2 text-muted-foreground transition-colors hover:text-foreground"
            >
              How it works
            </Link>
          </li>
          <li>
            <Link
              href="/account"
              className="py-2 text-muted-foreground transition-colors hover:text-foreground"
            >
              Devices
            </Link>
          </li>
        </ul>

        <div className="flex items-center gap-2">
          {/* The account control renders nothing until the session check settles, so a signed-in
              visitor never sees "Sign in" flash on a cold load. */}
          {settled &&
            (account === null ? (
              <Link
                href="/sign-in"
                className="rounded-lg bg-primary px-3.5 py-1.5 text-sm font-medium text-primary-foreground transition-opacity hover:opacity-90"
              >
                Sign in
              </Link>
            ) : (
              <Link
                href="/account"
                className="rounded-lg border border-border px-3.5 py-1.5 text-sm font-medium transition-colors hover:bg-accent"
              >
                {account.display_name !== "" ? account.display_name : "Account"}
              </Link>
            ))}
        </div>
      </div>
    </nav>
  );
}
