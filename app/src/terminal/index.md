# app/src/terminal — index

The terminal feature. The emulator it drives lives in `crates/warp_terminal`; what is here is the
part that knows about this application.

| Path | Holds |
| --- | --- |
| `TerminalSession.swift` | one shell on one pty: spawns it, reads it, feeds the parser, and points the parser at the grid of whichever block is currently being written to |
| `model/` | feature-level models — empty until a phase needs one |
| `view/` | the renderer, the surface, the window, the coordinator |
