# Implementation packages — backend, website and remaining native work

Planning only. Implement exactly one package per assigned task, then test, sign the commit, build
and stop for user acceptance. Read index.md, architecture.md, protocol.md, wire-contract.md,
schema.sql, this file and the package's predecessor report. No agent has permission to expand its
file allowlist, change a wire field, provision a service or choose product policies silently.
Report a blocked prerequisite precisely; use a deterministic fixture for independent work.
Future agents are not running now. Native R1 is implemented; B1–B7 and headless are not.

## Fixed choices and boundaries

Backend: Node 24 LTS, TypeScript strict ESM, node:http, ws, pg, jose. Website: TypeScript + Vite,
DOM components and Canvas 2D; no React/UI framework or second VT emulator is needed for v1.
Pin exact current patches in a lockfile when implementing, with Node 24 in .node-version and
CI. No dependencies are installed in this planning phase. Validate support against
[Node releases](https://nodejs.org/en/about/previous-releases). The ws server sets maxPayload=65536,
perMessageDeflate=false, and explicit socket queue caps; compression adds memory/CPU costs per
[ws documentation](https://github.com/websockets/ws/blob/master/README.md). Each transaction uses
one checked-out pg client, never pool.query for transaction statements, as required by
[node-postgres](https://node-postgres.com/features/transactions).

One backend service and managed PostgreSQL, website assets served through the same HTTPS origin.
Start owner-only. The Mac owns every PTY; backend has no SSH credentials, shell runner or filesystem
API. No AI anywhere. No Redis/broker/Kubernetes, teams, billing, recordings, public indexing, live
secret masking or #27 daemon. Images, mouse reporting, browser PTY resizing and simultaneous
writers are not v1. Git patches/cwd/history are not automatically added to terminal streaming.
The native right/left sidebars never become website chrome embedded in the Mac app.

Deployment inputs required before production B1: HTTPS origin, managed PostgreSQL URL, OIDC issuer,
client IDs/audience, secret rotation keys, approved download manifest and retention policy approval.
These are configuration, not license to choose/provision a provider. Missing production inputs
fail startup; localhost fixtures are explicitly test-only and cannot enable production auth bypass.

Initial enforced limits: 5 open streams/account, 1/pane, 10 viewers/stream, 25 publishers/process;
4 MiB snapshot, 64 KiB wire frame, 8 MiB/30 sec replay/session, 1 MiB/socket pending bytes,
256 MiB aggregate relay buffers. Refuse new sessions at capacity; evict oldest replay data to
respect global cap and require snapshots for resulting gaps. Host coalesces output at <=30 fps.
Input: <=64 KiB UTF-8 per paste/text, <=120 operations/sec with burst 240, <=256 KiB pending
host input; reject before queueing. Backend input rejection is visible, never silently truncated.
These are initial limits, not measured throughput claims. No payload logging or persistent input queue.

## C0 — immutable shared contracts (first prerequisite)

Allowlist: crates/shared_session/src/**, crates/cloud_objects/src/**, contracts/**, protocol harnesses,
Package.swift source/exclude lists, Scripts/run-tests.sh, affected indexes/docs. No socket code/UI.
Implement wire-contract.md as Swift Codable/Sendable DTOs and TypeScript validators with shared
JSON fixtures. Reject unknown fields/enums, duplicate IDs, unsafe integers and out-of-bound spans.
Generate JSON Schema fixtures from these explicit DTOs; do not invent nullable/optional alternatives.
No references to mutable TerminalGrid/Block or NSTextView in transport DTOs.

- [ ] Encode/decode the exact snapshot, damage, input and share structures.
- [ ] Test all boundary sizes, malformed UTF-8/base64, UUIDs/decimal counters and grapheme widths.
- [ ] Golden UTF-8 bytes hashed identically by Swift and Node/browser.
- [ ] Frame schema version mismatch fails closed; no implicit downgrade.
- [ ] Explicit eviction and geometry/mode barriers cannot leave stale cells/blocks.
- [ ] Publish fixtures and exports before downstream packages begin.

Gate: direct Foundation-only harness and TypeScript validator fixtures pass. Contract changes need
one coordinated revision here before changing either native transport or browser rendering.

## B1A — identity and database foundation

Allowlist: backend/src/{auth,db,http}/**, backend/migrations/**, backend/test/**, backend package/CI
files, website/src/auth/** and website build shell, affected indexes/docs. No native parser/rendering.
Use node:test for service tests and a disposable PostgreSQL container, never a user's database.
Migration 001 derives from schema.sql; separate owner/migrator, api and narrow auth/grant resolver
roles. API has no BYPASSRLS/superuser/DDL; snapshots have INSERT/SELECT/DELETE, no UPDATE.

Website uses authorization code + PKCE/state via backend callback. OIDC issuer/audience/signature/
expiry/nonce are verified with jose and fixed trusted JWKS; never trust an unsigned client subject.
Create app_users by verified issuer/subject, via narrow identity provisioning function. Browser
session: random 256-bit secret, only SHA-256 in web_sessions, Secure HttpOnly SameSite=Lax cookie,
24-hour absolute expiry. Random CSRF token bound to that session; readable Secure SameSite=Lax companion cookie,
checked by digest + Origin against a write request header. Never accept only the cookie for CSRF.
Cookies/secrets are never returned in logs/URLs. Logout revokes web_session and its live sockets.

Native sign-in also uses system-browser PKCE; register a device with client-generated 32-byte
random device token, hash only in devices, plaintext retained in Keychain. Registration includes
client_request_id; identical retries return the existing device UUID, changed payload returns 409.
Device token is an opaque credential bound to the registered owner/device, not a claimed device ID.
Use dedicated fixed-search-path token/session resolution functions for pre-owner lookup; do not
turn off owner RLS or grant ordinary API unrestricted reads of credential hashes. Rate-limit failed
credential lookup before expensive work. Check account/device/session revocation during renewals.

- [ ] GET /me; POST/DELETE /devices; login/callback/logout/session/CSRF endpoints.
- [ ] Bound HTTP bodies, parameterize SQL, transaction-local owner context on one pg client.
- [ ] Real-role tests: A/B isolation, missing owner context, pooled reuse, revoked/expired tokens.
- [ ] Device registration concurrent retries and changed request conflict.
- [ ] Session/token resolver grants/search_path abuse tests and log redaction tests.
- [ ] Migration from empty DB + rollback policy + backup/restore drill; syntax-only check is insufficient.

Gate: no stub authentication enabled outside tests, no website access to DB/device tokens.

## B1B — native identity and website shell (depends B1A)

Allowlist: crates/cloud_object_client/src/**, app/src/account/**, app/src/AppCore.swift wiring,
app/Info.plist callback registration, auth harnesses; website/src/{auth,pages}/** and build files.
Native owns cancellable auth tasks and Keychain, supports sign-out/revoke without touching local
terminal state. Website pages: sign-in, download, owner session list and account/device management.
Download metadata is an approved versioned manifest, not an arbitrary URL fetched from user input.
Do not expose the local OS profile as a cloud identity. Gate cancellation, failed callback, nonce
replay, credential rotation, denied auth and an offline terminal with zero cloud work.

## B2A — backend relay and control plane (depends C0/B1A)

Allowlist: backend/src/shared_session/**, its HTTP routes/tests and metadata migrations explicitly
required by schema; no native capture or browser rendering. Implement protocol.md live creation,
tickets/end/list. One-use tickets are relay-memory hashes, expire in 30 sec, consumed atomically;
never accept a browser as publisher. Host admission/renew/release uses DB epoch+lease comparisons.
Issue auth within 5 sec, heartbeat 15/30 sec, publisher lease 10/30 sec. Ended sessions stay ended.

- [ ] Session idempotency, immutable owner/device/pane association and open-stream limits.
- [ ] Snapshot barriers, ordered replay, bounded ring/outbound queues and global admission budget.
- [ ] viewer.count notification pauses native encoding at zero viewers; no terminal data in DB.
- [ ] Relaying malformed data cannot allocate beyond admission limits.
- [ ] Slow viewers cannot block host; disconnect/resync policy and incomplete snapshots tested.
- [ ] Fake clock/socket tests: reconnect, stale publisher, lost lease renewal, end/revoke and DB outage.

Gate: viewer-only relay. B3 input frames must be rejected until B3A is complete.

## B2B — native selected-pane publisher (depends C0/B1B/B2A)

Allowlist: app/src/terminal/shared_session/**, crates/shared_session/src/** transport-independent
capture helpers, crates/cloud_object_client/src/**, AppCore wiring and native harnesses. Dirty-row
hooks in core are allowed only to expose bounded immutable state; no networking inside parser/draw.
Allocate stable export UUIDs, not numeric PaneID/BlockID. One explicit native start/stop action.
Capture consistent watermark+bounded rows on MainActor, encode/hash/send off-main. Own encoder/
socket tasks; stop on pane close/shell exit/sign-out/app exit. No capture allocation while off.

Gate: offscreen scratch PTY parity for blocks/draft/collapse/resize/alternate/wide glyphs; no live
content upload before explicit start. Slow relay/sleep/offline cannot delay typing/PTY reads.
Measure idle vs sharing-off vs one viewer CPU/RSS/bytes; document actual figures, not estimates.

## B2C — website live viewer (depends C0/B1A/B2A; use fixtures until B2B)

Allowlist: website/src/shared_session/**, website/test/**, website pages/routes/CSP. State reducer
accepts exactly one epoch and contiguous seq; bounded snapshot scratch buffer verified before atomic
swap. Canvas owns grid rendering, DOM textContent owns escaped block/header/error text. Recycle
visible block/grid rows; viewport scaling does not resize host PTY. Handle palette/cell widths and
UTF-16 draft selection; no innerHTML, OSC execution, terminal subprocess or second VT parser.

Gate: screenshot/golden-cell equivalence for fixtures, replay gaps, mode/geometry transitions,
Unicode, malformed frames, XSS strings, huge snapshots, slow consumer and reconnect. Accessible
connection/control status, keyboard navigation and local copy remain usable without input rights.

## B3A — owner-only control (depends all B2 packages)

Allowlist: backend/src/shared_session/**, native shared_session/** and terminal input adapter,
website/src/shared_session/**, control tests. Native approves one browser connection explicitly;
local input revokes lease first. Host rechecks epoch/lease/seq then routes prompt actions to editor
and raw actions to TerminalInput. Send one admission ack, never shell-success/completion claims.
Text/paste/IME/undo route to the same paths as native. No raw bytes/command API or automatic retry.

Gate: duplicate/gapped/stale/viewer input, revoke-vs-Enter race, local takeover, lost ack during
paste/Enter/Ctrl-C, relay loss and host sleep. Unacked input becomes visibly uncertain and is never
replayed after reconnect. Fullscreen key/paste fidelity and draft undo isolation remain mandatory.

## B4A — invitations (depends B3A)

Allowlist: backend/src/{auth,shared_session,sharing}/**, website account/grant UI and native control
approval UI. Invite by opaque code for a known account; no public email/user enumeration. Only
owner creates/revokes grants; permission alone never grants current control. Native approval still
required. Commit explicit invitation expiry/recipient verification before implementation.
Gate: revoke closes affected sockets/leases before successful response, all devices/replicas fenced,
recipient role changes and deactivated accounts tested. No concurrent writers/presence in B4.

## B5A/B5B — static shares (independent after C0/B1)

B5A owner: crates/secret_redaction/src/**, crates/cloud_objects/src/** and app/src/cloud_object/**.
Select sealed blocks only, normalize/redact locally, preview editable redactions before first upload.
Allowlisted style spans, omit absolute cwd by default, reject controls/OSC/image blobs. Treat masking
as export processing, not live #14 implementation. Keep read secret through lost-response retries.
B5B owner: backend/src/sharing/** + website/src/sharing/** + share tests. Publish snapshot/link/grants
atomically, constant-time capability digest checks, uniform denied 404, no-store and CSP; hash in
fragment, never query/path/server logs. Immutable content, owner revoke/delete and bounded GC.
Gate: known secret fixtures, XSS/control strings, cross-owner FK, idempotency conflict/lost response,
expiry/revoke/cache invalidation and concurrent cleanup. No email dispatch or object storage yet.

## B6A — measured deployment (after B2/B3 and actual demand)

Allowlist: backend deploy/observability/load tests and session routing changes, deployment docs.
No infrastructure provisioning without user-supplied deployment inputs. Measure initial target
25 publishers x 10 viewers with bursty TUIs; report p95 output/ack latency, CPU/RSS and queue depth.
Enforce limits before claiming capacity. Add replicas only with session-key consistent routing for
both HTTP mutations and sockets; topology changes close/reconnect and fence old epochs. No blind
broadcast/pubsub replacement. Test DB outage, process crash, split publisher claim, failed revoke
and backup restore. Metrics hold IDs/counts/timing only, never terminal text, filenames or inputs.
Retention: ended session metadata 7 days; live expiry 24 hours; unlisted share default 7 days,
restricted default 30 days; orphan snapshots 24 hours grace. Index-backed bounded cleanup batches.
B7 object storage stays conditional on a shipped media/export requirement.

## Native follow-ups (not included in R1)

N-GIT2 allowlist app/src/code_review/** + crates/git/**: syntax colors/side-by-side, then hunk staging
using exact patch context and repository generation fencing. Test partially staged hunks, CRLF,
renames, conflicts, cancellation and changes during stage. Never reset a worktree to unstage.
N-GIT3: GitHub reviews/comments only after an explicit account/auth phase, narrow PR scopes and
provider contract; no token discovery from shell env or ambient credentials. Never auto-publish comments.
N-SSH2 allowlist bootstrap/** + relevant core/completion models: nested SSH, quoted/attached options,
remote child-path completion, remote metadata/actions. Negotiate protocol, cap work and preserve
normal SSH bypass. Actual remote host/auth/TUI testing is a gate. Do not add a generic command tunnel.
Headless packages H1–H4 are specified separately in headless-handoff.md.

## WEB-GIT1 — optional website review parity after B2

Separate protocol revision, not a widening of live v1. Allowlist native code_review adapter,
shared review DTO crate, website/src/code_review/** and backend opaque relay routes. A native owner
explicitly exposes one local repository by random repo UUID + monotonic review generation; never
accept a browser path/root/shell string. Read-only requests select known file IDs from a bounded
summary and fetch one <=4.375 MB/50,000-row patch. At most one outstanding request/browser, 10-second
request timeout, viewer revocation clears caches. Reuse native GitRepositoryService bounds and
virtualized website rows. Backend relays bounded payloads and never stores patches/cwd by default.
Web file/hunk mutations require a later explicit authorization/confirmation contract plus B3 lease;
controller status alone is not permission to stage arbitrary files. Gate repo switching, stale file
IDs, traversal strings, large/binary/non-UTF-8 paths, revocation and slow request cancellation.
No web GitHub credentials/comments until N-GIT3 and provider permissions are specified.

## Mandatory agent completion report

Package ID + implemented behavior; exact changed files; test commands/results; size/latency/RSS
measurements where required; signed commit ID; built/installed artifact and whether launched;
remaining gaps and next prerequisite. Update todo/index/feature-status, don't tick runtime boxes
for documentation. Never start another package just because a preceding one compiled.
