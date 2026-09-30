# contracts — index

The wire contract, in two independent implementations and one shared set of fixtures. Nothing here
is shipped to a user; it is the thing that stops the native publisher, the relay and the browser
viewer from disagreeing about what a frame means.

| Path | Holds |
| --- | --- |
| `ts/wire.ts` | the TypeScript validators — dependency-free and free of any `node:` import, so the relay, a test and the website viewer all load the same file |
| `ts/check-fixtures.ts` | the Node half of the C0 gate: replays the goldens and every invalid case |
| `fixtures/golden/` | canonical snapshot and share bytes, plus `SHA256SUMS` |
| `fixtures/invalid.json` | 54 cases both implementations must reject with the same allowlisted code |

## Running the gate

```sh
Scripts/run-tests.sh              # every harness, then this contract check
node contracts/ts/check-fixtures.ts   # just the Node half
```

`Scripts/run-tests.sh` runs the Node half automatically when `node` is on `PATH`, because a
Swift-only run cannot notice the other half drifting.

Node strips the types directly — there is no build step and no lockfile here. That is deliberate:
the contract is not a package, and a second toolchain in the build path would be one more thing
that can fail between a change and the test that catches it.

## What the gate actually asserts

1. **Both sides hash the same bytes.** Swift writes the goldens and records their SHA-256 in
   `SHA256SUMS`; Node computes its own SHA-256 over the same files and compares. Two independent
   implementations, one digest.
2. **Both sides serialise identically.** Node parses each golden and re-serialises it with sorted
   keys; the bytes must be identical to the file on disk. This is what makes the contract's
   "deterministic sorted-key JSON" a fact rather than a convention.
3. **Both sides reject the same cases.** Every entry in `invalid.json` must be refused with the
   named allowlisted code by the Swift harness *and* by the TypeScript validator.
4. **Both sides validate the same documents.** The goldens pass the TypeScript validators, not
   merely `JSON.parse`.

## Changing the contract

`docs/backend/wire-contract.md` is the specification. A wire change is one coordinated revision:
the spec, both DTO sets, the fixtures and the goldens move together. Regenerate the goldens
deliberately —

```sh
swiftc -swift-version 6 -warnings-as-errors \
    crates/shared_session/src/*.swift crates/cloud_objects/src/*.swift \
    Tests/wire-contract-test.swift -o /tmp/wire-contract-test
/tmp/wire-contract-test --write-fixtures
```

— and read the diff. A regenerated golden is a change to the bytes on the wire, and it should be
reviewed as one.
