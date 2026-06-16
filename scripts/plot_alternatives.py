#!/usr/bin/env python3
"""
Render the three data-driven figures used in README.md / README_EN.md
straight from the authoritative benchmark CSVs, so the published numbers
can never drift from the measurements.

Each figure is emitted in two languages. The bare filename is the Russian
(primary) asset; the English one carries an _en suffix -- the same naming
convention docs/ already uses (runbook.md / runbook_en.md):

    assets/overview.png  / overview_en.png             headline throughput
    assets/perf-tradeoffs.png / perf-tradeoffs_en.png  throughput / p95 / WAL
    assets/sorted-insert-finding.png / ..._en.png      sorted-vs-unsorted crossover

Source of truth (read, never hard-coded):
    docs/perf/bench-alternatives-20260524-disjoint-pg17.csv
    docs/perf/bench-alternatives-20260524-overlap-pg17.csv

A plotting library is used on purpose: image-generation models cannot place
points on a log axis or render exact axis labels, and a reader is invited to
cross-check these charts against the CSV. matplotlib reads the same bytes the
README quotes, so the figure and the table are guaranteed consistent.

Dependency: matplotlib (pip install matplotlib). No pandas required.

Usage:
    python3 scripts/plot_alternatives.py                # both langs -> 6 PNGs
    python3 scripts/plot_alternatives.py --lang ru      # Russian only (bare names)
    python3 scripts/plot_alternatives.py --lang en      # English only (_en names)
    python3 scripts/plot_alternatives.py --check        # verify CSVs parse, no write
    DISJOINT_CSV=... OVERLAP_CSV=... python3 scripts/plot_alternatives.py
"""

import csv
import os
import sys

import matplotlib

matplotlib.use("Agg")  # headless: no display needed
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

# --------------------------------------------------------------------------
# Paths. Resolve relative to the repo root (this file lives in scripts/).
# --------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PERF = os.path.join(ROOT, "docs", "perf")
ASSETS = os.path.join(ROOT, "assets")

DISJOINT_CSV = os.environ.get(
    "DISJOINT_CSV", os.path.join(PERF, "bench-alternatives-20260524-disjoint-pg17.csv")
)
OVERLAP_CSV = os.environ.get(
    "OVERLAP_CSV", os.path.join(PERF, "bench-alternatives-20260524-overlap-pg17.csv")
)

# CSV cite strings shown on the figures (basenames only -- the repo-relative
# path is what a reader greps for).
DISJOINT_CITE = "docs/perf/" + os.path.basename(DISJOINT_CSV)
OVERLAP_CITE = "docs/perf/" + os.path.basename(OVERLAP_CSV)

# --------------------------------------------------------------------------
# Implementation identity: stable order, colors, and labels shared by all
# three figures so a reader maps a color to an implementation once.
# --------------------------------------------------------------------------
IMPLS = ["A", "B", "C", "D", "E", "F"]

COLOR = {
    "A": "#159e9c",  # teal     -- pg_xclaim
    "B": "#8c8c84",  # warm gray-- claim-table UNLOGGED
    "C": "#4f6aa8",  # slate blue-- row locks (FOR UPDATE NOWAIT)
    "D": "#e1582f",  # red-orange-- claim-table LOGGED
    "E": "#7b5ea8",  # purple   -- claim-table LOGGED + sorted
    "F": "#9a9a3a",  # olive    -- claim-table UNLOGGED + sorted
}

# Only C carries translatable prose ("row locks"). Every other label is
# SQL/identifier text kept verbatim in both languages, mirroring README.md's
# house style: UNLOGGED / LOGGED / sorted / pg_xclaim stay English.
_LABEL_LONG = {
    "A": "A: pg_xclaim",
    "B": "B: claim-table UNLOGGED",
    "C": "C: row locks (FOR UPDATE NOWAIT)",
    "D": "D: claim-table LOGGED",
    "E": "E: claim-table LOGGED + sorted",
    "F": "F: claim-table UNLOGGED + sorted",
}
LABEL_LONG = {
    "en": _LABEL_LONG,
    "ru": {**_LABEL_LONG, "C": "C: блокировки строк (FOR UPDATE NOWAIT)"},
}

_LABEL_SHORT = {
    "A": "A\n(pg_xclaim)",
    "B": "B\n(UNLOGGED)",
    "C": "C\n(row locks)",
    "D": "D\n(LOGGED)",
    "E": "E\n(LOGGED\n+sorted)",
    "F": "F\n(UNLOGGED\n+sorted)",
}
LABEL_SHORT = {
    "en": _LABEL_SHORT,
    "ru": {**_LABEL_SHORT, "C": "C\n(блокировки\nстрок)"},
}

