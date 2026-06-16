# Contributing to pg_xclaim

`pg_xclaim` is a focused PostgreSQL extension with strict correctness
invariants. Small, well-scoped patches with tests are easiest to review
and merge.

---

## Before opening a PR

For **non-trivial changes** (new features, public API additions,
behavioural shifts in `xclaim.try` / `try_many` / cleanup, GUC
additions, on-disk format / shmem layout changes), please **open an
issue first** to discuss the design.

For **bug fixes**, **doc improvements**, **test additions**,
**measured performance optimisations**, just open the PR directly.

For **suspected security issues** (memory corruption, privilege
escalation, DoS via SQL surface), do **not** open a public issue —
contact the maintainer via a private GitHub channel.

---

## Build & test

**Environment prerequisite:** the test scripts run `initdb --locale=ru_RU.UTF-8`,
so that locale must exist on the host. On Debian/Ubuntu:
`sudo locale-gen ru_RU.UTF-8`.

The `installcheck*` targets do **not** depend on `install` — they run against
the already-installed `pg_xclaim.so`. Run `sudo make install` first (or have
write access to `pg_config --pkglibdir` / `--sharedir`).

```bash
PG_CONFIG=/path/to/bin/pg_config        # adjust per major (16 / 17 / 18)
make PG_CONFIG="$PG_CONFIG" -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
sudo make PG_CONFIG="$PG_CONFIG" install                # REQUIRED before installcheck

# Test suites — run all three before opening a PR
make PG_CONFIG="$PG_CONFIG" installcheck                # main
make PG_CONFIG="$PG_CONFIG" installcheck-capacity       # capacity
make PG_CONFIG="$PG_CONFIG" installcheck-nonpreload     # no-preload
bash test/concurrency/run_concurrency_suite.sh          # cross-session
bash scripts/smoke_gate.sh "$PG_CONFIG"                 # preload smoke
bash scripts/smoke_gate_no_preload.sh "$PG_CONFIG"      # no-preload smoke

# Optional
bash scripts/bench_try_many.sh "$PG_CONFIG"             # perf-budget gate
bash scripts/run_regress_matrix.sh                      # full PG 16/17/18 matrix
```

Build must complete cleanly under `-Wall -Wextra -Werror`; CI rejects
warnings on PG 16/17/18.

All temp clusters live under `/tmp/pg_xclaim_$USER_*` with `trap`
cleanup. Test scripts **never touch user-owned PostgreSQL clusters** —
this is a hard invariant, please preserve it in any new test you add.

If your change deliberately alters `pg_regress` output (e.g. a new
column in `xclaim.stats()`), inspect the diff in
`test/results/<name>.out` vs `test/expected/<name>.out`, then accept
the new baseline by copying `results` over `expected`.

---

## HARD invariants (correctness-load-bearing)

Non-negotiable. CI checks them and reviewers reject PRs that break
them. Key items:

- **Memory:** every per-backend allocation lives in `TopMemoryContext`
  (or a child of it) — never `CurTransactionContext`.
- **Function attributes:** SQL declarations of `xclaim.try` /
  `xclaim.try_many` MUST be exactly
  `LANGUAGE c VOLATILE PARALLEL RESTRICTED CALLED ON NULL INPUT`
  (mirror of `pg_try_advisory_xact_lock`; strictness is the one
  deliberate divergence).
- **Cleanup callback events:** handle ONLY `XACT_EVENT_COMMIT`,
  `XACT_EVENT_PARALLEL_COMMIT`, `XACT_EVENT_ABORT`,
  `XACT_EVENT_PARALLEL_ABORT`. `XACT_EVENT_PRE_PREPARE` is rejected
  with `ERRCODE_FEATURE_NOT_SUPPORTED`.
- **Backend exit:** use `before_shmem_exit`, never `on_shmem_exit` /
  `on_proc_exit`.
- **Owner identity:** never store raw `PGPROC *`. The saved triple
  (`procno`, `lxid`, `token`) is captured at acquisition time; cleanup
  reads only the saved triple — never current `MyProc->lxid` (cleared
  by `ProcArrayEndTransaction()` before the xact callback fires).
