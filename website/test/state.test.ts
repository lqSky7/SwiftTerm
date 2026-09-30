/**
 * The viewer's state reducer.
 *
 * The first test is the one that matters: it takes the golden snapshot the Swift harness writes,
 * feeds it through the viewer's own path, and compares every cell against the fixture. That is the
 * browser's half of the C0 agreement — if this file and `WireStreamState.swift` disagree about what
 * a frame means, this is where it shows, and it shows before anything is deployed.
 *
 * Everything else is the boundary: a gap, a duplicate, a stale epoch, a frame that would leave an
 * invalid state, and the cap on a snapshot nobody sized.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import {
  ContractError,
  LIMITS,
  validateDamage,
  validateSnapshot,
  type WireBlock,
  type WireDamage,
  type WireGrid,
  type WireRow,
  type WireSnapshot,
} from "../../contracts/ts/wire.ts";
import {
  applyDamage,
  applySnapshot,
  initialState,
  resumeSeq,
  type ViewerState,
} from "../src/shared_session/state.ts";

const here = dirname(fileURLToPath(import.meta.url));
const golden = (name: string): WireSnapshot =>
  validateSnapshot(
    JSON.parse(readFileSync(join(here, "..", "..", "contracts", "fixtures", "golden", name), "utf8")),
  );

/** A grid flattened to one comparable string per row: `text:width/style` for every cell. */
function gridFingerprint(grid: WireGrid): string[] {
  return grid.lines.map((row: WireRow) =>
    row.map((cell) => `${cell.text}:${cell.width}/${cell.style}`).join("|"),
  );
}

function blockFingerprint(block: WireBlock): string {
  return [
    block.id,
    block.command,
    block.state,
    String(block.collapsed),
    String(block.exit_code ?? "-"),
    String(block.duration_ms ?? "-"),
    gridFingerprint(block.header).join("\n"),
    gridFingerprint(block.output).join("\n"),
  ].join("~");
}

/** A viewer that has adopted the golden snapshot and is ready for a damage frame. */
function liveFromGolden(name = "snapshot-blocks.json"): ViewerState {
  return applySnapshot(initialState(), golden(name));
}

function damage(changes: unknown[], overrides: Partial<WireDamage> = {}): WireDamage {
  const state = liveFromGolden();
  const live = state.live;
  assert.notEqual(live, null);
  if (live === null) throw new Error("unreachable");
  return validateDamage(
    {
      type: "damage",
      epoch: overrides.epoch ?? live.epoch,
      seq: overrides.seq ?? String(live.lastSeq + 1),
      base_seq: overrides.base_seq ?? String(live.lastSeq),
      changes,
    },
    live.columns,
  );
}

/** A viewer one frame in, so `lastSeq` is 1 and a damage frame's `seq` can be >= 1. */
function advanced(): ViewerState {
  const snapshot = golden("snapshot-blocks.json");
  const outcome = applyDamage(
    liveFromGolden(),
    damage([{ op: "set_collapsed", block_id: snapshot.blocks[0]?.id, collapsed: true }]),
  );
  assert.equal(outcome.applied, true);
  if (!outcome.applied) throw new Error("unreachable");
  return { ...liveFromGolden(), live: outcome.live };
}

describe("golden equivalence", () => {
  it("adopts the golden snapshot cell for cell", () => {
    const snapshot = golden("snapshot-blocks.json");
    const state = applySnapshot(initialState(), snapshot);
    const live = state.live;
    assert.notEqual(live, null);
    if (live === null) return;

    assert.equal(state.status, "live");
    assert.equal(live.epoch, snapshot.epoch);
    assert.equal(live.lastSeq, Number(snapshot.seq));
    assert.equal(live.mode, snapshot.mode);
    assert.equal(live.columns, snapshot.columns);
    assert.equal(live.rows, snapshot.rows);
    assert.deepEqual(live.styles, snapshot.styles);
    assert.deepEqual(live.viewport, snapshot.viewport);
    assert.deepEqual(live.editor, snapshot.editor);

    // The part that would silently drift: every block, and every cell in every grid.
    assert.deepEqual(
      live.blocks.map(blockFingerprint),
      snapshot.blocks.map(blockFingerprint),
    );
  });

  it("adopts the fullscreen golden too", () => {
    const snapshot = golden("snapshot-fullscreen.json");
    const state = applySnapshot(initialState(), snapshot);
    assert.equal(state.live?.mode, "fullscreen");
    assert.deepEqual(
      state.live?.blocks.map(blockFingerprint),
      snapshot.blocks.map(blockFingerprint),
    );
  });

  it("replaces every field at once, so nothing stale survives", () => {
    const first = liveFromGolden("snapshot-blocks.json");
    const second = applySnapshot(first, golden("snapshot-fullscreen.json"));
    // A snapshot is the only carrier of a mode change, so this is the transition the viewer has to
    // get right: the old blocks are gone, not merged.
    assert.equal(second.live?.mode, "fullscreen");
    assert.deepEqual(second.live?.blocks, golden("snapshot-fullscreen.json").blocks);
    assert.notDeepEqual(second.live?.blocks, first.live?.blocks);
  });
});

