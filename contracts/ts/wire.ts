/**
 * The v1 wire contract, as validators.
 *
 * This module is the browser and Node half of C0. It is deliberately dependency-free and free of
 * any `node:` import, so the same file can be loaded by the relay, by a test, and by the website
 * viewer without a build step or a bundler shim.
 *
 * It mirrors `crates/shared_session/src` rule for rule. Where the two disagree, one of them is
 * wrong and the shared fixtures in `contracts/fixtures` are what say which: the goldens must
 * re-serialise byte-for-byte, and every case in `invalid.json` must be rejected with the same
 * allowlisted code by both implementations.
 *
 * Objects reject extra properties. Optional fields are omitted, never null. Counters are decimal
 * strings so no JSON parser can round them.
 */

// MARK: - Limits

export const LIMITS = {
  schema_version: 1,
  maxSnapshotBytes: 4 * 1024 * 1024,
  maxFrameBytes: 64 * 1024,
  maxRawChunkBytes: 45 * 1024,
  maxChunks: 128,
  maxAuthFrameBytes: 4 * 1024,
  maxBlocks: 50,
  maxTotalGridLines: 2000,
  minGridDimension: 1,
  maxGridDimension: 512,
  maxGraphemeBytes: 64,
  maxCommandBytes: 64 * 1024,
  maxEditorBytes: 64 * 1024,
  maxStyles: 4096,
  maxStyleIndex: 4095,
  maxColorIndex: 255,
  maxChannel: 255,
  maxStyleFlags: 255,
  maxDamageOps: 128,
  maxDamageBytes: 64 * 1024,
  maxInputBytes: 64 * 1024,
  maxShareBlocks: 20,
  maxShareBytes: 2 * 1024 * 1024,
  maxSafeInteger: 9_007_199_254_740_991,
  maxSignedInt32: 2_147_483_647,
  minSignedInt32: -2_147_483_648,
  maxCounterDigits: 19,
  maxCounterValue: 9_223_372_036_854_775_807n,
} as const;

export const ERROR_CODES = [
  "unauthorized",
  "unsupported_version",
  "invalid_frame",
  "stale_epoch",
  "stale_lease",
  "input_gap",
  "rate_limited",
  "capacity",
  "unsupported_input",
  "session_ended",
  "resync_required",
] as const;

export type ErrorCode = (typeof ERROR_CODES)[number];

export const DIRECTIONS = [
  "host_to_relay",
  "viewer_to_relay",
  "relay_to_host",
  "relay_to_viewer",
] as const;

export type Direction = (typeof DIRECTIONS)[number];

/** A rejection carrying the allowlisted code that will travel and a local-only diagnostic. */
export class ContractError extends Error {
  readonly code: ErrorCode;
  readonly path: string;

  constructor(code: ErrorCode, path: string, reason: string) {
    super(`${path}: ${reason}`);
    this.name = "ContractError";
    this.code = code;
    this.path = path;
  }
}

const invalid = (path: string, reason: string): never => {
  throw new ContractError("invalid_frame", path, reason);
};

const oversized = (path: string, limit: number, actual: number): never => {
  throw new ContractError("invalid_frame", path, `${actual} exceeds ${limit}`);
};

// MARK: - Types

export type WireColor =
  | { kind: "palette"; index: number }
  | { kind: "rgb"; r: number; g: number; b: number };

export interface WireStyle {
  fg: WireColor;
  bg: WireColor;
  flags: number;
}

export interface WireCell {
  text: string;
  width: 0 | 1 | 2;
  style: number;
}

export type WireRow = WireCell[];

export type WireCursorShape = "block" | "underline" | "bar";

export interface WireCursor {
  row: number;
  column: number;
  visible: boolean;
  shape: WireCursorShape;
  blink: boolean;
}

export interface WireGrid {
  lines: WireRow[];
  cursor: WireCursor;
}

export type WireBlockState = "draft" | "running" | "sealed";
export type WireMode = "blocks" | "fullscreen";
export type WireGridKind = "header" | "output";

export interface WireEditor {
  visible: boolean;
  text: string;
  selection_start: number;
  selection_length: number;
}

export interface WireViewport {
  first_block_id: string;
  first_line: number;
  pinned_block_id: string;
}

export interface WireBlock {
  id: string;
  command: string;
  state: WireBlockState;
  collapsed: boolean;
  header: WireGrid;
  output: WireGrid;
  exit_code?: number;
  duration_ms?: number;
}

export interface WireSnapshot {
  version: number;
  epoch: string;
  seq: string;
  mode: WireMode;
  columns: number;
  rows: number;
  styles: WireStyle[];
  blocks: WireBlock[];
  viewport: WireViewport;
  editor: WireEditor;
}

export type WireDamageOp =
  | { op: "insert_block"; after_id?: string; block: WireBlock }
  | { op: "remove_block"; block_id: string }
  | {
      op: "replace_header";
      block_id: string;
      command: string;
      state: WireBlockState;
      exit_code?: number;
      duration_ms?: number;
    }
  | { op: "set_collapsed"; block_id: string; collapsed: boolean }
  | { op: "replace_row"; block_id: string; grid: WireGridKind; row: number; cells: WireRow }
  | { op: "truncate_grid"; block_id: string; grid: WireGridKind; line_count: number }
  | { op: "set_cursor"; block_id: string; grid: WireGridKind; cursor: WireCursor }
  | { op: "replace_editor"; editor: WireEditor }
  | { op: "replace_viewport"; viewport: WireViewport };

export interface WireDamage {
  epoch: string;
  seq: string;
  base_seq: string;
  changes: WireDamageOp[];
}

export type WireInputKey =
  | "enter" | "tab" | "backspace" | "delete" | "escape"
  | "arrow_up" | "arrow_down" | "arrow_left" | "arrow_right"
  | "home" | "end" | "page_up" | "page_down"
  | "f1" | "f2" | "f3" | "f4" | "f5" | "f6" | "f7" | "f8" | "f9" | "f10" | "f11" | "f12"
  | "a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" | "k" | "l" | "m"
  | "n" | "o" | "p" | "q" | "r" | "s" | "t" | "u" | "v" | "w" | "x" | "y" | "z";

export type WireModifier = "shift" | "control" | "alt" | "meta";

export type WireInputOperation =
  | { kind: "text"; text: string }
  | { kind: "paste"; text: string }
  | { kind: "key"; key: WireInputKey; modifiers: WireModifier[] }
  | { kind: "undo" }
  | { kind: "redo" };

export interface WireInputFrame {
  epoch: string;
  control_lease: string;
  input_seq: string;
  operation: WireInputOperation;
}

export type WireShareSpan = { start: number; length: number; style: number };
export interface WireShareLine { text: string; spans: WireShareSpan[] }
export interface WireShareBlock {
  id: string;
  command: string;
  state: WireBlockState;
  exit_code?: number;
  duration_ms?: number;
  lines: WireShareLine[];
}
export interface WireShareSnapshot {
  schema_version: number;
  snapshot_id: string;
  styles: WireStyle[];
  blocks: WireShareBlock[];
  directory?: string;
}

