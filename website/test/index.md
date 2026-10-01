# website/test — index

Tests run with `node --test --test-force-exit --test-timeout=30000 test/`. No browser, no
network, no database: the reducer is pure and the socket is driven through a fake.

| File | Covers |
| --- | --- |
| `state.test.ts` | golden-cell equivalence, sequence discipline, every damage operation, hostile input |
| `connection.test.ts` | snapshot assembly against the real bytes, the socket URL, backoff, the state machine |

## The first test is the one that matters

`state.test.ts` loads the golden snapshot the Swift harness writes, feeds it through the viewer's own
path, and compares **every cell** of every grid against the fixture. That is the browser's half of
the C0 agreement. If this file and `crates/shared_session/src/WireStreamState.swift` ever disagree
about what a frame means, this is where it shows — before anything is deployed, and in a place that
runs in a second.

The fingerprint is deliberately per-cell (`text:width/style`, joined) rather than a whole-object
`deepEqual`: a diff of two 2000-line structures is unreadable, and the thing that actually drifts is
one cell's width.

## Three boundaries these tests found, which are worth knowing

**The contract refuses more than the reducer does.** `validateDamage` already requires
`base_seq === seq - 1`, refuses a wide cell in the last column, and bounds `line_count` to 2000. So
several tests assert that a frame never reaches the reducer, rather than that the reducer refuses it.
That is the cheaper place to catch it and the tests say so.

**A frame can be individually legal and collectively wrong.** Removing a block whose id the viewport
still references, or truncating a grid past the cursor, passes the per-operation checks and fails the
resulting `validateSnapshot`. Those are the cases that justify applying to a copy and validating
before the swap, and they are tested as such.

**Node strips types, it does not check them.** `--test-timeout` is load-bearing for the same reason
it is in the backend: an assertion that fails mid-socket would otherwise leave a connection open.
And a constructor parameter property is a syntax error under strip-only mode, which is why the fake
socket writes its field out.

## Requirements

None beyond `npm install`. The tests import the contract from `../contracts/ts` — the same file the
relay and the browser use — so a change there is felt here immediately rather than at deploy time.

## Still to add

The visual half of the gate: screenshot equivalence for the canvas, a slow-consumer case, and a
reconnect-under-load case. Those need a browser, which this environment does not have.

proxy.test.ts verifies fixed-upstream routing, CSRF/cookie/Origin forwarding, Set-Cookie retention, manual redirects and WebSocket headers. Socket URL tests retain `/api`.

The proxy regression also checks that the zrok interstitial header is present on HTTP and socket forwarding.

access.test.ts verifies invitation preservation through sign-in and rejection of external/unrelated redirect destinations.
