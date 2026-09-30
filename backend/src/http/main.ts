/**
 * The entrypoint. Wires configuration, the pool, the verifier and the routes, then listens.
 *
 * `loadConfig` runs first and throws on missing configuration, so the process cannot come up
 * half-configured. There is no fallback that would let a deployed instance start without a real
 * issuer, a real audience and a real JWKS.
 */

import { IdentityVerifier } from "../auth/oidc.ts";
import { FailureRateLimiter } from "../auth/session.ts";
import { loadConfig } from "../config.ts";
import { createDatabase } from "../db/pool.ts";
import { buildRoutes } from "./routes.ts";
import { createHttpServer } from "./server.ts";

function start(): void {
  const config = loadConfig();
  const db = createDatabase(config.databaseUrl);
  const verifier = new IdentityVerifier(config);
  // Ten failures of budget, refilling at one per second, checked before any hash or query.
  const limiter = new FailureRateLimiter(10, 1);
  const routes = buildRoutes({ config, db, verifier, limiter });
  const server = createHttpServer({ config, routes });

  server.listen(config.port, config.host, () => {
    console.log(`swiftterm backend listening on ${config.host}:${config.port}`);
  });

  let closing = false;
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => {
      if (closing) return;
      closing = true;
      server.close(() => {
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
