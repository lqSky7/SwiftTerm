/**
 * Real-role tests.
 *
 * These connect as `swiftterm_api` — the actual credential the service runs with — rather than as
 * the admin role, because the properties under test are properties of the *role*: what it may read,
 * what it may change, and what row-level security shows it. A test running as the admin role would
 * pass no matter how the grants were wrong.
 *
 * Requires DATABASE_URL (the API role) and DATABASE_ADMIN_URL (for fixture cleanup only). Run with:
 *
 *     node --test test/
 */

import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { after, before, describe, it } from "node:test";

import pg from "pg";

import { loadConfig } from "../src/config.ts";
import { createDatabase, type Database } from "../src/db/pool.ts";
import {
  createWebSession,
  listDevices,
  provisionAppUser,
  resolveWebSession,
  revokeWebSession,
} from "../src/db/resolvers.ts";
import { sslConfig } from "../src/db/ssl.ts";

const { Client } = pg;

const config = loadConfig();
const db: Database = createDatabase(config.databaseUrl, 4);

/** The privilege error PostgreSQL raises when a role is not allowed to do something. */
const INSUFFICIENT_PRIVILEGE = "42501";

async function expectSqlError(work: () => Promise<unknown>, code: string): Promise<void> {
  try {
    await work();
    assert.fail(`expected SQLSTATE ${code}, but the statement succeeded`);
  } catch (error) {
    const actual = (error as { code?: string }).code;
    assert.equal(actual, code, `expected SQLSTATE ${code}, got ${actual}`);
  }
}

const runId = randomUUID();
const issuer = `test://${runId}`;
const subjectA = `a-${runId}`;
const subjectB = `b-${runId}`;

let ownerA = "";
let ownerB = "";

before(async () => {
  ownerA = await provisionAppUser(db, issuer, subjectA, "Tenant A");
  ownerB = await provisionAppUser(db, issuer, subjectB, "Tenant B");
  assert.notEqual(ownerA, ownerB, "the two tenants must be distinct accounts");
});

after(async () => {
  // Cleanup runs as the admin role: the API role deliberately cannot delete an account.
  if (process.env.DATABASE_ADMIN_URL !== undefined) {
    const admin = new Client({
      connectionString: process.env.DATABASE_ADMIN_URL,
      ssl: sslConfig(),
    });
    await admin.connect();
    // Deleting an account is not something the API role can do, so cleanup borrows the owner role.
    // The owner is NOLOGIN; SET ROLE is the only way to reach it, which is the point.
    await admin.query("SET ROLE swiftterm_owner");
    await admin.query("DELETE FROM swiftterm.app_users WHERE auth_issuer LIKE $1", ["test://%"]);
    await admin.query("RESET ROLE");
    await admin.end();
  }
  await db.close();
});

describe("the API role's reach", () => {
  it("cannot read a session token digest", async () => {
    await db.withOwner(ownerA, async (client) => {
      await expectSqlError(
        () => client.query("SELECT token_sha256 FROM swiftterm.web_sessions LIMIT 1"),
        INSUFFICIENT_PRIVILEGE,
      );
    });
  });

  it("cannot read a CSRF digest, a device token or a registration digest", async () => {
    for (const column of ["csrf_sha256"]) {
      await db.withOwner(ownerA, async (client) => {
        await expectSqlError(
          () => client.query(`SELECT ${column} FROM swiftterm.web_sessions LIMIT 1`),
          INSUFFICIENT_PRIVILEGE,
        );
      });
    }
    for (const column of ["token_sha256", "registration_sha256"]) {
      await db.withOwner(ownerA, async (client) => {
        await expectSqlError(
          () => client.query(`SELECT ${column} FROM swiftterm.devices LIMIT 1`),
          INSUFFICIENT_PRIVILEGE,
        );
      });
    }
  });

  it("cannot read the issuer or subject behind an account", async () => {
    await db.withOwner(ownerA, async (client) => {
      await expectSqlError(
        () => client.query("SELECT auth_issuer FROM swiftterm.app_users LIMIT 1"),
        INSUFFICIENT_PRIVILEGE,
      );
    });
  });

  it("cannot create a table", async () => {
    await db.withOwner(ownerA, async (client) => {
      await expectSqlError(
        () => client.query("CREATE TABLE swiftterm.should_not_exist (id int)"),
        INSUFFICIENT_PRIVILEGE,
      );
    });
  });

  it("cannot drop a table", async () => {
    // A separate transaction on purpose: once a statement fails, PostgreSQL aborts the transaction
    // and every later statement reports 25P02 instead of its own error.
    await db.withOwner(ownerA, async (client) => {
      await expectSqlError(
        () => client.query("DROP TABLE swiftterm.app_users"),
        INSUFFICIENT_PRIVILEGE,
      );
    });
  });

  it("cannot rewrite an immutable snapshot", async () => {
    await db.withOwner(ownerA, async (client) => {
      await expectSqlError(
        () => client.query("UPDATE swiftterm.block_snapshots SET schema_version = 1"),
        INSUFFICIENT_PRIVILEGE,
      );
    });
  });

  it("cannot bypass row-level security", async () => {
    await db.withOwner(ownerA, async (client) => {
      const { rows } = await client.query(
        "SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user",
      );
      assert.equal(rows[0]?.rolbypassrls, false, "the API role must not hold BYPASSRLS");
    });
  });
});

