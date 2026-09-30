/**
 * The relay's socket layer.
 *
 * One WebSocket endpoint per session. The Mac (publisher) and any number of browsers (viewers)
 * connect to the same path; the ticket presented in the first frame decides which they are, and
 * that decision is enforced for the life of the connection rather than trusted per message.
 *
 * The rules this file exists to hold:
 *
 *   * **A browser can never be a publisher.** A viewer's socket is refused if it sends anything a
 *     publisher would send. This is the relay's whole authorisation model, and it is why the role
 *     comes from the ticket rather than from the first frame's contents.
 *   * **Nothing is trusted before the ticket.** The socket is not attached to a session, given a
 *     role, or allowed to allocate until `auth` has been consumed. A connection that has not
 *     authenticated within five seconds is closed, so an idle socket cannot hold a slot.
 *   * **The Origin is checked at the upgrade**, not after.
 *   * **Frames are forwarded verbatim.** The relay is a forwarder, not a re-encoder: it validates
 *     the envelope it needs for ordering, then relays the publisher's own bytes. Re-serialising
 *     would make the relay a second implementation of the DTOs, and the browser is the authority
 *     on what a frame means.
 *   * **A slow viewer is dropped, never buffered for.** The host must not be able to be stalled by
 *     a browser on a bad connection.
 *   * **Payloads are bounded at the socket.** `maxPayload` is the wire frame limit and
 *     `perMessageDeflate` is off: compression costs memory and CPU per connection, and the frames
 *     are already small and mostly incompressible.
 */

import type { IncomingMessage, Server } from "node:http";
import { WebSocketServer, type WebSocket } from "ws";

import type { Config } from "../config.ts";
import type { RelaySession, SessionRegistry } from "./sessions.ts";
import type { TicketGrant, TicketStore } from "./tickets.ts";

/** The wire frame limit. A frame larger than this is refused by the socket before any handler runs. */
const MAX_PAYLOAD_BYTES = 64 * 1024;

/** How long a connection may exist without presenting a ticket. */
const AUTH_TIMEOUT_MS = 5_000;

/** How often the relay pings, and how long it waits before treating the peer as gone. */
const HEARTBEAT_INTERVAL_MS = 15_000;

/**
 * The frames a publisher may send that carry output.
 *
 * The set exists so an unknown frame is refused as an unknown frame. Checking the epoch first would
 * report a frame the relay has never heard of as `stale_epoch`, which sends the host looking for a
 * fencing problem it does not have.
 */
const PUBLISHER_OUTPUT_FRAMES = new Set([
  "hello",
  "snapshot.begin",
  "snapshot.chunk",
  "snapshot.end",
  "damage",
]);

export interface RelayHandle {
  readonly wss: WebSocketServer;
  /**
   * Close every socket attached to a session. Called when the session is ended or its device
   * revoked: an ended session that keeps carrying frames is not ended.
   */
  closeSession(sessionId: string, code: number, reason: string): void;
}

/** Everything needed to release a publisher's database lease. */
export interface PublisherLeaseRef {
  readonly ownerId: string;
  readonly sessionId: string;
  readonly epoch: number;
  readonly leaseToken: string;
}

export interface RelayDependencies {
  readonly config: Config;
  readonly tickets: TicketStore;
  readonly registry: SessionRegistry;
  /** Called when a session's viewer count changes, so the host can pause encoding at zero. */
  readonly onViewerCount?: (sessionId: string, count: number) => void;
  /**
   * Called when the publisher's socket goes away, so the caller can release the database lease.
   *
   * The relay does not touch the database itself — it holds no credentials — and the owner travels
   * with the reference rather than being looked up later, because by the time this runs the session
   * may already have been dropped from the registry.
   */
  readonly onPublisherGone?: (lease: PublisherLeaseRef) => void;
  /** Injected for tests, so a fake clock can drive the same paths as a real one. */
  readonly now?: () => number;
}

interface Connection {
  readonly socket: WebSocket;
  readonly sessionId: string;
  grant: TicketGrant | null;
  session: RelaySession | null;
  role: "publisher" | "viewer" | null;
  viewerId: string | null;
  authenticated: boolean;
  isAlive: boolean;
  /**
   * Whether the publisher has completed a snapshot on this connection. The contract says the stream
   * begins with a snapshot even when the host already has output, so a damage frame before one is
   * refused rather than forwarded into a viewer that has nothing to apply it to.
   */
  hasSentSnapshot: boolean;
  /** The seq the in-flight snapshot belongs to, so its chunks inherit an ordering key. */
  snapshotSeq: number | null;
  readonly authTimer: NodeJS.Timeout;
}

/**
 * Attach the relay to an HTTP server. The path is `/live/<session-id>`; anything else is left to
 * the HTTP router, which is why this installs its own `upgrade` listener rather than wrapping the
 * server's request handler.
 */
