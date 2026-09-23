# crates/warp_terminal/src/bootstrap — index

| File | Holds |
| --- | --- |
| `ShellBootstrap.swift` | the shell integration scripts, and writing them into a generated rc directory |

The scripts are embedded in the binary rather than shipped as resources. A resource file can drift
from the parser that reads it; a string in the same module cannot.

Two markers come out of `preexec`. `OSC 133 ; C` is the spec-clean "command executed" every terminal
understands. `OSC 9281` is swiftTerm's own, carrying the command line itself — the grid cannot give
that up, because the prompt and the command are one drawn line and splitting them would mean
guessing where the user's prompt ends.
