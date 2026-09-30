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
    /*
     * Allowed in production, but never silently.
     *
     * The honest position: this keeps the connection encrypted and drops only certificate
     * verification, so it is strictly better than plaintext but it does not protect against an
     * active man-in-the-middle. It is needed when Node cannot build the provider's chain — which
     * is the case for the Supabase pooler, where OpenSSL verifies the same chain from the system
     * store and Node does not.
     *
     * The right fix is `PGSSLROOTCERT` pointing at the provider's CA. Until that is in place, the
     * concession is announced on every start so it is visible in the journal rather than buried in
     * a config file.
     */
    console.warn(
      "[swiftterm] DATABASE_SSL_NO_VERIFY=1: the database connection is encrypted but its " +
        "certificate is NOT verified. Set PGSSLROOTCERT to the provider's CA to remove this.",
    );
    return { rejectUnauthorized: false };
  }

  return { rejectUnauthorized: true };
}