export function attachRelay(server: Server, dependencies: RelayDependencies): RelayHandle {
  const { config, tickets, registry } = dependencies;
  const now = dependencies.now ?? (() => Date.now());

  const wss = new WebSocketServer({
    noServer: true,
    maxPayload: MAX_PAYLOAD_BYTES,
    // Compression costs memory and CPU per connection for frames that are already small.
    perMessageDeflate: false,
  });

  const connections = new Map<WebSocket, Connection>();
  /**
   * Which socket belongs to which viewer. `RelaySession` deliberately knows only viewer ids and
   * their byte budgets — it is the part that must stay testable without sockets — so the mapping
   * from a viewer to a socket lives here, next to the sockets.
   */
  const viewerSockets = new Map<string, WebSocket>();
  /** The publisher's socket per session, so the relay can report the viewer count to it. */
  const publisherSockets = new Map<string, WebSocket>();

  server.on("upgrade", (request, socket, head) => {
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);

    if (!url.pathname.startsWith("/live/")) {
      socket.destroy();
      return;
    }
    // The Origin is checked before the socket exists. A browser origin that is not allowed must
    // never reach the application layer, where a bug could accept it.
    const origin = request.headers.origin;
    if (typeof origin === "string" && !config.allowedOrigins.includes(origin)) {
      socket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
      socket.destroy();
      return;
    }

    const sessionId = url.pathname.slice("/live/".length);
    if (sessionId === "" || sessionId.includes("/")) {
      socket.destroy();
      return;
    }

    wss.handleUpgrade(request, socket, head, (ws) => {
      onConnection(ws, sessionId);
    });
  });

  function onConnection(socket: WebSocket, sessionId: string): void {
    const connection: Connection = {
      socket,
      sessionId,
      grant: null,
      session: null,
      role: null,
      viewerId: null,
      authenticated: false,
      isAlive: true,
      hasSentSnapshot: false,
      snapshotSeq: null,
      authTimer: setTimeout(() => {
        // An unauthenticated socket is not allowed to hold a slot. Closing it is the only way to
        // bound how many idle connections a process carries.
        if (!connection.authenticated) socket.close(4401, "auth_timeout");
      }, AUTH_TIMEOUT_MS),
    };
    connections.set(socket, connection);

    socket.on("pong", () => {
      connection.isAlive = true;
    });

    socket.on("message", (data, isBinary) => {
      handleMessage(connection, data as Buffer, isBinary);
    });

    socket.on("close", () => {
      clearTimeout(connection.authTimer);
      detach(connection);
      connections.delete(socket);
    });

    socket.on("error", () => {
      // A socket error is not worth logging with detail: the payload may be terminal content.
      socket.close();
    });
  }

  function handleMessage(connection: Connection, data: Buffer, isBinary: boolean): void {
    if (isBinary) {
      connection.socket.close(4400, "invalid_frame");
      return;
    }

    const text = data.toString("utf8");
    let frame: unknown;
    try {
      frame = JSON.parse(text);
    } catch {
      connection.socket.close(4400, "invalid_frame");
      return;
    }
    if (frame === null || typeof frame !== "object") {
      connection.socket.close(4400, "invalid_frame");
      return;
    }
    const message = frame as Record<string, unknown>;
    const type = message.type;

    if (!connection.authenticated) {
      if (type !== "auth") {
        connection.socket.close(4401, "unauthorized");
        return;
      }
      authenticate(connection, message);
      return;
    }

    // Authenticated. The role decides what is even parsed, so a viewer cannot reach the publishing
    // path by sending a frame shaped like one.
    if (connection.role === "viewer") {
      handleViewerMessage(connection, message);
      return;
    }
    handlePublisherMessage(connection, message, text);
  }

  function authenticate(connection: Connection, message: Record<string, unknown>): void {
    const ticket = message.ticket;
    if (typeof ticket !== "string" || ticket === "") {
      connection.socket.close(4401, "unauthorized");
      return;
    }

    const grant = tickets.consume(ticket);
    if (grant === null) {
      connection.socket.close(4401, "unauthorized");
      return;
    }
    if (grant.sessionId !== connection.sessionId) {
      // A ticket for another session is not a ticket for this one.
      connection.socket.close(4401, "unauthorized");
      return;
    }

    const session = registry.get(grant.sessionId);
    if (session === undefined || session.ended) {
      connection.socket.close(4404, "session_ended");
      return;
    }

    connection.authenticated = true;
    clearTimeout(connection.authTimer);
    connection.grant = grant;
    connection.session = session;
    connection.role = grant.role;

    if (grant.role === "viewer") {
      const viewerId = connectionId(connection);
      const admitted = session.admitViewer(viewerId);
      if (!admitted.ok) {
        connection.socket.close(4429, admitted.reason);
        return;
      }
      connection.viewerId = viewerId;
      viewerSockets.set(viewerId, connection.socket);

      // Hand a joining viewer the retained stream start, which is the only frame that carries the
      // epoch and geometry it needs before it can ask to resume. Nothing else is sent: a viewer that
      // has applied nothing must wait for a snapshot rather than be shown a mid-stream tail.
      const streamStart = session.streamStart();
      if (streamStart !== null) send(connection.socket, streamStart.payload);

      notifyViewerCount(session);
      return;
    }

    // The publisher. Its epoch is the one the ticket was minted for; a ticket for a superseded
    // epoch is refused here rather than allowed to fence the current publisher out.
    if (String(session.epoch) !== grant.epoch) {
      connection.socket.close(4409, "stale_epoch");
      return;
    }
    publisherSockets.set(session.id, connection.socket);
    session.renewLease();
    notifyViewerCount(session);
  }

  /** A viewer may only resume and acknowledge. Nothing it sends can become terminal output. */
  function handleViewerMessage(connection: Connection, message: Record<string, unknown>): void {
    const session = connection.session;
    if (session === null) return;

    switch (message.type) {
      case "resume": {
        const fromSeq = Number(message.seq);
        if (!Number.isFinite(fromSeq) || fromSeq < 0) {
          connection.socket.close(4400, "invalid_frame");
          return;
        }
        const frames = session.replayFrom(fromSeq);
        if (frames === null) {
          // The gap has been evicted, or the retained history does not start at the stream's
          // beginning. Asking the host for a snapshot is the only correct answer; replaying a hole
          // would render a lie.
          send(connection.socket, {
            type: "resync",
            epoch: String(session.epoch),
          });
          return;
        }
        for (const frame of frames) {
          if (!session.queueFor(connection.viewerId ?? "", frame.bytes)) {
            notifyViewerCount(session);
            connection.socket.close(4429, "viewer_too_slow");
            return;
          }
          send(connection.socket, frame.payload);
        }
        return;
      }
      case "output.ack": {
        const bytes = Number(message.bytes);
        if (connection.viewerId !== null && Number.isFinite(bytes) && bytes > 0) {
          session.acknowledge(connection.viewerId, bytes);
        }
        return;
      }
      default:
        // Including anything shaped like input. Input arrives in B3A, behind a control lease the
        // host approves; until then a viewer's only verbs are resume and ack.
        connection.socket.close(4400, "invalid_frame");
    }
  }

  /** The publisher may publish frames. It can never be sent a viewer's frames back. */
  function handlePublisherMessage(
    connection: Connection,
    message: Record<string, unknown>,
    text: string,
  ): void {
    const session = connection.session;
    if (session === null) return;

    if (message.type === "renew") {
      session.renewLease();
      return;
    }

    if (typeof message.type !== "string" || !PUBLISHER_OUTPUT_FRAMES.has(message.type)) {
      connection.socket.close(4400, "invalid_frame");
      return;
    }

    // Every output frame carries the epoch, and it is checked on each one rather than only at
    // admission: a publisher whose lease was taken over must not be able to keep writing with the
    // connection it already has.
    if (String(message.epoch ?? "") !== String(session.epoch)) {
      connection.socket.close(4409, "stale_epoch");
      return;
    }

    let seq: number;
    switch (message.type) {
      case "hello": {
        // The stream start. It carries no seq of its own, so it takes seq 0 — the position a viewer
        // that has applied nothing resumes from.
        seq = 0;
        connection.hasSentSnapshot = false;
        break;
      }
      case "snapshot.begin": {
        seq = Number(message.seq);
        if (!Number.isInteger(seq) || seq < 0) {
          connection.socket.close(4400, "invalid_frame");
          return;
        }
        connection.snapshotSeq = seq;
        break;
      }
      case "snapshot.chunk":
      case "snapshot.end": {
        // These carry a snapshot id rather than a seq, so they inherit the ordering key of the
        // snapshot they belong to. A chunk with no begin is a publisher bug, and forwarding it
        // would hand a viewer a fragment it can never complete.
        if (connection.snapshotSeq === null) {
          connection.socket.close(4400, "invalid_frame");
          return;
        }
        seq = connection.snapshotSeq;
        if (message.type === "snapshot.end") {
          connection.hasSentSnapshot = true;
          connection.snapshotSeq = null;
        }
        break;
      }
      case "damage": {
        seq = Number(message.seq);
        if (!Number.isInteger(seq) || seq < 1) {
          connection.socket.close(4400, "invalid_frame");
          return;
        }
        if (!connection.hasSentSnapshot) {
          // The stream begins with a snapshot even when the host already has output, so a delta
          // before one would be applied to a viewer's empty state.
          connection.socket.close(4400, "invalid_frame");
          return;
        }
        break;
      }
      default:
        // Unreachable while `PUBLISHER_OUTPUT_FRAMES` and this switch agree. Kept because the two
        // are edited in different places, and a type added to one but not the other would otherwise
        // fall through to the publishing path with an undefined `seq`.
        connection.socket.close(4400, "invalid_frame");
        return;
    }

    const bytes = Buffer.byteLength(text, "utf8");
    if (!session.publish(seq, bytes, text)) {
      // Refused before anything was stored, so nothing to undo. The host is told rather than
      // disconnected: an oversized frame is a bug it can fix, not an attack.
      send(connection.socket, { type: "error", code: "capacity" });
      return;
    }

    for (const viewer of session.viewers) {
      if (!session.queueFor(viewer.id, bytes)) {
        // `queueFor` dropped this viewer for being too far behind. Tell the host the count changed,
        // because at zero it stops encoding.
        viewerSockets.delete(viewer.id);
        notifyViewerCount(session);
        continue;
      }
      const target = viewerSockets.get(viewer.id);
      if (target === undefined) continue;
      send(target, text);
    }
  }

  function notifyViewerCount(session: RelaySession): void {
    dependencies.onViewerCount?.(session.id, session.viewerCount);
    const publisher = publisherSockets.get(session.id);
    if (publisher === undefined) return;
    // `viewer.count` is how the host learns to stop encoding. It is the only frame the relay
    // originates, and it exists so a stream with nobody watching costs the host nothing.
    send(publisher, {
      type: "viewer.count",
      epoch: String(session.epoch),
      count: session.viewerCount,
    });
  }

  function detach(connection: Connection): void {
    const session = connection.session;
    if (session === null) return;
    if (connection.viewerId !== null) {
      session.removeViewer(connection.viewerId);
      viewerSockets.delete(connection.viewerId);
      notifyViewerCount(session);
      return;
    }
    // The publisher is gone. The lease is the caller's to release, because releasing it is a
    // database write and this layer holds no credentials.
    if (publisherSockets.get(session.id) === connection.socket) {
      publisherSockets.delete(session.id);
      const leaseToken = connection.grant?.leaseToken;
      if (leaseToken !== undefined) {
        dependencies.onPublisherGone?.({
          ownerId: session.ownerId,
          sessionId: session.id,
          epoch: session.epoch,
          leaseToken,
        });
      }
    }
  }

  // A peer that stops answering pings is gone even if the socket has not noticed. Without this a
  // half-open connection holds a viewer slot until the OS gives up, which can be minutes.
  const heartbeat = setInterval(() => {
    for (const connection of connections.values()) {
      if (!connection.isAlive) {
        connection.socket.terminate();
        continue;
      }
      connection.isAlive = false;
      connection.socket.ping();
    }
  }, HEARTBEAT_INTERVAL_MS);
  heartbeat.unref();

  wss.on("close", () => {
    clearInterval(heartbeat);
    for (const connection of connections.values()) clearTimeout(connection.authTimer);
    connections.clear();
    viewerSockets.clear();
    publisherSockets.clear();
  });

  void now;

  return {
    wss,
    closeSession(sessionId, code, reason) {
      for (const connection of connections.values()) {
        if (connection.sessionId === sessionId) connection.socket.close(code, reason);
      }
    },
  };
}

