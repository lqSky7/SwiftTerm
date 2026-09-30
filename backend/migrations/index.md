# backend/migrations — index

Applied in filename order by `src/db/migrate.ts`, each file in its own transaction, recorded in
`swiftterm_meta.applied_migrations`. A file that fails rolls back whole and leaves the database
exactly as it was.

| File | Holds |
| --- | --- |
| `000_roles.sql` | the four roles, their memberships, the database-level `CREATE` grants and the attribute assertions |
| `001_identity.sql` | the eight tables, forced row-level security, the policies, the credential resolvers and every grant |

## Why 000 and 001 are separate files

PostgreSQL does not make a new role membership visible to privilege checks inside the transaction
that granted it. A single file that creates the roles and then tries to `SET ROLE` to one of them
fails with "must be able to SET ROLE". Two files, two transactions.

## Four things that are easy to get wrong here

**The resolver functions are created while acting as `swiftterm_resolver`.** A `SECURITY DEFINER`
function runs under its *owner's* policies, and `FORCE ROW LEVEL SECURITY` applies to the schema
owner too. A resolver function left owned by the owner runs against the owner-scoped policy with no
owner context set and is refused — observed as `42501` on `app_users` the first time the tests ran.
Creating them as the resolver also keeps the file re-runnable, because `CREATE OR REPLACE` needs
ownership and a function owned by the resolver can only be re-owned by the resolver.

**Ownership changes go last.** Once a function belongs to the resolver, the schema owner can no
longer grant or revoke on it.

**`GRANT CREATE ON SCHEMA` to the resolver is load-bearing.** PostgreSQL requires the new owner of
an object to hold `CREATE` on its schema. The role is `NOLOGIN`, so the grant is not reachable.

**`CREATE POLICY` is not idempotent.** Each one is preceded by `DROP POLICY IF EXISTS`, so the file
can be re-applied — which is also how the idempotency is proven: `001` is applied twice in the
verification run.

## Roles

| Role | Login | Holds |
| --- | --- | --- |
| `swiftterm_owner` | no | the schema and every object |
| `swiftterm_migrator` | yes, by provisioning | membership of the owner, so DDL runs as the owner |
| `swiftterm_api` | yes, by provisioning | column privileges on the tables, `EXECUTE` on the resolvers, no DDL |
| `swiftterm_resolver` | never | the `SECURITY DEFINER` credential resolvers |

`000_roles.sql` ends by asserting that none of the four holds `SUPERUSER`, `CREATEDB`, `CREATEROLE`
or `BYPASSRLS`, and that the resolver cannot log in. If a future PostgreSQL or Supabase change
altered those defaults the migration fails instead of shipping.
