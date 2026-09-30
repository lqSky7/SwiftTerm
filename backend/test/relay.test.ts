/**
 * Relay socket tests.
 *
 * A real HTTP server, a real WebSocket, and the real registry — the admission rules are the point of
 * this layer, and a mocked socket would test the mock. The clock and the ticket store are the only
 * injected pieces.
 *
 * The frames the publisher sends here are the real ones: the relay forwards them verbatim, so these
 * tests assert on the bytes a viewer receives rather than on a summary the relay made up.
 */

import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";

import { WebSocket } from "ws";

import { loadConfig } from "../src/config.ts";
import {
  DEFAULT_LIMITS,
  SessionRegistry,
  type OpenRequest,
  type SessionLimits,
} from "../src/shared_session/sessions.ts";
import {
  attachRelay,
  mintTicket,
  type PublisherLeaseRef,
  type RelayHandle,
} from "../src/shared_session/socket.ts";
import { TicketStore } from "../src/shared_session/tickets.ts";

const ORIGIN = "http://localhost:3000";
const config = loadConfig({ ...process.env, ALLOWED_ORIGINS: ORIGIN });

const tickets = new TicketStore();
// The process publisher budget is a real limit, but this file opens far more sessions than a
// deployment would carry at once. Raising it here keeps each test measuring the rule it is named
// for rather than the budget of the file.
const registry = new SessionRegistry({ ...DEFAULT_LIMITS, maxPublishersPerProcess: 1_000 });
let relay: RelayHandle;
let server: Server;
let base = "";
let viewerCounts: { sessionId: string; count: number }[] = [];
let releasedLeases: PublisherLeaseRef[] = [];

function openRequest(): OpenRequest {
  return {
    sessionId: crypto.randomUUID(),
    ownerId: "owner-1",
    deviceId: "device-1",
    localPaneId: crypto.randomUUID(),
    publisherEpoch: 0,
  };
}

