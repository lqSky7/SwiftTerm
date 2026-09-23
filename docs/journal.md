# Journal

What was attempted, what broke, and why the tree looks the way it does.

`learnings.md` holds the technical gotchas as rules. `phase-N.md` holds the plan for a phase and
`phase-N-todo.md` the checklist. This file is the one that is missing from those three: the narrative.
Read it before you change something and wonder why it is like that.

---

## Where things stand

| | |
| --- | --- |
| Working | Phase 1 (a live shell), Phase 2 (command blocks), Phase 2.5 (a grid per block) |
| Parked | Phase 3's editor — `CommandEditorView` exists, compiles, and **nothing instantiates it** |
| Built and tested, unused by the app | `ShellTokenizer`, `CommandResolver`, `Completion`, `CommandSubmission` |
| Gates | 12 harnesses, 422 checks, lint clean, `swiftc -typecheck` clean |

The terminal works. It is a terminal with blocks, per-block grids, headers, selection and a
right-click menu. What it does not have is an editor: the shell still echoes what you type, and the
cursor is still the grid's.

## The rule that was added to `AGENTS.md`

> Don't reinvent the wheel. Keep it as Warp does it, unless stated otherwise in `warp_features.md` —
> and implement only the features that file lists. **A divergence is allowed only where a phase doc
> records it and why.**

That last clause is load-bearing. Without it the rule contradicts a shipped decision — `phase-2.md`
§1 deliberately shared one grid between blocks, which `warp_features.md` #1 says not to — and the next
agent "fixes" it. With it, a divergence has a legal home and a reason attached.

## The five places this deliberately differs from Warp

Each one is recorded where it lives, as the rule requires.

| Divergence | Why |
| --- | --- |
| `grid_handler.rs` is not ported | `TerminalGrid` already *is* it. Re-translating our own emulator into a worse one is the real reinvention. |
| `HeaderGrid` holds one grid, not Warp's two | What the split is *for* is knowing where the prompt ends, which is one point. A second grid nothing writes to would drift. |
| `NSTextView` instead of porting `crates/editor` + `crates/vim` | Warp's editor exists because it is cross-platform and GPU-drawn. This app is macOS-only with AppKit, where undo, selections, word movement and IME are free. |
| A hand-rolled shell tokenizer instead of tree-sitter | Tree-sitter from Swift means FFI plus a vendored C grammar, for a grammar that is a few hundred lines of scanner. |
| No native shell completion generators | Warp spawns a subshell per completion. That is a second pty and a protocol of its own; it earns a phase after the three cheap sources have been lived with. |

## Things the plan did not cover

Both of these were found by asking "is this planned?", not by reading the plan — which is the point.

**Text-level selection is assigned to no phase.** `phase-2.md` §6 says "text-level selection is a
separate job and is not in this phase" and never says which one. `phases.md` Phase 5 has "full mouse
reporting", but that means forwarding mouse events *to the program running in the terminal*, which is
a different feature. So dragging to select output has no home, and neither does clicking into a block's
body once selection exists. Worth assigning before Phase 5 arrives.

**Block chrome was assigned to no phase either** — the rule that separates one block from the next, and
the horizontal margin that keeps a block's text off its own edges. It has now been named in Phase 4,
where it belongs, with Warp's implementation recorded there (`draw_border_between_blocks`, coloured
with `theme.outline()`, gated on `terminal_spacing.block_borders_enabled`).

What exists today is the block **header** from Phase 2, which is what tells blocks apart once something
has run — and it does. An empty terminal with one unsubmitted block correctly shows no header, because
there is no command to say anything about. The rule between blocks and the margin are the refinement on
top of that, and they are Phase 4.

**The selection indicator is a tint, not a border.** It was built as Warp's 2pt border first
(`SelectionBorderWidth`) and changed on request. Worth recording because Warp has both: its
`MinimalistUI` flag zeroes those border widths to `0.0`. So the tint is a mode Warp ships, not a
departure from it — and it avoids the border clipping the first column of a full-width block.

---

## The view layer has been wrong every time it was written

This is the single most useful thing in this file.

| | Model layer | View layer |
| --- | --- | --- |
| Bugs found by the harnesses | 2 | — |
| Bugs found by the user | 0 | 4 |
| Checks guarding it | 422 | 0 |

The four, in order:

1. **A launch trap.** `super.init(frame: .zero)` in an `NSTextView` subclass. `NSTextView`'s
   designated initializer is `init(frame:textContainer:)`; `init(frame:)` re-dispatches to it through
   `self`, and a subclass with its own designated initializer gets an *unimplemented* stub for the
   inherited one. Fix: call the designated initializer on `super`. (See `learnings.md`.)
