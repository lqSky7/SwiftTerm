# READ_ME.md — swiftTerm, agent handoff

**This is the file a new agent reads first.** `README.md` is for a person looking at the project
on GitHub; this one is for the next model waking up cold. Read it, then read the four documents
it points at, in the order it points at them.

---

## 1. What this is

A native macOS terminal, `swiftTerm`, that takes the *product* ideas from Warp
(`warp_features.md`) and implements them on Apple's own stack — AppKit, SwiftUI, CoreText — with
no third-party dependencies. Targets macOS 26+, Swift 6 language mode. The whole tree follows
Warp's directory layout: `app/` is the application, `crates/` are the subsystems it is built
from, and `Tests/` are standalone Swift harnesses (no XCTest target).

You are not the first agent on this project. Phases 1, 2 and 2.5 are built and working; Phase 2.6
(the reflow) is built; Phase 3 (the editor) is **parked on purpose**; Phase 4a (context & chrome)
is built; Phase 4b (multi-session — sidebar, tabs, split panes) is **built and has never run** —
its model is verified by harnesses and its view layer has only ever been typechecked.
The current numbers from a fresh run today:

```
./Scripts/run-tests.sh        ✓ 18 harnesses, 897 checks
./Scripts/lint.sh             ✓ clean (swiftlint + pure-model grep gate)
swiftc -typecheck (whole app) ✓ exit 0
swift build                   ✗ CANNOT BE RUN HERE — see §6
```

The app's actual UI has to be exercised by the human (`AGENTS.md` §"no need for you to open anything").
You will be told what is broken when something is.

---

## 2. Read these, in this order, before you change anything

| Order | File | Why |
| --- | --- | --- |
| 1 | `AGENTS.md` | The hard rules — non-negotiable. |
| 2 | `docs/journal.md` | The narrative: what was tried, what failed, and why the tree looks the way it does. |
| 3 | `docs/phases.md` | The plan. Every phase's *why*, the four deferred items, the five divergences from Warp. |
| 4 | `docs/phase-3-todo.md` (the bottom) and `docs/phase-2.6-todo.md` | Why the editor is parked. Why the reflow needed its own phase. Both are the same shape: a defect that hid inside documentation that outran the code. |
| 5 | `docs/learnings.md` | Technical residue — SwiftPM, AppKit, CoreText, the pty, and two bugs worth not repeating. |
| 6 | `docs/settings.md` | The settings standard, if you are adding one. Five lines in one file, and a page that does not explain itself. |
| 7 | `docs/audit-phase-1-2.md` | Twelve findings from checking every ticked box against the code. Four are fixed; eight are open. |
| 8 | The phase doc for whatever you are working on next. | |

If you only have time for one: **journal.md**. It is the one that is missing from the others.

---

## 3. The hard rules (from `AGENTS.md`, with the load-bearing bits bolded)

- **Don't reinvent the wheel. Keep it as Warp does it, unless `warp_features.md` says otherwise —
  and implement only the features that file lists. A divergence from Warp is allowed only where a
  phase doc records it and why.** Without that last clause the rule contradicts a shipped decision
  and the next agent "fixes" it. The five divergences that exist today are listed in
  `phases.md` §"five places this deliberately differs from Warp" and in `journal.md` — read both.

- **The model layer never imports AppKit, SwiftUI or Cocoa.** Enforced by compilation, not
  convention — `Scripts/run-tests.sh` compiles every harness against `crates/warp_terminal/src/`
  directly, so a single `import AppKit` there breaks every harness. `Scripts/lint.sh` also
  greps for it as a backstop.

- **The tree follows Warp's.** A terminal model file goes in `crates/warp_terminal/src/model/`,
  a terminal view in `app/src/terminal/view/`, and never the other way around. Feature folders
  are `lower_snake_case`, Swift files `PascalCase.swift` after the type they hold. Only `crates/`
  code may be reached from more than one feature — a feature never imports another feature.

- **Every meaningful change is committed with `git commit -s -S -m "..."`** (signed-off-by and
  GPG-signed). **HOWEVER — git does not work in this directory.** See §6. The signing requirement
  still applies when the human runs git from Terminal.app.

- **Maintain a per-phase todo list.** One file, `docs/phase-N-todo.md`, ticked against a real
  run, updated as tasks complete. Phase 4's two sub-phases have separate docs.

- **Maintain an `index.md` in every directory, updated when the directory changes.** Every
  `index.md` is named individually in `Package.swift`'s `exclude:` (SwiftPM has no globs) — they
  are also the honest list of what is not code.

- **Use the ponytail ladder first.** Does it need to exist? Is it already here? Does the stdlib
  or a native API already do it? (Skill: `~/.workbuddy-ai/skills/ponytail/`.)

- **Follow `tinycast_architecture_and_rules.md` for any design work.** That is the engineering
  posture (settings hierarchy, layered errors, etc.); it shapes how the code is organised more
  than how it is written.

- **Rust reuse is allowed where it pays, and only where it pays.** The terminal emulator is
  Swift because it is the product and Warp's emulator is half a workspace of crates with no Rust
  toolchain on this machine. Phase 6's search and possibly Phase 3's syntax trees may pull Rust
  in later — adding it then, not as a foundation.

- **The app installs and runs at the end of every phase.** This is the human's job
  (`AGENTS.md`); your job is to leave it in a state where they can.

---

## 4. The current state, file by file

### What works

