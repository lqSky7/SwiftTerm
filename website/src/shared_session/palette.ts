/**
 * Colour resolution for the viewer.
 *
 * A style carries either an explicit RGB triple or an index into a palette, and the wire contract
 * does not ship the palette itself — the snapshot has no palette table, so an index is an index into
 * the standard xterm 256-colour palette. That is a decision, not a default: the alternative would be
 * for the viewer to invent a theme, and then the same stream would render differently on two
 * machines. B2B's encoder is the other half of the agreement, and it must use this palette too.
 *
 * The flag bits are the eight the contract names, in the order it names them. A renderer reads the
 * bit; it never maps a flag to a font name or a CSS class, because the host has no way to know what
 * those would be.
 */

import type { WireColor, WireStyle } from "../../../contracts/ts/wire";

/** The eight style bits, in the contract's order. Bit 0 is the least significant. */
export const STYLE_FLAG = {
  bold: 1 << 0,
  dim: 1 << 1,
  italic: 1 << 2,
  underline: 1 << 3,
  blink: 1 << 4,
  inverse: 1 << 5,
  hidden: 1 << 6,
  strike: 1 << 7,
} as const;

export function hasFlag(flags: number, flag: number): boolean {
  return (flags & flag) !== 0;
}

/** The six levels the 6×6×6 colour cube is built from. Not evenly spaced, and that is the standard. */
const CUBE_LEVELS = [0, 95, 135, 175, 215, 255] as const;

/**
 * The standard xterm 256-colour palette.
 *
 * Built rather than written out: the cube and the greyscale ramp are generated, and only the
 * sixteen system colours are literal, because those are the only ones that are actually chosen by
 * hand. A table of 256 hex strings would be 256 chances to make a typo.
 */
export const PALETTE: readonly string[] = buildPalette();

function buildPalette(): string[] {
  const entries: string[] = [
    // The sixteen system colours, in the order every terminal has used since the beginning. The
    // second eight are the "bright" variants, not a different hue.
    "#000000", "#800000", "#008000", "#808000",
    "#000080", "#800080", "#008080", "#c0c0c0",
    "#808080", "#ff0000", "#00ff00", "#ffff00",
    "#0000ff", "#ff00ff", "#00ffff", "#ffffff",
  ];

  for (const r of CUBE_LEVELS) {
    for (const g of CUBE_LEVELS) {
      for (const b of CUBE_LEVELS) entries.push(rgb(r, g, b));
    }
  }

  // The 24-step greyscale ramp starts at 8 rather than 0 so it does not duplicate black, and steps
  // by 10 so it does not duplicate the last cube entries either.
  for (let step = 0; step < 24; step += 1) {
    const level = 8 + step * 10;
    entries.push(rgb(level, level, level));
  }

  return entries;
}

function rgb(r: number, g: number, b: number): string {
  return `#${hex(r)}${hex(g)}${hex(b)}`;
}

function hex(value: number): string {
  return value.toString(16).padStart(2, "0");
}

/**
 * A wire colour as a CSS colour string.
 *
 * An out-of-range palette index falls back to the default rather than throwing: the contract already
 * refuses an index above 255, so reaching here with one means the contract and this file disagree,
 * and painting nothing is a worse failure than painting the default.
 */
export function resolveColor(color: WireColor): string {
  if (color.kind === "rgb") return rgb(color.r, color.g, color.b);
  return PALETTE[color.index] ?? PALETTE[0] ?? "#000000";
}

/** The foreground and background a cell with this style should be drawn in, after `inverse`. */
export function resolveStyle(style: WireStyle | undefined): {
  readonly fg: string;
  readonly bg: string;
  readonly bold: boolean;
  readonly italic: boolean;
  readonly underline: boolean;
  readonly dim: boolean;
  readonly strike: boolean;
} {
  // An index the table does not hold is a default style rather than a crash. The contract requires
  // every cell's index to be inside the table, so this is the defensive branch.
  if (style === undefined) {
    return {
      fg: DEFAULT_FG,
      bg: DEFAULT_BG,
      bold: false,
      italic: false,
      underline: false,
      dim: false,
      strike: false,
    };
  }

  const inverse = hasFlag(style.flags, STYLE_FLAG.inverse);
  const hidden = hasFlag(style.flags, STYLE_FLAG.hidden);
  const foreground = inverse ? resolveColor(style.bg) : resolveColor(style.fg);
  const background = inverse ? resolveColor(style.fg) : resolveColor(style.bg);

  return {
    // `hidden` paints the background and not the glyph, which is what a terminal does with it.
    fg: hidden ? background : foreground,
    bg: background,
    bold: hasFlag(style.flags, STYLE_FLAG.bold),
    italic: hasFlag(style.flags, STYLE_FLAG.italic),
    underline: hasFlag(style.flags, STYLE_FLAG.underline),
    dim: hasFlag(style.flags, STYLE_FLAG.dim),
    strike: hasFlag(style.flags, STYLE_FLAG.strike),
  };
}

/** Palette index 0 is the default background, which is what the contract says index 0 means. */
export const DEFAULT_BG = PALETTE[0] ?? "#000000";
export const DEFAULT_FG = PALETTE[7] ?? "#c0c0c0";
