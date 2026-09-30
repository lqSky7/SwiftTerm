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