K_VALUES = [1000, 10000, 100000]
K_LABELS = ["1k", "10k", "100k"]

COMMON_FOOT = "PG 17, ITERS=200, fsync=on, ACCOUNT_POOL=1M"

# Per-language display strings. Technical jargon (tx/sec, p95, WAL, NOWAIT,
# disjoint/overlap, UNLOGGED/LOGGED, deadlock, sort, INSERT) stays English in
# BOTH languages, matching README.md's house style; only the connective prose
# is translated. The deadlock count line is a .format() template.
STRINGS = {
    "en": {
        "xlabel_keys": "Keys per transaction (K)",
        "ylabel_tx": "Transactions / sec (total across 8 backends)",
        "ov_title": "Throughput under concurrency without key conflicts "
                    "(8 backends, disjoint keyspace)",
        "ov_note": "Disjoint mode -- worker-shard keys, no conflicts. "
                   "NOWAIT fail-fast cannot 'cheat' here; raw implementation "
                   "cost is exposed.",
        "full_data": "full data",
        "tr_throughput": "Throughput (tx/sec, log scale)",
        "tr_nowait": "* NOWAIT fail-fast\nartifact, see caveat",
        "tr_p95": "p95 latency (ms, log scale)",
        "tr_ux": "interactive UX boundary",
        "tr_wal": "WAL bytes per scenario (log scale, disjoint only)",
        "tr_nowal": "~0\n(no WAL)",
        "tr_impl": "Implementation",
        "tr_suptitle": "pg_xclaim trade-offs at N=8 K=100k (worst-case workload)",
        "tr_legend_overlap": "overlap mode (~52% key overlap)",
        "tr_legend_disjoint": "disjoint mode (no key overlap)",
        "so_title": "Sorted INSERT under overlap concurrency: "
                    "trading deadlocks for serialization",
        "so_subtitle": "8 backends, ~52% key overlap, ITERS=200",
        "so_crossover": "At high K, sorted (dashed) drops BELOW unsorted (solid):\n"
                        "deterministic acquisition order kills deadlocks but\n"
                        "serializes on overlapping keys.",
        "so_lowk": "At low K: sorted is\nneutral or a small win\n(cache locality).",
        "so_deadlocks": "Deadlocks per scenario:  B={B}  D={D}  E={E}  F={F}\n"
                        "Sorting prevents deadlocks -- but the cure is not free.",
    },
    "ru": {
        "xlabel_keys": "Ключей на транзакцию (K)",
        "ylabel_tx": "Транзакций/сек (суммарно по 8 бэкендам)",
        "ov_title": "Пропускная способность при конкуренции без конфликтов ключей "
                    "(8 бэкендов, disjoint-пространство ключей)",
        "ov_note": "Режим disjoint — ключи шардированы по воркерам, без конфликтов. "
                   "Fail-fast NOWAIT здесь не может «сжульничать»; видна чистая "
                   "стоимость реализации.",
        "full_data": "полные данные",
        "tr_throughput": "Пропускная способность (tx/sec, лог. шкала)",
        "tr_nowait": "* артефакт fail-fast\nNOWAIT, см. оговорку",
        "tr_p95": "p95 (мс, лог. шкала)",
        "tr_ux": "граница интерактивного UX",
        "tr_wal": "Байты WAL на сценарий (лог. шкала, только disjoint)",
        "tr_nowal": "~0\n(нет WAL)",
        "tr_impl": "Реализация",
        "tr_suptitle": "Компромиссы pg_xclaim при N=8 K=100k (худший случай нагрузки)",
        "tr_legend_overlap": "режим overlap (~52% пересечения ключей)",
        "tr_legend_disjoint": "режим disjoint (без пересечения ключей)",
        "so_title": "Sorted INSERT при overlap-конкуренции: "
                    "deadlock'и в обмен на сериализацию",
        "so_subtitle": "8 бэкендов, ~52% пересечения ключей, ITERS=200",
        "so_crossover": "При высоком K sorted (пунктир) опускается НИЖЕ unsorted (сплошная):\n"
                        "детерминированный порядок захвата убивает deadlock'и, но\n"
                        "сериализует на пересекающихся ключах.",
        "so_lowk": "При низком K: sort нейтрален\nили даёт небольшой выигрыш\n(cache locality).",
        "so_deadlocks": "Deadlock'ов на сценарий:  B={B}  D={D}  E={E}  F={F}\n"
                        "Sort устраняет deadlock'и — но лекарство не бесплатно.",
    },
}

