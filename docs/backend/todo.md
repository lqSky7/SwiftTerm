# Phase checklists

Tick only against code or completed planning artifacts. Planning a feature is not implementing it.
Every implementation phase must update its own tests/indexes, run the required checks, commit with
`-s -S`, build/install without launching, then stop for human testing.

## B0 — planning (current)

- [x] Audit current source rather than trusting old phase checkboxes.
- [x] Define terminal chat as live native terminal output + browser input.
- [x] Replace the mistaken earlier plan; no inference/assistant components remain.
- [x] Record bringing web view/control and sharing forward into planning.
- [x] Choose small default backend/website/database boundaries.
- [x] Describe native/shared/backend/website feature placement.
- [x] Draft SQL with ownership FKs, idempotency and forced RLS.
- [x] Extend draft to eight tables with browser session/CSRF digests and device credentials.
- [x] Freeze wire DTOs and explicit headless/backend/website agent package boundaries.
- [x] Specify HTTP and WebSocket payload/lifecycle contracts.
- [x] Plan snapshot barriers, deltas, replay/resync and alternate-screen behavior.
- [x] Plan one-controller approval, local takeover and uncertain input acknowledgements.
- [x] Plan auth/device/grant revocation and publisher epoch/lease fencing.
- [x] Plan static export preview/redaction/immutability and revocable links.
- [x] Record resource caps, measured scaling gates and proposed retention policy.
- [x] Map remaining app phases and backend dependencies.
- [x] Parse SQL and check documentation/schema consistency (no runtime DB test in B0).
- [x] Complete U0 regression suite and build/install.
- [x] Update all changed directory indexes and commit signed work.

## U0 — active editor undo/redo (current)

- [x] Trace menu actions, native editor ownership and buffer replacements.
- [x] Add standard Cmd-Z and Shift-Cmd-Z menu actions through responder chain.
- [x] Own bounded native undo history per command editor/pane.
- [x] Use native undo registration for history/completion replacements.
- [x] Clear undo/redo at submitted/cancelled command boundaries.
- [x] Dismiss stale completion previews during undo/redo.
- [x] Forward surface actions to editable prompt after focus drift.
- [x] Disable editor undo/redo in fullscreen/raw program mode.
- [x] Test insertion, Unicode/multiline, selection, replacement and redo invalidation.
- [x] Test per-pane isolation, reset boundary and actual surface routing in isolated scratch PTY.
- [x] Run complete harness suite, lint and warning-free build.
- [x] Build/install without opening the application.
- [ ] User verifies shortcuts during typing/paste/completion/history and after submitting a command.

## 5R — catalogue completion audit

- [ ] Inventory actual syntax highlighting/command validation UI callers.
- [ ] Audit directory-color picker/model wiring; implement missing picker in current Settings.
- [ ] Audit theme creator and procedural background scope against #24.
- [ ] Audit modal keyboard requirements against #30; do not invent a new mode system.
- [ ] Document implemented/deferred items with code evidence and resource impact.
- [ ] Add missing catalogue requirements in separate small verified increments.

## 6A — process safety

- [ ] Query foreground process groups and descendants using native process APIs.
- [ ] Centralize policy for pane/tab/window/quit closure.
- [ ] Present native confirmation only for jobs that would be lost.
- [ ] Test shell-only, running jobs, nested panes and races with exit.

## 6B — durable local restoration

- [ ] Define SQLite layout/tab/pane/sealed-block schema and migrate current JSON.
- [ ] Keep pure DTOs in model and IO in service/store.
- [ ] Checkpoint changes with bounded background transactions, no per-cell writes.
- [ ] Persist bounded output/style/metadata and version migration rules.
- [ ] Restore historical output read-only and start fresh shells in original directories.
- [ ] Test crash during transaction, corrupt store and partial migration.
- [ ] Verify no restored command is executed automatically.

## 6C — undo closed panes/tabs

- [ ] Reuse persisted snapshots and safety policy.
- [ ] Track bounded close stack including layout insertion position.
- [ ] Restore context/output with new shell and clear expired entries.
- [ ] Test nested split removal, last tab closure and repeated undo-close.

## 6D — universal palette

- [ ] Reuse current fuzzy matcher and action catalogue.
- [ ] Add focused-context action dispatch and search scopes.
- [ ] Add shortcut/menu/Settings binding and keyboard navigation.
- [ ] Test unavailable actions, empty results, ordering and cancellation.

## 6E — search

- [ ] Unify scrollback/history/file results without copying complete history per query.
- [ ] Scope filesystem search and respect ignore rules/binary files.
- [ ] Reuse installed rg CLI first; document whether embedding is required.
- [ ] Bound results and cancel outdated background searches.
- [ ] Test large files, Unicode ranges, symlinks and inaccessible directories.

## 7A — launch configurations

