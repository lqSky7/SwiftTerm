# app/src/workspace — index

The window as a whole: the sidebar, and the terminal floating on it.

| File | Holds |
| --- | --- |
| `WorkspaceScreen.swift` | the window's content — the backdrop, the sidebar's glass, the sidebar column, and the content panel with its panes |
| `WorkspaceSidebar.swift` | the sidebar's column: the traffic lights' row, a row to open a tab, the tabs, and the settings popover |
| `SettingsView.swift` | the settings tab: a centred, searchable column of categories in a `NavigationStack`, the Appearance and Sidebar pages, our own back button, and the material-to-surface switch |
| `TabRenameField.swift` | the `NSTextField` a tab is renamed in |

**The sidebar is the window, and the terminal is a panel on it.** The sidebar's surface is full-bleed; the
tab list sits in its leading column; the terminal is the rest of the window, rounded on its *leading*
corners only — those are the corners that meet the sidebar, and the curve into it is the whole of the
effect. An earlier version had the two side by side, and before that it floated the panel clear of the
window's edges, which read as a card on a desktop and left a strip of sidebar visible even when the
sidebar was hidden.

**There is no tab strip and no top bar.** Tabs are listed on the sidebar and only there. The window has
no titlebar band — `.fullSizeContentView` with the title hidden — so the traffic lights float over the
sidebar and the sidebar's own control floats on the terminal.

**None of these holds state, and that is a rule rather than a style.** The selection, the chrome's
numbers, where a drag started, which tab is being renamed and what has been typed are all `AppCore`'s.
Two reasons:

- A draft or a selection kept in a view is a second copy of something the model already knows, and the
  four view-layer defects this project has had were all exactly that.
- `@State` is a macro, and the whole-app typecheck cannot expand macros — nor can it strip them, because
  the `$`-projections they generate stop existing. A view that uses one drops out of the only automated
  gate the view layer has. Keeping the views stateless is what keeps that gate working for the whole app.

Two more things worth knowing before changing any of them:

- **The panel's frame comes from `ChromeSettings.contentPanelFrame`, which is pure and harnessed**, and
  `AppCore` uses the same function to decide what size to tell the shell. One expression of that
  geometry, not two — which is the only reason a pane's drawn width and its reported width cannot drift.
- **The pane frames come from `PaneLayout`, likewise pure and harnessed.** These views place a pane at
  the rectangle they are handed and compute nothing. A pane one point too wide is not something a
  screenshot tells you about.
