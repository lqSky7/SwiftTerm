# crates/cloud_objects — index

Immutable export DTOs, shared between the native export path and the website share viewer. An
export is frozen content, not a live session: it carries explicit line text and allowlisted style
spans, and it has no editor, no grid controls, no images, no links and no live identifiers.

This crate reuses the value rules in `crates/shared_session/src` rather than restating them, so a
style index means the same thing in a snapshot and in an export. Both are compiled into the same
contract target and the same Foundation-only harness.

| File | Holds |
| --- | --- |
| `WireShare.swift` | `WireShareSnapshot`, its blocks, lines and spans, the directory label rule, and the 32-byte share capability |

`docs/backend/protocol.md` and `docs/backend/wire-contract.md` are the specification. The 20-block
and 2 MiB caps are enforced here and again by the TypeScript validators.
