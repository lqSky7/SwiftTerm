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

Latest repair: TUI cell alignment, streamed Unicode, fullscreen resize and cursor/input protocols.
See `docs/phase-tui-todo.md` for the repair checklist and human test targets.

The same repair restores inline current-directory suggestions and prioritizes history + local paths.

Verified build: 0.1.0 (101), installed at `/Applications/swiftTerm.app` without launching;
31 harnesses pass. Phase notes remain local under the repository's existing `docs/` ignore rule.
