/**
 * The viewer's state, as a pure reducer.
 *
 * This mirrors `crates/shared_session/src/WireStreamState.swift` operation for operation. That is
 * not a coincidence and not a nice-to-have: the host and the browser must agree on what a damage
 * frame means, or the browser renders a state the host never sent. Where the two could differ, this
 * file follows the Swift one and says so in a comment.
 *
 * Two rules carry the weight:
 *
 *   * **One epoch, contiguous sequences.** A damage frame is applied only if its epoch matches and
 *     its `seq` is exactly the next one, with `base_seq` pinned to the last applied sequence. A
 *     delta computed against an older state would be applied to a newer one and silently corrupt
 *     the view, so `base_seq` is checked and not merely assumed.
 *   * **The result is re-validated before it is adopted.** Every operation checks only its own local
 *     preconditions — bounds, existence, geometry — and the resulting state is then run through the
 *     contract's `validateSnapshot`. That is what lets one frame truncate a grid and move the cursor
 *     in the same message: an eager per-operation check would reject an intermediate state that
 *     never ships.
 *
 * Nothing here touches the DOM, so the whole thing is testable without a browser.
 */

import {
  LIMITS,
  validateSnapshot,
  type WireBlock,
  type WireDamage,
  type WireDamageOp,
  type WireEditor,
  type WireGridKind,
  type WireMode,
  type WireRow,
  type WireSnapshot,
  type WireStyle,
  type WireViewport,
} from "../../../contracts/ts/wire.ts";

export type ViewerStatus =
  | "idle"
  | "connecting"
  | "waiting"
  | "live"
  | "resyncing"
  | "ended"
  | "failed";

/**
 * The state that exists only once a snapshot has arrived.
 *
 * `viewport` and `editor` are not optional here, because a snapshot always carries them and damage
 * cannot be applied before one. Modelling it this way means the type system, rather than a runtime
 * check, is what stops a delta being applied to an empty view.
 */
export interface LiveState {
  readonly epoch: string;
  /** The highest sequence applied. A viewer at this value has seen everything up to it. */
  readonly lastSeq: number;
  readonly mode: WireMode;
  readonly columns: number;
  readonly rows: number;
  readonly styles: readonly WireStyle[];
  readonly blocks: readonly WireBlock[];
  readonly viewport: WireViewport;
  readonly editor: WireEditor;
}

export interface ViewerState {
  readonly status: ViewerStatus;
  readonly live: LiveState | null;
  /** Why the last frame was refused, as a short reason for the status line. Never terminal text. */
  readonly lastRefusal: string | null;
}

/** Why a frame could not be applied. Every one of these is a request for a fresh snapshot. */
export type RefusalReason = "no_snapshot" | "stale_epoch" | "duplicate" | "gap" | "invalid";

export type DamageOutcome =
  | { readonly applied: true; readonly live: LiveState }
  | { readonly applied: false; readonly reason: RefusalReason };

export function initialState(): ViewerState {
  return { status: "idle", live: null, lastRefusal: null };
}

export function withStatus(state: ViewerState, status: ViewerStatus): ViewerState {
  return { ...state, status };
}

export function withRefusal(state: ViewerState, reason: RefusalReason | null): ViewerState {
  return { ...state, lastRefusal: reason };
}

/**
 * Adopt a snapshot. This is the only way into `LiveState`, and it replaces every field at once.
 *
 * A snapshot is the only carrier of an epoch, a geometry or a mode change, so there is no partial
 * version of this: whatever was on screen is discarded in one step, which is why a stale cell cannot
 * survive a transition.
 */
export function applySnapshot(state: ViewerState, snapshot: WireSnapshot): ViewerState {
  return {
    status: "live",
    lastRefusal: null,
    live: {
      epoch: snapshot.epoch,
      lastSeq: Number(snapshot.seq),
      mode: snapshot.mode,
      columns: snapshot.columns,
      rows: snapshot.rows,
      styles: snapshot.styles,
      blocks: snapshot.blocks,
      viewport: snapshot.viewport,
      editor: snapshot.editor,
    },
  };
}

