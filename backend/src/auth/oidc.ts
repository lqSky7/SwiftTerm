/**
 * OIDC token verification.
 *
 * The only thing this file is allowed to conclude is "a trusted issuer signed this, for this
 * audience, and it has not expired". It never reads a subject out of request JSON, and it never
 * falls back to trusting an unverified token — the handoff's rule is "never trust an unsigned
 * client subject", and a fallback path is exactly how that rule gets broken.
 *
 * Supabase Auth is the issuer. Its JWKS is fetched over HTTPS and cached; jose refuses `alg: none`
 * because a key set is always supplied, and the accepted algorithms are pinned rather than taken
 * from the token header.
 */

import { createRemoteJWKSet, jwtVerify, type JWTPayload } from "jose";

import type { Config } from "../config.ts";

export class IdentityError extends Error {
  readonly code = "unauthorized" as const;

  constructor(message: string) {
    super(message);
    this.name = "IdentityError";
  }
}

export interface VerifiedIdentity {
  readonly issuer: string;
  readonly subject: string;
  readonly displayName: string;
}

/** Algorithms this service will accept. Pinned, not read from the token's own header. */
const ACCEPTED_ALGORITHMS = ["ES256", "RS256"];

export class IdentityVerifier {
  readonly #jwks: ReturnType<typeof createRemoteJWKSet>;
  readonly #issuer: string;
  readonly #audience: string;

  constructor(config: Config) {
    this.#jwks = createRemoteJWKSet(new URL(config.oidcJwksUri), {
      timeoutDuration: 5_000,
      // Ten minutes: long enough that a burst of requests does not hammer the issuer, short enough
      // that a rotated key is picked up without a restart.
      cacheMaxAge: 600_000,
      cooldownDuration: 30_000,
    });
    this.#issuer = config.oidcIssuer;
    this.#audience = config.oidcAudience;
  }

  /**
   * Verify a compact JWS and return the identity it asserts. Throws `IdentityError` for anything
   * that is not a signature-verified, unexpired, correctly-audienced token from the configured
   * issuer — including a malformed one, an unsigned one and one signed by a key we do not trust.
   */
  async verify(token: string): Promise<VerifiedIdentity> {
    let payload: JWTPayload;
    try {
      const verified = await jwtVerify(token, this.#jwks, {
        issuer: this.#issuer,
        audience: this.#audience,
        algorithms: ACCEPTED_ALGORITHMS,
        // Five seconds of clock skew. Expiry is otherwise enforced by jose.
        clockTolerance: 5,
      });
      payload = verified.payload;
    } catch (error) {
      // The reason is deliberately not echoed to the client; it goes to the caller's log only.
      throw new IdentityError(
        `token rejected: ${error instanceof Error ? error.message : "unverifiable"}`,
      );
    }

    const issuer = payload.iss;
    if (typeof issuer !== "string" || issuer.length === 0 || issuer.length > 2048) {
      throw new IdentityError("token has no usable issuer");
    }
    const subject = payload.sub;
    if (typeof subject !== "string" || subject.length === 0 || subject.length > 512) {
      throw new IdentityError("token has no usable subject");
    }

    return { issuer, subject, displayName: displayNameFrom(payload) };
  }
}

/**
 * A display name for the account row. This is presentation only — the identity is the
 * (issuer, subject) pair, and nothing here is ever used to authorise anything.
 */
function displayNameFrom(payload: JWTPayload): string {
  for (const claim of ["name", "email", "preferred_username"]) {
    const value = payload[claim];
    if (typeof value === "string" && value.trim() !== "") return value.slice(0, 256);
  }
  return "";
}
