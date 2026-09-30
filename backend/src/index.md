# backend/src — index

| Path | Holds |
| --- | --- |
| `config.ts` | startup configuration: validated once, and it fails rather than defaulting |
| `db/` | the pool, the transaction discipline and the credential resolvers |
| `auth/` | OIDC verification, sessions, CSRF, device registration |
| `shared_session/` | the relay: tickets, the session registry, the WebSocket endpoint and the live control plane |
| `http/` | the server, the routes and the entrypoint |

## Configuration fails closed

There is no fallback secret, no default issuer and no development mode that skips verification.
`loadConfig` refuses to start without `DATABASE_URL`, `OIDC_ISSUER`, `OIDC_AUDIENCE`,
`OIDC_JWKS_URI` and a non-wildcard `ALLOWED_ORIGINS`. It also refuses an issuer that is not HTTPS, a
JWKS that does not live under the issuer, and a session lifetime over 24 hours.

`SWIFTTERM_TEST_FIXTURES` exists for local work and is refused outright when
`NODE_ENV=production`: test fixtures are not an authentication bypass for a deployed service.

## Status

B1A and B2A are implemented on the service side, verified against the live database: the role
boundaries, row-level security, credential resolution, both halves of the CSRF rule, the live
control plane and the relay's socket rules. B2B (the native publisher) and B2C (the browser viewer)
are next; see `../../docs/backend/todo.md`.
