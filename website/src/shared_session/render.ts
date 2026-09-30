/**
 * The grid renderer.
 *
 * Canvas draws the cells; the DOM draws everything that is text a person reads as text — a block's
 * command, its exit code, the error line. That split is deliberate and it is a security boundary as
 * much as a rendering one: a terminal's content is attacker-adjacent data, and the only way it
 * reaches the page is as **pixels** or as a React text node. There is no `innerHTML` anywhere in
 * this file or the page that uses it, so a command containing `<script>` is a row of glyphs.
 *
 * Cells are addressed by the column arithmetic the contract defines: a width-2 cell occupies two
 * columns and the width-0 cell that follows it is its continuation, which draws nothing. Getting
 * that wrong shifts every glyph after it, so the loop advances by the cell's width rather than by
 * one.
 */

import type { WireCell, WireGrid, WireRow, WireStyle } from "../../../contracts/ts/wire.ts";
import { DEFAULT_BG, resolveStyle } from "./palette.ts";

/** Everything the renderer needs about one cell box, measured once per font and reused. */
export interface CellMetrics {
  readonly width: number;
  readonly height: number;
  readonly baseline: number;
}

export interface GridOptions {
  readonly styles: readonly WireStyle[];
  readonly fontFamily: string;
  readonly fontSize: number;
  readonly metrics: CellMetrics;
  /** The cell the cursor is drawn in, or null. Passed in so the renderer holds no state. */
  readonly cursorVisible: boolean;
}

/**
 * Measure one cell box.
 *
 * The advance width is taken from a monospace digit rather than from the font's own metrics,
 * because a cell is one column and the font's average character width is not. `height` is the line
 * box, and `baseline` is where the glyph sits inside it.
 */
export function measureCells(
  ctx: CanvasRenderingContext2D,
  fontFamily: string,
  fontSize: number,
): CellMetrics {
  ctx.font = `${fontSize}px ${fontFamily}`;
  const width = ctx.measureText("0").width;
  const height = Math.round(fontSize * 1.35);
  const metrics = ctx.measureText("M");
  const ascent = metrics.actualBoundingBoxAscent || fontSize * 0.75;
  return { width, height, baseline: Math.round((height + ascent) / 2) };
}

/** The pixel size a grid needs at these metrics. `columns` cells wide, one line per row. */
export function gridPixelSize(
  grid: WireGrid,
  metrics: CellMetrics,
  columns: number,
): { width: number; height: number } {
  return {
    width: Math.ceil(columns * metrics.width),
    height: grid.lines.length * metrics.height,
  };
}

/**
 * Draw one grid into a canvas.
 *
 * The canvas is sized in device pixels and scaled in CSS pixels, so a retina display gets a sharp
 * glyph without the cell arithmetic having to know about it.
 */
export function drawGrid(canvas: HTMLCanvasElement, grid: WireGrid, options: GridOptions): void {
  const ratio = typeof devicePixelRatio === "number" ? devicePixelRatio : 1;
  const columns = Math.max(1, widestRow(grid.lines));
  const { width, height } = gridPixelSize(grid, options.metrics, columns);

  canvas.width = Math.max(1, Math.floor(width * ratio));
  canvas.height = Math.max(1, Math.floor(height * ratio));
  canvas.style.width = `${width}px`;
  canvas.style.height = `${height}px`;

  const ctx = canvas.getContext("2d");
  if (ctx === null) return;
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);

  // The grid's own background first, so a cell that does not set one shows the terminal's default
  // rather than the page's.
  ctx.fillStyle = DEFAULT_BG;
  ctx.fillRect(0, 0, width, height);

  ctx.font = `${options.fontSize}px ${options.fontFamily}`;
  ctx.textBaseline = "alphabetic";
  // Ligatures would merge `->` into one glyph and the cell count would stop matching the host's.
  ctx.fontKerning = "none";

  for (let row = 0; row < grid.lines.length; row += 1) {
    const line = grid.lines[row];
    if (line === undefined) continue;
    drawRow(ctx, line, row, options);
  }

  if (options.cursorVisible && grid.cursor.visible) {
    drawCursor(ctx, grid, options);
  }
}

