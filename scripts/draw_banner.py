#!/usr/bin/env python3
"""
Draw assets/banner.png deterministically: the README hero banner.

The banner is pure vector content (wordmark + subtitle + a padlock icon whose
body holds a 4x4 partition grid with one slot held), so it is drawn with code
rather than an image model. Code gives crisp text edges (no JPEG ringing, no
generative halo), an exact 4x4 grid, a true lossless PNG, and clean metadata.

Dependency: matplotlib (pip install matplotlib).

Usage:
    python3 scripts/draw_banner.py                 # writes assets/banner.png
    python3 scripts/draw_banner.py out.png         # writes a draft elsewhere
"""

import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Arc, FancyBboxPatch, Rectangle

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ASSETS = os.path.join(ROOT, "assets")

# 2244x701 at 150 dpi -- matches the existing banner footprint (~3.2:1).
DPI = 150
FIG_W, FIG_H = 2244 / DPI, 701 / DPI
AR = 2244 / 701                      # axis is 0..AR wide, 0..1 tall

# Wordmark font. macOS ships these; on a host without them matplotlib falls
# back to DejaVu Sans (the committed PNG is the artifact, so the fallback only
# affects a from-scratch regeneration, which is rare for a static banner).
WORD_FONT = "Helvetica Neue"
SUB_FONT = "Helvetica Neue"

BLUE = "#2f6db0"      # "pg_" + padlock stroke (PostgreSQL-blue family)
INK = "#17191e"       # "xclaim"
GRAY = "#5b6673"      # subtitle
ORANGE = "#e8782e"    # the one held slot
GRIDLINE = "#2f6db0"

PNG_META = {"Software": None}


def draw_padlock(ax, cx, cy, scale=1.0):
    """A flat padlock: rounded body holding a 4x4 grid (one cell held),
    with a shackle arc above. cx, cy = body center."""
    bw, bh = 0.62 * scale, 0.56 * scale      # body size
    bx0, by0 = cx - bw / 2, cy - bh / 2

    # shackle: a half-ring above the body plus two short legs down to it
    sh_r = 0.20 * scale
    sh_cy = by0 + bh - 0.02 * scale
    lw = 9 * scale
    ax.add_patch(Arc((cx, sh_cy), 2 * sh_r, 2 * sh_r, theta1=0, theta2=180,
                     linewidth=lw, edgecolor=BLUE, capstyle="round", zorder=3))
    for sx in (cx - sh_r, cx + sh_r):
        ax.plot([sx, sx], [sh_cy, sh_cy - 0.13 * scale],
                color=BLUE, lw=lw, solid_capstyle="round", zorder=3)

    # body
    ax.add_patch(FancyBboxPatch(
        (bx0, by0), bw, bh,
        boxstyle=f"round,pad=0,rounding_size={0.05 * scale}",
        linewidth=7 * scale, edgecolor=BLUE, facecolor="white", zorder=4,
    ))

    # 4x4 grid of partition slots inside the body
    n = 4
    m = 0.085 * scale                       # inner margin
    gx0, gy0 = bx0 + m, by0 + m
    gw, gh = bw - 2 * m, bh - 2 * m
    cw, ch = gw / n, gh / n
    held = (1, 2)                           # (row-from-top, col) of the held slot
    for r in range(n):
        for c in range(n):
            x = gx0 + c * cw
            y = gy0 + (n - 1 - r) * ch
            if (r, c) == held:
                ax.add_patch(Rectangle((x, y), cw, ch, facecolor=ORANGE,
                                       edgecolor=ORANGE, linewidth=0, zorder=5))
            ax.add_patch(Rectangle((x, y), cw, ch, facecolor="none",
                                   edgecolor=GRIDLINE, linewidth=2.2 * scale,
                                   zorder=6))


def _text_width(ax, fig, s, font, size, weight):
    """Width of a string in axis data units (renders, measures, removes)."""
    t = ax.text(0, 0, s, fontfamily=font, fontsize=size, fontweight=weight)
    fig.canvas.draw()
    bb = t.get_window_extent(renderer=fig.canvas.get_renderer())
    inv = ax.transData.inverted()
    w = inv.transform((bb.x1, 0))[0] - inv.transform((bb.x0, 0))[0]
    t.remove()
    return w


def _fit_fontsize(ax, fig, s, font, target_w, weight, trial=100.0):
    """Font size (pt) that makes `s` exactly `target_w` data units wide."""
    return trial * target_w / _text_width(ax, fig, s, font, trial, weight)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ASSETS, "banner.png")
    subtitle = "high-cardinality transaction-level claims for PostgreSQL"

    fig = plt.figure(figsize=(FIG_W, FIG_H), dpi=DPI)
    fig.patch.set_facecolor("white")
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, AR)
    ax.set_ylim(0, 1)
    ax.axis("off")

    # Left text block occupies x in [x0, x0 + block_w]; the padlock sits to its
    # right with a comfortable gap. Both lines are width-fitted to block_w so
    # the wordmark and subtitle share a left edge and a right edge.
    x0 = 0.32
    block_w = 1.74

    # ---- wordmark: two-tone "pg_" + "xclaim", size fitted to block width ----
    y_word = 0.60
    word_size = _fit_fontsize(ax, fig, "pg_xclaim", WORD_FONT, block_w, "bold")
    t1 = ax.text(x0, y_word, "pg_", fontfamily=WORD_FONT, fontsize=word_size,
                 fontweight="bold", color=BLUE, ha="left", va="center", zorder=2)
    fig.canvas.draw()
    x_after = ax.transData.inverted().transform(
        (t1.get_window_extent(renderer=fig.canvas.get_renderer()).x1, 0))[0]
    ax.text(x_after, y_word, "xclaim", fontfamily=WORD_FONT, fontsize=word_size,
            fontweight="bold", color=INK, ha="left", va="center", zorder=2)

    # ---- subtitle, fitted to the same width so the right edges align ----
    sub_size = _fit_fontsize(ax, fig, subtitle, SUB_FONT, block_w, "normal")
    ax.text(x0, 0.255, subtitle, fontfamily=SUB_FONT, fontsize=sub_size,
            color=GRAY, ha="left", va="center")

    # ---- padlock, right of the text block ----
    draw_padlock(ax, cx=x0 + block_w + 0.70, cy=0.50, scale=0.86)

    fig.savefig(out, dpi=DPI, metadata=PNG_META, facecolor="white")
    plt.close(fig)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
