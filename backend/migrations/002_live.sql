-- 002 — the live-session control plane.
--
-- The tables already exist: 001 creates all eight from schema.sql, including `live_sessions` and
-- `live_session_grants`, with row-level security enabled and forced. What 001 does *not* provide is
-- the set of operations the relay's HTTP routes need, and those are all multi-step. They live in
-- functions for three reasons:
--
--   * **They are serialised.** Creating a stream has to check three limits and then insert. Check-
--     then-insert without a lock is a race, and the fix is a transaction-scoped advisory lock taken
--     inside the same transaction as the insert.
--   * **They are one round trip.** A publisher admission reads a row, compares five conditions and
--     writes three columns. Doing that from TypeScript means either a `SELECT ... FOR UPDATE` held
--     across round trips, or a read-then-write race.
--   * **They return an outcome, not an exception.** A refusal is an ordinary result — `account_limit`
--     is not an error, it is a 429 — so the caller never has to parse a message to decide a status.
--
-- **These are SECURITY INVOKER, deliberately.** The API already holds table privileges on
-- `live_sessions` and the owner context is set by the caller's transaction, so `live_owner` scopes
-- every row these functions touch. Elevating them to the resolver's identity would widen what the
-- credential-resolver role can reach for no benefit — and the resolver exists for exactly one job,
-- reading a digest before an owner is known.
--
-- **No `OUT` parameter is named after a column of the same function's body.** A PL/pgSQL output
-- parameter is a variable in scope for the whole body, so an output column called `status` makes
-- every unqualified `status` in the body ambiguous — which is not a warning but `42702`, raised at
-- run time on the first statement that touches it. Hence `session_status` and `admitted_epoch`
-- rather than `status` and `publisher_epoch`, and a table alias everywhere else.
--
-- Time is not a parameter. Every deadline here is `now()`, because the database is the only clock
-- both the relay and a second relay instance would agree on.

SET ROLE swiftterm_owner;

-- Drop this file's functions before recreating them.
--
-- `CREATE OR REPLACE FUNCTION` cannot change a function's return type, and for a `RETURNS TABLE`
-- function the output column list *is* the return type — so renaming an output column, which is
-- exactly what the shadowing fix below required, makes `CREATE OR REPLACE` fail with "cannot change
-- return type of existing function". Dropping first makes the file re-runnable under any signature
-- change rather than only under a body change, and the grants are reissued at the end of the file.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS signature
      FROM pg_proc p
     WHERE p.pronamespace = 'swiftterm'::regnamespace
       AND p.proname IN (
         'create_live_session', 'list_live_sessions', 'read_live_session',
         'admit_publisher', 'renew_publisher_lease', 'release_publisher_lease',
         'end_live_session', 'end_device_sessions'
       )
  LOOP
    EXECUTE format('DROP FUNCTION %s', r.signature);
  END LOOP;
END
$$;

-- MARK: - Session lifecycle

