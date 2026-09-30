/**
 * Live sessions: the durable metadata behind a stream.
 *
 * This is the only module that talks to the `swiftterm.live_session*` functions. It holds no live
 * state — the relay's registry does that — and it never sees terminal content. What it owns is the
 * control plane: which panes are being shared, by which device, in what state, and which publisher
 * generation currently holds the lease.
 *
 * Every function here runs inside a transaction with the owner context set, so `live_owner` scopes
 * each statement to the calling account. Nothing takes an owner id from request JSON: the caller
 * passes the id that came out of a verified session cookie.
 */

import { createHash, randomUUID } from "node:crypto";

import type { Database } from "../db/pool.ts";

/** The lifecycle a session is in. `live` means a publisher holds the lease. */
export type LiveStatus = "paused" | "live" | "ended";

export interface LiveSessionRow {
  readonly id: string;
  readonly deviceId: string;
  readonly localPaneId: string;
  readonly title: string;
  readonly status: LiveStatus;
  readonly publisherEpoch: number;
  readonly createdAt: Date;
  readonly expiresAt: Date;
  readonly endedAt: Date | null;
}

/**
 * Every way creating a stream can go, as an ordinary result.
 *
 * These are outcomes rather than exceptions because most of them are not errors: `existing` is a
 * successful idempotent retry, and `account_limit` is a 429 rather than a fault. A caller that had
 * to parse a message to tell them apart would eventually parse it wrong.
 */
export type CreateOutcome =
  | "created"
  | "existing"
  | "conflict"
  | "pane_shared"
  | "account_limit"
  | "device_unknown";

export interface CreateResult {
  readonly outcome: CreateOutcome;
  readonly sessionId: string | null;
  readonly publisherEpoch: number | null;
  readonly status: LiveStatus | null;
}

export type AdmitOutcome =
  | "admitted"
  | "not_found"
  | "ended"
  | "expired"
  | "device_mismatch"
  | "busy";

export interface AdmitResult {
  readonly outcome: AdmitOutcome;
  readonly publisherEpoch: number;
}

export interface CreateInput {
  readonly deviceId: string;
  readonly localPaneId: string;
  readonly clientRequestId: string;
  /** SHA-256 of the canonical request. See `canonicalRequestDigest`. */
  readonly requestSha256: Buffer;
  readonly title: string;
  readonly maxStreams: number;
}

function toDate(value: unknown): Date {
  return value instanceof Date ? value : new Date(String(value));
}

function toNullableDate(value: unknown): Date | null {
  return value === null || value === undefined ? null : toDate(value);
}

function toRow(row: Record<string, unknown>): LiveSessionRow {
  return {
    id: String(row.id),
    deviceId: String(row.device_id),
    localPaneId: String(row.local_pane_id),
    title: String(row.title ?? ""),
    status: String(row.status) as LiveStatus,
    publisherEpoch: Number(row.publisher_epoch),
    createdAt: toDate(row.created_at),
    expiresAt: toDate(row.expires_at),
    endedAt: toNullableDate(row.ended_at),
  };
}

/**
 * A digest over the *validated* fields of a create request.
 *
 * The contract calls for SHA-256 of the canonical request, and canonical here means one spelling per
 * request: keys in sorted order, no whitespace, values already checked to be strings. That is the
 * whole requirement — the digest is compared against itself on a retry, never against a value the
 * client computed — so a general-purpose canonical JSON encoder would be more machinery than the
 * job needs. It is deliberately not exported for reuse on nested data, where sorted-key encoding
 * has real subtleties this does not handle.
 */
