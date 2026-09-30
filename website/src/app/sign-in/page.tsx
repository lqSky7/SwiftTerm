"use client";

import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";

import { isSupabaseConfigured, signInWithPassword, startSession } from "@/auth/client";

/**
 * Sign in.
 *
 * Two paths, because the Supabase project has no OAuth provider configured yet:
 *
 *   * Email and password against Supabase Auth, then the access token is exchanged at the backend
 *     for a session cookie. This is the real flow.
 *   * A pasted access token, which is what makes the exchange testable before an email template or
 *     a provider exists. It is not a bypass: the backend still verifies the signature against the
 *     issuer's JWKS and still creates the account from the verified subject.
 *
 * Either way the website never handles a database credential.
 */
export default function SignInPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [token, setToken] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const supabaseReady = isSupabaseConfigured();

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setBusy(true);
    try {
      if (supabaseReady && token === "") {
        await signInWithPassword(email, password);
      } else {
        if (token.trim() === "") throw new Error("Paste an access token to continue");
        await startSession(token.trim());
      }
      router.push("/account");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Sign-in failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="mx-auto w-full max-w-md px-4 py-20 sm:px-6">
      <h1 className="text-2xl font-medium tracking-tight">Sign in</h1>
      <p className="mt-2 text-sm text-muted-foreground">
        SwiftTerm identifies you by a verified account, never by your local user name.
      </p>

      <form onSubmit={submit} className="mt-8 flex flex-col gap-4">
        {supabaseReady && (
          <>
            <label className="flex flex-col gap-1.5 text-sm">
              <span className="font-medium">Email</span>
              <input
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                autoComplete="email"
                className="rounded-lg border border-input bg-background px-3 py-2 text-sm outline-none focus-visible:ring-2 focus-visible:ring-ring"
              />
            </label>
            <label className="flex flex-col gap-1.5 text-sm">
              <span className="font-medium">Password</span>
              <input
                type="password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                autoComplete="current-password"
                className="rounded-lg border border-input bg-background px-3 py-2 text-sm outline-none focus-visible:ring-2 focus-visible:ring-ring"
              />
            </label>
          </>
        )}

        {!supabaseReady && (
          <label className="flex flex-col gap-1.5 text-sm">
            <span className="font-medium">Access token</span>
            <textarea
              value={token}
              onChange={(event) => setToken(event.target.value)}
              rows={4}
              spellCheck={false}
              className="terminal-cell rounded-lg border border-input bg-background px-3 py-2 text-xs outline-none focus-visible:ring-2 focus-visible:ring-ring"
            />
            <span className="text-xs text-muted-foreground">
              Supabase is not configured for this deployment, so paste an access token to exchange
              it for a session.
            </span>
          </label>
        )}

        {error !== null && (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        )}

        <button
          type="submit"
          disabled={busy}
          className="rounded-lg bg-primary px-4 py-2.5 text-sm font-medium text-primary-foreground transition-opacity hover:opacity-90 disabled:opacity-50"
        >
          {busy ? "Signing in…" : "Sign in"}
        </button>
      </form>
    </section>
  );
}
