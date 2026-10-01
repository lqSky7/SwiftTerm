/**
 * Session and device calls.
 *
 * The website never sees a database credential and never holds a device token — those belong to the
 * native app. What it holds is a session cookie the backend minted, plus the CSRF token it has to
 * echo back on writes.
 *
 * A note on the sign-in flow. The handoff describes authorization code + PKCE through a backend
 * callback. This Supabase project has **no OAuth provider configured**, so there is no redirect
 * target to send a browser to; the working path is that Supabase Auth issues the access token and
 * this client exchanges it for a session at `POST /auth/session`, where the backend verifies the
 * signature against the issuer's JWKS. That is a recorded divergence, not an oversight: the
 * exchange endpoint is the same one a redirect callback would use, so adding a provider later
 * changes only where the token comes from.
 */

import { apiFetch } from "@/lib/api";

export interface Account {
  readonly id: string;
  readonly display_name: string;
  readonly created_at: string;
  readonly deactivated_at: string | null;
}

export interface Device {
  readonly id: string;
  readonly label: string;
  readonly client_request_id: string;
  readonly created_at: string;
  readonly revoked_at: string | null;
}

export interface SessionResponse {
  readonly session_id: string;
  readonly csrf_token: string;
  readonly expires_in_hours: number;
}

/** Exchange a Supabase-issued access token for a session cookie. */
export async function startSession(accessToken: string): Promise<SessionResponse> {
  return apiFetch<SessionResponse>("/auth/session", {
    method: "POST",
    body: { access_token: accessToken },
  });
}

export async function endSession(): Promise<void> {
  await apiFetch<void>("/auth/logout", { method: "POST" });
}

/** `null` when there is no session, rather than throwing — the common case on a public page. */
export async function currentAccount(): Promise<Account | null> {
  try {
    return await apiFetch<Account>("/me");
  } catch {
    return null;
  }
}

export async function listDevices(): Promise<Device[]> {
  const response = await apiFetch<{ devices: Device[] }>("/devices");
  return response.devices;
}

export async function revokeDevice(id: string): Promise<void> {
  await apiFetch<void>(`/devices/${encodeURIComponent(id)}`, { method: "DELETE" });
}

/**
 * Sign in against Supabase Auth directly, then exchange the token.
 *
 * The anon key is public by design — it identifies the project, it does not grant anything. If it
 * is not configured the page falls back to accepting an access token pasted in by hand, which is
 * what makes the flow testable before a provider or an email template is set up.
 */
export async function signInWithPassword(email: string, password: string): Promise<SessionResponse> {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (supabaseUrl === undefined || anonKey === undefined) {
    throw new Error("Supabase is not configured for this deployment");
  }

  const response = await fetch(`${supabaseUrl}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: anonKey },
    body: JSON.stringify({ email, password }),
  });

  if (!response.ok) {
    // Deliberately not distinguishing "no such user" from "wrong password": that distinction is
    // how an account enumeration oracle gets built.
    throw new Error("Those credentials were not accepted");
  }

  const payload = (await response.json()) as { access_token?: string };
  if (typeof payload.access_token !== "string") {
    throw new Error("Supabase did not return an access token");
  }
  return startSession(payload.access_token);
}

export function isSupabaseConfigured(): boolean {
  return (
    process.env.NEXT_PUBLIC_SUPABASE_URL !== undefined &&
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY !== undefined
  );
}

/** Whether a fresh account can be used immediately, and the session if so. */
export interface SignUpResult {
  /**
   * The access token, present only when the project auto-confirms.
   *
   * `null` means the project requires email confirmation and there is nothing to sign in with yet.
   * The caller has to distinguish these two, because telling somebody to check an email that was
   * never sent is a worse failure than the sign-up failing outright.
   */
  readonly accessToken: string | null;
}

/**
 * Create an account.
 *
 * **The return value is the whole point.** This project has `mailer_autoconfirm: false`, so signup
 * returns a user and no session, and the caller must say "check your email". But that setting is a
 * dashboard toggle an operator can flip, and with it on GoTrue returns a **session** from the same
 * call — the account is usable immediately and no email is sent. An earlier version of this discarded
 * the response and always showed the confirmation panel, which would have told people to check an
 * inbox for a message that does not exist.
 *
 * It does not sign in either way. `startSession` is the caller's, so the two outcomes stay visible
 * where the redirect happens.
 *
 * A weak password is reported as the service describes it, because that is the one failure a person
 * can act on. Everything else is one sentence — "already registered" and "that address is invalid"
 * are the same shape of answer to somebody who cannot see the user table.
 */
export async function signUpWithPassword(email: string, password: string): Promise<SignUpResult> {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (supabaseUrl === undefined || anonKey === undefined) {
    throw new Error("Supabase is not configured for this deployment");
  }

  const response = await fetch(`${supabaseUrl}/auth/v1/signup`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: anonKey },
    body: JSON.stringify({ email, password }),
  });

  if (!response.ok) {
    const payload = (await response.json().catch(() => ({}))) as { msg?: string; error_code?: string };
    // The password policy is the one refusal worth repeating verbatim — it says what to change.
    if (payload.error_code === "weak_password" && typeof payload.msg === "string") {
      throw new Error(payload.msg);
    }
    throw new Error("That address could not be registered. It may already have an account.");
  }

  // Both shapes are checked rather than one assumed: GoTrue has returned the session at the top
  // level and nested under `session` depending on version, and guessing wrong here means either
  // signing nobody in or telling somebody to check an email that was never sent.
  const payload = (await response.json().catch(() => ({}))) as {
    access_token?: unknown;
    session?: { access_token?: unknown } | null;
  };
  const top = typeof payload.access_token === "string" ? payload.access_token : null;
  const nested =
    payload.session !== null && typeof payload.session?.access_token === "string"
      ? payload.session.access_token
      : null;
  return { accessToken: top ?? nested };
}

/**
 * Whether this deployment may offer the paste-a-token path.
 *
 * **Off unless a deployment turns it on, and it exists because it was on for everybody.** The path
 * is how the token exchange gets tested before an email template or a provider exists, and its only
 * audience is whoever is building the thing — but a deployed site was showing a credential-paste
 * field to whoever opened the page, which is not a thing a product does. Absent means off, so the
 * default is the honest one and nobody has to remember to remove it before shipping.
 */
export function allowsTokenSignIn(): boolean {
  return process.env.NEXT_PUBLIC_ALLOW_TOKEN_SIGN_IN === "1";
}
