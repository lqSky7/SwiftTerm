# Phase 4a — Todo

The working checklist for Phase 4a (context & chrome). Ticked against a real run.

`phase-4.md` says why this phase is two phases and why the sidebar, tabs and panes are not in it.

## Block chrome — `app/src/terminal/view/`

- [x] A hairline rule between every pair of adjacent blocks, and none above the document's first
- [x] Drawn after the blocks, so a header's own background cannot cover it
- [x] The rule's colour is the terminal's own ink at 18%, the palette's stand-in for Warp's `theme.outline()`
- [ ] **The block margin** — the horizontal padding that keeps a block's text off its own edges. Not  
  built: it changes the usable *column count*, so the shell is told a different size and every  
  block reflows. That is worth doing when there is a reason for it, and since the selection became  
  a tint rather than a border there is no longer one.

## Context — `crates/warp_terminal/src/model/`

- [x] `RepoMetadata` — the repository root, found by walking up for `.git`
- [x] `RepoMetadata.branch` — read out of `.git/HEAD`, including a detached HEAD's short commit
- [x] `RepoMetadata.branch` — a worktree's `.git` *file* is followed to the real directory
- [x] `RepoMetadata.projectKind` — the nearest manifest, in a deliberate order
- [x] `ContextChip` + `ContextChips.forPrompt` — the ordered chips, a pure function of what is known
- [x] The `~` abbreviation, shared with the block header so the two cannot disagree
- [x] `DirectoryColorTag` + `Table` — longest-path-prefix matching, by path components
- [x] A palette slot is clamped to the sixteen that exist

## Rendering

- [x] `BlockLayout` reserves a chip row *above* one block's content, shifting no other block
- [x] `BlockLayout.Entry` carries `chipTop` / `chipHeight`, so a caller that ignores chips is still right
- [x] The renderer draws each chip as a rounded capsule with its label
- [x] **The block header has no background of its own** — dim text, the status dot, and the thin rule
      between blocks, which is what Warp's header is. It was a strip tinted 7% toward the ink, and at
      26pt it reached past its own row into the chips below it as well as saying what the rule says
- [x] **The chip row is Warp's**: the directory, then the branch, then the environment. Where you are,
      what you are on, what you are inside
- [x] **The shell's own prompt is suppressed.** `PROMPT`/`PS1`/`fish_prompt` are emptied by the
      integration, so the command sits at the **left margin** instead of behind `user@host %`. That is
      Warp's format and the reason a block reads as a command and its output rather than as a
      transcript. The directory is not lost with the prompt — it arrives over `OSC 7` and is the first
      chip. An earlier build kept the prompt and put the directory in a chip as well; this is the way
      Warp does it
- [x] **The block header keeps the directory and the duration** — that is Warp's header line, and it is
      a record of where a command *ran*, which a chip can only ever say for now
- [x] **The block header is Warp's line**: the status dot, the directory and the duration, and *no
      command*. The command is the block's first body line instead, which is where Warp puts it
- [x] **A submitted block's body is its command and then its output** — every grid the block owns,
      drawn in order. Phase 2 had deliberately shown only the output, on the grounds that the header
      carried the command; that reasoning went with the command leaving the header
- [x] Chips are only shown while a prompt is showing — a running command has no prompt
- [x] Chips are recomputed when a new prompt begins, so a `cd` and a `git switch` both show up
- [ ] **`OSC 9282`** — the shell's own facts (a virtualenv, a conda env) over a private channel, the way  
  `9281` carries the command. Not built: the design is settled (a fixed key, a space, then the value  
  as the whole rest of the body) but nothing reports one yet, so the chip would always be absent.
- [ ] **Clicking a chip** — Warp's open a menu. Not built: no menu has anything to offer until  
  directory tagging has somewhere to set a tag.
- [ ] **Directory colour tagging's picker** — needs the settings window, which no phase has built yet  
  (`tinycast_architecture_and_rules.md` §7 specifies it). `DirectoryColorTag` and its table are in the
  model, tested, and currently unreachable: with the directory in the header rather than in a chip, the
  tag's home is the header's directory text once something can set one.

## Gates

- [x] `Tests/context-chips-test.swift` — 41 checks, against real temporary directories
- [x] `Tests/block-layout-test.swift` — extended to 38 checks for the chip row
- [x] `./Scripts/run-tests.sh` passes 100% — 13 harnesses, 476 checks
- [ ] `swift build -c release` clean with zero warnings — **not verified here**; see below
- [x] `./Scripts/lint.sh` passes
- [x] Pure-model grep returns zero files
- [x] Every `index.md` current
- [ ] Installed and running — **not run**

