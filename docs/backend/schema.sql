-- B0 PostgreSQL draft; not applied. No terminal frames or input text are stored here.
BEGIN;
CREATE SCHEMA swiftterm;
CREATE FUNCTION swiftterm.request_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('swiftterm.user_id', true), '')::uuid
$$;

CREATE TABLE swiftterm.app_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_issuer text NOT NULL CHECK (octet_length(auth_issuer) BETWEEN 1 AND 2048),
  auth_subject text NOT NULL CHECK (octet_length(auth_subject) BETWEEN 1 AND 512),
  display_name text NOT NULL DEFAULT '' CHECK (octet_length(display_name) <= 256),
  created_at timestamptz NOT NULL DEFAULT now(),
  deactivated_at timestamptz,
  UNIQUE (auth_issuer, auth_subject)
);
CREATE TABLE swiftterm.web_sessions (
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
CREATE INDEX web_session_owner ON swiftterm.web_sessions(owner_id, created_at DESC, id DESC);
CREATE INDEX web_session_expiry ON swiftterm.web_sessions(expires_at, id);
CREATE TABLE swiftterm.devices (
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

CREATE TABLE swiftterm.live_sessions (
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
CREATE UNIQUE INDEX one_open_stream_per_pane ON swiftterm.live_sessions(device_id, local_pane_id)
  WHERE status <> 'ended';
CREATE INDEX live_owner_page ON swiftterm.live_sessions(owner_id, created_at DESC, id DESC);
CREATE INDEX live_device ON swiftterm.live_sessions(device_id);
CREATE INDEX live_ended_retention ON swiftterm.live_sessions(ended_at, id) WHERE status = 'ended';
CREATE INDEX live_lease_expiry ON swiftterm.live_sessions(publisher_lease_expires_at, id) WHERE status = 'live';
CREATE INDEX live_expiry ON swiftterm.live_sessions(expires_at, id) WHERE status <> 'ended';

CREATE TABLE swiftterm.live_session_grants (
  owner_id uuid NOT NULL,
  session_id uuid NOT NULL,
  recipient_user_id uuid NOT NULL REFERENCES swiftterm.app_users(id) ON DELETE CASCADE,
  permission text NOT NULL CHECK (permission IN ('viewer', 'controller')),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  PRIMARY KEY (session_id, recipient_user_id),
  FOREIGN KEY (owner_id, session_id) REFERENCES swiftterm.live_sessions(owner_id, id) ON DELETE CASCADE
);
CREATE INDEX live_grants_recipient ON swiftterm.live_session_grants(recipient_user_id) WHERE revoked_at IS NULL;

-- An invitation to a named account, created by the owner and redeemed by the recipient.
--
-- Added by 003, which is the file to read for the reasoning. The two things worth knowing here:
-- `code_sha256` is the *only* form of the code that exists anywhere, and `expires_at` is NOT NULL
-- because an invitation with no deadline is a capability nobody can withdraw.
CREATE TABLE swiftterm.live_session_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL,
  session_id uuid NOT NULL,
  recipient_user_id uuid NOT NULL REFERENCES swiftterm.app_users(id) ON DELETE CASCADE,
  permission text NOT NULL CHECK (permission IN ('viewer', 'controller')),
  code_sha256 bytea NOT NULL UNIQUE CHECK (octet_length(code_sha256) = 32),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  redeemed_at timestamptz,
  revoked_at timestamptz,
  CHECK (expires_at > created_at),
  FOREIGN KEY (owner_id, session_id) REFERENCES swiftterm.live_sessions(owner_id, id) ON DELETE CASCADE,
  UNIQUE (owner_id, id)
);
CREATE INDEX invitations_session
  ON swiftterm.live_session_invitations(session_id) WHERE revoked_at IS NULL;
CREATE INDEX invitations_recipient
  ON swiftterm.live_session_invitations(recipient_user_id) WHERE redeemed_at IS NULL AND revoked_at IS NULL;

CREATE TABLE swiftterm.block_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES swiftterm.app_users(id) ON DELETE CASCADE,
  schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version = 1),
  blocks jsonb NOT NULL CHECK (jsonb_typeof(blocks) = 'array'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (jsonb_array_length(blocks) BETWEEN 1 AND 20),
  CHECK (octet_length(blocks::text) <= 2097152),
  UNIQUE (owner_id, id)
);
CREATE TABLE swiftterm.share_links (
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
CREATE INDEX shares_owner_page ON swiftterm.share_links(owner_id, created_at DESC, id DESC);
CREATE INDEX shares_snapshot ON swiftterm.share_links(snapshot_id);
CREATE INDEX shares_expiry ON swiftterm.share_links(expires_at, id) WHERE revoked_at IS NULL;
CREATE TABLE swiftterm.share_grants (
  owner_id uuid NOT NULL,
  share_id uuid NOT NULL,
  recipient_user_id uuid NOT NULL REFERENCES swiftterm.app_users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (share_id, recipient_user_id),
  FOREIGN KEY (owner_id, share_id) REFERENCES swiftterm.share_links(owner_id, id) ON DELETE CASCADE
);
CREATE INDEX grants_recipient ON swiftterm.share_grants(recipient_user_id);

ALTER TABLE swiftterm.app_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.app_users FORCE ROW LEVEL SECURITY;
CREATE POLICY user_self ON swiftterm.app_users
  USING (id = swiftterm.request_user_id()) WITH CHECK (id = swiftterm.request_user_id());
ALTER TABLE swiftterm.web_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.web_sessions FORCE ROW LEVEL SECURITY;
CREATE POLICY web_session_owner ON swiftterm.web_sessions
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
ALTER TABLE swiftterm.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.devices FORCE ROW LEVEL SECURITY;
CREATE POLICY device_owner ON swiftterm.devices
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
ALTER TABLE swiftterm.live_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.live_sessions FORCE ROW LEVEL SECURITY;
CREATE POLICY live_owner ON swiftterm.live_sessions
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
ALTER TABLE swiftterm.live_session_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.live_session_grants FORCE ROW LEVEL SECURITY;
CREATE POLICY live_grant_owner ON swiftterm.live_session_grants
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
ALTER TABLE swiftterm.block_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.block_snapshots FORCE ROW LEVEL SECURITY;
CREATE POLICY snapshot_owner ON swiftterm.block_snapshots
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
ALTER TABLE swiftterm.share_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.share_links FORCE ROW LEVEL SECURITY;
CREATE POLICY share_owner ON swiftterm.share_links
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
ALTER TABLE swiftterm.share_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE swiftterm.share_grants FORCE ROW LEVEL SECURITY;
CREATE POLICY grant_owner ON swiftterm.share_grants
  USING (owner_id = swiftterm.request_user_id()) WITH CHECK (owner_id = swiftterm.request_user_id());
COMMIT;
