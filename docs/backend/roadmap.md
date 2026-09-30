# Remaining phases and implementation order

2026-09-30 source audit; this supersedes completion assumptions in old local phase notes.
The terminal baseline is build 105. Current work adds active-editor undo/redo and completes backend
planning. Each implementation phase ends with harnesses, warning/lint checks, indexes/todo updates,
signed commit (`-s -S`), build/install and a stop for user testing. No app launch by the agent.

## What exists versus what remains

| Area | Verified in code | Remaining |
| --- | --- | --- |
| Terminal/blocks | own grids, reflow, VT/TUI modes, selection, collapse, cursor/input repair | user acceptance of recent TUI/collapse fixes |
| Editor | native NSTextView, history, inline local/history ranking, completion | undo/redo repair in current phase; audit token styling/validation UI against requirements |
| Context/workspace | chips, tabs, pane tree, sidebar and divider resizing | directory-tag picker wiring and network banner content need audit/implementation |
| Appearance | palettes/import/export, opacity/materials, keymaps, OSC8/path links | procedural backgrounds/theme creator/modal keymap scope audit; do not infer completion from checkboxes |
| Find | current block/scrollback find and pure fuzzy matcher | file/history search, embedded rg requirement, universal palette |
| Restoration | local JSON tab/pane/directory snapshot and restore | block persistence, crash recovery, process safety, undo-close |
| Reach | feature catalogue and plans | launch configs, SSH bootstrap, media, notebooks, git review, headless mode |
| Web/backend | this B0 plan only | identity, relay, viewer/control, publishing and deployment |

`SessionSnapshot` restores context with new shells, not running processes. `AppCore` saves the current snapshot during shutdown; structural change handling does
not itself checkpoint it. Add crash-safe checkpoints without duplicating restoration paths. Never rerun commands during restoration. Profile UI currently reflects the local
OS user, not a cloud account. The current settings/keymap implementation lacks a palette action
although an older checklist claims it exists. Verify actual callers for every next feature.

## Native phases

| Phase | Scope and dependency | Exit criterion |
| --- | --- | --- |
| U0 (current) | active command editor undo/redo, per-pane ownership and submission boundary | insertion/replacement/history/completion undoable; cleared at submit/cancel; no effect on raw programs |
| 5R | audit editor highlighting/validation, directory tag picker, theme creator/procedural backgrounds and modal keymaps against catalogue | explicit implemented/deferred matrix; implement only missing catalogue requirements in small increments, retain idle resource goals |
| 6A | process close/quit protection (#47), native process queries in local_tty service | all pane/tab/window/quit paths consistently protect active foreground jobs |
| 6B | local SQLite session + sealed-block persistence (#18), build on current JSON migration | crash restores layout/directories/output read-only, bounded writes/retention, no command replay |
| 6C | undo closed tab/pane (#48), depends 6A/6B | restores context/output/layout, fresh shell, bounded undo stack |
| 6D | universal palette (#15), reuse FuzzyMatcher/KeymapAction | actions/search discoverable and dispatched to focused context; no duplicate action model |
| 6E | file/history/scrollback search (#42), reuse existing find | cancellation, scoped roots/ignored files and bounded results; compare rg CLI reuse first, then embed only if required benefit justifies FFI |
| 7A | declarative launch configs (#25), depends pane/session models | validated profiles create named layout/directories/env; explicit trusted command launch |
| 7B | SSH bootstrap (#19) | use system ssh, hook negotiation, remote cwd/prompt/resize/input parity, no secret logging |
| 7C | Kitty/iTerm2 media (#23) | bounded payload/decode/cache, protocol tests, correct placement and memory reclamation |
| 7D | executable Markdown notebooks (#20) | editable cells/blocks, explicit execution, persistence/export, no automatic command replay |
| 7E | native Git diff/review (#26) | repository-scoped status/diff, large diff cancellation, correct file navigation |
| 7F | headless console TUI (#41) | reuse pure core; independent renderer and keyboard frontend, no AppKit leakage into models |

Order may move independent 7A/7B work earlier when user requests it. Avoid wholesale renderer/PTY
rewrites while adding reach features. GPU/media changes need measured benefit. Do not silently add
uncatalogued automation, agents, cloud shells or command-generation features.

## Backend and website phases

| Phase | Deliverable | Dependency / acceptance |
| --- | --- | --- |
| B0 (current) | architecture, SQL draft, protocol, remaining roadmap and todo | planning artifacts only; no service provisioned |
| B1 | managed identity, accounts/devices, PostgreSQL migration/roles, HTTP API and website sign-in/download shell | non-owner RLS/isolation tests, PKCE/Keychain, CSRF/Origin checks, backup restore drill |
| B2 | owner-only selected-pane web viewing | B1; outbound native WSS, snapshot/damage/render equivalence, reconnect/slow-reader limits, zero idle stream work |
| B3 | owner web input/control | B2; native approval, one controller, local takeover, lease/epoch fences, safe prompt/raw routing and uncertain input UX |
| B4 | invited viewer/controller grants | B3; ACL/expiry/revocation, invitation privacy, no simultaneous co-typing |
| B5 | reviewed static block exports/permalinks (#9/#14 export subset) | B1; native preview/redaction before upload, immutable snapshots, safe website viewer and revoke/delete |
| B6 | load testing, deployment hardening, multiple relay replicas | B2/B3; consistent routing, lease fencing, reconnect on topology change, resource budgets and measured capacity |
| B7 (conditional) | media/object storage | only after 7C or real large-export requirement; private objects, authorized reads, orphan GC |

B5 can precede B4 independently. Web input is requested; full multiplayer is still deferred:
no concurrent writers, presence avatars, session recording or collaborative editing in these phases.
Sharing plans are brought forward by the user's explicit backend/website request. Local IPC stays
out of scope. Stop after B0/U0 in this turn; do not roll into hosted infrastructure or the next app phase.

## Assumptions to resolve before implementation

- Backend stack/hosting default above; user can select a provider before B1 provisioning.
- Domain, identity provider, email invitations and signing/notarization/download distribution.
- Retention durations, account/session limits and whether relay-visible TLS is acceptable.
- Browser control initial owner-only; invited controller UX/policies in B4.
- Geometry v1 is host-owned; browser resize and mouse reporting require a later explicit increment.
