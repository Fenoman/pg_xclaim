#!/usr/bin/env python3
"""
Draw assets/concept.png deterministically: the partitioned-hash-table
architecture diagram used in README.md / README_EN.md.

This figure is fixed geometry (no measured data), so it is drawn with code
rather than an image model. An image model renders the routing arrows
inconsistently -- some reach their target cell, some are truncated -- and
cannot guarantee exactly 128 cells or exact label spelling. Code makes every
arrow land on its cell, the grid exactly 8x16, and the labels exact.

Dependency: matplotlib (pip install matplotlib).

Usage:
    python3 scripts/draw_concept.py            # writes assets/concept.png
"""

import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Arc, FancyBboxPatch, FancyArrowPatch

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ASSETS = os.path.join(ROOT, "assets")

# Palette (PostgreSQL-blue family + warm accent), matching the README banner.
NAVY = "#1f3a63"
BLUE = "#2f6db0"
LBLUE = "#7fa8d4"
OCHRE = "#c8862a"
ORANGE = "#e8782e"
INK = "#2b2b2b"
GRAYTEXT = "#555555"
CELL_FC = "#f3f6fb"
CELL_EC = "#c4d2e6"

PNG_META = {"Software": None}

# Grid geometry: 16 columns x 8 rows = 128 partitions.
NCOL, NROW = 16, 8
GX0, GY0 = 4.3, 1.55      # bottom-left of the grid (data coords)
CW, CH = 0.585, 0.60      # cell pitch
PAD = 0.07                # inner gap so cells read as separate tiles

# Three example keys routed to scattered partitions. The cells are
# deliberately NOT key % 128: get_hash_value() hashes the 16-byte key image,
# so the routing looks scrambled -- which is the point of "hash() & mask".
#   (key label, color, target column, target row-from-top, fill?)
ROUTES = [
    ("7", BLUE, 5, 0, False),
    ("42", OCHRE, 12, 3, True),     # filled -> "a slot actively held"
    ("1337", "#2a9d8f", 2, 6, False),
]


def cell_xy(col, row_from_top):
    """Bottom-left corner of a cell, row 0 at the TOP of the grid."""
    x = GX0 + col * CW
    y = GY0 + (NROW - 1 - row_from_top) * CH
    return x, y


def cell_y_center(row_from_top):
    _, y = cell_xy(0, row_from_top)
    return y + (CH - PAD) / 2


def bucket_cell(ax, col, row, edge=CELL_EC, fc=CELL_FC, lw=0.8):
    """One partition tile, kept intentionally plain. The accurate
    'each partition is an array of buckets, each a short chained list'
    statement lives in the bottom caption; a per-cell motif at this scale
    could only assert a misleading fixed bucket/chain count, so the tile
    stays a clean partition slot."""
    x, y = cell_xy(col, row)
    ax.add_patch(FancyBboxPatch(
        (x, y), CW - PAD, CH - PAD, boxstyle="round,pad=0,rounding_size=0.05",
        linewidth=lw, edgecolor=edge, facecolor=fc, zorder=2,
    ))


def key_token(ax, cx, cy, label, color):
    ax.add_patch(FancyBboxPatch(
        (cx - 0.42, cy - 0.27), 0.84, 0.54,
        boxstyle="round,pad=0,rounding_size=0.27",
        linewidth=1.4, edgecolor=color, facecolor="white", zorder=5,
    ))
    ax.text(cx, cy, label, ha="center", va="center",
            fontsize=13, color=INK, zorder=6)


