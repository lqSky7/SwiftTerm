# Phase 2 — Command Blocks

**Goal.** The thing that makes this Warp rather than a terminal. A command and its output stop being
a run of lines in one scrollback and become an object: a block with a command, an exit status, a
working directory, a duration, and its own output. Once blocks exist, everything Warp does with them
— per-block copy, jumping, collapsing, finding, sharing — is a small feature on top instead of a
scraping problem.

**Not in this phase.** No editor (Phase 3), no chips or sidebar (Phase 4), no themes (Phase 5), no
search *inside* a block (Phase 6 — it needs the search UI), no block sharing (deferred), no
collapsing (cheap once blocks exist, but it needs a disclosure control and hit-testing).

**Exit criterion.** Run several commands. Each one appears with its own header showing the command,
whether it succeeded and how long it took. Scroll back through them. Right-click one and copy its
command or its output. `⌘↑` and `⌘↓` jump between block boundaries. `vim` still works, in a block of
its own.

---

## 1. The design decision: line ranges, not a grid per block

> **Superseded by Phase 2.5.** This section records why Phase 2 shared one grid; `phase-2.5.md`
> reverses it and gives every block its own grids, which is what Warp does and what `warp_features.md`
> #1 describes. The reasoning below is kept because it is the honest account of a decision that was
> made deliberately — and because the costs it names are the ones Phase 2.5 had to pay.

Warp gives every block its own `BlockGrid` (`crates/warp_terminal/src/model/blockgrid.rs`). We did
not, and the reason was worth stating.

A block's output needs full terminal semantics — cursor addressing, a scroll region, the alternate
screen — so it needs a real grid. But a *sealed* block's output never changes again, and the only
thing that made it a grid was that it was once live. So:

- **One `TerminalGrid`**, owned by the session, exactly as in Phase 1. One scrollback, one limit,
  one reflow path. Scrolling, which was the hardest thing to get right in Phase 1, is untouched.
- **A block is a range over that grid's line sequence** plus the metadata the shell reported.
- Sealing a block records where its output ended. Nothing is copied, nothing is reflowed, and the
  renderer keeps working in one coordinate space.

What this costs: a block cannot have an independent scrollback, and collapsing one is a layout
change rather than a view state. Neither is needed. What it buys: Phase 1's scrolling keeps working,
and there is one place where lines live.

The one invariant this leans on: **`TerminalGrid.totalLineCount` must not change except by
appending.** It holds, because a resize moves lines between the screen and the scrollback without
changing how many there are — *provided* `resize` stops dropping blank lines when it shrinks.
Phase 1 dropped them to keep padding out of history; that silently renumbers every block. Blank
lines are now kept, which is also self-correcting: growing the window pulls them straight back.

## 2. Model — `crates/warp_terminal/src/model/`

| File | Owns |
| --- | --- |
| `Block.swift` | One block: id, state (editing / running / sealed), its line range, the command, the exit code, the timings, the working directory. A value; it holds no lines. |
| `BlockList.swift` | The ordered blocks and which one is active. `begin`, `markCommandSubmitted`, `finish`, `shift(by:)` when the scrollback is trimmed, `evictOldest`. Pure — no grid, no clock, no view. |
| `BlockLayout.swift` | The geometry: where each block's header and content sit in one vertically-scrolling document, and which block a document position belongs to. Pure arithmetic, and the part most worth testing. |
| `BlockID.swift` | A monotonic identifier, so a view can key on a block without holding it. |

`BlockList` takes every environmental fact as a parameter — the line index to start at, the time, the
exit code — so it can be exercised with no grid and no clock at all.

## 3. Shell integration — one new marker

The header needs the command, and the grid cannot give it up: the prompt and the command are one
drawn line, and separating them would mean guessing where the user's prompt ends.

So `preexec` reports it, on its own channel:

```
OSC 133 ; C          # command executed — spec-clean, unchanged, so other integrations keep working
OSC 9281 ; <command> # swiftTerm's own marker: the command text, verbatim
```

9281 sits in the private range Warp uses for its own extensions (9280 is its completions channel).
`OSC 133` stays exactly what iTerm2 and VS Code expect. The parser caps the payload at 8 KB and
strips nothing: an `OSC` string may contain newlines, so a heredoc arrives intact.

If a shell does not report a command — bash and fish do not have `preexec`'s argument in the same
shape, and a session with no integration reports nothing at all — the header falls back to the last
non-blank line of the block's prompt region. Degraded, never absent.