# Suppress matplotlib's default "Software: Matplotlib version X.Y" PNG chunk:
# it embeds the local library version, which would churn the committed PNG
# bytes across machines. None tells matplotlib to omit the key entirely.
PNG_META = {"Software": None}


def out_name(base, lang):
    """Bare filename is the Russian (primary) asset; English gets an _en
    suffix -- the same convention docs/ uses (runbook.md / runbook_en.md)."""
    return f"{base}.png" if lang == "ru" else f"{base}_en.png"


def parse_langs(argv):
    """--lang en|ru|both (default both -> regenerate every asset in one run,
    so a language can never be silently left stale)."""
    val = "both"
    for i, a in enumerate(argv):
        if a == "--lang" and i + 1 < len(argv):
            val = argv[i + 1]
        elif a.startswith("--lang="):
            val = a.split("=", 1)[1]
    if val == "both":
        return ["ru", "en"]
    if val in ("en", "ru"):
        return [val]
    raise SystemExit(f"--lang must be en|ru|both, got {val!r}")


# --------------------------------------------------------------------------
# CSV loading. Returns data[mode][impl][K] = {tx, p95, wal, deadlocks}.
# --------------------------------------------------------------------------
def load(path):
    rows = {}
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            if int(r["backends"]) != 8:
                continue
            impl = r["impl"]
            K = int(r["K"])
            rows.setdefault(impl, {})[K] = {
                "tx": float(r["throughput_tx_per_sec"]),
                "p95": float(r["p95_ms"]),
                "wal": int(r["wal_bytes"]),
                "deadlocks": int(r["deadlocks"]),
            }
    missing = [(i, k) for i in IMPLS for k in K_VALUES if k not in rows.get(i, {})]
    if missing:
        raise SystemExit(f"{path}: missing backends=8 rows for {missing}")
    return rows


def human_bytes(n):
    """Decimal (SI) bytes, matching the README's GB convention (/1000)."""
    if n < 1000:
        return f"{n} B"
    if n < 1_000_000:
        return f"{n / 1e3:.0f} KB"
    if n < 1_000_000_000:
        return f"{n / 1e6:.0f} MB"
    return f"{n / 1e9:.1f} GB"


# --------------------------------------------------------------------------
# Figure 1: overview.png -- disjoint throughput, six lines, log-log.
# --------------------------------------------------------------------------
def plot_overview(disjoint, out, lang):
    S = STRINGS[lang]
    fig, ax = plt.subplots(figsize=(12.8, 7.2))  # 16:9

    for impl in IMPLS:
        ys = [disjoint[impl][k]["tx"] for k in K_VALUES]
        ax.plot(
            K_VALUES, ys, marker="o", markersize=5, linewidth=2,
            color=COLOR[impl], label=LABEL_LONG[lang][impl],
        )

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xticks(K_VALUES)
    ax.set_xticklabels(K_LABELS)
    ax.set_ylim(1, 20000)  # A peaks at 13505; 10000 would clip it
    ax.set_yticks([1, 10, 100, 1000, 10000])
    ax.set_yticklabels(["1", "10", "100", "1000", "10000"])
    ax.set_xlabel(S["xlabel_keys"])
    ax.set_ylabel(S["ylabel_tx"])
    ax.set_title(S["ov_title"], fontsize=13, fontweight="bold")
    ax.grid(True, which="both", linewidth=0.4, alpha=0.4)
    ax.legend(loc="upper right", ncol=2, fontsize=8.5, framealpha=0.9)

    # Bottom band (below the lowest line) is the only fully clear zone.
    ax.text(
        0.30, 0.05, S["ov_note"],
        transform=ax.transAxes, ha="left", va="bottom", fontsize=8,
        color="#555", style="italic",
        bbox=dict(boxstyle="round", fc="white", ec="#ddd", lw=0.6, alpha=0.85),
    )

    fig.text(
        0.5, 0.012,
        f"{COMMON_FOOT}; {S['full_data']}: {DISJOINT_CITE}",
        ha="center", fontsize=7.5, color="#555",
    )
    fig.subplots_adjust(bottom=0.11, top=0.93, left=0.07, right=0.985)
    fig.savefig(out, dpi=150, metadata=PNG_META)
    plt.close(fig)