export type WireFrameType =
  | "auth" | "hello" | "resume" | "resync" | "output.ack" | "error" | "input.ack"
  | "snapshot.begin" | "snapshot.chunk" | "snapshot.end" | "damage" | "input"
  | "control.request" | "control.granted" | "control.denied" | "control.revoked"
  | "viewer.count";

// MARK: - Canonical encoding

/**
 * Sorted keys, no spaces, no slash escaping — the same bytes `WireCanonicalJSON` produces in
 * Swift. Every key in this contract is ASCII, so a UTF-16 code-unit sort is a byte sort.
 */
export function canonicalStringify(value: unknown): string {
  return JSON.stringify(sortKeys(value));
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value !== null && typeof value === "object") {
    const source = value as Record<string, unknown>;
    const sorted: Record<string, unknown> = {};
    for (const key of Object.keys(source).sort()) sorted[key] = sortKeys(source[key]);
    return sorted;
  }
  return value;
}

export function utf8Length(text: string): number {
  return new TextEncoder().encode(text).length;
}

const BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const BASE64_LOOKUP = (() => {
  const table = new Int16Array(128).fill(-1);
  for (let index = 0; index < BASE64_ALPHABET.length; index += 1) {
    table[BASE64_ALPHABET.charCodeAt(index)] = index;
  }
  return table;
})();

export function base64Encode(bytes: Uint8Array): string {
  let out = "";
  for (let index = 0; index < bytes.length; index += 3) {
    const b0 = bytes[index];
    const b1 = index + 1 < bytes.length ? bytes[index + 1] : undefined;
    const b2 = index + 2 < bytes.length ? bytes[index + 2] : undefined;
    out += BASE64_ALPHABET[b0 >> 2];
    out += BASE64_ALPHABET[((b0 & 0x03) << 4) | ((b1 ?? 0) >> 4)];
    if (b1 === undefined) return `${out}==`;
    out += BASE64_ALPHABET[((b1 & 0x0f) << 2) | ((b2 ?? 0) >> 6)];
    if (b2 === undefined) return `${out}=`;
    out += BASE64_ALPHABET[b2 & 0x3f];
  }
  return out;
}

/** Strict: the alphabet only, correct padding only, and no non-canonical tail. */
export function base64Decode(text: string): Uint8Array | null {
  if (text.length % 4 !== 0) return null;
  const padding = text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0;
  const core = padding ? text.slice(0, -padding) : text;
  const out = new Uint8Array((core.length * 6) >> 3);
  let bits = 0;
  let value = 0;
  let written = 0;
  for (let index = 0; index < core.length; index += 1) {
    const code = core.charCodeAt(index);
    const digit = code < 128 ? BASE64_LOOKUP[code] : -1;
    if (digit < 0) return null;
    value = (value << 6) | digit;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[written] = (value >> bits) & 0xff;
      written += 1;
    }
  }
  return written === out.length ? out : null;
}

const SEGMENTER = new Intl.Segmenter(undefined, { granularity: "grapheme" });

function graphemeCount(text: string): number {
  let count = 0;
  for (const _ of SEGMENTER.segment(text)) count += 1;
  return count;
}

/** C0/C1, DEL, and the bidi controls: undrawable, and the bidi set can make one row render as
 * another. */
const FORBIDDEN: ReadonlyArray<readonly [number, number]> = [
  [0x00, 0x1f],
  [0x7f, 0x9f],
  [0x202a, 0x202e],
  [0x2066, 0x2069],
];

function assertNoForbiddenScalar(text: string, path: string): void {
  for (const character of text) {
    const point = character.codePointAt(0) as number;
    for (const [low, high] of FORBIDDEN) {
      if (point >= low && point <= high) {
        invalid(path, `control scalar U+${point.toString(16)}`);
      }
    }
  }
}

// MARK: - Primitive readers

function readObject(
  value: unknown,
  path: string,
  known: readonly string[],
): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    invalid(path, "expected an object");
  }
  const record = value as Record<string, unknown>;
  const allowed = new Set(known);
  for (const key of Object.keys(record)) {
    if (!allowed.has(key)) invalid(path, `unknown field ${key}`);
  }
  return record;
}

function readArray(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) invalid(path, "expected an array");
  return value;
}

function readNumber(value: unknown, path: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    invalid(path, "expected a JSON safe integer");
  }
  if (value < min || value > max) invalid(path, `${value} outside ${min}...${max}`);
  return value;
}

function readBoolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") invalid(path, "expected a boolean");
  return value;
}

function readString(value: unknown, path: string): string {
  if (typeof value !== "string") invalid(path, "expected a string");
  if (!value.isWellFormed()) invalid(path, "unpaired UTF-16 surrogate");
  return value;
}

function readEnum<T extends string>(value: unknown, path: string, allowed: readonly T[]): T {
  const text = readString(value, path);
  if (!(allowed as readonly string[]).includes(text)) {
    invalid(path, `unknown value ${text}`);
  }
  return text as T;
}

/** A required field. Present-and-null is refused: only omission means "no value". */
function required(record: Record<string, unknown>, name: string, path: string): unknown {
  if (!Object.prototype.hasOwnProperty.call(record, name)) {
    invalid(path, `missing field ${name}`);
  }
  return record[name];
}

/** An optional field. Present-and-null is an error, not an absent value. */
function optional(record: Record<string, unknown>, name: string, path: string): unknown {
  if (!Object.prototype.hasOwnProperty.call(record, name)) return undefined;
  const value = record[name];
  if (value === null) invalid(`${path}.${name}`, "null is not a value; omit the field");
  return value;
}

/** Counters are decimal strings: `0|[1-9][0-9]{0,18}` and no wider than a signed 64-bit int. */
export function readCounter(value: unknown, path: string, minimum: bigint = 0n): bigint {
  const text = readString(value, path);
  if (text.length === 0 || text.length > LIMITS.maxCounterDigits) {
    invalid(path, `counter ${text.length} digits`);
  }
  if (text.length > 1 && text.startsWith("0")) invalid(path, "counter has a leading zero");
  if (!/^[0-9]+$/.test(text)) invalid(path, "counter is not decimal");
  const parsed = BigInt(text);
  if (parsed > LIMITS.maxCounterValue) invalid(path, "counter overflows Int64");
  if (parsed < minimum) invalid(path, `counter must be >= ${minimum}`);
  return parsed;
}

export function readUUID(value: unknown, path: string): string {
  const text = readString(value, path);
  if (text.length !== 36) invalid(path, `UUID is ${text.length} characters`);
  for (let index = 0; index < 36; index += 1) {
    const character = text[index];
    const isHyphenSlot = index === 8 || index === 13 || index === 18 || index === 23;
    if (isHyphenSlot) {
      if (character !== "-") invalid(path, "UUID hyphen misplaced");
    } else if (!/[0-9a-f]/.test(character)) {
      invalid(path, "UUID is not lowercase hex");
    }
  }
  return text;
}

