# app/src/terminal/view — index

| File | Holds |
| --- | --- |
| `TerminalCoordinator.swift` | the feature's action surface; owns the session and the surface view, and whether it is the active pane |
| `TerminalFont.swift` | the monospace cell metrics everything is laid out on |
| `TerminalRenderer.swift` | paints the block document with CoreText, the selected block's border, context chips styled with the active palette, and the alternate screen for full-screen programs |
| `TerminalSurfaceView.swift` | focus, keyboard translation, document scrolling, block selection, resize, hyperlink hover & ⌘-Click navigation, keymap shortcut handling, and the layout handed to the renderer |
| `CommandEditorView.swift` | the command line, as an `NSTextView`: what a Return means, which keys belong to the shell, ghost text, and palette-driven text/cursor styling |
| `CompletionPopover.swift` | the completion candidates list, floating above the caret with glass blur, keyboard navigation, and palette-driven badges |
| `BlockMenuPopover.swift` | floating context menu for block actions (copy command/output, rerun) styled with the active palette |
| `TerminalFindBar.swift` | floating in-terminal find bar on liquid glass with search query input, match counter, next/prev navigation, and keyboard shortcuts |
| `TerminalPane.swift` | one pane's content: the surface, or why the shell could not start |
| `TerminalWindowController.swift` | the `NSWindow`, and the responder-chain landing point for the tab and pane commands |

The renderer never decides anything, the surface never holds screen state (the grids do), and the
document's geometry lives in `BlockLayout` so it can be tested without a window server. A `draw` that
starts branching on terminal state is the first sign this split has slipped.

Two seams worth knowing about:

- **The layout is built once, in the surface view, and handed to the renderer.** The editor is an
  overlay the document has to leave room for, so the view's `contributions` are not quite
  `session.blockGeometry` — and two layouts that disagreed about the document's height would put the
  cursor in one place and the text in another.
- **Focus follows the prompt.** The editor is the first responder while a prompt is showing and the
  surface takes it back for a full-screen program. That is also what suppresses the grid's cursor
  while typing: the renderer only draws one when the surface is the first responder.

Since Phase 4b there is a third thing to know, and it is the one that changed:

- **A pane takes the keyboard for itself when it arrives in a window, and only if its coordinator says
  it is the active pane.** The window's backdrop is no longer drawn here — it belongs to the window,
  in `app/src/workspace/` — so a surface that has just appeared is a surface that has just been added
  to a view hierarchy, which is exactly the moment it should claim focus and the only moment it does.
  Nothing in this folder reacts to shell output to move focus, and that is deliberate: the defect
  `journal.md` records as "focus that moved under the user's hands" was the echo of a keystroke
  handing the keyboard to the editor mid-keystroke.
