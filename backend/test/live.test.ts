/**
 * The live control plane: the HTTP routes, the database functions behind them, and the relay.
 *
 * These run against the real database and a real listening server, because the properties under test
 * are not properties of the code — they are properties of the grants, the row-level policies and the
 * row locks. A mocked database would pass no matter how wrong any of those were.
 *
 * **Every test gets its own account.** The per-account stream cap is enforced in the database, so
 * tests sharing an account would start failing at whichever one crossed the cap, and the failure
 * would look like a broken route rather than a used-up budget. A fresh tenant makes each test
 * self-contained.
 *
 * The clock is real here. Where a test needs a lease to be gone it ends the session instead of
 * waiting thirty seconds, and the lease's own expiry is covered by the database's semantics rather
 * than by sleeping.
 */

import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";

import pg from "pg";
import { WebSocket } from "ws";

import { FailureRateLimiter, randomToken, sha256 } from "../src/auth/session.ts";
import type { IdentityVerifier } from "../src/auth/oidc.ts";
import { loadConfig } from "../src/config.ts";
import { createDatabase, type Database } from "../src/db/pool.ts";
import { createWebSession, provisionAppUser } from "../src/db/resolvers.ts";
import { sslConfig } from "../src/db/ssl.ts";
import { buildRoutes } from "../src/http/routes.ts";
import { createHttpServer } from "../src/http/server.ts";
import { DEFAULT_LIMITS, SessionRegistry } from "../src/shared_session/sessions.ts";
import { attachRelay } from "../src/shared_session/socket.ts";
import { TicketStore } from "../src/shared_session/tickets.ts";

const { Client } = pg;

const TEST_ORIGIN = "http://localhost:3000";
// Three streams per account: enough for the listing test to need two pages, and small enough that
// the cap can be reached by one test without creating a device farm.
const STREAM_CAP = 3;
const config = loadConfig({
  ...process.env,
  ALLOWED_ORIGINS: TEST_ORIGIN,
  MAX_LIVE_STREAMS_PER_ACCOUNT: String(STREAM_CAP),
});
const db: Database = createDatabase(config.databaseUrl, 4);

const verifier = {
  verify: () => Promise.reject(new Error("the verifier is not used by these tests")),
} as unknown as IdentityVerifier;

// The process publisher budget is a real limit, but this file opens far more sessions than a
// deployment would carry at once. Raising it keeps each test measuring the rule it is named for.
const registry = new SessionRegistry({ ...DEFAULT_LIMITS, maxPublishersPerProcess: 1_000 });
const tickets = new TicketStore();

let relay: ReturnType<typeof attachRelay>;
const server: Server = createHttpServer({
  config,
  routes: buildRoutes({
    config,
    db,
    verifier,
    limiter: new FailureRateLimiter(1000, 1000),
    relay: {
      registry,
      tickets,
      closeSession: (sessionId, code, reason) => relay.closeSession(sessionId, code, reason),
    },
  }),
  onError: () => {},
});
relay = attachRelay(server, { config, tickets, registry });

let base = "";
let wsBase = "";

const runId = randomUUID();
const issuer = `test://live-${runId}`;

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
  init: { method?: string; body?: unknown; session?: Session; origin?: string } = {},
): Promise<Response> {
  const headers: Record<string, string> = {};
  if (init.session !== undefined) {
    headers.cookie = init.session.cookie;
    headers[config.csrfHeaderName] = init.session.csrfToken;
  }
  headers.origin = init.origin ?? TEST_ORIGIN;
  const request: RequestInit = { method: init.method ?? "GET", headers };
  if (init.body !== undefined) {
    headers["content-type"] = "application/json";
    request.body = JSON.stringify(init.body);
  }
  return fetch(`${base}${path}`, request);
}

