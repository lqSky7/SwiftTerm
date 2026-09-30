# backend/src/auth — index

| File | Holds |
| --- | --- |
| `oidc.ts` | OIDC token verification against the issuer's JWKS |
| `session.ts` | session and CSRF token generation, cookies, and the rate limit in front of credential lookup |
| `devices.ts` | device registration, including the idempotency rule |

## The three rules this directory exists to enforce

**The issuer is the only source of identity.** `oidc.ts` verifies issuer, audience, signature and
expiry against a JWKS, with the accepted algorithms pinned rather than read from the token's own
header. There is no fallback that trusts an unverified token, because a fallback is exactly how
"never trust an unsigned client subject" gets broken.

**CSRF needs both halves.** The header value must hash to the digest stored against *that session*,
**and** the request must carry an `Origin` we allow. A cookie alone is never sufficient — which is
why the CSRF token is a second, independently generated secret rather than a copy of the session
token, and why the CSRF cookie is deliberately readable by script while the session cookie is not.

**An identical device retry is idempotent; a changed one is a conflict.** `registrationDigest`
covers the whole registration payload including the device token, so a retry that presents a new
token is a *different* registration. Accepting it silently would rotate a credential behind the
client's back, so it is a 409.

## Notes

The rate limiter is in-process and bounded on purpose: the handoff forbids a durable queue for this,
and the initial deployment is one relay process. The map is capped so a flood of distinct keys
cannot grow it without bound.

Nothing here logs a token, a digest or a cookie. Failures carry an allowlisted code and the reason
stays local.
