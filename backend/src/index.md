# backend/src — index

| Path | Holds |
| --- | --- |
| `config.ts` | startup configuration: validated once, and it fails rather than defaulting |
| `db/` | the pool, the transaction discipline and the credential resolvers |

## Configuration fails closed

There is no fallback secret, no default issuer and no development mode that skips verification.
`loadConfig` refuses to start without `DATABASE_URL`, `OIDC_ISSUER`, `OIDC_AUDIENCE`,
`OIDC_JWKS_URI` and a non-wildcard `ALLOWED_ORIGINS`. It also refuses an issuer that is not HTTPS, a
JWKS that does not live under the issuer, and a session lifetime over 24 hours.

`SWIFTTERM_TEST_FIXTURES` exists for local work and is refused outright when
`NODE_ENV=production`: test fixtures are not an authentication bypass for a deployed service.

## Not written yet

`auth/` and `http/` do not exist. OIDC token verification, session cookies, CSRF, device endpoints
and the server itself are the remaining half of B1A.
