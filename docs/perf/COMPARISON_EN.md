# pg_xclaim vs alternatives - full benchmark

> **Русская версия:** [`COMPARISON.md`](COMPARISON.md).

This file is the long-form companion to the `Comparison with alternatives`
summary in the project README. The README keeps a top-line table for
casual readers, and this document holds the full numbers, the methodology,
the fairness caveats, and the observations.

> **If you are skimming - the headline:**
>
> - In this benchmark pg_xclaim is clearly ahead under three conditions
>   at the same time:
>   - K >= 10k
>   - concurrency >= 8
>   - the alternative cannot use a fail-fast escape (NOWAIT trick).
> - The A and B-F numbers are not directly comparable: they are an
>   order of magnitude for this methodology, not a ratio of acquisition
>   costs (see the methodology limitation under [Reproducing](#reproducing)).
> - At K <= 1k or low concurrency, every approach (B/C/D/E/F) is in
>   the same league. Pick by operational simplicity, not raw
>   throughput.
> - At high concurrency claim-tables don't slow down because of
>   deadlocks. The pattern matches PostgreSQL's heap
>   `RelationExtensionLock` - a serialization point during heap-page
>   extension. xclaim does not have that point: state lives in shared
>   memory, not in the heap.
> - Sorted INSERT (the common production fix against deadlocks)
>   measurably loses to its own run without overlap. Deadlocks do not
>   disappear - they turn into wait-on-lock serialization. It cannot
>   be compared with unsorted B/D under overlap: their workers drop out
>   on deadlocks, and the B/D numbers there are unreliable.

## Implementations measured

- A (pg_xclaim): `xclaim.try_many(1, $keys)` - this extension.
- C (row locks): `SELECT ... FOR UPDATE NOWAIT` on a synthetic
  accounts table (1M rows, primary key).

Plus a full 2x2 matrix of claim-table variants
`{UNLOGGED, LOGGED} x {UNSORTED, SORTED}`:

|              | unsorted INSERT | sorted INSERT (`ORDER BY k`) |
|--------------|-----------------|------------------------------|
| **UNLOGGED** | **B**           | **F**                        |
| **LOGGED**   | **D**           | **E**                        |

- B (UNLOGGED unsorted): `INSERT INTO claims_t ... ON CONFLICT DO NOTHING`.
  Fair in-memory comparison to xclaim - no heap+index WAL, but
  UNIQUE conflicts present.
- D (LOGGED unsorted): same as B without `UNLOGGED`.
  Production-realistic durable claim-table.
- E (LOGGED sorted): same as D plus `ORDER BY account_id`.
  Production pattern against deadlocks.
- F (UNLOGGED sorted): same as E plus `UNLOGGED`. Isolates the
  cost of sort itself from WAL.

The full matrix lets us answer two independent questions: **B vs F**
answers "what does sorting cost without WAL?", **F vs E** answers
"what does WAL add on top of sorting?".

## Workload modes

- `MODE=overlap` - every backend draws random keys from a shared
  1M pool, ~52% pairwise overlap at N=8 K=100k. Models a production
  scenario where different operations naturally overlap on accounts.
- `MODE=disjoint` - every backend gets its own slice of the
  keyspace via a `worker_id` offset. Two concurrent backends never
  request the same key. Isolates the raw cost of the implementations
  from the cost of conflict resolution.

Why two modes. `overlap` mirrors a production workload where
backends naturally collide on the same accounts, and conflict
resolution dominates the picture. `disjoint` strips conflict cost
out entirely - backends never request the same key - so the
remaining throughput measures the raw per-implementation cost. For
A this holds with a caveat, see the methodology limitation below.

The two together let the reader separate two independent
contributions: the cost of resolving conflicts (visible only in
`overlap`) and the cost of the implementation's work per acquired
key (visible in `disjoint`). They also expose the NOWAIT fail-fast
artifact: at K=100k C jumps from 17.8 tx/sec (disjoint, real work)
to 223 tx/sec (overlap, NOWAIT bails out on the first conflict,
acquiring 0 keys per iteration).

## Reproducing

Script: [`scripts/bench_alternatives.sh`](../../scripts/bench_alternatives.sh)
(flag `MODE=overlap|disjoint`).

```bash
# overlap mode (default)
bash scripts/bench_alternatives.sh /usr/lib/postgresql/16/bin/pg_config

# disjoint mode
MODE=disjoint bash scripts/bench_alternatives.sh /usr/lib/postgresql/16/bin/pg_config
```

Numbers below: PG 17, ITERS=200 iterations per worker in every scenario, ACCOUNT_POOL=1M, `fsync=on`, `log_lock_waits=on`.
Full CSV results:
[`bench-alternatives-20260524-overlap-pg17.csv`](bench-alternatives-20260524-overlap-pg17.csv) and
[`bench-alternatives-20260524-disjoint-pg17.csv`](bench-alternatives-20260524-disjoint-pg17.csv).

**Methodology limitation.** In `scripts/bench_alternatives.sh` every
iteration runs in a subtransaction inside one worker transaction.
Claim-table rows (B, D, E, F) and C's row locks vanish when the
subtransaction rolls back, while pg_xclaim claims survive the rollback
and accumulate until the transaction ends, so with every iteration a
growing share of A's acquisitions re-enters keys it already holds or
conflicts with claims of other workers. A B or D worker that fails on
a deadlock drops out without samples, while throughput (tx/sec in the
tables is iterations per second across all workers) is computed for
the full iteration count. The A and B-F numbers are therefore not
directly comparable: they are an order of magnitude for this
methodology, not a ratio of acquisition costs.

---

## Results

### Single backend (N=1, no contention) - overlap mode

Throughput, tx/sec (numbers from the overlap run. At N=1 there is no
contention, so the mode does not affect the result):

| K | A | B (UNLOGGED) | C (row locks) | D (LOGGED) | E (LOGGED+sorted) | F (UNLOGGED+sorted) |
|---|---:|---:|---:|---:|---:|---:|
| 1k    | 2287 | 455 | 506  | 311  | 327  | 435  |
| 10k   | 311  | 31  | 73   | 26   | 37   | 52   |
| 100k  | 38   | 2.3 | 9.6  | 1.7  | 2.5  | 5.1  |

### 8 concurrent backends - `overlap` (~52% overlap)

Throughput, tx/sec (unreliable for B and D, see the deadlocks below):

| K | A | B (UNLOGGED) | C (row locks) | D (LOGGED) | E (LOGGED+sorted) | F (UNLOGGED+sorted) |
|---|---:|---:|---:|---:|---:|---:|
| 1k    | 12214 | **214** | 1390 | **201** | 296  | 915  |
| 10k   | 2422  | 124     | 701  | 98      | **25** | 60 |
| 100k  | 209   | 18      | **223**\* | 14 | **2.5** | **5.4** |

p95 latency, ms (unreliable for B and D, see the deadlocks below):

| K | A | B | C | D | E | F |
|---|---:|---:|---:|---:|---:|---:|
| 1k    | 0.6  | 2.6  | 14    | 8.5    | 58   | 17  |
| 10k   | 2.8  | 38   | 13    | 66     | **672** | 286 |
| 100k  | 29   | 478  | 23    | 669    | **8124** | **3571** |

Deadlocks (`pg_stat_database.deadlocks` delta per scenario):

| K | A | B | C | D | E | F |
|---|---:|---:|---:|---:|---:|---:|
| 1k    | 0 | **7** | 0 | **7** | 0 | 0 |
| 10k   | 0 | **7** | 0 | **7** | 0 | 0 |
| 100k  | 0 | **7** | 0 | **7** | 0 | 0 |

Important fairness caveat (C on overlap). C shows 223 tx/sec at
K=100k, ahead of A (209), but this is an artifact of NOWAIT
semantics. At ~52% overlap nearly every `FOR UPDATE NOWAIT`
fails with `lock_not_available` on the first conflicting row,
effectively acquiring **0 keys per iteration**. The iteration is
short --> throughput is high --> but no business work was done. A
operates with different semantics (best-effort: acquire everything
that does not conflict, mark the rest `false`), so it walks the full
100k-key batch instead of bailing out on the first conflict. These
are different "done" semantics: NOWAIT is atomic all-or-nothing,
xclaim/ON-CONFLICT is best-effort. To compare the raw cost of the
implementations without the fail-fast shortcut, see `disjoint` below.

Deadlocks measured directly (not inferred from throughput collapse):
B and D hit 7 deadlocks in every scenario, and each of them ends the
transaction of one worker: the `EXCEPTION` block in
`scripts/bench_alternatives.sh` catches only `XBENC` and
`lock_not_available`. Such a worker drops out without samples, the
script does not check worker exit statuses, and it computes
throughput for the full 8 x 200 iterations. 7 deadlocks with 8
workers mean that one worker reached the end. B and D throughput and
p95 in overlap mode are therefore unreliable, and the conclusions that
rely on them are marked as such. Indirectly this shows at K=100k: the
overlap throughput of B and D (18 and 14 tx/sec) is about 8 times
their own N=1 numbers (2.3 and 1.7), as if one worker ran and its
iterations were counted for eight.

E and F (sorted) hit 0 deadlocks. Sort really does eliminate them,
but converts them into wait-on-lock serialization (see
observation #3 below).

### 8 concurrent backends - `disjoint` (no key overlap)

Throughput, tx/sec:

| K | A | B (UNLOGGED) | C (row locks) | D (LOGGED) | E (LOGGED+sorted) | F (UNLOGGED+sorted) |
|---|---:|---:|---:|---:|---:|---:|
| 1k    | 13505 | 1216 | 522  | 266   | 323   | 1253 |
| 10k   | 3237  | 113  | 88   | 29    | 31    | 126  |
| 100k  | **194** | 13.6 | 17.8 | 4.3 | 5.2   | 15.2 |

p95 latency, ms:

| K | A | B | C | D | E | F |
|---|---:|---:|---:|---:|---:|---:|
| 1k    | 0.4  | 7.1  | 15    | 39    | 35    | 6.7   |
| 10k   | 1.8  | 87   | 120   | 344   | 333   | 68    |
| 100k  | 32   | 719  | 721   | 2367  | 1964  | 580   |

WAL bytes per scenario (cumulative across 8 backends x 200 iterations):

| K | A | B (UNLOGGED) | C (row locks) | D (LOGGED) | E (LOGGED+sorted) | F (UNLOGGED+sorted) |
|---|---:|---:|---:|---:|---:|---:|
| 1k    | 0 | 72 KB  | 178 MB | 291 MB  | 287 MB  | 72 KB |
| 10k   | 0 | 141 KB | 952 MB | 2.8 GB  | 2.8 GB  | 72 KB |
| 100k  | **0** | 73 KB  | **6.8 GB** | **20.5 GB** | 20.2 GB | 72 KB |

Under `fsync=on` (production-realistic) the LOGGED variants emit
20+ GB of WAL per N=8 K=100k scenario (D = 20.5 GB, E = 20.2 GB, avg
~2.6 GB per backend across 8 backends). This pressures replication
lag and autovacuum spend. C also writes notable WAL (6.8 GB in the
same scenario): on disjoint NOWAIT does not bail out, every iteration
locks the rows of all its keys, and each row lock writes a WAL
record.

---

## Observations

1. **On `disjoint` (no overlap) A has the highest numbers of this
   benchmark.** At N=8 K=100k: A=194 tx/sec, while the closest are
   C=17.8 and F=15.2 - a ~11x gap, with no NOWAIT shortcut. But this
   is not a ratio of acquisition costs: A's iterations increasingly
   re-enter keys already held (see the methodology limitation).

2. **The "C beats A on overlap K=100k" anomaly** is explained by
   NOWAIT fail-fast semantics (see caveat above). When the same C
   runs on `disjoint`, where NOWAIT cannot "bail out", its
   throughput drops from 223 to 17.8 tx/sec (~12x slower). A stays
   stable in that situation.

3. **Sorted INSERT (E/F) eliminates deadlocks but on overlap
   measurably loses to its own disjoint run.** At overlap K=100k E
   (LOGGED+sorted) gives 2.5 tx/sec and p95=8.1 s, F
   (UNLOGGED+sorted) gives 5.4 tx/sec and p95=3.6 s, while on
   disjoint the same variants give 5.2 and 15.2 tx/sec with p95 of
   2.0 and 0.58 s. They cannot be compared with unsorted D/B on
   overlap: the B and D numbers there are unreliable (see the
   deadlocks above). This is the _observed_ benchmark outcome, and
   the likely mechanism is that deterministic acquisition order rules
   out deadlocks but turns them into wait-on-lock chains where 8
   backends serialize on overlapping keys. Production claim-tables
   often recommend the sorted variant. Our data point shows the price
   of that advice under high overlap concurrency: throughput drops
   and p95 grows to seconds. We did not capture wait-event traces -
   this is the _observed_ outcome, not a proven cause.

4. **The full B/D/E/F matrix separates two independent cost
   factors: sort and WAL.** F vs B and F vs E expose this directly:

   | Comparison | overlap K=100k | disjoint K=100k |
   |---|---|---|
   | F vs B (sort cost without WAL) | F=5.4, B=18 - not comparable: the B number on overlap is unreliable | F=15.2, B=13.6 - sort is neutral or a small win |
   | F vs E (WAL cost on top of sorted) | F=5.4, E=2.5 - WAL adds ~2x penalty on top of serialization | F=15.2, E=5.2 - WAL costs ~65% throughput |
   | B vs D (WAL cost on top of unsorted) | B=18, D=14 - not comparable: the B and D numbers on overlap are unreliable | B=13.6, D=4.3 - WAL costs ~68% throughput |

   Conclusion: on disjoint the dominant cost is WAL and
   `RelationExtensionLock`. On overlap only the F vs E comparison is
   reliable: WAL adds ~2x to the sorted variant.

5. **B/D/E/F show low throughput even on `disjoint`** (~4-15 tx/sec
   at N=8 K=100k). This is not deadlocks (there are no key
   conflicts) and not sort (F (sorted) gives 15.2 tx/sec against
   B (unsorted) 13.6). The pattern is consistent with PostgreSQL's
   `RelationExtensionLock`: a per-relation lock taken when a backend
   has to extend the heap with a new page, see
   `LockRelationForExtension` (`lmgr.c:414`) and the
   `LOCKTAG_RELATION_EXTEND` tag (`lock.h:139`). Concurrent INSERTs
   into the same table all contend on this lock. We did not capture
   wait-event traces - this is the _observed_ outcome, not a proven
   cause. xclaim does not have an equivalent contention point because
   state lives in a shmem hashtable, not in the heap.

6. **WAL is the dominant cost of LOGGED variants on disjoint.** D on
   disjoint N=8 K=100k = 4.3 tx/sec and 20.5 GB of WAL per scenario,
   while F (no WAL) = 15.2 tx/sec at 72 KB of WAL. ~70% throughput
   difference under the same workload type and the same
   serialization effects. This pressures replication lag and
   autovacuum, and the effect grows with K.

7. **Row locks (C) scale reasonably**, but generate significant WAL
   (1.2 GB at N=1 K=100k --> 6.8 GB at N=8 K=100k disjoint), and on
   `overlap` suffer from NOWAIT semantics.

8. **A runs without WAL and keeps p95 predictable.** At K=1k all
   variants are in the same league, so choose by operational
   simplicity, which favours B/C/D/E/F (no extension needed,
   visible in standard tooling). At K >= 10k and concurrency >= 8
   without overlap A pulls clearly ahead in this benchmark, although
   this is not a ratio of acquisition costs (see the methodology
   limitation). This is the narrow niche where pg_xclaim is worth
   considering.

---

## Caveats

- All numbers come from a single hardware setup (Apple M-series, PG
  17.10) with `ITERS=200` iterations per scenario per backend
  (default from `scripts/bench_alternatives.sh`). On N=8 that is up
  to 1600 samples per p95: a worker that drops out on a deadlock
  leaves no samples. Treat the values as order-of-magnitude
  estimates, not as an SLA promise.
- `MODE=disjoint` gives each worker a separate shard via `worker_id`
  offset. This is the best case for any implementation that scales
  linearly with parallelism. Real production workloads usually sit
  somewhere between `overlap` and `disjoint`.
- Attributing the costs to `RelationExtensionLock` and to
  sorted-INSERT serialization - these are likely mechanisms, not
  fully proven causes. Wait-event traces would confirm them.
- The benchmark measures **throughput and tail latency** of acquire
  operations. It does not measure long-term overheads such as table
  bloat, vacuum cost, replication lag accumulated across days, or
  cache eviction patterns under sustained load. Real production
  workloads will surface effects this micro-benchmark cannot.
- **macOS fsync does not guarantee a real flush to disk.** These
  numbers were taken on Apple M-series, where PostgreSQL does **not**
  use `F_FULLFSYNC` by default: a plain `fsync()` on macOS returns
  before the data has physically reached the medium. So the WAL-heavy
  variants (C/D/E) may behave very differently on a real Linux server
  with honest fsync - their relative penalty there is likely even
  larger. Read the ranking of approaches as order-of-magnitude, not as
  exact ratios.
- Before choosing for your own system, run `bench_alternatives.sh`
  against a mirror of it. Numbers from someone else's hardware do not
  translate directly to yours.
