# Phase 1 — Live Shell Foundation

**Goal.** A native macOS window that is a genuinely usable terminal: a real login shell on a PTY,
correct VT emulation into an owned cell grid, scrollback, keyboard input, window resize, and the
shell-integration event channel wired end to end so Phase 2 has command boundaries to build blocks
on.

**Not in this phase.** No blocks, no tabs, no sidebar, no settings window, no theme chooser, no
editor, no autocomplete, no search, no inline images. Phase 1 ends when the thing is a good
terminal, not when it is a good Warp.

**Exit criterion.** Open it, run `ls`, run `vim`, run `htop`, `Ctrl-C` a `sleep`, resize the window
while `htop` runs, scroll back through output. All correct.

---

## 1. Shape

The tree is Warp's: `app/` is the application, `crates/` are the subsystems it is built from.

```
swiftTerm/
├── Package.swift                 # SwiftPM, macOS 26+, Swift 6 language mode
├── app/
│   ├── Info.plist                # read by Scripts/build-app.sh when it assembles the bundle
│   ├── SwiftTerm.entitlements
│   └── src/
│       ├── SwiftTermApp.swift    # @main
│       ├── AppDelegate.swift     # launch and terminate
│       ├── AppCore.swift         # composition root
│       ├── AppMenus.swift        # the menu bar, routed down the responder chain
│       └── terminal/
│           ├── TerminalSession.swift   # one shell on one pty
│           ├── model/                  # blocks land here in Phase 2
│           └── view/
│               ├── TerminalCoordinator.swift
│               ├── TerminalWindowController.swift
│               ├── TerminalScreen.swift
│               ├── TerminalSurfaceView.swift
│               ├── TerminalRenderer.swift
│               └── TerminalFont.swift
├── crates/
│   ├── warp_terminal/src/
│   │   ├── model/                # grid, cells, colours, parser — pure Swift
│   │   ├── local_tty/            # the pseudo-terminal
│   │   ├── shell/                # which shell is this
│   │   └── bootstrap/            # the integration scripts
│   └── warpui_core/src/          # Theme, VisualEffectView
├── Scripts/                      # build-app, run, run-tests, lint
├── Tests/                        # standalone harnesses, no XCTest
└── docs/
```

SwiftPM rather than XcodeGen: `xcodegen` is not installed, `swift build` is, and a 40-line script
assembles the `.app` bundle. One file instead of a generated project.

One SwiftPM target rather than one per crate. A Swift module boundary would mean marking the whole
emulator API `package` for no gain: the harnesses already compile `crates/warp_terminal/src` on
their own, so an AppKit import there is a compile error either way. The folder split is what keeps
the code organised; the module split would only add ceremony.

## 2. Model layer — `crates/warp_terminal/src/model/` (pure Swift, the heart of the phase)

| File | Owns |
| --- | --- |
| `TerminalColor.swift` | `.defaultForeground` / `.defaultBackground` / `.indexed(0…255)` / `.rgb`; the xterm-256 expansion as a pure function. |
| `TerminalRGB.swift` | An 8-bit-per-channel colour, and nothing else. |
| `TerminalPalette.swift` | The 16 ANSI colours plus foreground, background and cursor; a value, because Phase 5 lets the user edit one and swap it live. |
| `CellAttributes.swift` | Flags (bold, faint, italic, underline + styles, blink, reverse, hidden, strike), fg/bg/underline colours, and the reverse-video swap. |
| `TerminalCell.swift` | One cell: a whole grapheme, attributes, display width, and the continuation flag for the right half of a wide glyph. Also the East-Asian-Width table. |
| `TerminalLine.swift` | A row of cells plus its soft-wrap flag. |
| `TerminalSize.swift` | Columns × rows, with the pixel geometry for `TIOCSWINSZ`. |
| `TerminalModes.swift` | ANSI + DEC private mode set, including `DECAWM`, `DECOM`, alt-screen `1049`, `2004` bracketed paste, `25` cursor visible, mouse reporting. |
| `TerminalPen.swift` | Current attributes, G0/G1 charset designation, `SI`/`SO`, and the pending-wrap flag. |
| `TerminalCursorStyle.swift` | What `DECSCUSR` selects. |
| `TerminalGrid.swift` | The emulator sink: cursor, scroll region, screen lines, scrollback, erase/insert/delete, tabs, alt screen, resize, and the per-row damage stamps. |
| `VTStringDecoder.swift` | Incremental UTF-8 → `Character` decoding across chunk boundaries. |
| `VTParser.swift` | The byte state machine (ground / escape / csi / osc / dcs) and the CSI + OSC dispatch tables. |
| `TerminalEvent.swift` | What the parser reports upward: title, cwd, bell, notification, clipboard write, shell-integration hook. |
| `ShellIntegrationEvent.swift` | `.promptStart`, `.commandStart`, `.commandExecuted`, `.commandFinished(exitCode:)`. |

