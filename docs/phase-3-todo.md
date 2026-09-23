# Phase 3 — Todo

The working checklist for Phase 3. Ticked against a real run.

**State: the model half is built and verified; the editor is LIVE — wired into `TerminalSurfaceView`,
typed into, and carrying ↑/↓ history, `⌘A`/`⌘X` and the completion popover; syntax highlighting and the
not-found squiggle are still to come.**

This paragraph said the editor was PARKED for several sessions after it stopped being true. The code
comment in `CommandEditorView` said "live, wired into `TerminalSurfaceView`" the whole time, and the two
disagreed — which is the failure mode this project keeps paying for. If you find this file disagreeing with
the code again, believe the code and fix this file.

A tick below means the code exists. The editor items are all ticked **and reachable** now.

## The editor — `app/src/terminal/view/` — written, then parked
- [x] `CommandEditorView` — an `NSTextView` subclass, configured from `TerminalFont`
- [x] The text container's line height is the cell height, so a column is a column
- [x] `↩` submits; `⇧↩` inserts a newline
- [x] `Ctrl-C`, `Ctrl-D`, `Ctrl-Z` and `Ctrl-R` are forwarded to the pty rather than handled
- [x] `Ctrl-R` and `Tab` are *not* the shell's any more — the editor owns them
- [x] Smart quotes, smart dashes, smart links, spell checking and automatic substitution are off
- [x] Undo/redo works without a single line of undo code
- [x] Mouse positioning, drag selection and word movement work without a line of code
- [x] `⌘↑`/`⌘↓`/`⌘Home`/`⌘End` are handed back to the surface, so block jumping survives the editor
- [x] The editor's frame comes from `HeaderGrid.promptEnd`, and the surface's cursor stays out of the
      way because the surface is no longer the first responder while a prompt is showing
- [x] The editor is absent on a submitted block and while a full-screen program owns the keyboard
- [x] The document leaves room for the editor's extra lines, and the renderer is handed the *same*
      layout the view built rather than building a second one

## Submitting
- [x] `CommandSubmission` encodes a buffer as `" " VT NAK <buffer> \r`
- [x] Newlines become line continuations, so a multi-line buffer arrives as one command
- [x] The buffer reaches the pty through the same `TerminalSession.write` everything else uses
- [x] The editor resets on submit, and the block's lifecycle is untouched by any of this

## The tokenizer — `crates/warp_terminal/src/model/`
- [x] `ShellTokenizer` — flat, non-overlapping `(range, kind)` spans
- [x] Quoting rules: single, double, escaped, unterminated
- [x] Operators: `|`, `||`, `&&`, `;`, `&`, `(`, `)`
- [x] Redirections: `>`, `>>`, `<`, `2>`, `2>&1`, `&>`
- [x] Command position after every control operator, so a pipeline colours two commands
- [x] A heredoc body is not tokenised as shell: the body and its terminator are one string, `<<-` and
      a quoted terminator both work, and a terminator the shell would expand is deliberately *not*
      guessed at — colouring the body as shell beats swallowing the rest of the buffer

## Command resolution
- [x] `CommandResolver` — three-valued, because aliases are not captured by the bootstrap yet
- [x] Builtins and reserved words, checked before the glob-character check so `[` answers
- [x] Every command in the line is checked, not just the first
- [x] `~/` is expanded; `~someone` is reported as indeterminate rather than guessed at
- [x] A file that is there but not executable is `notFound`, which is a different answer from a typo

## Completion — `crates/warp_terminal/src/model/`
- [x] `CompletionCandidate`, `DirectoryEntry`, `CommandSignature`
- [x] Signature table for a dozen commands, as data
- [x] History source, newest first
- [x] Path source, with the directory part kept in the answer and directories marked
- [x] Flag and subcommand sources from the signature
- [x] Ranking: prefix matches first, the rest after, deduplicated
- [x] Ghost text from history, only with the cursor at the end of the line
- [x] The engine is pure — the directory listing is a closure, so a harness drives it with a dictionary
- [ ] Native shell completion generators — **not built**, and not planned until the first three have
      been lived with

## Ghost text and the popover
- [x] Ghost text: the best history candidate, drawn dimmed after the caret
- [x] `Tab` accepts it, and so does `→` — but `→` only at the end of the line, because anywhere else
      the arrow is how you move the caret and the two have to be told apart
- [x] `esc` dismisses it
- [x] The suggestion follows what is typed, not just what the shell prints
- [x] The popover: a filtered table of candidates with descriptions, on `NSGlassEffectView`
- [x] `Tab` opens it; `Tab` / `↓` / `↑` move, `↩` accepts, `esc` closes, any other key closes and is
      handled as itself — and `Tab` with nothing to offer still goes to the shell
- [x] ↑/↓ walk the commands already run, with the draft handed back on the way down
      (`HistoryNavigation`, pure and harnessed)
- [x] `⌘A` selects the current block's line and `⌘X` cuts it, through `NSText`'s own selectors — the
      Edit menu carries both now; a key equivalent with no menu item behind it is never matched
- [x] The editor's default context menu is suppressed: it was `NSTextView`'s, with Substitutions,
      Autofill and Services on it, none of which mean anything for a shell command
- [x] Syntax highlighting from the tokenizer: commands bold, flags, strings, variables, redirects and
      comments in palette slots, debounced so a colour lands a frame late rather than mid-keystroke
