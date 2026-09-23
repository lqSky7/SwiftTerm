# Phase 2 — Todo

The working checklist for Phase 2. Ticked against a real run.

Three things the plan called for were cut while building, all on the ponytail ladder:

- **`Block.state`** — redundant. Whether a block is being typed, running or finished *is* whether it
  has an output boundary and an end. Storing it as well would be a second source of truth for the
  same fact, free to disagree with the first.
- **`BlockList.evictOldest`** — the scrollback cap already bounds the sequence, and a block whose
  lines have scrolled away is dropped by `shift`. A second bound would have been a second policy.
- **`TerminalGrid.lines(in:)`** — nothing needed a range reader; `line(at:)` already does the job.

## Model — `crates/warp_terminal/src/model/`
- [x] `BlockID` — a monotonic identifier
- [x] `Block` — line range, command, exit code, timings, working directory
- [x] `Block.isSubmitted` / `isSealed` / `didSucceed` — derived, never stored
- [x] `BlockList.begin(at:workingDirectory:)` — start a block, reusing an empty one
- [x] `BlockList.markCommandSubmitted(at:command:at:)` — record the output boundary
- [x] `BlockList.finish(at:exitCode:at:)` — seal a submitted block
- [x] `BlockList.shift(by:)` — renumber when the scrollback drops lines off the front
- [x] `BlockList` drops a block whose output has scrolled away rather than clamping it to zero
- [x] `BlockLayout` — document geometry: header and content offsets per block
- [x] `BlockLayout.entries(intersecting:)` — which blocks a viewport touches
- [x] `BlockLayout.headerTop(ofBlock:)` — where to scroll a block's header to
- [x] `BlockLayout` handles an empty document and a headerless block

## Grid invariants Phase 2 leans on
- [x] `TerminalGrid.resize` keeps blank lines, so `totalLineCount` only ever grows
- [x] `TerminalGrid.trimmedLineCount` — how many lines fell off the front, and for `clearScrollback`
      and `reset` too, since those remove from the front by the same mechanism
- [x] `TerminalGrid.cursorLine` — the cursor's line in the same sequence `line(at:)` indexes
- [x] `TerminalGrid.contentLineCount` — one past the last line with anything on it
- [x] `TerminalGrid.line(at:)` rejects a negative index, which a part-scrolled viewport asks for

## Shell integration
- [x] `VTParser` — `OSC 9281` parsed into `TerminalEvent.commandSubmitted`
- [x] `VTParser` — newlines preserved, so a heredoc arrives whole
- [x] zsh integration — `preexec` reports `$1`
- [x] bash integration — `preexec` reports `$BASH_COMMAND`
- [x] fish integration — `fish_preexec` reports `$argv`

## Session wiring
- [x] `TerminalSession` owns a `BlockList`
- [x] `133;A` begins a block at the cursor line
- [x] `133;C` marks the command submitted, with the command text and the start time
- [x] `133;D` seals the block — but only one that was submitted
- [x] `OSC 7` sets the active block's working directory
- [x] Scrollback trims renumber the block list
- [x] A session with no integration still produces one block that renders as Phase 1 did
- [x] `commandText(for:)` falls back to the last non-blank prompt line when the shell reports none
- [x] `outputText(for:)` for the clipboard

## Rendering — `app/src/terminal/view/`
- [x] `TerminalRenderer` — the document model: a viewport over a stack of blocks
- [x] `TerminalRenderer` — block headers: status dot, command, cwd, duration
- [x] `TerminalRenderer` — content rows by line index, cached on the grid's generation
- [x] `TerminalRenderer` — the cursor only in the active block
- [x] `TerminalRenderer` — a submitted block does not repeat its prompt line
- [x] `TerminalRenderer` — the alternate screen still draws the grid's own screen, with no blocks
- [x] `TerminalSurfaceView` — scrolling over the document instead of the grid
- [x] `TerminalSurfaceView` — `⌘↑` / `⌘↓` jump to the previous / next block
- [x] `TerminalSurfaceView` — `⌘Home` / `⌘End` for the ends of the scrollback
- [x] `TerminalSurfaceView` — clicking a header selects that block
- [x] `TerminalSurfaceView` — right-click a block for its context menu

## Actions
- [x] `TerminalCoordinator.copyBlock(_:id:)` — copy command, output, or working directory
- [x] `⌘C` copies the selected block's output, `⇧⌘C` its command
- [x] `AppMenus` — the block actions in the Edit menu, with Copy greyed until a block is selected

## Gates
- [x] `Tests/block-list-test.swift` — 39 checks
- [x] `Tests/block-layout-test.swift` — 25 checks
- [x] `Tests/terminal-grid-test.swift` — extended to 71 checks for the line-identity invariants
- [x] `Tests/vt-parser-test.swift` — extended to 76 checks for `OSC 9281`
- [x] `Tests/terminal-session-test.swift` — extended to 50 checks, including a real zsh producing a
      real block through the real integration scripts
- [x] `./Scripts/run-tests.sh` passes 100% — 6 harnesses, 270 checks
- [x] `swift build -c release` clean with zero warnings
- [x] `./Scripts/lint.sh` passes
- [x] Pure-model grep returns zero files
- [x] Every `index.md` current
- [x] Installed and running
