# Scripts — index

| Script | Does |
| --- | --- |
| `run-tests.sh` | compiles and runs every harness in `Tests/` in parallel; no XCTest |
| `lint.sh` | swiftlint, then the pure-model import gate |
| `build-app.sh` | `swift build`, assembles the `.app`, advances the build number, installs it |
| `fallback-icon.swift` | draws a flat icon PNG from the icon package's SVG; `build-app.sh` uses it when `actool` (Xcode-only) is missing |
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

Git review harness adds shared Git sources + Foundation-only review coordinator. SwiftLint now scans actual app/src and crates paths rather than the removed SwiftTerm folder.

run-tests.sh includes the sign-in harness and remote-input contract sources required by the collapse/undo view harnesses.

run-tests.sh compiles stream-publisher-test with the shipped cloud client, wire DTOs and publisher; this transport regression requires the existing backend Node dependencies.

static-share-test guards export/masking/body/persistence. sharing-offline-test compiles the shipped app sources without its @main entry and checks lazy initialization, disabled entry points and teardown without opening windows or writing settings.
