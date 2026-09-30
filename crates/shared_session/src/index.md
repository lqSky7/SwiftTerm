# shared_session/src — index

The contract sources. Every file here is pure: Foundation only, no UI framework, no emulator
model. `Scripts/run-tests.sh --exec wire-contract-test` compiles this directory plus
`crates/cloud_objects/src` and nothing else, which is what keeps that true.

The DTOs reject unknown fields, unknown enum values, explicit nulls, duplicate ids, unsafe
integers, non-canonical UUIDs and base64, and out-of-bounds spans. A decoded value has already
been validated; there is no second pass a caller can forget.

See the directory above for what each file holds, and `docs/backend/wire-contract.md` for the
specification. Both DTO sets and the shared fixtures change together or not at all.

Audit hardening: UTF-8/raw-byte admission, overflow-safe counters, validated transfer metadata and
watermark binding. Viewer snapshots cannot regress epoch/seq; damage uses the snapshot validator
atomically, including fullscreen and aggregate byte limits. Native values receive bounds checks too.