## 4. Block lifecycle

Driven entirely by the markers already flowing since Phase 1:

| Marker | Effect |
| --- | --- |
| `133 ; A` | Begin a block at the current line. The previous block, if it was still editing and empty, is discarded. |
| `133 ; B` | Nothing yet. Kept because the split between the prompt and the command line is what a future phase needs to style them separately. |
| `133 ; C` | Mark the command submitted: record the output's start line, the command text from `9281`, and the start time. State → running. |
| `133 ; D ; code` | Record the exit code and the end time. State → sealed. |
| `OSC 7` | Record the working directory on the active block. |

A block with no integration at all stays in `editing` forever and renders exactly as Phase 1 did —
one long run of lines. That is the correct degradation: no hooks, no blocks, still a terminal.

## 5. Rendering — one document, headers between

The viewport becomes a window over a document:

```
[ header  block 1 ]  ← command · exit status · cwd · duration
   output line
   output line
[ header  block 2 ]
   output line
```

- A block's **content** is `outputStartLine..<endLine` once it has been submitted, and
  `startLine..<liveEnd` while it is still being edited. The prompt line is *not* repeated in the
  body of a submitted block: the header has the command, which is the whole point of a header.
- A block's **header** is a fixed-height strip. It is not drawn for a block still being edited —
  there is nothing to say about a command that has not been run.
- The document's height is the sum of header and content heights; the viewport sits at
  `totalHeight - scrollPosition - viewportHeight`. Phase 1's pixel scroll position carries straight
  over, so a trackpad gesture still slides rather than jumps.
- Content rows are still cached by the grid's per-row generation stamp, keyed by *line index*, which
  is now exactly what a block range names.
- **A full-screen program replaces the document entirely.** `vim` and `htop` switch to the alternate
  screen, which has its own grid, its own cursor and no scrollback — so while `isAlternateScreen` is
  true the renderer draws the grid's screen and nothing else. The block that contains the program
  keeps its range, and when the program exits the primary screen comes back with the blocks intact.
  Nothing about the alternate screen's contents survives, which is exactly what an alternate screen
  is for.

## 6. Actions

| Action | Where |
| --- | --- |
| Copy command / copy output / copy working directory | block context menu, and the Edit menu when a block is selected |
| Jump to previous / next block | `⌘↑` / `⌘↓`, scrolling the block's header into view |
| Copy | now meaningful: `⌘C` copies the selected block's output |

A selected block is Phase 2's minimal selection model: clicking a block selects it, and the actions
apply to it. Text-level selection is a separate job and is not in this phase.

**Amended after Phase 2.5.** Clicking was originally limited to a block's *header*, on the grounds
that a body click was ambiguous without text-level selection to tell it apart from a drag. There is
still no text-level selection, so a body click is not ambiguous — and a block you cannot click is a
block you cannot act on. Two things changed:

- **A click anywhere in a block selects it**, header or output. The right-click menu follows the same
  rule: it selects the block under the cursor and offers that block's actions.
- **A selected block is drawn as selected.** Before this, `selectedBlockID` was read only by the menu
  actions — the renderer never learned about it, so clicking a block changed nothing on screen. The
  indicator is a **subtle tint across the whole block**, header and output together, and deliberately
  *not* a border.

  Warp's default is a 2pt border (`SelectionBorderWidth` in `block_list_element.rs`), and this was
  built that way first. It was changed to a tint for two reasons: Warp's own `MinimalistUI` flag zeroes
  those widths to `0.0`, so a borderless selection is a mode Warp ships rather than a departure; and a
  border around a full-width block clips the first column of text, because these blocks have no
  horizontal padding. A tint says the same thing without touching a glyph, and a coloured cell inside
  the block still wins over it, which is correct — a cell's background is the program's, not ours.

Two things Warp has here that this does not, both deliberate: **multi-block selection** (Warp's
`SelectedBlocks` is a list of ranges, so `⇧`-click extends one) and **block padding**. Padding is a
chrome decision and belongs with Phase 4.

## 7. Gates

1. `./Scripts/run-tests.sh` green, with two new harnesses: `block-list-test` and `block-layout-test`.
2. `swift build -c release` clean, zero warnings.
3. `./Scripts/lint.sh` clean.
4. Pure-model grep still empty.
5. `index.md` updated in every directory that changed.
6. The app installs and runs, and `vim` inside a block still works.
