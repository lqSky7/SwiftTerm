# crates — index

The subsystems the application is built from. Warp keeps one crate per subsystem; here each folder
is a coherent group of sources, because a Swift module boundary would mean marking the whole
emulator API `package` for no gain — the harnesses already compile these sources on their own and
would fail if a UI framework ever leaked in.

| Folder | Holds |
| --- | --- |
| `warp_terminal/` | the terminal emulator: the grid, the escape-sequence parser, the pty, shell integration |
| `warpui_core/` | the shared UI framework: design tokens and the AppKit primitives SwiftUI cannot express |

Nothing here may import another feature. That is the whole point of the folder.
