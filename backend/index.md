# backend — index

The authenticated relay and share store. Node 24 LTS, TypeScript strict ESM, `node:http`, `pg`,
`jose`. It owns identity, sessions and metadata; it never launches a shell, holds no SSH credential
and has no filesystem API.

Read `../docs/backend/implementation-handoff.md` for the package boundaries and
`../docs/backend/wire-contract.md` for the frames. This directory is B1A.

| Path | Holds |
| --- | --- |
| `migrations/` | the reviewed schema, the least-privilege roles, the credential resolvers and the live-session control plane |
| `src/db/` | the pool, the transaction discipline and the only code that touches a credential digest |
| `src/shared_session/` | the relay: tickets, the session registry, the WebSocket endpoint and the durable control plane |
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

`npm run migrate` needs a role with `CREATEROLE` for `000_roles.sql`. On a managed platform that is
the project admin, so a fresh environment is built with
`MIGRATION_DATABASE_URL="$DATABASE_ADMIN_URL" npm run migrate`.

## The three decisions worth knowing before editing

**The API role cannot read a credential digest.** `swiftterm_api` holds column privileges rather
than table privileges, so `token_sha256`, `csrf_sha256` and `registration_sha256` are not readable
by the service at all. Resolution goes through `SECURITY DEFINER` functions owned by
`swiftterm_resolver`, a role that cannot be logged into. That is why the service never selects a
hash column and why adding one would fail rather than silently widen access. **The grant section in
`migrations/001_identity.sql` is what makes this true, and its absence is silent** — see
`migrations/index.md`.

**The owner context is transaction-local.** `set_config('swiftterm.user_id', $1, true)` is scoped to
one transaction on one checked-out client, so a pooled backend cannot carry one request's owner into
the next. Every policy compares `owner_id` with that value, so a query that forgets to set it sees
nothing rather than everything.

**The relay holds no credentials and writes nothing down.** Terminal frames live in memory only, and
`src/shared_session/socket.ts` never touches the database — releasing a publisher's lease on
disconnect is a callback into `live.ts`. The durable half is the metadata: which pane is shared, in
what state, and which publisher generation holds the lease.

## Status

B1A and B2A are implemented and verified against a live PostgreSQL 17 (Supabase): the database
foundation, the service layer in `src/auth/` and `src/http/`, and the relay in
`src/shared_session/`. The suite covers the role boundaries, row-level security, credential
resolution, both halves of the CSRF rule, the live control plane and the relay's socket rules.

Remaining: B2B (the native publisher) and B2C (the browser viewer), then B3A. B1A's rollback policy
and a backup/restore drill are also outstanding. See `../docs/backend/todo.md`.
