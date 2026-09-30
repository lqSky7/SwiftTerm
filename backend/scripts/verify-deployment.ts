/**
 * End-to-end check against the deployed relay.
 *
 * Not a test — a verification run. It uses the real database, the real public URL and a real
 * WebSocket, and it asserts the things a deploy can silently break: that the routes exist, that a
 * ticket is minted and spent, that a browser origin is accepted, and above all that the relay
 * **selects the subprotocol**, without which no browser can complete the handshake.
 */

import { createHash, randomBytes, randomUUID } from "node:crypto";
import { WebSocket } from "ws";

import { loadConfig } from "../src/config.ts";
import { createDatabase } from "../src/db/pool.ts";
import { createWebSession, provisionAppUser, registerDevice } from "../src/db/resolvers.ts";
import {
  admitPublisher,
  canonicalRequestDigest,
  createLiveSession,
  newLeaseToken,
} from "../src/shared_session/live.ts";
import { randomToken, sha256 } from "../src/auth/session.ts";

const API = "https://swiftterm.shares.zrok.io";
const WS = "wss://swiftterm.shares.zrok.io";
const WEBSITE_ORIGIN = "https://swiftterm.catinice.workers.dev";
const SUBPROTOCOL = "swiftterm.live.v1";

const config = loadConfig({ ...process.env, ALLOWED_ORIGINS: WEBSITE_ORIGIN });
const db = createDatabase(config.databaseUrl, 4);

