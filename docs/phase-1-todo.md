# Phase 1 — Todo

The working checklist for Phase 1. Every box below is ticked against a real run, not an intention.

## Scaffold
- [x] `Package.swift` — SwiftPM, `.macOS(.v26)`, Swift 6 language mode, one target spanning `app/` and `crates/`
- [x] `.gitignore` — `.build/`, `dist/`, `*.app`, `DerivedData/`, `.DS_Store`
- [x] `.swiftlint.yml` — the Tinycast rule set, paths retargeted
- [x] `app/Info.plist` — `NSHighResolutionCapable`, no `LSUIElement` (this app has a Dock icon)
- [x] `app/SwiftTerm.entitlements` — sandbox off; a terminal runs the user's own processes
- [x] `README.md`, root `index.md`
- [x] `Scripts/run-tests.sh` — parallel harness runner, no XCTest, per-harness timeout
- [x] `Scripts/lint.sh` — swiftlint + the pure-model import gate
- [x] `Scripts/build-app.sh` — release build, `.app` assembly, build-number bump, install
- [x] `Scripts/run.sh` — build, install, launch
- [x] `index.md` in all fifteen directories

## Model — `crates/warp_terminal/src/model/`
- [x] `TerminalColor` — default / indexed / rgb, xterm-256 expansion
- [x] `TerminalRGB` — an 8-bit-per-channel colour
- [x] `TerminalPalette` — 16 ANSI + fg/bg/cursor for the built-in scheme
- [x] `CellAttributes` — flags + fg/bg/underline colour + the reverse-video swap
- [x] `TerminalCell` — grapheme, attributes, width, continuation, East-Asian-Width table
- [x] `TerminalLine` — cells + soft-wrap flag *(the flag, not the reflow: nothing ever set it or read
      it, so `TerminalGrid.resize` truncated long lines instead of re-wrapping them. See
      `phases.md` Phase 2.6 — a phase that exists because this box was ticked and was not true.)*
- [x] `TerminalSize` — columns × rows + pixel geometry
- [x] `TerminalModes` — ANSI + DEC private modes
- [x] `TerminalPen` — attributes, G0/G1 charset, `SI`/`SO`, pending wrap
- [x] `TerminalCursorStyle` — what `DECSCUSR` selects

## Model — the emulator
- [x] `TerminalGrid` — cursor, scroll region, screen, scrollback, tabs
- [x] `TerminalGrid` — put/print with wide glyphs, combining marks, autowrap, pending wrap
- [x] `TerminalGrid` — erase in line / display, insert & delete chars, insert & delete lines
- [x] `TerminalGrid` — scroll up / down inside the region, line feed, reverse index
- [x] `TerminalGrid` — cursor motion, save/restore, absolute position, column/row set
- [x] `TerminalGrid` — resize, keeping the cursor line and dropping blank lines from history
- [x] `TerminalGrid` — alternate screen enter/leave with a saved primary screen
- [x] `TerminalGrid` — per-row damage stamps + a generation counter for the renderer
- [x] `TerminalGrid.applyControl` — the C0 vocabulary, so the parser only decides *when*
- [x] `VTStringDecoder` — incremental UTF-8 across chunk boundaries
- [x] `VTParser` — C0 controls and `ESC` dispatch
- [x] `VTParser` — CSI dispatch table (cursor, erase, edit, modes, SGR, tabs, scroll, cursor style)
- [x] `VTParser` — OSC dispatch (title, cwd, notification, `OSC 133`)
- [x] `VTParser` — DCS consumed and discarded, strings abandoned on an interrupting ESC
- [x] `VTParser` — device queries answered back down the pty (DA, DSR)
- [x] `TerminalEvent` + `ShellIntegrationEvent` — the upward event channel

## Service
- [x] `PseudoTerminal` — `forkpty`, initial `winsize`, `execve`, master fd
- [x] `PseudoTerminal` — `TIOCSWINSZ` resize, `write`, `kill(-pid, SIGHUP)` teardown
- [x] `ShellType` — zsh / bash / fish / other from the executable path
- [x] `ShellBootstrap` — `$SHELL` resolution, `TERM`/`COLORTERM`/`TERM_PROGRAM` environment
- [x] `ShellBootstrap` — scripts written into a generated rc directory
- [x] `ShellBootstrap` — zsh `ZDOTDIR` chain (all four dotfiles shimmed) and bash `--rcfile`
- [x] zsh integration — `OSC 133` A/B/C/D and `OSC 7`, via `precmd` + `preexec`
- [x] bash integration — `OSC 133` via a `DEBUG` trap + `PROMPT_COMMAND`
- [x] fish integration — `OSC 133` via the `fish_prompt` / `preexec` / `postexec` events
- [x] `TerminalSession` — spawn, detached read loop, main-actor feed, event fan-out
- [x] `TerminalSession` — `write`, `resize`, `stop` with the shell signalled before the close
- [x] `TerminalSession` — child-exit detection and a session-ended event

## UI — `app/src/terminal/view/`
- [x] `Theme` — spacing, radius, sizes, type, the chrome alpha ramp
- [x] `VisualEffectView` — `NSVisualEffectView` bridge for the window's behind-window blur
- [x] `TerminalFont` — font resolution, cell metrics, whole-pixel snapping
- [x] `TerminalRenderer` — background pass, glyph pass, underline pass, cursor
- [x] `TerminalRenderer` — per-row `CTLine` cache invalidated by row generation
- [x] `TerminalRenderer` — wide glyphs as their own runs, so columns stay aligned
- [x] `TerminalSurfaceView` — `draw`, focus, `acceptsFirstResponder`
- [x] `TerminalSurfaceView` — keyboard: control chars, arrows, function keys, meta, paste
- [x] `TerminalSurfaceView` — `NSTextInputClient` for dead keys and IME, candidate-window rect
- [x] `TerminalSurfaceView` — scroll wheel → scrollback, `setFrameSize` → PTY resize
- [x] `TerminalSurfaceView` — blinking cursor, and the menu actions the responder chain routes here
- [x] `TerminalScreen` — SwiftUI content: blur behind, surface in front, failure message in place
- [x] `TerminalWindowController` — `NSWindow`, system titlebar, frame autosave
- [x] `TerminalCoordinator` — the feature's action surface

## App
- [x] `AppCore` — composition root, owns the coordinator and the window
- [x] `AppMenus` — App / Edit / View / Window, all items targeting `nil`
- [x] `AppDelegate` — launch, terminate
- [x] `SwiftTermApp` — `@main`, driving `NSApplication` directly

## Gates
- [x] `Tests/terminal-grid-test.swift` — 55 checks
- [x] `Tests/vt-parser-test.swift` — 73 checks
- [x] `Tests/shell-integration-test.swift` — 9 checks
- [x] `Tests/terminal-session-test.swift` — 41 checks, against a real shell on a real pty
- [x] `./Scripts/run-tests.sh` passes 100%
- [x] `swift build -c release` clean with zero warnings
- [x] `./Scripts/lint.sh` passes with zero violations
- [x] Pure-model grep returns zero files
- [x] Every `index.md` current
- [x] `./Scripts/build-app.sh` installs to `/Applications`
