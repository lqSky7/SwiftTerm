# crates/warp_terminal/src/local_tty — index

| File | Holds |
| --- | --- |
| `PseudoTerminal.swift` | `forkpty`, `TIOCSWINSZ`, blocking read/write, session teardown |

`forkpty` rather than `openpty` + `posix_spawn`: it is the `TIOCSCTTY` inside it that gives the shell
a controlling terminal, and without one `Ctrl-C`, `Ctrl-Z` and `fg` all do nothing.