2. **Focus that moved under the user's hands.** The window gave the keyboard to the surface; the first
   keystroke went to the pty; the echo came back; and *that* handed focus to the editor mid-keystroke.
   Every `↩` in between sent a bare newline, which is why the screen filled with prompts and no output.
3. **A frame computed from callbacks**, so typing did not move it and scrolling did not carry it.
4. **A cursor that disappeared.** Moving focus to the editor suppressed the grid's cursor — correctly,
   since the renderer only draws one when the surface is the first responder — and the editor's own
   caret was not appearing, so there was nothing at all.

None of these is visible to a harness (which never compiles the view layer) or to a typecheck (which
cannot see a runtime dispatch trap, a callback that never fires, or a caret that is not drawn).

**So the working rule for the phases ahead:** move what can be moved out of the view and into the
model, where a harness can hold it. `BlockLayout`, `ShellTokenizer`, `CommandResolver`, `Completion`
and `CommandSubmission` all exist because of that. And for what cannot be moved, write it against a
running window rather than ahead of one.

## Three ways a defect has hidden here, all of them documentation

Worth knowing, because none of them was found by reading the code.

1. **A ticked box that was never true.** Phase 1 planned `TerminalLine` as "cells + soft-wrap flag" and
   ticked it. The flag was built and the re-wrapping it existed for never was — so for five phases a
   narrower window destroyed the right-hand side of every line. The tick was accurate about the flag and
   wrong about the feature, which is the worst kind of accurate. `phases.md` Phase 2.6 exists for it.
2. **A document that asserted the missing thing worked.** Three of them did, in this case:
   `phase-2.5.md`, the model's `index.md`, and a manual test in `phase-2.5-todo.md` that read "old
   blocks re-wrap to the new width" and passed. A test written from the same belief as the code proves
   the belief, not the behaviour — which is the lesson `learnings.md` already records from Phase 2's
   block boundaries. It happened again here.
3. **A warning nobody read.** A stray non-Swift file in a `sources:` directory made SwiftPM warn twice
   on every build. `learnings.md` said such files warn rather than error, which is true and is exactly
   why it shipped: a warning is a gate violation that nobody is looking for.

The common shape: **a claim about the system that was never checked against the system.** The harnesses
are the answer to it, and the reason the model layer has been reliable — they check the claim. Where
they cannot reach, the claim has to be checked by running the thing, and that has to be done by a person
with a window open.

## Why the editor is parked rather than finished

It was written ahead of a running window, and it was wrong three times out of three. A working
terminal matters more than a half-working editor, so the editor was unwired and the terminal put back
the way Phase 2.5 left it. `CommandEditorView.swift` carries the three things re-enabling it needs, and
nothing about the design is wasted — the model half is done, tested and waiting.

## Environment

Three things about the machine this was built on, all in `learnings.md` with more detail:

- **`swift build` does not work here.** `@Observable` is a macro, expanding it needs
  `swift-plugin-server`, and that needs `sandbox-exec`, which is refused. So the app has only ever been
  compiled by the person running it, and the view layer has only ever been *typechecked* by the agent
  writing it. That asymmetry is the root of everything above.
- **`git` does not work in this directory.** Every git command unlinks a `*.lock` path and that is
  denied, so `git init` fails. There is a copy of the tree from before Phase 2.5 at
  `../backup/swiftTerm-phase2/` in the working directory it was made from; a plain `git init` from
  Terminal.app should work fine.
- **`sed` on `PATH` is a toybox shim**, so `sed -i ''` fails. Use `perl -pi -e`.

## A dated log

**Phase 1 — live shell.** PTY, VT emulation, scrollback, keyboard, resize, OSC 133. The bug worth
remembering was a row cache keyed by *view row*: a history line carried no generation stamp, so the
cache hit on `0 == 0` and redrew the previous viewport. Symptom was "scrolling doesn't feel like
scrolling". Fixed by keying on what actually identifies the row.

**Phase 2 — command blocks.** Blocks as line ranges over one shared `TerminalGrid`. The bug was a
block sealed by a marker that meant nothing: zsh's first `precmd` reports the *rc files'* exit status,
so the real stream is `A B D A B C D A B`, and the first `D` sealed the block about to hold the user's
first command. Its range came out `3..<3`. Fixed with two guards; both are gone now, replaced by a
property of the type.

**Phase 2.5 — a grid per block.** The `AGENTS.md` rule was added, and Phase 2's divergence was
reopened and reversed: every block owns its own `HeaderGrid` and `BlockGrid`, `BlockList.shift(by:)`
and `TerminalGrid.trimmedLineCount` were deleted, and the bound moved from a shared scrollback to a
block cap. Verified by the user, then by a manual test script now at the end of `phase-2.5-todo.md`.