/** Open a session and return it with both tickets already minted. */
function sessionWithTickets() {
  const opened = registry.open(openRequest());
  assert.equal(opened.ok, true);
  if (!opened.ok) throw new Error("unreachable");
  const session = opened.session;
  const leaseToken = crypto.randomUUID();
  return {
    session,
    leaseToken,
    publisherTicket: mintTicket(tickets, {
      sessionId: session.id,
      accountId: session.ownerId,
      role: "publisher",
      deviceId: session.deviceId,
      leaseToken,
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

/**
 * Connect and authenticate. There is no admission frame to wait for — the relay's answer to a good
 * ticket is that the socket stays open, and its answer to a bad one is that it closes with a code.
 */
async function connect(sessionId: string, ticket: string, origin = ORIGIN, target = base) {
  const socket = new WebSocket(`${target}/live/${sessionId}`, { headers: { origin } });
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

  const next = (): Promise<string> =>
    new Promise((resolve) => {
      const queued = frames.shift();
      if (queued !== undefined) resolve(queued);
      else waiters.push(resolve);
    });

  const json = async (): Promise<Record<string, unknown>> => JSON.parse(await next()) as Record<string, unknown>;

  socket.send(JSON.stringify({ type: "auth", ticket }));
  return { socket, next, json };
}

/** Resolve with the close code, so a refusal can be asserted rather than a timeout waited out. */
function closedWith(socket: WebSocket): Promise<number> {
  return new Promise((resolve) => {
    socket.once("close", (code) => resolve(code));
  });
}

/** Give the event loop a turn, so a message that should not arrive has had its chance. */
function settle(ms = 60): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * A relay on its own server with its own registry, for the tests that need a different budget.
 *
 * The budget lives on the registry, so a test that wants a small ring or a small socket cannot use
 * the shared one without changing every other test in the file. Each of these is closed in a
 * `finally`, so a failing assertion cannot leak a listening server.
 */
async function spawnRelay(limits: Partial<SessionLimits>) {
  const ownRegistry = new SessionRegistry({ ...DEFAULT_LIMITS, ...limits });
  const ownTickets = new TicketStore();
  const ownServer = createServer();
  const handle = attachRelay(ownServer, {
    config,
    tickets: ownTickets,
    registry: ownRegistry,
    // Without this the spawned relay has no observer, and a test asserting the host was told the
    // count changed would pass by seeing nothing.
    onViewerCount: (sessionId, count) => viewerCounts.push({ sessionId, count }),
  });
  await new Promise<void>((resolve) => ownServer.listen(0, "127.0.0.1", resolve));
  return {
    registry: ownRegistry,
    tickets: ownTickets,
    base: `ws://127.0.0.1:${(ownServer.address() as AddressInfo).port}`,
    async close() {
      handle.wss.close();
      for (const client of handle.wss.clients) client.terminate();
      await new Promise<void>((resolve) => ownServer.close(() => resolve()));
    },
  };
}

/** The three frames that open a stream, so a test can reach the damage phase. */
function openStream(socket: WebSocket, sessionId: string, epoch = 0): void {
  socket.send(
    JSON.stringify({
      type: "hello",
      version: 1,
      session_id: sessionId,
      epoch: String(epoch),
      mode: "blocks",
      columns: 80,
      rows: 24,
    }),
  );
  socket.send(
    JSON.stringify({
      type: "snapshot.begin",
      epoch: String(epoch),
      seq: "1",
      snapshot_id: crypto.randomUUID(),
      bytes: 10,
      chunks: 1,
      sha256: "a".repeat(64),
    }),
  );
  socket.send(JSON.stringify({ type: "snapshot.end", epoch: String(epoch), snapshot_id: "s" }));
}

before(async () => {
  server = createServer();
  relay = attachRelay(server, {
    config,
    tickets,
    registry,
    onViewerCount: (sessionId, count) => viewerCounts.push({ sessionId, count }),
    onPublisherGone: (lease) => releasedLeases.push(lease),
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `ws://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

after(async () => {
  relay.wss.close();
  // A test that fails mid-socket leaves its connection open, and `server.close()` waits for every
  // open connection before calling back — so without this one failure turns into a hang.
  for (const client of relay.wss.clients) client.terminate();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("admission", () => {
  it("admits a publisher with a publisher ticket", async () => {
    const { session, publisherTicket } = sessionWithTickets();
    const { socket } = await connect(session.id, publisherTicket);
    assert.equal(socket.readyState, socket.OPEN, "the socket stays open, which is the acceptance");
    socket.close();
  });

  it("admits a viewer and tells the host the count changed", async () => {
    const { session, viewerTicket } = sessionWithTickets();
    const { socket } = await connect(session.id, viewerTicket);
    // Admission happens on the server, so it is a tick behind the client's `send`.
    await settle();
    assert.equal(session.viewerCount, 1);
    // Filtered to this session: an earlier test's socket closes asynchronously, and its count would
    // otherwise land in the array this test is reading.
    assert.deepEqual(
      viewerCounts.filter((entry) => entry.sessionId === session.id),
      [{ sessionId: session.id, count: 1 }],
    );
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

  it("closes a publisher whose epoch has been superseded", async () => {
    const { session, publisherTicket } = sessionWithTickets();
    const { socket } = await connect(session.id, publisherTicket);
    // The database moved on while this connection was open — another publisher was admitted.
    session.adoptEpoch(session.epoch + 1);
    const closed = closedWith(socket);
    socket.send(
      JSON.stringify({ type: "hello", version: 1, session_id: session.id, epoch: "0", mode: "blocks", columns: 80, rows: 24 }),
    );
    assert.equal(await closed, 4409, "a fenced publisher must not keep writing");
  });

  it("refuses a damage frame before the stream has a snapshot", async () => {
    const { session, publisherTicket } = sessionWithTickets();
    const { socket } = await connect(session.id, publisherTicket);
    const closed = closedWith(socket);
    // The stream begins with a snapshot even when the host already has output, so a delta now would
    // be applied to a viewer's empty state.
    socket.send(JSON.stringify({ type: "damage", epoch: "0", seq: "1", base_seq: "0", changes: [] }));
    assert.equal(await closed, 4400);
  });

  it("refuses a snapshot chunk with no begin", async () => {
    const { session, publisherTicket } = sessionWithTickets();
    const { socket } = await connect(session.id, publisherTicket);
    const closed = closedWith(socket);
    socket.send(
      JSON.stringify({ type: "snapshot.chunk", epoch: "0", snapshot_id: "s", index: 0, data: "" }),
    );
    assert.equal(await closed, 4400);
  });
});

describe("relaying", () => {
  it("carries a stream to a viewer verbatim, in order", async () => {
    const { session, publisherTicket, viewerTicket } = sessionWithTickets();
    const viewer = await connect(session.id, viewerTicket);
    const publisher = await connect(session.id, publisherTicket);

    openStream(publisher.socket, session.id);
    const hello = await viewer.json();
    assert.equal(hello.type, "hello");
    assert.equal(hello.session_id, session.id, "the publisher's own hello, forwarded unchanged");
    assert.equal((await viewer.json()).type, "snapshot.begin");
    assert.equal((await viewer.json()).type, "snapshot.end");

    publisher.socket.send(
      JSON.stringify({ type: "damage", epoch: "0", seq: "2", base_seq: "1", changes: [] }),
    );
    const damage = await viewer.json();
    assert.equal(damage.type, "damage");
    assert.equal(damage.seq, "2", "the publisher's own seq, not one the relay invented");
    assert.equal(session.lastSeq, 2);

    viewer.socket.close();
    publisher.socket.close();
  });

  it("hands a joining viewer the retained stream start", async () => {
    const { session, publisherTicket, viewerTicket } = sessionWithTickets();
    const publisher = await connect(session.id, publisherTicket);
    openStream(publisher.socket, session.id);
    await settle();

    // This viewer arrives after the hello. It is the only frame carrying the epoch and geometry, so
    // it is what lets the viewer know enough to ask for a resume.
    const viewer = await connect(session.id, viewerTicket);
    const hello = await viewer.json();
    assert.equal(hello.type, "hello");
    assert.equal(hello.epoch, "0");

    viewer.socket.close();
    publisher.socket.close();
  });

  it("answers a viewer that is behind with a replay", async () => {
    const { session, publisherTicket, viewerTicket } = sessionWithTickets();
    const publisher = await connect(session.id, publisherTicket);
    openStream(publisher.socket, session.id);
    publisher.socket.send(
      JSON.stringify({ type: "damage", epoch: "0", seq: "2", base_seq: "1", changes: [] }),
    );
    await settle();

    const viewer = await connect(session.id, viewerTicket);
    await viewer.json(); // the retained hello
    viewer.socket.send(JSON.stringify({ type: "resume", epoch: "0", seq: "1" }));
    const damage = await viewer.json();
    assert.equal(damage.type, "damage");
    assert.equal(damage.seq, "2");

    viewer.socket.close();
    publisher.socket.close();
  });

  it("asks for a resync when the gap has been evicted", async () => {
    // A ring this small cannot hold four frames, so the oldest are gone before the viewer arrives.
    const own = await spawnRelay({ replayBytesPerSession: 20 });
    try {
      const opened = own.registry.open(openRequest());
      assert.equal(opened.ok, true);
      if (!opened.ok) return;
      const session = opened.session;
      for (let seq = 1; seq <= 4; seq += 1) session.publish(seq, 10, `frame-${seq}`);

      const viewerTicket = mintTicket(own.tickets, {
        sessionId: session.id,
        accountId: session.ownerId,
        role: "viewer",
        epoch: String(session.epoch),
      }).ticket;
      const viewer = await connect(session.id, viewerTicket, ORIGIN, own.base);
      viewer.socket.send(JSON.stringify({ type: "resume", epoch: "0", seq: "1" }));
      const reply = await viewer.json();
      // A hole is never replayed. The viewer is told to resync, and the host will send a snapshot.
      assert.equal(reply.type, "resync");
      viewer.socket.close();
    } finally {
      await own.close();
    }
  });

  it("drops a viewer that cannot keep up rather than stalling the host", async () => {
    // A budget that holds the opening snapshot but not the delta after it, so the drop happens at a
    // known point rather than at whichever frame happens to cross the line.
    const own = await spawnRelay({ maxPendingBytesPerSocket: 1_000 });
    try {
      const opened = own.registry.open(openRequest());
      assert.equal(opened.ok, true);
      if (!opened.ok) return;
      const session = opened.session;

      const publisherTicket = mintTicket(own.tickets, {
        sessionId: session.id,
        accountId: session.ownerId,
        role: "publisher",
        deviceId: session.deviceId,
        leaseToken: crypto.randomUUID(),
        epoch: String(session.epoch),
      }).ticket;
      const viewerTicket = mintTicket(own.tickets, {
        sessionId: session.id,
        accountId: session.ownerId,
        role: "viewer",
        epoch: String(session.epoch),
      }).ticket;

      const viewer = await connect(session.id, viewerTicket, ORIGIN, own.base);
      const publisher = await connect(session.id, publisherTicket, ORIGIN, own.base);
      await settle();
      assert.equal(session.viewerCount, 1, "the viewer is attached before anything is published");

      openStream(publisher.socket, session.id);
      await settle();
      assert.equal(session.viewerCount, 1, "the opening snapshot fits the budget");

      // The host is told, because at zero viewers it stops encoding.
      const before = viewerCounts.length;
      publisher.socket.send(
        JSON.stringify({
          type: "damage",
          epoch: "0",
          seq: "2",
          base_seq: "1",
          changes: ["x".repeat(2_000)],
        }),
      );
      await settle();

      assert.equal(session.viewerCount, 0, "the slow viewer was dropped, not buffered for");
      assert.equal(
        viewerCounts.slice(before).some((entry) => entry.count === 0),
        true,
        "the host was told the count reached zero",
      );
      viewer.socket.close();
      publisher.socket.close();
    } finally {
      await own.close();
    }
  });
});

describe("the publisher's lease", () => {
  it("is handed back when the publisher's socket goes away", async () => {
    const { session, publisherTicket, leaseToken } = sessionWithTickets();
    releasedLeases = [];
    const publisher = await connect(session.id, publisherTicket);
    const closed = closedWith(publisher.socket);
    publisher.socket.close();
    await closed;
    await settle();

    assert.equal(releasedLeases.length, 1);
    assert.deepEqual(releasedLeases[0], {
      ownerId: session.ownerId,
      sessionId: session.id,
      epoch: session.epoch,
      leaseToken,
    });
  });

  it("is not released by a viewer leaving", async () => {
    const { session, viewerTicket } = sessionWithTickets();
    releasedLeases = [];
    const viewer = await connect(session.id, viewerTicket);
    const closed = closedWith(viewer.socket);
    viewer.socket.close();
    await closed;
    await settle();
    assert.deepEqual(releasedLeases, []);
  });
});

describe("ending a session", () => {
  it("closes the sockets attached to it", async () => {
    const { session, viewerTicket, publisherTicket } = sessionWithTickets();
    const viewer = await connect(session.id, viewerTicket);
    const publisher = await connect(session.id, publisherTicket);

    const viewerClosed = closedWith(viewer.socket);
    const publisherClosed = closedWith(publisher.socket);
    relay.closeSession(session.id, 4404, "session_ended");

    assert.equal(await viewerClosed, 4404);
    assert.equal(await publisherClosed, 4404);
  });
});