/**
 * Apply a damage frame, or say why not.
 *
 * The caller turns a refusal into a `resync` request. It is never treated as a no-op: a viewer that
 * silently ignores a frame it cannot apply is a viewer showing something the host has moved past.
 */
export function applyDamage(state: ViewerState, damage: WireDamage): DamageOutcome {
  const live = state.live;
  if (live === null) return { applied: false, reason: "no_snapshot" };

  // A different epoch means the host restarted its output. Only a snapshot can cross that boundary.
  if (damage.epoch !== live.epoch) return { applied: false, reason: "stale_epoch" };

  const seq = Number(damage.seq);
  const base = Number(damage.base_seq);

  // Already applied. The relay can replay, so a duplicate is expected and is not an error.
  if (seq <= live.lastSeq) return { applied: false, reason: "duplicate" };

  // Contiguity. The contract's damage validator already requires `base_seq === seq - 1`, so this is
  // the check that actually decides: a frame two sequences ahead has been computed against a state
  // this viewer has not reached, and applying it would corrupt the view silently. `base_seq` is
  // restated because the reducer's contract is "the next sequence, based on what was applied", and
  // stating it here means the rule survives a caller that validated the frame some other way.
  if (seq !== live.lastSeq + 1 || base !== live.lastSeq) {
    return { applied: false, reason: "gap" };
  }

  let next: LiveState;
  try {
    next = applyOperations(live, damage.changes);
  } catch {
    return { applied: false, reason: "invalid" };
  }

  // The whole point of applying to a copy: nothing reaches the renderer until it is known to be a
  // state the host could have produced.
  try {
    validateSnapshot({
      version: LIMITS.schema_version,
      epoch: next.epoch,
      seq: String(next.lastSeq),
      mode: next.mode,
      columns: next.columns,
      rows: next.rows,
      styles: next.styles,
      blocks: next.blocks,
      viewport: next.viewport,
      editor: next.editor,
    });
  } catch {
    return { applied: false, reason: "invalid" };
  }

  return { applied: true, live: next };
}

/**
 * Apply every operation to a copy, then return it.
 *
 * Copy-on-write per touched block rather than a deep clone of everything: a snapshot may hold 2000
 * grid lines and a damage frame usually touches one block, so cloning the world per frame would be
 * the relay's memory bound undone by the viewer.
 */
