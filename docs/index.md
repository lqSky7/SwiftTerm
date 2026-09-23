# docs — index

| File | Holds |
| --- | --- |
| `phases.md` | the high-level plan: what each phase is and why they are in that order |
| `phase-1.md` | Phase 1 in detail — a live shell, the emulator, the viewport |
| `phase-1-todo.md` | the Phase 1 checklist |
| `phase-2.md` | Phase 2 in detail — command blocks, and why they were line ranges not grids |
| `phase-2-todo.md` | the Phase 2 checklist |
| `phase-2.5.md` | Phase 2.5 in detail — a grid per block, which is what Warp does |
| `phase-2.5-todo.md` | the Phase 2.5 checklist |
| `phase-2.6-todo.md` | Phase 2.6 — the reflow, which Phase 1 ticked and never built |
| `phase-3.md` | Phase 3 in detail — the decoupled command editor, planned and half built |
| `phase-3-todo.md` | the Phase 3 checklist, and the record of what broke |
| `phase-4.md` | Phase 4 in detail — context and chrome, and why it is two phases; §6 is 4b |
| `phase-4-todo.md` | the Phase 4a checklist |
| `phase-4b-todo.md` | the Phase 4b checklist — the multi-session model, built; the view half, not |
| `audit-phase-1-2.md` | every ticked box in Phases 1 and 2, checked against the code |
| `journal.md` | what was attempted, what broke, and why the tree looks the way it does |
| `learnings.md` | what cost time to work out: toolchain, AppKit, CoreText, and two bugs worth reading |
| `settings.md` | **the settings standard** — where settings live, how they are stored, what a page looks like, and the two opacities |

`../EDITOR.md` is the handoff for Phase 3 specifically, and is the file to start from if that is your task.

Reference material outside this folder: `../tinycast_architecture_and_rules.md` (the engineering
posture and design system), `../warp_features.md` (the feature catalogue), `../warp/` (the
implementation being mined for ideas).

Read in this order: `journal.md` for where things stand and what has already been tried and failed,
then the current `phase-N-todo.md`, then `learnings.md` before writing any view code.
