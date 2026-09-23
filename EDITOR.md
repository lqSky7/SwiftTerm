# EDITOR.md — Phase 3, the decoupled command editor

**This is the second handoff file.** `READ_ME.md` is the one for the project as a whole and you should read
it first; this one is for a single phase — Phase 3 — and it exists because that phase is the one piece of
this project that has already been attempted and abandoned once, and the next attempt deserves to start from
what the first one learned rather than from a blank page.

Read `AGENTS.md` and `docs/journal.md` before you write anything. This file assumes them.

---

## 1. The feature

The bottom input stops being a grid and becomes an editor. In full, from `docs/phases.md`:

> multi-line, mouse positioning, undo/redo, word jump, selections, real-time syntax highlighting,
> not-found-command squiggles, inline history ghost text, and an autocomplete popover fed by command
> signatures, paths and history.

**Exit criterion** (`docs/phase-3.md` §"Exit criterion"): type a command with the mouse mid-line, undo a
word, `⇧↩` a second line, accept a ghost-text completion, and submit — with the shell echoing nothing and
the block behaving exactly as it does now.

**Phase 3 is next.** The order is 1 → 2 → 2.5 → 2.6 → **3** → 4 → 5 → 6 → 7, and 4 (both halves) is built.

**One thing it fixes as a side effect.** `docs/phase-4-todo.md` carries an open defect — *"the prompt repeats
as the window is resized"* — and its note says the editor is the fix: the shell's line editor erases its old
prompt with cursor addressing, the reflow moves the cursor, and the erase lands somewhere else. An editor
that owns the input makes the shell's line editor irrelevant. So this phase removes a known bug, not just adds
a feature.

---

## 2. What is already built — the model half

All four are in `crates/warp_terminal/src/model/`, all pure, all harnessed, and **all four are compiled by
every harness in the suite** (they are inside the directory `Scripts/run-tests.sh` globs).

| File | Owns |
| --- | --- |
| `ShellTokenizer.swift` | a command line as flat, non-overlapping `(range, kind)` spans — command, argument, flag, string, variable, redirect, control, comment. Handles here-documents. |
| `CommandResolver.swift` | whether the first word could actually run. **Three-valued**: `found` / `notFound` / `indeterminate`, and only `notFound` earns an underline. |
| `Completion.swift` | candidates from history, paths and a signature table, plus the ghost text. Pure — no file system. |
| `CommandSubmission.swift` | the bytes a submitted buffer becomes. See §4. |

Their harnesses: `shell-tokenizer-test`, `command-resolver-test`, `completion-test`, `editor-submit-test`.

**`editor-submit-test` pins the three bytes of protocol.** If you change the submit path and that harness
still passes, you have not changed the protocol.

Two rules from the model's own `index.md` that will bite you if you ignore them:

- **The tokenizer is a scanner, not a parser.** Its output is a flat span list because that is what a text
  view applies attributes to. A subcommand is deliberately *not* one of its kinds — deciding that needs the
  signature table.
- **`CommandResolver` never guesses.** Do not "simplify" it to a bool. A two-valued check would have to guess
  about `$EDITOR` and `foo*`, and underlining a command that works teaches people to ignore the underline.

---

## 3. What exists in the view half, and what "parked" means

`app/src/terminal/view/CommandEditorView.swift` — an `NSTextView` subclass, complete, typechecked, and
**instantiated by nothing**. Its public surface:

```swift
init(font: TerminalFont, palette: TerminalPalette, resolver: CommandResolver)

var onSubmit: ((String) -> Void)?          // ↩ — hand the buffer to whoever submits it
var onRawBytes: (([UInt8]) -> Void)?       // a key the editor does not want, straight to the pty
var onUnhandledTab: (() -> Void)?          // Tab when there is nothing to complete — the shell's job
var onNavigationKey: ((NSEvent) -> Bool)?  // ⌘↑ / ⌘↓ and friends; return true if handled
var onBufferChanged: (() -> Void)?         // the buffer moved, so the layout may need to
var ghostText: String?                     // set by the caller; drawn behind the caret
var lineCount: Int                         // how many lines the buffer needs — §6, thing 3
func reset()                               // clear, after a submit
func update(font: TerminalFont)            // a font-size change
```

