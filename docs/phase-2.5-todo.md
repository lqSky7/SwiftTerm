# Phase 2.5 — Todo

The working checklist for Phase 2.5. Ticked against a real run.

Four things the plan called for were changed while building, all on the ponytail ladder:

- **`HeaderGrid`'s second grid.** The plan ported Warp's `prompt_grid` *and* `prompt_and_command_grid`.
  Only the second is here. What the split is *for* is knowing where the prompt ends, which is one
  point — and a `prompt_grid` nothing writes to is a grid that will drift. It arrives in Phase 3, when
  an editor has to be laid out around the prompt.
- **The block-reuse path.** Phase 2 reused the active block when a prompt was redrawn, to stop empty
  blocks stacking on a bare Enter. That is deleted: a new block every `133 ; A`, which is what Warp
  does, and an unsubmitted block draws no header — so nothing stacks visibly and there is no rule to
  get wrong.
- **`BlockGrid.trimsTrailingBlankRows`.** The plan carried Warp's flag. The height rule already trims
  (a finished grid is its content; a live one is a line taller only when the cursor is there), so the
  flag would have been a second policy saying the same thing.
- **`BlockGrid.text` is bounded by content, not by `lineCount`.** A live grid is one line taller than
  its content because that is where the cursor is, and that blank line does not belong on the
  pasteboard.

## Model — `crates/warp_terminal/src/model/`
- [x] `BlockGrid` — a grid and its lifecycle: started, finished, started when
- [x] `BlockGrid.lineCount` — the block's height, content-bounded
- [x] `BlockGrid.text` — the grid's lines as one string, for the clipboard
- [x] `HeaderGrid` — the prompt-and-command grid and the point the prompt ends at
- [x] `HeaderGrid.commandText` — the command as drawn, for a shell that reports none
- [x] `Block` owns a `HeaderGrid` and an output `BlockGrid`; no line ranges anywhere
- [x] `Block.isSubmitted` / `isSealed` / `didSucceed` — still derived, never stored
- [x] `BlockList.begin` — a new block with fresh grids every `133 ; A`
- [x] `BlockList.markCommandSubmitted` — finishes the prompt grid, starts the output grid
- [x] `BlockList.finish` — seals the output grid, and a grid that never started cannot finish
- [x] `BlockList.evictOldest` — a block cap, because the scrollback cap no longer bounds the list
- [x] `BlockList.shift(by:)` — deleted, and with it `TerminalGrid.trimmedLineCount`
- [x] `BlockLayout` — unchanged; it was always grid-agnostic

## Grid and parser
- [x] `VTParser.grid` settable, so the session can move the output into the next grid
- [x] `TerminalGrid.trimmedLineCount` deleted; `clearScrollback` and `reset` no longer count
- [x] `TerminalGrid.resize` still keeps blank lines — now so a resize cannot lose a sealed block's output

## Session wiring
- [x] `TerminalSession` routes the parser at the active block's grids, not one grid
- [x] `133;A` begins a block and gives the parser its prompt-and-command grid
- [x] `133;B` records where the prompt ended — the marker Phase 2 kept and did nothing with
- [x] `133;C` gives the parser that block's output grid
- [x] `133;D` seals the output grid
- [x] `OSC 7` still sets the active block's working directory
- [x] Every block's grid reflows on resize, not just one
- [x] `isAlternateScreen` follows the active block's output grid
- [x] `commandText(for:)` prefers the shell's report, then the header grid's own drawn command
- [x] `outputText(for:)` reads the block's own grid

## Rendering — `app/src/terminal/view/`
- [x] `TerminalRenderer` draws each block from its own grids
- [x] Rows are cached against the grid that holds them and the row in that grid
- [x] A finished grid's history rows are cached once; a live grid's are rebuilt, as Phase 1 settled on
- [x] The cache is keyed on whether a row is a screen row or a history row, so the two cannot collide
- [x] The cursor is drawn only in the active block's active grid
- [x] The alternate screen draws the active block's grid, with no blocks
- [x] `TerminalSurfaceView` — scrolling, block jumping and header selection unchanged

