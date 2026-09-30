# src/shared_session — the relay

The backend half of live terminal sharing. The name is the same as the Swift crate because both
implement one contract: this side is the relay, `crates/shared_session` is the host and viewer.

| File | Holds |
| --- | --- |
| `tickets.ts` | one-use socket tickets — hash-only, atomic consume, 30-second hard TTL, never in a URL |
| `sessions.ts` | the in-memory live state: viewers, the replay ring, byte budgets, lease staleness |
| `socket.ts` | the WebSocket endpoint — admission, the role fence, verbatim forwarding, heartbeat |
| `live.ts` | the durable control plane: create, list, read, admit a publisher, renew, release, end |

## The split that matters

**The database owns anything that must survive a restart; memory owns anything that must be fast.**
Which pane is shared, who owns it, what state it is in and which publisher generation holds the
lease are all in `swiftterm.live_sessions`. The frames themselves, the viewer set and the replay
ring are in `SessionRegistry` and are never written down — the handoff's rule is that no terminal
content reaches the database, and this is where that rule is kept.

That line is why the admission limits are *not* here. One open stream per pane, the per-account cap
and idempotency on `client_request_id` live in `swiftterm.create_live_session`, because they have to
hold across relay instances and across a restart, and an in-memory copy would be wrong the moment
the process restarted. What stays in memory is what is genuinely process-local: how many publishers
this process will carry, how many bytes it will retain, and how many viewers one stream may attach.

## Two identities that must be the same number

`RelaySession.id` is the durable session UUID — the value in the socket path `/live/<uuid>` and the
primary key of `live_sessions`. `RelaySession.epoch` is the database's `publisher_epoch`. Both are
deliberate: a ticket carries the epoch and the socket layer refuses one that does not match, so a
relay counting independently would refuse its own publisher's ticket the first time the database
incremented. `adoptEpoch` only ever moves forward, so a stale registration cannot re-admit a
generation the database has already fenced out.

## What this layer refuses to do

- **A browser cannot publish.** The role comes from the ticket, not from the frame. A viewer that
  sends a publisher frame, or anything shaped like input, is closed. Input is B3A's, behind a lease
  the host approves.
- **It does not touch the database.** `socket.ts` holds no credentials. Releasing a lease on
  disconnect is a callback (`onPublisherGone`), not a query.
- **It does not re-encode frames.** It validates the envelope it needs for ordering and forwards the
  publisher's own bytes. Re-serialising would make the relay a second implementation of the DTOs.
- **It does not buffer for a slow viewer.** A viewer past its byte budget is dropped, and the host is
  told the count changed, because at zero viewers the host stops encoding.

## Where to look first

`live.ts` for what a stream is, `sessions.ts` for what the relay remembers, `socket.ts` for the
fence. The database side is `migrations/002_live.sql`; the HTTP routes that mint tickets are in
`../http/routes.ts`.