**Phase 3 — the editor.** Planned in `phase-3.md`. The model half was built and verified: tokenizer
(with here-documents), command resolution, completion, and the pty submit encoding — the last of which
is three bytes of protocol from Warp, `" "` + Ctrl-K + Ctrl-U, where the space exists so Ctrl-U has
something to delete and the shell does not bell on every command. The view half broke the app four
times and is parked.

**Phase 4a — context and chrome.** Block separators and the context chips. `phase-4.md` split Phase 4
in two: chips, git detection, colour tagging and block chrome are additive; the sidebar, tabs and
panes need the app to hold more than one session, which it cannot, so they are 4b.

The chips are where the "native gives me advantage" case finally paid off. Warp's `precmd` hex-encodes
the git branch and ships it over a DCS channel because its hooks run in a process it does not control;
here the branch is the contents of `.git/HEAD`, so `RepoMetadata` reads the file. No process spawn per
prompt, and — the part that matters more — a harness can test it against a temporary directory instead
of a real repository. 46 checks, and they found nothing, which is the first time in this project that
has happened on the first run.

Two traps the harness pins down because both look right until they are not: a path prefix is not a
string prefix (`/Users/me/work` must not cover `/Users/me/workshop`), and a worktree's `.git` is a
*file* pointing at the real directory rather than a directory.

Also removed a stray `XXoWyLMh` — a leftover copy of `ShellTokenizer.swift` sitting in a `sources:`
directory, which SwiftPM warned about twice and which nothing would have caught but a person reading
the build log. `learnings.md` already says non-Swift files there are warnings rather than errors; what
it did not say is that a warning is a gate violation that ships quietly.

### What the first build of 4a got wrong, and what that says

Four rounds of feedback, all of it about *chrome* and none of it about the model:

1. **A rule at the top of an empty terminal.** zsh emits `A B D A B` at startup, so there are two
   blocks and the first is empty. `blockIndex > 0` was the wrong test for "is there anything above
   this"; `headerTop > 0` is the right one.
2. **The directory in two places.** Put in the header, taken out of the header, put back. The header is
   a record of where a command *ran* and stays right for an old block; a chip can only say where you
   are now. The chips are branch and environment only, and an empty list is what stops the row being
   reserved at all.
3. **The header painting its own background.** It was a strip tinted 7% toward the ink, and at 26pt it
   reached past its own row into the chips below it — so it was both a second signal for what the rule
   already said and the cause of a strip appearing where no strip belonged. Gone: dim text, the dot and
   the rule, which is what Warp's header is.
4. **The command in a colour of its own.** Same dim ink as the metadata beside it now.

The pattern is worth naming: every one of these was *visible only when run*, and three of the four were
about a rectangle of colour. The model layer — the branch reading, the path matching, the chip row's
arithmetic — has been right every time, and its harnesses found the one real bug it had. **Chrome
cannot be reasoned into place from here; it has to be looked at.**

**Next.** The `OSC 9282` channel for the facts only the shell knows, clicking a chip, and then 4b —
which starts with `AppCore` learning to hold more than one session.

### The format, and the audit

Two more rounds of "make it exactly like Warp", plus an audit of the two phases built before this one.

**The format.** Warp's terminal is a chip row above the input, and the input at the left margin — there
is no `user@host %` in front of a command. That last part is the one that matters most and the one this
project had wrong from the start: the shell's own prompt was in front of every command, so a block read
as a transcript rather than as a command and its output. The integration now empties `PROMPT`, `PS1` and
`fish_prompt`, and the directory — which used to be the whole reason for the prompt — arrives over
`OSC 7` and is the first chip. `ShellBootstrap` says why in one line, because a future reader will
otherwise assume the prompt was forgotten.

**The audit** (`audit-phase-1-2.md`) checked every ticked box in Phases 1 and 2 against the code, on the
theory that if one tick could be false then others could. Twelve findings. Four are fixed: bracketed
paste was **never turned on** (`case 2004` was missing from the mode switch, so a pasted script ran line
by line while a comment claimed a protection that did not exist), `DECSCUSR 0` stopped the cursor
blinking, the selection tint stopped at the content instead of covering the header, and a second stray
temp file was sitting in `Tests/`. Eight are open and written down with their fixes.

The shape of what the audit found is worth keeping: **modes that are parsed and then never consulted,
and documentation that outran the code.** Both are the same failure as the `isWrapped` tick.

**The reflow** (`phase-2.6-todo.md`) is built. It was the audit's reason for existing, it is the one
defect here that destroyed a user's output, and it is now 38 harness checks — three of which caught
mistakes in the reflow itself, including one where the *old* resize test had been asserting the buggy
behaviour as correct since Phase 1.