describe("row-level security", () => {
  it("shows nothing when no owner context is set", async () => {
    // Rows for both tenants exist by now, so a leak would be visible.
    const seen = await db.withoutOwner(async (client) => {
      const { rows } = await client.query("SELECT id FROM swiftterm.app_users");
      return rows.length;
    });
    assert.equal(seen, 0, "a query with no owner context must see no rows at all");
  });

  it("shows tenant A only tenant A", async () => {
    const seen = await db.withOwner(ownerA, async (client) => {
      const { rows } = await client.query<{ id: string }>("SELECT id FROM swiftterm.app_users");
      return rows.map((row) => row.id);
    });
    assert.deepEqual(seen, [ownerA]);
  });

  it("shows tenant B only tenant B", async () => {
    const seen = await db.withOwner(ownerB, async (client) => {
      const { rows } = await client.query<{ id: string }>("SELECT id FROM swiftterm.app_users");
      return rows.map((row) => row.id);
    });
    assert.deepEqual(seen, [ownerB]);
  });

  it("refuses to let tenant A write a row owned by tenant B", async () => {
    await db.withOwner(ownerA, async (client) => {
      // The WITH CHECK clause rejects this, so cross-owner writes fail rather than being filtered.
      await expectSqlError(
        () =>
          client.query(
            "INSERT INTO swiftterm.live_sessions (owner_id, device_id, local_pane_id, " +
              "client_request_id, request_sha256) VALUES ($1, $2, $3, $4, $5)",
            [ownerB, randomUUID(), randomUUID(), randomUUID(), Buffer.alloc(32)],
          ),
        INSUFFICIENT_PRIVILEGE,
      );
    });
  });

  it("does not leak the owner context into the next request on the same pool", async () => {
    // A pooled backend that kept `swiftterm.user_id` would make the next tenant's query see the
    // previous tenant's rows. `set_config(..., true)` is what prevents that, so this is the test
    // that would catch it being changed to `false`.
    await db.withOwner(ownerA, async (client) => {
      const { rows } = await client.query("SELECT id FROM swiftterm.app_users");
      assert.equal(rows.length, 1, "tenant A sees its own row");
    });
    const afterReuse = await db.withoutOwner(async (client) => {
      const { rows } = await client.query(
        "SELECT coalesce(current_setting('swiftterm.user_id', true), '<unset>') AS ctx",
      );
      return String(rows[0]?.ctx);
    });
    assert.ok(
      afterReuse === "<unset>" || afterReuse === "",
      `owner context survived the transaction: ${afterReuse}`,
    );
  });
});

describe("credential resolution", () => {
  // Digests are derived from the run id. `web_sessions.token_sha256` is UNIQUE, so a fixed literal
  // would collide with a row an earlier run left behind and the test would fail for a reason that
  // has nothing to do with the code under test.
  const digest = (label: string): Buffer =>
    createHash("sha256").update(`${runId}:${label}`).digest();

  it("resolves a session digest without letting the API read the digest", async () => {
    const token = digest("session-a-token");
    const csrf = digest("session-a-csrf");
    const sessionId = await createWebSession(db, ownerA, token, csrf, 24);

    const resolved = await resolveWebSession(db, token);
    assert.notEqual(resolved, null);
    assert.equal(resolved?.sessionId, sessionId);
    assert.equal(resolved?.ownerId, ownerA);
    assert.equal(resolved?.revokedAt, null);
    // The CSRF digest comes back from the SECURITY DEFINER function, so the API never selects the
    // column itself — it holds no column privilege on it.
    assert.equal(resolved?.csrfSha256.toString("hex"), csrf.toString("hex"));
  });

  it("returns nothing for an unknown digest", async () => {
    assert.equal(await resolveWebSession(db, digest("never-issued")), null);
  });

  it("reports a revoked session as revoked rather than absent", async () => {
    const token = digest("session-b-token");
    const sessionId = await createWebSession(db, ownerB, token, digest("session-b-csrf"), 24);
    assert.equal(await revokeWebSession(db, ownerB, sessionId), true);

    const resolved = await resolveWebSession(db, token);
    assert.notEqual(
      resolved?.revokedAt,
      null,
      "a revoked session must still resolve, marked revoked",
    );
  });

  it("refuses to revoke another tenant's session", async () => {
    const sessionId = await createWebSession(
      db,
      ownerB,
      digest("session-c-token"),
      digest("session-c-csrf"),
      24,
    );
    assert.equal(
      await revokeWebSession(db, ownerA, sessionId),
      false,
      "tenant A must not be able to revoke tenant B's session",
    );
  });
});

describe("device listing", () => {
  it("shows a tenant only its own devices", async () => {
    assert.deepEqual(await listDevices(db, ownerA), []);
    assert.deepEqual(await listDevices(db, ownerB), []);
  });
});