- [ ] Define versioned config and validation using existing pane/layout models.
- [ ] Create named tabs/panes/directories/env without leaking credentials.
- [ ] Make startup commands explicit trusted configuration.
- [ ] Test malformed config, missing directory and partial launch failure.

## 7B — SSH bootstrapping (R1 basic implementation, see native-review-ssh.md)

- [x] Reuse system SSH and host-key/auth behavior.
- [x] Install existing remote shell hooks and handle unsupported shells.
- [x] Carry remote cwd/title/exit status without contaminating local state.
- [x] Bounded current-directory/PATH completion and original SSH command history.
- [ ] Complete nested SSH, attached/quoted options and remote child-directory completion.
- [ ] Test resize, reconnect/disconnect and raw fullscreen programs.

## 7C — terminal media

- [ ] Define bounded Kitty/iTerm2 parser payload and image placement model.
- [ ] Decode off-main with dimension/byte/cache caps.
- [ ] Reclaim images when blocks/session are evicted.
- [ ] Test malformed payloads, partial transport, resize and memory limits.

## 7D — notebooks

- [ ] Define Markdown cell persistence and map executed cells to blocks.
- [ ] Implement native editing, explicit execution and export.
- [ ] Keep commands read-only until deliberately run.
- [ ] Test notebook reopen, partial execution and cancellation.

## 7E — Git review (R1 local review, full #26 still partial)

- [x] Reuse project-root detection and cancellable system git commands.
- [x] Implement native file list/diff view with large-result limits.
- [x] Pinned diff chip, shared right-sidebar background/opacity and one-pixel separators.
- [x] File staging/unstaging, including unborn repository.
- [ ] Syntax/side-by-side view, hunk staging and GitHub PR reviews.
- [ ] Support safe file navigation and stale repository updates.
- [ ] Test binary files, renames and huge diffs.

## 7F — headless frontend

- [x] Specify explicit invocation and renderer/input boundary in headless-handoff.md.
- [ ] Reuse pure terminal/session models with no AppKit dependency.
- [ ] Add headless renderer and keyboard input mapping.
- [ ] Test terminal dimensions, nested terminal behavior and clean exit.

## C0 — immutable shared contracts (implemented)

- [x] Encode/decode the exact snapshot, damage, input and share structures.
- [x] Test all boundary sizes, malformed UTF-8/base64, UUIDs/decimal counters and grapheme widths.
- [x] Golden UTF-8 bytes hashed identically by Swift and Node.
- [x] Frame schema version mismatch fails closed; no implicit downgrade.
- [x] Explicit eviction and geometry/mode barriers cannot leave stale cells/blocks.
- [x] Publish fixtures and exports before downstream packages begin.
- [ ] B1A identity/database foundation (next; no code yet).

Gate result after audit: the Foundation-only harness passes 301 checks and the TypeScript validator check passes
94, over 3 goldens and 54 shared invalid cases. `Scripts/run-tests.sh` runs both halves. The
spellings and rules C0 had to freeze are recorded in wire-contract.md under "Frozen by C0".

## B1A — identity and database foundation (database half done)

- [x] Migration 000: four least-privilege roles, memberships, database `CREATE` grants, and
      assertions that none holds SUPERUSER/CREATEDB/CREATEROLE/BYPASSRLS.
- [x] Migration 001: eight tables derived from schema.sql, forced row-level security, policies.
- [x] Column-level grants: the API cannot read `token_sha256`, `csrf_sha256`, `registration_sha256`
      or `auth_issuer`; no DDL; snapshots have no `UPDATE`.
- [x] Fixed-search-path `SECURITY DEFINER` credential resolvers, owned by a role that cannot log in.
- [x] Transaction-local owner context on one checked-out pg client; no `pool.query` in a transaction.
- [x] `node:test` suites: 36 checks passing against live PostgreSQL 17 (roles + HTTP).
- [x] Idempotency proven by applying migration 001 twice.
- [x] OIDC token verification with `jose` against a fixed trusted JWKS, algorithms pinned.
- [x] Browser session cookie, CSRF companion cookie, logout revocation.
- [x] `GET /me`, `GET`/`POST`/`DELETE /devices`, session/logout/CSRF endpoints, `/healthz`.
- [x] Device registration idempotency and changed-payload 409.
- [ ] Resolver `search_path` abuse tests and log-redaction tests.
- [ ] Rollback policy and backup/restore drill.

Applied to Supabase project `upmarjiewuwvaljnnboq` (PostgreSQL 17.11, ap-south-1) via the pooler:
the direct `db.<ref>.supabase.co` host is IPv6-only and unreachable from this network.

## B1 — account/API/website foundation

