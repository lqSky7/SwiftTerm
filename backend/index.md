# backend — index

The authenticated relay and share store. Node 24 LTS, TypeScript strict ESM, `node:http`, `pg`,
`jose`. It owns identity, sessions and metadata; it never launches a shell, holds no SSH credential
and has no filesystem API.

Read `../docs/backend/implementation-handoff.md` for the package boundaries and
`../docs/backend/wire-contract.md` for the frames. This directory is B1A.

| Path | Holds |
| --- | --- |
| `migrations/` | the reviewed schema, the least-privilege roles and the credential resolvers |
| `src/db/` | the pool, the transaction discipline and the only code that touches a credential digest |
| `src/config.ts` | startup configuration, which fails rather than defaulting |
| `scripts/` | role provisioning, which is where a password comes from the environment |
| `test/` | real-role tests that connect as the API role, not as an admin |

## Running it

```sh
cp .env.example .env          # then fill it in; .env is gitignored
npm install
npm run migrate               # applies migrations/*.sql in order
npm run provision-roles       # gives the runtime roles a login, from the environment
npm test                      # node:test against the real database
npm run typecheck
```

## The two decisions worth knowing before editing

**The API role cannot read a credential digest.** `swiftterm_api` holds column privileges rather
than table privileges, so `token_sha256`, `csrf_sha256` and `registration_sha256` are not readable
by the service at all. Resolution goes through `SECURITY DEFINER` functions owned by
`swiftterm_resolver`, a role that cannot be logged into. That is why the service never selects a
hash column and why adding one would fail rather than silently widen access.

**The owner context is transaction-local.** `set_config('swiftterm.user_id', $1, true)` is scoped to
one transaction on one checked-out client, so a pooled backend cannot carry one request's owner into
the next. Every policy compares `owner_id` with that value, so a query that forgets to set it sees
nothing rather than everything.

## Status

B1A's database foundation is implemented and verified against a live PostgreSQL 17 (Supabase). The
service layer — OIDC verification, session cookies, CSRF, the HTTP endpoints — is **not written
yet**; `src/auth/` and `src/http/` do not exist. See `../docs/backend/todo.md`.