describe("sequence discipline", () => {
  it("applies the next sequence and advances", () => {
    const state = liveFromGolden();
    const before = state.live?.lastSeq ?? 0;
    const outcome = applyDamage(state, damage([{ op: "set_collapsed", block_id: golden("snapshot-blocks.json").blocks[0]?.id, collapsed: true }]));

    assert.equal(outcome.applied, true);
    if (!outcome.applied) return;
    assert.equal(outcome.live.lastSeq, before + 1);
    assert.equal(outcome.live.blocks[0]?.collapsed, true);
  });

  it("refuses a gap rather than guessing", () => {
    const state = liveFromGolden();
    const live = state.live;
    if (live === null) return;
    const outcome = applyDamage(
      state,
      validateDamage(
        {
          type: "damage",
          epoch: live.epoch,
          seq: String(live.lastSeq + 2),
          base_seq: String(live.lastSeq + 1),
          changes: [],
        },
        live.columns,
      ),
    );
    assert.deepEqual(outcome, { applied: false, reason: "gap" });
  });

  it("refuses a base_seq that disagrees with its own seq, before the reducer sees it", () => {
    // The damage validator requires `base_seq === seq - 1`, so a frame that claims the right
    // position but was computed against an older state never reaches the reducer at all. That is the
    // cheaper place to catch it, and this asserts the viewer inherits the check.
    const state = advanced();
    const live = state.live;
    if (live === null) return;
    assert.throws(
      () =>
        validateDamage(
          {
            type: "damage",
            epoch: live.epoch,
            seq: String(live.lastSeq + 1),
            base_seq: String(live.lastSeq - 1),
            changes: [],
          },
          live.columns,
        ),
      // `resync_required`, not `invalid_frame`: the frame is well-formed and out of position, and
      // the answer to that is a fresh snapshot rather than a complaint about the bytes.
      (error: unknown) => error instanceof ContractError && error.code === "resync_required",
    );
  });

  it("ignores a duplicate, because the relay replays", () => {
    const state = advanced();
    const live = state.live;
    if (live === null) return;
    const outcome = applyDamage(
      state,
      validateDamage(
        {
          type: "damage",
          epoch: live.epoch,
          seq: String(live.lastSeq),
          base_seq: String(live.lastSeq - 1),
          changes: [],
        },
        live.columns,
      ),
    );
    assert.deepEqual(outcome, { applied: false, reason: "duplicate" });
  });

  it("refuses a different epoch without a snapshot", () => {
    const state = liveFromGolden();
    const live = state.live;
    if (live === null) return;
    const outcome = applyDamage(
      state,
      validateDamage(
        {
          type: "damage",
          epoch: String(Number(live.epoch) + 1),
          seq: "1",
          base_seq: "0",
          changes: [],
        },
        live.columns,
      ),
    );
    assert.deepEqual(outcome, { applied: false, reason: "stale_epoch" });
  });

  it("refuses damage before any snapshot", () => {
    const empty = initialState();
    const outcome = applyDamage(
      empty,
      validateDamage({ type: "damage", epoch: "1", seq: "1", base_seq: "0", changes: [] }, 40),
    );
    assert.deepEqual(outcome, { applied: false, reason: "no_snapshot" });
    assert.equal(resumeSeq(empty.live), null, "nothing applied means nothing to resume from");
  });
});