export function readHexDigest(value: unknown, path: string): string {
  const text = readString(value, path);
  if (text.length !== 64) invalid(path, `digest is ${text.length} characters`);
  if (!/^[0-9a-f]{64}$/.test(text)) invalid(path, "digest is not lowercase hex");
  return text;
}

export function readBase64(value: unknown, path: string, maxBytes: number): Uint8Array {
  const text = readString(value, path);
  const bytes = base64Decode(text);
  if (bytes === null || base64Encode(bytes) !== text) {
    invalid(path, "not canonical base64");
  }
  if (bytes.length > maxBytes) oversized(path, maxBytes, bytes.length);
  return bytes;
}

function readUtf8(value: unknown, path: string, limit: number): string {
  const text = readString(value, path);
  const bytes = utf8Length(text);
  if (bytes > limit) oversized(path, limit, bytes);
  return text;
}

/** Exactly one extended grapheme cluster, at most 64 UTF-8 bytes, no control scalar. */
export function readGrapheme(value: unknown, path: string): string {
  const text = readString(value, path);
  if (graphemeCount(text) > 1) invalid(path, "more than one grapheme");
  if (utf8Length(text) > LIMITS.maxGraphemeBytes) {
    oversized(path, LIMITS.maxGraphemeBytes, utf8Length(text));
  }
  assertNoForbiddenScalar(text, path);
  return text;
}

// MARK: - Structure validators

export function validateColor(value: unknown, path = "color"): WireColor {
  const record = readObject(value, path, ["kind", "index", "r", "g", "b"]);
  const kind = readEnum(record.kind, `${path}.kind`, ["palette", "rgb"] as const);
  if (kind === "palette") {
    if (record.r !== undefined || record.g !== undefined || record.b !== undefined) {
      invalid(path, "palette carries rgb components");
    }
    return {
      kind,
      index: readNumber(required(record, "index", path), `${path}.index`, 0, LIMITS.maxColorIndex),
    };
  }
  if (record.index !== undefined) invalid(path, "rgb carries an index");
  return {
    kind,
    r: readNumber(required(record, "r", path), `${path}.r`, 0, LIMITS.maxChannel),
    g: readNumber(required(record, "g", path), `${path}.g`, 0, LIMITS.maxChannel),
    b: readNumber(required(record, "b", path), `${path}.b`, 0, LIMITS.maxChannel),
  };
}

export function validateStyle(value: unknown, path = "style"): WireStyle {
  const record = readObject(value, path, ["fg", "bg", "flags"]);
  return {
    fg: validateColor(required(record, "fg", path), `${path}.fg`),
    bg: validateColor(required(record, "bg", path), `${path}.bg`),
    flags: readNumber(required(record, "flags", path), `${path}.flags`, 0, LIMITS.maxStyleFlags),
  };
}

export function validateCell(value: unknown, path = "cell"): WireCell {
  const record = readObject(value, path, ["text", "width", "style"]);
  const width = readNumber(required(record, "width", path), `${path}.width`, 0, 2);
  return {
    text: readString(required(record, "text", path), `${path}.text`),
    width: width as 0 | 1 | 2,
    style: readNumber(required(record, "style", path), `${path}.style`, 0, LIMITS.maxStyleIndex),
  };
}

/** A row is a bare array of exactly `columns` cells, with the continuation rules applied. */
export function validateRow(value: unknown, path: string, columns: number): WireRow {
  const raw = readArray(value, path);
  if (raw.length !== columns) invalid(path, `${raw.length} cells, expected ${columns}`);
  const cells = raw.map((cell, index) => validateCell(cell, `${path}[${index}]`));
  cells.forEach((cell, index) => {
    const cellPath = `${path}[${index}]`;
    if (cell.width === 0) {
      if (cell.text !== "") invalid(cellPath, "continuation cell carries text");
      if (index === 0 || cells[index - 1].width !== 2) {
        invalid(cellPath, "isolated continuation cell");
      }
      return;
    }
    if (cell.text === "") invalid(cellPath, "empty text in a visible cell");
    readGrapheme(cell.text, cellPath);
    if (cell.width === 2) {
      if (index === columns - 1) invalid(cellPath, "wide cell in the last column");
      if (cells[index + 1].width !== 0) invalid(cellPath, "wide cell without a continuation");
    }
  });
  return cells;
}

export function validateCursor(value: unknown, path = "cursor"): WireCursor {
  const record = readObject(value, path, ["row", "column", "visible", "shape", "blink"]);
  return {
    row: readNumber(required(record, "row", path), `${path}.row`, 0, LIMITS.maxTotalGridLines),
    column: readNumber(
      required(record, "column", path),
      `${path}.column`,
      0,
      LIMITS.maxGridDimension,
    ),
    visible: readBoolean(required(record, "visible", path), `${path}.visible`),
    shape: readEnum(required(record, "shape", path), `${path}.shape`, [
      "block",
      "underline",
      "bar",
    ] as const),
    blink: readBoolean(required(record, "blink", path), `${path}.blink`),
  };
}

export function validateGrid(value: unknown, path: string, columns: number): WireGrid {
  const record = readObject(value, path, ["lines", "cursor"]);
  const lines = readArray(required(record, "lines", path), `${path}.lines`).map((line, index) =>
    validateRow(line, `${path}.lines[${index}]`, columns),
  );
  const cursor = validateCursor(required(record, "cursor", path), `${path}.cursor`);
  if (lines.length === 0) {
    if (cursor.row !== 0 || cursor.column !== 0 || cursor.visible) {
      invalid(`${path}.cursor`, "empty grid must park an invisible cursor at 0,0");
    }
    return { lines, cursor };
  }
  if (cursor.row >= lines.length) {
    invalid(`${path}.cursor.row`, `${cursor.row} of ${lines.length} lines`);
  }
  if (cursor.column >= columns) {
    invalid(`${path}.cursor.column`, `${cursor.column} of ${columns} columns`);
  }
  return { lines, cursor };
}

export function validateEditor(value: unknown, path = "editor"): WireEditor {
  const record = readObject(value, path, [
    "visible",
    "text",
    "selection_start",
    "selection_length",
  ]);
  const visible = readBoolean(required(record, "visible", path), `${path}.visible`);
  const text = readUtf8(required(record, "text", path), `${path}.text`, LIMITS.maxEditorBytes);
  const selection_start = readNumber(
    required(record, "selection_start", path),
    `${path}.selection_start`,
    0,
    LIMITS.maxSafeInteger,
  );
  const selection_length = readNumber(
    required(record, "selection_length", path),
    `${path}.selection_length`,
    0,
    LIMITS.maxSafeInteger,
  );
  if (!visible) {
    if (text !== "" || selection_start !== 0 || selection_length !== 0) {
      invalid(path, "hidden editor must carry no text or selection");
    }
    return { visible, text, selection_start, selection_length };
  }
  const units = text.length; // UTF-16 code units, which is what a selection offset counts.
  const end = selection_start + selection_length;
  if (end > units) {
    invalid(`${path}.selection_length`, `selection ends at ${end} of ${units} UTF-16 units`);
  }
  for (const offset of [selection_start, end]) {
    if (offset >= units) continue;
    const unit = text.charCodeAt(offset);
    if (unit >= 0xdc00 && unit <= 0xdfff) {
      invalid(path, `selection offset ${offset} splits a surrogate pair`);
    }
  }
  return { visible, text, selection_start, selection_length };
}