Parser coverage required for a usable terminal: C0 controls, `ESC 7/8/D/E/H/M/c/=/>`, `ESC ( ) * + #`
charset designation, CSI `A B C D E F G H f J K L M P S T X Z @ \` a b c d e f g h l m n p q r s u`,
DEC private modes `1 3 5 6 7 25 47 1000 1002 1003 1006 1047 1048 1049 2004`, OSC `0 1 2 7 9 52 133
777`, DCS consumed and discarded, and UTF-8 with wide-glyph and combining-mark handling.

`VTParser` owns the grid and calls it directly rather than through a delegate, so the entire
escape-sequence vocabulary is one switch instead of a protocol spread over several files. That is
also what lets a harness feed bytes and assert on a grid with no wiring in between.

## 3. Service layer

- **`PseudoTerminal`** (`crates/warp_terminal/src/local_tty/`) — `forkpty` with an initial
  `winsize`, `execve` of the shell in the child, `TIOCSWINSZ` on resize, `read`/`write` on the
  master, and `kill(-pid, SIGHUP)` on teardown so the whole session dies. `forkpty` rather than
  `openpty` + `posix_spawn`, because it is the `TIOCSCTTY` inside it that gives the shell a
  controlling terminal — without one, `Ctrl-C`, `Ctrl-Z` and `fg` all do nothing.
- **`ShellType`** (`crates/warp_terminal/src/shell/`) — zsh, bash, fish or something else, decided
  from the executable's basename.
- **`ShellBootstrap`** (`crates/warp_terminal/src/bootstrap/`) — writes the integration scripts into
  a generated rc directory and hands the shell a `ZDOTDIR` (zsh) or `--rcfile` (bash) that sources
  the user's own dotfiles first and the integration second. The user's config must behave exactly as
  it does everywhere else, so every dotfile zsh would read out of `ZDOTDIR` gets a shim. The scripts
  are embedded in the binary, so the protocol and the parser that reads it cannot drift apart.
- **`TerminalSession`** (`app/src/terminal/`) — `@MainActor`, owns the PTY + `VTParser` +
  `TerminalGrid`. A `nonisolated` detached task does the blocking `read` and yields chunks through
  an `AsyncStream`; the session consumes them on the main actor. That is the whole concurrency
  design: one actor owns the mutable screen, so there is no lock and no second actor. `stop()`
  signals the shell *before* it closes, because a read parked on a pty cannot be interrupted any
  other way, and cancelling the reader first leaves the exit status unreapable.

## 4. UI layer

- **`TerminalFont`** (`app/src/terminal/view/`) — resolves the mono font, measures `M` for the cell
  advance, snaps the cell box to whole pixels, exposes the baseline offset. Measured from a real
  glyph rather than a typographic constant, because the two disagree for several monospace faces.
- **`TerminalRenderer`** — builds one `CTLine` per changed row from the grid's cells, then draws
  backgrounds, glyphs, underlines and the cursor. Live screen rows are cached by the grid's per-row
  generation stamp, keyed by *screen row* rather than by where the row sits on screen; history rows
  are rebuilt each frame. That distinction is what makes scrolling work at all: a cache keyed by
  view row serves whatever it built for that view row last frame, and a history line carries no
  generation stamp of its own, so the stale entry is never invalidated. A glyph wider than one
  column is always its own run, because a monospace face does not promise a double-width advance.
- **`TerminalSurfaceView`** — `NSView`, layer-backed. Owns focus, keyboard translation (control
  characters, arrows, function keys, `Option` as meta, `Cmd-K`/`Cmd-V`/`Cmd-+`), scroll wheel →
  scrollback, and `setFrameSize` → column/row recompute → PTY resize. The viewport is held as a
  single pixel offset, so a trackpad gesture slides the rows rather than accumulating into whole-row
  jumps; a discrete action (page key, menu item) snaps to a row instead. Conforms to
  `NSTextInputClient` so dead keys, IME composition and the candidate window's position all work.
- **`TerminalScreen` / `TerminalWindowController` / `TerminalCoordinator`** — the SwiftUI content
  (behind-window blur under the surface), the `NSWindow`, and the feature's action surface.
- **`Theme` / `VisualEffectView`** (`crates/warpui_core/src/`) — spacing, radius, sizes, type, the
  chrome alpha ramp, and the one AppKit primitive SwiftUI cannot express.

## 5. Gates

1. `./Scripts/run-tests.sh` green — `vt-parser-test`, `terminal-grid-test`,
   `shell-integration-test`, `terminal-session-test`.
2. `swift build` clean, zero warnings.
3. `./Scripts/lint.sh` clean.
4. `grep -rlE '^import (AppKit|SwiftUI|Cocoa)' crates/warp_terminal/src/model/` returns nothing.
5. `index.md` present and current in every directory; this file and `phase-1-todo.md` updated in the
   same commit.
6. `./Scripts/build-app.sh` installs a working app to `/Applications`.
