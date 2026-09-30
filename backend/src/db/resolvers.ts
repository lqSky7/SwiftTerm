/**
 * The only places a credential digest is touched.
 *
 * Every function here calls a `SECURITY DEFINER` function in the `swiftterm` schema. That is not a
 * style choice: the API role has no column privilege on `token_sha256`, `csrf_sha256` or
 * `registration_sha256`, so a direct `SELECT` from this service would fail. Resolution has to go
 * through the fixed-search-path functions, which is what keeps "the API cannot read credential
 * hashes" true at the database rather than in a code review.
 */

import type { Database } from "./pool.ts";

export interface ResolvedWebSession {
  readonly sessionId: string;
  readonly ownerId: string;
  readonly csrfSha256: Buffer;
  readonly expiresAt: Date;
  readonly revokedAt: Date | null;
  readonly accountDeactivatedAt: Date | null;
}

export interface ResolvedDevice {
  readonly deviceId: string;
  readonly ownerId: string;
  readonly label: string;
  readonly revokedAt: Date | null;
  readonly accountDeactivatedAt: Date | null;
}

export interface DeviceRegistration {
  readonly deviceId: string;
  readonly storedRegistrationSha256: Buffer;
  readonly created: boolean;
}

function toDate(value: unknown): Date {
  return value instanceof Date ? value : new Date(String(value));
}

function toNullableDate(value: unknown): Date | null {
  return value === null || value === undefined ? null : toDate(value);
}

export async function resolveWebSession(
  db: Database,
  tokenSha256: Buffer,
): Promise<ResolvedWebSession | null> {
  return db.withoutOwner(async (client) => {
    const { rows } = await client.query(
      "SELECT * FROM swiftterm.resolve_web_session($1)",
      [tokenSha256],
    );
    const row = rows[0];
    if (row === undefined) return null;
    return {
      sessionId: String(row.session_id),
      ownerId: String(row.owner_id),
      csrfSha256: Buffer.from(row.csrf_sha256),
      expiresAt: toDate(row.expires_at),
      revokedAt: toNullableDate(row.revoked_at),
      accountDeactivatedAt: toNullableDate(row.account_deactivated_at),
    };
  });
}

export async function resolveDevice(
  db: Database,
  tokenSha256: Buffer,
): Promise<ResolvedDevice | null> {
  return db.withoutOwner(async (client) => {
    const { rows } = await client.query("SELECT * FROM swiftterm.resolve_device($1)", [tokenSha256]);
    const row = rows[0];
    if (row === undefined) return null;
    return {
      deviceId: String(row.device_id),
      ownerId: String(row.owner_id),
      label: String(row.label),
      revokedAt: toNullableDate(row.revoked_at),
      accountDeactivatedAt: toNullableDate(row.account_deactivated_at),
    };
  });
}

/**
 * Create or fetch the account for a verified issuer/subject pair. The caller passes values that
 * came out of a signature-verified token, never values from request JSON.
 */
export async function provisionAppUser(
  db: Database,
  issuer: string,
  subject: string,
  displayName: string,
): Promise<string> {
  return db.withoutOwner(async (client) => {
    const { rows } = await client.query(
      "SELECT swiftterm.provision_app_user($1, $2, $3) AS id",
      [issuer, subject, displayName],
    );
    const row = rows[0];
    if (row === undefined) throw new Error("provision_app_user returned no row");
    return String(row.id);
  });
}

export async function createWebSession(
  db: Database,
  ownerId: string,
  tokenSha256: Buffer,
  csrfSha256: Buffer,
  ttlHours: number,
): Promise<string> {
  return db.withoutOwner(async (client) => {
    const { rows } = await client.query(
      "SELECT swiftterm.create_web_session($1, $2, $3, make_interval(hours => $4)) AS id",
      [ownerId, tokenSha256, csrfSha256, ttlHours],
    );
    const row = rows[0];
    if (row === undefined) throw new Error("create_web_session returned no row");
    return String(row.id);
  });
}

/**
 * Register a device. An identical retry returns the device that already exists; a changed payload
 * comes back with `created = false` and a different stored digest, which the caller turns into a
 * 409 rather than silently minting a second credential.
 */
export async function registerDevice(
  db: Database,
  ownerId: string,
  label: string,
  clientRequestId: string,
  registrationSha256: Buffer,
  tokenSha256: Buffer,
): Promise<DeviceRegistration> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query(
      "SELECT * FROM swiftterm.register_device($1, $2, $3, $4, $5)",
      [ownerId, label, clientRequestId, registrationSha256, tokenSha256],
    );
    const row = rows[0];
    if (row === undefined) throw new Error("register_device returned no row");
    return {
      deviceId: String(row.device_id),
      storedRegistrationSha256: Buffer.from(row.stored_registration_sha256),
      created: row.created === true,
    };
  });
}

export async function revokeWebSession(
  db: Database,
  ownerId: string,
  sessionId: string,
): Promise<boolean> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query(
      "SELECT swiftterm.revoke_web_session($1, $2) AS revoked",
      [ownerId, sessionId],
    );
    return rows[0]?.revoked === true;
  });
}

export async function revokeDevice(
  db: Database,
  ownerId: string,
  deviceId: string,
): Promise<boolean> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query("SELECT swiftterm.revoke_device($1, $2) AS revoked", [
      ownerId,
      deviceId,
    ]);
    return rows[0]?.revoked === true;
  });
}

export interface DeviceSummary {
  readonly id: string;
  readonly label: string;
  readonly clientRequestId: string;
  readonly createdAt: Date;
  readonly revokedAt: Date | null;
}

/** Owner-scoped device listing. RLS does the scoping; the owner context is set by `withOwner`. */
export async function listDevices(db: Database, ownerId: string): Promise<DeviceSummary[]> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query(
      `SELECT id, label, client_request_id, created_at, revoked_at
         FROM swiftterm.devices
        WHERE owner_id = $1
        ORDER BY created_at DESC, id DESC`,
      [ownerId],
    );
    return rows.map((row) => ({
      id: String(row.id),
      label: String(row.label),
      clientRequestId: String(row.client_request_id),
      createdAt: toDate(row.created_at),
      revokedAt: toNullableDate(row.revoked_at),
    }));
  });
}

export interface AccountSummary {
  readonly id: string;
  readonly displayName: string;
  readonly createdAt: Date;
  readonly deactivatedAt: Date | null;
}

export async function readOwnAccount(
  db: Database,
  ownerId: string,
): Promise<AccountSummary | null> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query(
      "SELECT id, display_name, created_at, deactivated_at FROM swiftterm.app_users WHERE id = $1",
      [ownerId],
    );
    const row = rows[0];
    if (row === undefined) return null;
    return {
      id: String(row.id),
      displayName: String(row.display_name),
      createdAt: toDate(row.created_at),
      deactivatedAt: toNullableDate(row.deactivated_at),
    };
  });
}
