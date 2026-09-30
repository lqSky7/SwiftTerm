/**
 * TLS configuration for every database connection.
 *
 * The default is full verification, and that is the only posture a deployed service may use. Two
 * escape hatches exist and both are explicit:
 *
 *   PGSSLROOTCERT=<path>       trust a specific CA bundle — the correct answer for a managed
 *                              provider whose CA is not in Node's default store.
 *   DATABASE_SSL_NO_VERIFY=1   skip verification entirely. This exists for a development
 *                              environment behind a TLS-intercepting proxy, where the chain cannot
 *                              be verified at all. It is refused in production.
 *
 * Making it a flag rather than a default matters: an unverified connection is indistinguishable
 * from a verified one at the call site, so the concession has to be something an operator typed.
 */

import { readFileSync } from "node:fs";

import type { ConnectionOptions } from "node:tls";

export function sslConfig(env: NodeJS.ProcessEnv = process.env): ConnectionOptions | boolean {
  const ca = env.PGSSLROOTCERT;
  if (ca !== undefined && ca.trim() !== "") {
    return { ca: readFileSync(ca, "utf8"), rejectUnauthorized: true };
  }

  if (env.DATABASE_SSL_NO_VERIFY === "1") {
    if (env.NODE_ENV === "production") {
      throw new Error(
        "DATABASE_SSL_NO_VERIFY cannot be used with NODE_ENV=production: a deployed service must " +
          "verify the database certificate. Set PGSSLROOTCERT instead.",
      );
    }
    return { rejectUnauthorized: false };
  }

  return { rejectUnauthorized: true };
}
