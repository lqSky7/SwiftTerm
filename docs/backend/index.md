# Backend, website and headless handoffs

C0 (immutable shared contracts), B1A (identity and database foundation) and B2A (the relay and its
control plane) are implemented and verified against a live PostgreSQL 17 on Supabase. The backend is
deployed and reachable; the website is live on Cloudflare. B1B native identity, B2B publishing,
B2C viewing and B3A control are implemented. Terminal chat means
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
| `../../backend/index.md` | the deployed service — **note: the backend is no longer in this repository.** It is versioned at `gitlab.com:lqSky7/swiftterm-backend`, and this path is a local working copy that nothing here tracks |

Current source: C0, B1A, B2A/B2B/B2C, B3A, B4 and B5B are implemented. B1B now includes
native anonymous sign-in and account/device management. B5A native static export is next, after
human acceptance of this phase. See `phase-b1b-completion-todo.md` for current evidence.

The website proxies HTTP and WebSockets under `/api` to zrok. Browser session/CSRF cookies now
belong to the website origin; Supabase Auth still issues identities directly. The native app uses
its existing direct API configuration and private cookie jar.

The backend migrations 000–004 and its 177-test baseline are from the previous session; this phase
changed no backend code. B2B still publishes whole snapshots. Delta encoding and live output/input
parity remain human-test/optimization work; B5A still has no native producer.

The current Mac has Xcode-beta selected and builds Observation macros successfully. Release build
132 is installed at `/Applications/swiftTerm.app` without launching. The former collapse/undo
harness compile failures required missing shared-session sources, not an Observation workaround.

Anonymous sign-in regression: URLSession’s own ephemeral store must be retained. A bare
HTTPCookieStorage() loses the session cookies on this Mac. Website upstream requests must set
skip_zrok_interstitial or browser user-agents get HTML and the client reports invalid_frame.
Both paths passed real session exchange, account read and CSRF logout after repair.