/** Register a device through the API, so the test exercises the route that actually mints one. */
async function registerDevice(session: Session, label: string): Promise<string> {
  const response = await call("/devices", {
    method: "POST",
    session,
    body: {
      label,
      client_request_id: randomUUID(),
      // Canonical standard base64, not base64url: the route refuses a non-canonical spelling so one
      // credential cannot have two wire forms.
      device_token: randomBytes(32).toString("base64"),
    },
  });
  assert.equal(response.status, 201);
  const body = (await response.json()) as { device_id: string };
  return body.device_id;
}

interface Tenant {
  readonly ownerId: string;
  readonly session: Session;
  readonly deviceId: string;
}

/** A fresh account with a session and one registered device. */
async function newTenant(label: string): Promise<Tenant> {
  const ownerId = await provisionAppUser(db, issuer, `${label}-${randomUUID()}`, label);
  const session = await createSession(ownerId);
  const deviceId = await registerDevice(session, `${label} Mac`);
  return { ownerId, session, deviceId };
}

interface LiveBody {
  session_id: string;
  status: string;
  publisher_epoch: string;
  created: boolean;
}

async function openStream(
  session: Session,
  deviceId: string,
  localPaneId = randomUUID(),
  clientRequestId = randomUUID(),
  title = "shell",
): Promise<{ status: number; body: LiveBody }> {
  const response = await call("/live", {
    method: "POST",
    session,
    body: {
      device_id: deviceId,
      local_pane_id: localPaneId,
      client_request_id: clientRequestId,
      title,
    },
  });
  return { status: response.status, body: (await response.json()) as LiveBody };
}

/** Open a stream that is known to succeed, so a test can work with its id. */
async function openedStream(tenant: Tenant): Promise<string> {
  const opened = await openStream(tenant.session, tenant.deviceId);
  assert.equal(opened.status, 201);
  return opened.body.session_id;
}

/** A socket that can be asked for its next frame, so a refusal is asserted rather than waited out. */
async function connectSocket(sessionId: string, ticket: string) {
  const socket = new WebSocket(`${wsBase}/live/${sessionId}`, {
    headers: { origin: TEST_ORIGIN },
  });
  const frames: string[] = [];
  const waiters: ((frame: string) => void)[] = [];
  socket.on("message", (data) => {
    const text = data.toString();
    const waiter = waiters.shift();
    if (waiter !== undefined) waiter(text);
    else frames.push(text);
  });
  await new Promise<void>((resolve, reject) => {
    socket.once("open", () => resolve());
    socket.once("error", reject);
  });
  socket.send(JSON.stringify({ type: "auth", ticket }));
  return {
    socket,
    next: (): Promise<Record<string, unknown>> =>
      new Promise((resolve) => {
        const queued = frames.shift();
        if (queued !== undefined) resolve(JSON.parse(queued) as Record<string, unknown>);
        else waiters.push((text) => resolve(JSON.parse(text) as Record<string, unknown>));
      }),
  };
}

function settle(ms = 80): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Ask for a ticket, and hand back the body. */
async function ticket(
  session: Session,
  sessionId: string,
  role: "publisher" | "viewer",
): Promise<{ status: number; body: { ticket?: string; epoch?: string; role?: string } }> {
  const response = await call(`/live/${sessionId}/tickets`, {
    method: "POST",
    session,
    body: { role },
  });
  return { status: response.status, body: (await response.json()) as Record<string, unknown> };
}

before(async () => {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address() as AddressInfo;
  base = `http://127.0.0.1:${address.port}`;
  wsBase = `ws://127.0.0.1:${address.port}`;
});

after(async () => {
  if (process.env.DATABASE_ADMIN_URL !== undefined) {
    const admin = new Client({ connectionString: process.env.DATABASE_ADMIN_URL, ssl: sslConfig() });
    await admin.connect();
    // Deleting an account is not something the API role can do, so cleanup borrows the owner role.
    await admin.query("SET ROLE swiftterm_owner");
    await admin.query("DELETE FROM swiftterm.app_users WHERE auth_issuer LIKE $1", ["test://%"]);
    await admin.query("RESET ROLE");
    await admin.end();
  }
  relay.wss.close();
  // A test that fails mid-socket leaves its connection open, and `server.close()` waits for every
  // open connection before calling back — so without this one failure turns into a hang.
  for (const client of relay.wss.clients) client.terminate();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await db.close();
});

