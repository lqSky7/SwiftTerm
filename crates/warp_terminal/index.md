# crates/warp_terminal — index

The terminal emulator. Pure Swift, no AppKit: everything in `src/model` compiles and runs in a
harness with no window server, which is what makes the escape-sequence behaviour testable at all.

| Path | Holds |
| --- | --- |
| `src/model/` | the grid, the cells, the colours, the parser |
| `src/local_tty/` | the pseudo-terminal and the process on it |
| `src/shell/` | recognising which shell is about to be started |
| `src/bootstrap/` | the shell integration scripts and how they get installed |

TUI regressions are covered by `Tests/tui-compatibility-test.swift` and offscreen renderer checks.

`TerminalInput.paste` protects nano from Ctrl-J; bootstrap prompt hooks emit one startup prompt.

ASCII paths avoid temporary decoding arrays and Unicode segmentation; Unicode behavior is retained.

BlockLayout preserves a folding header viewport offset and immediately clamps the shorter document.