describe("operations", () => {
  const snapshot = golden("snapshot-blocks.json");
  const first = snapshot.blocks[0]?.id ?? "";
  const second = snapshot.blocks[1]?.id ?? "";

  function apply(changes: unknown[]) {
    const outcome = applyDamage(liveFromGolden(), damage(changes));
    assert.equal(outcome.applied, true, `expected the frame to apply: ${JSON.stringify(changes)}`);
    if (!outcome.applied) throw new Error("unreachable");
    return outcome.live;
  }

  it("inserts a block at the front when no anchor is given", () => {
    const block = { ...snapshot.blocks[0], id: "33333333-3333-4333-8333-333333333333" };
    const live = apply([{ op: "insert_block", block }]);
    assert.equal(live.blocks[0]?.id, block.id);
    assert.equal(live.blocks.length, snapshot.blocks.length + 1);
  });

  it("inserts a block after its anchor", () => {
    const block = { ...snapshot.blocks[0], id: "44444444-4444-4444-8444-444444444444" };
    const live = apply([{ op: "insert_block", after_id: first, block }]);
    assert.equal(live.blocks[1]?.id, block.id);
  });

  it("refuses an insert anchored to a block that is not there", () => {
    const block = { ...snapshot.blocks[0], id: "55555555-5555-4555-8555-555555555555" };
    const outcome = applyDamage(
      liveFromGolden(),
      damage([{ op: "insert_block", after_id: "99999999-9999-4999-8999-999999999999", block }]),
    );
    assert.deepEqual(outcome, { applied: false, reason: "invalid" });
  });

  it("refuses an insert that reuses an id", () => {
    const outcome = applyDamage(liveFromGolden(), damage([{ op: "insert_block", block: snapshot.blocks[0] }]));
    assert.deepEqual(outcome, { applied: false, reason: "invalid" });
  });

  it("removes a block, with the viewport moved off it in the same frame", () => {
    // Both blocks are referenced by the golden viewport, so removing one on its own would leave a
    // dangling reference and the resulting state would be refused. That is the contract's rule and
    // this is the frame that satisfies it: a removal and a viewport change together.
    const live = apply([
      { op: "remove_block", block_id: second },
      {
        op: "replace_viewport",
        viewport: { first_block_id: first, first_line: 0, pinned_block_id: first },
      },
    ]);
    assert.equal(live.blocks.some((block) => block.id === second), false);
  });

  it("refuses a removal that would leave the viewport pointing at nothing", () => {
    const outcome = applyDamage(liveFromGolden(), damage([{ op: "remove_block", block_id: second }]));
    assert.deepEqual(outcome, { applied: false, reason: "invalid" });
  });

  it("refuses to remove a block it does not have", () => {
    // A no-op would let a desynchronised viewer keep showing a block the host already dropped.
    const outcome = applyDamage(
      liveFromGolden(),
      damage([{ op: "remove_block", block_id: "99999999-9999-4999-8999-999999999999" }]),
    );
    assert.deepEqual(outcome, { applied: false, reason: "invalid" });
  });

  it("replaces a header and clears an omitted exit code", () => {
    const live = apply([
      { op: "replace_header", block_id: first, command: "make test", state: "sealed" },
    ]);
    const block = live.blocks.find((candidate) => candidate.id === first);
    assert.equal(block?.command, "make test");
    assert.equal(block?.state, "sealed");
    // Omitted means absent, not "keep the old one": the frame is the whole truth about the header.
    assert.equal(block?.exit_code, undefined);
    assert.equal(block?.duration_ms, undefined);
  });

  it("replaces a row, appending only at the current length", () => {
    const live = apply([
      {
        op: "replace_row",
        block_id: first,
        grid: "output",
        row: 0,
        cells: Array.from({ length: snapshot.columns }, () => ({ text: "x", width: 1, style: 0 })),
      },
    ]);
    const block = live.blocks.find((candidate) => candidate.id === first);
    assert.equal(block?.output.lines[0]?.[0]?.text, "x");
  });

  it("refuses a row past the end, which would leave a gap", () => {
    const outcome = applyDamage(
      liveFromGolden(),
      damage([
        {
          op: "replace_row",
          block_id: first,
          grid: "output",
          row: 400,
          cells: Array.from({ length: snapshot.columns }, () => ({ text: "x", width: 1, style: 0 })),
        },
      ]),
    );
    assert.deepEqual(outcome, { applied: false, reason: "invalid" });
  });

  it("truncates a grid, with the cursor moved into it in the same frame", () => {
    // Truncating on its own would leave the cursor past the last line, which the snapshot validator
    // refuses — so the frame that ships carries both operations, and the cross-cutting check runs
    // once at the end rather than rejecting the intermediate state.
    const live = apply([
      { op: "truncate_grid", block_id: first, grid: "output", line_count: 1 },
      {
        op: "set_cursor",
        block_id: first,
        grid: "output",
        cursor: { row: 0, column: 0, visible: true, shape: "block", blink: false },
      },
    ]);
    const block = live.blocks.find((candidate) => candidate.id === first);
    assert.equal(block?.output.lines.length, 1);
  });

  it("refuses a truncate beyond the grid", () => {
    // Within the contract's own bound for the field, so it is the reducer that has to refuse it.
    const outcome = applyDamage(
      liveFromGolden(),
      damage([{ op: "truncate_grid", block_id: first, grid: "output", line_count: 2000 }]),
    );
    assert.deepEqual(outcome, { applied: false, reason: "invalid" });
  });

  it("moves a cursor and replaces the editor and the viewport", () => {
    const live = apply([
      {
        op: "set_cursor",
        block_id: first,
        grid: "output",
        cursor: { row: 0, column: 1, visible: true, shape: "bar", blink: true },
      },
      { op: "replace_editor", editor: { visible: true, text: "hi", selection_start: 2, selection_length: 0 } },
      {
        op: "replace_viewport",
        viewport: { first_block_id: first, first_line: 0, pinned_block_id: second },
      },
    ]);
    const block = live.blocks.find((candidate) => candidate.id === first);
    assert.equal(block?.output.cursor.shape, "bar");
    assert.equal(live.editor.text, "hi");
    assert.equal(live.viewport.pinned_block_id, second);
  });

  it("applies several operations in one frame", () => {
    // A frame may truncate a grid and move the cursor together: the cross-cutting checks happen once
    // per frame, so an intermediate state that never ships is not rejected.
    const live = apply([
      { op: "truncate_grid", block_id: first, grid: "output", line_count: 1 },
      {
        op: "set_cursor",
        block_id: first,
        grid: "output",
        cursor: { row: 0, column: 0, visible: true, shape: "block", blink: false },
      },
    ]);
    const block = live.blocks.find((candidate) => candidate.id === first);
    assert.equal(block?.output.lines.length, 1);
    assert.equal(block?.output.cursor.row, 0);
  });

  it("leaves the previous state untouched when a frame is refused", () => {
    const state = liveFromGolden();
    const outcome = applyDamage(
      state,
      damage([{ op: "remove_block", block_id: "99999999-9999-4999-8999-999999999999" }]),
    );
    assert.equal(outcome.applied, false);
    // The whole reason operations run against a copy.
    assert.deepEqual(state.live?.blocks, golden("snapshot-blocks.json").blocks);
  });
});

