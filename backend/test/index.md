# backend/test — index

Five files, run with `node --test --test-force-exit --test-timeout=30000 test/`.

| File | Covers |
| --- | --- |
| `roles.test.ts` | the role boundaries and row-level security, against the real database |
| `http.test.ts` | the identity and device surface: sessions, CSRF, `/me`, `/devices` |
| `shared_session.test.ts` | the one-use ticket store |
| `sessions.test.ts` | the in-memory registry: the replay ring, byte budgets, lease staleness |
| `relay.test.ts` | the WebSocket endpoint: admission, the role fence, verbatim forwarding |
| `live.test.ts` | the live control plane end to end: the routes, the database functions and the relay |

`roles.test.ts`, `http.test.ts` and `live.test.ts` connect as **`swiftterm_api`** — the actual
credential the service runs with — rather than as an admin role. That is the whole point: the
properties under test are properties of the *role*, so a suite running as the admin would pass no
matter how the grants were wrong.

`shared_session.test.ts` and `sessions.test.ts` need no database at all, and `relay.test.ts` needs no
database either — the relay holds no credentials, which is why its tests can run without one.

## The timeout is load-bearing

`--test-timeout=30000` turns a hung `await` into a named failure instead of a run that never
finishes. It is not decoration: an assertion that fails mid-socket used to leave the connection open,
and `server.close()` waits for every open connection before calling back, so one failure became a
hang. Every `after` hook now terminates the relay's clients before closing the server, and the
timeout is the backstop for the next version of that mistake.

## Two conventions these files follow

**Fixtures are unique per run.** `web_sessions.token_sha256` is `UNIQUE`, so a fixed literal would
collide with a row an earlier run left behind and the test would fail for a reason unrelated to the
code. Every digest is derived from the run's UUID.

**Cleanup borrows the owner role.** Deleting an account is deliberately not an API capability — the
API holds no `DELETE` grant on `app_users` at all. The teardown connects as the project admin and
`SET ROLE swiftterm_owner`, which is the only way to reach the owner because it is `NOLOGIN`.

## Writing a test here

**A socket test must settle before asserting.** Admission happens on the server, a tick behind the
client's `send`. Asserting `session.viewerCount` immediately after connecting reads zero, and the
failure looks like a broken relay.

**Count the process publisher budget.** `SessionRegistry` refuses past `maxPublishersPerProcess`, and
one registry is shared by a whole file. A file that opens more sessions than that budget will fail
on whichever test crosses the line rather than on the test it is about. Raise it for the file, or
give the test its own relay via `spawnRelay`.

**A test that needs a different budget needs its own relay.** The limits live on the registry, so a
test wanting a small ring or a small socket budget cannot use the shared one. `spawnRelay` in
`relay.test.ts` builds one on its own server and must be closed in a `finally`.

**An error code is part of the assertion.** `stale_epoch` and `invalid_frame` are different failures
with different fixes, so a test asserts the specific one. That is how the ordering bug was found:
the relay checked the epoch before it checked the frame type, so an unknown frame was reported as a
fencing problem.

## Requirements

`DATABASE_URL` (the API role) and `DATABASE_ADMIN_URL` (for cleanup only). Both come from `.env`,
which is gitignored. `shared_session.test.ts` and `sessions.test.ts` need neither.

## Still to add

OIDC verification tests with a locally generated key pair, device registration concurrency,
resolver `search_path` abuse, log-redaction tests, and a database-outage test for the relay's
fail-closed path.
