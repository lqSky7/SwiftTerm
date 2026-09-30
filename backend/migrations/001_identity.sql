-- 001 — identity and database foundation.
--
-- Derived from docs/backend/schema.sql. Run by the migrator (a member of swiftterm_owner), which
-- is why the file starts by becoming the owner: objects are then owned by swiftterm_owner rather
-- than by whichever admin role happened to apply the migration.
--
-- Everything below is namespaced into `swiftterm`. Nothing here touches `auth`, `storage` or
-- `public`, so applying this to a Supabase project cannot disturb its managed schemas.

-- Created here rather than in 000: the membership that makes SET ROLE possible is not visible to
-- privilege checks inside the transaction that granted it, so role creation and schema creation
-- have to be separate transactions.
SET ROLE swiftterm_owner;

CREATE SCHEMA IF NOT EXISTS swiftterm;

-- PostgreSQL requires the new owner of an object to hold CREATE on its schema, so the resolver
-- needs this before the functions can be handed to it below. It is not reachable in practice:
-- swiftterm_resolver is NOLOGIN and cannot be connected to, so the only way to act as it is
-- through the fixed functions that are granted to the API. The alternative — leaving the
-- credential functions owned by the schema owner — does not work at all, because forced row-level
-- security applies to the owner too.
GRANT CREATE ON SCHEMA swiftterm TO swiftterm_resolver;

-- Reaching the schema at all is a separate privilege from reaching anything in it, and a role with
-- neither sees "schema does not exist" rather than "permission denied", which is a confusing way to
-- discover a missing grant. Stated here for every role that has business in this schema.
GRANT USAGE ON SCHEMA swiftterm TO swiftterm_api, swiftterm_migrator, swiftterm_resolver;

-- The managed `auth`, `storage` and `extensions` schemas are left exactly as Supabase configured
-- them. Revoking their grants would break Supabase's own Auth flows, and this migration has no
-- business reaching outside its own schema.

-- The transaction-local owner context. `true` means it lasts only for the transaction, which is
-- what makes it safe on a pooled connection: the value cannot leak into the next request that
-- borrows the same backend.
CREATE OR REPLACE FUNCTION swiftterm.request_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('swiftterm.user_id', true), '')::uuid
$$;

-- MARK: - Tables

CREATE TABLE IF NOT EXISTS swiftterm.app_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_issuer text NOT NULL CHECK (octet_length(auth_issuer) BETWEEN 1 AND 2048),
  auth_subject text NOT NULL CHECK (octet_length(auth_subject) BETWEEN 1 AND 512),
  display_name text NOT NULL DEFAULT '' CHECK (octet_length(display_name) <= 256),
  created_at timestamptz NOT NULL DEFAULT now(),
  deactivated_at timestamptz,
  UNIQUE (auth_issuer, auth_subject)
);

CREATE TABLE IF NOT EXISTS swiftterm.web_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES swiftterm.app_users(id) ON DELETE CASCADE,
  token_sha256 bytea NOT NULL UNIQUE CHECK (octet_length(token_sha256) = 32),
  csrf_sha256 bytea NOT NULL CHECK (octet_length(csrf_sha256) = 32),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
  revoked_at timestamptz,
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '24 hours'),
  UNIQUE (owner_id, id)
);
CREATE INDEX IF NOT EXISTS web_session_owner
  ON swiftterm.web_sessions(owner_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS web_session_expiry ON swiftterm.web_sessions(expires_at, id);

CREATE TABLE IF NOT EXISTS swiftterm.devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES swiftterm.app_users(id) ON DELETE CASCADE,
  label text NOT NULL CHECK (octet_length(label) BETWEEN 1 AND 256),
  client_request_id uuid NOT NULL,
  registration_sha256 bytea NOT NULL CHECK (octet_length(registration_sha256) = 32),
  token_sha256 bytea NOT NULL UNIQUE CHECK (octet_length(token_sha256) = 32),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  UNIQUE (owner_id, client_request_id),
  UNIQUE (owner_id, id)
);