- [ ] Select hosting/domain/OIDC provider and pin runtime/dependencies.
- [ ] Implement system-browser PKCE sign-in and Keychain storage.
- [ ] Map verified issuer/subject to accounts; bind native device credentials.
- [x] Turn SQL draft into numbered migration and exact production role grants.
- [ ] Test RLS as non-owner roles, cross-tenant FKs and pooled context isolation.
- [ ] Implement input byte limits, auth/CSRF/Origin checks and idempotency.
- [ ] Build website sign-in/download pages using same API/session.
- [ ] Restore database backup and exercise migration recovery.

## B2A — backend relay and control plane (implemented)

- [x] Session idempotency, immutable owner/device/pane association and open-stream limits.
- [x] Snapshot barriers, ordered replay, bounded ring/outbound queues and global admission budget.
- [x] `viewer.count` notification pauses native encoding at zero viewers; no terminal data in DB.
- [x] Relaying malformed data cannot allocate beyond admission limits.
- [x] Slow viewers cannot block host; disconnect/resync policy and incomplete snapshots tested.
- [x] Fake clock/socket tests: reconnect, stale publisher, lost lease renewal, end/revoke and DB outage.
- [x] Gate: viewer-only relay. B3 input frames rejected until B3A is complete.
- [ ] User acceptance of the deployed relay.

## B2 — selected-pane viewer

- [ ] Allocate stable stream pane UUIDs; do not reuse local numeric IDs across installs.
- [ ] Capture immutable bounded model state with watermark.
- [ ] Encode dirty-row/block deltas and alternate/size snapshot barriers.
- [ ] Keep capture/transport off PTY/parser path; allocate nothing while off.
- [x] Implement publisher lease/epoch and relay ticket admission. *(B2A: the relay half. The native publisher is B2B.)*
- [ ] Implement browser canvas + escaped block/editor rendering.
- [ ] Verify snapshot/delta parity for nano/tmux/wide text/IME/draft/collapse.
- [x] Test replay gaps, interrupted snapshots, slow viewers and host sleep. *(B2A: relay-side. Host sleep is B2B.)*
- [ ] End streams and revoke leases on pane close, shell exit, account logout and app shutdown.
- [ ] Measure native CPU/RSS/network with zero/one/multiple viewers.

## B3 — owner browser control

- [ ] Native visible opt-in and current controller indicator.
- [ ] One controller lease; local input revokes it first.
- [ ] Reuse prompt editor actions and raw TerminalInput translation.
- [ ] Bound input bytes/rate, preserve paste line endings and IME commits.
- [ ] Reject stale epoch/lease, duplicate/gapped sequences and viewer input.
- [ ] Ack admitted input without claiming command completion.
- [ ] Mark uncertain input on disconnect; never replay it automatically.
- [ ] Test reconnect/relay loss during Enter, Ctrl-C and paste.

## B4 — invitations and grants

- [ ] Specify private recipient discovery/invitation flow before implementation.
- [ ] Implement viewer/controller grants and host approval requirement.
- [ ] Revoke affected sockets/leases before acknowledging permission removal.
- [ ] Test account/device deactivation and access expiry on active sockets.

## B5 — static block shares

- [ ] Select sealed blocks and build immutable normalized DTO.
- [ ] Preview and redact before first content upload; server checks again.
- [ ] Publish snapshot/link/grants atomically with request hash idempotency.
- [ ] Client retains generated read secret through lost-response retries.
- [ ] Website escapes content and enforces bounded style spans/CSP/no-store.
- [ ] Implement restricted/unlisted resolve, expiry, revoke/delete and GC.
- [ ] Test cross-owner references, secrets, denied-read indistinguishability and XSS strings.

## B6 — scalable deployment

- [ ] Measure stated load targets; publish actual latency/RSS/bytes results.
- [ ] Route all session traffic/mutations consistently across replicas.
- [ ] Fence split publisher claims and fail closed on failed lease renewal.
- [ ] Test topology changes, DB outage, socket backpressure and process crashes.
- [ ] Budget connections/aggregate buffers and add metadata-only metrics/alerts.
- [ ] Confirm retention/privacy policy and incremental cleanup.

## B7 — conditional media storage

- [ ] Introduce private object metadata only when 7C/exports need it.
- [ ] Validate uploads before publish and collect orphaned objects.
- [ ] Serve through authorization when immediate revocation is required.

## Deferred

- [ ] Local IPC daemon/CLI (#27): do not implement in these phases.
- [ ] Simultaneous terminal writers, presence and full multiplayer: later explicit scope.
- [ ] Automatic masking of every live terminal cell: separate #14 phase.
- [ ] Session recordings, teams and public indexing: no requirement yet.

## C0 audit follow-up

- [x] Harden counter/transfer/Unicode/native bounds and static exports.
- [x] Preserve snapshot ordering, fullscreen invariants and aggregate byte bounds during damage.
- [x] Make TypeScript snapshot completion async with required hash verification.
- [x] Complete audit validation/install (build 116); see c0-audit.md.
