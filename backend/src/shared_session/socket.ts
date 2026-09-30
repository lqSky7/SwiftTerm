/**
 * The relay's socket layer.
 *
 * One WebSocket endpoint per session. The Mac (publisher) and any number of browsers (viewers)
 * connect to the same path; the ticket presented in the first frame decides which they are, and
 * that decision is enforced for the life of the connection rather than trusted per message.
 *
 * The rules this file exists to hold:
 *
 *   * **A browser can never be a publisher.** A viewer ticket's socket is refused if it sends
 *     anything a publisher would send. This is the relay's whole authorisation model in one line,
 *     and it is why the role comes from the ticket rather than from the first frame's contents.
 *   * **Nothing is trusted before the ticket.** The socket is not attached to a session, given a
 *     role, or allowed to allocate until `auth` has been consumed. A connection that has not
 *     authenticated within five seconds is closed, so an idle socket cannot hold a slot.
 *   * **The Origin is checked at the upgrade**, not after. A socket that would be rejected should
 *     never reach the application layer.
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

export interface RelayDependencies {
  readonly config: Config;
  readonly tickets: TicketStore;
  readonly registry: SessionRegistry;
  /** Called when a session's viewer count changes, so the host can pause encoding at zero. */
  readonly onViewerCount?: (sessionId: string, count: number) => void;
  /** Injected for tests, so a fake socket can drive the same paths as a real one. */
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
  readonly authTimer: NodeJS.Timeout;
}

/**
 * Attach the relay to an HTTP server. The path is `/live/<session-id>`; anything else is left to
 * the HTTP router, which is why this installs its own `upgrade` listener rather than wrapping the
 * server's request handler.
 */
export function attachRelay(server: Server, dependencies: RelayDependencies): WebSocketServer {
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
      void handleMessage(connection, data as Buffer, isBinary);
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

  async function handleMessage(
    connection: Connection,
    data: Buffer,
    isBinary: boolean,
  ): Promise<void> {
    if (isBinary) {
      connection.socket.close(4400, "invalid_frame");
      return;
    }

    let frame: unknown;
    try {
      frame = JSON.parse(data.toString("utf8"));
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
      await authenticate(connection, message);
      return;
    }

    // Authenticated. The role decides what is even parsed, so a viewer cannot reach the publishing
    // path by sending a frame shaped like one.
    if (connection.role === "viewer") {
      handleViewerMessage(connection, message);
      return;
    }
    handlePublisherMessage(connection, message);
  }

  async function authenticate(connection: Connection, message: Record<string, unknown>): Promise<void> {
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
      const admitted = session.admitViewer(connectionId(connection));
      if (!admitted.ok) {
        connection.socket.close(4429, admitted.reason);
        return;
      }
      connection.viewerId = connectionId(connection);
      viewerSockets.set(connection.viewerId, connection.socket);
      send(connection.socket, {
        type: "hello",
        version: 1,
        session_id: session.id,
        epoch: String(session.epoch),
      });
      dependencies.onViewerCount?.(session.id, session.viewerCount);
      return;
    }

    // The publisher. Its epoch is the one the ticket was minted for; a ticket for a superseded
    // epoch is refused here rather than allowed to fence the current publisher out.
    if (String(session.epoch) !== grant.epoch) {
      connection.socket.close(4409, "stale_epoch");
      return;
    }
    session.renewLease();
    send(connection.socket, {
      type: "hello",
      version: 1,
      session_id: session.id,
      epoch: String(session.epoch),
    });
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
          // The gap has been evicted. Asking the host for a snapshot is the only correct answer;
          // replaying a hole would render a lie.
          send(connection.socket, { type: "resync", epoch: String(session.epoch) });
          return;
        }
        send(connection.socket, {
          type: "replay",
          epoch: String(session.epoch),
          seq: String(session.lastSeq),
          count: frames.length,
        });
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
  function handlePublisherMessage(connection: Connection, message: Record<string, unknown>): void {
    const session = connection.session;
    if (session === null) return;

    switch (message.type) {
      case "damage":
      case "snapshot.chunk": {
        const bytes = Number(message.bytes);
        const size = Number.isFinite(bytes) && bytes > 0 ? bytes : 0;
        const frame = session.publish(size);
        if (frame === null) {
          // Refused before anything was stored, so nothing to undo.
          send(connection.socket, { type: "error", code: "capacity" });
          return;
        }
        for (const viewer of session.viewers) {
          if (!session.queueFor(viewer.id, size)) {
            // `queueFor` dropped this viewer for being too far behind. Tell the host the count
            // changed, because at zero it stops encoding.
            viewerSockets.delete(viewer.id);
            dependencies.onViewerCount?.(session.id, session.viewerCount);
            continue;
          }
          const target = viewerSockets.get(viewer.id);
          if (target === undefined) continue;
          send(target, {
            type: "damage",
            epoch: String(session.epoch),
            seq: String(frame.seq),
          });
        }
        return;
      }
      case "renew": {
        session.renewLease();
        return;
      }
      default:
        connection.socket.close(4400, "invalid_frame");
    }
  }

  function detach(connection: Connection): void {
    const session = connection.session;
    if (session === null) return;
    if (connection.viewerId !== null) {
      session.removeViewer(connection.viewerId);
      viewerSockets.delete(connection.viewerId);
      dependencies.onViewerCount?.(session.id, session.viewerCount);
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
  });

  void now;
  return wss;
}

function connectionId(connection: Connection): string {
  return `viewer-${connection.sessionId}-${Math.random().toString(36).slice(2, 10)}`;
}

function send(socket: WebSocket, payload: unknown): void {
  if (socket.readyState !== socket.OPEN) return;
  socket.send(JSON.stringify(payload));
}

/** Exposed for the HTTP router, which mints the tickets these sockets consume. */
export interface TicketRequest {
  readonly sessionId: string;
  readonly accountId: string;
  readonly role: "publisher" | "viewer";
  readonly deviceId?: string;
  readonly epoch: string;
}

export function mintTicket(tickets: TicketStore, request: TicketRequest) {
  return tickets.issue({
    role: request.role,
    sessionId: request.sessionId,
    accountId: request.accountId,
    epoch: request.epoch,
    ...(request.deviceId === undefined ? {} : { deviceId: request.deviceId }),
  });
}

/** Narrower than `IncomingMessage`, so a caller can pass a test double. */
export type UpgradeRequest = Pick<IncomingMessage, "url" | "headers">;
