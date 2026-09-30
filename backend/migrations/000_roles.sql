-- 000 — roles, memberships and role-level settings.
--
-- Run as the project admin role (`postgres` on Supabase), which holds CREATEROLE. Contains no
-- secrets: passwords are set separately by scripts/provision-roles.ts from the environment, so a
-- credential never enters version control.
--
-- Four roles, because one role that can do everything is the thing B1A exists to avoid:
--
--   swiftterm_owner     NOLOGIN. Owns the schema and every object. Cannot be logged into, so it
--                       cannot be used to read data; it exists so ownership is not the admin role.
--   swiftterm_migrator  NOLOGIN here, given LOGIN by provisioning. Member of the owner, so DDL runs
--                       as the owner. Holds no runtime credential and the server never uses it.
--   swiftterm_api       NOLOGIN here, given LOGIN by provisioning. The only credential the running
--                       service holds. No DDL, no BYPASSRLS, no superuser, no CREATEROLE.
--   swiftterm_resolver  NOLOGIN always. Owns the fixed-search-path SECURITY DEFINER functions that
--                       resolve a credential digest before an owner is known. Nobody can log in as
--                       it, so those functions are the only way to act as it.
--
-- The schema itself is created by 001, not here. PostgreSQL does not make a role's new membership
-- visible to privilege checks inside the transaction that granted it, so a file that creates the
-- roles and then tries to act as one fails. Separate files, separate transactions.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'swiftterm_owner') THEN
    CREATE ROLE swiftterm_owner NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'swiftterm_migrator') THEN
    CREATE ROLE swiftterm_migrator NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'swiftterm_api') THEN
    CREATE ROLE swiftterm_api NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'swiftterm_resolver') THEN
    CREATE ROLE swiftterm_resolver NOLOGIN;
  END IF;
END
$$;

-- `CREATE ROLE ... NOLOGIN` already implies NOSUPERUSER, NOCREATEDB, NOCREATEROLE and NOBYPASSRLS,
-- and PostgreSQL 16+ forbids a non-superuser from restating those attributes even to turn them
-- off. The properties are asserted at the end of this file instead.
ALTER ROLE swiftterm_owner NOINHERIT;

-- The migrator creates objects owned by the owner; the API and resolver never become the owner.
-- `SET TRUE` is required and is not what CREATE ROLE hands out: PostgreSQL 16+ grants a role's
-- creator ADMIN but not SET, so a role could administer these without being able to become them.
GRANT swiftterm_owner TO swiftterm_migrator WITH SET TRUE, INHERIT FALSE;

-- The owner must be able to hand a function to the resolver role. `FORCE ROW LEVEL SECURITY`
-- applies to the owner as well, so a SECURITY DEFINER function left owned by the owner would run
-- against the owner-scoped policies with no owner context set and be rejected. Ownership is what
-- decides which policies a SECURITY DEFINER body runs under, so this membership is load-bearing.
GRANT swiftterm_resolver TO swiftterm_owner WITH SET TRUE, INHERIT FALSE;

DO $$
DECLARE
  v_set boolean;
BEGIN
  SELECT m.set_option INTO v_set
    FROM pg_auth_members m
   WHERE m.roleid = 'swiftterm_owner'::regrole
     AND m.member = current_user::regrole;
  IF v_set IS NULL OR v_set = false THEN
    EXECUTE format('GRANT swiftterm_owner TO %I WITH SET TRUE, INHERIT FALSE', current_user);
  END IF;
END
$$;

-- The owner role needs CREATE on the database before it can make its own schema, and the migrator
-- needs it for its `swiftterm_meta` bookkeeping. Granted here rather than left to the admin role's
-- inherited authority, so each role's reach is stated in one place and is exactly this.
DO $$
BEGIN
  EXECUTE format(
    'GRANT CREATE ON DATABASE %I TO swiftterm_owner, swiftterm_migrator', current_database());
END
$$;

-- Nothing may create objects in `public`. Supabase grants CREATE there to PUBLIC by default, which
-- is how a compromised API credential would drop a table it was never meant to touch.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- A session must not be able to reach another schema by guessing at search_path.
ALTER ROLE swiftterm_api SET search_path = swiftterm, pg_temp;
ALTER ROLE swiftterm_migrator SET search_path = swiftterm, pg_temp;
ALTER ROLE swiftterm_resolver SET search_path = swiftterm, pg_temp;

-- Assert the design rather than trusting defaults. If a future PostgreSQL or Supabase change hands
-- any of these roles a privileged attribute, this migration fails instead of shipping.
DO $$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(
           rolname || '(' || concat_ws(',',
             CASE WHEN rolsuper THEN 'SUPERUSER' END,
             CASE WHEN rolcreatedb THEN 'CREATEDB' END,
             CASE WHEN rolcreaterole THEN 'CREATEROLE' END,
             CASE WHEN rolbypassrls THEN 'BYPASSRLS' END) || ')', ', ')
    INTO v_bad
    FROM pg_roles
   WHERE rolname LIKE 'swiftterm%'
     AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolbypassrls);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'swiftterm role holds a privileged attribute: %', v_bad;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'swiftterm_resolver' AND rolcanlogin) THEN
    RAISE EXCEPTION 'swiftterm_resolver must never be able to log in';
  END IF;
END
$$;
