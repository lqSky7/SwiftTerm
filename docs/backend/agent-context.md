# Agent context — implementing the backend and website

Written after C0 and B1A's database half landed. `implementation-handoff.md` is the plan;
this file is everything the plan does not say that cost real time to discover. Read the handoff
first, then this, then `wire-contract.md`.

---

## 1. What already exists — do not rebuild it

| Commit | What | Verified how |
| --- | --- | --- |
| `01f1063` | **C0** — the wire contract, Swift DTOs + TypeScript validators + shared fixtures | 270 Swift checks, 79 TypeScript checks, 54 shared invalid cases, digests matched across both languages |
| `9bfa682` | **B1A database half** — migrations, roles, resolvers, `src/config.ts`, `src/db/**`, tests | 17 `node:test` checks passing against live PostgreSQL 17 |

Already applied to the live database: 8 tables, forced row-level security, 4 roles, 7
`SECURITY DEFINER` credential resolvers. Migration `001` is **idempotent and proven so** — it is
applied twice during verification. Keep it that way.

Reuse, do not reinvent:

- `contracts/ts/wire.ts` — the validators, for the website. Dependency-free, no `node:` import, so
  the browser loads it directly. `SnapshotAssembler.finish` takes an **injected digest** because the
  only browser SHA-256 is asynchronous.
- `backend/src/db/pool.ts` — `withOwner` / `withoutOwner` are the **only** way to run a transaction.
- `backend/src/db/resolvers.ts` — the only code that may touch a credential digest.

---

## 2. What to build next, in order

**Backend — finish B1A.** `backend/src/auth/**` and `backend/src/http/**` do not exist.
- OIDC verification with `jose` against the issuer's JWKS; verify issuer, audience, signature,
  expiry, nonce. Never trust a client-claimed subject.
- Browser session: 256-bit random secret, only SHA-256 stored, `Secure HttpOnly SameSite=Lax`,
  24-hour absolute expiry. Plus a CSRF companion cookie checked by digest **and** `Origin` against a
  request header — never cookie-only.
- Device registration with `client_request_id` idempotency: identical retry returns the existing
  device UUID, **changed payload returns 409**. `registerDevice` in `resolvers.ts` already returns
  the stored registration digest so you can tell the two apart.
- Endpoints: `GET /me`, `POST`/`DELETE /devices`, login/callback/logout/session/CSRF.
- Rate-limit failed credential lookups *before* the expensive work.

**Website — `website/` does not exist at all.** B1A's share is `website/src/auth/**` plus the build
shell (a sign-in page). B2C later adds the live viewer: canvas grid, DOM `textContent` for
escaped block/header text, no `innerHTML`, no second VT parser.

**Then** B1B (native identity + website pages), B2A (relay), B2C (viewer), B3A (control). Each
depends on the previous; do not start one because the previous compiled.

---

## 3. Environment traps — each of these cost time

**Supabase: the direct host does not work here.** `db.<ref>.supabase.co` is **IPv6-only** and this
machine has no IPv6, so it fails DNS outright. Use the pooler:

```
aws-0-ap-south-1.pooler.supabase.com:5432   user: <role>.upmarjiewuwvaljnnboq
```

**PostgreSQL 16+ role semantics.** Three separate failures came from these:
1. `CREATE ROLE` by a `CREATEROLE` user grants the creator `ADMIN` but **not `SET`**, so
   `SET ROLE` fails until an explicit `GRANT x TO y WITH SET TRUE, INHERIT FALSE`.
2. A new role membership is **not visible to privilege checks inside the transaction that granted
   it** — which is why `000_roles.sql` and `001_identity.sql` are separate files.
3. A non-superuser **cannot restate `NOSUPERUSER` / `NOBYPASSRLS`** even to turn them off. Assert
   attributes in a `DO` block instead.

**`FORCE ROW LEVEL SECURITY` applies to the schema owner too.** A `SECURITY DEFINER` function owned
by the owner runs against the owner-scoped policy with no owner context and is refused (`42501` on
`app_users`). Credential resolvers must be **created while acting as `swiftterm_resolver`**, not
created as the owner and handed over — a resolver-owned function can only be re-owned by the
resolver, which is not a member of the owner. `GRANT CREATE ON SCHEMA` to the resolver is
load-bearing for this.

**TLS.** `pg` verifies by default and this environment sits behind a TLS-intercepting proxy, so
`DATABASE_SSL_NO_VERIFY=1` is needed locally. It is refused when `NODE_ENV=production`. The correct
production answer is `PGSSLROOTCERT`.

