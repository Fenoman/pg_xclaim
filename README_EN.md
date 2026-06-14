# pg_xclaim

[![CI Matrix](https://github.com/Fenoman/pg_xclaim/actions/workflows/ci-pg-matrix.yml/badge.svg)](https://github.com/Fenoman/pg_xclaim/actions/workflows/ci-pg-matrix.yml)
[![License: PostgreSQL](https://img.shields.io/badge/License-PostgreSQL-336791.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Fenoman/pg_xclaim?include_prereleases&color=blue)](https://github.com/Fenoman/pg_xclaim/releases)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16%20%7C%2017%20%7C%2018-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Language: C](https://img.shields.io/badge/Language-C-A8B9CC.svg?logo=c&logoColor=white)](https://en.wikipedia.org/wiki/C_(programming_language))
[![GitHub stars](https://img.shields.io/github/stars/Fenoman/pg_xclaim?style=social)](https://github.com/Fenoman/pg_xclaim/stargazers)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

![pg_xclaim — experimental high-cardinality claim primitive for PostgreSQL](assets/banner.png)

> ### Before considering pg_xclaim — 3 rules
>
> 1. This is not a general-purpose advisory-lock replacement. First,
>    raise `max_locks_per_transaction` (4096..16384); for most
>    workloads that is enough.
> 2. Do not use unless `LWLock:LockManager` is in the top-3 wait
>    events under realistic load. That is the narrow bottleneck
>    pg_xclaim is built for; without it the extension is just an
>    operational tax.
> 3. Run the [alternatives benchmark](#comparison-with-alternatives)
>    on a mirror of your own system. If any of alternatives 1–6 is
>    faster or comparable in stability on your workload, take it.

**Experimental** PostgreSQL extension: an alternative storage
mechanism for transaction-level claims in its own partitioned shared-
memory hashtable. Built as a proof-of-concept for one specific
workload: a legacy codebase with hundreds of `pg_try_advisory_xact_lock`
call sites, operations holding 100k+ claims per transaction, and the
standard alternatives did not fit (see [Alternatives](#alternatives)).

This is **not** a replacement for `pg_try_advisory_xact_lock` and is
not positioned as one. The API matches its signature deliberately so
that legacy call sites can be migrated by textual replacement — not
as a general recipe. Read [Alternatives](#alternatives) and
[FAQ](#faq) before installing.

> ### Before you install
>
> **Operational complexity.** pg_xclaim's claims are not visible
> in `pg_locks`, `pg_stat_activity`, or EXPLAIN. During an incident
> a DBA looks in two places — PostgreSQL's standard tooling plus
> `xclaim.stats()`. A separate incident playbook covers this
> ([`docs/incident-decision-tree_en.md`](docs/incident-decision-tree_en.md));
> the detailed `xclaim.debug_snapshot()` has a partition-count caveat
> (see [FAQ Q4](#q4-this-adds-operational-complexity--dbas-now-look-in-two-places-during-an-incident)).

---

## Why this exists

Context. In one specific system, long-running transactions hold
`pg_try_advisory_xact_lock` on 100k+ keys at the same time. On that
load `LWLock:LockManager` becomes the dominant wait event. Not because
of `max_locks_per_transaction` (that's a GUC tuning fix), but because
of contention on the LockManager's own partition LWLocks.

Standard alternatives (see [Alternatives](#alternatives)) did not fit
this codebase. Too many advisory call sites, no freedom to decompose
transactions, no schema changes allowed.

`pg_xclaim` is an experiment: what if we put these claims into a
separate partitioned shmem structure with the same transactional
semantics, but bypassing the LockManager? The result is a working
prototype with tests, runbooks, and perf budgets.

On cost: one key acquire is one partition LWLock cycle. Cleanup is
amortized to ≤ `num_partitions` cycles per transaction (group by
partition, not per-key). The per-key C work is `memset` + `memcmp`
on a 16-byte key.

The `xclaim.try(int4, int4)` and `xclaim.try(int8)` overloads have
**identical function attributes** to `pg_try_advisory_xact_lock`
(volatility, parallel mode; strictness differs deliberately — see
below). This is so that legacy call sites can be migrated by textual
replacement.

![Architecture: partitioned shared-memory claim storage](assets/concept.png)

---

## Alternatives

Before considering pg_xclaim, evaluate the standard approaches.
For ~95% of workloads one of rows 1–6 covers the case.

| # | Solution | When to choose | Trade-offs |
|---|----------|----------------|------------|
| 1 | Raise `max_locks_per_transaction` (4096..16384) | Default 64 too small; `LWLock:LockManager` is NOT a top wait event | Shared-memory footprint is small (PG 16: ~100 KB at 4096×200, PG 18: ~5 MB due to Fast-Path Array). **The real cost is per-backend LOCALLOCK hash under high cardinality:** ~17 MB per backend when 100k locks are held in one tx. Usually cheaper than any extension if per-tx cardinality stays modest. |
| 2 | Batching + idempotency via `document_id UNIQUE` | The operation can be decomposed into 100–500 accounts; outbox/saga is acceptable for atomicity | All-in-one-tx atomicity is lost; idempotency design required |
| 3 | `SELECT ... FOR UPDATE NOWAIT / SKIP LOCKED` on real account rows | Accounts are first-class rows available for row-locking; concurrency is moderate | WAL and dead tuples per locked tuple; vacuum interaction; partitioning by another key = unpredictable cost |
| 4 | Claim-table `INSERT ... ON CONFLICT DO NOTHING RETURNING` (non-blocking) | Simple, portable, inspectable with standard PG tooling; moderate cardinality, low concurrency | **Hits deadlocks under high concurrency** on the UNIQUE index (see [benchmark](#comparison-with-alternatives): ~2.5–18 tx/sec and p95 from ~0.5s (unsorted) to 3.5–8s (sorted) at 8 backends depending on K and variant); requires DDL and schema migration; on LOGGED tables also heap+index WAL and autovacuum pressure |
| 5 | App-level sharding via `hash(account_id) % N` | The app can be reworked; N PG connections are available | No conflicts by construction, but requires an app rewrite — not applicable to legacy |
| 6 | Optimistic concurrency (`version` column + CAS) | Conflicts are rare (<5%) | Retry storm if conflicts are frequent |
| 7 | **pg_xclaim** | Alternatives 3-4 (B/C/D) measurably lose on our workload (see benchmark); 1, 2 ruled out by architectural reasons specific to our system (see FAQ Q1, Q3); self-hosted PG; legacy advisory call sites; team capacity for extension maintenance | Operational opacity, managed cloud cut off, ABI lock-in |

If you are building a new system you almost certainly want one of
1–6, not this extension. See also the [FAQ](#faq); it covers the
common objections in detail.

---

## Build matrix

| Target | Version | CI status |
|--------|---------|-----------|
| PostgreSQL | 16.x latest minor | GitHub Actions |
| PostgreSQL | 17.x latest minor | GitHub Actions (primary) |
| PostgreSQL | 18.x latest minor | GitHub Actions |
| ABI-compatible PG fork | 16/17/18 | manual local |

Compile flags: `-Wall -Wextra -Werror` (HARD invariant).

---

## Install

### Prerequisites

- A PG 16 / 17 / 18 cluster (tested against upstream PG; ABI-compatible forks may require local build verification).
- `pg_config` on the build machine.
- macOS dev: `brew install postgresql@17` (or 16 / 18).

### Build + install

```bash
set -euo pipefail
make PG_CONFIG=/opt/homebrew/Cellar/postgresql@17/17.9/bin/pg_config
sudo make PG_CONFIG=/opt/homebrew/Cellar/postgresql@17/17.9/bin/pg_config install
```


### Configure

Edit `postgresql.conf`:

```conf
# Put pg_xclaim LAST in the list — its cleanup callback then runs first
# at commit (PostgreSQL invokes xact callbacks in LIFO order).
shared_preload_libraries = 'citus,timescaledb,pg_xclaim'

pg_xclaim.max_claims                  = 4194304    # 4M (default; ~360 MB shmem)
pg_xclaim.num_partitions              = 128
pg_xclaim.expected_claims_per_backend = 16384
pg_xclaim.enabled                     = true
pg_xclaim.capacity_warn_pct           = 80
pg_xclaim.on_capacity_exhaustion      = error
```

> **Sizing note.** `expected_claims_per_backend = 16384` is the size
> the extension pre-grows the backend-local `simplehash` to. If a
> single backend holds more than 16k concurrent claims (e.g. the goal
> is the 750k single-backend hot path), raise this GUC to your
> expected peak (~750000). Otherwise everything still works, but the
> backend will spend time rehashing in the middle of a burst.
>
> You don't need to watch this by hand. The extension writes a server
> log line `crossed 75% of pg_xclaim.expected_claims_per_backend` the
> first time a backend approaches the limit. That's the ready-made
> "time to raise the GUC" signal. See `docs/runbook_en.md` §3.
>
> Total memory budget formula. Each held claim occupies a 48-byte
> `XClaimLocalEntry`; with simplehash rounding to a power of two and a
> ~75% load factor the effective cost is ~63 bytes per claim at 100k,
> which empirically gives **~50.3 MB per backend at 750k** (see
> [`docs/runbook_en.md` §9](docs/runbook_en.md#9-capacity-planning)).
>
> ```
> Per-backend local memory (at 750k claims) ≈ 50.3 MB
>
> Cluster-wide local memory (total) ≈
>     ~50.3 MB × max_connections
> ```
>
> Example. With `max_connections=200` and
> `expected_claims_per_backend=750000`, that's ~10 GB cumulative
> across backend TopMemoryContexts (~50.3 MB × 200), plus
> ~360 MB shmem dynahash from `max_claims=4194304`. Account for this
> in your cluster RAM sizing: per-backend pre-grow is the largest
> line item in the cluster-wide budget.

Restart the cluster, then:

```sql
CREATE EXTENSION pg_xclaim;
```

### Hot-standby caveat

The extension is **not supported on hot-standby replicas**. The first SQL
call raises `ERRCODE_FEATURE_NOT_SUPPORTED` when `RecoveryInProgress()`
is true and `pg_xclaim` is in `shared_preload_libraries`. Remove from
preload before promoting a standby. See [`docs/runbook_en.md`](docs/runbook_en.md).

---

## SQL surface

All functions live in the dedicated `xclaim` schema (never `pg_catalog`,
never `public`).

| Function | Purpose |
|----------|---------|
| `xclaim.try(int4, int4) RETURNS boolean` | Two-arg API; signature matches `pg_try_advisory_xact_lock(int4, int4)` for ergonomic legacy migration. |
| `xclaim.try(int8) RETURNS boolean` | Single-arg API; signature matches `pg_try_advisory_xact_lock(bigint)`. Distinct keyspace. |
| `xclaim.try_many(int4, int4[]) RETURNS boolean[]` | Bulk variant; pre-sorts by partition (≤ `num_partitions` LWLock cycles for the whole batch). |
| `xclaim.try_many(int8[]) RETURNS boolean[]` | Bulk single-arg form. |
| `xclaim.count() RETURNS int8` | Number of claims held by current top-level transaction. |
| `xclaim.stats() RETURNS TABLE(...)` | Atomic counter snapshot + capacity gauges. `pg_monitor`. |
| `xclaim.debug_snapshot() RETURNS TABLE(...)` | Detailed shared-state snapshot under shared locks on all partitions. `pg_monitor`; requires `pg_xclaim.num_partitions <= 192`. |
| `xclaim.debug() RETURNS TABLE(...)` | All-partition consistent snapshot. **Superuser only.** |
| `xclaim.debug_inject_stale(int4, int4) RETURNS void` | **Test-only.** Stale-entry injector (simulates an owner that did not survive a crash). **Superuser only**, `REVOKE`d from `PUBLIC`. Never called in production. |
| `xclaim.session_reset() RETURNS void` | Optional triage hook. Force-clears local state and rotates owner_token. **Not required for routine operation:** claims are released automatically by the xact callback on every COMMIT/ABORT. Use reactively only if `xclaim.stats().cleanup_misses > 0` in production. Do not wire into the pooler `server_reset_query` — it adds an RTT per handoff with no functional benefit. |

### Function-attribute parity with `pg_try_advisory_xact_lock`

`xclaim.try` matches `pg_try_advisory_xact_lock` on volatility and
parallel mode; strictness differs by design. The table below is a
precise description of the API invariant, not marketing:

| Attribute | `pg_try_advisory_xact_lock` | `xclaim.try` | Match |
|-----------|------------------------------|--------------|-------|
| `provolatile`  | `v` (VOLATILE)              | `v` (VOLATILE)              | yes |
| `proparallel`  | `r` (PARALLEL RESTRICTED)   | `r` (PARALLEL RESTRICTED)   | yes |
| `proisstrict`  | `t` (STRICT)                | `f` (CALLED ON NULL INPUT)  | **deliberate delta** |

> Note. `pg_try_advisory_xact_lock` is declared STRICT
> (`pg_proc.proisstrict = t`), so PostgreSQL silently returns NULL
> for any NULL argument and never invokes the C body. `xclaim.try`
> behaves differently: it catches NULL and raises
> `ERRCODE_NULL_VALUE_NOT_ALLOWED` explicitly. Programming bugs
> surface immediately instead of hiding behind a silent NULL.
>
> What this means for migration. Callers must not pass NULL as a
> key. Most production call sites already do this. If a specific
> call site relied on the silent-NULL path, add
> `WHERE key IS NOT NULL` before calling `xclaim.try(key)`.

### NULL handling

```sql
SELECT xclaim.try(NULL, 1);                  -- raises ERRCODE_NULL_VALUE_NOT_ALLOWED
SELECT xclaim.try(NULL);                     -- raises ERRCODE_NULL_VALUE_NOT_ALLOWED
SELECT xclaim.try_many(NULL::int8[]);        -- raises ERRCODE_NULL_VALUE_NOT_ALLOWED
SELECT xclaim.try_many(NULL, ARRAY[1]);      -- raises ERRCODE_NULL_VALUE_NOT_ALLOWED
SELECT xclaim.try_many(ARRAY[1, NULL, 3]);   -- raises ERRCODE_NULL_VALUE_NOT_ALLOWED
```

> **NULL handling is symmetric across scalar and bulk:** `xclaim.try_many`
> raises ERROR on any NULL argument AND on any NULL element inside an
> otherwise-valid array, just like the scalar `xclaim.try`. Silent NULL
> pass-through would hide programming bugs (e.g. an array built from a
> subquery that produced NULL): the recommended `bool_and(unnest)`
> idiom would then silently treat the partial result as successful
> because `bool_and` ignores NULL by SQL semantics. Filter out NULL
> elements with `array_remove(arr, NULL)` (or `WHERE x IS NOT NULL` in
> the subquery) before calling `xclaim.try_many`.

### Quick example

```sql
BEGIN;
SELECT xclaim.try(1, 100);   -- true (claim acquired)
SELECT xclaim.try(1, 100);   -- true (reentrancy fast path; no LWLock)
SELECT xclaim.try(1, 100), xclaim.count();  -- (true, 1)
COMMIT;                      -- claim released by xact callback
```

```sql
-- Bulk acquisition:
SELECT bool_and(ok)
FROM unnest(xclaim.try_many(1, ARRAY[100, 200, 300, 400])) AS ok;
```

> **`try_many` result semantics.** Result element `i` maps to input
> element `i` (order is preserved despite the internal re-sort by
> partition). This is **best-effort**, not all-or-nothing: on partial
> failure the acquired subset stays held until the end of the
> transaction. If you need all-or-nothing atomicity, check
> `bool_and(...)` and `ROLLBACK` when any element returned `false`.

### Subtransaction lifetime

Claims taken inside a `SAVEPOINT` (or a PL/pgSQL `BEGIN ... EXCEPTION`
block, which PostgreSQL implements as an implicit savepoint) survive
`ROLLBACK TO SAVEPOINT` and are released only by the top-level
COMMIT or ABORT. This is a **deliberate divergence from
`pg_try_advisory_xact_lock`**, whose locks ARE released by subxact
rollback. The simpler "top-level lifetime" contract lets pg_xclaim use
only a single xact callback (no per-subxact bookkeeping in shared or
local memory). If your workload depends on per-savepoint release,
either restructure to keep the claim inside the outermost xact you
want it released by, or stay on `pg_try_advisory_xact_lock` for that
specific call site.

---

## GUCs

| GUC | Type | Default | Description |
|-----|------|---------|-------------|
| `pg_xclaim.max_claims` | int4 | 4194304 | Shared dynahash capacity. Restart required. Footprint scales linearly with `max_claims`; default sizing is ~360 MB, doubling `max_claims` -> doubling footprint. |
| `pg_xclaim.num_partitions` | int4 | 128 | Number of LWLock-protected partitions. Restart required. |
| `pg_xclaim.expected_claims_per_backend` | int4 | 16384 | Pre-grow `simplehash` to avoid rehashes. Restart required. |
| `pg_xclaim.enabled` | bool | true | Live kill-switch. Off = `xclaim.try` returns `true` unconditionally. `PGC_SUSET`. |
| `pg_xclaim.capacity_warn_pct` | int4 | 80 | Watermark log threshold (LOG line at 80/90/95%). |
| `pg_xclaim.on_capacity_exhaustion` | enum | error | `error` (default; ERRCODE 53400) / `warn` (log + return false). |

See [`docs/runbook_en.md`](docs/runbook_en.md) for tuning guidance.

---

## Use in legacy codebases

> If you are starting a new project, do not use pg_xclaim. Take one
> of alternatives 1–6 from the table above. The section below is for
> the case where you already have hundreds of
> `pg_try_advisory_xact_lock` call sites in a legacy codebase, and
> you have walked through every alternative.

> ### ⚠️ Disjoint namespace — migrate all call sites atomically
>
> `xclaim.try(k)` and `pg_try_advisory_xact_lock(k)` live in **separate
> keyspaces** and do **not** mutually exclude: key `k` taken via advisory
> and the same `k` taken via xclaim are two independent claims. If part
> of the code is already migrated to `xclaim.try` while another part
> still calls `pg_try_advisory_xact_lock` on the same key, both will
> "successfully" acquire it at once — mutual exclusion is broken. So
> **all** call sites of one keyspace must migrate at once, in a single
> change. A partial keyspace migration is a correctness bug, not an
> optimization.

Replace `pg_try_advisory_xact_lock(a, b)` with `xclaim.try(a, b)` and
`pg_try_advisory_xact_lock(c)` with `xclaim.try(c)` at each call site.
The signatures match exactly (volatility and parallel mode are
identical — see the parity table above). NULL behavior differs by
design: advisory silently returns NULL, `xclaim.try` raises an ERROR.

So the API is **signature-compatible but not behavior-identical**.
For most production call sites this is fine, nobody passes NULL as
a key. Still, check your code before migrating.

---

## Project layout

```
pg_xclaim/
├── Makefile                                   # PGXS
├── pg_xclaim.control                          # extension metadata
├── sql/
│   └── pg_xclaim--1.0.0-rc1.sql               # install script
├── src/
│   ├── pg_xclaim.c                            # _PG_init + GUCs + glue
│   ├── pg_xclaim_compat.h                     # PG 16/17/18 ABI shim
│   └── ...                                    # acquisition / cleanup / bulk
├── test/
│   ├── sql/, expected/                        # pg_regress
│   └── concurrency/                           # shell-driven concurrency suite
├── scripts/
│   ├── find_pg_config.sh
│   ├── run_temp_cluster.sh
│   ├── smoke_gate.sh                          # preload smoke gate
│   ├── smoke_gate_no_preload.sh               # no-preload smoke gate
│   ├── run_regress_matrix.sh
│   ├── bench_try_many.sh                      # self perf-budget gate
│   └── bench_alternatives.sh                  # comparison vs row locks / claim-table
├── docs/
│   ├── runbook.md                             # DBA runbook (Russian)
│   ├── runbook_en.md                          # DBA runbook (English)
│   ├── incident-decision-tree.md              # oncall triage (Russian)
│   ├── incident-decision-tree_en.md           # oncall triage (English)
│   └── perf/
│       ├── hot-path-analysis_en.md         # English version
│       ├── hot-path-analysis.md            # Russian version
│       ├── flamegraphs/                       # SVG flamegraphs
│       └── *.csv                              # bench + baseline measurements
├── .github/workflows/ci-pg-matrix.yml
└── README.md
```

---

## Performance

![Throughput under concurrency without key conflicts — true raw cost of 6 implementations on N=8 disjoint keyspace](assets/overview.png)

Numbers below are synthetic measurements, not universal performance claims. Cross-check against the latest CSV
in `docs/perf/` and measure on your own workload.

| Workload | Observed | Budget | Gate |
|----------|----------|--------|------|
| 750k single-backend scalar API | **~378 ms** end-to-end | 2000 ms | `bench_try_many.sh` |
| 750k bulk `xclaim.try_many` | **~288 ms** | 500 ms | `bench_try_many.sh` |
| 50k acquire+COMMIT (group cleanup) | **< 100 ms** | 100 ms | `grouped_cleanup_50k.sh` |

Numbers from the latest run on macOS PG 17.10 / Apple M-series:
[`docs/perf/bench-20260525-pg17.csv`](docs/perf/bench-20260525-pg17.csv)
(cumulative CSV, one row per run).

### Memory: how to size the budget

A fair "advisory vs pg_xclaim" memory comparison needs one caveat: for
advisory to hold 100k locks per backend at all, you need a
`max_locks_per_transaction` many times the default — which itself
balloons the cluster-wide shared lock table. So the "before" config is
either infeasible or pays its own price in shmem. That is why this
section gives a formula and an order of magnitude rather than one
flattering number — size it for your own `max_connections` and claim peak.

pg_xclaim **adds** a fixed shmem pool (`max_claims`; default ~360 MB)
plus per-backend local memory:

```
shmem (shared pool)       ≈ chosen max_claims (default 4M -> ~360 MB)
per-backend local         ≈ ~50.3 MB at 750k claims
                          ≈ ~6.3 MB at 100k claims
cluster-wide local        ≈ per-backend × number of active backends
```

Example (the high-cardinality scenario pg_xclaim is built for): 100k
claims per transaction × 200 concurrent backends gives
~6.3 MB × 200 ≈ ~1.26 GB of local memory plus ~360 MB shmem. In
exchange you drop the per-backend LOCALLOCK hash (~17 MB/backend at 100k
held advisory locks) and the need for an inflated
`max_locks_per_transaction`.

Empirically measured on PG 16 and PG 18 (the CPU/shmem structures
involved are backend-local, identical across versions). Full
breakdown with pre-grown floor and simplehash growth is in
[`docs/runbook_en.md` §9](docs/runbook_en.md#9-capacity-planning).
Under a light workload (10-100 locks per transaction), switching to
pg_xclaim **only adds** ~360 MB of shmem with no visible saving —
that kind of workload does not need pg_xclaim in the first place.

### Comparison with alternatives

![Tradeoffs at N=8 K=100k — throughput, p95 latency, WAL bytes across 6 implementations in overlap and disjoint modes](assets/perf-tradeoffs.png)

The repository contains a benchmark of pg_xclaim against five
standard alternatives forming a full 2×2 matrix of
`{UNLOGGED, LOGGED} × {UNSORTED, SORTED}` claim-tables:

| | unsorted INSERT | sorted INSERT (`ORDER BY k`) |
|---|---|---|
| **UNLOGGED** | B | F |
| **LOGGED**   | D | E |

Plus C: row locks via `FOR UPDATE NOWAIT`. The benchmark runs in two
workload modes: `overlap` (shared key pool, ~52% pairwise overlap at
N=8 K=100k) and `disjoint` (worker-disjoint slices, no key overlap).

Full numbers, methodology, and fairness caveats live in
[`docs/perf/COMPARISON_EN.md`](docs/perf/COMPARISON_EN.md). Raw
results:
[`bench-alternatives-20260524-overlap-pg17.csv`](docs/perf/bench-alternatives-20260524-overlap-pg17.csv)
and
[`bench-alternatives-20260524-disjoint-pg17.csv`](docs/perf/bench-alternatives-20260524-disjoint-pg17.csv).

Hardware: macOS, Apple M-series, PG 17.10. Important caveat: macOS does
not use `F_FULLFSYNC` by default, so a plain `fsync()` returns before
the data physically reaches disk — this flatters WAL-heavy variants
(C/D/E). On a server Linux box with honest fsync the ranking may differ;
read these as order-of-magnitude, not exact ratios.

Top-line summary (PG 17, ITERS=200, `fsync=on`, `log_lock_waits=on`, ACCOUNT_POOL=1M):

| Scenario | A pg_xclaim | B UNLOGGED | C row locks | D LOGGED | E LOGGED+sorted | F UNLOGGED+sorted |
|---|---:|---:|---:|---:|---:|---:|
| N=1, K=100k overlap — tx/sec | **38** | 2.3 | 9.6 | 1.7 | 2.5 | 5.1 |
| N=1, K=100k overlap — WAL    | **0** | 723 KB | 1.2 GB | 3.6 GB | 3.4 GB | 9 KB |
| N=8, K=100k overlap — tx/sec  | **209** | 18 | 223\* | 14 | 2.5 | 5.4 |
| N=8, K=100k overlap — p95 ms  | **29** | 478 | 23 | 669 | 8124 | 3571 |
| N=8, K=100k overlap — deadlocks (per scenario, cumulative) | 0 | **7** | 0 | **7** | 0 | 0 |
| N=8, K=100k disjoint — tx/sec | **194** | 13.6 | 17.8 | 4.3 | 5.2 | 15.2 |
| N=8, K=100k disjoint — p95 ms | **32** | 719 | 721 | 2367 | 1964 | 580 |
| N=8, K=100k disjoint — WAL    | **0** | 73 KB | **6.8 GB** | **20.5 GB** | 20.2 GB | 72 KB |

> \* C's apparent overlap win is a NOWAIT fail-fast artifact: it
> bails out on the first conflict in microseconds and **acquires 0
> keys per transaction**. On `disjoint`, where NOWAIT cannot "cheat",
> the same C drops to 18 tx/sec. See `docs/perf/COMPARISON_EN.md`
> for the full caveat and observations.

Deadlocks measured directly: at N=8 K=100k overlap, the
unsorted claim-tables (B and D) hit 7 deadlocks per scenario.
Sorted variants (E and F) hit 0 deadlocks. Sort really does
eliminate them, but converts them into wait-on-lock serialization
(see COMPARISON_EN.md).

What the full B/D/E/F matrix shows:

- **On overlap** sort itself produces serialization. F (no WAL) ≈ E
  (with WAL) at K=100k — both ~5 tx/sec with p95 > 3 seconds. So
  the main cost of the sorted variant is not WAL, it is the
  deterministic acquisition order under key overlap.
- **On disjoint** the picture inverts: F (15.2) > B (13.6) and
  F >> E (5.2). Without conflicts sort is neutral or a small win
  (likely cache locality in btree), and the main cost of E/D is
  WAL (a LOGGED table emits ~20 GB of WAL per N=8 K=100k scenario —
  D ~20.5 GB, E ~20.2 GB — vs ~72 KB for F).

When pg_xclaim earns its place: K ≥ 10k and concurrency ≥ 8 and
workload cannot rely on NOWAIT fail-fast. Otherwise, pick by
operational simplicity (B/C/D/E/F need no extension and are visible
in standard tooling). Run the benchmark against a mirror of your own
system before deciding.

## Operational reference

| Document | Purpose |
|----------|---------|
| [`docs/runbook_en.md`](docs/runbook_en.md) | DBA ops runbook — deploy, monitor, rollback. |
| [`docs/incident-decision-tree_en.md`](docs/incident-decision-tree_en.md) | Oncall triage flow (P0–P3). |
| [`docs/perf/hot-path-analysis_en.md`](docs/perf/hot-path-analysis_en.md) | Hot-path profile with flamegraphs. |

---

## Limitations

A compact list of what pg_xclaim deliberately does not do. Details for
each item are in [`docs/runbook_en.md`](docs/runbook_en.md).

- **`PREPARE TRANSACTION` is rejected** (SQLSTATE `0A000`,
  `ERRCODE_FEATURE_NOT_SUPPORTED`). This is an explicit divergence from
  advisory: advisory locks **survive** `PREPARE`, pg_xclaim claims do
  not. See `docs/runbook_en.md`.
- **Try-only API:** no blocking acquire, no wait queue, no deadlock
  detection. Retry-loop acquisition ordering is the caller's
  responsibility; PostgreSQL's deadlock detector cannot see pg_xclaim
  claims.
- **Hot-standby:** on a replica in recovery the first call raises
  `ERRCODE_FEATURE_NOT_SUPPORTED`. Remove from preload before promotion.
- **Subtransaction lifetime** diverges from advisory: a claim survives
  `ROLLBACK TO SAVEPOINT` and is released only by the top-level
  COMMIT/ABORT (see the section above).
- **Windows** is untested and unsupported.
- **Transaction pooling** (pgbouncer/odyssey in `transaction` mode):
  claims are tied to the transaction and released at its boundary; do
  not wire `session_reset` into the pooler `server_reset_query`.

---

## Security and multi-tenant

`pg_xclaim.max_claims` is **one** fixed pool, cluster-wide, shared across
all databases. The default `GRANT EXECUTE ... TO PUBLIC` grants mirror
advisory's defaults and carry the same exposure: any grantee can
deliberately exhaust the pool and force `on_capacity_exhaustion=error`
to raise for other sessions. On clusters with untrusted roles, run
`REVOKE EXECUTE` (verify the exact signatures in
[`sql/pg_xclaim--1.0.0-rc1.sql`](sql/pg_xclaim--1.0.0-rc1.sql)):

```sql
REVOKE EXECUTE ON FUNCTION xclaim.try(int8)              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION xclaim.try(int4, int4)        FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION xclaim.try_many(int8[])       FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION xclaim.try_many(int4, int4[]) FROM PUBLIC;
```

Full threat model and vulnerability-disclosure process are in
[`.github/SECURITY.md`](.github/SECURITY.md).

---

## FAQ

Questions any thoughtful PG engineer will ask.

### Q1: "Why not just bump `max_locks_per_transaction` to 8192?"

In most cases this is the right fix; we recommend it first (see
row 1 in [Alternatives](#alternatives)).

It did not work for us for one reason: under high concurrency the
LockManager partition LWLocks themselves become a wait-event
hotspot. Raising `max_locks_per_transaction` does not cure that,
the contention is still there.

If you have ordinary `max_locks_per_transaction` exhaustion and
`LWLock:LockManager` is not in your top wait events, raise the GUC
and skip pg_xclaim. It is cheaper and simpler.

### Q2: "Why not `SELECT ... FOR UPDATE NOWAIT` on the accounts themselves?"

For new systems this is often the right choice. In our system
`accounts` is a heavy-update table with dozens of columns and is
partitioned by an unrelated key. FOR UPDATE on thousands of rows
generates significant WAL and dead tuples, and row-level locks on
thousands of accounts hit dozens of partitions with unpredictable
cost. See [Comparison with alternatives](#comparison-with-alternatives)
for measured numbers.

### Q3: "Why not `INSERT INTO claim_table ... ON CONFLICT DO NOTHING`?"

![Sorted INSERT trades deadlocks for serialization — 4-line counter-intuitive finding (B/D/F/E throughput vs K under overlap)](assets/sorted-insert-finding.png)

It works semantically, we tested it. The main problem shows up
under load: deadlocks on the UNIQUE index (see
[Comparison with alternatives](#comparison-with-alternatives)).

Concrete numbers, 8 concurrent backends with overlapping keys
(overlap, K=100k) — these are distinct points, not one range:
- B (UNLOGGED): 17.8 tx/sec, p95 478 ms, 7 deadlocks per scenario;
- D (LOGGED): 14.1 tx/sec, p95 669 ms, 7 deadlocks;
- E (LOGGED+sorted): 2.5 tx/sec, p95 8124 ms, 0 deadlocks;
- F (UNLOGGED+sorted): 5.4 tx/sec, p95 3571 ms, 0 deadlocks;
- pg_xclaim in the same setup: 209 tx/sec, p95 29 ms.

Exact numbers depend on K and whether the batch is sorted (see the
tables in [Comparison](#comparison-with-alternatives)). You can
soften this with `lock_timeout` + application retries, but that's
extra complexity.

We run the benchmark in three claim-table variants:

- B (UNLOGGED) — a fair in-memory comparison with xclaim;
- D (LOGGED) — closer to production;
- E (LOGGED + ORDER BY) — the production trick against deadlocks.

LOGGED variants also generate heap+index WAL: ~18 MB of WAL per
100k-claim transaction (~3.6 GB over a 200-transaction scenario;
pg_xclaim emits 0). This directly pressures replication lag and
autovacuum. Deadlocks on the UNIQUE index under key overlap show up
in the unsorted variants (B/D, 7 per scenario); sorted variants (E/F)
eliminate them at the cost of wait-on-lock serialization. In E under
overlap that serialization turned out worse than the unsorted variant.

Claim-table also needs DDL: a separate table, a migration,
coupling to the application schema. The decisive argument in our
case was zero DDL and hundreds of legacy advisory call sites — a
`sed`-based migration of `pg_try_advisory_xact_lock` → `xclaim.try`
without touching the schema.

If you have a new project with low cardinality and moderate
concurrency, the claim-table approach is simpler and clearer.

### Q4: "This adds operational complexity — DBAs now look in two places during an incident."

Yes, that is a real downside, and we acknowledge it openly.
`pg_locks` will not show xclaims; baseline visibility comes from
`xclaim.stats()`, and detailed `SELECT * FROM xclaim.debug_snapshot()`
works only when `pg_xclaim.num_partitions <= 192`. We added
[`docs/runbook_en.md`](docs/runbook_en.md) and
[`docs/incident-decision-tree_en.md`](docs/incident-decision-tree_en.md)
precisely because a new stateful primitive equals a new incident
playbook. If you do not have the team capacity to train DBAs on an
additional tool, do not use pg_xclaim.

### Q5: "Will this be maintained two years from now, on PG 19/20?"

No guarantee. Every PG major release requires compat patches (PG 16->17->18
already covered).

Upstream PG is moving toward less LockManager contention. For example,
in PG 18 Tomas Vondra extended fast-path locking
([release notes](https://www.postgresql.org/docs/release/18.0/),
[commit `c4d5cb71d22`](https://git.postgresql.org/gitweb/?p=postgresql.git;a=commit;h=c4d5cb71d229095a39fda1121a75ee40e6069a2a)),
removing the `LWLock:LockManager` bottleneck for query-heavy workloads
with many relation locks.

That mechanism does not transfer to advisory locks. Fast-path
requires weak-mode dominance (`mode < ShareUpdateExclusiveLock` in
`EligibleForRelationFastPath`), and advisory locks are exclusive by
design: mutual exclusion is their whole point.

Other paths for reducing LockManager contention exist (raising
`NUM_LOCK_PARTITIONS`, a dedicated pool for advisory locks). If
upstream takes one of these steps, pg_xclaim's niche shrinks.

### Q6: "Where is it actually appropriate to use this?"

A very narrow segment:

1. Self-hosted PG (managed cloud is excluded by `shared_preload_libraries`).
2. `LWLock:LockManager` measured as a top wait event under realistic load.
3. The workload holds 100k+ claims per transaction.
4. Alternatives 3-4 ruled out by measured reasons (benchmark); 1, 2
   by architectural reasons specific to the system (not "felt wrong").
5. Team capacity for extension maintenance + DBA training.

If any one of (1)–(5) is missing, take the alternatives.

### Q7: "Is this related to Redis XCLAIM?"

No. No relation to the Redis `XCLAIM` command. The name stands for
**transactional (xact) claims** — claims tied to the lifecycle of a
PostgreSQL transaction. The `xclaim` schema is fixed
(`relocatable = false`) and cannot be renamed at `CREATE EXTENSION` —
check that the name `xclaim` is free in your database before installing.

---

## License

[PostgreSQL License](LICENSE) — same liberal terms as PostgreSQL itself.
Copyright (c) 2026, E. Pavlichenko.

---

## Status

**v1.0.0-rc1** — first public release candidate of an experimental
proof-of-concept. Documentation and tests are in place, build matrix
green on PG 16/17/18, the code is covered by a 3-tier test suite
plus perf budgets.

Why `1.0.0-rc1` rather than `0.x` while still "experimental": the public
SQL API is frozen (function signatures, GUC names, schema), and the
extension passes the full test matrix on PG 16/17/18. "Experimental"
refers to the narrowness of the niche and operational maturity, not to
API instability. See [`CHANGELOG.md`](CHANGELOG.md) for the change history.