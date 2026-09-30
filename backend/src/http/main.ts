/**
 * The entrypoint. Wires configuration, the pool, the verifier, the relay and the routes, then
 * listens.
 *
 * `loadConfig` runs first and throws on missing configuration, so the process cannot come up
 * half-configured. There is no fallback that would let a deployed instance start without a real
 * issuer, a real audience and a real JWKS.
 *
 * The relay is attached to the same HTTP server as the routes, so `/live/<uuid>` upgrades on the
 * same port and under the same origin rules as everything else. One registry and one ticket store
 * are shared between the two halves: the routes mint the tickets the sockets consume.
 */

import { IdentityVerifier } from "../auth/oidc.ts";
import { FailureRateLimiter } from "../auth/session.ts";
import { loadConfig } from "../config.ts";
import { createDatabase } from "../db/pool.ts";
import { releasePublisherLease } from "../shared_session/live.ts";
import { SessionRegistry } from "../shared_session/sessions.ts";
import { attachRelay, type RelayHandle } from "../shared_session/socket.ts";
import { TicketStore } from "../shared_session/tickets.ts";
import { buildRoutes } from "./routes.ts";
import { createHttpServer } from "./server.ts";

function start(): void {
  const config = loadConfig();
  const db = createDatabase(config.databaseUrl);
  const verifier = new IdentityVerifier(config);
  // Ten failures of budget, refilling at one per second, checked before any hash or query.
  const limiter = new FailureRateLimiter(10, 1);

  const registry = new SessionRegistry();
  const tickets = new TicketStore();

  // The routes need to close sockets, and the relay needs the server the routes live on, so one of
  // the two has to be named before it exists. It is assigned on the next statement and nothing calls
  // into it until a request arrives.
  let relay: RelayHandle;

  const server = createHttpServer({
    config,
    routes: buildRoutes({
      config,
      db,
      verifier,
      limiter,
      relay: {
        registry,
        tickets,
        closeSession: (sessionId, code, reason) => relay.closeSession(sessionId, code, reason),
      },
    }),
  });

  relay = attachRelay(server, {
    config,
    tickets,
    registry,
    onPublisherGone: (lease) => {
      // Released in the database rather than in memory, because the relay that admits this session
      // next may be a different process. A failure here is not fatal: the lease expires on its own
      // after thirty seconds, which is exactly why it has an expiry.
      void releasePublisherLease(db, lease.ownerId, lease).catch(() => {});
    },
  });

  server.listen(config.port, config.host, () => {
    console.log(`swiftterm backend listening on ${config.host}:${config.port}`);
  });

  let closing = false;
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => {
      if (closing) return;
      closing = true;
      server.close(() => {
        relay.wss.close();
        void db.close().finally(() => process.exit(0));
      });
    });
  }
}

if (import.meta.filename === process.argv[1]) {
  try {
    start();
  } catch (error) {
    // Configuration errors are the expected failure here, and they must not print a secret.
    console.error(error instanceof Error ? error.message : "startup failed");
    process.exit(1);
  }
}
