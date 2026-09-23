# swiftTerm — index

A native macOS terminal built on Apple's stack, taking its product ideas from Warp.

| Path | Holds |
| --- | --- |
| `app/` | the application — composition root, menus, and one folder per feature |
| `crates/` | the subsystems the app is built from (the emulator, the shared UI framework) |
| `Tests/` | standalone harnesses, one Swift file each, no XCTest target |
| `Scripts/` | every executable: test runner, lint, build, install |
| `docs/` | the phase plan and the per-phase detail |
| `READ_ME.md` | the handoff for the project as a whole — read this one first |
| `EDITOR.md` | the handoff for Phase 3, the command editor: the one phase already attempted and abandoned |

Read before changing anything: `AGENTS.md`, then `READ_ME.md` for the project's state and its hard rules,
then `docs/journal.md` for what has been tried and what broke. `docs/phases.md` is where this is going.

If your task is the command editor, `EDITOR.md` is written for you and is the only file you need to start
from.
