# backend/src/db — index

| File | Holds |
| --- | --- |
| `pool.ts` | the connection pool, and the only way a transaction may be run |
| `resolvers.ts` | every call into a `SECURITY DEFINER` credential resolver, and the owner-scoped reads |
| `ssl.ts` | TLS configuration for every database connection |
| `migrate.ts` | applies `migrations/*.sql` in order and records what it applied |

## The transaction rule

node-postgres requires every statement in a transaction to go through the *same* checked-out client.
`pool.query` picks an arbitrary backend each time, so a transaction written that way silently splits
across connections. `withOwner` and `withoutOwner` therefore hand the callback one client, and the
pool's own `query` method is never exposed to a handler.

`withOwner` also sets the transaction-local owner context. The `true` in
`set_config('swiftterm.user_id', $1, true)` is what stops a pooled backend carrying one request's
owner into the next; `withoutOwner` clears the setting explicitly for the same reason.

## Why `resolvers.ts` exists at all

The API role holds no column privilege on `token_sha256`, `csrf_sha256` or `registration_sha256`. A
direct `SELECT` from this service would fail. Resolution has to go through the fixed-search-path
functions, which is what keeps "the API cannot read credential hashes" true at the database rather
than in a code review.

`registerDevice` is the one to read closely: it returns the stored registration digest alongside the
device id so the caller can answer `409` when a retry carries a *changed* payload, while an
identical retry returns the device that already exists.

## TLS

`ssl.ts` defaults to full verification. `PGSSLROOTCERT` is the correct answer for a managed
provider. `DATABASE_SSL_NO_VERIFY=1` exists for a development environment behind a TLS-intercepting
proxy and is refused when `NODE_ENV=production`. Making it a flag rather than a default matters: an
unverified connection is indistinguishable from a verified one at the call site, so the concession
has to be something an operator typed.
