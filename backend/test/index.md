# backend/test — index

One file, `roles.test.ts`, run with `node --test --test-force-exit test/`.

These connect as **`swiftterm_api`** — the actual credential the service runs with — rather than as
an admin role. That is the whole point: the properties under test are properties of the *role*, so a
suite running as the admin would pass no matter how the grants were wrong.

| Group | Asserts |
| --- | --- |
| the API role's reach | it cannot read a token, CSRF or registration digest; cannot read the issuer or subject; cannot create or drop a table; cannot rewrite an immutable snapshot; does not hold `BYPASSRLS` |
| row-level security | no owner context sees zero rows; tenant A sees only A; tenant B sees only B; A cannot write a row owned by B; the owner context does not survive into the next request on the same pooled connection |
| credential resolution | a digest resolves through the function while the column stays unreadable; an unknown digest resolves to nothing; a revoked session still resolves, marked revoked; one tenant cannot revoke another's session |
| device listing | a tenant sees only its own devices |

## Two conventions this file follows

**Fixtures are unique per run.** `web_sessions.token_sha256` is `UNIQUE`, so a fixed literal would
collide with a row an earlier run left behind and the test would fail for a reason unrelated to the
code. Every digest is derived from the run's UUID.

**Cleanup borrows the owner role.** Deleting an account is deliberately not an API capability — the
API holds no `DELETE` grant on `app_users` at all. The teardown connects as the project admin and
`SET ROLE swiftterm_owner`, which is the only way to reach the owner because it is `NOLOGIN`.

## Requirements

`DATABASE_URL` (the API role) and `DATABASE_ADMIN_URL` (for cleanup only). Both come from `.env`,
which is gitignored.

## Still to add for B1A

OIDC verification tests with a locally generated key pair, session and CSRF cookie tests, device
registration concurrency and changed-payload conflict, resolver privilege and `search_path` abuse,
and log-redaction tests. Those belong with the service layer that does not exist yet.
