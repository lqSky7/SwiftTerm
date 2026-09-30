/**
 * The C0 cross-language gate.
 *
 * Swift writes `contracts/fixtures`. This script is the other independent implementation: it
 * re-validates the goldens with the TypeScript validators, re-serialises them and demands the
 * bytes are identical, hashes them with Node's own SHA-256 and compares against the digests the
 * Swift harness recorded, and then replays every case in `invalid.json` expecting the same
 * allowlisted rejection code.
 *
 * Run it directly — Node strips the types, so there is no build step:
 *
 *     node contracts/ts/check-fixtures.ts
 *
 * A disagreement here means the Swift and TypeScript halves of the contract have drifted, which
 * is exactly the failure that would otherwise surface as a browser rendering a frame the host
 * thought it had rejected.
 */

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  ContractError,
  SnapshotAssembler,
  base64Encode,
  canonicalStringify,
  validateDamage,
  validateFrame,
  validateInputFrame,
  validateShareSnapshot,
  validateSnapshot,
  type Direction,
  type ErrorCode,
} from "./wire.ts";

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, "..", "fixtures");
const golden = join(fixtures, "golden");

const failures: string[] = [];
let checks = 0;

function expect(condition: boolean, message: string): void {
  checks += 1;
  if (!condition) failures.push(message);
}

function rejects(label: string, expected: ErrorCode, body: () => void): void {
  checks += 1;
  try {
    body();
    failures.push(`${label}: expected ${expected}, nothing thrown`);
  } catch (error) {
    if (error instanceof ContractError) {
      if (error.code !== expected) {
        failures.push(`${label}: expected ${expected}, got ${error.code} — ${error.message}`);
      }
      return;
    }
    failures.push(`${label}: unexpected error ${String(error)}`);
  }
}

function accepts(label: string, body: () => void): void {
  checks += 1;
  try {
    body();
  } catch (error) {
    failures.push(`${label}: rejected (${String(error)})`);
  }
}

const sha256Hex = (bytes: Uint8Array): string =>
  createHash("sha256").update(bytes).digest("hex");

const bytesOf = (path: string): Uint8Array => new Uint8Array(readFileSync(path));
const textOf = (path: string): string => readFileSync(path, "utf8");

// MARK: - 1. Golden bytes: identical serialisation and identical digest

const goldenValidators: Record<string, (value: unknown) => unknown> = {
  "snapshot-blocks.json": validateSnapshot,
  "snapshot-fullscreen.json": validateSnapshot,
  "share.json": validateShareSnapshot,
};

const recordedSums = new Map<string, string>();
for (const line of textOf(join(golden, "SHA256SUMS")).trim().split("\n")) {
  const [digest, name] = line.split(/\s+/);
  recordedSums.set(name, digest);
}
expect(recordedSums.size === Object.keys(goldenValidators).length, "SHA256SUMS lists every golden");

for (const [name, validate] of Object.entries(goldenValidators)) {
  const bytes = bytesOf(join(golden, name));
  const raw = textOf(join(golden, name));

  // Same digest, computed independently by Node's SHA-256 and by the Swift harness.
  const digest = sha256Hex(bytes);
  expect(
    digest === recordedSums.get(name),
    `${name}: Node digest ${digest} != recorded ${recordedSums.get(name)}`,
  );

  // The golden is canonical: parsing and re-serialising with sorted keys reproduces the bytes.
  const parsed = JSON.parse(raw) as unknown;
  expect(
    canonicalStringify(parsed) === raw,
    `${name}: canonical re-serialisation differs from the golden bytes`,
  );

  // And it is valid under the TypeScript rules, not merely well-formed JSON.
  accepts(`${name} validates`, () => {
    validate(parsed);
  });

  // Determinism: serialising the validated value twice gives the same bytes.
  const validated = validate(parsed);
  expect(
    canonicalStringify(validated) === raw,
    `${name}: validated value re-serialises differently`,
  );
}

// MARK: - 2. Invalid fixtures: both implementations reject the same things

interface InvalidCase {
  name: string;
  kind: string;
  expected: ErrorCode;
  payload: string;
  direction?: Direction;
}

const invalidIndex = JSON.parse(textOf(join(fixtures, "invalid.json"))) as {
  version: number;
  cases: InvalidCase[];
};

expect(invalidIndex.version === 1, "invalid.json schema version");
expect(invalidIndex.cases.length > 0, "invalid.json carries cases");

const columnsForGeometry = 80;

