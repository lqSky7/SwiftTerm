# crates/warp_terminal/src/model — index

The emulator and the block model. **Nothing in this folder may import AppKit, SwiftUI or Cocoa** —
the harnesses compile these files on their own, so an import here is a compile error, not a
code-review note.

## The emulator

| File | Holds |
| --- | --- |
| `TerminalGrid.swift` | the screen: cursor, scroll region, scrollback, erase/edit, alt screen, resize |
| `TerminalLine.swift` | one row of cells, and whether the next row continues it |
| `TerminalCell.swift` | one cell, plus the display width of a grapheme |
| `CellAttributes.swift` | bold/faint/italic/underline/reverse/…, and the reverse-video swap |
| `TerminalColor.swift` | `.default` / `.indexed` / `.rgb`, and the xterm-256 expansion |
| `TerminalRGB.swift` | an 8-bit-per-channel colour |
| `TerminalPalette.swift` | a colour scheme: sixteen ANSI slots plus foreground, background, cursor, presets and JSON import/export |
| `Hyperlink.swift` | an OSC 8 explicit hyperlink (id and target URI) |
| `LinkDetector.swift` | scanner for implicit links: URLs, file paths with line/col, and git commit hashes |
| `TerminalPen.swift` | the attributes, character set, and active hyperlink SGR has left in force |
| `TerminalModes.swift` | ANSI and DEC private modes |
| `TerminalCursorStyle.swift` | what `DECSCUSR` selects |
| `TerminalSize.swift` | the grid's dimensions and the pixel geometry that goes with them |
| `VTStringDecoder.swift` | incremental UTF-8 that survives a read ending mid-codepoint |
| `VTParser.swift` | the byte state machine, CSI/OSC dispatch tables, and OSC 8 parser |
| `TerminalEvent.swift` | what the parser reports upward that is not a screen change |
| `ShellIntegrationEvent.swift` | the `OSC 133` prompt markers |

## The blocks

| File | Holds |
| --- | --- |
| `BlockGrid.swift` | one grid and its lifecycle: started, finished, started when |
| `HeaderGrid.swift` | the prompt-and-command grid, and the point the prompt ends at |
| `Block.swift` | one command and its output: a header grid and an output grid, plus the metadata |
| `BlockID.swift` | a monotonic identifier |
| `BlockList.swift` | the ordered blocks, the prompt cycle, and the block cap |
| `BlockLayout.swift` | where every header and line lands in the document |

**Every block owns its own grids.** That is the load-bearing decision in this folder, and it is what
Warp does: a block's prompt-and-command grid finishes when the command is submitted, its output grid
when the command reports an exit code, and after that nothing writes to them again. There is no shared
line sequence and no index arithmetic between blocks — a block's extent is its own grid's length, so
the off-by-one that a shared sequence invited cannot be written down.

Two consequences worth knowing before changing anything here:

- **Sealed is not frozen.** A finished grid is re-wrapped on resize like any other — finished means the
  shell will not write to it again, not that its bytes are fixed. The re-wrapping itself is
  `TerminalGrid.reflow`, a pure static function that rejoins the rows a logical line is made of,
  re-splits them at the new width and maps the cursor through. It took until Phase 2.6 to exist: Phase 1
  built `TerminalLine.isWrapped` and ticked it, and nothing ever set or read it, so a narrower window
  truncated every long line for good.
- **The bound moved to the block list.** One grid used to cap the whole sequence at 10,000 lines; now
  every block has its own history, so `BlockList` caps the number of blocks instead.

`VTParser` writes into one grid at a time and calls it directly rather than through a delegate, so the
whole escape-sequence vocabulary is one switch instead of a protocol spread over several files. The
grid it writes into is settable, because that is how the output moves from a block's prompt grid to
its output grid to the next block.

## Context

What the terminal knows about where the shell is, without asking it:

| File | Holds |
| --- | --- |
| `RepoMetadata.swift` | the repository root, the branch out of `.git/HEAD`, and the project kind from the manifest present |
| `ContextChip.swift` | the ordered chips a prompt deserves, and the one abbreviation they share with the block header |
| `DirectoryColorTag.swift` | a path-to-colour table matched by longest prefix |

