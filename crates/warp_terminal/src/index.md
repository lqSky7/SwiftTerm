# crates/warp_terminal/src — index

| Path | Holds |
| --- | --- |
| `model/` | the emulator: grid, cells, colours, the escape-sequence parser |
| `local_tty/` | the pseudo-terminal and the process on it |
| `shell/` | recognising which shell is about to be started |
| `bootstrap/` | the shell integration scripts and how they get installed |

The split is Warp's: `model` is the emulator proper, `local_tty` is the operating system's part, and
`shell`/`bootstrap` are the two halves of talking to the shell that is running inside it.
