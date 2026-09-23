# Phase 2.5 — A grid per block

**Goal.** Do it the way Warp does it. `warp_features.md` #1: *"The terminal core maintains an indexed
list of `BlockGrid` objects. When a command finishes, that block's grid is sealed as immutable, and a
new block is readied for the next command."* Phase 2 got the blocks and the boundaries right and the
ownership wrong: one `TerminalGrid` served every block, and a block was a range of line indices into
it. This phase gives each block its own grids and deletes the index arithmetic that came with sharing.

**Why this is a phase and not a refactor.** Phase 2's blocks work. What they do not do is give a block
its own scrollback, its own alternate screen, or an immutability a renderer can rely on. Everything
Phase 6 wants — find within a block, filter a block's output, bookmark a line — is a per-block
operation, and every one of them is cheaper against a grid the block owns.

**Not in this phase.** No editor (Phase 3). No chips, sidebar or themes (Phases 4–5). No search
(Phase 6). No block sharing, collapsing or bookmarks. The UI does not change at all: same headers,
same scrolling, same menu, same keys.

**Exit criterion.** Run several commands, including one with more than a screenful of output and one
that opens `vim`. Everything behaves as it did at the end of Phase 2 — headers, `⌘↑`/`⌘↓`, per-block
copy, `vim` in its own block — and each block now keeps its own history, so scrolling back through a
long block does not scroll the others.

---

## 1. What is already here, and what is actually ported

`grid_handler.rs` (2,854 lines) is not ported, and saying so is the point: it is alacritty's grid plus
Warp's ANSI handler, and `crates/warp_terminal/src/model/TerminalGrid.swift` already *is* that — the
cell grid, the scrollback, the scroll region, the alternate screen, the damage stamps. Re-porting it
would be translating a thing this project already has into a worse version of itself.

| Warp | Here | Verdict |
| --- | --- | --- |
| `grid_handler.rs` | `TerminalGrid.swift` | already equivalent — reused as is |
| `blockgrid.rs` — the grid *plus* a lifecycle | new `BlockGrid.swift` | ported |
| `header_grid.rs` — where the prompt ends, and the command as drawn | new `HeaderGrid.swift` | ported, minus the second grid |
| `rprompt_grid` | — | not ported: no right-prompt support exists to need it |
| `blockgrid.rs`'s caches (`OnceLock`, "only sound once finished") | per-block row cache in the renderer | ported as behaviour, not as types |

## 2. Model

| File | Owns |
| --- | --- |
| `BlockGrid.swift` | One grid and its lifecycle: started, finished, when it started. The unit Warp seals. |
| `HeaderGrid.swift` | The prompt-and-command grid, and the line and column the prompt ends at. |
| `Block.swift` | A header grid and an output grid, plus the metadata the shell reported. A reference type now: it owns grids, and a value type that copied them would be a lie. |
| `BlockList.swift` | The ordered blocks and which one is active. Still pure. `shift(by:)` is deleted. |
| `BlockLayout.swift` | Unchanged. It was always grid-agnostic — it takes line counts and gives geometry. |

`BlockGrid` is deliberately thin: a grid, two timestamps, and one rule about height. A *finished* grid
is exactly as tall as its content; a live one is a line taller when the cursor sits past the last thing
written, because that is where the cursor is. The screen always has `rows` rows, so trailing blanks are
never content — a block that claimed them would reserve the bottom of the window for nothing.

`HeaderGrid` is one grid, not Warp's two, and the difference is worth being explicit about. Warp keeps
a `prompt_grid` and a `prompt_and_command_grid` so the shell's prompt can be drawn independently of the
user's command; what that split is *for* is knowing where the prompt ends, which is one point. So this
holds the single grid the shell writes into plus that point, taken from the cursor at `133 ; B` — the
marker Phase 2 kept with nothing to do. The second grid arrives when Phase 3 needs to draw the prompt
around an editor rather than echo a command; adding it now would be a grid nothing writes to.

## 3. Where the output goes

The parser keeps writing to one grid at a time; it is the *grid* that changes, not the parser's shape.
`VTParser.grid` becomes settable and the session moves it at the two markers that already exist:

```
133 ; A   begin a block        → parser writes into the new block's prompt-and-command grid
133 ; C   command submitted    → parser writes into that block's output grid
133 ; D   command finished     → seal the output grid
```

`OSC 7` still lands on the active block. A session with no integration still produces one block whose
grid never seals, which is the same degradation as before: no hooks, no blocks, still a terminal.

## 4. What sharing was buying, and what pays for it now

Two things in Phase 2 were only there because one grid served every block, and both go:

- **`TerminalGrid.trimmedLineCount`** existed so a block naming a line by index could renumber when
  the scrollback dropped lines off the front. No block names a line in a shared sequence any more.
- **`BlockList.shift(by:)`** existed for the same reason. Deleted.

The bound moves with them. Phase 2 cut `evictOldest` on the grounds that the scrollback cap already
bounded the sequence — true then, false now: each block's grid has its own cap, so a thousand blocks
would hold a thousand scrollbacks. `BlockList` gets a block cap and evicts the oldest.

Resize gets more expensive, honestly so: every block's grid has to be re-wrapped, not just one. It is a
loop over the list, and it is what Warp does — a block's output is re-wrapped when the window does.

*(Phase 2.5 wrote that sentence when it was not true: `resize` narrowed and padded lines rather than
re-wrapping them, so a narrower window truncated every long line for good. Phase 2.6 built the reflow —
see `phase-2.6-todo.md` — and this is now an accurate description of what happens.)*

## 5. What this deletes, and what it makes sound

`learnings.md` records two bugs. Both were shapes the shared sequence invited.

The first was a row cache keyed by *view row* that served stale content, because a history line carried
no stamp of its own. The cache still has to exist — a `CTLine` is expensive to build — but its key is
now provably unique to its contents: the grid that holds the row, the row in *that grid*, and whether
the row is a screen row or a history row, since those two are stamped from different sources and must
not share a slot. A finished grid's history becomes cacheable at all, which it never was before, and
that is the memoisation Warp gets from sealing a grid.

The second was a block sealed by a marker that meant nothing, whose range came out empty. There is no
guard to get wrong now: a `D` with no `C` before it has no output grid that has started, so there is
nothing to seal. The bug is not fixed, it is unrepresentable.

## 6. Gates

1. `./Scripts/run-tests.sh` green. `block-list-test` and `block-layout-test` rewritten for the new
   model; `terminal-session-test` still drives a real zsh into a real block through the real scripts.
2. `swift build -c release` clean, zero warnings.
3. `./Scripts/lint.sh` clean.
4. Pure-model grep still empty.
5. `index.md` updated in every directory that changed.
6. The app installs and runs, and `vim` inside a block still works.
