# Phase 4 — Context & Chrome

**Goal.** The window starts telling you things you would otherwise type a command to find out: where
you are, what branch you are on, whether the tree is dirty, what runtime is in play — and the blocks
stop being one undifferentiated wall of text, with a rule between them and a margin that keeps their
text off their own edges.

**Not in this phase.** The editor (Phase 3, parked). Themes (Phase 5). Search (Phase 6).

**Exit criterion.** The chips above the prompt show the directory and, inside a repository, the branch.
Run a few commands and there is a visible rule between the blocks. Tag a directory with a colour and
the chip picks it up. Nothing else changes.

---

## 1. This phase is two phases, and should be

`phases.md` lists Phase 4 as one thing: context chips, the sidebar and tab manager, split panes, git
project detection, directory colour tagging, the banner system, and block chrome. Those are not the
same size.

| | |
| --- | --- |
| **4a — Context & chrome** | chips, git project detection, block chrome, directory colour tagging. Each is small, each is additive, and none of them changes how the app is put together. |
| **4b — Multi-session** | the sidebar, the tab manager, split panes. These need the app to hold *more than one session*, which it cannot: `AppCore` owns exactly one `TerminalCoordinator`, one window and one pty. That is a structural change and it deserves its own phase, its own exit criterion and its own test. |

So this phase is **4a**. 4b is written down here and left for when it can be done properly.

Two more of the listed items are blocked on something that does not exist yet, and saying so is more
useful than building them:

