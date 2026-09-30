/**
 * Gives the two runtime roles a login and a password, from the environment.
 *
 * This is separate from the migrations on purpose: a password in a `.sql` file is a password in
 * version control. The migrations create the roles with the right attributes and no login; this
 * script is the only thing that hands out a credential, and it reads it from the environment so
 * the secret never enters the repository.
 *
 * It also asserts the two roles that must *not* be able to log in still cannot, so a later change
 * to the migrations cannot quietly turn the resolver or the owner into a usable account.
 */

import pg from "pg";

import { sslConfig } from "../src/db/ssl.ts";

const { Client } = pg;

const LOGIN_ROLES = ["swiftterm_api", "swiftterm_migrator"] as const;
const NOLOGIN_ROLES = ["swiftterm_owner", "swiftterm_resolver"] as const;

function passwordFor(env: NodeJS.ProcessEnv, role: string): string {
  const name = `${role.toUpperCase()}_PASSWORD`;
  const value = env[name];
  if (value === undefined || value.length < 24) {
    throw new Error(`${name} is required and must be at least 24 characters`);
  }
  return value;
}

export async function provisionRoles(
  adminConnectionString: string,
  env: NodeJS.ProcessEnv = process.env,
  log: (message: string) => void = () => {},
): Promise<void> {
  const client = new Client({ connectionString: adminConnectionString, ssl: sslConfig() });
  await client.connect();
  try {
    for (const role of LOGIN_ROLES) {
      const password = passwordFor(env, role);
      // format(%I, %L) does the quoting, so the password is never interpolated by hand.
      const { rows } = await client.query<{ sql: string }>(
        "SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', $1::text, $2::text) AS sql",
        [role, password],
      );
      const statement = rows[0]?.sql;
      if (statement === undefined) throw new Error(`could not build the statement for ${role}`);
      await client.query(statement);
      log(`${role}: login enabled, password set from the environment`);
    }

    for (const role of NOLOGIN_ROLES) {
      const { rows } = await client.query<{ sql: string }>(
        "SELECT format('ALTER ROLE %I NOLOGIN', $1::text) AS sql",
        [role],
      );
      const statement = rows[0]?.sql;
      if (statement === undefined) throw new Error(`could not build the statement for ${role}`);
      await client.query(statement);
      log(`${role}: login explicitly disabled`);
    }

    const { rows: still } = await client.query<{ rolname: string }>(
      `SELECT rolname FROM pg_roles WHERE rolname = ANY($1) AND rolcanlogin`,
      [NOLOGIN_ROLES],
    );
    if (still.length > 0) {
      throw new Error(
        `refusing to finish: ${still.map((row) => row.rolname).join(", ")} can still log in`,
      );
    }
  } finally {
    await client.end();
  }
}

if (import.meta.filename === process.argv[1]) {
  const admin = process.env.DATABASE_ADMIN_URL;
  if (admin === undefined || admin === "") {
    console.error("DATABASE_ADMIN_URL is required (the project admin role, not the API role)");
    process.exit(1);
  }
  try {
    await provisionRoles(admin, process.env, (message) => console.log(message));
    console.log("roles provisioned");
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
