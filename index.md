# swiftTerm — index

A native macOS terminal built on Apple's stack, taking its product ideas from Warp.

| Path | Holds |
| --- | --- |
| `app/` | the application — composition root, menus, and one folder per feature |
| `crates/` | the subsystems the app is built from (the emulator, the shared UI framework) |
| `Tests/` | standalone harnesses, one Swift file each, no XCTest target |
| `Scripts/` | every executable: test runner, lint, build, install |
| `docs/` | local phase notes; versioned backend plan starts at `docs/backend/index.md` |
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

Follow-up repair: raw nano paste sends CR line endings without shell escapes; zsh/bash emit
only real prompt boundaries, and zsh prompt padding no longer creates a `%` block.

Current follow-up build: 0.1.0 (102), installed without launching. All 31 harnesses pass;
checklist: `docs/phase-paste-startup-todo.md`.

Resource optimization: duplicated glyph objects and unused span text removed; ASCII parsing
and idle cursor work reduced. Three paired optimized standalone benchmark runs preserve identical
pixel/output digests: renderer median 0.916 → 0.422 seconds, peak RSS 152.7 → 45.0 MiB;
ASCII parser median 0.708 → 0.342 seconds (RSS unchanged). These are workload measurements,
not a whole-app resource claim. Build 103 installed unopened; 31 harnesses pass.
Checklist and methodology: `docs/phase-resource-optimization-todo.md`.

Current repair: header double-click collapse/expand and immediate viewport reconciliation,
plus fullscreen TUI edge-to-edge drawing, PTY sizing and matching mouse/IME coordinates.
Build 0.1.0 (105) installed unopened; 32 harnesses pass. Local checklists:
`docs/phase-block-collapse-todo.md`, `docs/phase-fullscreen-edges-todo.md`.

Current phase: active-editor undo/redo and backend planning. Cmd-Z/Shift-Cmd-Z use bounded native
per-pane histories, including history/completion replacements; submit/cancel clears old actions.
Web terminal means streaming native state to a browser with authorized browser input back to the Mac.
No assistant/inference features. Read `docs/backend/index.md` for architecture, SQL and remaining phases.
Historical docs stay ignored; only `docs/backend/` is versioned. Build/check results are recorded there.

Current installed build: 0.1.0 (106), unopened. All 33 harnesses pass; PostgreSQL draft syntax
validated without deploying a service. User tests the active editor shortcuts.

Apple text assistance cleanup: all app inputs clear AutoFill content hints and disable system
completion/prediction/Writing Tools, while terminal manual completion uses the local engine.
Checklist: `docs/phase-autofill-todo.md`. No system-wide preferences are modified.

Startup crash repair: window field-editor lookup never mutates NSTextField, because its content-type
setter re-enters the lookup. Regression fields are attached to a window; user authorized app launch
for crash diagnosis and installed-build verification.

Current build 108 fixes the startup recursion; app reopened with user authorization and user
confirmed it works. All 33 harnesses pass (59 native editor/text-policy checks). Catalogue audit:
`docs/backend/feature-status.md` — 5 substantially built, 12 partial, 16 not implemented.

Native R1: Git diff chip/right review, bounded unified diff and file staging, conservative SSH
bootstrap and remote completion. Both sidebar drag targets are 16 points; review width and file/diff
split are adjustable. Curved terminal outline and Glass circle actions share existing appearance.
Build 115 installed without launching; 35 native harnesses pass (37 checks including delegated C0).
Read `docs/backend/native-review-ssh.md` for limits and `docs/backend/implementation-handoff.md`
for the saved backend/website packages; headless remains an implementation handoff.

C0 implementation audit: hardened transfer hash/watermark verification, counters, snapshot rollback,
atomic retained-size/fullscreen validation and sealed exports. All 37 suite gates pass. Build 116
installed unopened; details in `docs/backend/c0-audit.md`. Backend and website runtime still absent.