export function validateViewport(value: unknown, path = "viewport"): WireViewport {
  const record = readObject(value, path, ["first_block_id", "first_line", "pinned_block_id"]);
  return {
    first_block_id: readUUID(required(record, "first_block_id", path), `${path}.first_block_id`),
    first_line: readNumber(
      required(record, "first_line", path),
      `${path}.first_line`,
      0,
      LIMITS.maxTotalGridLines,
    ),
    pinned_block_id: readUUID(
      required(record, "pinned_block_id", path),
      `${path}.pinned_block_id`,
    ),
  };
}

export function validateBlock(value: unknown, path: string, columns: number): WireBlock {
  const record = readObject(value, path, [
    "id",
    "command",
    "state",
    "collapsed",
    "header",
    "output",
    "exit_code",
    "duration_ms",
  ]);
  const block: WireBlock = {
    id: readUUID(required(record, "id", path), `${path}.id`),
    command: readUtf8(required(record, "command", path), `${path}.command`, LIMITS.maxCommandBytes),
    state: readEnum(required(record, "state", path), `${path}.state`, [
      "draft",
      "running",
      "sealed",
    ] as const),
    collapsed: readBoolean(required(record, "collapsed", path), `${path}.collapsed`),
    header: validateGrid(required(record, "header", path), `${path}.header`, columns),
    output: validateGrid(required(record, "output", path), `${path}.output`, columns),
  };
  const exit_code = optional(record, "exit_code", path);
  if (exit_code !== undefined) {
    block.exit_code = readNumber(
      exit_code,
      `${path}.exit_code`,
      LIMITS.minSignedInt32,
      LIMITS.maxSignedInt32,
    );
  }
  const duration = optional(record, "duration_ms", path);
  if (duration !== undefined) {
    block.duration_ms = readNumber(duration, `${path}.duration_ms`, 0, LIMITS.maxSafeInteger);
  }
  return block;
}

export function validateSnapshot(value: unknown): WireSnapshot {
  const path = "snapshot";
  const record = readObject(value, path, [
    "version",
    "epoch",
    "seq",
    "mode",
    "columns",
    "rows",
    "styles",
    "blocks",
    "viewport",
    "editor",
  ]);
  const version = readNumber(required(record, "version", path), `${path}.version`, 0, LIMITS.maxSafeInteger);
  if (version !== LIMITS.schema_version) {
    throw new ContractError("unsupported_version", path, `unsupported version ${version}`);
  }
  const epoch = readCounter(required(record, "epoch", path), `${path}.epoch`, 1n).toString();
  const seq = readCounter(required(record, "seq", path), `${path}.seq`).toString();
  const mode = readEnum(required(record, "mode", path), `${path}.mode`, [
    "blocks",
    "fullscreen",
  ] as const);
  const columns = readNumber(
    required(record, "columns", path),
    `${path}.columns`,
    LIMITS.minGridDimension,
    LIMITS.maxGridDimension,
  );
  const rows = readNumber(
    required(record, "rows", path),
    `${path}.rows`,
    LIMITS.minGridDimension,
    LIMITS.maxGridDimension,
  );
  const styles = readArray(required(record, "styles", path), `${path}.styles`).map(
    (style, index) => validateStyle(style, `${path}.styles[${index}]`),
  );
  if (styles.length === 0) invalid(`${path}.styles`, "index 0 is the default style");
  if (styles.length > LIMITS.maxStyles) oversized(`${path}.styles`, LIMITS.maxStyles, styles.length);

  const rawBlocks = readArray(required(record, "blocks", path), `${path}.blocks`);
  if (rawBlocks.length > LIMITS.maxBlocks) {
    oversized(`${path}.blocks`, LIMITS.maxBlocks, rawBlocks.length);
  }
  const blocks = rawBlocks.map((block, index) =>
    validateBlock(block, `${path}.blocks[${index}]`, columns),
  );

  const identifiers = new Set<string>();
  let lines = 0;
  blocks.forEach((block) => {
    if (identifiers.has(block.id)) {
      throw new ContractError("invalid_frame", `${path}.blocks`, `duplicate id ${block.id}`);
    }
    identifiers.add(block.id);
    lines += block.header.lines.length + block.output.lines.length;
  });
  if (lines > LIMITS.maxTotalGridLines) {
    oversized(`${path}.blocks`, LIMITS.maxTotalGridLines, lines);
  }

  blocks.forEach((block, blockIndex) => {
    for (const [name, grid] of [["header", block.header], ["output", block.output]] as const) {
      grid.lines.forEach((line, lineIndex) => {
        line.forEach((cell, cellIndex) => {
          if (cell.style >= styles.length) {
            invalid(
              `${path}.blocks[${blockIndex}].${name}[${lineIndex}][${cellIndex}].style`,
              `style ${cell.style} of ${styles.length}`,
            );
          }
        });
      });
    }
  });

  const viewport = validateViewport(required(record, "viewport", path), `${path}.viewport`);
  if (!identifiers.has(viewport.first_block_id)) {
    throw new ContractError("invalid_frame", path, `unknown block ${viewport.first_block_id}`);
  }
  if (!identifiers.has(viewport.pinned_block_id)) {
    throw new ContractError("invalid_frame", path, `unknown block ${viewport.pinned_block_id}`);
  }
  const editor = validateEditor(required(record, "editor", path), `${path}.editor`);

  if (mode === "fullscreen") {
    if (blocks.length !== 1) {
      invalid(`${path}.blocks`, `fullscreen has exactly one block, got ${blocks.length}`);
    }
    if (editor.visible) invalid(`${path}.editor`, "fullscreen hides the editor");
  }

  const snapshot: WireSnapshot = {
    version,
    epoch,
    seq,
    mode,
    columns,
    rows,
    styles,
    blocks,
    viewport,
    editor,
  };
  const bytes = utf8Length(canonicalStringify(snapshot));
  if (bytes > LIMITS.maxSnapshotBytes) oversized(path, LIMITS.maxSnapshotBytes, bytes);
  return snapshot;
}

const OP_FIELDS: Record<string, readonly string[]> = {
  insert_block: ["op", "after_id", "block"],
  remove_block: ["op", "block_id"],
  replace_header: ["op", "block_id", "command", "state", "exit_code", "duration_ms"],
  set_collapsed: ["op", "block_id", "collapsed"],
  replace_row: ["op", "block_id", "grid", "row", "cells"],
  truncate_grid: ["op", "block_id", "grid", "line_count"],
  set_cursor: ["op", "block_id", "grid", "cursor"],
  replace_editor: ["op", "editor"],
  replace_viewport: ["op", "viewport"],
};

