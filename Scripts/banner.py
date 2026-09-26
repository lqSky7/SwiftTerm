#!/usr/bin/env python3
"""Print the swiftTerm logo as truecolor half-block art.

The app draws its mark from `app/assets/swiftTerm.icon/Assets/SVG Image.svg`: two chevrons,
stroked, round caps. This rasterises those same two polylines and emits them as `▀` cells with
24-bit colour, because the terminal has no image protocol to hand an actual PNG to.

By default the mark is sized to fill the window it is run in and wears the icon's crimson
gradient. `--color ffffff` flattens it to one colour.

    ./Scripts/banner.py                    # fills the window, brand gradient
    ./Scripts/banner.py --color ffffff     # fills the window, white
    ./Scripts/banner.py --width 64         # an explicit size instead of filling
    ./Scripts/banner.py --plain            # no colour, for a log or a diff

Stdlib only, so it runs anywhere the project's `python3` does.
"""

import argparse
import shutil
import sys

# The two chevrons, in the SVG's own 100x80 box. Same order as the file.
STROKES = (
    ((25, 65), (29, 34), (54, 53)),
    ((59, 49), (62, 19), (88, 38)),
)
BOX = (100.0, 80.0)

# The icon's own gradient: deep crimson at the tail, pale rose at the tip.
RAMP = ((0x7A, 0x00, 0x24), (0xD4, 0x11, 0x4A), (0xFF, 0xB3, 0xC6))
WHITE = (0xFF, 0xFF, 0xFF)

UPPER, LOWER = "▀", "▄"
RESET = "\x1b[0m"


def ramp(t, flat=None):
    """Sample the three-stop gradient at t in 0..1, or return `flat` if one was asked for."""
    if flat:
        return flat
    t = min(max(t, 0.0), 1.0) * (len(RAMP) - 1)
    i = min(int(t), len(RAMP) - 2)
    f = t - i
    a, b = RAMP[i], RAMP[i + 1]
    return tuple(round(a[c] + (b[c] - a[c]) * f) for c in range(3))


def distance_to_segment(p, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    span = dx * dx + dy * dy
    t = 0.0 if span == 0 else ((p[0] - ax) * dx + (p[1] - ay) * dy) / span
    t = min(max(t, 0.0), 1.0)
    return ((p[0] - ax - t * dx) ** 2 + (p[1] - ay - t * dy) ** 2) ** 0.5


def raster(width, height, stroke, feather):
    """Coverage in 0..1 for every subpixel, plus the gradient parameter at each one.

    `height` counts *cells*, and a cell holds two subpixels, so the grid the logo is drawn on is
    `width` x `2 * height` — square subpixels, which is what keeps the chevrons' angles honest.
    """
    sub_h = height * 2
    unit = min(width / BOX[0], sub_h / BOX[1])  # one SVG unit, in subpixels
    ox = (width - BOX[0] * unit) / 2
    oy = (sub_h - BOX[1] * unit) / 2
    half = stroke * unit / 2

    grid = []
    for sy in range(sub_h):
        row = []
        for sx in range(width):
            p = ((sx + 0.5 - ox) / unit, (sy + 0.5 - oy) / unit)
            d = min(distance_to_segment(p, a, b) for s in STROKES for a, b in zip(s, s[1:]))
            # A half block has no alpha channel to spend, so a partly covered subpixel would have to
            # be painted at full strength and the stroke would come out fat. Coverage is therefore
            # decided, not blended: `feather` just moves where the edge falls.
            cover = 1.0 if d <= half + feather else 0.0
            # The gradient runs along the mark's diagonal, tail to tip.
            t = (p[0] - 25) / (88 - 25) * 0.7 + (1 - p[1] / 80) * 0.3
            row.append((cover, t))
        grid.append(row)
    return grid


def render(width, height, stroke, plain, feather, flat=None):
    grid = raster(width, height, stroke, feather)
    lines = []
    for row in range(height):
        top, bottom = grid[row * 2], grid[row * 2 + 1]
        out = []
        for col in range(width):
            (ct, tt), (cb, tb) = top[col], bottom[col]
            if plain:
                out.append(UPPER if ct else (LOWER if cb else " "))
                continue
            if not ct and not cb:
                # A reset, not a bare space: the previous cell's background is still in effect, and
                # a space under it paints a solid block.
                out.append(RESET + " ")
                continue
            ft, fb = ramp(tt, flat), ramp(tb, flat)
            if ct and cb:
                out.append(f"\x1b[38;2;{ft[0]};{ft[1]};{ft[2]}m\x1b[48;2;{fb[0]};{fb[1]};{fb[2]}m{UPPER}")
            elif ct:
                out.append(f"\x1b[49m\x1b[38;2;{ft[0]};{ft[1]};{ft[2]}m{UPPER}")
            else:
                out.append(f"\x1b[49m\x1b[38;2;{fb[0]};{fb[1]};{fb[2]}m{LOWER}")
        lines.append("".join(out) + ("" if plain else RESET))
    return lines


def fit(cols, rows, fill):
    """The largest `(width, height)` in cells whose mark fits inside `cols` x `rows`."""
    # A cell holds two subpixels, so the logo's 100x80 box wants height = width * 0.4 for square
    # subpixels — hence a width ceiling of `rows / 0.4` as well as the obvious one.
    width = max(8, min(int(cols * fill), int(rows * fill * 2 * BOX[0] / BOX[1])))
    return width, max(1, round(width / BOX[0] * BOX[1] / 2))


def main():
    ap = argparse.ArgumentParser(description="swiftTerm logo, as terminal art.")
    ap.add_argument("--width", type=int, default=None, help="columns (default: fill the window)")
    ap.add_argument("--height", type=int, default=None, help="rows (default: from the aspect)")
    ap.add_argument("--stroke", type=float, default=9.0, help="stroke width in SVG units")
    ap.add_argument("--feather", type=float, default=0.0, help="subpixels of edge bias")
    ap.add_argument("--plain", action="store_true", help="no colour")
    ap.add_argument("--color", default=None, help="one flat colour, e.g. ffffff")
    ap.add_argument("--pad", type=int, default=None, help="left margin (default: centre it)")
    ap.add_argument("--fill", type=float, default=1.0, help="fraction of the window to fill")
    a = ap.parse_args()

    cols, rows = shutil.get_terminal_size((100, 40))
    width, height = fit(cols, rows, a.fill)
    width, height = a.width or width, a.height or height
    flat = tuple(int(a.color[i:i + 2], 16) for i in (0, 2, 4)) if a.color else None

    pad = " " * (a.pad if a.pad is not None else max(0, (cols - width) // 2))
    sys.stdout.write("\n" * max(0, (rows - height - 1) // 2))
    for line in render(width, height, a.stroke, a.plain, a.feather, flat):
        sys.stdout.write(pad + line + "\n")
    sys.stdout.write(RESET)


if __name__ == "__main__":
    main()