Warp gets the branch from its shell hooks (`warp_features.md` #5), which hex-encode it and ship it over
a DCS channel. It has to: its hooks run in a process it does not control. Here the branch is the
contents of a file, so `RepoMetadata` reads it — no process spawn per prompt, and a harness can test it
against a temporary directory instead of a real repository.

Two rules worth knowing:

- **A path prefix is not a string prefix.** `DirectoryColorTag.Table` and `ContextChips.abbreviated`
  both compare path *components*, so `/Users/me/work` does not cover `/Users/me/workshop`. A harness
  asserts both, because both are the kind of thing that looks right until it is not.
- **`RepoMetadata` answers only what a file can.** Ahead/behind counts and a dirty-file count are not
  in a file, so they are absent rather than approximated — a count that is wrong is worse than no count.

## The window

One window holds a list of tabs; a tab holds a tree of panes. Both are pure, and both hold
*identities* rather than sessions — the session a `PaneID` stands for is the view layer's to keep.

| File | Holds |
| --- | --- |
| `PaneTree.swift` | the split tree: `PaneID`, the axis and the placement a split is named by, and the tree itself — split, close, collapse, focus, and the layout order |
| `PaneLayout.swift` | the tree as rectangles: where each pane lands in the content area, and the gap that divides them |
| `Tab.swift` | one tab: its identity and its pane tree |
| `TabList.swift` | the tabs in one window, which one is showing, and the operations that mint identities |

Four things worth knowing before changing any of them:

- **A split along the axis a branch already runs along joins that branch as a sibling**, rather than
  nesting a branch inside a branch. Three panes side by side are one branch of three. Nesting looks
  identical in a two-pane window and is a staircase in a three-pane one, which is why the harness
  asserts the *shape* and not only the order.
- **A branch left holding one child collapses into its parent**, so closing one of two panes gives
  the survivor the whole space rather than half of it. That is what makes "every branch holds at
  least two children" an invariant, and the harness checks it after every operation in a long
  sequence of splits and closes.
- **The focus is a property of the tree, not of the tab.** A tab cannot disagree with its own tree
  about where the keyboard is, for the same reason `BlockList` owns the active block rather than a
  view holding a pointer to one.
- **Nothing here knows about a session.** Warp's tree is `Leaf(PaneId)` with the `PaneGroup` holding
  the panes, and this is the same split: `AppCore` keeps the `PaneID` → coordinator map. That is what
  lets a harness build any layout a user can build with no shell, no window and no pty.
- **The geometry is here too, not in the views.** `PaneLayout` turns a tree into a rectangle per pane,
  the way `BlockLayout` turns line counts into a document. A view places a pane at the rectangle it was
  handed and computes nothing, so the arithmetic a split's *appearance* rests on is arithmetic a
  harness can hold — and a pane one point too wide is not something a screenshot tells you about.

Three deliberate differences from Warp, all recorded in `docs/phase-4.md` §6: a branch carries no flex
weights or dividers, because nothing in the model drags a divider and a weight nothing writes to would
drift; there is no pane focus *history*, because it exists for undo-close, which is Phase 6; and
**the gap between panes is the divider** — the panes do not touch and what shows between them is the
window's own backdrop, so there is no rule to draw, no second piece of geometry to keep in step with
the layout, and no colour token for a line that is really an absence. It is also what makes fractional
pane widths safe: two panes that met exactly would seam on a half-pixel.

## The command line

What the editor needs to know about a shell command, all of it pure — no window server, no shell, and
in completion's case no file system either:

| File | Holds |
| --- | --- |
| `ShellTokenizer.swift` | a command line as flat, non-overlapping spans: command, argument, flag, string, variable, redirect, control, comment |
| `CommandResolver.swift` | whether the first word of a command could actually run — three-valued, because aliases are not captured yet |
| `FuzzyMatcher.swift` | pure Swift subsequence fuzzy matching with boundary, prefix, and consecutive bonuses, plus smart-case |
| `Completion.swift` | candidates from top 50+ signatures, local paths, and history, plus ghost text |
| `CompletionMenu.swift` | windowed selection model and state for the completion popover |
| `CommandSubmission.swift` | the bytes a submitted buffer becomes: the `" " VT NAK` prefix, and newlines escaped into continuations |

Two rules worth knowing before changing any of them:

- **The tokenizer is a scanner, not a parser.** Its output is a flat span list because that is exactly
  what a text view wants to apply attributes to; nesting is resolved into consecutive spans rather
  than into a tree. A subcommand is *not* one of its kinds — deciding that needs the signature table.
- **`CommandResolver` never guesses.** It answers `found`, `notFound` or `indeterminate`, and
  `notFound` is the only one that earns an underline. A two-valued check would have to guess about
  `$EDITOR` and `foo*`, and underlining a command that works teaches people to ignore the underline.
