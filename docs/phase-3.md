# Phase 3 — Decoupled Command Editor

**Goal.** The bottom of the terminal stops being a grid the shell echoes into and becomes an editor
this app owns. Typing behaves like typing in Xcode rather than like typing into a pty: the cursor goes
where the mouse puts it, a command can span lines, undo works, words move by `⌥←`/`⌥→`, selections
exist, the command is coloured as shell syntax while it is being typed, a command that is not on
`PATH` is underlined before it is run, the rest of the last matching command sits greyed out after the
cursor, and `Tab` offers the command, the flag or the path.

**Not in this phase.** No Vim modal editing (`warp_features.md` #2 mentions it; it is a phase of its
own, not a checkbox). No argument "word pills" (#39). No chips or sidebar (Phase 4). No themes
(Phase 5). No AI or agent anything. No native shell completion generators — see §5.

**Exit criterion.** Type a command with the mouse mid-line, undo a word, `⇧↩` a second line, accept a
ghost-text completion with `→`, `Tab` through a popover of flags and paths, see a mistyped command
underlined in red, press `↩`, and watch it run as a block with the header it already has. `vim` still
works, `Ctrl-C` still cancels, `Ctrl-R` still reaches the shell.

---

## 1. The decision that shapes it: an `NSTextView`, not a hand-written editor

Warp wrote its own editor (`crates/editor`, `crates/vim`) because it has to run on three platforms and
draw on its own GPU renderer. Neither reason applies here: this app is macOS-only and its UI is AppKit.

So the editor is an `NSTextView` subclass. That is not a shortcut around the work, it is the work
done once by someone else — and it is where the following come from, for free and correctly:

| Wanted | Where it comes from |
| --- | --- |
| Undo / redo (`⌘Z`, `⇧⌘Z`) | `NSUndoManager`, already wired into `NSTextView` |
| Mouse positioning, drag selection | `NSTextView` |
| Word movement (`⌥←` / `⌥→`) | the input system's own selectors |
| Multi-line with `⇧↩` | a text view is multi-line; the key binding decides what submits |
| IME, dead keys, `setMarkedText` | `NSTextInputClient`, which the view already implements for the grid |
| Find, spell-check suppression, insertion point | free, and we turn the parts we do not want off |

What it costs: the editor draws with `NSLayoutManager` while the terminal draws with CoreText. They
have to agree on a font and a cell box, which means the editor's text container is configured from
`TerminalFont` rather than from its own defaults, and the plan for that is §3.

## 2. Taking the command line away from the shell

This is the load-bearing protocol change, and Warp's is three bytes. `clear_line_editor_and_write_to_pty`
(`app/src/terminal/view.rs:9964`) writes, on submit:

```
" "  VT(0x0B)  NAK(0x15)  <the whole buffer>  "\r"
     Ctrl-K    Ctrl-U
```

Ctrl-K clears forward, Ctrl-U clears backward, and the leading space exists so that Ctrl-U always has
at least one character to delete — otherwise a shell with an empty line editor rings the bell on every
command. Ctrl-C is deliberately not used: it would cancel a running command.

So the shell's own line editor (zsh's `zle`, bash's `readline`) is never disabled and never used. It
sits there holding whatever it last held, gets wiped the instant a command is submitted, and the whole
buffer arrives at once. That is why `Tab`, arrow keys and `Ctrl-R` stop being the shell's business the
moment the editor owns the input: nothing is typed into the line editor any more, so nothing has to be
kept in sync with it.

**`Ctrl-C` and `Ctrl-D` stay the shell's.** They are signals, not editing, and an editor that
swallowed them would break the way people actually stop things.

## 3. Where the editor sits

`HeaderGrid` already has the point the prompt ends at — that is what `133 ; B` records, and it is why
Phase 2.5 recorded it. The editor's frame is derived from it: the prompt occupies its own grid, the
editor is an `NSTextView` overlaid from `promptEnd` to the end of the block's prompt region, and its
text container is sized from `TerminalFont`'s cell metrics so a column is a column.

This is where Warp's second `HeaderGrid` grid arrives. Phase 2.5 deliberately built only one, on the
grounds that a `prompt_grid` nothing writes to is a grid that will drift; now something writes to it —
the shell's prompt is drawn from it, independently of the editor's buffer, which is the whole reason
the split exists.

A block that has been submitted shows no editor. There is nothing to edit about a command that has
run.

## 4. Submitting, and what the grid sees

`↩` submits; `⇧↩` inserts a newline. On submit the editor's buffer goes to the pty wrapped as §2
describes, the editor clears, and the block's lifecycle carries on exactly as it does now: the shell
echoes nothing, because the editor never typed into it — but the shell's `preexec` still fires, `133 ; C`
still arrives, and the block's output grid starts. **No part of Phase 2.5's block model changes.**

## 5. Completion, in three sources

Cheapest first, and each one is a plain function from `(buffer, cursor)` to candidates, so each is
testable in a harness with no window server:

1. **History** — the shell's own history file, read once per session and indexed by first token. Gives
   both the ghost text and the popover.
2. **Paths** — real directory traversal from the last token, fuzzy-matched. `cd`, `ls`, `cat` and every
   other argument that is a file.
3. **Command signatures** — a table of subcommands, flags and descriptions for a curated set of
   commands (`git`, `docker`, `cargo`, `npm`, `kubectl`, …). Warp ships 500+ specs; this starts with a
   dozen and a file format that takes more, because a spec table is content, not code.

**Native completion generators are not in this phase.** Warp spawns background workers to invoke the
shell's own completion engine for unmodelled commands. That is a second pty per completion and a
protocol of its own; it earns a phase when the first three sources have been lived with.

## 6. Highlighting: a tokenizer, not tree-sitter

`phases.md` allows Rust reuse "where it pays". Tree-sitter is a C library with Rust bindings and no
Swift binding worth depending on, so using it means an FFI boundary, a build dependency and a vendored
grammar — for a grammar (`sh`) that is a few hundred lines of tokenizer. It does not pay here.

So: a shell tokenizer in the model layer, producing `(range, kind)` for command, subcommand, flag,
argument, string, operator, comment and variable. Same shapes as the grid's cells: pure, harness-tested,
no AppKit.

`not-found` is a kind, not a separate pass: the first token is checked against `PATH` and against the
shell's builtins and aliases, and an unknown one is drawn with a red dashed underline — the same
`squiggly` rendering the grid's `CellAttributes` already carries for other purposes.

## 7. What is deliberately thin

- **Ghost text** is one line of the history candidate appended after the cursor in a dimmed colour, and
  `→` or `Tab` accepts it. No inline expansion animation, no partial-accept by word.
- **The popover** is a table of candidates with their description, filtered as you type, `Tab`/`↑`/`↓`
  to move and `↩` to accept. No icons, no grouped sections, no preview pane.
- **Syntax highlighting** recolours on a debounce, not per keystroke, and only the edited line.

## 8. Gates

1. `./Scripts/run-tests.sh` green, with new harnesses for the tokenizer, the completion sources, and
   the buffer-to-pty encoding (the `" " VT NAK` prefix is exactly the kind of thing a harness should
   pin down).
2. `swift build -c release` clean, zero warnings.
3. `./Scripts/lint.sh` clean.
4. Pure-model grep still empty — the tokenizer and the completion sources are model code and must
   compile with no window server.
5. `index.md` updated in every directory that changed.
6. The app installs and runs; `vim`, `Ctrl-C`, `Ctrl-R` and paste all still work.