describe("creating a stream", () => {
  it("creates a paused stream and registers it in the relay", async () => {
    const tenant = await newTenant("create");
    const opened = await openStream(tenant.session, tenant.deviceId);

    assert.equal(opened.status, 201);
    assert.equal(opened.body.created, true);
    assert.equal(opened.body.status, "paused", "nothing is captured before an explicit start");
    assert.equal(opened.body.publisher_epoch, "0", "no publisher has been admitted yet");
    assert.notEqual(registry.get(opened.body.session_id), undefined);
  });

  it("is idempotent for an identical retry", async () => {
    const tenant = await newTenant("idempotent");
    const paneId = randomUUID();
    const requestId = randomUUID();

    const first = await openStream(tenant.session, tenant.deviceId, paneId, requestId);
    const second = await openStream(tenant.session, tenant.deviceId, paneId, requestId);

    assert.equal(first.status, 201);
    assert.equal(second.status, 200, "a retry is not a second creation");
    assert.equal(second.body.created, false);
    assert.equal(second.body.session_id, first.body.session_id);
  });

  it("conflicts when the same request id carries a different payload", async () => {
    const tenant = await newTenant("conflict");
    const paneId = randomUUID();
    const requestId = randomUUID();

    await openStream(tenant.session, tenant.deviceId, paneId, requestId, "shell");
    const changed = await openStream(tenant.session, tenant.deviceId, paneId, requestId, "another title");
    assert.equal(changed.status, 409, "reusing a request id for another stream is a conflict");
  });

  it("refuses a second stream for a pane that is already shared", async () => {
    const tenant = await newTenant("pane");
    const paneId = randomUUID();

    assert.equal((await openStream(tenant.session, tenant.deviceId, paneId)).status, 201);
    // A different request id, the same pane. The partial unique index is what makes this true under
    // concurrency; the function is what makes it a 409 rather than a 23505.
    const second = await openStream(tenant.session, tenant.deviceId, paneId);
    assert.equal(second.status, 409);
  });

  it("refuses a device that does not exist", async () => {
    const tenant = await newTenant("unknown-device");
    const opened = await openStream(tenant.session, randomUUID());
    assert.equal(opened.status, 404, "an id the caller does not own and one that never existed agree");
  });

  it("refuses another tenant's device", async () => {
    const tenantA = await newTenant("device-owner");
    const tenantB = await newTenant("device-thief");
    const opened = await openStream(tenantB.session, tenantA.deviceId);
    assert.equal(opened.status, 404);
  });

  it("refuses past the account's stream cap", async () => {
    const tenant = await newTenant("cap");
    for (let index = 0; index < STREAM_CAP; index += 1) {
      assert.equal((await openStream(tenant.session, tenant.deviceId)).status, 201);
    }
    const overflow = await openStream(tenant.session, tenant.deviceId);
    assert.equal(overflow.status, 429, `the cap is ${STREAM_CAP} streams per account`);
  });

  it("requires the CSRF header, not just the cookie", async () => {
    const tenant = await newTenant("csrf");
    const response = await call("/live", {
      method: "POST",
      session: { ...tenant.session, csrfToken: "not-the-token" },
      body: {
        device_id: tenant.deviceId,
        local_pane_id: randomUUID(),
        client_request_id: randomUUID(),
      },
    });
    assert.equal(response.status, 403);
  });
});