# --------------------------------------------------------------------------
# Figure 2: perf-tradeoffs.png -- 3 panels at N=8 K=100k.
# --------------------------------------------------------------------------
def plot_tradeoffs(disjoint, overlap, out, lang):
    S = STRINGS[lang]
    K = 100000
    x = range(len(IMPLS))
    w = 0.38
    colors = [COLOR[i] for i in IMPLS]

    fig, (axT, axP, axW) = plt.subplots(1, 3, figsize=(16.8, 7.0))

    # ---- LEFT: throughput, overlap (dark) vs disjoint (light) ----
    ov = [overlap[i][K]["tx"] for i in IMPLS]
    dj = [disjoint[i][K]["tx"] for i in IMPLS]
    axT.bar([xi - w / 2 for xi in x], ov, w, color=colors)
    axT.bar([xi + w / 2 for xi in x], dj, w, color=colors, alpha=0.45)
    axT.set_yscale("log")
    axT.set_ylim(1, 10000)
    axT.set_title(S["tr_throughput"], fontsize=11)
    # NOWAIT artifact callout on the overlap C bar.
    c_idx = IMPLS.index("C")
    axT.annotate(
        S["tr_nowait"],
        xy=(c_idx - w / 2, overlap["C"][K]["tx"]), xytext=(c_idx - 0.4, 1300),
        fontsize=7.5, color="#444",
        arrowprops=dict(arrowstyle="->", color="#888", lw=0.8),
    )

    # ---- MIDDLE: p95 latency ----
    ovp = [overlap[i][K]["p95"] for i in IMPLS]
    djp = [disjoint[i][K]["p95"] for i in IMPLS]
    axP.bar([xi - w / 2 for xi in x], ovp, w, color=colors)
    axP.bar([xi + w / 2 for xi in x], djp, w, color=colors, alpha=0.45)
    axP.set_yscale("log")
    axP.set_ylim(10, 10000)
    axP.set_title(S["tr_p95"], fontsize=11)
    axP.axhline(100, ls="--", lw=1, color="#999")
    # Place the label at the far left, above A/C bars (both < 100 ms there).
    axP.text(-0.35, 112, S["tr_ux"],
             ha="left", va="bottom", fontsize=7.5, color="#777")

    # ---- RIGHT: WAL bytes, disjoint only ----
    djw = [disjoint[i][K]["wal"] for i in IMPLS]
    # Log axis cannot show A's ~0; floor it and annotate honestly.
    floor = 100
    heights = [max(v, floor) for v in djw]
    axW.bar(list(x), heights, w * 1.6, color=colors, alpha=0.7)
    axW.set_yscale("log")
    axW.set_ylim(floor, 1e11)  # 100 B .. 100 GB
    axW.set_title(S["tr_wal"], fontsize=11)
    for xi, v in zip(x, djw):
        if v < floor:
            axW.text(xi, floor * 1.15, S["tr_nowal"], ha="center", va="bottom",
                     fontsize=7.5, color="#444")
        else:
            axW.text(xi, v * 1.25, human_bytes(v), ha="center", va="bottom",
                     fontsize=7.5, color="#333")

    for ax in (axT, axP, axW):
        ax.set_xticks(list(x))
        ax.set_xticklabels([LABEL_SHORT[lang][i] for i in IMPLS], fontsize=7)
        ax.set_xlabel(S["tr_impl"], fontsize=9)
        ax.grid(True, axis="y", which="both", linewidth=0.4, alpha=0.35)

    fig.suptitle(S["tr_suptitle"], fontsize=13, fontweight="bold")
    # Shared legend: shade = mode.
    legend_handles = [
        Patch(facecolor="#555", label=S["tr_legend_overlap"]),
        Patch(facecolor="#555", alpha=0.45, label=S["tr_legend_disjoint"]),
    ]
    fig.legend(handles=legend_handles, loc="upper center", ncol=2,
               bbox_to_anchor=(0.5, 0.945), fontsize=9, frameon=False)
    fig.text(
        0.5, 0.012,
        f"{COMMON_FOOT}; {S['full_data']}: docs/perf/bench-alternatives-20260524-*.csv",
        ha="center", fontsize=7.5, color="#555",
    )
    fig.subplots_adjust(bottom=0.13, top=0.86, left=0.06, right=0.985, wspace=0.26)
    fig.savefig(out, dpi=150, metadata=PNG_META)
    plt.close(fig)


