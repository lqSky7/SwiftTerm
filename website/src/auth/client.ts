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

/**
 * Create an account, then tell the caller to go and confirm it.
 *
 * **This is the half that was missing, and it is why "how does a user get in" had no good answer.**
 * The backend provisions its own account automatically from the verified token — but a Supabase Auth
 * account has to exist first, and nothing in this repository created one. So the only way in was an
 * operator adding a row in the dashboard, which is not a product.
 *
 * It does **not** sign the person in, and that is not an oversight: this project has
 * `mailer_autoconfirm: false`, so a fresh account cannot authenticate until the address is
 * confirmed. Calling `startSession` here would fail with "Invalid login credentials" and look like
 * a broken sign-up. The caller shows the confirmation message instead.
 *
 * A weak password is reported as the service describes it, because that is the one failure a person
 * can act on. Everything else is one sentence — "already registered" and "that address is invalid"
 * are the same shape of answer to somebody who cannot see the user table.
 */
export async function signUpWithPassword(email: string, password: string): Promise<void> {
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