## Gates
- [x] `Tests/block-grid-test.swift` — 22 checks, the lifecycle and the content-bounded height
- [x] `Tests/header-grid-test.swift` — 6 checks, the prompt end and the drawn command
- [x] `Tests/block-list-test.swift` — rewritten to 44 checks: the prompt cycle, eviction, per-block grids
- [x] `Tests/block-layout-test.swift` — 25 checks, unchanged and still green
- [x] `Tests/terminal-grid-test.swift` — 68 checks, the `trimmedLineCount` checks removed
- [x] `Tests/terminal-session-test.swift` — 51 checks, a real zsh into a real block in its own grid
- [x] `./Scripts/run-tests.sh` passes 100% — 8 harnesses, 301 checks
- [ ] `swift build -c release` clean with zero warnings — **not verified; see below**
- [x] `./Scripts/lint.sh` passes
- [x] Pure-model grep returns zero files
- [x] Every `index.md` current
- [ ] Installed and running — **not verified; see below**

### The two unticked gates

Both need a compiler the agent that wrote this did not have. `@Observable` is a macro, and expanding a
macro means running `swift-plugin-server`, which needs `sandbox-exec`, which the build environment
refuses: `sandbox-exec: sandbox_apply: Operation not permitted`. SwiftPM's own sandbox can be turned
off (`--disable-sandbox`) and that is not the one that matters here.

What was verified instead, and what it does and does not cover:

- The whole app — including `TerminalRenderer`, `TerminalSurfaceView` and `TerminalCoordinator` —
  typechecks with zero errors and zero warnings when the two macro attributes are stripped from a copy
  of the sources. That covers every signature, name and type the rework touched.
- It does **not** cover macro expansion, and it does not link or run.

So the last two gates are the ones to run first:

```
./Scripts/build-app.sh && open dist/swiftTerm.app
```

*(Compiled and installed by hand on 2026-09-22. The warnings half of gate 2 is still unreported.)*

---

## Testing it by hand

### 1. The Phase 2 exit criterion still holds

Run several commands. Each appears with its own header — status dot, command, cwd, duration. Scroll
back through them. Right-click a block and copy its command, its output, its working directory. `⌘↑`
and `⌘↓` walk between block headers. `vim` opens in a block of its own, and on `:q` the blocks come
back intact.

### 2. The deliberate trade-off to judge

**A block now keeps 1,000 lines of its own history, and at most 100 blocks are kept.** The old bound
was 10,000 lines shared between every block.

- `seq 1 5000`, then scroll up inside that block. You should reach roughly 1,000 lines and no further.
- The question worth answering: **is 1,000 the right number?** It is one constant —
  `BlockGrid.defaultScrollbackLimit` — and `BlockList.defaultMaximumBlockCount` is the other.

### 3. What is genuinely new

- **Scrolling inside a long block does not disturb the others.** Scroll up in a `seq 1 200` block,
  then `⌘↓` past it; the blocks below should be exactly where they were.
- **Every block is re-shaped on resize.** With a dozen blocks on screen, drag the window narrower and
  wider: old blocks change width too, not just the one you are in. **Corrected:** this test said "re-wrap"
  and it does not — lines are truncated on the way down and padded on the way back, and content that
  fell off the right is gone. See `phases.md` Phase 2.6.
- **`⌘K` now keeps only the block you are in** and drops the rest, then clears the screen.
- **A bare `↩` no longer stacks empty blocks**, and an unsubmitted block still draws no header — so a
  terminal with no shell integration should look exactly as it did in Phase 1.

### 4. Where it is most likely to be broken

The view layer was typechecked but never run before you built it. These are the four places I would
look first, in order:

1. **The renderer's row cache.** Its key changed. If it is wrong the symptom is the one in
   `learnings.md`: rows that do not change when you scroll, or scrolling that "feels like
   re-rendering" rather than moving. Try `seq 1 200`, scroll up and down repeatedly, resize, scroll
   again.
2. **The document height.** A sealed block is exactly as tall as its content; a live one is a line
   taller when the cursor is past the last thing written. If that is wrong the prompt jumps, or a gap
   appears above it.
3. **The cursor.** It is now drawn from the *active* grid's cursor line, bounded by the active block's
   content height. If those disagree the cursor is simply not drawn, which reads as a frozen terminal.
4. **Eviction.** Run more than 100 commands and make sure nothing goes strange at the boundary.

### 5. Regressions to check

`vim`, `htop` and `less` (alternate screen); `Ctrl-C` and `Ctrl-Z`/`fg`; paste, including bracketed
paste; window resize *while* a full-screen program is running; `⌘C` and `⇧⌘C` on a selected block;
`⌘+`/`⌘-` font size; IME and non-Latin input; and bash or fish as the shell, where the header's command
falls back to the block's own drawn prompt line.