- **The banner system** (#45) has nothing to say. Its content is product announcements, connection loss
  and shell-upgrade advice, and this app has no network, no accounts and no update channel. It is a
  rendering feature with no source.
- **Directory colour tagging** (#53) needs somewhere to *set* a tag, which is the settings window —
  and `tinycast_architecture_and_rules.md` §7 already specifies a settings hierarchy that no phase has
  built yet. The model can land now; the picker waits for settings.

## 2. Where the facts come from, and the one place we beat Warp at it

Warp's `precmd` gathers `$PWD`, the git branch, the virtualenv, the node version and more, hex-encodes
them as JSON and ships them over a DCS channel (`warp_features.md` #5). It has to: its shell hooks run
in a process it does not control.

Most of that is a *file read* from where we are sitting:

| Fact | Where it comes from |
| --- | --- |
| working directory | `OSC 7`, already flowing since Phase 1 |
| **git branch** | **`.git/HEAD` — read directly, no process spawn** |
| **project kind** | **`Cargo.toml` / `package.json` / `pyproject.toml` / `Package.swift` / `go.mod`** |
| virtualenv or conda env | `OSC 9282` from the shell — only the shell knows this |

Reading `.git/HEAD` is a file read rather than a `git` invocation per prompt, and it is testable in a
harness with a temporary directory. That is the "native gives me advantage" case: Warp pays a process
spawn per prompt for a string that is sitting in a file. Ahead/behind and dirty counts are *not* in a
file and do need git, so they are deferred rather than faked — a count that is wrong is worse than a
count that is absent.

**`OSC 9282`** is the second channel, following `9281`'s pattern: a code in the private range, a fixed
key, a space, then the value as the whole rest of the body.

```
OSC 9282 ; branch main BEL      # when the shell would rather report it than have us read the file
OSC 9282 ; venv .venv BEL
```

A key and the rest of the body, rather than `key=value` pairs separated by `;`, because a value may
contain `=` and — for a path — `;`. The value is never split.

## 3. Model

| File | Owns |
| --- | --- |
| `RepoMetadata.swift` | walking up from a directory for `.git`, reading the branch out of `HEAD`, and recognising a project by its manifest |
| `ContextChip.swift` | the ordered chips a directory deserves: directory, branch, environment |
| `DirectoryColorTag.swift` | a path-to-colour table, matched by longest prefix |

`RepoMetadata` is pure and takes a `FileManager`, so a harness points it at a temporary directory and
gets a real answer. `ContextChip` is a pure function of `(cwd, repo, environment)` — which is what
makes it testable at all, and is the whole reason it is a model rather than a view.

## 4. Rendering

- **Chips** are drawn in the block that is being edited, on the line above the prompt — the same place
  Warp puts them. They are drawn by the renderer as part of the document, not as views: a chip is a
  rounded capsule with a background and a label, which is one Core Graphics path and one `CTLine`.
  Clicking one is not in this phase.
- **Block chrome** is Warp's, and this is where the separator the user asked about lands:
  `draw_border_between_blocks` (`app/src/terminal/block_list_element.rs`), one rule at each block
  boundary in `theme.outline()`, gated on `terminal_spacing.block_borders_enabled`, plus the block
  margin that keeps text off the edges and stops the selection tint touching a glyph.

## 5. Gates

1. `./Scripts/run-tests.sh` green, with new harnesses for `RepoMetadata`, `ContextChip` and
   `DirectoryColorTag`, and `OSC 9282` added to the parser harness.
2. `swift build -c release` clean, zero warnings. **The stray non-Swift file in `model/` is gone**, so
   the two `no rule to process file` warnings are gone with it.
3. `./Scripts/lint.sh` clean.
4. Pure-model grep still empty.
5. `index.md` updated in every directory that changed.
6. The app installs and runs.

## 6. 4b — multi-session

### Both halves are built; the view half has never run

`AppCore` used to own one `TerminalCoordinator`, which owned one `TerminalSession` and one
`TerminalSurfaceView`. A tab is a list of those plus which one is showing; a split is a tree of them;
the sidebar is a view over the list. The session, the surface and the coordinator were already
separable — `TerminalCoordinator` is the action surface and `TerminalSurfaceView` holds no screen
state — so the work was in `AppCore` and in the window controller, not in the terminal, and that is
where it went.

| File | Owns | State |
| --- | --- | --- |
| `crates/warp_terminal/src/model/PaneTree.swift` | the split tree, and which pane the keyboard is in | built — 101 checks |
| `crates/warp_terminal/src/model/PaneLayout.swift` | the tree as rectangles, and the gap that divides them | built — 41 checks |
| `crates/warp_terminal/src/model/Tab.swift` | one tab: an identity and a pane tree | built |
| `crates/warp_terminal/src/model/TabList.swift` | the tabs in a window, which is showing, the identity counter, and naming, pinning and order | built — 108 checks |
| `app/src/AppCore.swift` | the `TabList`, a `[PaneID: TerminalCoordinator]`, every command, and the sidebar's width | built, unrun |
| `app/src/workspace/WorkspaceScreen.swift` | the window: backdrop, the sidebar's glass, the column, and the terminal as a panel floating on it | built, unrun |
| `app/src/workspace/WorkspaceSidebar.swift` | the sidebar's column — traffic lights' row, New Tab, the tabs, and the settings popover | built, unrun |
| `app/src/workspace/SettingsView.swift` | the settings page as a tab, and the sidebar's material switch | built, unrun |
| `app/src/workspace/TabRenameField.swift` | the `NSTextField` a tab is renamed in | built, unrun |
| `crates/warpui_core/src/ChromeSettings.swift` | the chrome's numbers, their ranges, the material list, and where the panel lands | built — 34 checks |
| `app/src/terminal/view/TerminalPane.swift` | one pane's content, and the surface's representable | built, unrun |

The model is verified by its harnesses. The view is typechecked and nothing more — the four
view-layer defects this project has had were all invisible to a typecheck, which is why
`phase-4b-todo.md` carries a list of predictions rather than a list of results.

### Four decisions, recorded because the rule requires it

- **It lives in `crates/`, not in `app/`.** Warp's pane tree is `app/src/pane_group/tree.rs` because
  Warp's UI is GPU-drawn and its tree is made of warpui elements. Here the tree is pure and the
  harnesses compile `crates/warp_terminal/src/model/` directly, so putting it in `app/` would mean it
  could not be tested at all — which is the entire reason for writing it first.
- **A branch holds no flex weights and no dividers.** Warp's `PaneBranch` has both. They are rendering
  facts — somewhere for a dragged divider to put the share it was given — and nothing in this model
  drags one. They arrive with the geometry, the way `BlockLayout` did, rather than being stored
  unread; a weight nothing writes to would drift, which is the argument that keeps `HeaderGrid` one
  grid.
- **No pane focus history.** Warp keeps a most-recently-focused list and consults it when the focused
  pane closes. It exists for undo-close, which is Phase 6. What is here is Warp's own fallback: the
  pane before the closed one, or the one after when it was the first.
- **Tabs and panes hand focus over in opposite directions, on purpose.** Closing a pane focuses the
  one *before* it — Warp's rule, because a pane's neighbour is usually where the last command ran.
  Closing the tab that is showing hands over to the one on its *right*, or the left when there is none
  — the browser rule, because a hand expects the strip to move one step left. Both are recorded at the
  code and pinned in the harness, so neither gets "fixed" into the other.

### How the view half is put together

1. **`AppCore` holds a `TabList`** where it held one `TerminalCoordinator`, plus a
   `[PaneID: TerminalCoordinator]` map — the tree names panes, and the map is what turns a name into a
   session. `add()` and `split(_:in:_:)` return the `PaneID` to start a session for. Every command goes
   through `afterStructuralChange()`, which is the one place that stops the shells of closed panes,
   brings the active pane and the window's title up to date, and closes the window when no tab is left.
2. **The window hosts one `WorkspaceScreen`** and swaps nothing: a tab that is not showing has no
   surfaces in the hierarchy at all, so switching tabs is SwiftUI removing and adding panes rather than
   the window controller replacing a content view.
3. **The sidebar is the window.** Its surface is full-bleed and the tab list sits in its leading column;
   the terminal is everything to the right of that, rounded on its two *leading* corners — the corners
   that meet the sidebar, which is the whole of the "curving into" effect. There is no margin: an earlier
   version floated the panel clear of the window's edges, which read as a card lying on a desktop and,
   worse, kept a strip of sidebar visible even when the sidebar was hidden. An earlier version still had
   the two side by side, and one before that had a strip above the panes drawing the same tabs, which is
   what "doubled and duplicated" was.
4. **There is no top bar.** `.fullSizeContentView` with the title hidden, so the traffic lights float
   over the sidebar and the sidebar's own control is a glass button floating on the terminal. The path is
   not in the chrome at all: the sidebar is where you are.
5. **No view holds `@State`.** The selection, the chrome's numbers, where a drag started and the rename
   draft are all `AppCore`'s. Two reasons: a copy of something the model knows is the defect class this
   project keeps meeting, and `@State` is a macro the whole-app typecheck cannot expand — nor strip,
   because the `$`-projections stop existing — so a view using one drops out of the only automated gate
   the view layer has.
6. **The panel's geometry exists once.** `ChromeSettings.contentPanelFrame` is used by the layout *and*
   by `AppCore` to decide what size to tell the shell, and it is pure and harnessed. Two expressions of
   that arithmetic is how a pane comes to be drawn at one width and told another.
7. **The chrome's numbers are settings, not tokens.** Width, margin and glass opacity live in
   `ChromeSettings` with the range each is clamped to, editable from a popover in the sidebar's header.
   They are not in `Theme` because a value with a range is a decision with two ends that have to agree.
8. **Focus is claimed by the surface, from the model's answer.** `TerminalSurfaceView` takes the keyboard
   when it *arrives in a window* and its coordinator says it is the active pane; the rename field does the
   same. Nothing reacts to shell output, which is what makes this different from the "focus that moved
   under the user's hands" defect in `journal.md`.

### What is left of 4b

- **Split dividers, and dragging one.** The gap between panes is the divider — the panes do not touch and
  the window's backdrop shows through — so there is nothing to draw. Dragging needs the flex weights that
  were deliberately left out of `PaneBranch`, and they should arrive with a `PaneLayout` that reads them
  rather than being stored before anything writes to them.
- **Pane rows in the sidebar.** It lists tabs only, so the panes of a split are reachable by
  `⌘⌥[` / `⌘⌥]` and not by clicking. A pane row would need the list's selection to hold two kinds of
  identity, which is a design decision rather than a row.
- **A settings window.** What exists is the chrome's own numbers in a popover. The hierarchy
  `tinycast_architecture_and_rules.md` §7 specifies is still unbuilt, and it is still what blocks the
  directory-colour picker from `phase-4-todo.md` — so the popover is the first tenant of a house that
  does not exist yet, not a substitute for it.
- **The animation's cost.** Hiding the sidebar animates the panel's width, which means the pty is told a
  new size on each frame of the slide. If that reads as a flicker in practice, the fix is to animate the
  sidebar alone and let the panel snap — the sidebar arrives over exactly the region the panel gives up,
  so the snap is hidden. Recorded here because it is a rendering decision that has to be *seen*.