Parked means: it compiles, it is in the typecheck, and **nothing creates it**. The terminal is a working
terminal without it, and `journal.md`'s judgement stands — a working terminal matters more than a
half-working editor.

---

## 4. The protocol, and why nothing is disabled

Warp's `clear_line_editor_and_write_to_pty` (`app/src/terminal/view.rs:9964`). On submit, the pty receives:

```
" "   VT(0x0B)   NAK(0x15)   <the whole buffer>   "\r"
      Ctrl-K     Ctrl-U
```

- **The leading space** exists so Ctrl-U always has one character to delete. Without it the shell rings the
  bell on every command.
- **Ctrl-K clears forward, Ctrl-U clears backward** — together they empty the shell's line editor of whatever
  it last held, so the buffer that arrives is the whole line rather than a suffix of one.
- **Not Ctrl-C**: it would clear the line *and* cancel whatever is running.
- **The shell's line editor is never disabled.** It is wiped, every time, immediately before the buffer
  arrives. That is the whole trick, and it is why nothing has to be kept in sync with it.
- **`Ctrl-C` and `Ctrl-D` stay the shell's.** They are signals, not editing.

`CommandSubmission.bytes(for:)` is this, already written and tested. Multi-line buffers are escaped as line
continuations (`\` + newline) so the shell sees one continued line, and **line endings are normalised before
trailing newlines are stripped** — `"\r\n"` is a *single* `Character` in Swift, so the other order silently
never matches the CRLF case. That bug was found by a harness; do not undo it.

---

## 5. Where the editor sits

`HeaderGrid` already records the point the prompt ends at — `133 ; B` — as
`HeaderGrid.PromptEnd { line: Int, column: Int }`. That is why Phase 2.5 recorded it.

The editor's frame comes from there: the prompt occupies its own grid, the editor is an `NSTextView` overlaid
from `promptEnd` to the end of the block's prompt region, and its text container is sized from
`TerminalFont`'s cell metrics so a column is a column.

**A block that has been submitted shows no editor.** There is nothing to edit about a command that has run.

---

## 6. The three things re-enabling needs

Quoted from the file's own doc comment, because it is the shortest correct statement of the work:

1. **A `CommandEditorView` subview of `TerminalSurfaceView`, positioned in `draw` from the same `BlockLayout`
   the renderer is handed** — never from a callback, or it goes stale the first time the document moves
   without telling it.
2. **One place that decides who has the keyboard**: the editor while a prompt is showing (which is also what
   suppresses the grid's cursor, since the renderer only draws one when the surface is the first responder),
   the surface otherwise. It must not be re-asserted on shell output.
3. **The block being edited has to be tall enough for the buffer**, which means folding the editor's
   `lineCount` into that block's contribution to the layout.

---

## 7. The seams, exactly

### The layout

`TerminalSurfaceView.layout` (`TerminalSurfaceView.swift:198`) is the one place the document geometry is
built, and the renderer is handed the same value:

```swift
private var layout: BlockLayout {
    BlockLayout(
        contributions: session.blockGeometry,
        chipRow: chipRow,
        headerHeight: …, lineHeight: …)
}
```

and the contributions come from `TerminalSession.blockGeometry` (`TerminalSession.swift:160`):

```swift
var blockGeometry: [(lineCount: Int, hasHeader: Bool)] {
    blocks.map { ($0.lineCount, $0.isSubmitted) }
}
```

**This is thing 3.** The editor's line count has to be folded in for the block being edited — the
contributions are not quite `session.blockGeometry` any more once an editor is on screen. `BlockLayout.Entry`
carries `headerTop`, `headerHeight`, `chipTop`, `chipHeight`, `contentTop`, `contentLineCount`,
`contentHeight` and a `bottom`; a caller that ignores chips is still right, by design.

### Sending bytes

`TerminalSurfaceView.send(_ bytes: [UInt8])` (`:362`) is the one door to the pty. `translatedBytes(for:)`
(`:389`) is the keyboard translation, and `controlSequence(for:isOption:)` (`:421`) is where Ctrl chords are
turned into bytes — **the editor's `onRawBytes` should end up here, not in a second translator.**

### Focus

`TerminalSurfaceView.claimFocusIfActive()` (`:82`) is the current rule: a surface takes the keyboard when it
*arrives in a window* and its coordinator says it is the active pane. `TerminalCoordinator.isActive` is
written by `AppCore.syncActivePane()`.

**Nothing in this app moves focus in response to shell output.** That is deliberate and it is the fix for bug
2 below. If your editor needs the keyboard back after a submit, ask `AppCore` for it — do not react to a
session event.

### Paste, font, and the menu

`insertPastedText(_:)` (`:539`), `setPointSize(_:)` (`:101`) and the `@objc` menu actions at `:489` are the
existing surface API. Bracketed paste (mode `2004`) is already handled in `TerminalModes`.

---

## 8. Why it was parked — read this twice

Four failures, all of them invisible to a harness *and* to a typecheck, and all of them found by a person
with a window open. The full accounts are in `docs/journal.md` §"The view layer has been wrong every time it
was written" and `docs/learnings.md`.

1. **A launch trap.** `super.init(frame: .zero)` in an `NSTextView` subclass. `NSTextView`'s designated
   initializer is `init(frame:textContainer:)`; `init(frame:)` re-dispatches through `self`, and a subclass
   with its own designated initializer gets an *unimplemented* stub for the inherited one — so re-dispatch
   lands on the stub and traps at launch. **Call the designated initializer on `super`.**
2. **Focus that moved under the user's hands.** The window gave the keyboard to the surface; the first
   keystroke went to the pty; the echo came back; and *that* handed focus to the editor mid-keystroke. Every
   `↩` in between sent a bare newline, which is why the screen filled with prompts and no output. **Never
   move focus from anything that fires on shell output.**
3. **A frame computed from callbacks**, so typing did not move it and scrolling did not carry it. **Compute
   it in `draw` from the layout**, which is thing 1 above.
4. **A cursor that disappeared.** Moving focus to the editor suppressed the grid's cursor — correctly, since
   the renderer only draws one when the surface is the first responder — and the editor's own caret was not
   appearing, so there was nothing at all. **Both halves of the focus switch have to work, or the user sees
   no cursor anywhere.**

The generalisation, which is the most useful thing in this file: **the model layer has been reliable because
harnesses hold it; the view layer has never been right the first time.** Move what can be moved into the
model, and for what cannot, write it against a running window rather than ahead of one.

---

## 9. The plan: four increments, each separately testable

Do not do these in one turn. Each ends with a build and a run by the human.

**Increment 1 — the editor exists, and nothing else.**
Create it as a subview of `TerminalSurfaceView`, position it in `draw` from the layout, fold `lineCount` into
the block's contribution, wire `onSubmit` to `CommandSubmission.bytes(for:)` through `send(_:)`, and make the
focus switch. **No highlighting, no ghost text, no squiggles, no popover.** This isolates the three things in
§6, which are the three things that have failed before.

What to check when it runs: does the editor sit exactly where the prompt's command begins; does typing land
in it; does `↩` run the command with the shell echoing nothing; does `vim` still get the keyboard; is there a
cursor at all times.

**Increment 2 — highlighting.** `ShellTokenizer` is done; apply its spans as attributes. Nothing else.

**Increment 3 — the not-found squiggle.** `CommandResolver` is done; underline only `notFound`.

**Increment 4 — ghost text and the popover.** `Completion` is done. Ghost text first (it is one string), the
popover second (it is a view).

---

## 10. Rules that apply to this work specifically

- **Views in this app hold no `@State`.** `@State` and `@FocusState` are macros and the whole-app typecheck
  cannot expand them — nor strip them, because the `$`-projections stop existing. A view that uses one drops
  out of the only automated gate the view layer has. Put the state on `AppCore` instead; that is what
  `hoveredTab`, `settingsSearch`, the rename draft and the drag origins are. **`@Environment` is a property
  wrapper, not a macro, so it is fine.**
- **The editor is an AppKit view owned by the feature**, like `TerminalSurfaceView` — created once by the
  coordinator, handed to SwiftUI only to be placed. Do not try to build it in SwiftUI.
- **`Theme` tokens for every number.** A view that invents its own padding is how a design system rots.
- **`Theme.Colors.ramp` is for ink, never for a scrim** — it returns *white* on dark, so a "dark scrim" built
  from it lightens dark mode. Use `Theme.Colors.settingsSurface` as the model for the other direction.
- **A tap gesture on a `Button` competes with the button's own** — `.simultaneousGesture(TapGesture(count: 2))`
  is the spelling that works.
- **`Rect`/`Color` in a `.background` takes hits.** A full-window layer that swallows events is a window where
  nothing responds; say `.allowsHitTesting(false)`.
- **Ponytail first** (`~/.workbuddy-ai/skills/ponytail/`): does it need to exist, is it already here, does a
  native API already do it. The `NSTextView` decision in §1 *is* that ladder applied.
- **Update the docs in the same change** — `docs/phase-3-todo.md`, the relevant `index.md`, and
  `docs/audit-phase-1-2.md` if you close a finding. Gate 5.
- **Do not start increment 2 in the same turn as increment 1.** A phase ends with a build and a run by the
  human.

---

## 11. Environment — the same traps as `READ_ME.md` §6

- **`swift build` cannot run in the agent's environment.** `@Observable` is a macro, expanding it needs
  `swift-plugin-server`, which needs `sandbox-exec`, which is refused. The app has only ever been compiled by
  the person running it. **That is the root of everything in §8.**
- **`swiftc -typecheck` does work**, if you strip `@Observable` and `@ObservationIgnored` from a copy first:

  ```bash
  T="${TMPDIR:-/tmp}/swiftterm-typecheck"
  rm -rf "$T" && mkdir -p "$T" && cp -R app crates "$T"/
  perl -pi -e 's/\@Observable//g; s/\@ObservationIgnored //g' $(find "$T" -name '*.swift')
  swiftc -typecheck -swift-version 6 $(find "$T/app/src" "$T/crates" -name '*.swift' | sort)
  ```

  It catches every wrong name and signature. It does **not** catch a dispatch trap, a callback that never
  fires, or a caret that is not drawn.
- **`git` does not work in this directory.** `sed -i ''` is a toybox shim — use `perl -pi -e`. Bash `grep` is
  unreliable here; prefer the dedicated search tooling.
- The machine is macOS 27 / Xcode-beta / Swift 6.4. Liquid Glass is macOS 26+ and lives in **SwiftUICore**,
  re-exported by SwiftUI: `Glass.regular` / `.clear` / `.identity`, `.glassEffect(_:in:)`.

### Gates — all three, before you say you are done

```bash
./Scripts/run-tests.sh     # 18 harnesses, 888 checks, all must pass
./Scripts/lint.sh          # swiftlint + the pure-model grep gate
# and the typecheck above — exit 0, zero warnings
```

A harness that stops compiling means a decision leaked out of a pure layer. **If you add a new pure model
file, add it to `Scripts/run-tests.sh`'s `SOURCES` and to `Scripts/lint.sh`'s `PURE_PATHS`** — both name
files individually rather than globbing, because a glob would let a UI framework into the harnesses.

---

## 12. Read next, in this order

| | Why |
| --- | --- |
| `docs/phase-3.md` | the plan in full: the `NSTextView` decision, the protocol, the frame, completion's three sources, why tree-sitter is not used |
| `docs/phase-3-todo.md` | the checklist, and "Why the phase is half-built on purpose" |
| `docs/journal.md` §"The view layer has been wrong every time it was written" | §8 of this file, in the original |
| `docs/learnings.md` | the `NSTextView` trap, the stale frame, the focus switch — as rules |
| `app/src/terminal/view/index.md` | the two seams: the layout is built once and handed to the renderer; focus follows the prompt |
| `crates/warp_terminal/src/model/index.md` §"The command line" | the four model files and the two rules that will bite you |
| `app/src/terminal/view/TerminalSurfaceView.swift` | the file you will be editing |

The last thing, and it is the thing this file exists to say: **the person testing this is the only one who
can see it.** Every one of the four failures in §8 was invisible from where the code was written. Write the
smallest thing that could work, say what you expect to see, and let them tell you what actually happened.
