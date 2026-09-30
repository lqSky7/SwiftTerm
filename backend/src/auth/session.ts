/**
 * Browser sessions, CSRF, cookies and the rate limit in front of credential lookup.
 *
 * Two things here are the whole point:
 *
 *   1. The session secret is random and only its SHA-256 is ever stored. The plaintext exists in
 *      exactly two places: the client's cookie, and the response that set it.
 *   2. CSRF is not "does the cookie match the header". The header value must hash to the digest
 *      stored against *that session*, and the request must also carry an Origin we allow. A cookie
 *      alone is never sufficient — that is the rule the handoff states and the reason the CSRF
 *      token is a second, independently generated secret rather than a copy of the session token.
 */

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

import type { Config } from "../config.ts";

export const SESSION_TOKEN_BYTES = 32;
export const CSRF_TOKEN_BYTES = 32;

export function randomToken(bytes = SESSION_TOKEN_BYTES): Buffer {
  return randomBytes(bytes);
}

export function sha256(value: Buffer | string): Buffer {
  return createHash("sha256").update(value).digest();
}

/** Constant-time comparison, so a digest check cannot be turned into an oracle. */
export function digestsEqual(a: Buffer, b: Buffer): boolean {
  return a.length === b.length && timingSafeEqual(a, b);
}

// MARK: - Cookies

export interface CookieOptions {
  readonly maxAgeSeconds?: number;
  readonly httpOnly?: boolean;
  readonly secure?: boolean;
  readonly sameSite?: "Lax" | "Strict" | "None";
  readonly path?: string;
}

export function serializeCookie(name: string, value: string, options: CookieOptions): string {
  const parts = [`${name}=${value}`, `Path=${options.path ?? "/"}`];
  if (options.maxAgeSeconds !== undefined) parts.push(`Max-Age=${options.maxAgeSeconds}`);
  if (options.httpOnly !== false) parts.push("HttpOnly");
  if (options.secure !== false) parts.push("Secure");
  parts.push(`SameSite=${options.sameSite ?? "Lax"}`);
  return parts.join("; ");
}

export function clearCookie(name: string, options: CookieOptions = {}): string {
  return serializeCookie(name, "", { ...options, maxAgeSeconds: 0 });
}

/** Parse a `Cookie` header. Values are returned verbatim; nothing is decoded twice. */
export function parseCookies(header: string | undefined): Map<string, string> {
  const cookies = new Map<string, string>();
  if (header === undefined) return cookies;
  for (const pair of header.split(";")) {
    const index = pair.indexOf("=");
    if (index < 1) continue;
    const name = pair.slice(0, index).trim();
    const value = pair.slice(index + 1).trim();
    if (name !== "") cookies.set(name, value);
  }
  return cookies;
}

// MARK: - Rate limiting

/**
 * A bounded token bucket, keyed coarsely, checked *before* the expensive work of hashing a token
 * and querying the database.
 *
 * It is in-process on purpose: the handoff forbids a durable queue for this, and a single relay
 * process is the initial deployment. The map is capped so a flood of distinct keys cannot grow it
 * without bound — an attacker who can vary the key gets a full bucket, but cannot exhaust memory.
 */
export class FailureRateLimiter {
  readonly #capacity: number;
  readonly #refillPerSecond: number;
  readonly #maxKeys: number;
  readonly #buckets = new Map<string, { tokens: number; updatedAt: number }>();

  constructor(capacity = 10, refillPerSecond = 1, maxKeys = 10_000) {
    this.#capacity = capacity;
    this.#refillPerSecond = refillPerSecond;
    this.#maxKeys = maxKeys;
  }

  /** True when the caller may proceed. Consumes one token. */
  tryConsume(key: string, now = Date.now()): boolean {
    const bucket = this.#buckets.get(key);
    if (bucket === undefined) {
      if (this.#buckets.size >= this.#maxKeys) this.#evictOldest();
      this.#buckets.set(key, { tokens: this.#capacity - 1, updatedAt: now });
      return true;
    }
    const elapsedSeconds = Math.max(0, (now - bucket.updatedAt) / 1000);
    const refilled = Math.min(this.#capacity, bucket.tokens + elapsedSeconds * this.#refillPerSecond);
    bucket.updatedAt = now;
    if (refilled < 1) {
      bucket.tokens = refilled;
      return false;
    }
    bucket.tokens = refilled - 1;
    return true;
  }

  /** A successful credential lookup gives the key its budget back. */
  reset(key: string): void {
    this.#buckets.delete(key);
  }

  #evictOldest(): void {
    let oldestKey: string | null = null;
    let oldest = Number.POSITIVE_INFINITY;
    for (const [key, bucket] of this.#buckets) {
      if (bucket.updatedAt < oldest) {
        oldest = bucket.updatedAt;
        oldestKey = key;
      }
    }
    if (oldestKey !== null) this.#buckets.delete(oldestKey);
  }
}

// MARK: - Session lifecycle

export interface AuthenticatedSession {
  readonly sessionId: string;
  readonly ownerId: string;
  readonly csrfSha256: Buffer;
  readonly expiresAt: Date;
}

export interface StartedSession {
  readonly sessionId: string;
  readonly sessionToken: string;
  readonly csrfToken: string;
  readonly expiresAt: Date;
}

export interface SessionCookieNames {
  readonly session: string;
  readonly csrf: string;
}

/**
 * The cookies a started session sets. The session cookie is `HttpOnly` so script cannot read it;
 * the CSRF cookie deliberately is not, because the page has to read it to echo it back in a
 * header. That asymmetry is the design: an attacker who can read a cookie still cannot forge the
 * header check, because the check is against the digest stored server-side.
 */
export function sessionCookies(
  session: StartedSession,
  names: SessionCookieNames,
  config: Config,
): string[] {
  const maxAge = Math.max(0, Math.floor((session.expiresAt.getTime() - Date.now()) / 1000));
  const secure = config.secureCookies;
  return [
    serializeCookie(names.session, session.sessionToken, {
      maxAgeSeconds: maxAge,
      httpOnly: true,
      secure,
      sameSite: config.cookieSameSite,
    }),
    serializeCookie(names.csrf, session.csrfToken, {
      maxAgeSeconds: maxAge,
      httpOnly: false,
      secure,
      sameSite: config.cookieSameSite,
    }),
  ];
}

export function clearedSessionCookies(names: SessionCookieNames, config: Config): string[] {
  const secure = config.secureCookies;
  return [
    clearCookie(names.session, { httpOnly: true, secure, sameSite: config.cookieSameSite }),
    clearCookie(names.csrf, { httpOnly: false, secure, sameSite: config.cookieSameSite }),
  ];
}