function drawRow(
  ctx: CanvasRenderingContext2D,
  line: WireRow,
  row: number,
  options: GridOptions,
): void {
  const y = row * options.metrics.height;
  let column = 0;

  for (const cell of line) {
    // A continuation cell occupies no column of its own: the wide cell before it already advanced
    // past this position, and drawing here would shift everything after it.
    if (cell.width === 0) continue;

    const style = resolveStyle(options.styles[cell.style]);
    const span = cell.width === 2 ? 2 : 1;
    const x = column * options.metrics.width;

    if (style.bg !== DEFAULT_BG) {
      ctx.fillStyle = style.bg;
      ctx.fillRect(x, y, span * options.metrics.width, options.metrics.height);
    }

    if (cell.text !== " " && cell.text !== "") {
      ctx.fillStyle = style.fg;
      const font = `${style.italic ? "italic " : ""}${style.bold ? "bold " : ""}${options.fontSize}px ${options.fontFamily}`;
      if (font !== ctx.font) ctx.font = font;
      ctx.fillText(cell.text, x, y + options.metrics.baseline);

      if (style.underline || style.strike) {
        const thickness = Math.max(1, Math.round(options.fontSize / 14));
        ctx.fillStyle = style.fg;
        const lineY = style.underline
          ? y + options.metrics.height - thickness
          : y + Math.round(options.metrics.height * 0.6);
        ctx.fillRect(x, lineY, span * options.metrics.width, thickness);
      }
      ctx.font = `${options.fontSize}px ${options.fontFamily}`;
    }

    column += span;
  }
}

function drawCursor(ctx: CanvasRenderingContext2D, grid: WireGrid, options: GridOptions): void {
  const { cursor } = grid;
  const x = cursor.column * options.metrics.width;
  const y = cursor.row * options.metrics.height;
  const style = resolveStyle(options.styles[0]);

  ctx.save();
  if (cursor.shape === "block") {
    // A block cursor is the cell painted in reverse, which is how a terminal shows it: the glyph
    // stays legible rather than disappearing under a solid rectangle.
    ctx.globalAlpha = 0.55;
    ctx.fillStyle = style.fg;
    ctx.fillRect(x, y, options.metrics.width, options.metrics.height);
  } else {
    const thickness = cursor.shape === "bar" ? Math.max(1, Math.round(options.metrics.width / 6)) : Math.max(1, Math.round(options.fontSize / 12));
    const width = cursor.shape === "bar" ? thickness : options.metrics.width;
    ctx.fillStyle = style.fg;
    ctx.fillRect(x, y + options.metrics.height - thickness, width, thickness);
  }
  ctx.restore();
}

/** The column count a grid actually uses, which is what the canvas is sized from. */
function widestRow(lines: readonly WireRow[]): number {
  let widest = 1;
  for (const line of lines) {
    let columns = 0;
    for (const cell of line) columns += cell.width === 0 ? 0 : cell.width === 2 ? 2 : 1;
    if (columns > widest) widest = columns;
  }
  return widest;
}

/**
 * The plain text of one grid.
 *
 * Used for the local copy affordance and for an accessible text alternative to the canvas. It is
 * built here rather than in the page so the same wide-cell arithmetic applies: a continuation cell
 * contributes no character, or the copied text would not match what is on screen.
 */
export function gridText(grid: WireGrid): string {
  return grid.lines
    .map((line) => {
      let text = "";
      for (const cell of line) {
        if (cell.width === 0) continue;
        text += cell.text === " " ? " " : cell.text;
      }
      return text.replace(/\s+$/, "");
    })
    .join("\n");
}

/** The text of one row, for the accessible description of a grid. */
export function rowText(line: WireRow): string {
  let text = "";
  for (const cell of line as readonly WireCell[]) {
    if (cell.width === 0) continue;
    text += cell.text;
  }
  return text.replace(/\s+$/, "");
}
