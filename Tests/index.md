# Tests — index

One harness per guarded decision. Each compiles the shipped sources directly with `swiftc`, so a
harness that stops compiling means a decision leaked out of a pure layer. There is no XCTest target.

29 harnesses. The count is not a goal — it is what the decisions cost to hold down.

## The emulator

| Harness | Guards |
| --- | --- |
| `terminal-grid-test.swift` | wrapping, scrolling, the scrollback, wide glyphs, editing, resize and reflow, the alternate screen, line identity |
| `vt-parser-test.swift` | the escape-sequence dispatch tables, the string states, SGR's two spellings of an extended colour, UTF-8 buffering, OSC 8 |
| `shell-integration-test.swift` | the `OSC 133` prompt cycle that blocks are built on, in the order a real shell emits it |
| `text-selection-test.swift` | cell and block text selection boundaries and clipboard extraction |

## The blocks

| Harness | Guards |
| --- | --- |
| `block-list-test.swift` | the block lifecycle: boundaries, what a block owns, what a finish with nothing submitted does |
| `block-grid-test.swift` | a grid with a start and a finish — the thing Warp actually seals |
| `header-grid-test.swift` | the point the prompt ends at, and the command line as drawn |
| `block-layout-test.swift` | the document geometry: where every header, chip and line lands |

## Context

| Harness | Guards |
| --- | --- |
| `context-chips-test.swift` | the repository walk, the branch out of `.git/HEAD`, the project kind, the chips and the colour table — against real temporary directories |

## The command line

| Harness | Guards |
| --- | --- |
| `shell-tokenizer-test.swift` | the spans a command line is coloured in, and that they stay ordered, non-overlapping and complete |
| `command-resolver-test.swift` | the not-found check, including the *indeterminate* answer that keeps a working command from being underlined |
| `fuzzy-matcher-test.swift` | subsequence fuzzy matching scoring, prefix/boundary/consecutive bonuses, and smart-case rules |
| `completion-test.swift` | what the popover and the ghost text offer, from 50+ signatures, cd/dotfile paths, and history |
| `completion-menu-test.swift` | popover windowing, pagination, cursor selection, and insertion replacement range |
| `editor-submit-test.swift` | the three bytes of protocol a submitted command becomes: `" "` Ctrl-K Ctrl-U |
| `command-history-test.swift` | deduplication, prefix search, and MRU command ordering |
| `history-navigation-test.swift` | up/down arrow history recall, prefix filtering, and editor draft preservation |
| `shell-history-file-test.swift` | zsh, bash, and fish history file parsing and line extraction |

## The window & Settings

| Harness | Guards |
| --- | --- |
| `pane-tree-test.swift` | where a split puts a pane, the sibling insert on a matching axis, the collapse when a branch is left with one child, and where the focus goes when the focused pane closes |
| `pane-layout-test.swift` | the tree as rectangles: that the gaps come out of the space before it is divided, that a nested split uses its parent's slot, and that a window too small for its panes gets zero widths rather than negative ones |
| `tab-list-test.swift` | the tab list: opening, closing, which tab shows, focusing a pane inside a tab, renaming, pinning, dragging to reorder, the settings tab and that every pane operation refuses it, and the two rules that keep it consistent — a terminal tab never holds no panes, and no two panes in a window share an identity |
| `chrome-settings-test.swift` | the chrome's numbers: that each has a range, that the default is inside its own range, the 5 materials picker (including `.none`), and where the content panel lands |
| `settings-store-test.swift` | the settings document: round-trip, backwards compatibility, missing fields, unknown fields, material fallback, and invalid blobs |
| `session-snapshot-test.swift` | workspace state serialization, window tabs, and layout reconstruction |

## Phase 5: Hyperlinks, Themes, and Keymaps

| Harness | Guards |
| --- | --- |
| `hyperlink-test.swift` | OSC 8 parse, cell stamping, URI preservation, and OSC 8 end-anchor reset |
| `link-detector-test.swift` | scanning for HTTP/HTTPS URLs, file paths with line/column numbers, trailing punctuation stripping, and git commit SHAs |
| `theme-palette-test.swift` | 8 preset themes, contrast checks, 16-color ANSI palettes, and JSON import/export schemas |
| `keymap-test.swift` | KeyEquivalent, modifier matching, override mapping, collision avoidance, and settings round-trip |

## End to end

| Harness | Guards |
| --- | --- |
| `terminal-session-test.swift` | a real shell on a real pty, and that the integration scripts parse in the shells they claim to be for |

`terminal-session-test` is the only one that runs anything real, and it is the one that found Phase
2's boundary bug that every unit test had agreed with. Keep it end to end.

`HarnessSupport.swift` is shared by all of them and is not itself a harness — it is the assertion
helper plus the read-only extensions the harnesses use to look at a grid.