- [x] An unknown command is drawn with a red dashed underline — and *not* while the caret is inside it,
      because every prefix of a real command is unknown and complaining would flash red on the way to
      `git`
- [x] A new text size moves the editor's font and its line height together, or the caret would stop
      lining up with the grid behind it

## Carried in from Phase 2
- [x] Clicking anywhere in a block selects it, not just the header
- [x] A selected block is drawn with a subtle tint across the whole block — no border
- [x] Every block action is greyed until a block is selected

## Gates
- [x] `Tests/shell-tokenizer-test.swift` — 58 checks
- [x] `Tests/command-resolver-test.swift` — 25 checks
- [x] `Tests/completion-test.swift` — 26 checks
- [x] `Tests/editor-submit-test.swift` — 12 checks, the `" " VT NAK` prefix pinned
- [x] `./Scripts/run-tests.sh` passes 100% — 12 harnesses, 422 checks
- [ ] `swift build -c release` clean with zero warnings — **not verified here**; see below
- [x] `./Scripts/lint.sh` passes
- [x] Pure-model grep returns zero files
- [x] Every `index.md` current
- [ ] Installed and running, with `vim`, `Ctrl-C`, `Ctrl-R` and paste all still working — **not run**

### The launch crash, and why it was not caught here

The first build of this phase crashed on launch, before a window appeared:

```
CommandEditorView.init(frame:textContainer:) + 32 [inlined]
AppKit  -[NSTextView _initWithFrame:usingTextLayoutManager:]
SwiftTerm  specialized CommandEditorView.init(font:palette:resolver:)
```

`NSTextView`'s designated initializer is `init(frame:textContainer:)`; its `init(frame:)` is a
convenience path that re-dispatches to `self.init(frame:textContainer:)`. A subclass that declares a
designated initializer of its own gets an *unimplemented* stub emitted for the inherited one, so that
re-dispatch landed on the stub and trapped. Fixed by calling the designated initializer on `super`:
`super.init(frame: .zero, textContainer: nil)`. Written up in `learnings.md`.

### Then it was unusable, and the reason was two more of the same kind

With the crash gone the app ran but could not be typed into: the caret jumped away mid-keystroke, and
the screen filled with prompts and no output. Both causes were structural, and both are the same
mistake — a second thing keeping its own idea of a state that something else already owns.

1. **Focus was decided in a callback that fires on shell output.** The window controller gave the
   keyboard to the surface; the first keystroke went to the pty; the shell's echo came back; and
   *that* handed focus to the editor. So every keystroke before the switch was typed into the shell
   and every one after it went into a buffer — and each `↩` in between sent a bare newline, which is
   why the screen filled with prompts. Fixed with one property, `firstResponderView`, read by the
   window controller at launch and reconciled afterwards by a function that does nothing when the two
   already agree.
2. **The editor's frame was computed from callbacks.** Typing did not recompute it, scrolling did not
   move it, and the room the document had reserved for it no longer matched its height. Fixed by
   positioning it in `draw`, from the same layout the renderer just painted — which is the principle
   Warp's own input follows, since its element tree is laid out every frame from the model.

### Why neither the harnesses nor the typecheck saw any of it

The harnesses never compile the view layer, and a typecheck cannot see a runtime dispatch trap or a
callback that never fires. This is the gap `learnings.md` already names in plain sight — *"the
harnesses cover the model and the parser thoroughly and the view not at all"* — and it is the reason
the remaining work is the part that needs a running window.

**A lesson for the phases ahead:** the model layer has been reliable all along (422 checks, two bugs
found by them); the view layer has been wrong three times out of three. Anything that can be moved out
of the view and into a harness should be, and anything that cannot should be written against a
running window rather than ahead of one.

---

## Why the phase is half-built on purpose

Everything above that is ticked in the **model** layer is verified: 115 of the 416 checks are new
model code, and a harness caught a real bug on the way — `"\r\n"` is a single Swift `Character`, so
stripping trailing newlines by suffix never matched CRLF, and a buffer ending in one kept a line
continuation with nothing after it.

Everything above that is ticked in the **view** layer is typechecked and nothing more. The agent that
wrote it could not compile the app — `@Observable` needs `swift-plugin-server`, which needs
`sandbox-exec`, which this environment refuses — so the editor, its frame arithmetic and the focus
switching have never run.

That is why the remaining items are the *visible* ones: the popover, the squiggles and the
highlighting all need a running window to be worth writing, because they are entirely a matter of
where things land on screen. The pieces they need — `ShellTokenizer`, `CommandResolver`,
`CompletionEngine` — are done, tested, and waiting.

The three things to look at first when the app is built, in order of how likely they are to be wrong:

1. **The editor's frame.** It is placed from `promptEnd` and grows downward by its own line count, and
   the document reserves that room. If the arithmetic is off the editor will sit a row too high or too
   low, or overlap the block below it.
2. **Focus.** The keyboard follows the prompt: the editor has it while a prompt shows, the surface
   takes it back for a full-screen program. If that switch is wrong, typing goes nowhere or `vim`
   cannot be driven.
3. **The selected block's tint.** It is drawn before the block's content, so a cell with a background
   of its own still wins. If it reads as too strong or too faint, the number is `selectionTint`'s
   alpha in `TerminalRenderer` and nothing else.