describe("hostile input", () => {
  it("carries markup as text, not as markup", () => {
    const payload = "<script>alert('x')</script>& <img src=x onerror=y>";
    const live = applyDamage(
      liveFromGolden(),
      damage([
        {
          op: "replace_header",
          block_id: golden("snapshot-blocks.json").blocks[0]?.id,
          command: payload,
          state: "sealed",
        },
      ]),
    );
    assert.equal(live.applied, true);
    if (!live.applied) return;
    const block = live.live.blocks[0];
    // The reducer is not a sanitiser and does not pretend to be one: it stores the string exactly.
    // The page is what keeps it inert, by rendering it as a text node and never as HTML.
    assert.equal(block?.command, payload);
  });

  it("refuses a snapshot nobody sized", () => {
    const snapshot = golden("snapshot-blocks.json");
    const huge = {
      ...snapshot,
      // One block with more lines than the whole-snapshot budget allows.
      blocks: [
        {
          ...snapshot.blocks[0],
          output: {
            cursor: snapshot.blocks[0]?.output.cursor,
            lines: Array.from({ length: LIMITS.maxTotalGridLines + 1 }, () => snapshot.blocks[0]?.output.lines[0]),
          },
        },
      ],
    };
    assert.throws(() => validateSnapshot(huge), (error: unknown) => error instanceof ContractError);
  });

  it("refuses a malformed frame with an allowlisted code", () => {
    assert.throws(
      () => validateSnapshot({ version: 1 }),
      (error: unknown) => error instanceof ContractError && error.code === "invalid_frame",
    );
  });

  it("refuses a damage frame that would break a snapshot invariant", () => {
    // Each operation is legal on its own and the frame passes the damage validator: a truncate and
    // a cursor inside the contract's bounds. What is wrong is the *result* — a cursor past the last
    // line — and that is only visible once the frame is applied, which is why the reducer validates
    // the state it is about to adopt rather than trusting the frame.
    const outcome = applyDamage(
      liveFromGolden(),
      damage([
        { op: "truncate_grid", block_id: golden("snapshot-blocks.json").blocks[0]?.id, grid: "output", line_count: 1 },
        {
          op: "set_cursor",
          block_id: golden("snapshot-blocks.json").blocks[0]?.id,
          grid: "output",
          cursor: { row: 5, column: 0, visible: true, shape: "block", blink: false },
        },
      ]),
    );
    assert.deepEqual(outcome, { applied: false, reason: "invalid" });
  });

  it("refuses a cell the damage validator can already see is wrong", () => {
    // A wide cell in the last column is caught before the reducer runs, which is the cheaper place
    // to catch it. This asserts the viewer inherits that rather than reaching it.
    const snapshot = golden("snapshot-blocks.json");
    assert.throws(
      () =>
        damage([
          {
            op: "replace_row",
            block_id: snapshot.blocks[0]?.id,
            grid: "output",
            row: 0,
            cells: Array.from({ length: snapshot.columns }, (_, index) =>
              index === snapshot.columns - 1
                ? { text: "世", width: 2, style: 0 }
                : { text: "a", width: 1, style: 0 },
            ),
          },
        ]),
      (error: unknown) => error instanceof ContractError && error.code === "invalid_frame",
    );
  });
});
