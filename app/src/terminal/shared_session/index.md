# app/src/terminal/shared_session — index

The host side of live sharing: capture a pane, publish it, and (in B3A) route a browser's input back.

| File | Holds |
| --- | --- |
| `PaneExporter.swift` | the terminal model → `WireSnapshot`, on the main actor, as a pure function |
| `StreamPublisher.swift` | the socket, the encoder, the lease renewal and the viewer count |

## The split that keeps typing fast

**Capture happens on the main actor; everything else happens off it.** `PaneExporter` reads the model
and returns value types; `StreamPublisher` never reads a grid — it takes an already-captured
`WireSnapshot` or `WireDamage` and owns the encoding, the socket and the lease from there. That is
the handoff's rule ("capture consistent watermark+bounded rows on MainActor, encode/hash/send
off-main"), and it is what stops a slow relay from showing up as a stuttering prompt. A publisher
that reached back into the model from its own task would be racing the shell.

**Nothing allocates while off.** `stop()` cancels the tasks, closes the socket and clears the queue.
A pane that is not sharing costs nothing, which is a property of the code rather than a promise.

**It fails closed.** The lease is renewed every ten seconds against a thirty-second expiry. A renewal
that fails stops the stream rather than continuing to write with a credential the server has already
fenced out.

**At zero viewers the host stops capturing.** The relay sends `viewer.count` for exactly this reason:
a stream nobody is watching should cost the host nothing.

## Three mappings that are losses or conventions, not copies

- **Default colours become palette indices 0 and 7.** The model keeps `.defaultForeground` and
  `.defaultBackground` symbolic so a theme change repaints history; the wire has no "default" case.
  Index 0 for the background and 7 for the foreground is the convention the golden fixture already
  uses and the browser viewer resolves the same two slots — the three agree, or the same stream
  renders differently in two places.
- **Underline variants collapse to one bit.** The model distinguishes single, double, curly, dotted
  and dashed because it draws them differently; the wire has one underline bit. A real loss, and the
  reason the model keeps them: a later schema version can carry them without the parser changing.
- **The window is bounded and the oldest blocks go first.** A viewer follows the tail, so a budget
  that has to give gives up the beginning.

## Identity

`crates/shared_session/src/ExportIdentity.swift` allocates the UUIDs. The terminal's own identities
are local and numeric — a `BlockID` is a `UInt64` reused after a close — so a block that goes on the
wire gets a UUID allocated once and keeps it for the stream's life. Re-deriving it from the local id
would be the bug: the second block to hold `#7` is not the first.

## Still to add

- **B3A's control lease** — approving one browser, holding the lease, and routing its input to the
  editor and to `TerminalInput`. The relay already refuses a viewer's input frames; what is missing
  is the host-side approval and the routing.
- **The wiring** — nothing calls `PaneExporter` or `StreamPublisher` yet. There is no Share command,
  no pane-close hook and no sign-out hook, so this code compiles into the app and does nothing until
  something drives it.
- **A harness.** These read the terminal model, so their harness would have to compile the model
  layer; that is the next test to write.
