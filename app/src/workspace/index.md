# app/src/workspace — index

The window as a whole: the sidebar, and the terminal floating on it.

| File | Holds |
| --- | --- |
| `WorkspaceScreen.swift` | the window's content — the backdrop, the sidebar's glass, the sidebar column, and the content panel with its panes |
| `WorkspaceSidebar.swift` | the sidebar's column: the traffic lights' row, whose window this is, the tabs — and `SidebarRowHighlight`, the lit row the selection draws |
| `IdentityMark.swift` | the app's identity — the icon's own two strokes as a `Shape`, and the view that draws it at a row's size |
| `ProfileAvatar.swift` | the user's picture at whatever size it is needed: the one view the sidebar's row and the profile page share |
| `ProfileView.swift` | the profile page — the picture, the name, and the account, each editable by double-clicking it |
| `Appearance.swift` | names to AppKit for the one setting whose meaning AppKit owns: `AppearanceMode` to `NSAppearance` and to a terminal palette |
| `SettingsView.swift` | the settings tab: a centred, searchable column of categories in a `NavigationStack`, Appearance (with "None", explicit glass options, and chip background material), Themes & Colors (presets, ANSI palette customization, import/export), Commands & History (saved commands and autocomplete data manager), Keyboard Shortcuts (granular keybinding recorder), and Sidebar pages |
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

**A selected row is lit by two corners, not by a border.** `SidebarRowHighlight` draws a scrim that
darkens, plus a one-point hairline along the *top and bottom* edges only — and along each of those it is
bright at one end and gone at the other: the top edge at its leading end, the bottom edge at its trailing
one. Light from one side catching the two corners that face it. Even along both edges the same hairline
reads as a border and makes the row look like a button; run down the vertical sides as well and it reads
as a box. Both the tab rows and the profile row use it, because "this is the row you are in" is one
question with one answer.

Two things about it are easy to get wrong and both were:

- **It is two `Rectangle`s, not a masked `strokeBorder`.** A mask on a stroke cannot tell the top edge
  from the left one, so there is no mask that lights the top and bottom while leaving the sides dark —
  the sides have to simply not be drawn.
- **Its fill and its hairline are the only two colours in `Theme.Colors` that are a scrim rather than a
  `ramp`.** The row is lit by being *recessed*, so the ink has to be black in both appearances, and `ramp`
  is white on dark.

**The highlight runs almost edge to edge, and getting it there takes two numbers.** A `List` keeps its
rows clear of its own edges and `.listRowInsets` can only add to that, so `WorkspaceSidebar.rowInsets`
takes the list's inset back with a *negative* `Theme.Size.sidebarRowBleed` and the row pads itself in
again by `Theme.Size.sidebarRowInset`. Eight and four, and the eight was measured rather than guessed —
with `leading: 0` a row lands twelve points in. Change either and the highlight stops short of the edge by
exactly the error, which is what it did for two attempts.

**The identity mark is the icon's own geometry, not a copy of it.** `IdentityMark.swift` carries the
numbers from `app/assets/swiftTerm.icon/Assets/SVG Image.svg`, in that file's coordinate space; if the icon
changes, that file changes with it. The one thing that is *not* the icon's is the stroke weight, and the
note on `Theme.Size.identityMarkStrokeRatio` says why: 3 units in a 100-unit box is right on a 1024-point
canvas and under three quarters of a point on a row.