function applyOperations(live: LiveState, operations: readonly WireDamageOp[]): LiveState {
  let blocks = live.blocks;
  let viewport = live.viewport;
  let editor = live.editor;

  for (const operation of operations) {
    switch (operation.op) {
      case "insert_block": {
        if (blocks.length >= LIMITS.maxBlocks) {
          throw new Error("insert_block past the block cap");
        }
        if (blocks.some((block) => block.id === operation.block.id)) {
          throw new Error(`insert_block reuses ${operation.block.id}`);
        }
        const afterID = operation.after_id;
        if (afterID === undefined) {
          // No anchor means the front, which is how the Swift implementation reads it: a block with
          // no predecessor is a block that goes first.
          blocks = [operation.block, ...blocks];
          break;
        }
        const index = blocks.findIndex((block) => block.id === afterID);
        if (index < 0) throw new Error(`insert_block after unknown ${afterID}`);
        blocks = [...blocks.slice(0, index + 1), operation.block, ...blocks.slice(index + 1)];
        break;
      }

      case "remove_block": {
        // An unknown id is an error, not a no-op: a silent no-op would let a desynchronised viewer
        // keep showing a block the host already dropped.
        const index = blocks.findIndex((block) => block.id === operation.block_id);
        if (index < 0) throw new Error(`remove_block unknown ${operation.block_id}`);
        blocks = [...blocks.slice(0, index), ...blocks.slice(index + 1)];
        break;
      }

      case "replace_header": {
        const index = requireIndex(blocks, operation.block_id);
        const block = cloneBlock(requireBlock(blocks, index));
        block.command = operation.command;
        block.state = operation.state;
        // Assigned rather than spread so an omitted field clears the old value. A frame that drops
        // `exit_code` means the block has no exit code, not that it keeps the previous one.
        if (operation.exit_code === undefined) delete block.exit_code;
        else block.exit_code = operation.exit_code;
        if (operation.duration_ms === undefined) delete block.duration_ms;
        else block.duration_ms = operation.duration_ms;
        blocks = replaceAt(blocks, index, block);
        break;
      }

      case "set_collapsed": {
        const index = requireIndex(blocks, operation.block_id);
        const block = cloneBlock(requireBlock(blocks, index));
        block.collapsed = operation.collapsed;
        blocks = replaceAt(blocks, index, block);
        break;
      }

      case "replace_row": {
        const index = requireIndex(blocks, operation.block_id);
        const block = cloneBlock(requireBlock(blocks, index));
        const lines = linesOf(block, operation.grid);
        const row = operation.row;
        // Append at the current length only. A row index past the end would leave a gap the viewer
        // has nothing to draw in.
        if (row > lines.length) {
          throw new Error(`replace_row ${row} past ${lines.length} lines`);
        }
        if (row === lines.length) lines.push(operation.cells);
        else lines[row] = operation.cells;
        blocks = replaceAt(blocks, index, block);
        break;
      }

      case "truncate_grid": {
        const index = requireIndex(blocks, operation.block_id);
        const block = cloneBlock(requireBlock(blocks, index));
        const lines = linesOf(block, operation.grid);
        const lineCount = operation.line_count;
        if (lineCount > lines.length) {
          throw new Error(`truncate_grid ${lineCount} beyond ${lines.length} lines`);
        }
        lines.length = lineCount;
        blocks = replaceAt(blocks, index, block);
        break;
      }

      case "set_cursor": {
        const index = requireIndex(blocks, operation.block_id);
        const block = cloneBlock(requireBlock(blocks, index));
        if (operation.grid === "header") block.header.cursor = operation.cursor;
        else block.output.cursor = operation.cursor;
        blocks = replaceAt(blocks, index, block);
        break;
      }

      case "replace_editor":
        editor = operation.editor;
        break;

      case "replace_viewport":
        viewport = operation.viewport;
        break;
    }
  }

  return { ...live, blocks, viewport, editor, lastSeq: live.lastSeq + 1 };
}

function requireBlock(blocks: readonly WireBlock[], index: number): WireBlock {
  const block = blocks[index];
  if (block === undefined) throw new Error(`no block at ${index}`);
  return block;
}

function requireIndex(blocks: readonly WireBlock[], blockID: string): number {
  const index = blocks.findIndex((block) => block.id === blockID);
  if (index < 0) throw new Error(`unknown block ${blockID}`);
  return index;
}

function replaceAt(blocks: readonly WireBlock[], index: number, block: WireBlock): WireBlock[] {
  const next = blocks.slice();
  next[index] = block;
  return next;
}

/** A shallow copy of one block, with its grid lines copied so the original cannot be mutated. */
function cloneBlock(block: WireBlock): WireBlock {
  return {
    ...block,
    header: { ...block.header, lines: block.header.lines.slice() },
    output: { ...block.output, lines: block.output.lines.slice() },
  };
}

function linesOf(block: WireBlock, grid: WireGridKind): WireRow[] {
  return grid === "header" ? block.header.lines : block.output.lines;
}

/**
 * The last sequence the viewer has applied, for a `resume` frame after a reconnect.
 *
 * Returns null before the first snapshot: a viewer that has applied nothing has nothing to resume
 * from, and the relay's answer to `resume 0` is a full replay or a resync rather than a delta.
 */
export function resumeSeq(live: LiveState | null): string | null {
  return live === null ? null : String(live.lastSeq);
}