const results: { name: string; ok: boolean; detail: string }[] = [];
function check(name: string, ok: boolean, detail = ""): void {
  results.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail === "" ? "" : `  — ${detail}`}`);
}

const runId = randomUUID();
const owner = await provisionAppUser(db, "test://e2e", `e2e-${runId}`, "E2E");
const device = await registerDevice(
  db,
  owner,
  "E2E Mac",
  randomUUID(),
  createHash("sha256").update("registration").digest(),
  createHash("sha256").update(randomBytes(32)).digest(),
);
check("provisioned an account and a device", device.created === true, device.deviceId);

const sessionToken = randomToken().toString("base64url");
const csrfToken = randomToken().toString("base64url");
await createWebSession(db, owner, sha256(sessionToken), sha256(csrfToken), 24);
const cookie = `${config.cookieName}=${sessionToken}; ${config.csrfCookieName}=${csrfToken}`;

function call(
  path: string,
  init: { method?: string; body?: unknown } = {},
): Promise<Response> {
  const headers: Record<string, string> = {
    cookie,
    origin: WEBSITE_ORIGIN,
    [config.csrfHeaderName]: csrfToken,
  };
  const request: RequestInit = { method: init.method ?? "GET", headers };
  if (init.body !== undefined) {
    headers["content-type"] = "application/json";
    request.body = JSON.stringify(init.body);
  }
  return fetch(`${API}${path}`, request);
}

const pane = randomUUID();
const created = await createLiveSession(db, owner, {
  deviceId: device.deviceId,
  localPaneId: pane,
  clientRequestId: randomUUID(),
  requestSha256: canonicalRequestDigest({
    device_id: device.deviceId,
    local_pane_id: pane,
    title: "e2e",
  }),
  title: "e2e",
  maxStreams: 5,
});
check("created a stream in the database", created.outcome === "created", created.outcome);
if (created.sessionId === null) throw new Error("no session id");
const sessionId = created.sessionId;

const listed = await call("/live?limit=5");
const listedBody = (await listed.json()) as { sessions: { id: string }[] };
check(
  "GET /live is live and lists the stream",
  listed.status === 200 && listedBody.sessions.some((row) => row.id === sessionId),
  `HTTP ${listed.status}`,
);

const publisherTicketResponse = await call(`/live/${sessionId}/tickets`, { method: "POST", body: { role: "publisher" } });
const publisherTicketBody = (await publisherTicketResponse.json()) as { ticket: string; epoch: string };
check(
  "minted a publisher ticket",
  publisherTicketResponse.status === 201 && typeof publisherTicketBody.ticket === "string",
  `HTTP ${publisherTicketResponse.status} epoch ${publisherTicketBody.epoch}`,
);

/** Connect, authenticate, and collect frames until told to stop. */
function connect(ticket: string, frames: Record<string, unknown>[]) {
  return new Promise<{ socket: WebSocket; error: string | null }>((resolve) => {
    const socket = new WebSocket(`${WS}/live/${sessionId}`, [SUBPROTOCOL], {
      headers: { origin: WEBSITE_ORIGIN },
    });
    let settled = false;
    socket.on("open", () => {
      // The subprotocol is only echoed by a relay that selects one; `ws` exposes the negotiated
      // value on the socket. A browser treats a missing echo as a failed handshake, so this is the
      // exact condition that decides whether a browser could connect at all.
      if (socket.protocol !== SUBPROTOCOL) {
        if (!settled) {
          settled = true;
          resolve({ socket, error: `subprotocol not selected (got ${JSON.stringify(socket.protocol)})` });
        }
        return;
      }
      socket.send(JSON.stringify({ type: "auth", ticket, client_id: randomUUID() }));
      if (!settled) {
        settled = true;
        resolve({ socket, error: null });
      }
    });
    socket.on("message", (data) => {
      frames.push(JSON.parse(data.toString()) as Record<string, unknown>);
    });
    socket.on("error", (error: Error) => {
      if (!settled) {
        settled = true;
        resolve({ socket, error: error.message });
      }
    });
    setTimeout(() => {
      if (!settled) {
        settled = true;
        resolve({ socket, error: "timed out" });
      }
    }, 15_000);
  });
}

const settle = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const publisherFrames: Record<string, unknown>[] = [];
const publisher = await connect(publisherTicketBody.ticket, publisherFrames);
check("publisher connected over wss with the subprotocol", publisher.error === null, publisher.error ?? "");

const viewerTicketResponse = await call(`/live/${sessionId}/tickets`, { method: "POST", body: { role: "viewer" } });
const viewerTicketBody = (await viewerTicketResponse.json()) as { ticket: string };
const viewerFrames: Record<string, unknown>[] = [];
const viewer = await connect(viewerTicketBody.ticket, viewerFrames);
check("viewer connected over wss with the subprotocol", viewer.error === null, viewer.error ?? "");

if (publisher.error === null && viewer.error === null) {
  await settle(300);
  publisher.socket.send(
    JSON.stringify({
      type: "hello",
      version: 1,
      session_id: sessionId,
      epoch: publisherTicketBody.epoch,
      mode: "blocks",
      columns: 40,
      rows: 12,
    }),
  );
  publisher.socket.send(
    JSON.stringify({
      type: "snapshot.begin",
      epoch: publisherTicketBody.epoch,
      seq: "1",
      snapshot_id: randomUUID(),
      bytes: 8,
      chunks: 1,
      sha256: "c".repeat(64),
    }),
  );
  publisher.socket.send(
    JSON.stringify({
      type: "snapshot.end",
      epoch: publisherTicketBody.epoch,
      snapshot_id: randomUUID(),
    }),
  );
  publisher.socket.send(
    JSON.stringify({
      type: "damage",
      epoch: publisherTicketBody.epoch,
      seq: "2",
      base_seq: "1",
      changes: [{ op: "remove_block", block_id: randomUUID() }],
    }),
  );
  await settle(600);

  const types = viewerFrames.map((frame) => frame.type);
  check("a viewer received the host's hello", types.includes("hello"), types.join(","));
  check("a viewer received the snapshot frames", types.includes("snapshot.begin") && types.includes("snapshot.end"));
  const damage = viewerFrames.find((frame) => frame.type === "damage");
  check("a viewer received the damage frame verbatim", damage?.seq === "2", `seq ${String(damage?.seq)}`);
  check(
    "the host was told the viewer count",
    publisherFrames.some((frame) => frame.type === "viewer.count"),
  );

  // A viewer is not a publisher, and the relay has to say so by closing it.
  const closed = new Promise<number>((resolve) => viewer.socket.once("close", (code) => resolve(code)));
  viewer.socket.send(
    JSON.stringify({
      type: "damage",
      epoch: publisherTicketBody.epoch,
      seq: "3",
      base_seq: "2",
      changes: [],
    }),
  );
  check("a browser attempting to publish was closed with 4400", (await closed) === 4400);
}

publisher.socket.close();
viewer.socket.close();

const ended = await call(`/live/${sessionId}/end`, { method: "POST" });
check("POST /live/:id/end is live", ended.status === 204, `HTTP ${ended.status}`);
const afterEnd = await call(`/live/${sessionId}/tickets`, { method: "POST", body: { role: "viewer" } });
check("an ended session refuses tickets", afterEnd.status === 409, `HTTP ${afterEnd.status}`);

await db.close();

const failed = results.filter((result) => !result.ok);
console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
process.exit(failed.length === 0 ? 0 : 1);
