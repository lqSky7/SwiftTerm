# app/src/terminal/shared_session — index

The host side of live sharing: capture a pane, publish it, and route a browser's input back.

| File | Holds |
| --- | --- |
| `PaneExporter.swift` | the terminal model → `WireSnapshot`, on the main actor, as a pure function |
| `StreamPublisher.swift` | the socket, the encoder, the lease renewal and the viewer count |
| `PaneSharing.swift` | one pane's sharing: the capture, the lease, and the routing decision |
| `RemoteKey.swift` | a logical key from a browser → the bytes a shell receives |

## The split that keeps typing fast

**Capture happens on the main actor; the encoding, the hashing and the send happen off it.**
`PaneExporter` reads the model and returns value types; `StreamPublisher` never reads a grid — it
takes an already-captured `WireSnapshot` or `WireDamage` and owns the socket and the lease from
there. That is the handoff's rule ("capture consistent watermark+bounded rows on MainActor,
encode/hash/send off-main"), and it is what stops a slow relay from showing up as a stuttering
prompt.

**Two details make that a fact rather than a comment, and both were wrong until the first compile.**
`StreamPublisher` is `@MainActor` because `state` is observed by the UI, and a plain `Task { }`
written inside a `@MainActor` type *inherits that actor* — so the expensive half ran on the actor the
prompt is drawn from. `enqueue` detaches for that reason, and `frames(for:)` is `nonisolated` so it
can be called from there: a `static` member of a `@MainActor` type is main-actor isolated too, so
without it the work would hop straight back.

**Nothing allocates while off.** `stop()` cancels the tasks, closes the socket and clears the queue.
A pane that is not sharing costs nothing, which is a property of the code rather than a promise.

**It fails closed.** The lease is renewed every ten seconds against a thirty-second expiry. A renewal
that fails stops the stream rather than continuing to write with a credential the server has already
fenced out.

**At zero viewers the host stops capturing.** The relay sends `viewer.count` for exactly this reason:
a stream nobody is watching should cost the host nothing.

## Who decides what

`PaneSharing` is the coordinator that was missing between the model and the wire. It owns four
things, and each is here for a reason:

- **The capture, on the main actor.** It reads the session's blocks and hands the publisher a value.
- **The lease.** Whether a browser may type is a question about the person in front of the machine,
  so it is answered next to the pane rather than by the relay.
- **The routing decision.** By *operation*, not by mode: `text`, `paste` and undo/redo are edits, and
  a logical key is input the terminal translates. Where an edit lands — the prompt editor or the raw
  path — is the surface's decision, because whether a prompt is showing is a fact about the view.
- **Nothing about the shell.** It cannot start, stop or resize a PTY except to write an approved
  input, which is the whole point of putting the lease next to the thing it guards.

**The mechanisms are supplied, never defaulted.** `TerminalCoordinator.sharingMechanisms()` returns
`nil` when there is no surface, and `AppCore.startSharing` refuses to start rather than starting a
publisher whose every input would be acked `applied` and then do nothing. A control path that lies is
worse than one that is missing.

## The identity the host cannot see

The contract's `control.request` carries **no requester identity**, deliberately: *"the requester
cannot specify another client."* So the host has no browser id to key a lease on, and must not be
able to name one. The relay supplies the missing half — one outstanding request, and `input`
forwarded only from the connection it granted — and the host keys its lease on the *generation*,
which is the only identity the frames carry. `PaneSharing.holderID` says so where it matters.

## Local input wins

Any keystroke at the machine revokes the browser's lease *before* the keystroke is applied, so nobody
ever has to fight a browser for their own prompt. That is enforced at the two funnels a local byte
can take — `TerminalSurfaceView.send(_:)` and `insertPastedText` — plus `editor.onBufferChanged` for
the editor, which takes its own keystrokes. `applyingRemoteInput` is load-bearing: without it a remote
key routed through the same funnel would revoke its own lease and the second character would be
refused.

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

## Lifecycle

A stream ends when the pane closes, when the shell exits, when the person stops sharing, when they
sign out and when the app terminates. The first two are the ones worth knowing about, because neither
is a command anybody types:

- **A closed pane** is caught in `AppCore.reapOrphanedCoordinators`, which runs on every structural
  change and already takes the shell with it.
- **An exited shell** is caught by `TerminalCoordinator.onShellExit`, wired where the coordinator is
  built — looked up by identity, because a coordinator is constructed before its caller has assigned
  it a pane id.

Both stop sharing *before* tearing down, and that order is the point: the revocation has to go out on
a socket that is still open.

## Still to add

- **Deltas.** Only whole snapshots are published. Correct, and wasteful: every capture re-encodes the
  visible window. `WireDamage` and the publisher's `publish(_:)` for it exist and nothing produces
  one.
- **A harness.** These read the terminal model, so their harness would have to compile the model
  layer — except `RemoteKey.swift`, which is deliberately dependency-free enough to have one
  (`Tests/remote-key-test.swift`, 35 checks).
