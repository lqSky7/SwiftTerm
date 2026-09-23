# Phase 4b — Todo

The working checklist for Phase 4b (multi-session: the tab manager, split panes, the sidebar).
Ticked against a real run.

`phase-4.md` §1 says why this is a phase of its own; §6 has what landed and the decisions behind it.

**The model half is verified. The view half has been typechecked and has never run.** That asymmetry is
not an accident of this phase — it is the working rule `journal.md` records after the editor was written
ahead of a window three times out of three. Everything under "What to look at" is a prediction, not a
result.

## The model — `crates/warp_terminal/src/model/`

- [x] `PaneID` — monotonic and never reused, like `BlockID`
- [x] `SplitAxis` + `SplitPlacement` — Warp's `SplitDirection`/`Direction` pair, kept apart so "the
      horizontal direction" cannot be confused with "the horizontal axis"
- [x] `PaneTree` — a leaf, or a branch holding an axis and its children
- [x] `PaneTree.split` — a same-axis split joins the branch as a **sibling**; a cross-axis split nests
- [x] `PaneTree.close` — removes a leaf and **collapses** a branch left holding one child
- [x] The focus moves to the pane before the closed one, or to the one after when it was the first
- [x] `focus` / `focusNext` / `focusPrevious`, wrapping, walking the layout order
- [x] `PaneLayout` — the tree as rectangles: the gaps come out of the space before it is divided, a
      nested split uses its parent's slot, and a window too small gets zero widths, not negative ones
- [x] `Tab` — an identity, a pane tree, the user's name for it when they gave one, and whether it is
      pinned
- [x] `TabID` — monotonic and never reused
- [x] `TabList` — the tabs, which is showing, `add`, `close`, `select`, `selectNext`/`selectPrevious`
- [x] `TabList.split` / `closePane` — the pane operations, and the tab closing when its last pane goes
- [x] `TabList.focus` / `focusNextPane` / `focusPreviousPane`
- [x] `TabList.rename` — trims, and clears the override on blank or `nil` so the session's own title
      shows through again
- [x] `TabList.setPinned` / `move` — pinned tabs are a block at the front, and a drag is clamped to keep
      it
- [x] One identity counter per window, so no two panes in it can collide
- [x] A refused split, close, focus, rename or move changes nothing

## The view half

- [x] **The sidebar is the window and the terminal floats on it.** Full-bleed glass, the tab list in its
      leading column, and the terminal as a rounded panel inset from the window's edges. The first
      version had the two side by side, which is a split and not what this is
- [x] `ChromeSettings` — sidebar width, panel margin, glass opacity, the collapse, and the ranges each is
      clamped to. Pure, `Foundation`-only, harnessed
- [x] `ChromeSettings.contentPanelFrame` — where the panel sits, used by the layout *and* by `AppCore` to
      decide what size to tell the shell, so the two cannot disagree
- [x] The window has no titlebar band: full-size content, hidden title, so the traffic lights float over
      the sidebar
- [x] A floating glass button on the terminal's top-left for the sidebar, level with the traffic lights,
      and `⌘⇧B`, whose menu item reads "Hide Sidebar" or "Show Sidebar" depending on which it will do
- [x] **The window's own controls go with the sidebar.** Hidden, the lights would be three buttons floating
      over the terminal's first line — so `AppCore.toggleSidebar` is the one place that hides them, and the
      sidebar's button takes the corner they were in. Recoverable without them: `⌘⇧B`, and Minimize, Zoom
      and Close Window are all in the Window menu
- [x] Hiding and showing the sidebar slides, on one animation scoped to the one value that decides both
      the sidebar's width and the panel's frame
- [x] `WorkspaceSidebar` — the traffic lights' row, a "New Tab" row, the tabs, and the settings popover
- [x] `WorkspaceScreen` — the backdrop, the sidebar's glass, the column, the resize handle, the panel
- [x] `TabRenameField` — an `NSTextField` that takes the keyboard on arrival
- [x] **Tabs are listed in exactly one place.** The strip above the panes was deleted: it and the sidebar
      were both drawing the list, which is what "doubled and duplicated" was
- [x] The selected tab's highlight is a fill *inside* the row, inset from the sidebar's edges, with no
      stroke — a boundary is not something a selection has an opinion about
- [x] A new tab is named for its place in the window, so a list of tabs is never a list of rows all
      reading the app's name
- [x] Rename on double click; rename and pin from the context menu; drag a row to reorder
- [x] **No view holds `@State`.** `@State` is a macro the whole-app typecheck cannot expand — nor strip —
      so a view using one drops out of the only automated gate the view layer has. That is also the
      discipline that has kept the four historical view bugs out
- [x] **The settings are a tab**, not a window and not a popover: `⌘,` and the gear in the sidebar's
      header both open it, and asking twice brings the tab that is already there to the front