### The stray file, and the two warnings it caused

The build the user ran reported:

```
warning: no rule to process file '.../crates/warp_terminal/src/model/XXoWyLMh' of type 'file'
```

`XXoWyLMh` was a stale copy of `ShellTokenizer.swift` from before the here-document work — a temp file  
left behind in a `sources:` directory, which SwiftPM warns about twice because it is neither Swift nor  
one of the named `exclude` paths. Moved out of the tree rather than deleted, to  
`backup/swiftTerm-stray/` in the working directory it came from. `find app/src crates -type f ! -name
'*.swift' ! -name 'index.md'` now returns nothing.

**Worth knowing for the next agent:** `learnings.md` says non-Swift files in a `sources:` directory are  
warnings rather than errors, which is true — but it means a stray file is a *silent* gate violation  
until someone reads the build log.

### Why the build is unticked

`swift build` cannot run in the agent's environment: `@Observable` is a macro, expanding it needs  
`swift-plugin-server`, and that needs `sandbox-exec`, which is refused. `swiftc -typecheck` over the  
whole app, with the macro attributes stripped from a copy, is clean — zero errors, zero warnings — and  
that covers every signature and name this phase touched. It does not cover macro expansion, linking or  
running.

---

## Testing it by hand

### 1. On open

A chips row and a prompt, and **no rule at the top**. There is one block and nothing above it, so there  
is nothing to separate — an earlier build drew a rule there because zsh emits `A B D A B` at startup,  
which leaves an empty block before the first real one.

### 2. Separators

Run two or three commands. There should be a hairline between each pair of blocks, and none above the  
first one that has anything in it.

### 3. The header

Status dot, the command, the duration — and **no directory**. The chips already say where you are, so  
the header no longer repeats it, and the command is in the same dim ink as the duration rather than a  
colour of its own.

### 4. Chips

- At home: one chip, reading `~`.
- `cd` into a git repository: a second chip appears with the branch name.
- `cd` somewhere that is not a repository: the branch chip disappears.
- `cd` deep inside a repository: the branch chip stays — the repository is found by walking up.
- `git switch <other-branch>`: the branch chip follows on the next prompt.
- A worktree: the branch is the worktree's, not the main checkout's.
- A detached HEAD: the chip shows the short commit.
- `sleep 3`: no chips while it runs, and they come back with the prompt.

### 5. Selection

Click a block — its header or its output — and it gets a subtle tint, with no border.

### 6. Regressions

Typing and the cursor blink; `vim` and `htop`; scrolling; `⌘↑` / `⌘↓`; `⌘C` and `⇧⌘C` on a selected  
block; window resize; `⌘K`.

### Two resize defects, found by the user

**1. Long lines were truncated by narrowing, not re-wrapped.** *Fixed — `phases.md` Phase 2.6.*
`TerminalGrid.resize` narrowed or padded each line, and `TerminalLine.isWrapped` was never set or read,
so narrowing a window lost the end of every long line for good. The reflow now rejoins, re-splits and
maps the cursor through, with 38 new checks in `terminal-grid-test`. `phase-2.5.md` and the model's
`index.md` claimed this worked before it did; both are corrected.

**2. The prompt repeats as the window is resized.** Shrinking moves the top rows of the *live* grid into
that block's own scrollback — including the prompt — and the shell then redraws its prompt when it hears
about the new size. The block ends up holding the old prompt in its history and the new one on screen,
which is what "resizing shows the same thing several times" is.

This one is a consequence of not owning the input. In a normal terminal the shell's line editor erases
its old prompt using cursor addressing; the reflow moves the cursor, so the erase lands somewhere else
and the old copy stays. **The decoupled editor fixes it by making the shell's line editor irrelevant** —
which is one more reason Phase 3 matters, and a reason not to spend effort on a patch that the editor
would delete. Still open.

1. **The separator's position.** It is drawn at each block's `headerTop`, which is exactly the previous  
   block's `bottom`. If it sits a pixel high or low, that is the place.
2. **The chip row's height.** `Theme.Size.contextChipHeight` is 24, and the capsules are inset by  
   `Theme.Spacing.xs` inside it. If the capsules touch the prompt below them, that is the number.
3. **The chips' content.** The directory chip should read `~` at home and `~/src/app` under it. If a  
   path is wrong or a branch chip is missing, `RepoMetadata` is the place and its harness is the test.
4. **A chip appearing or disappearing should not move the prompt.** The document is anchored to its  
   bottom, so a row added above the prompt must leave the prompt where it is. If it jumps, that is why.