CREATE TABLE IF NOT EXISTS swiftterm.live_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL,
  device_id uuid NOT NULL,
  local_pane_id uuid NOT NULL,
  client_request_id uuid NOT NULL,
  request_sha256 bytea NOT NULL CHECK (octet_length(request_sha256) = 32),
  title text NOT NULL DEFAULT '' CHECK (octet_length(title) <= 512),
  status text NOT NULL DEFAULT 'paused' CHECK (status IN ('paused', 'live', 'ended')),
  publisher_epoch bigint NOT NULL DEFAULT 0 CHECK (publisher_epoch >= 0),
  publisher_lease_token uuid,
  publisher_lease_expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
  ended_at timestamptz,
  CHECK (expires_at > created_at),
  CHECK ((status = 'live') = (publisher_lease_token IS NOT NULL AND publisher_lease_expires_at IS NOT NULL)),
  CHECK ((publisher_lease_token IS NULL) = (publisher_lease_expires_at IS NULL)),
  CHECK (status <> 'live' OR publisher_epoch > 0),
  CHECK ((status = 'ended') = (ended_at IS NOT NULL)),
  FOREIGN KEY (owner_id, device_id) REFERENCES swiftterm.devices(owner_id, id) ON DELETE CASCADE,
  UNIQUE (owner_id, id),
  UNIQUE (owner_id, client_request_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS one_open_stream_per_pane
  ON swiftterm.live_sessions(device_id, local_pane_id) WHERE status <> 'ended';
CREATE INDEX IF NOT EXISTS live_owner_page
  ON swiftterm.live_sessions(owner_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS live_device ON swiftterm.live_sessions(device_id);
CREATE INDEX IF NOT EXISTS live_ended_retention
  ON swiftterm.live_sessions(ended_at, id) WHERE status = 'ended';
CREATE INDEX IF NOT EXISTS live_lease_expiry
  ON swiftterm.live_sessions(publisher_lease_expires_at, id) WHERE status = 'live';
CREATE INDEX IF NOT EXISTS live_expiry
  ON swiftterm.live_sessions(expires_at, id) WHERE status <> 'ended';

CREATE TABLE IF NOT EXISTS swiftterm.live_session_grants (
  owner_id uuid NOT NULL,
  session_id uuid NOT NULL,
  recipient_user_id uuid NOT NULL REFERENCES swiftterm.app_users(id) ON DELETE CASCADE,
  permission text NOT NULL CHECK (permission IN ('viewer', 'controller')),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  PRIMARY KEY (session_id, recipient_user_id),
  FOREIGN KEY (owner_id, session_id) REFERENCES swiftterm.live_sessions(owner_id, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS live_grants_recipient
  ON swiftterm.live_session_grants(recipient_user_id) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS swiftterm.block_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES swiftterm.app_users(id) ON DELETE CASCADE,
  schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version = 1),
  blocks jsonb NOT NULL CHECK (jsonb_typeof(blocks) = 'array'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (jsonb_array_length(blocks) BETWEEN 1 AND 20),
  CHECK (octet_length(blocks::text) <= 2097152),
  UNIQUE (owner_id, id)
);

CREATE TABLE IF NOT EXISTS swiftterm.share_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL,
  snapshot_id uuid NOT NULL,
  public_locator uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  secret_sha256 bytea NOT NULL UNIQUE CHECK (octet_length(secret_sha256) = 32),
  access_mode text NOT NULL CHECK (access_mode IN ('link', 'restricted')),
  client_request_id uuid NOT NULL,
  request_sha256 bytea NOT NULL CHECK (octet_length(request_sha256) = 32),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  CHECK (expires_at IS NULL OR expires_at > created_at),
  FOREIGN KEY (owner_id, snapshot_id) REFERENCES swiftterm.block_snapshots(owner_id, id) ON DELETE CASCADE,
  UNIQUE (owner_id, id),
  UNIQUE (owner_id, client_request_id)
);
CREATE INDEX IF NOT EXISTS shares_owner_page
  ON swiftterm.share_links(owner_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS shares_snapshot ON swiftterm.share_links(snapshot_id);
CREATE INDEX IF NOT EXISTS shares_expiry
  ON swiftterm.share_links(expires_at, id) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS swiftterm.share_grants (
  owner_id uuid NOT NULL,
  share_id uuid NOT NULL,
  recipient_user_id uuid NOT NULL REFERENCES swiftterm.app_users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (share_id, recipient_user_id),
  FOREIGN KEY (owner_id, share_id) REFERENCES swiftterm.share_links(owner_id, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS grants_recipient ON swiftterm.share_grants(recipient_user_id);

-- MARK: - Row level security

ALTER TABLE swiftterm.app_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.app_users FORCE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.web_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.web_sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.devices FORCE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.live_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.live_sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.live_session_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.live_session_grants FORCE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.block_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.block_snapshots FORCE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.share_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.share_links FORCE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.share_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.share_grants FORCE ROW LEVEL SECURITY;

-- Owner-scoped policies. Every private row carries owner_id and the policy compares it with the
-- transaction-local context, so a query that forgets to set the context sees nothing rather than
-- everything.
DROP POLICY IF EXISTS user_self ON swiftterm.app_users;
CREATE POLICY user_self ON swiftterm.app_users
  USING (id = swiftterm.request_user_id()) WITH CHECK (id = swiftterm.request_user_id());
DROP POLICY IF EXISTS web_session_owner ON swiftterm.web_sessions;
CREATE POLICY web_session_owner ON swiftterm.web_sessions
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
DROP POLICY IF EXISTS device_owner ON swiftterm.devices;
CREATE POLICY device_owner ON swiftterm.devices
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
DROP POLICY IF EXISTS live_owner ON swiftterm.live_sessions;
CREATE POLICY live_owner ON swiftterm.live_sessions
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
DROP POLICY IF EXISTS live_grant_owner ON swiftterm.live_session_grants;
CREATE POLICY live_grant_owner ON swiftterm.live_session_grants
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
DROP POLICY IF EXISTS snapshot_owner ON swiftterm.block_snapshots;
CREATE POLICY snapshot_owner ON swiftterm.block_snapshots
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
DROP POLICY IF EXISTS share_owner ON swiftterm.share_links;
CREATE POLICY share_owner ON swiftterm.share_links
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
DROP POLICY IF EXISTS grant_owner ON swiftterm.share_grants;
CREATE POLICY grant_owner ON swiftterm.share_grants
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());

-- The pre-owner lookup problem, solved without turning RLS off.
--
-- Resolving a session or a device credential happens *before* an owner is known, so the
-- owner-scoped policy above would correctly return nothing. Rather than disabling RLS, these
-- policies grant exactly the three tables to swiftterm_resolver — a role that is NOLOGIN and
-- therefore cannot be connected to at all. The only way to act as it is through the SECURITY
-- DEFINER functions below, each of which has a fixed search_path and does one narrow lookup.
-- RLS stays enabled and forced for every other role, including the owner.
DROP POLICY IF EXISTS app_user_resolver ON swiftterm.app_users;
CREATE POLICY app_user_resolver ON swiftterm.app_users
  FOR SELECT TO swiftterm_resolver USING (true);
DROP POLICY IF EXISTS app_user_provision ON swiftterm.app_users;
-- Account deletion is deliberately not an API capability: swiftterm_api holds no DELETE grant on
-- app_users at all. It belongs to the owner role, which is NOLOGIN and reachable only by SET ROLE
-- from the migrator or the project admin. B6A's maintenance role is the intended long-term user of
-- this path; until then it is what lets a test or an operator purge a fixture.
DROP POLICY IF EXISTS app_user_owner_maintenance ON swiftterm.app_users;
CREATE POLICY app_user_owner_maintenance ON swiftterm.app_users
  FOR DELETE TO swiftterm_owner USING (true);

CREATE POLICY app_user_provision ON swiftterm.app_users
  FOR INSERT TO swiftterm_resolver WITH CHECK (true);
DROP POLICY IF EXISTS web_session_resolver ON swiftterm.web_sessions;
CREATE POLICY web_session_resolver ON swiftterm.web_sessions
  FOR ALL TO swiftterm_resolver USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS device_resolver ON swiftterm.devices;
CREATE POLICY device_resolver ON swiftterm.devices
  FOR ALL TO swiftterm_resolver USING (true) WITH CHECK (true);

-- MARK: - Grants (as the owner)
--
-- This section is why "the API cannot read a credential digest" is a property of the database
-- rather than a promise in a code review. It is also the section whose absence is easiest to miss:
-- without it every statement below still applies cleanly and the service simply fails at runtime
-- with 42501, so the migration is verified by diffing the resulting ACLs and not by exit code.
--
-- The API is granted **column** privileges, never table privileges, on the three credential
-- tables. `has_table_privilege('swiftterm_api', 'swiftterm.web_sessions', 'SELECT')` is therefore
-- false while `SELECT id, expires_at FROM swiftterm.web_sessions` succeeds — the difference is
-- exactly the columns a handler needs versus `token_sha256`, `csrf_sha256` and `auth_issuer`,
-- which the API holds no privilege on at all.

REVOKE ALL ON ALL TABLES IN SCHEMA swiftterm FROM PUBLIC, swiftterm_api, swiftterm_resolver;

-- The resolver reads and writes the credential tables in full. That is safe because it is NOLOGIN:
-- the only way to act as it is through the fixed-search-path functions handed to the API below,
-- each of which does one narrow lookup.
GRANT SELECT, INSERT, UPDATE ON swiftterm.app_users TO swiftterm_resolver;
GRANT SELECT, INSERT, UPDATE ON swiftterm.web_sessions TO swiftterm_resolver;
GRANT SELECT, INSERT, UPDATE ON swiftterm.devices TO swiftterm_resolver;

-- The API reads the account row it is already authenticated as, and can revoke a session or a
-- device but not create one directly — creation goes through the resolver functions so the digest
-- is written in one place.
GRANT SELECT (id, display_name, created_at, deactivated_at)
  ON swiftterm.app_users TO swiftterm_api;
GRANT SELECT (id, owner_id, created_at, expires_at, revoked_at)
  ON swiftterm.web_sessions TO swiftterm_api;
GRANT UPDATE (revoked_at) ON swiftterm.web_sessions TO swiftterm_api;
GRANT SELECT (id, owner_id, label, client_request_id, created_at, revoked_at)
  ON swiftterm.devices TO swiftterm_api;
GRANT UPDATE (revoked_at) ON swiftterm.devices TO swiftterm_api;

-- Live sessions are ordinary owner-scoped data: the API creates, reads, updates and ends its own
-- rows, and the `live_owner` policy above is what stops it touching anyone else's.
GRANT SELECT, INSERT, UPDATE, DELETE ON swiftterm.live_sessions TO swiftterm_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON swiftterm.live_session_grants TO swiftterm_api;

-- Snapshots are immutable, and that is enforced by grant rather than by discipline: there is no
-- UPDATE privilege on block_snapshots for any role but the owner, so editing an export has to
-- create a new snapshot. The same rule applies to a share's grants.
GRANT SELECT, INSERT, DELETE ON swiftterm.block_snapshots TO swiftterm_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON swiftterm.share_links TO swiftterm_api;
GRANT SELECT, INSERT, DELETE ON swiftterm.share_grants TO swiftterm_api;

-- The owner context function is called by every policy expression above, so it is granted to the
-- API explicitly and revoked from PUBLIC. The resolver is deliberately not granted it: the three
-- resolver policies are `true`, so a resolver-owned body never evaluates an owner comparison.
REVOKE ALL ON FUNCTION swiftterm.request_user_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.request_user_id() TO swiftterm_api;

-- MARK: - Credential resolution, created as the resolver
--
-- These functions are created while acting as swiftterm_resolver rather than created as the owner
-- and handed over afterwards. Ownership is what decides which policies a SECURITY DEFINER body runs
-- under, and it has to be right from the start:
--
--   * Owned by the schema owner, each function would run against the owner-scoped policies with no
--     owner context set and be refused. Forced row-level security applies to the owner too, so
--     this is not a theoretical concern — it is what the first run of the test suite reported, as a
--     42501 on app_users.
--   * Handing them over afterwards does not work either: a function owned by the resolver can only
--     be re-owned by the resolver, and the resolver is not a member of the owner.
--
-- Created here, they run under the three narrow resolver policies above and nothing else, and the
-- file stays re-runnable because `CREATE OR REPLACE` is executed by the owning role.

SET ROLE swiftterm_resolver;

CREATE OR REPLACE FUNCTION swiftterm.resolve_web_session(p_token_sha256 bytea)
RETURNS TABLE (
  session_id uuid,
  owner_id uuid,
  csrf_sha256 bytea,
  expires_at timestamptz,
  revoked_at timestamptz,
  account_deactivated_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = swiftterm, pg_temp
AS $$
  SELECT s.id, s.owner_id, s.csrf_sha256, s.expires_at, s.revoked_at, u.deactivated_at
    FROM swiftterm.web_sessions s
    JOIN swiftterm.app_users u ON u.id = s.owner_id
   WHERE s.token_sha256 = p_token_sha256
$$;

CREATE OR REPLACE FUNCTION swiftterm.resolve_device(p_token_sha256 bytea)
RETURNS TABLE (
  device_id uuid,
  owner_id uuid,
  label text,
  revoked_at timestamptz,
  account_deactivated_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = swiftterm, pg_temp
AS $$
  SELECT d.id, d.owner_id, d.label, d.revoked_at, u.deactivated_at
    FROM swiftterm.devices d
    JOIN swiftterm.app_users u ON u.id = d.owner_id
   WHERE d.token_sha256 = p_token_sha256
$$;

-- Creates the account row for a verified issuer/subject pair, or returns the existing one. The
-- issuer and subject come from a verified token, never from request JSON.
CREATE OR REPLACE FUNCTION swiftterm.provision_app_user(
  p_issuer text,
  p_subject text,
  p_display_name text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = swiftterm, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  SELECT id INTO v_id FROM swiftterm.app_users
   WHERE auth_issuer = p_issuer AND auth_subject = p_subject;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO swiftterm.app_users (auth_issuer, auth_subject, display_name)
       VALUES (p_issuer, p_subject, left(p_display_name, 256))
    ON CONFLICT (auth_issuer, auth_subject) DO NOTHING
    RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM swiftterm.app_users
     WHERE auth_issuer = p_issuer AND auth_subject = p_subject;
  END IF;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION swiftterm.create_web_session(
  p_owner_id uuid,
  p_token_sha256 bytea,
  p_csrf_sha256 bytea,
  p_ttl interval DEFAULT interval '24 hours'
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = swiftterm, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO swiftterm.web_sessions (owner_id, token_sha256, csrf_sha256, expires_at)
       VALUES (p_owner_id, p_token_sha256, p_csrf_sha256, now() + least(p_ttl, interval '24 hours'))
    RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

-- Device registration with client_request_id idempotency. An identical retry returns the device
-- that already exists; a changed payload is reported as a conflict so the caller can answer 409
-- instead of silently minting a second credential.
CREATE OR REPLACE FUNCTION swiftterm.register_device(
  p_owner_id uuid,
  p_label text,
  p_client_request_id uuid,
  p_registration_sha256 bytea,
  p_token_sha256 bytea
) RETURNS TABLE (device_id uuid, stored_registration_sha256 bytea, created boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = swiftterm, pg_temp
AS $$
DECLARE
  v_row swiftterm.devices;
BEGIN
  INSERT INTO swiftterm.devices
    (owner_id, label, client_request_id, registration_sha256, token_sha256)
  VALUES
    (p_owner_id, left(p_label, 256), p_client_request_id, p_registration_sha256, p_token_sha256)
  ON CONFLICT (owner_id, client_request_id) DO NOTHING
  RETURNING * INTO v_row;

  IF v_row.id IS NOT NULL THEN
    RETURN QUERY SELECT v_row.id, v_row.registration_sha256, true;
    RETURN;
  END IF;

  SELECT * INTO v_row FROM swiftterm.devices
   WHERE owner_id = p_owner_id AND client_request_id = p_client_request_id;
  RETURN QUERY SELECT v_row.id, v_row.registration_sha256, false;
END
$$;

CREATE OR REPLACE FUNCTION swiftterm.revoke_web_session(p_owner_id uuid, p_session_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = swiftterm, pg_temp
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE swiftterm.web_sessions SET revoked_at = now()
   WHERE id = p_session_id AND owner_id = p_owner_id AND revoked_at IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count > 0;
END
$$;

CREATE OR REPLACE FUNCTION swiftterm.revoke_device(p_owner_id uuid, p_device_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = swiftterm, pg_temp
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE swiftterm.devices SET revoked_at = now()
   WHERE id = p_device_id AND owner_id = p_owner_id AND revoked_at IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count > 0;
END
$$;

REVOKE ALL ON FUNCTION swiftterm.resolve_web_session(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.resolve_web_session(bytea) TO swiftterm_api;
REVOKE ALL ON FUNCTION swiftterm.resolve_device(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.resolve_device(bytea) TO swiftterm_api;
REVOKE ALL ON FUNCTION swiftterm.provision_app_user(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.provision_app_user(text, text, text) TO swiftterm_api;
REVOKE ALL ON FUNCTION swiftterm.create_web_session(uuid, bytea, bytea, interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.create_web_session(uuid, bytea, bytea, interval) TO swiftterm_api;
REVOKE ALL ON FUNCTION swiftterm.register_device(uuid, text, uuid, bytea, bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.register_device(uuid, text, uuid, bytea, bytea) TO swiftterm_api;
REVOKE ALL ON FUNCTION swiftterm.revoke_web_session(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.revoke_web_session(uuid, uuid) TO swiftterm_api;
REVOKE ALL ON FUNCTION swiftterm.revoke_device(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.revoke_device(uuid, uuid) TO swiftterm_api;

RESET ROLE;
