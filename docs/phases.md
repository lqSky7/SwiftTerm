# swiftTerm — Phase Plan

swiftTerm is a native macOS terminal that takes the *product* ideas from Warp
(`warp_features.md`) and implements them on Apple's own stack: AppKit + SwiftUI +
CoreText + Metal, Swift 6, macOS 26+ only, following the engineering posture in
`tinycast_architecture_and_rules.md`.

This document is the high-level map. Each phase gets its own `phase-N.md` with the
detail and a `phase-N-todo.md` checklist.

---

## The one architectural decision that shapes everything

Warp's terminal core is Rust (`crates/warp_terminal`, ~15k lines of model alone) and is
not liftable: its `Cargo.toml` pulls in `warp_core`, `warpui_core`, `warp_completer`,
`warp_assets`, `channel_versions` and a dozen more workspace crates, so "copy the
emulator" means "port half of Warp". There is also no Rust toolchain on this machine.

So the split is:

| Concern | Where it lives | Why |
| --- | --- | --- |
| Terminal emulation (VT parser, cell grid, scrollback, blocks) | **Swift, `crates/warp_terminal/src/model/`** | It is the product. It must be pure, harness-testable, and ours to shape for blocks. |
| PTY / process control | **Swift, `crates/warp_terminal/src/local_tty/`** | `forkpty` + `TIOCSWINSZ` is ~150 lines of Darwin. |
| Shell integration protocol | **Portable shell, `crates/warp_terminal/src/bootstrap/`** | Warp's shell scripts are plain `zsh`/`bash`; the *protocol* is what we reuse, not the Rust. |
| Rendering | **Swift, CoreText now / Metal later, `app/src/terminal/view/`** | "The entire UI shall be native." |
| Rust reuse | **Only where it pays** (Phase 6 search, maybe Phase 3 syntax trees) | Add it when a specific crate is worth an FFI boundary, not as a foundation. |

Phase 1 therefore uses the standard **OSC 133** shell-integration protocol (prompt
start / command start / pre-exec / finished+exit-code) plus **OSC 7** (cwd) and
**OSC 0/2** (title). Warp's richer hex-encoded-JSON **DCS** hook channel
(`crates/warp_terminal/src/model/ansi/dcs_hooks.rs`, `{"hook": …, "value": …}`) is a
drop-in extension of the same parser and lands in Phase 2, where the extra metadata
(git branch, block ids, timing) is actually consumed. Parsing a protocol nothing reads
yet is the kind of thing this project does not do.

---

## Phases

### Phase 1 — Live Shell Foundation
A native window that is a genuinely usable terminal: PTY-backed shell, correct VT
emulation, scrollback, keyboard, resize, and the shell-integration event channel
working end to end.

Exit criterion: you can open it, run your normal commands, use `vim`, and scroll.

### Phase 2 — Command Blocks
The thing that makes it Warp. Blocks become real objects: boundaries derived from the
shell hooks, sealed-on-finish immutable grids, the block list scroll view, block
headers (cwd · git branch · exit status · duration), per-block selection and copy,
find-within-block, block context menu, block jumping. Adds Warp's DCS hook channel for
richer block metadata.

### Phase 2.5 — A Grid Per Block
Do it the way Warp does it. Phase 2 got the blocks and the boundaries right and the ownership wrong:
one `TerminalGrid` served every block and a block was a range of line indices into it. This gives each
block its own grids — `BlockGrid` with a start and a finish, and a `HeaderGrid` for the prompt and the
command line — and deletes the index arithmetic that sharing required.

Exit criterion: everything Phase 2 did still works, and each block now keeps its own history.

### Phase 2.6 — Reflow
**A phase that exists because a ticked box was never true.**

Phase 1 planned `TerminalLine` as "cells + soft-wrap flag" and ticked it. The flag was built; nothing
ever set it or read it, so the re-wrapping it was there for was never written, and
`TerminalGrid.resize` narrowed or padded each line instead. Three later documents then described the
reflow as working, which is what kept it invisible: `phase-2.5.md` claimed a sealed block re-wraps,
the model's `index.md` claimed the same, and `phase-2.5-todo.md` listed "old blocks re-wrap to the new
width" as a manual test that passed. All four are corrected.

The defect: **narrowing the window permanently destroys the right-hand side of every line**, in every
block, and widening fills the space with blanks rather than restoring it.

The work, all of it in `TerminalGrid` and all of it pure:

- Set `isWrapped` when the grid actually wraps in `put`, which is the one place a wrap happens.
- Rejoin the runs joined by that flag, re-split them at the new column count, and rebuild the flags.
- Map the cursor's line and column through the reflow so it lands on the same character.
- Reflow the *whole* sequence — history and screen together — because a logical line can straddle the
  boundary between them.