# --------------------------------------------------------------------------
# Figure 3: sorted-insert-finding.png -- overlap, B/F + D/E, solid/dashed.
# --------------------------------------------------------------------------
def plot_sorted(overlap, out, lang):
    S = STRINGS[lang]
    fig, ax = plt.subplots(figsize=(12.8, 7.2))

    # Color by STORAGE FAMILY (not the global per-impl palette): the whole
    # point of this figure is the unsorted-vs-sorted contrast WITHIN each
    # storage type, so UNLOGGED (B,F) share one hue and LOGGED (D,E) another,
    # with solid = unsorted and dashed = sorted. The series labels are
    # SQL/identifier text (sorted/unsorted INSERT) -- kept English in both
    # languages, exactly as README.md's 2x2 table writes them.
    GRAY = "#7a7a72"   # UNLOGGED family
    RED = "#d9542b"    # LOGGED family
    series = [
        ("B", "B: UNLOGGED + unsorted INSERT", "-", GRAY),
        ("F", "F: UNLOGGED + sorted INSERT", "--", GRAY),
        ("D", "D: LOGGED + unsorted INSERT", "-", RED),
        ("E", "E: LOGGED + sorted INSERT", "--", RED),
    ]
    for impl, label, style, color in series:
        ys = [overlap[impl][k]["tx"] for k in K_VALUES]
        ax.plot(K_VALUES, ys, style, marker="o", markersize=6, linewidth=2.2,
                color=color, label=label)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xticks(K_VALUES)
    ax.set_xticklabels(K_LABELS)
    ax.set_xlim(700, 145000)
    ax.set_ylim(1, 10000)
    ax.set_yticks([1, 10, 100, 1000, 10000])
    ax.set_yticklabels(["1", "10", "100", "1000", "10000"])
    ax.set_xlabel(S["xlabel_keys"])
    ax.set_ylabel(S["ylabel_tx"])
    ax.set_title(S["so_title"], fontsize=13, fontweight="bold", pad=24)
    ax.text(0.5, 1.012, S["so_subtitle"],
            transform=ax.transAxes, ha="center", va="bottom",
            fontsize=10, color="#555")
    ax.grid(True, which="both", linewidth=0.4, alpha=0.4)
    ax.legend(loc="lower left", fontsize=8.5, framealpha=0.92)

    # Crossover message: arrow into the sorted E point at K=100k (the lowest),
    # text parked in the empty upper-right band (all lines have descended).
    ax.annotate(
        S["so_crossover"],
        xy=(100000, overlap["E"][100000]["tx"]),
        xytext=(8500, 1300), fontsize=8.5, color="#333", ha="left",
        arrowprops=dict(arrowstyle="->", color="#888", lw=0.9),
    )
    # Low-K aside (clear band just under the K=1k cluster).
    ax.text(770, 25, S["so_lowk"],
            fontsize=8, color="#555", style="italic", ha="left", va="top")
    # Deadlock-count box, bottom-center clear zone.
    dl = overlap
    ax.text(
        0.52, 0.045,
        S["so_deadlocks"].format(
            B=dl["B"][100000]["deadlocks"], D=dl["D"][100000]["deadlocks"],
            E=dl["E"][100000]["deadlocks"], F=dl["F"][100000]["deadlocks"],
        ),
        transform=ax.transAxes, fontsize=8.5, color="#333", ha="center", va="bottom",
        bbox=dict(boxstyle="round", fc="#f4f4f4", ec="#ccc", lw=0.8),
    )

    fig.text(
        0.5, 0.012,
        f"{COMMON_FOOT}, log_lock_waits=on; {S['full_data']}: {OVERLAP_CITE}",
        ha="center", fontsize=7.5, color="#555",
    )
    fig.subplots_adjust(bottom=0.11, top=0.90, left=0.07, right=0.985)
    fig.savefig(out, dpi=150, metadata=PNG_META)
    plt.close(fig)


def main():
    disjoint = load(DISJOINT_CSV)
    overlap = load(OVERLAP_CSV)

    if "--check" in sys.argv:
        print("CSV parse OK (backends=8 rows present for A-F at 1k/10k/100k)")
        print(f"  disjoint: {DISJOINT_CITE}")
        print(f"  overlap:  {OVERLAP_CITE}")
        return

    os.makedirs(ASSETS, exist_ok=True)
    for lang in parse_langs(sys.argv):
        plot_overview(disjoint, os.path.join(ASSETS, out_name("overview", lang)), lang)
        plot_tradeoffs(disjoint, overlap,
                       os.path.join(ASSETS, out_name("perf-tradeoffs", lang)), lang)
        plot_sorted(overlap,
                    os.path.join(ASSETS, out_name("sorted-insert-finding", lang)), lang)
        print(f"wrote [{lang}]: " + ", ".join(
            "assets/" + out_name(b, lang)
            for b in ("overview", "perf-tradeoffs", "sorted-insert-finding")))


if __name__ == "__main__":
    main()