-- Create a stream, or return the one an identical retry already made.
--
-- The advisory lock is the account-level serialisation the handoff asks for ("lock account row for
-- admission limits"). It is an advisory lock rather than `SELECT ... FOR UPDATE` on `app_users`
-- because the API holds no UPDATE privilege on that table — only column-level SELECT — so a row
-- lock there is not available to it at all. A transaction-scoped advisory lock keyed by the owner
-- gives the same mutual exclusion without needing a write privilege on the account.
--
-- The lock is `_xact_`, so it is released at COMMIT or ROLLBACK and cannot leak onto a pooled
-- connection. The key is two int4s: a fixed class id for "stream admission", and a hash of the
-- owner. Different accounts never block each other.
CREATE OR REPLACE FUNCTION swiftterm.create_live_session(
  p_owner_id uuid,
  p_device_id uuid,
  p_local_pane_id uuid,
  p_client_request_id uuid,
  p_request_sha256 bytea,
  p_title text DEFAULT '',
  p_max_streams int DEFAULT 5
) RETURNS TABLE (outcome text, session_id uuid, session_epoch bigint, session_status text)
LANGUAGE plpgsql
SET search_path = swiftterm, pg_temp
AS $$
DECLARE
  v_row swiftterm.live_sessions;
  v_open int;
BEGIN
  IF octet_length(p_request_sha256) <> 32 THEN
    RAISE EXCEPTION 'request digest must be 32 bytes';
  END IF;

  -- Class id 0x5357 ('SW') is this application's advisory-lock namespace.
  PERFORM pg_advisory_xact_lock(21335, hashtext(p_owner_id::text));

  -- Idempotency is checked before anything else, which is what makes a retry cheap and a conflict
  -- unambiguous: the same request id with the same payload returns the same session, and with a
  -- different payload is a conflict rather than a second session.
  SELECT * INTO v_row FROM swiftterm.live_sessions
   WHERE owner_id = p_owner_id AND client_request_id = p_client_request_id;

  IF v_row.id IS NOT NULL THEN
    IF v_row.request_sha256 <> p_request_sha256 THEN
      RETURN QUERY SELECT 'conflict'::text, v_row.id, v_row.publisher_epoch, v_row.status;
    ELSE
      RETURN QUERY SELECT 'existing'::text, v_row.id, v_row.publisher_epoch, v_row.status;
    END IF;
    RETURN;
  END IF;

  -- A revoked device cannot publish. Checked here as well as by the foreign key, because the key
  -- proves the device belongs to the owner and says nothing about whether it was revoked.
  IF NOT EXISTS (
    SELECT 1 FROM swiftterm.devices d
     WHERE d.id = p_device_id AND d.owner_id = p_owner_id AND d.revoked_at IS NULL
  ) THEN
    RETURN QUERY SELECT 'device_unknown'::text, NULL::uuid, NULL::bigint, NULL::text;
    RETURN;
  END IF;

  -- One open stream per pane. The partial unique index `one_open_stream_per_pane` would catch this
  -- too, but as a 23505 the caller would have to translate; reporting it as an outcome keeps the
  -- refusal a normal answer. The index is what makes it true under concurrency.
  IF EXISTS (
    SELECT 1 FROM swiftterm.live_sessions s
     WHERE s.device_id = p_device_id AND s.local_pane_id = p_local_pane_id AND s.status <> 'ended'
  ) THEN
    RETURN QUERY SELECT 'pane_shared'::text, NULL::uuid, NULL::bigint, NULL::text;
    RETURN;
  END IF;

  SELECT count(*) INTO v_open FROM swiftterm.live_sessions s
   WHERE s.owner_id = p_owner_id AND s.status <> 'ended';

  IF v_open >= greatest(p_max_streams, 1) THEN
    RETURN QUERY SELECT 'account_limit'::text, NULL::uuid, NULL::bigint, NULL::text;
    RETURN;
  END IF;

  INSERT INTO swiftterm.live_sessions
    (owner_id, device_id, local_pane_id, client_request_id, request_sha256, title)
  VALUES
    (p_owner_id, p_device_id, p_local_pane_id, p_client_request_id, p_request_sha256,
     left(coalesce(p_title, ''), 512))
  RETURNING * INTO v_row;

  RETURN QUERY SELECT 'created'::text, v_row.id, v_row.publisher_epoch, v_row.status;
END
$$;

-- The owner's streams, newest first, keyset-paged by `(created_at, id)`.
--
-- Keyset rather than OFFSET: a session created between two pages would shift every later row and
-- silently skip one, which for a list whose rows are live streams is a real omission rather than a
-- cosmetic one.
CREATE OR REPLACE FUNCTION swiftterm.list_live_sessions(
  p_owner_id uuid,
  p_before_created_at timestamptz DEFAULT NULL,
  p_before_id uuid DEFAULT NULL,
  p_limit int DEFAULT 50
) RETURNS TABLE (
  id uuid,
  device_id uuid,
  local_pane_id uuid,
  title text,
  status text,
  publisher_epoch bigint,
  created_at timestamptz,
  expires_at timestamptz,
  ended_at timestamptz
)
LANGUAGE sql STABLE
SET search_path = swiftterm, pg_temp
AS $$
  SELECT s.id, s.device_id, s.local_pane_id, s.title, s.status,
         s.publisher_epoch, s.created_at, s.expires_at, s.ended_at
    FROM swiftterm.live_sessions s
   WHERE s.owner_id = p_owner_id
     AND (p_before_created_at IS NULL
          OR (s.created_at, s.id) < (p_before_created_at, p_before_id))
   ORDER BY s.created_at DESC, s.id DESC
   LIMIT least(greatest(coalesce(p_limit, 50), 1), 100)
$$;

CREATE OR REPLACE FUNCTION swiftterm.read_live_session(
  p_owner_id uuid,
  p_session_id uuid
) RETURNS TABLE (
  id uuid,
  device_id uuid,
  local_pane_id uuid,
  title text,
  status text,
  publisher_epoch bigint,
  created_at timestamptz,
  expires_at timestamptz,
  ended_at timestamptz
)
LANGUAGE sql STABLE
SET search_path = swiftterm, pg_temp
AS $$
  SELECT s.id, s.device_id, s.local_pane_id, s.title, s.status,
         s.publisher_epoch, s.created_at, s.expires_at, s.ended_at
    FROM swiftterm.live_sessions s
   WHERE s.id = p_session_id AND s.owner_id = p_owner_id
$$;

-- MARK: - Publisher fencing

-- Admit a publisher, or explain why not.
--
-- This is the fence the whole control plane exists for. The row lock means two relays racing to
-- admit the same session cannot both win: one increments the epoch and installs a token, the other
-- sees the token still unexpired and is told `busy`. A ticket minted before that increment carries
-- a superseded epoch and the socket layer refuses it, so a stale publisher cannot write.
--
-- The epoch is the ordering, and the token is the identity. Comparing only the epoch would let a
-- connection that has the right number but not the right session act as the publisher; comparing
-- only the token would let a superseded connection keep renewing. Both are required.
CREATE OR REPLACE FUNCTION swiftterm.admit_publisher(
  p_owner_id uuid,
  p_session_id uuid,
  p_device_id uuid,
  p_lease_token uuid,
  p_lease interval DEFAULT interval '30 seconds'
) RETURNS TABLE (outcome text, admitted_epoch bigint)
LANGUAGE plpgsql
SET search_path = swiftterm, pg_temp
AS $$
DECLARE
  v_row swiftterm.live_sessions;
BEGIN
  SELECT * INTO v_row FROM swiftterm.live_sessions s
   WHERE s.id = p_session_id AND s.owner_id = p_owner_id
   FOR UPDATE;

  IF v_row.id IS NULL THEN
    RETURN QUERY SELECT 'not_found'::text, 0::bigint; RETURN;
  END IF;
  IF v_row.status = 'ended' THEN
    RETURN QUERY SELECT 'ended'::text, v_row.publisher_epoch; RETURN;
  END IF;
  IF v_row.expires_at <= now() THEN
    RETURN QUERY SELECT 'expired'::text, v_row.publisher_epoch; RETURN;
  END IF;
  -- A ticket is minted for one pane, so a device that is not the session's device is not the
  -- session's publisher even if it belongs to the same account.
  IF v_row.device_id <> p_device_id THEN
    RETURN QUERY SELECT 'device_mismatch'::text, v_row.publisher_epoch; RETURN;
  END IF;
  IF v_row.publisher_lease_token IS NOT NULL AND v_row.publisher_lease_expires_at > now() THEN
    RETURN QUERY SELECT 'busy'::text, v_row.publisher_epoch; RETURN;
  END IF;

  UPDATE swiftterm.live_sessions s
     SET publisher_epoch = s.publisher_epoch + 1,
         publisher_lease_token = p_lease_token,
         publisher_lease_expires_at = now() + p_lease,
         status = 'live'
   WHERE s.id = p_session_id AND s.owner_id = p_owner_id
   RETURNING s.publisher_epoch INTO v_row.publisher_epoch;

  RETURN QUERY SELECT 'admitted'::text, v_row.publisher_epoch;
END
$$;

-- Extend the lease. Every condition is part of the fence: a renewal that matches the epoch but not
-- the token is a superseded connection, and one past `expires_at` is a session the owner no longer
-- has. The relay fails closed before expiry if this cannot be reached, so a `false` here means
-- "stop publishing", not "try again".
CREATE OR REPLACE FUNCTION swiftterm.renew_publisher_lease(
  p_owner_id uuid,
  p_session_id uuid,
  p_epoch bigint,
  p_lease_token uuid,
  p_lease interval DEFAULT interval '30 seconds'
) RETURNS boolean
LANGUAGE plpgsql
SET search_path = swiftterm, pg_temp
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE swiftterm.live_sessions
     SET publisher_lease_expires_at = now() + p_lease
   WHERE id = p_session_id
     AND owner_id = p_owner_id
     AND status = 'live'
     AND publisher_epoch = p_epoch
     AND publisher_lease_token = p_lease_token
     AND expires_at > now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count > 0;
END
$$;

-- Give the lease up. Only the token that holds it may release it, so a superseded publisher cannot
-- mark the live one's session paused on its way out — which is exactly the race a plain
-- "set paused on disconnect" would lose.
CREATE OR REPLACE FUNCTION swiftterm.release_publisher_lease(
  p_owner_id uuid,
  p_session_id uuid,
  p_epoch bigint,
  p_lease_token uuid
) RETURNS boolean
LANGUAGE plpgsql
SET search_path = swiftterm, pg_temp
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE swiftterm.live_sessions
     SET publisher_lease_token = NULL,
         publisher_lease_expires_at = NULL,
         status = 'paused'
   WHERE id = p_session_id
     AND owner_id = p_owner_id
     AND status = 'live'
     AND publisher_epoch = p_epoch
     AND publisher_lease_token = p_lease_token;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count > 0;
END
$$;

-- End a session for good. Idempotent, and it fences: the epoch advances so any ticket or lease
-- minted before this point is stale, and the lease is cleared so nothing can renew into a session
-- that has ended. A second call reports `found = true, changed = false` rather than failing.
CREATE OR REPLACE FUNCTION swiftterm.end_live_session(
  p_owner_id uuid,
  p_session_id uuid
) RETURNS TABLE (found boolean, changed boolean)
LANGUAGE plpgsql
SET search_path = swiftterm, pg_temp
AS $$
DECLARE
  v_found boolean;
  v_count integer;
BEGIN
  SELECT true INTO v_found FROM swiftterm.live_sessions
   WHERE id = p_session_id AND owner_id = p_owner_id
   FOR UPDATE;

  IF v_found IS NULL THEN
    RETURN QUERY SELECT false, false; RETURN;
  END IF;

  UPDATE swiftterm.live_sessions
     SET status = 'ended',
         ended_at = now(),
         publisher_lease_token = NULL,
         publisher_lease_expires_at = NULL,
         publisher_epoch = publisher_epoch + 1
   WHERE id = p_session_id AND owner_id = p_owner_id AND status <> 'ended';
  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN QUERY SELECT true, v_count > 0;
END
$$;

-- End every stream a device owns, returning the ids that changed.
--
-- Revoking a device has to end its streams, or a device the owner has just revoked keeps publishing
-- until someone notices. The relay closes the sockets for the returned ids; the epoch advance is
-- what makes any ticket already in flight stale.
CREATE OR REPLACE FUNCTION swiftterm.end_device_sessions(
  p_owner_id uuid,
  p_device_id uuid
) RETURNS SETOF uuid
LANGUAGE sql
SET search_path = swiftterm, pg_temp
AS $$
  UPDATE swiftterm.live_sessions
     SET status = 'ended',
         ended_at = now(),
         publisher_lease_token = NULL,
         publisher_lease_expires_at = NULL,
         publisher_epoch = publisher_epoch + 1
   WHERE owner_id = p_owner_id AND device_id = p_device_id AND status <> 'ended'
  RETURNING id
$$;

-- MARK: - Grants

REVOKE ALL ON FUNCTION swiftterm.create_live_session(uuid, uuid, uuid, uuid, bytea, text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.create_live_session(uuid, uuid, uuid, uuid, bytea, text, int) TO swiftterm_api;

REVOKE ALL ON FUNCTION swiftterm.list_live_sessions(uuid, timestamptz, uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.list_live_sessions(uuid, timestamptz, uuid, int) TO swiftterm_api;

REVOKE ALL ON FUNCTION swiftterm.read_live_session(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.read_live_session(uuid, uuid) TO swiftterm_api;

REVOKE ALL ON FUNCTION swiftterm.admit_publisher(uuid, uuid, uuid, uuid, interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.admit_publisher(uuid, uuid, uuid, uuid, interval) TO swiftterm_api;

REVOKE ALL ON FUNCTION swiftterm.renew_publisher_lease(uuid, uuid, bigint, uuid, interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.renew_publisher_lease(uuid, uuid, bigint, uuid, interval) TO swiftterm_api;

REVOKE ALL ON FUNCTION swiftterm.release_publisher_lease(uuid, uuid, bigint, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.release_publisher_lease(uuid, uuid, bigint, uuid) TO swiftterm_api;

REVOKE ALL ON FUNCTION swiftterm.end_live_session(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.end_live_session(uuid, uuid) TO swiftterm_api;

REVOKE ALL ON FUNCTION swiftterm.end_device_sessions(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION swiftterm.end_device_sessions(uuid, uuid) TO swiftterm_api;

RESET ROLE;