function connectionId(connection: Connection): string {
  return `viewer-${connection.sessionId}-${Math.random().toString(36).slice(2, 10)}`;
}

function send(socket: WebSocket, payload: string | Record<string, unknown>): void {
  if (socket.readyState !== socket.OPEN) return;
  socket.send(typeof payload === "string" ? payload : JSON.stringify(payload));
}

/** Exposed for the HTTP router, which mints the tickets these sockets consume. */
export interface TicketRequest {
  readonly sessionId: string;
  readonly accountId: string;
  readonly role: "publisher" | "viewer";
  readonly deviceId?: string;
  /** For a publisher, the lease the route just installed. Released when the socket goes away. */
  readonly leaseToken?: string;
  readonly epoch: string;
}

export function mintTicket(tickets: TicketStore, request: TicketRequest) {
  return tickets.issue({
    role: request.role,
    sessionId: request.sessionId,
    accountId: request.accountId,
    epoch: request.epoch,
    ...(request.deviceId === undefined ? {} : { deviceId: request.deviceId }),
    ...(request.leaseToken === undefined ? {} : { leaseToken: request.leaseToken }),
  });
}

/** Narrower than `IncomingMessage`, so a caller can pass a test double. */
export type UpgradeRequest = Pick<IncomingMessage, "url" | "headers">;
