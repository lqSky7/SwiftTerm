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
