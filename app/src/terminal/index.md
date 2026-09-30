# app/src/terminal — index

The terminal feature. The emulator it drives lives in `crates/warp_terminal`; what is here is the
part that knows about this application.

| Path | Holds |
| --- | --- |
| `TerminalSession.swift` | one shell on one pty: spawns it, reads it, feeds the parser, and points the parser at the grid of whichever block is currently being written to |
| `model/` | feature-level models — empty until a phase needs one |
| `view/` | the renderer, the surface, the window, the coordinator |

Fullscreen state is read from the active grid, including shells without integration hooks.
PTY resize settling uses an owned cancellable Swift task.

Shell bootstrap emits prompt boundaries from hooks only, preventing an extra startup block.

Resource optimization shares glyphs and avoids unused cursor work; no session protocol changes.

Collapse gestures/menu actions reconcile viewport geometry immediately. Fullscreen mode changes
recompute PTY columns; ordinary blocks retain their existing padding and appearance.

Active command editor undo/redo is native and isolated per pane; submission/cancel starts fresh.
Future web-terminal capture/control is specified in `../../../docs/backend/`, with no runtime networking yet.

Apple text assistance is disabled through shared UI policy; native editor and IME stay intact.

Session routes conservative SSH submissions through shared bootstrap, keeps per-block remote origins and local restoration context. Native coordinator reports prompt-ready independently of title changes.
