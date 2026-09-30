/**
 * Applies `migrations/*.sql` in filename order, each in its own transaction, recording what has
 * been applied.
 *
 * Its own bookkeeping lives in `swiftterm_meta`, deliberately outside the `swiftterm` schema: the
 * schema is created *by* migration 001, so a tracker that lived inside it could not record the
 * migration that created it.
 *
 * A migration file that fails leaves the database exactly as it was, because the whole file runs in
 * one transaction. `000_roles.sql` and `001_identity.sql` are deliberately separate files for the
 * same reason: PostgreSQL does not make a new role membership visible to privilege checks inside
 * the transaction that granted it, so the file that creates the roles cannot also act as one.
 */

import { readdir, readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import pg from "pg";

import { sslConfig } from "./ssl.ts";

const { Client } = pg;

const migrationsDir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "migrations");

export interface MigrationResult {
  readonly applied: readonly string[];
  readonly skipped: readonly string[];
}

export async function migrate(
  connectionString: string,
  log: (message: string) => void = () => {},
): Promise<MigrationResult> {
  const client = new Client({
    connectionString,
    application_name: "swiftterm-migrate",
    ssl: sslConfig(),
  });
  await client.connect();
  const applied: string[] = [];
  const skipped: string[] = [];

  try {
    await client.query("BEGIN");
    await client.query("CREATE SCHEMA IF NOT EXISTS swiftterm_meta");
    await client.query(`
      CREATE TABLE IF NOT EXISTS swiftterm_meta.applied_migrations (
        filename text PRIMARY KEY,
        applied_at timestamptz NOT NULL DEFAULT now()
      )`);
    await client.query("COMMIT");

    const files = (await readdir(migrationsDir)).filter((name) => name.endsWith(".sql")).sort();
    const { rows } = await client.query<{ filename: string }>(
      "SELECT filename FROM swiftterm_meta.applied_migrations",
    );
    const done = new Set(rows.map((row) => row.filename));

    for (const filename of files) {
      if (done.has(filename)) {
        skipped.push(filename);
        continue;
      }
      const sql = await readFile(join(migrationsDir, filename), "utf8");
      log(`applying ${filename}`);
      try {
        await client.query("BEGIN");
        await client.query(sql);
        await client.query(
          "INSERT INTO swiftterm_meta.applied_migrations (filename) VALUES ($1)",
          [filename],
        );
        await client.query("COMMIT");
        applied.push(filename);
      } catch (error) {
        await client.query("ROLLBACK");
        throw new Error(
          `${filename} failed and was rolled back: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }
  } finally {
    await client.end();
  }

  return { applied, skipped };
}

if (import.meta.filename === process.argv[1]) {
  const connectionString = process.env.MIGRATION_DATABASE_URL ?? process.env.DATABASE_URL;
  if (connectionString === undefined || connectionString === "") {
    console.error("MIGRATION_DATABASE_URL (or DATABASE_URL) is required");
    process.exit(1);
  }
  try {
    const result = await migrate(connectionString, (message) => console.log(message));
    console.log(
      `applied ${result.applied.length}, skipped ${result.skipped.length} already-applied migration(s)`,
    );
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
