/**
 * The connection pool, and the only way this service is allowed to run a transaction.
 *
 * node-postgres requires that every statement in a transaction go through the *same* checked-out
 * client — `pool.query` picks an arbitrary backend each time, so a transaction written that way
 * silently splits across connections. `withOwner` therefore hands the callback one client and
 * never exposes the pool's own query method to handlers.
 *
 * It also sets the transaction-local owner context. `set_config(..., true)` is the `true` that
 * matters: it reverts at COMMIT, so a pooled connection cannot carry one request's owner into the
 * next request that borrows it. A query that forgets to set it sees nothing, because every policy
 * compares `owner_id` with `swiftterm.request_user_id()` and NULL matches no row.
 */

import pg from "pg";

import { sslConfig } from "./ssl.ts";

const { Pool } = pg;

export type Queryable = pg.PoolClient;

export interface Database {
  /** Run work with an owner context, so row-level security scopes every statement to that owner. */
  withOwner<T>(ownerId: string | null, work: (client: Queryable) => Promise<T>): Promise<T>;
  /** Run pre-owner work: credential resolution and account provisioning, which happen before an
   * owner is known. Same transaction discipline, no owner context set. */
  withoutOwner<T>(work: (client: Queryable) => Promise<T>): Promise<T>;
  /** Health probe for the readiness endpoint. */
  ping(): Promise<boolean>;
  close(): Promise<void>;
}

export function createDatabase(databaseUrl: string, max = 10): Database {
  const pool = new Pool({
    connectionString: databaseUrl,
    max,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    ssl: sslConfig(),
    // The pooler in front of a managed database speaks plain PostgreSQL; a long statement timeout
    // stops a stuck query from holding a pool slot indefinitely.
    statement_timeout: 15_000,
    application_name: "swiftterm-api",
  });

  // An idle client erroring must not take the process down; the pool replaces it.
  pool.on("error", () => {});

  async function inTransaction<T>(
    ownerId: string | null,
    work: (client: Queryable) => Promise<T>,
  ): Promise<T> {
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      if (ownerId !== null) {
        // set_config with is_local = true: scoped to this transaction, gone at COMMIT.
        await client.query("SELECT set_config('swiftterm.user_id', $1, true)", [ownerId]);
      } else {
        // Explicitly clear it so a reused backend cannot inherit a previous owner.
        await client.query("SELECT set_config('swiftterm.user_id', '', true)");
      }
      const result = await work(client);
      await client.query("COMMIT");
      return result;
    } catch (error) {
      try {
        await client.query("ROLLBACK");
      } catch {
        // A failed rollback means the connection is unusable; releasing it lets the pool discard it.
      }
      throw error;
    } finally {
      client.release();
    }
  }

  return {
    withOwner: (ownerId, work) => inTransaction(ownerId, work),
    withoutOwner: (work) => inTransaction(null, work),
    async ping() {
      try {
        await pool.query("SELECT 1");
        return true;
      } catch {
        return false;
      }
    },
    async close() {
      await pool.end();
    },
  };
}
