# Web terminal protocol v1

Planning contract, not a running API. wire-contract.md fixes exact DTOs and validation limits;
implementation-handoff.md fixes package ownership and auth/session credential lifecycle. All HTTP endpoints are under `/v1`. UUID IDs and sequence
counters are strings in JSON (avoid JavaScript integer precision loss). Errors are JSON
`{ "code": "...", "request_id": "..." }`, never raw terminal text or stack traces.

## HTTP control plane

| Method/path | Contract |
| --- | --- |
| `POST /auth/logout` | revoke current web session and close its sockets |
| `GET /me` | verified account and registered devices |
| `POST /devices` | register installation with client_request_id and client-generated device token; return UUID |
| `DELETE /devices/:id` | revoke device, end streams and close its sockets |
| `POST /live` | owner/device, stable pane UUID, request UUID and title; create paused session |
| `GET /live` | owner's sessions, keyset page by `(created_at,id)`; default 50, max 100 |
| `POST /live/:id/tickets` | role-specific one-use socket ticket; reject unauthorized users |
| `POST /live/:id/grants` | owner grants viewer/controller to a known account, later phase |
| `DELETE /live/:id/grants/:user` | revoke access and affected controller/socket |
| `POST /live/:id/end` | idempotently stop and fence session; owner only |
| `POST /shares` | publish reviewed redacted snapshot + metadata + recipient grants atomically |
| `GET /shares` | owner's links, bounded keyset pagination |
| `POST /shares/:id/revoke` | idempotent owner revoke |
| `DELETE /shares/:id` | delete link; collect unreferenced snapshot |
| `POST /shares/resolve` | locator + read secret; restricted link additionally needs signed-in recipient |

Assign a stable stream UUID to a pane when sharing starts; current numeric PaneIDs are local
identities and cannot be used as globally persistent pane IDs.

Native device credentials are random 256-bit secrets generated once by the client and stored in
Keychain; only token_sha256 is stored in devices. web_sessions stores browser token/CSRF digests
and expiry/revocation. Narrow credential resolvers authenticate before owner-scoped RLS access.
Native tokens bind a verified registered device. A claimed device UUID alone is not authentication.
Website session cookies require CSRF protection on writes. Content is excluded from logs.
Never accept `owner_id` from request JSON. With verified account context:

```sql
BEGIN;
SELECT set_config('swiftterm.user_id', $1, true);
-- Parameterized ownership-scoped reads/writes here.
COMMIT;
```

Create endpoints use `(owner_id,client_request_id)` with SHA-256 of canonical validated request.
Same request returns the same session/share; different payload with reused ID returns 409.
Lock account row for admission limits, and check idempotency before conflict checks. Insert new
snapshot/link/grants in one transaction so duplicate retries do not leave orphan snapshots.
Share secret is generated on the client once, sent on create, hashed by server and not persisted
in cleartext. Response gives locator, not a new unrecoverable secret. Recipient resolution must
not expose a public directory of emails/accounts.

## WebSocket admission and fencing

Connect `wss://<service>/live/<session_uuid>` using subprotocol `swiftterm.live.v1`.
The exact same path key routes host and browsers to the same relay instance. HTTP mutations
concerning that live session must use that routing key too. First small frame within 5 seconds:

```json
{"type":"auth","ticket":"one-use-opaque-ticket","client_id":"browser-uuid"}
```

Ticket issuance/exchange checks account/device status, session expiry, role and grant; a publisher
must be the session's registered device. Ticket hashes expire after 30 seconds in relay memory.
After relay failure, fetch a new ticket; do not reuse old tickets across instances. Reject extra
frames before auth and reject cross-site Origin upgrades. Viewer is read-only by default.

Publisher admission locks `live_sessions`. Refuse ended/expired/revoked sessions and any unexpired
publisher lease. A controlled reconnect can release the old lease after closing its socket;
otherwise wait for expiry. Atomically increment publisher epoch and install a random lease token,
30-second expiry and `live` status. Every renewal compares epoch + token and verifies auth/device
status. Renew every 10 seconds; relay fails closed before expiry if DB renewal is unavailable.
Stale publisher generations cannot write or admit inputs. On disconnect clear lease to `paused`
only if the token still matches. Ending/revoking clears lease, increments epoch, closes sockets
and sets ended status/timestamp. Never resurrect ended sessions.

A new publisher connection also starts a fresh local input epoch and revokes controller leases,
regardless of whether the former relay is reachable. This is the host-side fence against stale input.

## Output state and replay

```json
{"type":"hello","version":1,"session_id":"uuid","epoch":"4","mode":"blocks","columns":2,"rows":32}
```