| Phase | Feature | State |
| --- | --- | --- |
| 1 | Live shell, VT emulation, scrollback, keyboard, resize, OSC 133 | Built, tested, running |
| 2 | Command blocks, headers, per-block selection & copy, block jumping | Built, tested, running |
| 2.5 | A grid per block (Phase 2's deliberate divergence reversed) | Built, tested, running |
| 2.6 | Reflow — the long-line / resize fix Phase 1 ticked and never built | Built, tested, running |
| 4a | Context chips (directory, branch, environment), git project detection, directory colour tagging, block chrome | Built, tested, running |

### What is parked, on purpose

| Feature | Where it is | Why |
| --- | --- | --- |
| **Phase 3 — the editor** | `app/src/terminal/view/CommandEditorView.swift` | The model half is built and tested (tokenizer, command resolver, completion, the submit encoding — the last is `" "` + Ctrl-K + Ctrl-U, three bytes of protocol that exist so Ctrl-U has something to delete and the shell does not bell). The view half was written three times and broke the app three times; the crashes do not show up in a harness or a typecheck. The terminal is back to the way Phase 2.5 left it. The piece that needs a running window is the visible part: focus, frame arithmetic, the popover. |
| **Phase 3 — the Tab popover** | — | Blocked on the editor; the completion engine behind it is built and tested. |
| **Phase 4b — multi-session** (sidebar, tabs, split panes) | Built. The model is in `crates/warp_terminal/src/model/` — `PaneTree.swift`, `PaneLayout.swift`, `Tab.swift`, `TabList.swift`, 225 checks. The view is in `app/src/workspace/` and `AppCore.swift`. | **It has never run.** The model is verified; the view layer has only been typechecked, and this project's view layer has been wrong four times out of four. `docs/phase-4b-todo.md` lists what to look at, most-likely-wrong first. Still missing on purpose: dividers and dragging, a draggable sidebar. |
| **Runtime-version chip** (rustc, node, python) | — | Deferred. You said later is fine. |
| **Git ahead/behind / dirty count** | `crates/warp_terminal/src/model/RepoMetadata.swift` | Absent rather than approximated — a wrong count is worse than no count, and the count is not in a file. |
| **Clicking a chip** | — | Deferred. |

### Built but unused by the app

These are model code from Phase 3 that compiles, has harness checks, and is not wired into the
running terminal because the editor is parked:

| File | Owns |
| --- | --- |
| `crates/warp_terminal/src/model/ShellTokenizer.swift` | flat, non-overlapping `(range, kind)` spans for the editor |
| `crates/warp_terminal/src/model/CommandResolver.swift` | three-valued `found` / `notFound` / `indeterminate` |
| `crates/warp_terminal/src/model/Completion.swift` | history + paths + signature table, ghost text |
| `crates/warp_terminal/src/model/CommandSubmission.swift` | `" " + VT + NAK` prefix + CRLF escaping |
| `app/src/terminal/view/CommandEditorView.swift` | the `NSTextView` subclass |

### Open defects from the audit (`docs/audit-phase-1-2.md`)

Eight findings, written down with their fixes. Pick from the top:

| # | Finding | Severity | Status |
| --- | --- | --- | --- |
| 5 | **bash users lose their entire configuration** — the generated `integration.bash` is `--rcfile`-pointed at a file that sources nothing; zsh gets all four of its dotfiles, bash gets none. | **High** | Mostly fixed in the latest commit (`ShellBootstrap.swift`); verify with `Tests/shell-integration-test.swift`. |
| 6 | **Scrolling back then new output yanks the view** — `sessionDidUpdate` keeps `scrollPosition` unchanged while `viewportTop` is derived from `totalHeight`, so every new line scrolls the text being read away. The comment above the code claims the opposite. | **High** | Open. |
| 7 | **A wide glyph is not drawn as its own run** — runs are concatenated into one `CTLine` at one origin, so a CJK line drifts out of alignment from its start column. The file's own comment says a monospace face does not promise a double-width advance. | Medium | Open. |
| 8 | **OSC 52 unimplemented** — `TerminalEvent.clipboardWrite` is declared and never emitted. | Medium | Open. |
| 9 | **Three parsed modes are stored and never read** — `reverseVideo` (DECSCNM), `focusReporting` (`?1004`), `applicationKeypad` (DECKPAM/DECKPNM). | Medium | Open (or record as deferred). |
| 11 | **A document contradicts a constant** — `phase-2.md` says OSC payload cap is 8 KB; `VTParser` caps at 64 KB. | Low | Open. |
| 12 | **Stale ticks and a stale index** — `phase-2-todo.md` ticks five things the 2.5 rework deleted; the view's `index.md` describes a selection *border* and a *parked editor* as though both were live. | Low | Open. |

(Items 1, 2, 3, 4 and 10 — bracketed paste, cursor blink, selection tint, stray temp file, reflow —
are fixed.)

### The Warp features explicitly deferred

Per `warp_features.md` and `phases.md` §"Later": block sharing & permalinks (#9), automatic secret
redaction (#14), the local control daemon & CLI IPC (#27), and live multiplayer sessions (#31).
Each is "for later" because each needs a backend we have not written.

---

## 5. Architecture and directory layout

The tree follows Warp's. Read `AGENTS.md` §"Directory Structure" first; this is the live map.

```
swiftTerm/
├── AGENTS.md                              # the hard rules
├── README.md                              # the GitHub-facing 13-liner (do not extend)
├── READ_ME.md                             # this file
├── Package.swift                          # one target, sources in app/src + crates/*
├── tinycast_architecture_and_rules.md     # engineering posture & design system
├── warp_features.md                       # the feature catalogue — what we are implementing
│
├── app/                                   # the application (Warp: app/)
│   ├── Info.plist                         # build number is bumped on every build-app.sh
│   ├── SwiftTerm.entitlements             # ad-hoc signed locally
│   ├── index.md
│   └── src/
│       ├── AppCore.swift                  # composition root — the window's tabs, one shell per pane
│       ├── AppDelegate.swift              # launch and terminate
│       ├── AppMenus.swift                 # menu bar; targets nil, walks responder chain
│       ├── SwiftTermApp.swift             # @main
│       ├── index.md
│       ├── workspace/                     # PHASE 4b — the window: the sidebar, and where panes go
│       │   ├── WorkspaceScreen.swift      # backdrop, sidebar, resize handle, panes by PaneLayout
│       │   ├── WorkspaceSidebar.swift     # glass; the traffic lights' row, New Tab, the tabs
│       │   ├── SettingsView.swift         # the settings page, as a tab; the material switch
│       │   ├── TabRenameField.swift       # the NSTextField a tab is renamed in
│       │   └── index.md
│       └── terminal/
│           ├── TerminalSession.swift      # one shell on one pty
│           ├── index.md
│           ├── model/                     # deliberately empty; see crates/warp_terminal/src/model/
│           │   └── index.md
│           └── view/
│               ├── TerminalCoordinator.swift      # owns session + surface view, and `isActive`
│               ├── TerminalFont.swift             # the monospace cell metrics
│               ├── TerminalRenderer.swift         # CoreText paint; selected block tint; alt screen
│               ├── TerminalSurfaceView.swift      # focus, keyboard, scroll, resize, block selection
│               ├── CommandEditorView.swift        # PHASE 3 — PARKED, do not instantiate
│               ├── TerminalPane.swift             # one pane's content: the surface, or the failure
│               ├── TerminalWindowController.swift # the NSWindow, and the menu actions' landing point
│               └── index.md
│
├── crates/                                # subsystems shared by the app (Warp: crates/)
│   ├── index.md
│   ├── warp_terminal/                     # the emulator + process control + shell hooks
│   │   ├── index.md
│   │   └── src/
│   │       ├── index.md
│   │       ├── model/                     # the emulator and the block model — PURE
│   │       │   ├── TerminalGrid.swift     # screen, scroll region, scrollback, alt screen, RESIZE+REFLOW
│   │       │   ├── TerminalLine.swift     # one row + isWrapped
│   │       │   ├── TerminalCell.swift     # one cell + display width (hand-rolled wcwidth)
│   │       │   ├── CellAttributes.swift   # bold/faint/italic/underline/reverse
│   │       │   ├── TerminalColor.swift    # default/indexed/rgb + xterm-256 expansion
│   │       │   ├── TerminalRGB.swift
│   │       │   ├── TerminalPalette.swift  # 16 ANSI slots + fg/bg/cursor
│   │       │   ├── TerminalPen.swift      # the attributes SGR has left in force
│   │       │   ├── TerminalModes.swift    # ANSI + DEC private modes (2004h here is the paste fix)
│   │       │   ├── TerminalCursorStyle.swift
│   │       │   ├── TerminalSize.swift
│   │       │   ├── VTStringDecoder.swift  # incremental UTF-8
│   │       │   ├── VTParser.swift         # the byte state machine + CSI/OSC dispatch
│   │       │   ├── TerminalEvent.swift
│   │       │   ├── ShellIntegrationEvent.swift
│   │       │   ├── BlockGrid.swift        # one grid + its lifecycle
│   │       │   ├── HeaderGrid.swift       # prompt-and-command grid + promptEnd
│   │       │   ├── Block.swift            # header + output grid + metadata
│   │       │   ├── BlockID.swift          # monotonic identifier
│   │       │   ├── BlockList.swift        # ordered blocks + prompt cycle + block cap
│   │       │   ├── BlockLayout.swift      # document geometry — headerTop, contentTop, lineCount
│   │       │   ├── RepoMetadata.swift     # branch out of .git/HEAD, project kind from manifest
│   │       │   ├── ContextChip.swift      # ordered chips a prompt deserves
│   │       │   ├── DirectoryColorTag.swift # path-to-colour table matched by longest prefix
│   │       │   ├── PaneTree.swift         # PHASE 4b — the split tree
│   │       │   ├── PaneLayout.swift       # PHASE 4b — the tree as rectangles; the gap is the divider
│   │       │   ├── Tab.swift              # PHASE 4b — one tab: an identity and a pane tree
│   │       │   ├── TabList.swift          # PHASE 4b — the tabs in a window, and which shows
│   │       │   ├── ShellTokenizer.swift   # PHASE 3 — built, parked
│   │       │   ├── CommandResolver.swift  # PHASE 3 — built, parked
│   │       │   ├── Completion.swift       # PHASE 3 — built, parked
│   │       │   ├── CommandSubmission.swift # PHASE 3 — built, parked
│   │       │   └── index.md
│   │       ├── local_tty/
│   │       │   ├── PseudoTerminal.swift   # forkpty + TIOCSWINSZ + reap
│   │       │   └── index.md
│   │       ├── shell/
│   │       │   ├── ShellType.swift        # zsh/bash/fish/other
│   │       │   └── index.md
│   │       └── bootstrap/
│   │           ├── ShellBootstrap.swift   # the integration scripts (embedded, not shipped)
│   │           └── index.md
│   └── warpui_core/                       # design tokens + visual effect view
│       ├── index.md
│       └── src/
│           ├── Theme.swift                # every design token — view that invents its own padding rots the design
│           ├── VisualEffectView.swift     # behind-window blur
│           └── index.md
│
├── Tests/                                 # standalone harnesses, no XCTest
│   ├── HarnessSupport.swift               # assertion helper + read-only extensions
│   ├── terminal-grid-test.swift           # 106 checks
│   ├── vt-parser-test.swift
│   ├── shell-integration-test.swift       # the OSC 133 cycle
│   ├── block-list-test.swift
│   ├── block-layout-test.swift
│   ├── block-grid-test.swift
│   ├── header-grid-test.swift
│   ├── terminal-session-test.swift        # ONLY end-to-end harness — real shell, real pty
│   ├── shell-tokenizer-test.swift         # Phase 3
│   ├── command-resolver-test.swift        # Phase 3
│   ├── completion-test.swift              # Phase 3
│   ├── editor-submit-test.swift           # Phase 3 — pins the " " VT NAK prefix
│   ├── context-chips-test.swift           # Phase 4a
│   ├── pane-tree-test.swift               # Phase 4b — 101 checks
│   ├── pane-layout-test.swift             # Phase 4b — 41 checks
│   ├── tab-list-test.swift                # Phase 4b — 125 checks
│   ├── chrome-settings-test.swift         # Phase 4b — 59 checks
│   └── index.md
│
├── Scripts/
│   ├── run-tests.sh                       # compiles + runs every harness in parallel; no XCTest
│   ├── lint.sh                            # swiftlint + pure-model grep gate
│   ├── build-app.sh                       # swift build, assembles .app, advances build number, installs
│   ├── run.sh                             # build, install, launch
│   └── index.md
│
├── docs/                                  # the phase plan and the per-phase detail
│   ├── index.md
│   ├── phases.md                          # the plan
│   ├── phase-1.md, phase-1-todo.md
│   ├── phase-2.md, phase-2-todo.md
│   ├── phase-2.5.md, phase-2.5-todo.md
│   ├── phase-2.6-todo.md                  # reflow — the one Phase 1 ticked and never built
│   ├── phase-3.md, phase-3-todo.md        # the editor — model built, view parked
│   ├── phase-4.md, phase-4-todo.md        # 4a context & chrome (built); §6 is 4b
│   ├── phase-4b-todo.md                   # 4b multi-session — built; what to look at, in order
│   ├── audit-phase-1-2.md                 # twelve findings from checking every ticked box
│   ├── journal.md                         # the narrative — what was tried, what failed
│   ├── learnings.md                       # technical residue
│   └── settings.md                        # the settings standard
│
├── dist/                                  # .app bundles land here; .gitkeep so SwiftPM doesn't warn
└── .swiftlint.yml
```

### Load-bearing facts about the layout

- **One SwiftPM target, sources in three directories.** A Swift module boundary would mean marking
  the whole emulator API `package` for no gain — the purity rule is already enforced by the
  harnesses, which compile the model sources on their own and would fail if AppKit ever leaked in.
- **`exclude:` in `Package.swift` must come before `sources:`** or the manifest is rejected.
- **Every `exclude:` path must exist** or SwiftPM warns on every build. The `index.md` in every
  directory is named individually — SwiftPM has no globs — and that doubles as the honest list
  of what is not code. `dist/` is kept alive with a `.gitkeep` for the same reason.
- **Non-Swift files inside a `sources:` directory are warnings, not errors.** Easy to mistake for
  a real problem. A stray temp file in `Tests/` (which is excluded) was once sitting in there
  doing nothing; a sweep is worth running if you see `no rule to process file` warnings.
- **`HeaderGrid` holds one grid, not Warp's two.** The split is for knowing where the prompt
  ends, which is one point. A second grid nothing writes to would drift. Phase 3's editor
  changes this — when it is unparked, `HeaderGrid` becomes two grids so the prompt is drawn
  independently of the editor's buffer.

---

## 6. Toolchain and environment — read this before you build anything

This is the most error-prone section of the project. Get any of it wrong and you spend an hour
debugging a healthy app.

### What works here

- **`Scripts/run-tests.sh`** — compiles every harness in parallel with `swiftc -warnings-as-errors`.
  A harness that stops compiling means a decision leaked out of a pure layer. **There is no
  XCTest**, and every harness opens with `@main enum SomethingTest { static func main() { ... } }`.
  A harness that touches `@MainActor` types must itself be `@MainActor` (put it on the enum, not
  on `main()`). The runner is at
  `/Users/ca5/Desktop/swiftTerm/Scripts/run-tests.sh` and writes per-harness logs to
  `${TMPDIR:-/tmp}/swiftterm-harness/<name>.log`.

- **`Scripts/lint.sh`** — swiftlint, then the pure-model import gate. Warnings do not block;
  errors do. The grep gate is the honest statement of the model-layer purity rule even though
  the harnesses already enforce it at compile time.

- **`swiftc -typecheck`** on the whole app works, *if you strip `@Observable` and
  `@ObservationIgnored` first* (the macros cannot expand under the sandbox — see below). The
  command that has been used:

  ```bash
  T="${TMPDIR:-/tmp}/swiftterm-typecheck"
  rm -rf "$T" && mkdir -p "$T" && cp -R app crates "$T"/
  perl -pi -e 's/\@Observable//g; s/\@ObservationIgnored //g' \
      $(find "$T" -name '*.swift')
  swiftc -typecheck -swift-version 6 \
      $(find "$T/app/src" "$T/crates" -name '*.swift' | sort)
  ```

  This catches every wrong name and signature in the view layer without expanding a macro. It
  is **not** a substitute for `swift build`; it does not link.

### What does not work here

- **`swift build`** — refused by the sandbox, not the project's fault. SwiftPM sandboxes manifest
  compilation itself, so it dies with `sandbox_apply: Operation not permitted`. Adding
  `--disable-sandbox` fixes that one and not the next one: `@Observable` is a macro, expanding
  it runs `swift-plugin-server`, and that needs `sandbox-exec` too. So the app has only ever
  been compiled by the person running it. The model layer compiles in the harnesses because the
  harnesses call `swiftc` directly and never touch a macro.
- **`git`** — every git command unlinks a `*.lock` path and that is denied, so `git init` fails
  here. Keep a copy of the tree somewhere writable instead; that is the undo. `git commit -s -S`
  still applies when the human runs it from Terminal.app.
- **`sed -i ''`** — the `sed` on `PATH` is a toybox shim, not BSD sed. It reads `-i` differently
  and dies. Use `perl -pi -e` in scripts, or the `Edit` tool.
- **Swift 6.2 toolchain** — `.macOS(.v26)` requires `swift-tools-version: 6.2`; at 6.0 the
  manifest fails with `'v26' is unavailable`. The machine is on macOS 27 / Xcode 27 / Swift 6.4.
- **Launching the app from a sandboxed shell** — it kills the app when the command finishes,
  which looks exactly like a crash. For an `open -a` smoke test, use `dangerouslyDisableSandbox`
  or you will spend an hour debugging a healthy app.

### Swift gotchas that bit this project

(All in `learnings.md`; the short version.)

- **`"\r\n"` is one `Character`.** CRLF is a single extended grapheme cluster, so a buffer
  ending in CRLF kept a line continuation with nothing after it in `CommandSubmission.escaped`.
  Strip or scan line endings by normalising `\r\n` to `\n` *first*.

- **`super.init(frame:)` traps in an `NSTextView` subclass.** The designated initializer is
  `init(frame:textContainer:)`; a subclass that declares its own designated initializer gets
  an *unimplemented* stub emitted for the inherited one, so re-dispatch lands on the stub and
  traps at launch. The trace is `CommandEditorView.init(frame:textContainer:)`. Call the
  designated initializer on `super` instead. This trap does not show up in a typecheck.

- **`NSEvent.SpecialKey` is not what you would guess.** No `.escape`. Only some keys are
  "special" — arrows, function keys, Home/End/PageUp/PageDown/Insert/DeleteForward arrive as
  `specialKey`; Tab, Return, Escape, Backspace and every Ctrl chord arrive as control characters
  in `characters`. Handle both.

- **Shift-Tab arrives as the single control character `0x19`** — every shell expects the
  two-byte `CSI Z`. The one key that has to be spelled out by hand.

- **`doCommand(by:)` needs `override`** — `NSResponder` already declares it. The hook that
  turns Option+Arrow into `ESC b` / `ESC f` via the input system's word-movement selectors.

- **`@preconcurrency` on an `NSTextInputClient` conformance** lets a `@MainActor` class satisfy
  the protocol's non-isolated requirements without `MainActor.assumeIsolated`. The protocol also
  needs `firstRect(forCharacterRange:)` or the IME candidate window lands in the corner.

- **`@Observable` works on a `@MainActor` class.** Mark non-`Sendable` stored properties
  `@ObservationIgnored` or the macro will try to observe an `NSView`.

### CoreText rendering gotchas

- **Measure the cell from a real glyph, not a typographic constant.** `CTFontGetAdvancesForGlyphs`
  on `M` is the only value that agrees with where the next column actually lands; several
  monospace faces disagree with `size(withAttributes:)`.
- **Snap the cell box to whole pixels, not whole points.** Rounding to points halves the usable
  density on a Retina display.
- **An unflipped `NSView` is y-up**, so row *r* is drawn at
  `bounds.maxY - (r + 1) * cellHeight`. Flipping the view makes CoreText draw text upside down.
- **A glyph wider than one column must be its own `CTLine`.** A monospace face does not promise
  a double-width advance, so a run containing CJK drifts out of alignment from its start column.
  (This is audit finding #7 — currently broken.)
- **Combining marks need folding, not placing.** `TerminalCell.displayWidth` returns 0 for them
  and the grid appends them to the cell before; a terminal that places them gets a row one
  column too wide.
- **`wcwidth` reads the process locale**, which a test harness must not have to mutate. The
  East-Asian-Width table in `TerminalCell.swift` is hand-rolled for that reason.

### PTY gotchas

- **`forkpty` is the right call.** It is `openpty` + `fork` + `setsid` + `TIOCSCTTY` + `dup2` in
  one function. The `TIOCSCTTY` is what matters: without a controlling terminal a shell cannot
  put a job in the foreground, so `Ctrl-C`, `Ctrl-Z` and `fg` all silently do nothing.
  `posix_spawn` cannot do this, because the `TIOCSCTTY` has to happen in the child between
  `fork` and `exec`.
- **A `read` parked on a pty master cannot be interrupted.** Not by a signal, not by cancelling
  the Swift `Task` around it. Closing the master is the only thing that unblocks it.
- **Shutdown order is load-bearing.** Signal the shell, close the master, *then* cancel — and
  poll `reapIfExited()` rather than blocking on the main actor. The first version cancelled the
  read task and then signalled the shell; `finish()` then blocked the main actor in `waitpid`
  for a child that was never going to be signalled. It presented as a hung test harness.

---

## 7. How to work — the workflow

### Before you change anything

1. **Read the relevant `phase-N-todo.md`** — it is the working checklist, ticked against a real run.
2. **Read the relevant `phase-N.md`** — it is the *why*, with exit criteria.
3. **If what you are changing has a model half, write the harness first.** The model layer has
   been right every time, the view layer has been wrong three times out of three. See §9.
4. **If what you are changing is the view layer, write it against a running window rather than
   ahead of one.** You will not see runtime dispatch traps, focus moving mid-keystroke, or a
   missing caret from a typecheck.

### Making a change

1. Move what can be moved out of the view and into the model, where a harness can hold it.
2. If a finding from `docs/audit-phase-1-2.md` matches what you are doing, **read the existing
   test before assuming it still passes**. The reflow audit found three places where the old
   tests had been asserting the buggy behaviour as correct.
3. Update the relevant `index.md` when you change a directory.
4. Update the relevant `phase-N-todo.md` as you complete items — a tick means *the code exists
   and has been verified*, not just that someone wrote it.

### The five gates (every phase, every PR)

From `tinycast_architecture_and_rules.md` §8, and they apply to *every* change, not just at
phase boundaries:

1. `./Scripts/run-tests.sh` green.
2. Zero new compiler warnings (`-warnings-as-errors` in the runner; the typecheck command above).
3. `./Scripts/lint.sh` clean.
4. Pure-model grep empty (the gate inside `lint.sh`).
5. Docs updated in the same commit — phase doc, index.md, audit if a finding is closed.

A warning is a gate violation that ships quietly if nobody is reading build output. **SwiftPM
warns about non-Swift files inside `sources:`, not errors.** That is how the stray
`XXoWyLMh` file went unnoticed for an entire phase.

### The end of a phase

When a phase is complete: build and install the app so it can be tested, **then stop**. Do not
start the next phase in the same turn. This is the human's testing boundary
(`AGENTS.md`).

### The rules the human has held you to

The user has corrected chrome four times in a row — every correction was visible only when the
app was run, and three of the four were about a rectangle of colour. Recorded in
`docs/journal.md` §"What the first build of 4a got wrong". **Chrome cannot be reasoned into
place from here; it has to be looked at.** When you finish something visual, leave the
document you wrote up with what you *expect* to look right, so the human can see your
prediction and tell you when it is wrong.

---

## 8. Things to know about specific subsystems

### The grid

- **Every block owns its own grids** — `HeaderGrid` for the prompt-and-command, `BlockGrid` for
  the output. There is no shared line sequence and no index arithmetic between blocks. A
  block's extent is its own grid's length, so the off-by-one that a shared sequence invited
  cannot be written down.
- **`Sealed` is not frozen.** A finished grid is re-wrapped on resize like any other — finished
  means the shell will not write to it again, not that its bytes are fixed. The re-wrapping
  is `TerminalGrid.reflow`, a pure static function that rejoins the rows a logical line is
  made of, re-splits them at the new width, and maps the cursor through.
- **`VTParser` writes into one grid at a time** and calls it directly rather than through a
  delegate. The grid is settable — that is how the output moves from a block's prompt grid to
  its output grid to the next block.

### The shell integration protocol

- **OSC 133** is the prompt cycle: `A` (prompt start), `B` (command start), `C` (pre-exec),
  `D` (finished + exit code). `TerminalIntegrationEvent.swift` is where they land.
- **OSC 7** is the working directory (Warp gets this via OSC 7 too; the prompt is wiped in the
  bootstrap so the directory arrives as a chip rather than as text).
- **OSC 9281** is swiftTerm's own channel, carrying the command line itself from `preexec`.
  The grid cannot give up the command line because the prompt and the command are one drawn
  line, and splitting them would mean guessing where the user's prompt ends.
- **OSC 9282** is the second channel — facts only the shell knows (virtualenv, conda env). The
  body format is `key value` with the value being the rest of the body (no splitting), because
  a value can contain `=` and, for a path, `;`.
- **OSC 52** is clipboard write — declared, never emitted (audit finding #8).

### The shell bootstrap

- **`ShellBootstrap.swift`** holds the integration scripts as embedded strings, not as
  resources. A resource file can drift from the parser that reads it; a string in the same
  module cannot.
- The integration **empties `PROMPT`, `PS1` and `fish_prompt`** so a command sits at the left
  margin and a block reads as a command + its output rather than as a transcript. The
  directory is not lost — it arrives over `OSC 7` and is the first chip.
- zsh is shimmed via `ZDOTDIR` pointing at a generated directory containing all four dotfiles
  (`.zshenv`, `.zprofile`, `.zshrc`, `.zlogin`) that source the user's originals.
- bash is launched with `--rcfile <generated>/integration.bash -i`. **The generated rc must
  source the user's `~/.bashrc` / `~/.bash_profile` first** — that is `phase-1.md`'s
  requirement and was audit finding #5; verify with `Tests/shell-integration-test.swift`.

### The protocol is what the protocol actually emits

This is the lesson from Phase 2's boundary bug and it is worth a paragraph:

> The prompt cycle is not `A B C D`. zsh's first `precmd` reports the **exit status of the rc
> files**, so the real stream from a fresh shell is `A B D A B C D A B`. `finish` sealed
> whatever block was last — which at that first `D` was the block about to hold the user's
> first command. The block then looked sealed, so when the real `D` arrived `finish`'s guard
> rejected it and the block kept `endLine` from the earlier, bogus marker. The block's range
> came out `3..<3`: empty. Its header showed the right command and the right exit code, and
> its output was nowhere.

Every unit test passed while the feature was broken, because the tests encoded the same wrong
assumption as the code — that a lifecycle starts with `begin`. The fix was two guards rather
than special cases, both of which are gone now, replaced by a property of the type. **The
lesson:** capture the stream and read it before trusting a state machine built on it. The
end-to-end harness `terminal-session-test.swift` exists for exactly this — it spawns the real
shell and reads the real marker stream.

### Block layout (`BlockLayout.swift`)

Pure. Computes where every header and line lands in the document — `headerTop`, `contentTop`,
`lineCount` per block. The view layer never recomputes it; it gets handed the same layout the
renderer just painted. This is what makes Warp's input-element approach work: every frame lays
out from the model, so there is no second thing to keep in sync.

---

## 9. The two structural lessons from this project

These are worth a section of their own because they have shaped every decision since.

### Lesson 1: a claim about the system that was never checked against the system

Three defects hid here, all of them documentation-shaped:

1. **A ticked box that was never true.** Phase 1 planned `TerminalLine` as "cells + soft-wrap
   flag" and ticked it. The flag was built and the re-wrapping it existed for never was — so
   for five phases a narrower window destroyed the right-hand side of every line.
2. **A document that asserted the missing thing worked.** Three did, in the reflow case:
   `phase-2.5.md`, the model's `index.md`, and a manual test in `phase-2.5-todo.md`. A test
   written from the same belief as the code proves the belief, not the behaviour.
3. **A warning nobody read.** SwiftPM warned twice on every build about a stray non-Swift file
   in `sources:`. The warning was a gate violation that nobody was looking for.

The audit (`docs/audit-phase-1-2.md`) was prompted by the reflow and is the standing answer:
**every ticked box, checked against the code**. The harness count grew 461 → 524 across that
exercise.

### Lesson 2: the model layer is reliable because harnesses hold it; the view layer is not

| | Model layer | View layer |
| --- | --- | --- |
| Bugs found by harnesses | 2 | — |
| Bugs found by the user | 0 | 4 |
| Checks guarding it | 774 | 0 |

The four view-layer bugs, in order: a launch trap (`super.init(frame:)` in an `NSTextView`
subclass); focus that switched mid-keystroke because the editor's first responder status was
re-asserted from a callback that fires on shell output; a frame computed from callbacks, so
typing did not move it and scrolling did not carry it; and a cursor that disappeared because
the surface lost first responder without the editor's caret appearing. None of these is
visible to a harness (which never compiles the view layer) or to a typecheck (which cannot see
a runtime dispatch trap, a callback that never fires, or a caret that is not drawn).

**Working rule for the phases ahead:** move what can be moved out of the view and into the
model, where a harness can hold it. `BlockLayout`, `ShellTokenizer`, `CommandResolver`,
`Completion` and `CommandSubmission` all exist because of that. And for what cannot be moved,
write it against a running window rather than ahead of one.

---

## 10. The directory narrative — what got tried, in one paragraph

**Phase 1** built a live shell on a real pty, with VT emulation, scrollback, keyboard, resize
and `OSC 133`. The bug worth remembering was a row cache keyed by view row, not by what
identifies the row, so the first scroll step rebuilt correctly and every one after it
redrew the previous viewport. Symptom: "scrolling doesn't feel like scrolling". Fixed by
keying on what actually identifies the row. (`learnings.md` §"The bug worth writing down".)

**Phase 2** made blocks real objects: boundaries derived from the shell hooks, sealed-on-finish
immutable grids, the block list, headers, per-block selection and copy, block jumping. The
boundary bug above was found by `terminal-session-test.swift`, the only end-to-end harness,
because every unit test had encoded the same wrong assumption as the code.

**Phase 2.5** reversed Phase 2's *one grid, blocks as line ranges* on the grounds that
`warp_features.md` #1 says not to. Every block now owns its own `HeaderGrid` and `BlockGrid`;
the index arithmetic that sharing required was deleted; the bound moved from a shared
scrollback to a block cap. The `AGENTS.md` rule "a divergence from Warp is allowed only where
a phase doc records it and why" was added in this phase, and the divergence that broke it
("Phase 2 deliberately shared one grid") was reversed in the same phase.

**Phase 2.6** is a phase that exists because a ticked box was never true. `TerminalGrid.reflow`
is a pure static function, and 38 new checks guard it. Three of them caught mistakes in the
reflow itself, including one where the *old* resize test had been asserting the buggy behaviour
as correct since Phase 1. **Read `docs/phase-2.6-todo.md` §"Three things the harness caught".**

**Phase 3** planned the editor and built the model half: tokenizer (with here-documents),
command resolution, completion, the pty submit encoding — the last of which is three bytes of
protocol from Warp (`" "` + Ctrl-K + Ctrl-U), where the space exists so Ctrl-U has something
to delete and the shell does not bell. The view half broke the app four times. It is parked,
on purpose, and the terminal is back to the way Phase 2.5 left it. The pieces that need a
running window are the visible ones — focus, frame arithmetic, the popover.

**Phase 4a** built context chips (directory, branch, environment), git project detection,
directory colour tagging, and block chrome. The chips are where the "native gives me
advantage" case paid off: Warp hex-encodes the git branch and ships it over a DCS channel
because its hooks run in a process it does not control. Here the branch is the contents of
`.git/HEAD`, so `RepoMetadata` reads the file. No process spawn per prompt, and a harness can
test it against a temporary directory. 46 checks, found nothing on the first run — the first
time in this project that has happened.

**Phase 4b** is the next structural change: the sidebar, tabs, split panes. These need the
app to hold more than one session, which `AppCore` cannot (it owns one `TerminalCoordinator`,
one window, one pty). A list of them is the tab model; a tree of them is the split model; a
view over the list is the sidebar. The session, surface and coordinator are already separable
— `TerminalCoordinator` is the action surface and `TerminalSurfaceView` holds no screen state
— so the work is in `AppCore` and in the window controller, not in the terminal.

**Phase 4b is built and has never run.** `PaneTree`, `PaneLayout`, `Tab` and `TabList` under
`crates/warp_terminal/src/model/` — 250 checks across three harnesses — plus `AppCore` holding a
`TabList` and one coordinator per pane, and the sidebar, the tab strip and the pane placement in
`app/src/workspace/`. It is in `crates/` rather than `app/` — a divergence from Warp's own layout —
because the harnesses compile that directory directly, so a tree in `app/` could not be tested at all.
Three more deliberate differences are recorded with it: a branch holds no flex weights or dividers
(they are rendering facts, and they arrive with the geometry the way `BlockLayout` did), there is no
pane focus history (it exists for undo-close, which is Phase 6), and **the gap between panes is the
divider** — the panes do not touch and the window's own backdrop shows between them, so there is no
rule to draw and no second piece of geometry to keep in step. Every material is Apple's — SwiftUI's
`.ultraThin`/`.thin`, `.glassEffect(.regular)`/`.glassEffect(.clear)` for `NSGlassEffectView`'s two
styles, or `NSVisualEffectView`'s `.titlebar` for the material the removed top bar used — and there is no
custom shader anywhere in the app. They are a setting, and so is the window's opacity, which is the
window's *background colour drawn over* the material rather than the material's own strength: at 100% the
material is hidden, at 0% only the material is left. That is vicinae's arrangement, and
`docs/learnings.md` has why it matters.

The model is verified by its harnesses. The view layer has only ever been typechecked, and this
project's view layer has been wrong four times out of four — so `docs/phase-4b-todo.md` carries
predictions rather than results, most-likely-wrong first, and the phase's real gate is a run.

---

## 11. The order to do things, when you start

You have a task. You read this file. Then:

1. **Re-read `AGENTS.md`** and `docs/journal.md`. They are short and they are the source of
   truth on intent.
2. **Re-read the `phase-N-todo.md` for the phase you are working on.** It is the working
   checklist, ticked against a real run.
3. **If the work is in the model layer**, write the harness first. Use `HarnessSupport.swift`
   for the assertion helpers. Compile with `swiftc -swift-version 6 -warnings-as-errors`.
4. **If the work is in the view layer**, write it knowing you cannot compile it. Use the
   `swiftc -typecheck` workaround from §6 for signatures. The actual visual check is the
   human's; leave the document up to date with what you *expect* so they can confirm or
   correct.
5. **Run `./Scripts/run-tests.sh` and `./Scripts/lint.sh`** before saying you are done.
   Both must be green.
6. **Update the relevant `index.md` and `phase-N-todo.md`.**
7. **Update `docs/audit-phase-1-2.md`** if you close any of the eight open findings.
8. **When the phase is complete**, build and install (`./Scripts/build-app.sh release`) and
   tell the human. Do not start the next phase in the same turn.

---

## 12. A note on what is *not* in this file

- **Per-function documentation.** That lives in the source files themselves, and at the top of
  each directory's `index.md`. The model's `index.md` (`crates/warp_terminal/src/model/index.md`)
  is especially worth a read — it is the closest thing the project has to a "tour".
- **The shell-integration protocol's byte-for-byte spec.** That is in
  `docs/phase-1.md` and `phase-2.md`, and in `VTParser.swift` and `ShellIntegrationEvent.swift`.
- **The design system.** That is in `tinycast_architecture_and_rules.md` and the eight design
  tokens in `crates/warpui_core/src/Theme.swift`.
- **The feature catalogue.** That is `warp_features.md`.

If you find yourself reaching for any of those, read the named file rather than this one.

---

## 13. A short list of files you will edit most often

| File | Why |
| --- | --- |
| `crates/warp_terminal/src/model/TerminalGrid.swift` | The screen. Cursor, scroll region, scrollback, alt screen, **reflow** (Phase 2.6). The hardest arithmetic in the project. |
| `crates/warp_terminal/src/model/VTParser.swift` | The byte state machine + CSI/OSC dispatch. Adding an OSC handler is one switch case plus a harness check. |
| `crates/warp_terminal/src/model/PaneLayout.swift` | Where a pane lands. Pure and harnessed — change it here, never in a view. |
| `crates/warp_terminal/src/bootstrap/ShellBootstrap.swift` | The integration scripts. Embedded, not shipped. |
| `app/src/AppCore.swift` | The window's tabs and one shell per pane. Every command the chrome and the menu bar reach ends up here. |
| `app/src/workspace/WorkspaceScreen.swift` | The window's layout, and where each pane is placed from `PaneLayout`. |
| `app/src/terminal/view/TerminalRenderer.swift` | CoreText paint, selected-block tint, alt-screen drawing. Audit finding #7 lives here. |
| `app/src/terminal/view/TerminalSurfaceView.swift` | Focus, keyboard translation, scrolling, resize, block selection. |
| `app/src/terminal/view/CommandEditorView.swift` | Phase 3 — parked. Edit only when unparking. |
| `Scripts/run-tests.sh` and `Scripts/lint.sh` | If you change the harness source set or the gate. |

---

The terminal works. The things that don't work are recorded with their fixes. The model layer
is reliable; the view layer has never run without the human; the next thing is `AppCore`
learning to hold more than one session.