- **`HASH_BLOBS` keys:** `memset` the `XClaimKey` to zero before
  populating fields. `dynahash` hashes raw byte layout.
- **`StaticAssertDecl`** at module scope (not `StaticAssertStmt`) for
  layout invariants on `XClaimKey`.
- **Group-by-partition cleanup:** total LWLock acquire/release pairs
  per cleanup ≤ `num_partitions`. No per-key lock cycles.
- **No `simplehash.h` in shared memory** (local-only; shmem uses
  `dynahash` via `ShmemInitHash`).
- **No `MyProc->vxid.procNumber`** — use `xclaim_get_current_procno()`
  from `pg_xclaim_compat.h`.
- **`CHECK_FOR_INTERRUPTS()`** only at the documented step in the
  acquisition algorithm and never under an LWLock.

If you need to bend one of these for a good reason, raise it in the
PR — we'll discuss.

---

## Coding standards

- Match the style of surrounding code. The project broadly follows the
  [PostgreSQL C coding conventions](https://www.postgresql.org/docs/current/source-format.html)
  — BSD-style braces, `CamelCase` for types, `lowercase_with_underscores`
  for functions, `ereport(ERROR, ...)` for user-facing errors,
  `palloc`/`pfree`, disciplined memory contexts.
- **Indentation diverges from upstream:** the project uses **4 spaces**,
  not tabs. No trailing whitespace.
- Comments explain the **why**, not the **what**.
- Shell scripts: `set -euo pipefail`, `trap 'cleanup' EXIT INT TERM`
  for any state-creating script, locale `--locale=ru_RU.UTF-8` in
  `initdb`.

---

## Submitting a PR

1. Branch from `main` with a descriptive name
   (`fix/cleanup-leak-on-2pc-abort`, `feat/xclaim-debug-hist`).
2. Add tests covering the behavioural change.
3. Commit message: short subject (≤72 chars, imperative, no trailing
   period), blank line, body explaining **why** and any non-obvious
   tradeoffs.
4. Open the PR against `main` covering: what + why, test plan (which
   suites + PG majors), HARD-invariant impact (usually none), perf
   impact (if applicable; reference `bench_try_many.sh` numbers).
5. Link the issue with `Fixes #N` if applicable.

---

## Documentation sync

- READMEs are bilingual: `README.md` (RU) + `README_EN.md` (EN).
  If you change one, update the other.
- Operational docs are bilingual: `docs/runbook{,_en}.md`,
  `docs/incident-decision-tree{,_en}.md`,
  `docs/perf/hot-path-analysis{,_en}.md`. Keep RU and EN in sync.
- `docs/perf/hot-path-analysis*.md` documents the current profile.
  Don't update its numbers casually — re-run perf and update both
  language versions with reproduced measurements.
- Every README figure is generated from code, not drawn by hand, so they
  stay exact and reproducible. The charts are bilingual, following the same
  convention as the docs: the bare filename is Russian (primary), the
  English one carries an `_en` suffix (`overview.png` / `overview_en.png`).
  The banner is language-neutral and shared by both READMEs. By default each
  chart generator emits both languages in one run, so a language can never be
  left stale. The generators need only matplotlib (`pip install matplotlib`,
  the sole extra dependency):

  ```bash
  # the three benchmark charts, straight from docs/perf/bench-alternatives-*.csv
  # (regenerate these whenever you regenerate a CSV, so the figures match
  #  the README tables). Default writes RU (bare) + EN (_en) in one run:
  python3 scripts/plot_alternatives.py            # *.png + *_en.png (both langs)
  python3 scripts/plot_alternatives.py --lang en  # English only, if needed

  # the architecture diagram (fixed geometry, no data input):
  python3 scripts/draw_concept.py        # concept.png + concept_en.png

  # the hero banner (wordmark + padlock; language-neutral, single file):
  python3 scripts/draw_banner.py         # banner.png
  ```

---

## License

By submitting a contribution, you agree that your contribution is
licensed under the [PostgreSQL License](LICENSE) (same as the rest of
the project).