def main():
    fig, ax = plt.subplots(figsize=(12.8, 7.2))  # 16:9 -> 1920x1080 at 150 dpi
    ax.set_xlim(0, 16.8)      # right headroom for the LWLock bracket + label
    ax.set_ylim(0, 8.0)
    ax.axis("off")

    # ---- the 128-partition grid ----
    for r in range(NROW):
        for c in range(NCOL):
            bucket_cell(ax, c, r)

    # column + row indices
    for c in range(NCOL):
        x, y = cell_xy(c, 0)
        ax.text(x + (CW - PAD) / 2, GY0 + NROW * CH + 0.06, str(c),
                ha="center", va="bottom", fontsize=8, color=GRAYTEXT)
    for r in range(NROW):
        _, y = cell_xy(0, r)
        ax.text(GX0 - 0.14, y + (CH - PAD) / 2, str(r),
                ha="right", va="center", fontsize=8.5, color=GRAYTEXT)

    ax.text(GX0 + NCOL * CW / 2, GY0 + NROW * CH + 0.42,
            "128 partitions (default)", ha="center", va="bottom",
            fontsize=15, fontweight="bold", color=NAVY)

    # ---- hash() & mask operator ----
    hb_cx, hb_cy = 2.35, 3.55
    hb_w, hb_h = 1.86, 0.72
    ax.add_patch(FancyBboxPatch(
        (hb_cx - hb_w / 2, hb_cy - hb_h / 2), hb_w, hb_h,
        boxstyle="round,pad=0,rounding_size=0.08",
        linewidth=1.4, edgecolor=NAVY, facecolor="#eef3fa", zorder=5,
    ))
    ax.text(hb_cx, hb_cy, "hash() & mask", ha="center", va="center",
            fontsize=11, color=NAVY, zorder=6)

    # ---- three example keys + routing ----
    key_ys = [4.55, 3.55, 2.55]
    for (label, color, col, row, fill), ky in zip(ROUTES, key_ys):
        key_token(ax, 0.85, ky, label, color)
        # key -> hash box (solid connector)
        ax.plot([1.30, hb_cx - hb_w / 2], [ky, hb_cy], color="#90a4bd",
                lw=1.1, zorder=4)

        # hash box -> target PARTITION: a clean two-leg dashed route. Leg 1
        # diagonal to just left of the grid at the target row's height; leg 2
        # a horizontal arrowhead landing on the tile's left border -- pointing
        # at the partition as a whole (key -> partition), not at any one bucket
        # inside it.
        cx0, cy0 = cell_xy(col, row)
        rcy = cell_y_center(row)
        tgt_x = cx0 + 0.04            # the destination tile's left border
        entry_x = GX0 - 0.18
        ax.plot([hb_cx + hb_w / 2, entry_x], [hb_cy, rcy],
                color=color, lw=1.2, ls=(0, (4, 3)), zorder=4)
        ax.add_patch(FancyArrowPatch(
            (entry_x, rcy), (tgt_x, rcy),
            arrowstyle="-|>", mutation_scale=12, lw=1.2,
            linestyle="--", color=color, zorder=7,
        ))
        # highlight the destination cell
        x, y = cell_xy(col, row)
        ax.add_patch(FancyBboxPatch(
            (x, y), CW - PAD, CH - PAD,
            boxstyle="round,pad=0,rounding_size=0.05",
            linewidth=2.0, edgecolor=color,
            facecolor=(ORANGE if fill else "none"),
            alpha=(0.85 if fill else 1.0), zorder=4,
        ))

    ax.text(0.85, 1.95, "Example keys", ha="center", va="top",
            fontsize=9.5, color=GRAYTEXT)

    # ---- ShmemInitHash caption (top-left) ----
    ax.text(0.15, 7.62, "ShmemInitHash", ha="left", va="top",
            fontsize=12.5, fontweight="bold", color=NAVY)
    ax.text(0.15, 7.18,
            "Allocates the partitioned hash\ntable in shared memory with\n"
            "128 partitions.",
            ha="left", va="top", fontsize=9.5, color=GRAYTEXT)

    # ---- one LWLock per partition (right side) ----
    lock_x = GX0 + NCOL * CW + 0.30
    top_y = GY0 + NROW * CH - 0.10
    bot_y = GY0 + 0.10
    # a square bracket spanning the grid rows
    ax.plot([lock_x, lock_x + 0.18, lock_x + 0.18, lock_x],
            [top_y, top_y, bot_y, bot_y], color=NAVY, lw=1.3, zorder=3)
    # a small padlock glyph: shackle (half-circle arc) above a body box
    pk_x, pk_y = lock_x + 0.60, (top_y + bot_y) / 2
    ax.add_patch(Arc(
        (pk_x, pk_y + 0.14), 0.22, 0.26, theta1=0, theta2=180,
        linewidth=1.5, edgecolor=NAVY, zorder=3,
    ))
    ax.add_patch(FancyBboxPatch(
        (pk_x - 0.17, pk_y - 0.17), 0.34, 0.30,
        boxstyle="round,pad=0,rounding_size=0.05",
        linewidth=1.5, edgecolor=NAVY, facecolor="#eef3fa", zorder=4,
    ))
    ax.text(pk_x + 0.34, pk_y, "one LWLock\nper partition", ha="left",
            va="center", fontsize=10.5, color=NAVY)

    # ---- bottom caption ----
    cap_cx = GX0 + NCOL * CW / 2
    ax.text(cap_cx, 1.12, "HASH_PARTITION + HASH_BLOBS",
            ha="center", va="top", fontsize=13, fontweight="bold", color=NAVY)
    ax.text(cap_cx, 0.66,
            "Each partition is an array of hash buckets (HASH_BLOBS);\n"
            "each bucket is a short chained list of entries.",
            ha="center", va="top", fontsize=10, color=GRAYTEXT)

    fig.subplots_adjust(left=0.005, right=0.995, top=0.995, bottom=0.005)
    out = os.path.join(ASSETS, "concept.png")
    fig.savefig(out, dpi=150, metadata=PNG_META)
    plt.close(fig)
    print("wrote assets/concept.png")


if __name__ == "__main__":
    main()