/** Every field any operation may name. The probe pass accepts this union so it can read `op`
 * before it knows which field set applies; the second pass then enforces the exact one. */
const ALL_OP_FIELDS: readonly string[] = [
  "op", "after_id", "block", "block_id", "command", "state", "exit_code", "duration_ms",
  "collapsed", "grid", "row", "cells", "line_count", "cursor", "editor", "viewport",
];

export function validateDamageOp(value: unknown, path: string, columns: number): WireDamageOp {
  const probe = readObject(value, path, ALL_OP_FIELDS);
  const name = readEnum(probe.op, `${path}.op`, Object.keys(OP_FIELDS) as string[]);
  const record = readObject(value, path, OP_FIELDS[name]);
  const block_id = () => readUUID(required(record, "block_id", path), `${path}.block_id`);
  const grid = () =>
    readEnum(required(record, "grid", path), `${path}.grid`, ["header", "output"] as const);

  switch (name) {
    case "insert_block": {
      const after = optional(record, "after_id", path);
      const op: WireDamageOp = {
        op: "insert_block",
        block: validateBlock(required(record, "block", path), `${path}.block`, columns),
      };
      if (after !== undefined) op.after_id = readUUID(after, `${path}.after_id`);
      return op;
    }
    case "remove_block":
      return { op: "remove_block", block_id: block_id() };
    case "replace_header": {
      const op: WireDamageOp = {
        op: "replace_header",
        block_id: block_id(),
        command: readUtf8(
          required(record, "command", path),
          `${path}.command`,
          LIMITS.maxCommandBytes,
        ),
        state: readEnum(required(record, "state", path), `${path}.state`, [
          "draft",
          "running",
          "sealed",
        ] as const),
      };
      const exit_code = optional(record, "exit_code", path);
      if (exit_code !== undefined) {
        op.exit_code = readNumber(
          exit_code,
          `${path}.exit_code`,
          LIMITS.minSignedInt32,
          LIMITS.maxSignedInt32,
        );
      }
      const duration = optional(record, "duration_ms", path);
      if (duration !== undefined) {
        op.duration_ms = readNumber(duration, `${path}.duration_ms`, 0, LIMITS.maxSafeInteger);
      }
      return op;
    }
    case "set_collapsed":
      return {
        op: "set_collapsed",
        block_id: block_id(),
        collapsed: readBoolean(required(record, "collapsed", path), `${path}.collapsed`),
      };
    case "replace_row":
      return {
        op: "replace_row",
        block_id: block_id(),
        grid: grid(),
        row: readNumber(required(record, "row", path), `${path}.row`, 0, LIMITS.maxTotalGridLines),
        cells: validateRow(required(record, "cells", path), `${path}.cells`, columns),
      };
    case "truncate_grid":
      return {
        op: "truncate_grid",
        block_id: block_id(),
        grid: grid(),
        line_count: readNumber(
          required(record, "line_count", path),
          `${path}.line_count`,
          0,
          LIMITS.maxTotalGridLines,
        ),
      };
    case "set_cursor":
      return {
        op: "set_cursor",
        block_id: block_id(),
        grid: grid(),
        cursor: validateCursor(required(record, "cursor", path), `${path}.cursor`),
      };
    case "replace_editor":
      return {
        op: "replace_editor",
        editor: validateEditor(required(record, "editor", path), `${path}.editor`),
      };
    case "replace_viewport":
      return {
        op: "replace_viewport",
        viewport: validateViewport(required(record, "viewport", path), `${path}.viewport`),
      };
    default:
      invalid(`${path}.op`, `unknown operation ${name}`);
  }
}

/** Damage is validated against the snapshot's geometry, so the op union can check cell widths. */
export function validateDamage(value: unknown, columns: number): WireDamage {
  const path = "damage";
  const record = readObject(value, path, ["type", "epoch", "seq", "base_seq", "changes"]);
  const epoch = readCounter(required(record, "epoch", path), `${path}.epoch`, 1n).toString();
  const seq = readCounter(required(record, "seq", path), `${path}.seq`, 1n);
  const base_seq = readCounter(required(record, "base_seq", path), `${path}.base_seq`);
  if (seq !== base_seq + 1n) {
    throw new ContractError(
      "resync_required",
      path,
      `sequence gap: expected ${base_seq + 1n}, got ${seq}`,
    );
  }
  const raw = readArray(required(record, "changes", path), `${path}.changes`);
  if (raw.length > LIMITS.maxDamageOps) {
    oversized(`${path}.changes`, LIMITS.maxDamageOps, raw.length);
  }
  const changes = raw.map((op, index) =>
    validateDamageOp(op, `${path}.changes[${index}]`, columns),
  );
  const damage: WireDamage = { epoch, seq: seq.toString(), base_seq: base_seq.toString(), changes };
  const bytes = utf8Length(canonicalStringify(damage));
  if (bytes > LIMITS.maxDamageBytes) oversized(path, LIMITS.maxDamageBytes, bytes);
  return damage;
}

const LETTER_KEYS = new Set([
  "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
  "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
]);

const INPUT_KEYS: readonly WireInputKey[] = [
  "enter", "tab", "backspace", "delete", "escape",
  "arrow_up", "arrow_down", "arrow_left", "arrow_right",
  "home", "end", "page_up", "page_down",
  "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
  ...(Array.from(LETTER_KEYS) as WireInputKey[]),
];

const MODIFIERS: readonly WireModifier[] = ["shift", "control", "alt", "meta"];

export function validateInputOperation(
  value: unknown,
  path = "operation",
): WireInputOperation {
  const probe = readObject(value, path, ["kind", "text", "key", "modifiers"]);
  const kind = readEnum(probe.kind, `${path}.kind`, ["text", "paste", "key", "undo", "redo"] as const);

  if (kind === "text" || kind === "paste") {
    const record = readObject(value, path, ["kind", "text"]);
    const text = readUtf8(required(record, "text", path), `${path}.text`, LIMITS.maxInputBytes);
    if (text.includes("\u0000")) invalid(`${path}.text`, "NUL in text");
    return kind === "text" ? { kind: "text", text } : { kind: "paste", text };
  }
  if (kind === "key") {
    const record = readObject(value, path, ["kind", "key", "modifiers"]);
    const key = readEnum(required(record, "key", path), `${path}.key`, INPUT_KEYS);
    const modifiers = readArray(
      required(record, "modifiers", path),
      `${path}.modifiers`,
    ).map((modifier, index) =>
      readEnum(modifier, `${path}.modifiers[${index}]`, MODIFIERS),
    );
    const seen = new Set<WireModifier>();
    for (const modifier of modifiers) {
      if (seen.has(modifier)) invalid(`${path}.modifiers`, `duplicate ${modifier}`);
      seen.add(modifier);
    }
    // An unmodified letter is text; a layout guess is exactly what the contract forbids.
    if (LETTER_KEYS.has(key)) {
      const chords = ["control", "alt", "meta"].filter((modifier) =>
        seen.has(modifier as WireModifier),
      );
      if (chords.length === 0) {
        throw new ContractError(
          "unsupported_input",
          path,
          "letter key needs a control, alt or meta chord",
        );
      }
    }
    return { kind: "key", key, modifiers };
  }
  readObject(value, path, ["kind"]);
  return kind === "undo" ? { kind: "undo" } : { kind: "redo" };
}

