/**
 * Relay socket tests.
 *
 * A real HTTP server, a real WebSocket, and the real registry — the admission rules are the point
 * of this layer, and a mocked socket would test the mock. The clock and the ticket store are the
 * only injected pieces.
 */

import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";

import { WebSocket } from "ws";

import { loadConfig } from "../src/config.ts";
import { SessionRegistry, type OpenRequest } from "../src/shared_session/sessions.ts";
import { attachRelay, mintTicket } from "../src/shared_session/socket.ts";
import { TicketStore } from "../src/shared_session/tickets.ts";

const ORIGIN = "http://localhost:3000";
const config = loadConfig({ ...process.env, ALLOWED_ORIGINS: ORIGIN });

const tickets = new TicketStore();
const registry = new SessionRegistry();
let server: Server;
let base = "";
let viewerCounts: { sessionId: string; count: number }[] = [];

function openRequest(): OpenRequest {
  return {
    ownerId: "owner-1",
    deviceId: "device-1",
    localPaneId: "pane-1",
    clientRequestId: crypto.randomUUID(),
    requestDigest: "digest-1",
  };
}

/** Open a session and return it with both tickets already minted. */
function sessionWithTickets() {
  const opened = registry.open(openRequest());
  assert.equal(opened.ok, true);
  if (!opened.ok) throw new Error("unreachable");
  const session = opened.session;
  return {
    session,
    publisherTicket: mintTicket(tickets, {
      sessionId: session.id,
      accountId: session.ownerId,
      role: "publisher",
      deviceId: session.deviceId,
      epoch: String(session.epoch),
    }).ticket,
    viewerTicket: mintTicket(tickets, {
      sessionId: session.id,
      accountId: session.ownerId,
      role: "viewer",
      epoch: String(session.epoch),
    }).ticket,
  };
}

/** Connect, authenticate, and resolve with the first frame the relay sends back. */
async function connect(sessionId: string, ticket: string, origin = ORIGIN) {
  const socket = new WebSocket(`${base}/live/${sessionId}`, { headers: { origin } });
  const frames: Record<string, unknown>[] = [];
  const waiters: ((frame: Record<string, unknown>) => void)[] = [];

  socket.on("message", (data) => {
    const frame = JSON.parse(data.toString()) as Record<string, unknown>;
    const waiter = waiters.shift();
    if (waiter !== undefined) waiter(frame);
    else frames.push(frame);
  });

  await new Promise<void>((resolve, reject) => {
    socket.once("open", () => resolve());
    socket.once("error", reject);
  });

  const next = (): Promise<Record<string, unknown>> =>
    new Promise((resolve) => {
      const queued = frames.shift();
      if (queued !== undefined) resolve(queued);
      else waiters.push(resolve);
    });

  socket.send(JSON.stringify({ type: "auth", ticket }));
  const hello = await next();
  return { socket, hello, next, frames };
}

/** Resolve with the close code, so a refusal can be asserted rather than a timeout waited out. */
function closedWith(socket: WebSocket): Promise<number> {
  return new Promise((resolve) => {
    socket.once("close", (code) => resolve(code));
  });
}