export function canonicalRequestDigest(fields: Record<string, string>): Buffer {
  const canonical = `{${Object.keys(fields)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${JSON.stringify(fields[key])}`)
    .join(",")}}`;
  return createHash("sha256").update(canonical, "utf8").digest();
}

/** A fresh lease identity. Random rather than derived, so a replayed epoch cannot be guessed. */
export function newLeaseToken(): string {
  return randomUUID();
}

export async function createLiveSession(
  db: Database,
  ownerId: string,
  input: CreateInput,
): Promise<CreateResult> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query(
      `SELECT * FROM swiftterm.create_live_session($1, $2, $3, $4, $5, $6, $7)`,
      [
        ownerId,
        input.deviceId,
        input.localPaneId,
        input.clientRequestId,
        input.requestSha256,
        input.title,
        input.maxStreams,
      ],
    );
    const row = rows[0];
    if (row === undefined) throw new Error("create_live_session returned no row");
    return {
      outcome: String(row.outcome) as CreateOutcome,
      sessionId: row.session_id === null ? null : String(row.session_id),
      // `session_epoch` and `session_status`, not `publisher_epoch` and `status`: the function's
      // output columns deliberately avoid the names of its own table's columns, because a PL/pgSQL
      // output parameter shadows a column and makes every unqualified reference to it ambiguous.
      publisherEpoch: row.session_epoch === null ? null : Number(row.session_epoch),
      status: row.session_status === null ? null : (String(row.session_status) as LiveStatus),
    };
  });
}

export interface ListOptions {
  /** Keyset cursor. Both parts are needed: `created_at` alone is not unique. */
  readonly beforeCreatedAt?: Date;
  readonly beforeId?: string;
  readonly limit: number;
}

export async function listLiveSessions(
  db: Database,
  ownerId: string,
  options: ListOptions,
): Promise<LiveSessionRow[]> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query(
      `SELECT * FROM swiftterm.list_live_sessions($1, $2, $3, $4)`,
      [ownerId, options.beforeCreatedAt ?? null, options.beforeId ?? null, options.limit],
    );
    return rows.map(toRow);
  });
}

export async function readLiveSession(
  db: Database,
  ownerId: string,
  sessionId: string,
): Promise<LiveSessionRow | null> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query(`SELECT * FROM swiftterm.read_live_session($1, $2)`, [
      ownerId,
      sessionId,
    ]);
    const row = rows[0];
    return row === undefined ? null : toRow(row);
  });
}

export interface AdmitInput {
  readonly sessionId: string;
  readonly deviceId: string;
  readonly leaseToken: string;
}

/**
 * Take the publisher lease, or learn why not.
 *
 * The epoch this returns is the one a ticket must carry. Because the database increments it under a
 * row lock, a ticket minted before this call holds a superseded epoch and the socket layer refuses
 * it — which is how a stale publisher is fenced out without the relay having to remember anything.
 */
export async function admitPublisher(
  db: Database,
  ownerId: string,
  input: AdmitInput,
): Promise<AdmitResult> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query(
      `SELECT * FROM swiftterm.admit_publisher($1, $2, $3, $4)`,
      [ownerId, input.sessionId, input.deviceId, input.leaseToken],
    );
    const row = rows[0];
    if (row === undefined) throw new Error("admit_publisher returned no row");
    return {
      outcome: String(row.outcome) as AdmitOutcome,
      publisherEpoch: Number(row.admitted_epoch),
    };
  });
}

export interface LeaseRef {
  readonly sessionId: string;
  readonly epoch: number;
  readonly leaseToken: string;
}

/** Extend the lease. `false` means stop publishing: the lease was superseded or the session ended. */
export async function renewPublisherLease(
  db: Database,
  ownerId: string,
  ref: LeaseRef,
): Promise<boolean> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query(
      `SELECT swiftterm.renew_publisher_lease($1, $2, $3, $4) AS renewed`,
      [ownerId, ref.sessionId, ref.epoch, ref.leaseToken],
    );
    return rows[0]?.renewed === true;
  });
}

/** Give the lease up. Only the current holder can, so a superseded publisher cannot pause a live one. */
export async function releasePublisherLease(
  db: Database,
  ownerId: string,
  ref: LeaseRef,
): Promise<boolean> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query(
      `SELECT swiftterm.release_publisher_lease($1, $2, $3, $4) AS released`,
      [ownerId, ref.sessionId, ref.epoch, ref.leaseToken],
    );
    return rows[0]?.released === true;
  });
}

export interface EndResult {
  readonly found: boolean;
  readonly changed: boolean;
}

/** End a session for good. `changed` is false on a second call, which is what idempotent means here. */
export async function endLiveSession(
  db: Database,
  ownerId: string,
  sessionId: string,
): Promise<EndResult> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query(`SELECT * FROM swiftterm.end_live_session($1, $2)`, [
      ownerId,
      sessionId,
    ]);
    const row = rows[0];
    if (row === undefined) throw new Error("end_live_session returned no row");
    return { found: row.found === true, changed: row.changed === true };
  });
}

/**
 * End every stream a device owns, returning the ids that changed.
 *
 * Called when a device is revoked. Without it a device the owner has just revoked keeps publishing
 * until someone notices, which is the difference between revoking a credential and asking it to
 * stop.
 */
export async function endDeviceSessions(
  db: Database,
  ownerId: string,
  deviceId: string,
): Promise<string[]> {
  return db.withOwner(ownerId, async (client) => {
    const { rows } = await client.query(`SELECT * FROM swiftterm.end_device_sessions($1, $2)`, [
      ownerId,
      deviceId,
    ]);
    return rows.map((row) => String(row.end_device_sessions));
  });
}
