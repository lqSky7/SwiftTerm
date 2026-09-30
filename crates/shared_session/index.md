# crates/shared_session — index

The live terminal wire format: the DTOs a native publisher, a relay and a browser viewer all agree
on. Foundation-only, no AppKit, no `TerminalGrid`, no `Block`, no view type. The C0 harness
compiles this directory and `crates/cloud_objects/src` on their own precisely so that a transport
type reaching for the emulator or a view stops the build.

Read `docs/backend/wire-contract.md` first — it is the frozen specification this code implements,
and it is the file to change if a wire field ever has to change.

| File | Holds |
| --- | --- |
| `WireLimits.swift` | the frozen v1 numbers, in one place so no caller keeps a private copy of "64 KiB" |
| `WireError.swift` | the allowlisted protocol error codes and the local-only diagnostic behind each |
| `WireValue.swift` | the value rules: counters, UUIDs, base64, grapheme clusters, safe integers |
| `WireCanonicalJSON.swift` | the one encoder, and `DecodingError` translated into a contract rejection |
| `WireSHA256.swift` | SHA-256 written out, so the harness needs no second Apple framework |
| `WirePrimitives.swift` | colours, styles, cells, rows, grids, cursors, editors, blocks, the snapshot |
| `WireDamage.swift` | the exact damage operation union and its seq arithmetic |
| `WireInput.swift` | the input operation union, keys, modifiers and the input acknowledgement |
| `WireControl.swift` | control request/grant/deny/revoke, the lease, and the viewer count |
| `WireFrames.swift` | the envelope, every remaining frame, and the direction each may travel |
| `WireSnapshotAssembler.swift` | the bounded scratch buffer that verifies count, length and digest |
| `WireStreamState.swift` | the viewer's model, and the barrier and ordering rules |

## The two rules that matter most

**A snapshot is the only carrier of an epoch, a geometry or a mode change.** Applying one replaces
every field at once, so no cell from a previous mode can survive into the new one. There is
deliberately no damage operation that resizes or changes mode.

**A damage frame is applied to a copy.** Operations check their own local preconditions, and the
cross-cutting invariants — cursor placement, viewport references, style indices, the line budget —
are checked once per frame, because a frame is allowed to truncate a grid and move the cursor in
the same message. A frame that fails anywhere leaves the view exactly as it was.

## Divergences to remember

- `snapshot.begin.sha256` is taken over the raw UTF-8 bytes a producer actually sends, not over a
  re-encoding of the parsed object. `WireCanonicalJSON` exists so both are the same bytes anyway.
- The `directory` in an export is an abbreviated display label. An absolute path is refused rather
  than silently abbreviated, because implicit full-path export is the thing the contract forbids.
- A browser paste never gets an appended newline, and a rejected input always carries a code.

C0 audit fixes watermark/size admission, snapshot rollback, counter overflow and damage invariants.
WireStreamState remains a contract reference, not a measured production capture/render hot path.