before(async () => {
  server = createServer();
  attachRelay(server, {
    config,
    tickets,
    registry,
    onViewerCount: (sessionId, count) => viewerCounts.push({ sessionId, count }),
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `ws://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

after(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("admission", () => {
  it("admits a publisher with a publisher ticket", async () => {
    const { session, publisherTicket } = sessionWithTickets();
    const { socket, hello } = await connect(session.id, publisherTicket);
    assert.equal(hello.type, "hello");
    assert.equal(hello.session_id, session.id);
    assert.equal(hello.epoch, "1");
    socket.close();
  });

  it("admits a viewer and tells the host the count changed", async () => {
    const { session, viewerTicket } = sessionWithTickets();
    viewerCounts = [];
    const { socket, hello } = await connect(session.id, viewerTicket);
    assert.equal(hello.type, "hello");
    assert.equal(session.viewerCount, 1);
    assert.deepEqual(viewerCounts, [{ sessionId: session.id, count: 1 }]);
    socket.close();
  });

  it("refuses a ticket that was never issued", async () => {
    const { session } = sessionWithTickets();
    const socket = new WebSocket(`${base}/live/${session.id}`, { headers: { origin: ORIGIN } });
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    const closed = closedWith(socket);
    socket.send(JSON.stringify({ type: "auth", ticket: "not-a-real-ticket" }));
    assert.equal(await closed, 4401);
  });

  it("refuses a ticket minted for a different session", async () => {
    const a = sessionWithTickets();
    const b = sessionWithTickets();
    const socket = new WebSocket(`${base}/live/${a.session.id}`, { headers: { origin: ORIGIN } });
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    const closed = closedWith(socket);
    // b's ticket is genuine, but it is not for a's session.
    socket.send(JSON.stringify({ type: "auth", ticket: b.publisherTicket }));
    assert.equal(await closed, 4401);
  });

  it("spends a ticket, so a second socket cannot reuse it", async () => {
    const { session, viewerTicket } = sessionWithTickets();
    const first = await connect(session.id, viewerTicket);
    first.socket.close();

    const second = new WebSocket(`${base}/live/${session.id}`, { headers: { origin: ORIGIN } });
    await new Promise<void>((resolve) => second.once("open", () => resolve()));
    const closed = closedWith(second);
    second.send(JSON.stringify({ type: "auth", ticket: viewerTicket }));
    assert.equal(await closed, 4401);
  });

  it("refuses a frame sent before authenticating", async () => {
    const { session } = sessionWithTickets();
    const socket = new WebSocket(`${base}/live/${session.id}`, { headers: { origin: ORIGIN } });
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    const closed = closedWith(socket);
    socket.send(JSON.stringify({ type: "damage", bytes: 10 }));
    assert.equal(await closed, 4401);
  });

  it("refuses an upgrade from an origin that is not allowed", async () => {
    const { session, viewerTicket } = sessionWithTickets();
    const socket = new WebSocket(`${base}/live/${session.id}`, {
      headers: { origin: "http://evil.example" },
    });
    const outcome = await new Promise<string>((resolve) => {
      socket.once("error", () => resolve("rejected"));
      socket.once("open", () => resolve("accepted"));
    });
    assert.equal(outcome, "rejected");
  });

  it("refuses a ticket for a session that has ended", async () => {
    const { session, viewerTicket } = sessionWithTickets();
    registry.end(session.id);
    const socket = new WebSocket(`${base}/live/${session.id}`, { headers: { origin: ORIGIN } });
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    const closed = closedWith(socket);
    socket.send(JSON.stringify({ type: "auth", ticket: viewerTicket }));
    assert.equal(await closed, 4404);
  });
});

describe("roles", () => {
  it("closes a viewer that sends a publisher frame", async () => {
    const { session, viewerTicket } = sessionWithTickets();
    const { socket } = await connect(session.id, viewerTicket);
    const closed = closedWith(socket);
    // A browser attempting to publish. This is the relay's whole authorisation model.
    socket.send(JSON.stringify({ type: "damage", bytes: 10 }));
    assert.equal(await closed, 4400);
  });

  it("closes a viewer that sends anything shaped like input", async () => {
    const { session, viewerTicket } = sessionWithTickets();
    const { socket } = await connect(session.id, viewerTicket);
    const closed = closedWith(socket);
    // Input belongs to B3A, behind a lease the host approves. Until then it is refused outright.
    socket.send(JSON.stringify({ type: "input", operation: { kind: "text", text: "rm -rf /" } }));
    assert.equal(await closed, 4400);
  });

  it("closes a publisher that sends an unknown frame", async () => {
    const { session, publisherTicket } = sessionWithTickets();
    const { socket } = await connect(session.id, publisherTicket);
    const closed = closedWith(socket);
    socket.send(JSON.stringify({ type: "teleport" }));
    assert.equal(await closed, 4400);
  });
});

describe("relaying", () => {
  it("carries a published frame to a viewer", async () => {
    const { session, publisherTicket, viewerTicket } = sessionWithTickets();
    const viewer = await connect(session.id, viewerTicket);
    const publisher = await connect(session.id, publisherTicket);

    publisher.socket.send(JSON.stringify({ type: "damage", bytes: 42 }));
    const relayed = await viewer.next();
    assert.equal(relayed.type, "damage");
    assert.equal(relayed.seq, "1");
    assert.equal(session.lastSeq, 1);

    viewer.socket.close();
    publisher.socket.close();
  });

  it("answers a viewer that is behind with a replay", async () => {
    const { session, publisherTicket, viewerTicket } = sessionWithTickets();
    const publisher = await connect(session.id, publisherTicket);
    publisher.socket.send(JSON.stringify({ type: "damage", bytes: 10 }));
    publisher.socket.send(JSON.stringify({ type: "damage", bytes: 10 }));

    const viewer = await connect(session.id, viewerTicket);
    viewer.socket.send(JSON.stringify({ type: "resume", seq: 0 }));
    const reply = await viewer.next();
    assert.equal(reply.type, "replay");
    assert.equal(reply.count, 2);

    viewer.socket.close();
    publisher.socket.close();
  });

  it("asks for a resync when the gap has been evicted", async () => {
    const tiny = new SessionRegistry({
      maxStreamsPerAccount: 5,
      maxViewersPerStream: 10,
      maxPublishersPerProcess: 25,
      replayBytesPerSession: 20,
      replayWindowMs: 30_000,
      maxPendingBytesPerSocket: 1024 * 1024,
      aggregateBytes: 256 * 1024 * 1024,
      publisherLeaseMs: 30_000,
    });
    const opened = tiny.open(openRequest());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    const session = opened.session;
    for (let index = 0; index < 5; index += 1) session.publish(10);

    const viewerTicket = mintTicket(tickets, {
      sessionId: session.id,
      accountId: session.ownerId,
      role: "viewer",
      epoch: String(session.epoch),
    }).ticket;
    const viewer = await connect(session.id, viewerTicket);
    viewer.socket.send(JSON.stringify({ type: "resume", seq: 0 }));
    const reply = await viewer.next();
    // A hole is never replayed. The viewer is told to resync, and the host will send a snapshot.
    assert.equal(reply.type, "resync");
    viewer.socket.close();
  });

  it("drops a viewer that cannot keep up rather than stalling the host", async () => {
    const small = new SessionRegistry({
      maxStreamsPerAccount: 5,
      maxViewersPerStream: 10,
      maxPublishersPerProcess: 25,
      replayBytesPerSession: 8 * 1024 * 1024,
      replayWindowMs: 30_000,
      maxPendingBytesPerSocket: 100,
      aggregateBytes: 256 * 1024 * 1024,
      publisherLeaseMs: 30_000,
    });
    const opened = small.open(openRequest());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    const session = opened.session;

    const publisherTicket = mintTicket(tickets, {
      sessionId: session.id,
      accountId: session.ownerId,
      role: "publisher",
      deviceId: session.deviceId,
      epoch: String(session.epoch),
    }).ticket;
    const viewerTicket = mintTicket(tickets, {
      sessionId: session.id,
      accountId: session.ownerId,
      role: "viewer",
      epoch: String(session.epoch),
    }).ticket;

    const viewer = await connect(session.id, viewerTicket);
    const publisher = await connect(session.id, publisherTicket);
    assert.equal(session.viewerCount, 1);

    // Each frame is 60 bytes against a 100-byte socket budget, so the second exceeds it. The
    // viewer is dropped; the host is told, because at zero viewers it stops encoding.
    publisher.socket.send(JSON.stringify({ type: "damage", bytes: 60 }));
    publisher.socket.send(JSON.stringify({ type: "damage", bytes: 60 }));
    await new Promise((resolve) => setTimeout(resolve, 50));

    assert.equal(session.viewerCount, 0, "the slow viewer was dropped");
    viewer.socket.close();
    publisher.socket.close();
  });
});
