# Web terminal and remaining phases — index

Planning phase B0, 2026-09-30. No backend deployed. Terminal chat means streaming the selected
native terminal to the website and sending browser input back to it. The host Mac owns the PTY.

| File | Read for |
| --- | --- |
| `architecture.md` | hosting, relay boundaries, authorization and scaling decisions |
| `schema.sql` | PostgreSQL draft for accounts, devices, live sessions and block sharing |
| `protocol.md` | WebSocket frames, resync, browser input and share API contract |
| `feature-status.md` | current source-audited status of all 33 catalogue features |
| `roadmap.md` | verified baseline and remaining native/web/backend phases |
| `todo.md` | current phase completion and future implementation checklists |

Default stack: TypeScript on a supported Node LTS, managed PostgreSQL and OIDC. Live output and
input are bidirectional WebSocket traffic; terminal data is not a database event queue. There are
no model providers, assistants, prompts or generated commands in this product plan.

The latest request explicitly brings web viewing/control into planning even though feature #31
was previously deferred. Start with owner-only browser control, then invited viewers/controllers.
General simultaneous multiplayer and the local IPC daemon remain deferred. SQL is a schema draft,
not an applied migration; deployment roles and database integration tests are future B1 gates.

Validation: 33 harnesses pass, including 25 native undo checks. Debug and release builds have no
compiler warnings; lint succeeds with existing warnings in other files. PostgreSQL DDL syntax
was parsed with pglast in a temporary tool environment; no DB was created or migration applied.
Build 0.1.0 (106) installed at `/Applications/swiftTerm.app` without launching. U0/B0 complete;
user acceptance and all future implementation checklists remain open.
