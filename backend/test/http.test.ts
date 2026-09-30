/**
 * HTTP layer tests, against the real database and a real listening server.
 *
 * The session is created directly rather than through `/auth/session`, so these tests exercise the
 * session, CSRF and route behaviour without needing a Supabase-signed token. Token verification has
 * its own test; keeping them apart means a failure here is never an OIDC failure in disguise.
 *
 * The server listens on an ephemeral loopback port, so nothing here can collide with a real
 * deployment.
 */

import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";

import pg from "pg";

import { FailureRateLimiter, randomToken, sha256 } from "../src/auth/session.ts";
import type { IdentityVerifier } from "../src/auth/oidc.ts";
import { loadConfig } from "../src/config.ts";
import { createDatabase, type Database } from "../src/db/pool.ts";
import { createWebSession, provisionAppUser } from "../src/db/resolvers.ts";
import { sslConfig } from "../src/db/ssl.ts";
import { buildRoutes, type RelayControl } from "../src/http/routes.ts";
import { createHttpServer } from "../src/http/server.ts";
import { SessionRegistry } from "../src/shared_session/sessions.ts";
import { TicketStore } from "../src/shared_session/tickets.ts";

const { Client } = pg;

const TEST_ORIGIN = "http://localhost:3000";
const config = loadConfig({ ...process.env, ALLOWED_ORIGINS: TEST_ORIGIN });
const db: Database = createDatabase(config.databaseUrl, 4);

// `/auth/session` is the only route that needs the verifier, and it is not under test here.
const verifier = {
  verify: () => Promise.reject(new Error("the verifier is not used by these tests")),
} as unknown as IdentityVerifier;

// The live routes are not exercised here — `live.test.ts` owns them — but the router needs a relay.
const relay: RelayControl = {
  registry: new SessionRegistry(),
  tickets: new TicketStore(),
  closeSession: () => {},
};

const server = createHttpServer({
  config,
  routes: buildRoutes({ config, db, verifier, limiter: new FailureRateLimiter(1000, 1000), relay }),
  onError: () => {},
});

let base = "";
let ownerA = "";
let ownerB = "";

const runId = randomUUID();
const issuer = `test://http-${runId}`;

interface Session {
  readonly cookie: string;
  readonly csrfToken: string;
  readonly sessionId: string;
}

async function createSession(ownerId: string): Promise<Session> {
  const sessionToken = randomToken().toString("base64url");
  const csrfToken = randomToken().toString("base64url");
  const sessionId = await createWebSession(db, ownerId, sha256(sessionToken), sha256(csrfToken), 24);
  return {
    sessionId,
    csrfToken,
    cookie: `${config.cookieName}=${sessionToken}; ${config.csrfCookieName}=${csrfToken}`,
  };
}

function call(
  path: string,
  init: { method?: string; body?: unknown; cookie?: string; csrf?: string; origin?: string } = {},
): Promise<Response> {
  const headers: Record<string, string> = {};
  if (init.cookie !== undefined) headers.cookie = init.cookie;
  if (init.csrf !== undefined) headers[config.csrfHeaderName] = init.csrf;
  if (init.origin !== undefined) headers.origin = init.origin;
  if (init.body !== undefined) headers["content-type"] = "application/json";
  const request: RequestInit = { method: init.method ?? "GET", headers };
  // Assigned rather than passed as undefined: `exactOptionalPropertyTypes` distinguishes an
  // absent property from one explicitly set to undefined.
  if (init.body !== undefined) request.body = JSON.stringify(init.body);
  return fetch(`${base}${path}`, request);
}

before(async () => {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address() as AddressInfo;
  base = `http://127.0.0.1:${address.port}`;
  ownerA = await provisionAppUser(db, issuer, `a-${runId}`, "Tenant A");
  ownerB = await provisionAppUser(db, issuer, `b-${runId}`, "Tenant B");
});

after(async () => {
  if (process.env.DATABASE_ADMIN_URL !== undefined) {
    const admin = new Client({ connectionString: process.env.DATABASE_ADMIN_URL, ssl: sslConfig() });
    await admin.connect();
    await admin.query("SET ROLE swiftterm_owner");
    await admin.query("DELETE FROM swiftterm.app_users WHERE auth_issuer LIKE $1", ["test://%"]);
    await admin.query("RESET ROLE");
    await admin.end();
  }
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await db.close();
});

describe("health", () => {
  it("reports ok when the database answers", async () => {
    const response = await call("/healthz");
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { status: "ok" });
  });

  it("404s an unknown route", async () => {
    assert.equal((await call("/nope")).status, 404);
  });

  it("sets no-store on every response", async () => {
    assert.equal((await call("/healthz")).headers.get("cache-control"), "no-store");
  });
});

