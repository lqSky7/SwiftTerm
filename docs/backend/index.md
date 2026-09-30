# Backend, website and headless handoffs

C0 (immutable shared contracts) is implemented: Swift DTOs in `crates/shared_session` and
`crates/cloud_objects`, TypeScript validators in `contracts/ts`, shared fixtures in
`contracts/fixtures`, and a Foundation-only harness plus a Node checker. No backend is deployed and
no headless frontend is implemented. Terminal chat means live terminal output to browser + browser
input back to the host PTY. No AI.

| File | Read for |
| --- | --- |
| `implementation-handoff.md` | C0/B1–B7 task ownership, file allowlists, dependencies, gates; remaining Git/SSH/web review |
| `headless-handoff.md` | H1–H4 shared module, console frontend and portability boundaries |
| `wire-contract.md` | frozen DTO shapes, limits, directions, counters and render/input rules; "Frozen by C0" records the spellings and rules C0 had to decide |
| `protocol.md` | HTTP/WebSocket flow, replay, leases, input uncertainty and share API |
| `schema.sql` | eight-table PostgreSQL draft, browser session/CSRF and device credential digests, owner RLS |
| `architecture.md` | relay/data ownership and scaling/privacy boundaries |
| `c0-audit.md` | source audit, fixed contract failures and runtime work still absent |
| `native-review-ssh.md` | implemented R1 scope, Warp references, divergences, limitations and checklist |
| `feature-status.md` | source-audited catalogue status |
| `roadmap.md` / `todo.md` | remaining phases and implementation checklists |
| `../../contracts/index.md` | the two contract implementations, the fixtures, and how to run both halves of the C0 gate |

Start B1A for backend/website; start H1 independently for headless. Remaining packages wait for
their named predecessors. Do not provision infrastructure, expand protocols or implement deferred
features silently. Each package stops after validation/signed commit for user acceptance. Node 24
LTS + TypeScript backend; TypeScript DOM/canvas website, managed PostgreSQL, OIDC and outbound WSS.
No PTY/shell execution on backend and no durable live input/output queue.

SQL syntax validation: pglast parsed 49 statements in a temporary environment; schema was not
applied to a DB. Actual role/auth/transaction tests are mandatory in B1A. Native R1 verification,
installation and user acceptance are tracked separately; documentation is not runtime completion.
