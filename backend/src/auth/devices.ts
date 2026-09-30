/**
 * Native device registration.
 *
 * The rule this file exists to enforce: a client generates its device token **once** and keeps it
 * in the Keychain, so a retry of the same registration must return the device that already exists.
 * A retry carrying a *different* payload under the same `client_request_id` is a bug or an attack,
 * and it gets a conflict rather than a second credential.
 *
 * The registration digest is what makes those two cases distinguishable. It covers the whole
 * registration payload, so `register_device` can hand back the digest it stored and this layer can
 * compare — the database enforces uniqueness on `(owner_id, client_request_id)` and nothing more.
 */

import { randomUUID } from "node:crypto";

import type { Database } from "../db/pool.ts";
import { registerDevice } from "../db/resolvers.ts";
import { digestsEqual, sha256 } from "./session.ts";

export const DEVICE_TOKEN_BYTES = 32;
export const MAX_LABEL_BYTES = 256;

export class DeviceConflictError extends Error {
  readonly code = "conflict" as const;

  constructor() {
    super("client_request_id was already used with a different registration payload");
    this.name = "DeviceConflictError";
  }
}

export class DeviceRequestError extends Error {
  readonly code = "invalid_request" as const;

  constructor(message: string) {
    super(message);
    this.name = "DeviceRequestError";
  }
}

export interface DeviceRegistrationInput {
  readonly label: unknown;
  readonly clientRequestId: unknown;
  /** Base64 of the client-generated 32-byte device token. */
  readonly deviceToken: unknown;
}

export interface DeviceRegistrationResult {
  readonly deviceId: string;
  readonly created: boolean;
}

function parseLabel(value: unknown): string {
  if (typeof value !== "string") throw new DeviceRequestError("label must be a string");
  const trimmed = value.trim();
  if (trimmed === "") throw new DeviceRequestError("label must not be empty");
  if (Buffer.byteLength(trimmed, "utf8") > MAX_LABEL_BYTES) {
    throw new DeviceRequestError(`label must be at most ${MAX_LABEL_BYTES} bytes`);
  }
  return trimmed;
}

function parseClientRequestId(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)) {
    throw new DeviceRequestError("client_request_id must be a lowercase UUID");
  }
  return value;
}

function parseDeviceToken(value: unknown): Buffer {
  if (typeof value !== "string") throw new DeviceRequestError("device_token must be base64");
  let decoded: Buffer;
  try {
    decoded = Buffer.from(value, "base64");
  } catch {
    throw new DeviceRequestError("device_token must be base64");
  }
  // Re-encode and compare, so a non-canonical tail cannot give one token two spellings.
  if (decoded.toString("base64") !== value) {
    throw new DeviceRequestError("device_token must be canonical base64");
  }
  if (decoded.length !== DEVICE_TOKEN_BYTES) {
    throw new DeviceRequestError(`device_token must be ${DEVICE_TOKEN_BYTES} bytes`);
  }
  return decoded;
}

/**
 * The digest of the registration *request*, which is what makes an identical retry idempotent and
 * a changed one a conflict. It deliberately includes the device token: a retry that presents a new
 * token is not the same registration, and silently accepting it would rotate a credential behind
 * the client's back.
 */
export function registrationDigest(
  clientRequestId: string,
  label: string,
  deviceToken: Buffer,
): Buffer {
  return sha256(
    Buffer.concat([
      Buffer.from("swiftterm/device-registration/v1\0", "utf8"),
      Buffer.from(clientRequestId, "utf8"),
      Buffer.from("\0", "utf8"),
      Buffer.from(label, "utf8"),
      Buffer.from("\0", "utf8"),
      deviceToken,
    ]),
  );
}

export async function registerDeviceForOwner(
  db: Database,
  ownerId: string,
  input: DeviceRegistrationInput,
): Promise<DeviceRegistrationResult> {
  const label = parseLabel(input.label);
  const clientRequestId = parseClientRequestId(input.clientRequestId);
  const deviceToken = parseDeviceToken(input.deviceToken);

  const digest = registrationDigest(clientRequestId, label, deviceToken);
  const result = await registerDevice(
    db,
    ownerId,
    label,
    clientRequestId,
    digest,
    sha256(deviceToken),
  );

  if (!result.created && !digestsEqual(result.storedRegistrationSha256, digest)) {
    throw new DeviceConflictError();
  }
  return { deviceId: result.deviceId, created: result.created };
}

/** A fresh device id for a caller that needs to mint one; kept here so the shape has one home. */
export function newClientRequestId(): string {
  return randomUUID();
}