describe("authentication", () => {
  it("rejects /me without a session", async () => {
    assert.equal((await call("/me")).status, 401);
  });

  it("rejects /me with an unknown session token", async () => {
    const bogus = `${config.cookieName}=${randomBytes(32).toString("base64url")}`;
    assert.equal((await call("/me", { cookie: bogus })).status, 401);
  });

  it("returns the caller's own account", async () => {
    const session = await createSession(ownerA);
    const response = await call("/me", { cookie: session.cookie });
    assert.equal(response.status, 200);
    const body = (await response.json()) as { id: string };
    assert.equal(body.id, ownerA);
  });

  it("does not accept the CSRF cookie as a substitute for the header", async () => {
    const session = await createSession(ownerA);
    // The cookie is present in the session string; the header is what the check needs.
    const response = await call("/devices", {
      method: "POST",
      cookie: session.cookie,
      origin: TEST_ORIGIN,
      body: { label: "x", client_request_id: randomUUID(), device_token: randomBytes(32).toString("base64") },
    });
    assert.equal(response.status, 403);
  });

  it("refuses a write from an origin that is not allowed", async () => {
    const session = await createSession(ownerA);
    const response = await call("/devices", {
      method: "POST",
      cookie: session.cookie,
      csrf: session.csrfToken,
      origin: "http://evil.example",
      body: { label: "x", client_request_id: randomUUID(), device_token: randomBytes(32).toString("base64") },
    });
    assert.equal(response.status, 403);
  });

  it("refuses a write whose CSRF header does not match the session", async () => {
    const session = await createSession(ownerA);
    const response = await call("/devices", {
      method: "POST",
      cookie: session.cookie,
      csrf: randomToken().toString("base64url"),
      origin: TEST_ORIGIN,
      body: { label: "x", client_request_id: randomUUID(), device_token: randomBytes(32).toString("base64") },
    });
    assert.equal(response.status, 403);
  });
});

describe("devices", () => {
  const clientRequestId = randomUUID();
  const deviceToken = randomBytes(32).toString("base64");
  let session: Session;
  let deviceId = "";

  before(async () => {
    session = await createSession(ownerA);
  });

  it("registers a device", async () => {
    const response = await call("/devices", {
      method: "POST",
      cookie: session.cookie,
      csrf: session.csrfToken,
      origin: TEST_ORIGIN,
      body: { label: "Studio Mac", client_request_id: clientRequestId, device_token: deviceToken },
    });
    assert.equal(response.status, 201);
    const body = (await response.json()) as { device_id: string; created: boolean };
    assert.equal(body.created, true);
    deviceId = body.device_id;
  });

  it("returns the same device for an identical retry", async () => {
    const response = await call("/devices", {
      method: "POST",
      cookie: session.cookie,
      csrf: session.csrfToken,
      origin: TEST_ORIGIN,
      body: { label: "Studio Mac", client_request_id: clientRequestId, device_token: deviceToken },
    });
    assert.equal(response.status, 200);
    const body = (await response.json()) as { device_id: string; created: boolean };
    assert.equal(body.created, false);
    assert.equal(body.device_id, deviceId, "an identical retry must not mint a second credential");
  });

  it("409s when the same client_request_id carries a changed payload", async () => {
    const response = await call("/devices", {
      method: "POST",
      cookie: session.cookie,
      csrf: session.csrfToken,
      origin: TEST_ORIGIN,
      body: {
        label: "A different label",
        client_request_id: clientRequestId,
        device_token: deviceToken,
      },
    });
    assert.equal(response.status, 409);
  });

  it("lists only the caller's devices", async () => {
    const response = await call("/devices", { cookie: session.cookie });
    assert.equal(response.status, 200);
    const body = (await response.json()) as { devices: { id: string }[] };
    assert.equal(body.devices.length, 1);
    assert.equal(body.devices[0]?.id, deviceId);
  });

  it("shows another tenant none of them", async () => {
    const other = await createSession(ownerB);
    const response = await call("/devices", { cookie: other.cookie });
    const body = (await response.json()) as { devices: unknown[] };
    assert.deepEqual(body.devices, []);
  });

  it("revokes a device", async () => {
    const response = await call(`/devices/${deviceId}`, {
      method: "DELETE",
      cookie: session.cookie,
      csrf: session.csrfToken,
      origin: TEST_ORIGIN,
    });
    assert.equal(response.status, 204);
    const listed = (await (await call("/devices", { cookie: session.cookie })).json()) as {
      devices: { revoked_at: string | null }[];
    };
    assert.notEqual(listed.devices[0]?.revoked_at, null);
  });

  it("reports another tenant's device as absent rather than forbidden", async () => {
    const other = await createSession(ownerB);
    const response = await call(`/devices/${deviceId}`, {
      method: "DELETE",
      cookie: other.cookie,
      csrf: other.csrfToken,
      origin: TEST_ORIGIN,
    });
    // 404, not 403: the endpoint must not reveal which device ids exist.
    assert.equal(response.status, 404);
  });
});

describe("logout", () => {
  it("revokes the session and the cookie stops working", async () => {
    const session = await createSession(ownerA);
    assert.equal((await call("/me", { cookie: session.cookie })).status, 200);

    const logout = await call("/auth/logout", {
      method: "POST",
      cookie: session.cookie,
      csrf: session.csrfToken,
      origin: TEST_ORIGIN,
    });
    assert.equal(logout.status, 204);

    assert.equal(
      (await call("/me", { cookie: session.cookie })).status,
      401,
      "a revoked session must stop authenticating immediately",
    );
  });
});

describe("request limits", () => {
  it("refuses a body over the cap", async () => {
    const session = await createSession(ownerA);
    const response = await call("/devices", {
      method: "POST",
      cookie: session.cookie,
      csrf: session.csrfToken,
      origin: TEST_ORIGIN,
      body: { label: "x".repeat(70 * 1024), client_request_id: randomUUID(), device_token: deviceTokenOf() },
    });
    assert.equal(response.status, 413);
  });

  it("rejects a malformed device token", async () => {
    const session = await createSession(ownerA);
    const response = await call("/devices", {
      method: "POST",
      cookie: session.cookie,
      csrf: session.csrfToken,
      origin: TEST_ORIGIN,
      body: { label: "ok", client_request_id: randomUUID(), device_token: "not-base64!" },
    });
    assert.equal(response.status, 400);
  });
});

function deviceTokenOf(): string {
  return randomBytes(32).toString("base64");
}