- [x] The settings page picks the window's **material** — ultra thin, glass, or clear glass, and no more than
      three: `thin` was the same surface as `ultraThin` with a weight nobody chooses between, and `titlebar`
      existed only for having been on screen before the titlebar was removed
- [x] **The settings are stored.** `SettingsDocument` is a versioned `Codable` document with one field per
      *area*; `SettingsStore` keeps it as one JSON blob in `UserDefaults`; `AppCore` loads it once and writes it
      from every command that changes a setting. Tolerant and clamped on the way in, so a file from another
      build, a hand-edited file, or a file that is not a document all end with usable settings rather than a
      reset. Persistence was **not in the plan** — §7 specifies a settings hierarchy and nothing about storage
- [x] **The standard is written down** in `docs/settings.md`: where settings live (a tab, a `NavigationStack`,
      our own back button), how they are stored (five lines in one file per setting), and what a page looks like
      (sections, one line per row, no explanatory captions, a `Reset` on every slider). The reference is
      Tinycast's settings UI; the one place we differ is `List` rather than a grouped `Form`, because a grouped
      form draws a *light* surface of its own on a dark window
- [x] **Two opacity controls, not one.** The sidebar's and the terminal's are separate settings whose fills
      stack, so 0% on the terminal means "as translucent as the sidebar" and 100% is solid — which is the thing
      a single slider for both could not say
- [x] The sidebar's width has no control, because its edge is draggable and a slider would be a second
      way to set the same number. The settings page says so, and says `⌘⇧B`
- [x] The panel has **no margin**: it takes everything to the right of the sidebar's column, so hiding
      the sidebar really does give the terminal the whole window
- [x] **Split dividers, and dragging one.** `PaneBranch` carries a weight per child (Warp's
      `DEFAULT_FLEX_SIZE`, one per split, so a branch's children start equal); `PaneLayout` divides by weight
      and emits a `Divider` per boundary, named by the pair of panes either side of it; dragging one moves
      that boundary and leaves the panes outside the pair alone, with neither pane able to be squeezed past
      5% of the branch
- [ ] Pane rows in the sidebar. The sidebar lists tabs only, so the panes of a split are reachable by
      `⌘⌥[` / `⌘⌥]` and not by clicking
- [ ] A settings *window*. What exists is the chrome's own numbers in a popover; the hierarchy
      `tinycast_architecture_and_rules.md` §7 specifies is still unbuilt, and still blocks the
      directory-colour picker

## Gates

- [x] `Tests/pane-tree-test.swift` — 111 checks
- [x] `Tests/pane-layout-test.swift` — 53 checks
- [x] `Tests/tab-list-test.swift` — 125 checks
- [x] `Tests/chrome-settings-test.swift` — 59 checks
- [x] `./Scripts/run-tests.sh` passes 100% — 18 harnesses, 897 checks
- [x] `./Scripts/lint.sh` clean
- [x] Pure-model grep returns zero files
- [x] `swiftc -typecheck` over the whole app, macros stripped — exit 0, zero warnings
- [x] Every `index.md` current, and the new directories named in `Package.swift`'s `exclude:`
- [ ] `swift build -c release` clean with zero warnings — **not verified here**; see below
- [ ] Installed and running — **not run.** This is the phase's real gate and it is yours

### Why the build is unticked

The same reason Phase 4a's is: `@Observable` is a macro, expanding it needs `swift-plugin-server`, and
that needs `sandbox-exec`, which is refused. The typecheck strips the macro attributes from a copy and
covers every name and signature this phase added. It does not cover macro expansion, linking, or running
— and the four view-layer defects this project has had were all invisible to it.

### A limitation found while writing this

`@State` and `@FocusState` are macros too, so the typecheck workaround cannot expand them either — and
unlike `@Observable`, stripping them does not work, because the `$`-projections they generate
(`$draft`, `$isFocused`) stop existing. That is why the views here hold no state: not only is it the
discipline this project already had, it is what keeps the whole-app typecheck usable as a gate. A future
agent that wants `@State` in a view should know it costs the gate for that file.

## What to look at

Predictions, most likely to be wrong first. If something below is not what you see, that line is where to
start and the file it names is where to look.

1. **Nothing responds to a click.** This was the first real bug after the chrome was built, and it was
   `Theme.Size.titlebarBand`: with a full-size content view the titlebar still takes the mouse events in
   the top ~28pt of the window, so a control placed there is drawn, hovers, and does nothing. The sidebar's
   header row is now 54pt with its controls bottom-aligned, the floating toggle is padded clear of the
   band, and both full-window background layers refuse clicks explicitly. If a *specific* control is dead,
   check first whether it is inside the top 28 points; `docs/learnings.md` has the whole story.
2. **The inversion itself.** The sidebar's surface should be the window — edge to edge — with the terminal
   filling everything to the right of the tab column, rounded on its two *leading* corners so it curves
   into the sidebar. There is no margin: `contentPanelFrame` puts the panel at x = the sidebar's width and
   gives it the rest. If the terminal is still a column beside the sidebar, or the corners are square,
   that is `WorkspaceScreen.contentPanel`.
3. **The slide, and what it does to the terminal.** Hiding and showing the sidebar animates over
   `Theme.Motion.chromeFade` (0.18s). The known cost is in the code comment: the panel's width animates
   with it, and the panel *is* the terminal, so the pty is told a new size on each frame and the shell
   redraws its prompt each time. If that reads as a flicker, the one-line fix is to move the
   `.animation` modifier from the `ZStack` onto `sidebarColumn` alone — the sidebar slides, the panel
   snaps, and the jump is hidden because the sidebar arrives over exactly the region the panel gives up.
4. **The settings tab, and the two controls in it.** `⌘,`, or the gear at the sidebar's top right. It
   should open a *tab* — not a window, not a popover — and asking twice must bring the same tab to the
   front rather than opening a second.
   - **Window material** changes the surface the moment one is clicked. Five names, five surfaces; if two
     look identical, the mapping in `SidebarBackground` is wrong.
   - **Window opacity** is the window's *background colour over* the material, not the material's own
     strength. So at 100% the material is hidden and at 0% only the material is left — this is vicinae's
     arrangement, and its own config says "Needs window opacity < 1 to be visible" about the material.
     Picking a material moves the opacity to that material's default (0.6 for the glass pair, 0.55 for the
     blur trio), so a choice is visible immediately.
   - The bug this replaced: the opacity was multiplied *into* the material, so at 0% every material looked
     the same — which is to say invisible — and the picker appeared to do nothing at all.
   - The page is a `NavigationStack` and the stack is the system's, but **the back button is ours**: the
     system's lands in the window's toolbar, and the window's toolbar is the window's *leading edge* — over
     the sidebar, which is not where the settings are. `SettingsBackButton` uses `@Environment(\.dismiss)` and
     sits inside the page it goes back from.
   - The root is a centred, fixed-width column with a search field over it: a heading, the search field, then
     a row per category with a symbol, a name and a sentence. A list of names is a menu; this is a page.
   - **The light grey wash in dark mode was `Theme.Colors.panelScrim`**, which was built on `ramp` — and `ramp`
     is *white on dark*. A scrim that whitens in dark mode is not a scrim. It is now
     `Theme.Colors.settingsSurface`: black at 45% in dark and 12% in light, so it darkens in both.