export function validateInputFrame(value: unknown): WireInputFrame {
  const path = "input";
  const record = readObject(value, path, ["type", "epoch", "control_lease", "input_seq", "operation"]);
  return {
    epoch: readCounter(required(record, "epoch", path), `${path}.epoch`, 1n).toString(),
    control_lease: readUUID(required(record, "control_lease", path), `${path}.control_lease`),
    input_seq: readCounter(required(record, "input_seq", path), `${path}.input_seq`, 1n).toString(),
    operation: validateInputOperation(required(record, "operation", path), `${path}.operation`),
  };
}

/** The directory label is a display string the owner approved; an absolute path is refused. */
export function validateShareDirectory(directory: unknown): string {
  const path = "share.directory";
  const text = readString(directory, path);
  if (utf8Length(text) > 256) oversized(path, 256, utf8Length(text));
  if (text.startsWith("/")) invalid(path, "absolute path in an export label");
  if (text.startsWith("~")) invalid(path, "home path in an export label");
  if (text.split("/").includes("..")) invalid(path, "traversal in an export label");
  return text;
}

export function validateShareSnapshot(value: unknown): WireShareSnapshot {
  const path = "share";
  const record = readObject(value, path, [
    "schema_version",
    "snapshot_id",
    "styles",
    "blocks",
    "directory",
  ]);
  const schema_version = readNumber(
    required(record, "schema_version", path),
    `${path}.schema_version`,
    0,
    LIMITS.maxSafeInteger,
  );
  if (schema_version !== LIMITS.schema_version) {
    throw new ContractError("unsupported_version", path, `unsupported version ${schema_version}`);
  }
  const snapshot_id = readUUID(required(record, "snapshot_id", path), `${path}.snapshot_id`);
  const styles = readArray(required(record, "styles", path), `${path}.styles`).map(
    (style, index) => validateStyle(style, `${path}.styles[${index}]`),
  );
  if (styles.length === 0) invalid(`${path}.styles`, "index 0 is the default style");
  if (styles.length > LIMITS.maxStyles) oversized(`${path}.styles`, LIMITS.maxStyles, styles.length);

  const rawBlocks = readArray(required(record, "blocks", path), `${path}.blocks`);
  if (rawBlocks.length > LIMITS.maxShareBlocks) {
    oversized(`${path}.blocks`, LIMITS.maxShareBlocks, rawBlocks.length);
  }
  const identifiers = new Set<string>();
  const blocks = rawBlocks.map((value2, index) => {
    const blockPath = `${path}.blocks[${index}]`;
    const block = readObject(value2, blockPath, [
      "id",
      "command",
      "state",
      "exit_code",
      "duration_ms",
      "lines",
    ]);
    const id = readUUID(required(block, "id", blockPath), `${blockPath}.id`);
    if (identifiers.has(id)) {
      throw new ContractError("invalid_frame", blockPath, `duplicate id ${id}`);
    }
    identifiers.add(id);
    const command = readUtf8(
      required(block, "command", blockPath),
      `${blockPath}.command`,
      LIMITS.maxCommandBytes,
    );
    if (/[\n\r]/.test(command)) invalid(`${blockPath}.command`, "command is not one line");
    const lines = readArray(required(block, "lines", blockPath), `${blockPath}.lines`).map(
      (line, lineIndex) => {
        const linePath = `${blockPath}.lines[${lineIndex}]`;
        const entry = readObject(line, linePath, ["text", "spans"]);
        const text = readString(required(entry, "text", linePath), `${linePath}.text`);
        for (const character of text) {
          const point = character.codePointAt(0) as number;
          if (point === 0x0a || point === 0x0d) {
            invalid(`${linePath}.text`, "newline inside an exported line");
          }
          if (point === 0x09) continue;
          for (const [low, high] of FORBIDDEN) {
            if (point >= low && point <= high) {
              invalid(`${linePath}.text`, `control scalar U+${point.toString(16)}`);
            }
          }
        }
        const spans = readArray(required(entry, "spans", linePath), `${linePath}.spans`).map(
          (span, spanIndex) => {
            const spanPath = `${linePath}.spans[${spanIndex}]`;
            const fields = readObject(span, spanPath, ["start", "length", "style"]);
            return {
              start: readNumber(
                required(fields, "start", spanPath),
                `${spanPath}.start`,
                0,
                LIMITS.maxSafeInteger,
              ),
              length: readNumber(
                required(fields, "length", spanPath),
                `${spanPath}.length`,
                1,
                LIMITS.maxSafeInteger,
              ),
              style: readNumber(
                required(fields, "style", spanPath),
                `${spanPath}.style`,
                0,
                LIMITS.maxStyleIndex,
              ),
            };
          },
        );
        let previousEnd = 0;
        spans.forEach((span, spanIndex) => {
          const spanPath = `${linePath}.spans[${spanIndex}]`;
          if (span.start < previousEnd) {
            invalid(spanPath, `overlaps or is out of order at ${span.start}`);
          }
          const end = span.start + span.length;
          if (end > text.length) {
            invalid(spanPath, `ends at ${end} of ${text.length} UTF-16 units`);
          }
          if (span.style >= styles.length) {
            invalid(`${spanPath}.style`, `style ${span.style} of ${styles.length}`);
          }
          for (const offset of [span.start, end]) {
            const unit = text.charCodeAt(offset);
            if (unit >= 0xdc00 && unit <= 0xdfff) invalid(spanPath, "span splits a surrogate pair");
          }
          previousEnd = end;
        });
        return { text, spans };
      },
    );
    const state = readEnum(required(block, "state", blockPath), `${blockPath}.state`, ["sealed"] as const);
    const result: WireShareBlock = { id, command, state, lines };
    const exit_code = optional(block, "exit_code", blockPath);
    if (exit_code !== undefined) {
      result.exit_code = readNumber(
        exit_code,
        `${blockPath}.exit_code`,
        LIMITS.minSignedInt32,
        LIMITS.maxSignedInt32,
      );
    }
    const duration = optional(block, "duration_ms", blockPath);
    if (duration !== undefined) {
      result.duration_ms = readNumber(
        duration,
        `${blockPath}.duration_ms`,
        0,
        LIMITS.maxSafeInteger,
      );
    }
    return result;
  });

  const share: WireShareSnapshot = { schema_version, snapshot_id, styles, blocks };
  const directory = optional(record, "directory", path);
  if (directory !== undefined) share.directory = validateShareDirectory(directory);
  const bytes = utf8Length(canonicalStringify(share));
  if (bytes > LIMITS.maxShareBytes) oversized(path, LIMITS.maxShareBytes, bytes);
  return share;
}

// MARK: - Frames

