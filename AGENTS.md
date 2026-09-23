# Agent Guidelines
## for feature implementations, refer /Users/ca5/Desktop/swiftTerm/warp_features.md. We are building a swift native terminal based on some features of Warp, not everything from there.
## Somethings are marked as planned for later, let them be. 

## Don't reinvent the wheel — keep it as Warp does it
Don't reinvent the wheel. Keep it as Warp does it, unless stated otherwise in
`warp_features.md` — and implement only the features that file lists. A divergence is allowed only
where a phase doc records it and why.

## Commit Standard
- Every meaningful change must be committed with git flags `-s -S`:
  ```bash
  git commit -s -S -m "commit message"
  ```

## Working Philosophy & Skill Rules
- Always use the [ponytail](https://github.com/DietrichGebert/ponytail/blob/main/skills/ponytail/SKILL.md) skill for all tasks.

## No need for you to open anything to physically test it, When done with a phase let me know I will test it for you.

## you will follow /Users/ca5/Desktop/swiftTerm/tinycast_architecture_and_rules.md for any design related work

## You will maintain a massive todo list, which will be created per phase. You will update it as you complete tasks. 

## You will create small index.md at every directory level, so you or some other agent don't waste context. if any change, update that index.md

## It's not necessary to have the entire project in Swift, you can use rust at some parts directly copying warp team's implementation/modifying it to save work. But the entire UI shall be native.

## Directory Structure — follow Warp's
You should follow /Users/ca5/Desktop/warp's directory structure to keep stuff organised. Warp splits the
emulator and shared frameworks from the application, and each feature lives in its own folder:

```
app/                                   # the application (Warp: app/)
  assets/                              # bundled resources (Warp: app/assets/bundled/)
  src/                                 # (Warp: app/src/)
    AppCore.swift  AppDelegate.swift   # composition root and menus (Warp: app_state.rs, app_menus.rs)
    <feature>/                         # one folder per feature, e.g. terminal/ (Warp: app/src/terminal/)
      model/  service/  view/          # split when the folder stops being scannable
crates/                                # subsystems shared by the app (Warp: crates/)
  warp_terminal/src/                   # the emulator: model/ local_tty/ shell/ bootstrap/
  warpui_core/src/                     # shared UI framework and design tokens
Tests/  Scripts/  docs/                # harnesses, executables, documentation
```

Rules that come with it:
- New code goes in the folder Warp would put it in. A terminal model file belongs under
  `crates/warp_terminal/src/model/`; a terminal view belongs under `app/src/terminal/view/`.
- Feature folders are named in `lower_snake_case` like Warp's, while Swift files stay
  `PascalCase.swift` after the type they hold.
- Only `crates/` code may be reached from more than one feature. A feature never imports another
  feature.

## Finishing a phase
When a phase is complete: build and install the app so it can be tested, then stop. Do not start the
next phase in the same turn.