5. **The traffic lights with the sidebar hidden.** They do not move, so with the sidebar hidden they sit
   over the terminal: the panel starts at the very left edge, which is what "completely hideable" means.
   If the first line of output is behind them, that is the trade — the alternative was the band that used
   to be there, which kept a strip of sidebar on screen and is what you asked me to remove.
6. **The selected tab's highlight.** A fill inside the row, inset from the sidebar's edges, with no
   stroke and no full-width bar. `Theme.Colors.selectionFill` is the colour and it is a white lift, not
   an accent — near-white in light mode, a lighter grey in dark. If it reads as a bar across the row, the
   fill is on the wrong view in `WorkspaceSidebar.row`.
7. **New tab names.** A new tab should read "Tab 1", "Tab 2" and so on immediately, not the app's name,
   and should switch to the directory once the shell has drawn a prompt. `AppCore.title(for:)` is the
   three-step fallback.
8. **The rename field.** Double-click a tab: a field with the whole name selected, Return commits,
   Escape cancels, clicking away commits. Most likely wrong, in order: the field not taking the keyboard
   on arrival, Escape not cancelling, and the terminal not getting the keyboard back afterwards —
   `AppCore.endRename` is where that happens, and if typing does nothing after a rename, that is it.
9. **Drag to reorder.** Drag a tab up and down; it must land where it was dropped. `List` measures the
   drop point before the move and `TabList.move` after, and `AppCore.moveTabs` is the one line that
   converts. A tab landing one slot short every time it is dragged down is that conversion.
10. **Pinning.** Pin from the context menu: the tab jumps to the top and shows a pin glyph. Dragging it
   down must refuse to leave the pinned block, and dragging another tab above it must not absorb it.
11. **`⌘⇧B`.** The View menu item should read "Hide Sidebar" or "Show Sidebar" depending on which it will
    do — that is `validateMenuItem` on the window controller, and if the title never changes, that method
    is not being reached through the responder chain.
12. **Splits.** `⌘D` then type: the characters must land in the new right-hand pane. `⌘D` three times:
    three equal columns, two 1pt gaps — a column and a staircase means the sibling insert is not firing,
    and it looks *correct* with two panes.
13. **A pane that appears blank or duplicated after a split.** The panes are `NSViewRepresentable`s
    wrapping surfaces the coordinator already owns, identified by `.id(entry.pane)`.