describe("listing streams", () => {
  it("returns the owner's streams, newest first, with a keyset cursor", async () => {
    const tenant = await newTenant("listing");
    const first = await openedStream(tenant);
    const second = await openedStream(tenant);
    const third = await openedStream(tenant);

    const page = await call("/live?limit=2", { session: tenant.session });
    assert.equal(page.status, 200);
    const body = (await page.json()) as { sessions: { id: string }[]; next_before: string | null };
    assert.equal(body.sessions.length, 2);
    assert.equal(body.sessions[0]?.id, third, "newest first");
    assert.equal(body.sessions[1]?.id, second);
    assert.notEqual(body.next_before, null, "a full page offers a cursor");

    const next = await call(`/live?limit=2&before=${encodeURIComponent(body.next_before ?? "")}`, {
      session: tenant.session,
    });
    const nextBody = (await next.json()) as {
      sessions: { id: string }[];
      next_before: string | null;
    };
    assert.equal(nextBody.sessions.length, 1, "the second page holds the remainder");
    assert.equal(nextBody.sessions[0]?.id, first);
    assert.equal(nextBody.next_before, null, "a short page is the end of the list");
  });

  it("shows one tenant nothing of another's", async () => {
    const tenantA = await newTenant("listing-a");
    const created = await openedStream(tenantA);

    const tenantB = await newTenant("listing-b");
    const listed = await call("/live", { session: tenantB.session });
    const body = (await listed.json()) as { sessions: { id: string }[] };
    assert.equal(
      body.sessions.some((row) => row.id === created),
      false,
    );
  });
});

describe("tickets", () => {
  it("mints a viewer ticket against the session's epoch", async () => {
    const tenant = await newTenant("viewer-ticket");
    const sessionId = await openedStream(tenant);

    const response = await ticket(tenant.session, sessionId, "viewer");
    assert.equal(response.status, 201);
    assert.equal(response.body.role, "viewer");
    assert.equal(response.body.epoch, "0");
    assert.equal((response.body.ticket ?? "").length > 20, true);
  });

  it("admits one publisher and refuses a second", async () => {
    const tenant = await newTenant("publisher-ticket");
    const sessionId = await openedStream(tenant);

    const first = await ticket(tenant.session, sessionId, "publisher");
    assert.equal(first.status, 201);
    assert.equal(first.body.epoch, "1", "admission advances the publisher generation");

    // The lease is still unexpired, so the second admission is refused rather than silently fencing
    // the publisher that is already connected.
    const second = await call(`/live/${sessionId}/tickets`, {
      method: "POST",
      session: tenant.session,
      body: { role: "publisher" },
    });
    assert.equal(second.status, 409);
    assert.equal(((await second.json()) as { error: string }).error, "stale_lease");
  });

  it("refuses a ticket for another tenant's session", async () => {
    const tenantA = await newTenant("ticket-owner");
    const sessionId = await openedStream(tenantA);

    const tenantB = await newTenant("ticket-thief");
    const response = await ticket(tenantB.session, sessionId, "viewer");
    assert.equal(response.status, 404, "not 403: the endpoint must not confirm the id exists");
  });

  it("refuses an unknown role", async () => {
    const tenant = await newTenant("bad-role");
    const sessionId = await openedStream(tenant);
    const response = await call(`/live/${sessionId}/tickets`, {
      method: "POST",
      session: tenant.session,
      body: { role: "admin" },
    });
    assert.equal(response.status, 400);
  });
});

describe("ending a stream", () => {
  it("ends it, is idempotent, and refuses tickets afterwards", async () => {
    const tenant = await newTenant("end");
    const sessionId = await openedStream(tenant);

    const ended = await call(`/live/${sessionId}/end`, { method: "POST", session: tenant.session });
    assert.equal(ended.status, 204);
    assert.equal(registry.get(sessionId), undefined, "the relay forgot it too");

    // A client retry after a dropped response must not look like a failure.
    const again = await call(`/live/${sessionId}/end`, { method: "POST", session: tenant.session });
    assert.equal(again.status, 204);

    assert.equal((await ticket(tenant.session, sessionId, "viewer")).status, 409, "ended stays ended");
  });

  it("reports another tenant's stream as absent", async () => {
    const tenantA = await newTenant("end-owner");
    const sessionId = await openedStream(tenantA);

    const tenantB = await newTenant("end-thief");
    const response = await call(`/live/${sessionId}/end`, {
      method: "POST",
      session: tenantB.session,
    });
    assert.equal(response.status, 404);
  });

  it("frees a slot in the account's cap", async () => {
    const tenant = await newTenant("end-frees");
    const first = await openedStream(tenant);
    for (let index = 1; index < STREAM_CAP; index += 1) await openedStream(tenant);
    assert.equal((await openStream(tenant.session, tenant.deviceId)).status, 429);

    await call(`/live/${first}/end`, { method: "POST", session: tenant.session });
    assert.equal((await openStream(tenant.session, tenant.deviceId)).status, 201);
  });
});

