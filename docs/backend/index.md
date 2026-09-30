# Backend, website and headless handoffs

C0 (immutable shared contracts), B1A (identity and database foundation) and B2A (the relay and its
control plane) are implemented and verified against a live PostgreSQL 17 on Supabase. The backend is
deployed and reachable; the website is live on Cloudflare. B1B (native sign-in), B2B (the native
publisher), B2C (the browser viewer) and B3A (browser control) are not started. Terminal chat means
live terminal output to browser + browser input back to the host PTY. No AI.

| File | Read for |
| --- | --- |
| `agent-context.md` | what already exists, what to build next, and the environment traps that cost real time — read this before starting any implementation |
| `implementation-handoff.md` | C0/B1–B7 task ownership, file allowlists, dependencies, gates; remaining Git/SSH/web review |
| `headless-handoff.md` | H1–H4 shared module, console frontend and portability boundaries |
| `wire-contract.md` | frozen DTO shapes, limits, directions, counters and render/input rules; "Frozen by C0" records the spellings and rules C0 had to decide, and the B2A correction records the one direction that was wrong |
| `protocol.md` | HTTP/WebSocket flow, replay, leases, input uncertainty and share API |
| `schema.sql` | eight-table PostgreSQL draft, browser session/CSRF and device credential digests, owner RLS |
| `architecture.md` | relay/data ownership and scaling/privacy boundaries |
| `c0-audit.md` | source audit, fixed contract failures and runtime work still absent |
| `native-review-ssh.md` | implemented R1 scope, Warp references, divergences, limitations and checklist |
| `feature-status.md` | source-audited catalogue status |
| `roadmap.md` / `todo.md` | remaining phases and implementation checklists |
| `../../contracts/index.md` | the two contract implementations, the fixtures, and how to run both halves of the C0 gate |
| `../../backend/index.md` | the deployed service: what runs, how to run it, and the three decisions to know before editing |

Start B2B (the native publisher) for the app, or B2C (the browser viewer) for the website. Both have
their predecessors in place. Remaining packages wait for their named predecessors. Do not provision
infrastructure, expand protocols or implement deferred features silently. Each package stops after
validation/signed commit for user acceptance. Node 24 LTS + TypeScript backend; TypeScript
DOM/canvas website, managed PostgreSQL, OIDC and outbound WSS. No PTY/shell execution on backend and
no durable live input/output queue.

The database is real now, so the old caveat about `pglast` no longer applies: `000`–`002` are applied
and the role, transaction and control-plane tests run against it as the actual service role. What
remains unproven is anything the native side owns — B2B's capture parity and B3A's input fencing
have no implementation to test.
