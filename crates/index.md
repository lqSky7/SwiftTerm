# crates — index

The subsystems the application is built from. Warp keeps one crate per subsystem; here each folder
is a coherent group of sources, because a Swift module boundary would mean marking the whole
emulator API `package` for no gain — the harnesses already compile these sources on their own and
would fail if a UI framework ever leaked in.

| Folder | Holds |
| --- | --- |
| `warp_terminal/` | the terminal emulator: the grid, the escape-sequence parser, the pty, shell integration |
| `warpui_core/` | the shared UI framework: design tokens and the AppKit primitives SwiftUI cannot express |
| `shared_session/` | the live terminal wire format: snapshot, damage, input and control DTOs |
| `cloud_objects/` | immutable export DTOs shared between the native export path and the website viewer |

Nothing here may import another feature. That is the whole point of the folder.

`shared_session/` and `cloud_objects/` are the exception in one direction only: they are a contract,
not a feature, so they may be imported by the app, the backend's TypeScript half and the website
alike. They are Foundation-only by construction — `Tests/wire-contract-test.swift` compiles them
with nothing else, so a transport type that reached for the emulator or a view would stop the
build. `contracts/` holds the fixtures and the second, independent implementation.

TUI repair stays in `warp_terminal`: grapheme cells, VT movement, fixed-coordinate fullscreen resize.

Paste/startup follow-up is shared terminal input encoding plus shell bootstrap hooks.

Resource optimization stays in existing Swift models; no new dependencies or subsystems.

Block collapse scroll anchoring/clamping is pure geometry in the existing terminal model.

Unused Apple text assistance is disabled centrally in warpui_core; app recommendations stay local.

`git/` holds shared Foundation-only diff/summary models and cancellable local Git operations.

Cloud device credentials and registration retries are scoped per cloud account.

secret_redaction/ is a pure Foundation export-only masking helper. It never changes local or live terminal content.
