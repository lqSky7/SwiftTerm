# C0 implementation audit — 2026-09-30

## Actual status

Reviewed commit 01f1063 against implementation-handoff.md, protocol.md and wire-contract.md.
C0 supplies Swift/TypeScript DTO validators, canonical fixtures, snapshot assembly and a Swift
viewer-state reference. Native Git/SSH/sidebar work is already separate. No backend, numbered DB
migrations, OIDC/device auth, relay, native publisher, website, browser control or sharing service
exists. B1–B6 and H1–H4 are still handoffs. SQL is a draft; syntax checks do not establish RLS.

## Findings fixed

| Finding | Fix / regression |
| --- | --- |
| Swift damage base_seq at Int64.max overflows on +1 | reject exhaustion before arithmetic |
| Assembled snapshot can disagree with begin epoch/seq | validate payload and bind watermark in both assemblers |
| TypeScript digest callback optional; unchecked output returned | mandatory sync/async verifier, async finish must be awaited |
| Native begin/chunk values bypass decoded bounds; mutable JS chunks retained | validate begin before arithmetic/allocation, cap chunks, copy JS byte arrays |
| Older snapshot rolls back viewer epoch/seq | reject rollback before replacing state |
| Damage can expose fullscreen editor/add extra blocks or exceed 4 MiB retained state | reuse snapshot validator on candidate state before atomic commit |
| Native editor/span indices can overflow or index negative positions | validate before arithmetic/indexing; negative grid cursors rejected too |
| Swift JSONDecoder accepts alternate encodings; helper has no raw cap | bound raw JSON and require UTF-8 JSON; frame admission keeps tighter limit |
| JS accepts unpaired UTF-16 surrogates | reject before encoding/validation to match Swift scalar rules |
| Invalid dates normalize rather than reject | require exact date round-trip, including leap-day cases |
| Exports accept draft/running blocks and spans cutting emoji | sealed-only export and surrogate-boundary checks in both languages |

## Phase checklist

- [x] Inventory actual new files and runtime callers, compare contract/delegation boundaries.
- [x] Fix admission, overflow, ownership, ordering and export issues above.
- [x] Add Swift and Node regression checks without regenerating golden wire bytes.
- [x] Update contracts, per-directory indexes and future-client API guidance.
- [x] Full suite, clean Debug/release build and lint.
- [x] Signed commit and build/install without app launch.
- [ ] User acceptance of installed app; real streaming UX waits for B2/B3 runtime.

## Remaining boundaries

C0 is not proof of authorization, CSRF/Origin enforcement, controller fencing, PTY input safety,
replay correctness across sockets, reconnect behavior, or multi-replica scalability. There are no
runtime implementations to verify those claims. B1A must test actual non-owner DB roles, pooled
context isolation and migrations; B2A/B2B/B2C build capture/relay/browser rendering; B3A builds input.

WireStreamState validates/serializes candidate state for correctness. It is not used by the native
terminal or a browser hot path today. Measure costs in B2 and optimize touched-block validation
only while preserving every admission invariant; do not remove bounds to obtain throughput.

Raw WebSocket/HTTP bytes must be bounded before JSON.parse; TypeScript object validators cannot
undo an allocation a caller already made. Async assembly consumers must fence disconnect/epoch
changes after await before installing output. No live host/server/network tests or app launch.

## Verification

All 37 suite gates pass: 36 Swift harnesses plus the Node fixture gate. C0 now checks 301 Swift
and 94 Node assertions; the three golden byte files/digests and 54 shared invalid fixtures remain
unchanged. Debug/release compile without warnings. Lint passes with existing warnings. Build 116
is installed at `/Applications/swiftTerm.app`, signature verified, without opening the app.

Node tests execute stripped TypeScript. C0 does not configure a standalone tsc gate; B1 must pin
its strict TypeScript toolchain alongside runtime dependencies as the handoff specifies.
