# backend/migrations — index

Applied in filename order by `src/db/migrate.ts`, each file in its own transaction, recorded in
`swiftterm_meta.applied_migrations`. A file that fails rolls back whole and leaves the database
exactly as it was.

| File | Holds |
| --- | --- |
| `000_roles.sql` | the four roles, their memberships, the database-level `CREATE` grants and the attribute assertions |
| `001_identity.sql` | the eight tables, forced row-level security, the policies, the credential resolvers and every grant |
| `002_live.sql` | the live-session control plane: create, list, read, admit a publisher, renew, release, end, and end-a-device's-streams |

## Why 000 and 001 are separate files

PostgreSQL does not make a new role membership visible to privilege checks inside the transaction
that granted it. A single file that creates the roles and then tries to `SET ROLE` to one of them
fails with "must be able to SET ROLE". Two files, two transactions.

## Who applies what

`000` needs `CREATEROLE`, so it is the one file the migrator cannot run — it is applied by the
project admin. The rest run as the migrator. `MIGRATION_DATABASE_URL` points at the migrator; running
`src/db/migrate.ts` with `MIGRATION_DATABASE_URL="$DATABASE_ADMIN_URL"` applies the whole chain as
the admin, which is how a fresh environment is built. Objects still end up owned by
`swiftterm_owner`, because every file begins with `SET ROLE swiftterm_owner`.

`swiftterm_meta` is created and owned by whichever role first ran the migrator, so the other role
cannot read the tracker without a grant. On this deployment the tracker is written by the migrator;
`002` was applied by the admin and its row inserted by the migrator.

## Four things that are easy to get wrong here

**The grants are the part whose absence is silent.** `001`'s grant section is what makes "the API
cannot read a credential digest" true at the database rather than in a code review. Without it every
statement still applies cleanly and the service fails at runtime with `42501`. It was in fact lost
once during a restructure, and nothing noticed because `GRANT` and `REVOKE` are not exercised by
applying the file. The way to check a change here is to **diff the resulting ACLs** —
`pg_class.relacl`, `pg_attribute.attacl`, `pg_namespace.nspacl`, `pg_proc.proacl` — against the
previous state, not to read the exit code.

**The resolver functions are created while acting as `swiftterm_resolver`.** A `SECURITY DEFINER`
function runs under its *owner's* policies, and `FORCE ROW LEVEL SECURITY` applies to the schema
owner too. A resolver function left owned by the owner runs against the owner-scoped policy with no
owner context set and is refused — observed as `42501` on `app_users` the first time the tests ran.
Creating them as the resolver also keeps the file re-runnable, because `CREATE OR REPLACE` needs
ownership and a function owned by the resolver can only be re-owned by the resolver.

**`002`'s functions are `SECURITY INVOKER`, deliberately.** The API already holds table privileges on
`live_sessions` and the caller's transaction sets the owner context, so `live_owner` scopes every row
they touch. Elevating them to the resolver would widen what the credential-resolver role can reach
for no benefit.

**`CREATE POLICY` is not idempotent.** Each one is preceded by `DROP POLICY IF EXISTS`, so the files
can be re-applied — which is also how idempotency is proven: `001` and `002` are each applied twice
in the verification run.

## Roles

| Role | Login | Holds |
| --- | --- | --- |
| `swiftterm_owner` | no | the schema and every object |
| `swiftterm_migrator` | yes, by provisioning | membership of the owner, so DDL runs as the owner |
| `swiftterm_api` | yes, by provisioning | column privileges on the tables, `EXECUTE` on the functions, no DDL |
| `swiftterm_resolver` | never | the `SECURITY DEFINER` credential resolvers |

`000_roles.sql` ends by asserting that none of the four holds `SUPERUSER`, `CREATEDB`, `CREATEROLE`
or `BYPASSRLS`, and that the resolver cannot log in. If a future PostgreSQL or Supabase change
altered those defaults the migration fails instead of shipping.

## The advisory lock in `002`

`create_live_session` serialises per account with `pg_advisory_xact_lock(21335, hashtext(owner_id))`
rather than `SELECT ... FOR UPDATE` on `app_users`. That is not a preference: the API holds no
`UPDATE` privilege on `app_users` — only column-level `SELECT` — so a row lock there is not available
to it at all. An advisory lock keyed by the owner gives the same mutual exclusion without needing a
write privilege on the account. It is `_xact_`, so it is released at `COMMIT` and cannot leak onto a
pooled connection.
