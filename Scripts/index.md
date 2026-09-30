# Scripts — index

| Script | Does |
| --- | --- |
| `run-tests.sh` | compiles and runs every harness in `Tests/` in parallel; no XCTest |
| `lint.sh` | swiftlint, then the pure-model import gate |
| `build-app.sh` | `swift build`, assembles the `.app`, advances the build number, installs it |
| `run.sh` | build, install, launch |
| `banner.py` | prints the logo as truecolor half-block art, filling the window — for a screenshot, not for the app |

`run-tests.sh --exec <name>` is the worker half the runner re-enters itself with; it is not meant
to be called by hand.

`terminal-renderer-test` and `block-collapse-test` add AppKit view sources explicitly. Other
harnesses preserve the pure-model compilation gate; no harness launches the app or opens a window.

The block-collapse harness additionally compiles the native terminal surface and its collaborators.
It sends synthetic mouse events to an undisplayed nested view and uses an isolated scratch shell
and history file; no app launch or window presentation. Other model harnesses remain UI-free.

`command-editor-undo-test` uses the same undisplayed native source set as block-collapse tests;
all other harnesses retain the pure compilation boundary.
