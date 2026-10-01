"use client";

import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";

import {
  allowsTokenSignIn,
  isSupabaseConfigured,
  signInWithPassword,
  startSession,
} from "@/auth/client";

/** The Supabase project this deployment is built against, for the link an operator needs. */
const PROJECT_REF = "upmarjiewuwvaljnnboq";
/**
 * Where the client key lives.
 *
 * **`settings/api-keys`, and the earlier `settings/api` was wrong.** Supabase's own documentation is
 * explicit that there is no separate "Settings → API" page any more — every key, legacy or current,
 * is on this one. A link that lands on a page which does not exist is worse than no link, because it
 * looks like the reader did something wrong.
 */
const PROJECT_API_KEYS_URL = `https://supabase.com/dashboard/project/${PROJECT_REF}/settings/api-keys/`;
/** The Connect dialog, which shows the URL and the client key together, ready to copy. */
const PROJECT_CONNECT_URL = `https://supabase.com/dashboard/project/${PROJECT_REF}?showConnect=true`;

/**
 * Sign in.
 *
 * Two paths, because the Supabase project has no OAuth provider configured yet:
 *
 *   * Email and password against Supabase Auth, then the access token is exchanged at the backend
 *     for a session cookie. This is the real flow, and it is what anyone signing in should see.
 *   * A pasted access token, which is what makes the exchange testable before an email template or a
 *     provider exists. It is not a bypass: the backend still verifies the signature against the
 *     issuer's JWKS and still creates the account from the verified subject.
 *
 * Either way the website never handles a database credential.
 *
 * **When the Supabase pair is missing, this page is not a sign-in page.** It used to show a bare
 * textarea labelled "Access token" and one line saying Supabase was not configured — which is
 * accurate and useless: a person who has never seen a Supabase token has no idea what one is, where
 * it comes from, or who could give them one. So the unconfigured state says what is wrong, what
 * would fix it, and who can do it; the token field is demoted to a labelled operator escape hatch
 * underneath, with the command that produces one. A page that cannot sign anybody in should say so
 * rather than invite someone to paste a credential they do not have.
 */
export default function SignInPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [token, setToken] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const supabaseReady = isSupabaseConfigured();
  // Only in a deployment that asked for it. See `allowsTokenSignIn`.
  const tokenSignInAvailable = !supabaseReady && allowsTokenSignIn();
  const usingToken = tokenSignInAvailable;

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setBusy(true);
    try {
      if (!usingToken) {
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
        {supabaseReady ? (
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
        ) : (
          <NotConfigured
            token={token}
            onToken={setToken}
            tokenSignInAvailable={tokenSignInAvailable}
          />
        )}

        {error !== null && (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        )}

        {/* No button at all when there is nothing to submit: a page with a disabled button and no
            way to enable it is the same complaint as a field nobody can fill in. */}
        {!supabaseReady && !tokenSignInAvailable ? null : (
          <button
            type="submit"
            disabled={busy || (usingToken && token.trim() === "")}
            className="rounded-lg bg-primary px-4 py-2.5 text-sm font-medium text-primary-foreground transition-opacity hover:opacity-90 disabled:opacity-50"
          >
            {busy ? "Signing in…" : usingToken ? "Exchange token for a session" : "Sign in"}
          </button>
        )}
      </form>
    </section>
  );
}

/**
 * What to show when this deployment has no Supabase pair.
 *
 * Three things, in the order a person needs them: what is wrong, what would fix it, and who can do
 * that. Then the operator path, closed, because it is not what a visitor should reach for.
 */
function NotConfigured({
  token,
  onToken,
  tokenSignInAvailable,
}: {
  readonly token: string;
  readonly onToken: (value: string) => void;
  readonly tokenSignInAvailable: boolean;
}) {
  return (
    <div className="flex flex-col gap-3">
      <div className="rounded-lg border border-dashed p-4 text-sm">
        <p className="font-medium">Sign-in is not set up on this deployment.</p>
        <p className="mt-1.5 text-muted-foreground">
          Password sign-in needs two values this build does not have, so there is nothing here to
          sign in with yet. This is a deployment problem rather than something you can fix from this
          page.
        </p>
        <p className="mt-2 text-muted-foreground">
          An operator sets <Code>NEXT_PUBLIC_SUPABASE_URL</Code> and{" "}
          <Code>NEXT_PUBLIC_SUPABASE_ANON_KEY</Code>. The second is the client key —{" "}
          <Code>anon</Code> <Code>public</Code>, or its newer name <Code>publishable</Code> — under{" "}
          <a
            href={PROJECT_API_KEYS_URL}
            target="_blank"
            rel="noreferrer noopener"
            className="underline underline-offset-2 hover:text-foreground"
          >
            Settings → API Keys
          </a>{" "}
          in the Supabase dashboard. It is publishable and safe to embed: it authorises the client,
          and every row is still scoped by row-level security. The <Code>secret</Code> key (formerly{" "}
          <Code>service_role</Code>) must never be.
        </p>
        <p className="mt-2 text-muted-foreground">
          The{" "}
          <a
            href={PROJECT_CONNECT_URL}
            target="_blank"
            rel="noreferrer noopener"
            className="underline underline-offset-2 hover:text-foreground"
          >
            Connect dialog
          </a>{" "}
          shows the URL and the key together, ready to copy.
        </p>
      </div>

      {/*
        The escape hatch, closed and labelled, and absent unless this deployment asked for it. It
        exists because the exchange is worth being able to test before an email template or a
        provider exists — not because a visitor should be expected to arrive with a token.
      */}
      {!tokenSignInAvailable ? null : (
      <details className="rounded-lg border p-4 text-sm">
        <summary className="cursor-pointer font-medium">
          I already have an access token
        </summary>
        <div className="mt-3 flex flex-col gap-3">
          <p className="text-muted-foreground">
            An access token is a short-lived signed pass that Supabase Auth issues when somebody
            signs in. It is not a password and not a shared secret: the backend verifies its
            signature against the project&apos;s published keys, so a token it did not issue is
            refused. It is valid for about an hour.
          </p>
          <p className="text-muted-foreground">
            If you are the operator, this produces one — it needs the same anon key as above, and an
            account that already exists on the project (the dashboard&apos;s Authentication → Users
            page creates one):
          </p>
          <pre className="overflow-x-auto rounded-md bg-muted p-3 text-xs">
            <code>{`curl -s -X POST \\
  'https://${PROJECT_REF}.supabase.co/auth/v1/token?grant_type=password' \\
  -H 'apikey: <ANON_KEY>' -H 'content-type: application/json' \\
  -d '{"email":"you@example.com","password":"..."}' | jq -r .access_token`}</code>
          </pre>
          <label className="flex flex-col gap-1.5">
            <span className="font-medium">Access token</span>
            <textarea
              value={token}
              onChange={(event) => onToken(event.target.value)}
              rows={4}
              spellCheck={false}
              placeholder="eyJhbGciOi…"
              className="terminal-cell rounded-lg border border-input bg-background px-3 py-2 text-xs outline-none focus-visible:ring-2 focus-visible:ring-ring"
            />
          </label>
        </div>
      </details>
      )}
    </div>
  );
}

function Code({ children }: { readonly children: React.ReactNode }) {
  return <code className="rounded bg-muted px-1 py-0.5 text-xs">{children}</code>;
}