describe("revoking a device", () => {
  it("ends that device's streams", async () => {
    const tenant = await newTenant("revoke");
    const sessionId = await openedStream(tenant);

    const revoked = await call(`/devices/${tenant.deviceId}`, {
      method: "DELETE",
      session: tenant.session,
    });
    assert.equal(revoked.status, 204);

    // Revoking a credential has to stop what it was doing, not merely refuse it next time.
    assert.equal((await ticket(tenant.session, sessionId, "viewer")).status, 409);
    assert.equal(registry.get(sessionId), undefined);
  });
});

describe("the relay end to end", () => {
  it("carries a published stream from the host to a browser", async () => {
    const tenant = await newTenant("relay");
    const sessionId = await openedStream(tenant);

    const publisherTicket = await ticket(tenant.session, sessionId, "publisher");
    assert.equal(publisherTicket.status, 201);
    const publisher = await connectSocket(sessionId, publisherTicket.body.ticket ?? "");

    const viewerTicket = await ticket(tenant.session, sessionId, "viewer");
    assert.equal(viewerTicket.status, 201);
    const viewer = await connectSocket(sessionId, viewerTicket.body.ticket ?? "");
    await settle();

    // The stream begins with a hello and a snapshot, which is what a viewer needs before any delta.
    publisher.socket.send(
      JSON.stringify({
        type: "hello",
        version: 1,
        session_id: sessionId,
        epoch: "1",
        mode: "blocks",
        columns: 80,
        rows: 24,
      }),
    );
    publisher.socket.send(
      JSON.stringify({
        type: "snapshot.begin",
        epoch: "1",
        seq: "1",
        snapshot_id: randomUUID(),
        bytes: 12,
        chunks: 1,
        sha256: "b".repeat(64),
      }),
    );
    publisher.socket.send(
      JSON.stringify({ type: "snapshot.end", epoch: "1", snapshot_id: randomUUID() }),
    );
    publisher.socket.send(
      JSON.stringify({
        type: "damage",
        epoch: "1",
        seq: "2",
        base_seq: "1",
        changes: [{ op: "remove_block", block_id: randomUUID() }],
      }),
    );

    const hello = await viewer.next();
    assert.equal(hello.type, "hello");
    assert.equal(hello.epoch, "1");
    assert.equal((await viewer.next()).type, "snapshot.begin");
    assert.equal((await viewer.next()).type, "snapshot.end");
    const damage = await viewer.next();
    assert.equal(damage.type, "damage");
    assert.equal(damage.seq, "2");

    viewer.socket.close();
    publisher.socket.close();
  });

  it("refuses a viewer that tries to publish", async () => {
    const tenant = await newTenant("relay-fence");
    const sessionId = await openedStream(tenant);

    const viewerTicket = await ticket(tenant.session, sessionId, "viewer");
    assert.equal(viewerTicket.status, 201);
    const viewer = await connectSocket(sessionId, viewerTicket.body.ticket ?? "");

    const closed = new Promise<number>((resolve) => {
      viewer.socket.once("close", (code) => resolve(code));
    });
    viewer.socket.send(
      JSON.stringify({ type: "damage", epoch: "1", seq: "3", base_seq: "2", changes: [] }),
    );
    assert.equal(await closed, 4400, "a browser can never be a publisher");
  });
});