Then send a snapshot with `snapshot.begin`, ordered `snapshot.chunk` frames and `snapshot.end`.
Serialized chunks are at most 64 KiB (45 KiB raw bytes), and total snapshot at most 4 MiB; include total bytes/count and SHA-256.
Snapshot describes one consistent state through sequence S. Buffer deltas above S until snapshot
finishes. Native captures immutable state + watermark together; output continues locally without
waiting for transfer. Browser assembles and verifies in bounded scratch memory, swaps atomically,
then applies consecutive deltas. Discard incomplete snapshots on reconnect.

The DTO includes version, epoch/S, palette, viewport, primary/alternate mode, bounded visible/recent
blocks, each block's stable export UUID/header/collapsed state/grid rows, cursor visibility/style,
and the active editor text/UTF-16 selection. Cells hold grapheme, width (0 continuation/1/2) and a bounded style-table index;
styles hold palette/RGB colors. The browser treats all text as data, never terminal commands or HTML.
Omit active external links, local environment and full path history. Closed blocks outside the
window are evicted with explicit IDs. Later archived output uses static sharing.

```json
{"type":"damage","epoch":"4","seq":"19","base_seq":"18","changes":[{"op":"replace_row","block_id":"uuid","grid":"output","row":2,"cells":[{"text":"x","width":1,"style":0},{"text":" ","width":1,"style":0}]}]}
```

Operations: block insert/remove/header/collapse, row replacement, cursor change and editor replace.
Size/alternate-screen transitions require a fresh snapshot barrier. Do not apply row coordinates
across a geometry change. The stream begins with a snapshot even when the host already has output.

Browser applies only consecutive sequences within one epoch and deduplicates already applied IDs.
After reconnect, request `resume` with epoch and last applied sequence. Relay replays from its ring
if retained, otherwise requests a snapshot. It serializes replay and new frames for that socket;
no interleaving that skips output. A new epoch always resets state using a snapshot.
Ring limit: 8 MiB or 30 seconds per session. Viewer sends applied-sequence acknowledgements; relay
never treats network send as rendered. If a socket exceeds 1 MiB pending bytes, request resync or
close it. Slow readers cannot block the publisher. Ping every 15 seconds; terminate unresponsive
connections after 30 seconds. Exponential reconnect backoff with jitter capped at 30 seconds.

## Browser input

A browser requests control; native host approves and returns a random lease ID, bound to the
current publisher epoch and that browser connection. Initial lease expires after 30 seconds,
renewed only while host approval, grant and connection remain valid. One holder at a time.
Every local user input revokes the remote lease first. Viewing remains allowed after lease loss.

```json
{"type":"input","epoch":"4","control_lease":"uuid","input_seq":"7","operation":{"kind":"key","key":"Enter","modifiers":[]}}
```

Allowed operations: `text`, logical `key`, explicit `paste`, and prompt-editor undo/redo.
No arbitrary raw escape bytes, filesystem operations, API-driven command execution or browser
PTY resize in v1. Mouse reporting can follow after coordinate mapping tests; initially web viewer
selection is local and does not send mouse events. Frame/input payload maximum 64 KiB; paste cap
64 KiB in v1 (reject oversize before allocation). Limit input rate and aggregate queued bytes.

Host rechecks lease/epoch and serializes input on the same action path as local input. In a prompt,
use NSTextView editing/submission semantics; in raw/TUI mode translate logical keys and paste
through existing TerminalInput rules. IME sends committed text only. Control-C remains a terminal
signal. Read-only viewers cannot acquire control by forging input frames.

```json
{"type":"input.ack","epoch":"4","control_lease":"uuid","input_seq":"7","status":"applied"}
```

Per lease, accept the next input sequence only; retain the last applied cursor to reject duplicates.
An ack can be resent for a duplicate within that still-valid lease, without reapplying input.
Sequence gaps are rejected. Ack records admission to editor/PTY write queue, not shell completion.
Do not retry timed-out/unacknowledged input automatically; surface uncertainty and reconnect for a
new lease. Relay restart, host reconnect or local keyboard takeover makes old input unusable.
No durable input queue, no speculative exactly-once effects, no keyboard replay after host sleep.

## Invitations and grants

A live session is visible to its owner and to nobody else until the owner grants access. A grant is
created by redeeming an **invitation**, which is the only way in: there is no directory, no search
and no way to ask whether an account exists.

```json
{"type":"live.invitation","session_id":"uuid","recipient_user_id":"uuid","permission":"viewer","expires_in_hours":168,"code":"base64url-43"}
```

The code is 32 random bytes, base64url without padding, and the server stores **only its SHA-256**.
It is returned exactly once, in the response that creates it, and is never recoverable afterwards —
a lost response means minting another, which is cheaper than a recoverable capability.

**Recipient verification, committed here because the alternative is a bearer token.** An invitation
is minted *for a specific account*, and redeeming it requires being signed in **as that account**.
Possession of the code is not sufficient and is not intended to be: a code that leaks to a third
party grants nothing, because the third party is not the recipient. This is what makes an invitation
safe to send over a channel the server does not control.