**Swift/SwiftPM cannot build here.** `swift package` and `swift build` both fail: SwiftPM's manifest
compilation needs `sandbox-exec`, which is blocked. Harnesses using plain `swiftc` work, so use
`Scripts/run-tests.sh`. Related: `swift-plugin-server` cannot start, which breaks every source using
`@Observable` — `block-collapse-test`, `command-editor-undo-test` and `git-review-test` fail to
compile for that reason and did so before this work began (verified against a clean worktree).

**Node.** Managed is 22.22.2, system is 26.9.0; `.node-version` pins 24. Both run `.ts` directly, so
there is no build step anywhere — do not add one. `npm test` uses `--test-force-exit` because a
pooled socket can otherwise keep the process alive after the suite finishes.

**Commit signing works** (SSH, `gpg.format=ssh`). Use `git commit -s -S`.

---

## 4. The production server is shared — treat it carefully

`ubuntu@155.248.241.153`, key at `~/Downloads/ssh-key-2022-09-12.key`. **Nothing of ours is deployed
there.**

It already runs other projects: `traverse-backend`/`traverse-postgres`/`traverse-redis`,
`zoth-api`/`zoth-alerting`/`zoth-emitter`/`zoth-postgres`/`zoth-rabbitmq`, `podsync-app`,
`audiomuse-*`, `nginx-proxy-manager`, and nginx sites `hermes-dashboard`, `rpidash`,
`traverse-backend`. **Ports 80, 443, 81, 3000, 5432, 6379, 8080 and 8088 are all taken.** The git
identity on that box is `achubadyal4@gmail.com / YuanziX` — not the account this work belongs to.

Inbound HTTP genuinely is firewalled (80/443/8080 time out from outside even though the box listens
on them), so a tunnel really is required. SSH on 22 works.

**`zrok` is not installed** on the server or locally. **`cloudflared` already is** on the server
(`/usr/local/bin/cloudflared`), with an empty `~/.cloudflared` — a stable tunnel may be available
without a new install.

Before adding a service there, agree the port and the unit name with the human. Do not touch another
project's container, nginx site or database.

---

## 5. Open decisions only the human can make

1. **The website stack conflicts.** The handoff fixes the website as **TypeScript + Vite, DOM
   components and Canvas 2D, no React or UI framework for v1**. The human said to build on the
   existing `lqSky7/aside-clone` repo. If that repo is Next/React, one of the two has to give.
   **Inspect `aside-clone` before writing a line of website code** — an earlier clone attempt
   returned nothing, so this is still unresolved.
2. **Where the backend repo lives on GitLab.** `lqSky7/swiftterm` and `lqSky7/swiftterm-backend`
   both 404; no GitLab remote is configured. The only remote is GitHub.
3. **Secret rotation keys** — the last B1 production input not supplied.
4. **Supabase directly, or a dedicated Postgres container on the box.**

---

## 6. How to run and verify

```sh
# contracts (both halves of the C0 gate)
Scripts/run-tests.sh
node contracts/ts/check-fixtures.ts

# backend
cd backend
cp .env.example .env      # then fill it in; .env is gitignored, never commit it
npm install
npm run migrate           # migrations/*.sql in order
npm run provision-roles   # role logins from the environment
npm test                  # 17 checks against the live database
npm run typecheck
```

`.env` holds `DATABASE_URL` (the **API** role), `MIGRATION_DATABASE_URL`, `DATABASE_ADMIN_URL`,
`OIDC_*` and `DATABASE_SSL_NO_VERIFY`. It is gitignored; verify that before every commit.

---

## 7. Boundaries — these are the ones that matter

- **The API role cannot read a credential digest, and that must stay true.** It holds *column*
  privileges, not table privileges. If you need a digest, add a resolver function — never widen the
  grant.
- **Never `pool.query` inside a transaction.** One checked-out client, or the transaction silently
  splits across connections.
- **The owner context is transaction-local** (`set_config(..., true)`). A query that forgets to set
  it sees nothing rather than everything — that is the design, not a bug.
- **Auth never touches `app/src/terminal/**`.** It is not in B1B's allowlist. The terminal stays
  offline-capable and B1B's gate tests that it does zero cloud work when signed out.
- **Do not expose the local OS profile as a cloud identity.**
- **No stub authentication outside tests**, and `SWIFTTERM_TEST_FIXTURES` is refused in production.
- **No infrastructure provisioning without the named deployment inputs.**
- **Never commit a secret**, and never log a payload, a credential or an input's text.