/** Which way each frame may travel. A viewer sending `snapshot.chunk` is a rejection, not a
 * no-op: the direction check is what stops one role writing on another's behalf. */
export const FRAME_DIRECTIONS: Record<WireFrameType, readonly Direction[]> = {
  auth: ["host_to_relay", "viewer_to_relay"],
  hello: ["relay_to_host", "relay_to_viewer"],
  resume: ["viewer_to_relay"],
  resync: ["viewer_to_relay", "relay_to_host"],
  "output.ack": ["viewer_to_relay", "relay_to_host"],
  error: ["host_to_relay", "viewer_to_relay", "relay_to_host", "relay_to_viewer"],
  "input.ack": ["host_to_relay", "relay_to_viewer"],
  "snapshot.begin": ["host_to_relay", "relay_to_viewer"],
  "snapshot.chunk": ["host_to_relay", "relay_to_viewer"],
  "snapshot.end": ["host_to_relay", "relay_to_viewer"],
  damage: ["host_to_relay", "relay_to_viewer"],
  input: ["viewer_to_relay", "relay_to_host"],
  "control.request": ["viewer_to_relay", "relay_to_host"],
  "control.granted": ["host_to_relay", "relay_to_viewer"],
  "control.denied": ["host_to_relay", "relay_to_viewer"],
  "control.revoked": ["host_to_relay", "relay_to_viewer"],
  "viewer.count": ["relay_to_host"],
};

export interface WireFrame {
  type: WireFrameType;
  value: unknown;
}

/**
 * Validate one frame from one direction. Size is checked first, so an oversized frame is refused
 * before a parser is allowed to walk it. `columns` is required for frames that carry cells and
 * may be omitted for the rest.
 */
export function validateFrame(value: unknown, direction: Direction, columns?: number): WireFrame {
  const text = canonicalStringify(value);
  if (utf8Length(text) > LIMITS.maxFrameBytes) {
    oversized("frame", LIMITS.maxFrameBytes, utf8Length(text));
  }
  const record = readObject(value, "frame", [
    "type", "version", "session_id", "ticket", "client_id", "epoch", "seq", "base_seq",
    "changes", "snapshot_id", "bytes", "chunks", "sha256", "index", "data", "code", "status",
    "control_lease", "input_seq", "operation", "lease", "expires_at", "reason", "count", "mode",
    "columns", "rows",
  ]);
  const type = readEnum(required(record, "type", "frame"), "frame.type", Object.keys(
    FRAME_DIRECTIONS,
  ) as WireFrameType[]);
  const allowed = FRAME_DIRECTIONS[type];
  if (!allowed.includes(direction)) {
    invalid("frame", `${type} may not travel ${direction}`);
  }
  const path = type;
  const epoch = () => readCounter(required(record, "epoch", path), `${path}.epoch`, 1n).toString();

  switch (type) {
    case "auth": {
      const fields = readObject(value, path, ["type", "ticket", "client_id"]);
      const ticket = readUtf8(
        required(fields, "ticket", path),
        `${path}.ticket`,
        LIMITS.maxAuthFrameBytes,
      );
      if (ticket === "") invalid(`${path}.ticket`, "must not be empty");
      readUUID(required(fields, "client_id", path), `${path}.client_id`);
      break;
    }
    case "hello": {
      const fields = readObject(value, path, [
        "type", "version", "session_id", "epoch", "mode", "columns", "rows",
      ]);
      const version = readNumber(required(fields, "version", path), `${path}.version`, 0, LIMITS.maxSafeInteger);
      if (version !== LIMITS.schema_version) {
        throw new ContractError("unsupported_version", path, `unsupported version ${version}`);
      }
      readUUID(required(fields, "session_id", path), `${path}.session_id`);
      epoch();
      readEnum(required(fields, "mode", path), `${path}.mode`, ["blocks", "fullscreen"] as const);
      readNumber(required(fields, "columns", path), `${path}.columns`, LIMITS.minGridDimension, LIMITS.maxGridDimension);
      readNumber(required(fields, "rows", path), `${path}.rows`, LIMITS.minGridDimension, LIMITS.maxGridDimension);
      break;
    }
    case "resume": {
      const fields = readObject(value, path, ["type", "epoch", "seq"]);
      epoch();
      readCounter(required(fields, "seq", path), `${path}.seq`);
      break;
    }
    case "resync": {
      readObject(value, path, ["type", "epoch"]);
      epoch();
      break;
    }
    case "output.ack": {
      const fields = readObject(value, path, ["type", "epoch", "seq"]);
      epoch();
      readCounter(required(fields, "seq", path), `${path}.seq`);
      break;
    }
    case "error": {
      const fields = readObject(value, path, ["type", "code"]);
      readEnum(required(fields, "code", path), `${path}.code`, ERROR_CODES);
      break;
    }
    case "input.ack": {
      const fields = readObject(value, path, [
        "type", "epoch", "control_lease", "input_seq", "status", "code",
      ]);
      epoch();
      readUUID(required(fields, "control_lease", path), `${path}.control_lease`);
      readCounter(required(fields, "input_seq", path), `${path}.input_seq`, 1n);
      const status = readEnum(required(fields, "status", path), `${path}.status`, [
        "applied",
        "rejected",
      ] as const);
      const code = optional(fields, "code", path);
      if (code !== undefined) readEnum(code, `${path}.code`, ERROR_CODES);
      if (status === "rejected" && code === undefined) {
        invalid(path, "a rejected input must carry a code");
      }
      break;
    }
    case "snapshot.begin": {
      const fields = readObject(value, path, [
        "type", "epoch", "seq", "snapshot_id", "bytes", "chunks", "sha256",
      ]);
      epoch();
      readCounter(required(fields, "seq", path), `${path}.seq`);
      readUUID(required(fields, "snapshot_id", path), `${path}.snapshot_id`);
      const bytes = readNumber(required(fields, "bytes", path), `${path}.bytes`, 0, LIMITS.maxSnapshotBytes);
      const chunks = readNumber(required(fields, "chunks", path), `${path}.chunks`, 1, LIMITS.maxChunks);
      readHexDigest(required(fields, "sha256", path), `${path}.sha256`);
      if (bytes > chunks * LIMITS.maxRawChunkBytes) {
        oversized(`${path}.bytes`, chunks * LIMITS.maxRawChunkBytes, bytes);
      }
      break;
    }
    case "snapshot.chunk": {
      const fields = readObject(value, path, ["type", "epoch", "snapshot_id", "index", "data"]);
      epoch();
      readUUID(required(fields, "snapshot_id", path), `${path}.snapshot_id`);
      readNumber(required(fields, "index", path), `${path}.index`, 0, LIMITS.maxChunks - 1);
      readBase64(required(fields, "data", path), `${path}.data`, LIMITS.maxRawChunkBytes);
      break;
    }
    case "snapshot.end": {
      const fields = readObject(value, path, ["type", "epoch", "snapshot_id"]);
      epoch();
      readUUID(required(fields, "snapshot_id", path), `${path}.snapshot_id`);
      break;
    }
    case "damage": {
      if (columns === undefined) invalid(path, "damage needs the snapshot geometry");
      validateDamage(value, columns);
      break;
    }
    case "input":
      validateInputFrame(value);
      break;
    case "control.request": {
      readObject(value, path, ["type", "epoch"]);
      epoch();
      break;
    }
    case "control.granted": {
      const fields = readObject(value, path, ["type", "epoch", "lease", "expires_at"]);
      epoch();
      readUUID(required(fields, "lease", path), `${path}.lease`);
      const expires = readString(required(fields, "expires_at", path), `${path}.expires_at`);
      if (!isWireTime(expires)) invalid(`${path}.expires_at`, "not UTC ISO8601 milliseconds");
      break;
    }
    case "control.denied": {
      readObject(value, path, ["type", "epoch"]);
      epoch();
      break;
    }
    case "control.revoked": {
      const fields = readObject(value, path, ["type", "epoch", "lease", "reason"]);
      epoch();
      readUUID(required(fields, "lease", path), `${path}.lease`);
      readEnum(required(fields, "reason", path), `${path}.reason`, [
        "local_input",
        "expired",
        "disconnect",
        "revoked",
        "ended",
      ] as const);
      break;
    }
    case "viewer.count": {
      const fields = readObject(value, path, ["type", "epoch", "count"]);
      epoch();
      readNumber(required(fields, "count", path), `${path}.count`, 0, LIMITS.maxSafeInteger);
      break;
    }
    default:
      invalid("frame.type", `unknown frame ${type}`);
  }
  return { type, value: record };
}

