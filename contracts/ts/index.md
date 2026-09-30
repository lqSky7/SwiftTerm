# contracts/ts — index

The TypeScript half of the wire contract.

`wire.ts` is the validator set: limits, `ContractError` with its allowlisted code, the primitive
readers, every DTO validator, the frame direction table, and `SnapshotAssembler`. It imports
nothing, so it loads unchanged in Node, in a browser and in a bundler.

Two things about it are deliberate and easy to get wrong on a later edit:

- **It has no `node:` import and no SHA-256.** The only browser SHA-256 is `crypto.subtle`, which
  is asynchronous, so `SnapshotAssembler.finish` is async and requires a digest callback returning
  a string or Promise<string>. Always await it. It verifies the digest and decoded snapshot's
  epoch/seq against snapshot.begin before returning bytes; unchecked bytes are never returned.
- **The validated shapes are the wire shapes.** Fields keep their snake_case names so that
  re-serialising a validated value reproduces the bytes on the wire. The relay forwards frames
  verbatim and the browser consumes them, so a camelCase convenience layer here would be a second
  place for the two to drift.

`check-fixtures.ts` is the checker. It uses `node:crypto` for SHA-256 and is Node-only. Run it
directly — Node strips the types, so there is no build step:

```sh
node contracts/ts/check-fixtures.ts
```

Audit regressions cover mandatory async hash verification, watermark binding, owned chunk bytes,
chunk/metadata limits, exhausted counters, UTF-16 scalar validity, strict dates and sealed exports.