for (const testCase of invalidIndex.cases) {
  rejects(testCase.name, testCase.expected, () => {
    const payload = JSON.parse(testCase.payload) as unknown;
    switch (testCase.kind) {
      case "snapshot":
        validateSnapshot(payload);
        return;
      case "damage":
        validateDamage(payload, columnsForGeometry);
        return;
      case "input":
        validateInputFrame(payload);
        return;
      case "share":
        validateShareSnapshot(payload);
        return;
      case "frame":
        validateFrame(payload, testCase.direction ?? "host_to_relay", columnsForGeometry);
        return;
      default:
        throw new Error(`unknown fixture kind ${testCase.kind}`);
    }
  });
}

// MARK: - 3. Snapshot assembly with a real digest

const snapshotBytes = bytesOf(join(golden, "snapshot-blocks.json"));
const chunkSize = 45 * 1024;
const chunkCount = Math.max(1, Math.ceil(snapshotBytes.length / chunkSize));
const snapshotID = "44444444-4444-4444-8444-444444444444";

function assemble(
  mutate?: (frame: Record<string, unknown>, index: number) => Record<string, unknown>,
): Uint8Array {
  const assembler = new SnapshotAssembler();
  assembler.begin({
    epoch: "1",
    seq: "0",
    snapshot_id: snapshotID,
    bytes: snapshotBytes.length,
    chunks: chunkCount,
    sha256: sha256Hex(snapshotBytes),
  });
  for (let index = 0; index < chunkCount; index += 1) {
    const slice = snapshotBytes.subarray(index * chunkSize, (index + 1) * chunkSize);
    const frame: Record<string, unknown> = {
      epoch: "1",
      snapshot_id: snapshotID,
      index,
      data: base64Encode(slice),
    };
    assembler.append(mutate ? mutate(frame, index) : frame);
  }
  return assembler.finish({ epoch: "1", snapshot_id: snapshotID }, sha256Hex);
}

accepts("chunked snapshot assembles", () => {
  const assembled = assemble();
  expect(
    Buffer.compare(Buffer.from(assembled), Buffer.from(snapshotBytes)) === 0,
    "assembled bytes differ from the golden snapshot",
  );
});

rejects("chunk from another snapshot", "resync_required", () => {
  assemble((frame, index) => (index === 0 ? { ...frame, snapshot_id: "9".repeat(8) + "-1111-4111-8111-111111111111" } : frame));
});

rejects("chunk out of order", "resync_required", () => {
  assemble((frame, index) => (index === 0 ? { ...frame, index: 5 } : frame));
});

rejects("digest mismatch", "resync_required", () => {
  const assembler = new SnapshotAssembler();
  assembler.begin({
    epoch: "1",
    seq: "0",
    snapshot_id: snapshotID,
    bytes: snapshotBytes.length,
    chunks: chunkCount,
    sha256: "0".repeat(64),
  });
  for (let index = 0; index < chunkCount; index += 1) {
    assembler.append({
      epoch: "1",
      snapshot_id: snapshotID,
      index,
      data: base64Encode(snapshotBytes.subarray(index * chunkSize, (index + 1) * chunkSize)),
    });
  }
  assembler.finish({ epoch: "1", snapshot_id: snapshotID }, sha256Hex);
});

rejects("end without all chunks", "resync_required", () => {
  const assembler = new SnapshotAssembler();
  assembler.begin({
    epoch: "1",
    seq: "0",
    snapshot_id: snapshotID,
    bytes: snapshotBytes.length,
    chunks: 2,
    sha256: sha256Hex(snapshotBytes),
  });
  assembler.finish({ epoch: "1", snapshot_id: snapshotID }, sha256Hex);
});

rejects("second begin while assembling", "resync_required", () => {
  const assembler = new SnapshotAssembler();
  const begin = {
    epoch: "1",
    seq: "0",
    snapshot_id: snapshotID,
    bytes: snapshotBytes.length,
    chunks: 1,
    sha256: sha256Hex(snapshotBytes),
  };
  assembler.begin(begin);
  assembler.begin(begin);
});

// MARK: - 4. Frame size and direction

const padding = "a".repeat(64 * 1024);
rejects("frame over 64 KiB", "invalid_frame", () => {
  validateFrame({ type: "resync", epoch: "1", pad: padding }, "viewer_to_relay");
});

accepts("resume from a viewer", () => {
  validateFrame({ type: "resume", epoch: "1", seq: "0" }, "viewer_to_relay");
});

accepts("viewer.count to the host", () => {
  validateFrame({ type: "viewer.count", epoch: "1", count: 0 }, "relay_to_host");
});

// MARK: - Verdict

if (failures.length > 0) {
  console.error(`✗ check-fixtures: ${failures.length} of ${checks} checks failed`);
  for (const failure of failures) console.error(`    ${failure}`);
  process.exit(1);
}
console.log(
  `✓ check-fixtures: ${checks} checks passed — ${Object.keys(goldenValidators).length} goldens, `
    + `${invalidIndex.cases.length} shared invalid cases, digest and canonical bytes verified`,
);