/** `YYYY-MM-DDTHH:MM:SS.mmmZ`, fixed width, no other spelling accepted. */
export function isWireTime(text: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(text)) return false;
  const parsed = Date.parse(text);
  return Number.isFinite(parsed) && new Date(parsed).toISOString() === text;
}

// MARK: - Snapshot assembly

/**
 * Reassembles a chunked snapshot and swaps it in only when the count, the length and the digest
 * all agree. Any mismatch throws `resync_required` rather than rendering a partial view.
 */
export class SnapshotAssembler {
  private pending: {
    epoch: string;
    seq: string;
    snapshot_id: string;
    expectedBytes: number;
    expectedChunks: number;
    sha256: string;
    chunks: Uint8Array[];
  } | null = null;

  get isAssembling(): boolean {
    return this.pending !== null;
  }

  /** The eviction barrier: nothing from an abandoned transfer can reach a renderer. */
  reset(): void {
    this.pending = null;
  }

  begin(frame: Record<string, unknown>): void {
    if (this.pending !== null) {
      throw new ContractError("resync_required", "snapshot.begin", "a snapshot is already in flight");
    }
    validateFrame({ ...frame, type: "snapshot.begin" }, "relay_to_viewer");
    const bytes = frame.bytes as number;
    const chunks = frame.chunks as number;
    if (bytes > chunks * LIMITS.maxRawChunkBytes) {
      oversized("snapshot.begin.bytes", chunks * LIMITS.maxRawChunkBytes, bytes);
    }
    this.pending = {
      epoch: String(frame.epoch),
      seq: String(frame.seq),
      snapshot_id: String(frame.snapshot_id),
      expectedBytes: bytes,
      expectedChunks: chunks,
      sha256: String(frame.sha256),
      chunks: [],
    };
  }

  append(frame: Record<string, unknown>): void {
    const current = this.pending;
    if (current === null) {
      throw new ContractError("resync_required", "snapshot.chunk", "chunk without a begin");
    }
    const epoch = String(frame.epoch);
    const snapshot_id = String(frame.snapshot_id);
    const index = frame.index as number;
    // The frame carries base64 because that is what is on the wire; decode it here rather than
    // making every caller remember to, which is how a length check silently measures the wrong
    // thing.
    const raw = frame.data;
    const data =
      typeof raw === "string" ? base64Decode(raw) : (raw as Uint8Array | undefined);
    if (!(data instanceof Uint8Array)) {
      this.pending = null;
      invalid("snapshot.chunk.data", "not canonical base64");
    }
    if (data.byteLength > LIMITS.maxRawChunkBytes) {
      this.pending = null;
      oversized("snapshot.chunk", LIMITS.maxRawChunkBytes, data.byteLength);
    }
    if (current.snapshot_id !== snapshot_id || current.epoch !== epoch) {
      this.pending = null;
      throw new ContractError("resync_required", "snapshot.chunk", "chunk belongs to another snapshot");
    }
    if (index !== current.chunks.length) {
      this.pending = null;
      throw new ContractError(
        "resync_required",
        "snapshot.chunk",
        `chunk index ${index}, expected ${current.chunks.length}`,
      );
    }
    if (current.chunks.length >= current.expectedChunks) {
      this.pending = null;
      throw new ContractError("resync_required", "snapshot.chunk", "more chunks than declared");
    }
    const total = current.chunks.reduce((sum, chunk) => sum + chunk.length, 0) + data.length;
    if (total > current.expectedBytes) {
      this.pending = null;
      oversized("snapshot", current.expectedBytes, total);
    }
    current.chunks.push(data.slice());
  }

  /** Verification is mandatory and supports the browser's asynchronous Web Crypto digest. */
  async finish(
    frame: Record<string, unknown>,
    digest: (bytes: Uint8Array) => string | Promise<string>,
  ): Promise<Uint8Array> {
    const current = this.pending;
    if (current === null) {
      throw new ContractError("resync_required", "snapshot.end", "end without a begin");
    }
    this.pending = null;
    if (
      current.snapshot_id !== String(frame.snapshot_id) ||
      current.epoch !== String(frame.epoch)
    ) {
      throw new ContractError("resync_required", "snapshot.end", "end belongs to another snapshot");
    }
    if (current.chunks.length !== current.expectedChunks) {
      throw new ContractError(
        "resync_required",
        "snapshot.end",
        `${current.chunks.length} of ${current.expectedChunks} chunks`,
      );
    }
    const buffer = new Uint8Array(current.chunks.reduce((sum, chunk) => sum + chunk.length, 0));
    let offset = 0;
    for (const chunk of current.chunks) {
      buffer.set(chunk, offset);
      offset += chunk.length;
    }
    if (buffer.length !== current.expectedBytes) {
      throw new ContractError(
        "resync_required",
        "snapshot.end",
        `${buffer.length} bytes, expected ${current.expectedBytes}`,
      );
    }
    if (typeof digest !== "function" || await digest(buffer) !== current.sha256) {
      throw new ContractError("resync_required", "snapshot.end", "digest mismatch or missing verifier");
    }
    let value: unknown;
    try {
      value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(buffer));
    } catch {
      invalid("snapshot", "not UTF-8 JSON");
    }
    const snapshot = validateSnapshot(value);
    if (snapshot.epoch !== current.epoch || snapshot.seq !== current.seq) {
      throw new ContractError("resync_required", "snapshot.end", "snapshot differs from its transfer watermark");
    }
    return buffer;
  }
}
