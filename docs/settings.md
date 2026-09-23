# Settings — the standard

Where settings live, how they are stored, and what a page looks like. Short on purpose.

The reference for the look is the settings UI in **Tinycast** (`~/Desktop/tinycast`,
`Tinycast/Features/Settings/` and `Tinycast/DesignSystem/SettingsComponents.swift`). What is taken from it is
the **organisation and the restraint** — groups on cards, one line per row, small controls — not its feature
list. We have five settings; the reference has thirty, and copying its rows would be inventing settings.

## 1. Where they live

- **Settings are a tab, not a window.** `⌘,` and the gear in the sidebar's header both open it, and asking
  twice brings the tab that is already there to the front. A window of its own would be a second place that
  knows what is open.
- The root page is a **list of categories**. Each category is a page pushed onto a `NavigationStack`.
- **The bar at the top of a page is ours**, not the window's toolbar — the window's toolbar is the window's
  *leading edge*, over the sidebar, which is not where the settings are. `SettingsTopBar` draws the page's
  name **centred** and the way back on the leading side, stepped past `Theme.Size.paneToggleFootprint` so it
  does not sit under the floating sidebar button.
- **The column is a ceiling, not a width.** `Theme.Size.settingsContentWidth` is applied as `maxWidth`, so a
  window dragged narrow shrinks the page instead of cutting its right-hand side off.

## 2. How they are stored

`SettingsDocument` is a versioned `Codable` document, kept as one JSON blob in `UserDefaults` by
`SettingsStore`. `AppCore` loads it once and writes it from every command that changes a setting.

**It is split in two, and that is what makes it syncable:**

| Area | Holds | Roams? |
| ---- | ----- | ------ |
| `synced.chrome` — `ChromeSettings` | material, sidebar opacity, terminal opacity | yes — a preference |
| `device.chrome` — `ChromeLayoutSettings` | sidebar width, whether it is collapsed | no — a fact about a screen |

The split is in the **shape** rather than a filter at the edge, because a backend that had to be told which
fields to skip would have to be changed every time a setting is added. `SettingsDocument.revision` goes up on
every save and is what a sync backend compares to tell a stale write from a fresh one.

### Adding a setting

On the area's own type, all in one file:

1. a property with its default;
2. a `CodingKeys` case;
3. a `decodeIfPresent … ?? fallback` line;
4. an `encode` line;
5. a `mutating func set…` with a range, if it has one.

Then one `AppCore` command that calls the setter and `persist()`s. Nothing else — not the store, not the
document, not a view.

Adding a whole **area** is a field on `SyncedSettings` or `DeviceSettings` plus its two decode lines. The
choice between those two is the only real decision, and it is the question in the table above: *would a person
be annoyed to set this again on a second machine?*

### Decoding is tolerant, and that is not optional

A missing field falls back to its default; an unknown field is ignored; a name this build does not know costs
that one setting rather than throwing and taking the document with it; a value outside its range is clamped
through the same setter a control uses; a blob that is not a document loads as a fresh one. A version 1 file —
one `chrome` object holding both areas — is migrated on read, through the same setters, so its width arrives
clamped too.

`Tests/settings-store-test.swift` guards all of it, and it is the file to extend when you add a setting.

## 3. What a page looks like

- **A group is a labelled card.** Rows that share a subject share a surface (`SettingsGroup`): a small caps
  label above, then one `Material.ultraThin` card with hairline dividers between its rows. The label names the
  group and the rows do not repeat it — "Material" under "Window", not "Window material".
- **One line per row.** A title, and a subtitle **only when the title is ambiguous** — "Terminal" needs
  "Over the sidebar's."; "Material" under "Window" needs nothing. **No paragraphs, and no explanatory
  captions.** If a control needs a sentence to explain itself, the control is wrong.
- **The trailing control does the work**: a `Toggle`, a `Picker`, a `Slider`, a `Button`.
- **Three or more mutually exclusive choices are a dropdown, not a radio group.** A stacked radio group is
  the tallest thing on a page for a setting whose value is one word. `Picker(…).pickerStyle(.menu)`.
- **A `Slider` is not the row's width.** `Theme.Size.settingsSliderWidth` caps it, with **"Less" and "More"**
  either side, because an opacity slider has no left or right that means anything on its own. A slider
  stretched across the window is one whose value is hard to nudge.
- **A `Slider` gets a `Reset`**, disabled while it is already at the default. A neutral value somewhere in the
  middle is a value nobody can get back to.
- **A row that is meaningless while another setting is off is dimmed, not hidden** — a list that changes shape
  as you toggle things is a list you have to re-read.
- **Values nobody types are plain trailing text** in a `SettingsRow`. Tinycast uses `LabeledContent` for
  these; we do not, because it wraps its trailing value in a selectable field that eats clicks. A read-only
  value does not need a field to hold it.
- **Not a `Form`.** `SettingsRow` and `SettingsGroup` are hand-rolled, because a grouped `Form` draws a
  surface of its own and on a dark window it is a *light* one — which made the settings page a grey wash while
  the sidebar beside it was correct.
- **Every number is a `Theme` token.** A view that invents its own padding is how a design system rots.

## 4. The chrome's settings, as the worked example

| Setting              | Area     | Range           | Default                                        | Reset to                        |
| -------------------- | -------- | --------------- | ---------------------------------------------- | ------------------------------- |
| `sidebarWidth`       | device   | 160–420         | 220                                            | — (dragged, no control)         |
| `isSidebarCollapsed` | device   | —               | `false`                                        | —                               |
| `sidebarMaterial`    | synced   | three materials | `.glassClear`                                  | —                               |
| `sidebarOpacity`     | synced   | 0–1             | the material's `defaultOpacity`                | the material's `defaultOpacity` |
| `terminalOpacity`    | synced   | 0–1             | `ChromeSettings.defaultTerminalOpacity` (0.85) | 0.85                            |

## 5. The two opacities, and why they stack

There are two surfaces and two controls, because they have opposite instincts: **the sidebar is chrome and
wants to be translucent; the terminal is content and usually wants to be solid.** One slider could not say
that.

They are two fills, and the terminal's is drawn *over* the window's:

```
material                                          ← the chosen material, always drawn
windowBackgroundColor at sidebarOpacity           ← the window's own background
  └─ windowBackgroundColor at terminalOpacity     ← the terminal panel's, inside its rounded clip
```

So the terminal's effective opacity is `t + s(1 - t)`: at **0% it is as translucent as the sidebar**, and at
100% it is solid. That is the honest reading of two stacked fills, and it is what the subtitles say.

### Why 0% is *brighter* than the window's own background

Because the slider does not control the material — it controls **how much of the window's background colour
covers it**. The material is a surface the system draws with a light tint and a specular highlight of its own,
and it is lighter than `windowBackgroundColor`. So at 100% the dark background hides it, and at 0% you are
looking at the glass at full strength, which is lighter than the colour underneath.

The alternative — the slider scaling the material's opacity instead — is what an earlier version did, and it
is worse in a different way: at 0 every material looks the same, which is to say invisible, which is to say
the picker appears to do nothing. That is why the arrangement is this way round.

If 0% should mean "no glass at all, just the window's colour", the fix is to invert the pair: draw the
material at `sidebarOpacity` over an opaque `windowBackgroundColor`. It is a one-line change in
`WorkspaceScreen`, and it trades "the picker does something at every value" for "0% is the plain background".