- Move the saved primary screen to the new width too, or leaving a full-screen program after a resize
  puts a screen of the wrong shape back.

Exit criterion: a long line wrapped at one width is whole again at a wider one and re-wraps at a
narrower one, the cursor stays on the same character, and nothing is lost or duplicated at any width —
asserted by a harness, because this is the file everything depends on and a botched reflow loses output
silently rather than loudly.

### Phase 3 — Decoupled Command Editor
The bottom input stops being a grid and becomes an editor: multi-line, mouse
positioning, undo/redo, word jump, selections, real-time syntax highlighting,
not-found-command squiggles, inline history ghost text, and an autocomplete popover
fed by command signatures, paths and history.

### Phase 4 — Context & Chrome
**Split into 4a and 4b, because they are not the same size.** `phase-4.md` has the detail.

**4a — Context & chrome.** Context chips (directory, git branch, environment), automatic git project
detection, directory colour tagging, the in-app banner system, and block chrome: the rule that
separates one block from the next, and the horizontal margin that keeps a block's text off its own
edges. Each is additive; none changes how the app is put together.

Block chrome is named here because it was not named anywhere until it was asked about. Warp draws the
separator in `draw_border_between_blocks` (`app/src/terminal/block_list_element.rs`), coloured with
`theme.outline()` and gated on `terminal_spacing.block_borders_enabled` — a one-pixel rule at each
block boundary, plus the padding that stops a selection from touching a glyph. Phase 2 built the block
*header*, which is what tells blocks apart once something has run; the rule and the margin are the
refinement on top.

**4b — Multi-session.** The rich left sidebar and tab manager, and split panes. These need the app to
hold *more than one session*, which it cannot: `AppCore` owns one `TerminalCoordinator`, one window and
one pty. That is a structural change and it gets its own phase, its own exit criterion and its own test
rather than being smuggled in beside a chip.

**Built.** `PaneTree`, `PaneLayout`, `Tab` and `TabList` in `crates/warp_terminal/src/model/`, with 225
harness checks between them; `AppCore` holding a `TabList` and one coordinator per pane; and the
sidebar, the tab strip and the pane placement in `app/src/workspace/`, glass and all. The model is
verified by its harnesses; the view has been typechecked and has **never run**, which is the phase's
real remaining gate — `docs/phase-4b-todo.md` says what to look at and in what order.
`docs/phase-4.md` §6 has the decisions behind it and what is deliberately left out: dividers and
dragging, and a draggable sidebar.

Two items in the original Phase 4 are blocked on something that does not exist, and are recorded as
such rather than built:

- **The banner system** (#45) has nothing to say. Its content is product announcements, connection loss
  and shell-upgrade advice; this app has no network, no accounts and no update channel.
- **Directory colour tagging's picker** (#53) needs somewhere to set a tag, which is the settings
  window — specified in `tinycast_architecture_and_rules.md` §7 and not yet built by any phase. The
  model lands with 4a; the picker waits.

### Phase 5 — Appearance & Interaction
Theme engine (light/dark, 16-colour ANSI palettes, opacity, blur, procedural
backgrounds), theme creator, granular keymap configuration, OSC 8 hyperlinks and
clickable paths, full mouse reporting, alternate-screen polish.

### Phase 6 — Speed & Recall
Embedded ripgrep search over scrollback, history and files; the universal omnibar and
command palette on a fuzzy matcher; session restoration and crash recovery; undo-closed
tab/pane; quit safety when processes are running.

### Phase 7 — Reach
Terminal graphics protocols (Kitty + iTerm2 inline images), executable markdown
notebooks, declarative launch configurations, the built-in git code-review pane,
headless TUI mode, automatic SSH remote bootstrapping.

### Later (explicitly deferred in `warp_features.md`)
Block sharing and permalinks (#9), automatic secret redaction (#14), the local control
daemon and CLI IPC (#27), and live multiplayer sessions (#31). Each is marked
"for later" in the feature catalogue and each needs a backend we have not written.

---

## Rules that hold in every phase

- The five gates in `tinycast_architecture_and_rules.md` §8 pass before a phase is
  done: harnesses green, zero new warnings, lint clean, pure-model grep empty, docs
  updated in the same commit.
- `crates/warp_terminal/src/model/` never imports AppKit, SwiftUI or Cocoa. Enforced by compilation,
  not convention — the harnesses build those files directly.
- The tree follows Warp's: `app/` is the application, `crates/` are the subsystems. New code goes
  where Warp would put it. See `AGENTS.md`.
- The ponytail ladder runs first on every task: does it need to exist, is it already
  here, does the stdlib or a native API already do it.
- `index.md` in every directory, updated whenever that directory changes.