**Expiry, committed here for the same reason.** Seven days by default, thirty maximum, and the
deadline is **absolute** — redeeming never extends it. A capability with no deadline is a capability
nobody can withdraw; a deadline that moves with use is one that never arrives.

**One redemption.** `redeemed_at` is set once. A second redemption of the same code by the same
recipient returns the grant that already exists rather than failing, because the first response may
have been lost in transit and "already redeemed" is not an error the recipient can act on.

**Permission is a ceiling, never control.** `viewer` or `controller`. A `controller` grant does not
grant *current* control: the host still approves each browser, the lease is still bound to one
connection, and local input still revokes it first. The grant says what may be asked for; the person
in front of the machine says what is given.

**Only the owner creates and revokes.** The one exception is that a recipient may revoke **their own**
grant — leaving is a reduction of access, and requiring the owner to do it would mean access that
cannot be given up without asking.

**Revocation fences before it answers.** Revoking a grant closes that recipient's sockets and ends
their control lease *before* the response is sent, so a caller who has been told the access is gone
cannot still be watching. A revocation that answered first and disconnected afterwards would leave a
window in which the answer and the state disagree.

**No enumeration.** An invitation names a recipient by account id and the API never accepts an email,
a display name or a search term. Minting for an account that does not exist fails the foreign key,
which is reported as the same generic refusal as any other bad request.

## Static sharing DTO

```json
{"client_request_id":"uuid","read_secret":"base64url-32-random-bytes","access_mode":"restricted","recipient_user_ids":["uuid"],"snapshot":{"schema_version":1,"blocks":[{"id":"uuid","command":"ls","directory":"~/project","exit_code":0,"duration_ms":12,"lines":[{"text":"file.txt","styles":[]}]}],"styles":[{"fg":{"kind":"palette","index":7},"bg":{"kind":"palette","index":0},"flags":0}]}}
```

Only sanitized sealed blocks; 20 blocks / 2 MiB encoded JSON. Source IDs are globally allocated
export UUIDs, not reused local numeric BlockIDs. JSON style spans must be bounded, ordered and
within UTF-16 text length. Reject raw ESC/control strings and unsupported schema versions.
Snapshot is immutable: API role gets no UPDATE privilege on `block_snapshots`; editing an export
creates a new snapshot/link. Delete cascades links/grants; UI must identify affected links.
Capability compare uses constant-time digest comparison. Restricted share owner may resolve
through authenticated management routes without a capability; anonymous resolve always needs it.
All resolve responses are private/no-store. Revoked/expired/denied/missing returns the same 404.

### Resolving a share

```json
{"locator":"uuid","read_secret":"base64url-43"}
```

The link a person receives carries the locator in the **path** and the secret in the **fragment**:

```
https://…/s/<locator>#<read_secret>
```

The fragment is not sent to the server, which is the whole reason it is there. The page reads it,
posts it once to resolve, then **removes it with `replaceState`** and keeps it in memory only — never
`localStorage`, never a service worker cache, never the URL bar of the next person who looks over a
shoulder. The server never sees a fragment, so a secret cannot appear in an access log, a `Referer`
or a reverse proxy's request line.

`access_mode` decides what else is needed. `link` resolves on the capability alone. `restricted`
needs the capability **and** an approved account named in `share_grants` — an account alone is not
enough, and a capability alone is not enough. The owner may resolve their own share through an
authenticated management route without the capability, because the alternative is an owner locked
out of their own export.

Every resolve answers `404` when it cannot succeed — revoked, expired, denied, missing, or a
capability that does not match. One answer for all of them, because distinguishing them is an oracle
for which locators exist. The comparison is constant-time over the digest.

## Database and protocol acceptance gates

DDL guarantees cross-owner foreign keys, owner-scoped idempotency, one open stream per pane,
basic lifecycle/lease consistency, bounded snapshot JSON and forced owner RLS. Service code
must guarantee monotonic epochs, lease comparisons, permission checks, state transitions,
request hash stability, canonical DTO validation, immutable exports and socket revocation.

Before B1/B2/B3 release, run actual PostgreSQL integration tests as non-owner application roles:

- Account A cannot read/update B's rows or attach its device/grants/exports to B's parents.
- Missing auth context denies access; transaction pooling does not retain the previous account.
- Concurrent publisher claims admit one lease; stale-token renew/release/input fail.
- Same idempotency key/payload returns same result; different payload returns conflict.
- Snapshot + link + grants publish atomically; caller cannot update existing snapshots.
- Revoke/expiry/device deletion ends active input and denies future socket/share admission.
- Lost frames/resume overflow/size changes reconstruct exactly the current bounded host state.
- Lost input ack never causes duplicate command submission after reconnect.

No actual DB server has been provisioned in B0. Syntax parsing is not proof that these runtime
constraints, permissions and transaction invariants pass.
