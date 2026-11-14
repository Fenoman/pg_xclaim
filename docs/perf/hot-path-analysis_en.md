# Hot-path analysis

> **Русская версия:** [`hot-path-analysis.md`](hot-path-analysis.md).

Where `pg_xclaim` spends CPU and why. This document is for anyone
curious - see how the overhead breaks down without spinning up your
own profiling pipeline.

All numbers below are real measurements taken with `perf` and
flamegraphs. The artifacts ship in `docs/perf/flamegraphs/` (SVG,
open in any browser).

Numbers depend on the hardware: CPU, kernel, compiler, debug-info
availability. On your server they will be different. Treat them as
illustrating the pattern, not as universal performance claims. The
reproduction script is in §Reproduction below.

---

## Setup (this profile run)

| Property | Value |
|----------|-------|
| Hardware | x86_64 AMD EPYC, 16 vCPU @ 2.6 GHz, 62 GiB RAM (dedicated Linux VPS) |
| Kernel | 6.8.0-106-generic (Ubuntu 24.04.4 LTS) |
| PostgreSQL | **17.10 from PGDG apt repo** (`postgresql-17` + `postgresql-17-dbgsym`). The binary `/usr/lib/postgresql/17/bin/postgres` is stripped, but debug-info in `/usr/lib/debug/.build-id/...` is wired up by `perf` automatically via Build-ID. No manual PG rebuild from source needed. |
| Build | gcc 13.3 (`/usr/bin/gcc`), pg_xclaim built with `PG_CFLAGS='-O2 -g -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer'`. `pg_xclaim.so` carries debug-info inline (`with debug_info, not stripped`). |
| Profiler | `perf record -F 997 -g -a` (system-wide CPU sampling), perf 6.8.12 |
| Window | 12 seconds for single-backend scenarios, 15 seconds for concurrent. The load is finite: one second after `perf` starts, the driver runs the scenario SQL once and does not fit it to the window. If the SQL ends before the window does, the tail of the window has no load, and if it does not finish in time, the rest is not recorded |
| Stack unwind | Frame pointers: `perf record -g` without `--call-graph dwarf`. When a function has no frame pointer, its direct caller drops out of the stack: in the scalar SVG `hash_bytes` sits under `xclaim_try_pair`, although the call comes from `xclaim_try_internal` |
| Symbol resolution | **Each layer resolves through its own source:** kernel symbols via `kallsyms`, PG core via dbgsym Build-ID debug-info (`/usr/lib/debug/.build-id/...`), and pg_xclaim via its own inline DWARF in `pg_xclaim.so`. The top-15 leaves below name real functions (`xclaim_local_lookup_with_hash`, `hash_search_with_hash_value`, `clear_page_rep`, `asm_exc_page_fault`). The `[libc.so.6]` bucket (~2-5%) is libc memcpy/memset/strlen without `libc6-dbg` - not critical for user-space hot-path interpretation. Requires `sysctl kernel.kptr_restrict=0` and running `perf record` as root (initdb/pg_ctl/psql delegated to the postgres user via `runuser`). Without that, kernel symbols collapse into an `[unknown]` bucket. |

---

## Architectural call chain

A typical `xclaim.try(int4, int4)` in a single backend:

```
PostgresMain
└── exec_simple_query
    └── PortalRun -> ExecutorRun
        └── ExecResult -> ExecEvalFuncArgs
            └── FunctionCall (V1 trampoline)
                ├── xclaim_try_pair             [SQL entry]
                │   ├── XCLAIM_REQUIRE_INIT     [recovery + preload gate]
                │   ├── memset(&key, 0, sizeof(XClaimKey))   [HASH_BLOBS req]
                │   └── xclaim_try_internal     [12-step algorithm]
                │       ├── CHECK_FOR_INTERRUPTS            [the only cancel point]
                │       ├── xclaim_ensure_owner_token        [lazy, a new token after session_reset]
                │       ├── xclaim_compute_hash             [one key hash for local + shared]
                │       │   └── get_hash_value -> tag_hash -> hash_bytes
                │       ├── xclaim_local_lookup_with_hash    [reentrancy fast-path]
                │       │   └── xcl_local_lookup_hash (simplehash, hash is passed, not recomputed)
                │       │       └── memcmp (16-byte key)
                │       ├── xclaim_local_reserve(1)          [set growth before the lock]
                │       ├── xclaim_local_add                 [local entry before the lock,
                │       │                                     not counted yet]
                │       ├── xclaim_partition_lock           [hashvalue & mask]
                │       ├── PG_TRY { LWLockAcquire(plock, EXCLUSIVE) } ─┐
                │       ├── hash_search_with_hash_value     │ critical
                │       │   (HASH_ENTER_NULL - combined     │ section
                │       │    lookup-or-insert, *found       │
                │       │    distinguishes existing vs      │
                │       │    fresh, NULL on capacity)       │
                │       ├── [if found && !matches_self]     │
                │       │       xclaim_is_stale_owner       │
                │       │   └── xclaim_get_pgproc_by_procno │
                │       │       └── GetPGProcByNumber       [PG core macro,
                │       │                                    storage/proc.h]
                │       ├── [fresh] pg_atomic_fetch_add_u64 │
                │       │   (live_capacity)                 │
                │       ├── populate XClaimEntry owner      │
                │       │   triple (procno+lxid+token)      │ - writes fresh
                │       │                                   │   slot OR
                │       │                                   │   overwrites a
                │       │                                   │   stale-reap'd
                │       │                                   │   slot in place
                │       └── LWLockRelease(plock)            ─┘
                │       ├── xclaim_local_note_held          [count, peak, held-key list,
                │       │                                    75% hint]
                │       │   (xclaim_local_drop instead on a conflict or a
                │       │    capacity miss)
                │       ├── pg_atomic_fetch_add_u64(per-backend total_acquires_local)
                │       ├── CAS peak_per_backend
                │       ├── xclaim_local_emit_peak_warning  [messages after the counters]
                │       └── xclaim_check_capacity_watermark
                │           └── pg_atomic_read_u64(live_capacity)
```

Cleanup on COMMIT/ABORT:

```
CommitTransactionCommand / AbortTransaction
└── CallXactCallbacks(XACT_EVENT_COMMIT | _ABORT)
    └── xclaim_xact_callback
        └── xclaim_local_cleanup_held
            ├── [claims at most 1/64 of the buckets, all in the held-key list]
            │   xclaim_local_cleanup_by_list: lookup of the listed keys,
            │   qsort by partition_id, release per partition, delete of
            │   the keys one by one, no walk of the array
            └── [otherwise] the full path:
            ├── xclaim_local_gather_pointers     [O(N) walk simplehash]
            ├── counting sort by partition_id    [O(N + num_partitions)]
            └── for each partition (<= num_partitions cycles):
                ├── LWLockAcquire(plock, EXCLUSIVE) ─┐
                ├── for each entry in partition:    │
                │   ├── hash_search HASH_FIND       │
                │   ├── xclaim_shared_matches_saved_owner
                │   │   (compare saved triple)      │
                │   └── hash_search HASH_REMOVE     │
                └── LWLockRelease(plock)            ─┘
            ├── pg_atomic_fetch_sub_u64(live_capacity, total_removed)  [batched]
            └── xcl_local_reset (in-place truncate of simplehash)
```

---

## Hardware-counter evidence (`perf stat`)

CPU attribution via FlameGraph answers "where does CPU burn when the
process is ON-CPU". HW counters answer a **different** question: "is
the code CPU-bound, memory-bound, or branch-bound?", but only when
collected per process. Here they are collected for the whole machine,
see below.

Raw data: [`perf-stat/<scenario>.txt`](perf-stat/) from
`scripts/record_perf_evidence.sh` (system-wide
`perf stat -e cycles,instructions,cache-references,cache-misses,
LLC-load-misses,LLC-store-misses,branch-instructions,branch-misses,
page-faults,context-switches,cpu-migrations`).

| Scenario | cycles | instructions | IPC | cache-miss% | branch-miss% | page-faults | ctx-sw |
|----------|------:|-------------:|----:|------------:|-------------:|------------:|-------:|
| scalar-acquire | 20.7G | 13.1G | **0.63** | 39.31% | 5.84% | 117K | 86K |
| bulk-try-many | 29.3G | 33.1G | 1.13 | 33.97% | 2.90% | 264K | 77K |
| cleanup-commit | 24.0G | 14.8G | **0.62** | 37.51% | 6.03% | 229K | 89K |
| concurrent-contention | 39.1G | 29.4G | 0.75 | 32.38% | 4.55% | 527K | 104K |

These counters come from a separate run of the same SQL:
`perf stat -a` over the whole window (the raw files say
"Performance counter stats for 'system wide'"). They include every
process and the kernel of the machine for the whole window, including
the tail after the SQL ends, and the events are multiplexed (each was
counted for ~2/3 of the window). The share of the scenario backend
cannot be determined from this data, so the IPC, cache-miss% and
branch-miss% are not attributed to pg_xclaim or to individual paths
such as HASH_REMOVE.

These counters do not measure the win of the bulk API over scalar
either. On the Mac (`docs/perf/bench-20260525-pg17.csv`) the 750k-key
medians are 378 ms for scalar and 288 ms for bulk, ~1.3x.

`LLC-load-misses` shows `<not supported>` - on the test AMD EPYC the
Linux perf subsystem does not enumerate the LLC perf event.

---

## Off-CPU wait evidence (`pg_wait_sampling`)

FlameGraph sees ON-CPU samples - a backend blocked on an LWLock or IO
is **invisible** there. `pg_wait_sampling` samples
`pg_stat_activity.wait_event` every 10ms, providing wait attribution
that complements the FlameGraph.

Raw data: [`wait-events/<scenario>.csv`](wait-events/) (filter:
`event_type NOT IN ('Activity', 'Client', 'Timeout', 'Extension')` -
excludes idle background workers and clients parked on ClientRead).

| Scenario | Top wait events (samples x 10ms each) |
|----------|---------------------------------------|
| scalar-acquire | IO:BuffileWrite 2, IO:BuffileRead 1 - negligible |
| bulk-try-many | IO:BuffileWrite 22, IO:BuffileRead 4 - plpgsql tuplestore I/O |
| cleanup-commit | (empty - no measurable waits) |
| **concurrent-contention** | **LWLock:xclaim_partition 11**, IO:BuffileWrite 12, IO:BuffileRead 5 |

**Bottom line #1:** scalar / bulk / cleanup have no significant waits -
single-backend paths do not block. All CPU time is on-CPU work, and
the FlameGraph gives the full picture for those scenarios.

**Bottom line #2:** under the 10-backend concurrent overlap
workload, **real LWLock contention on `xclaim_partition` is
visible**. 11 samples x 10ms ~ 110ms cumulative
wait against a capacity of 10 backends x 15s = 150s - that is
~0.07% wait time. This is a share of the whole window: the load is
finite and may end before the window does, so the share of the
backends' actual running time is higher. Small in absolute terms,
but it is **direct evidence** that our partition lock IS a wait point
under contention.

The wait events do not tell which path waited: acquisition
(`try_many` holds the partition lock for HASH_ENTER_NULL) and the
COMMIT cleanup take locks of the same tranche, and a wait on either
shows up as `LWLock:xclaim_partition`. If the wait share grows on
larger workloads (N > 16 backends), consider partition-level
prefetching or finer-grained sharding.

The plpgsql tuplestore I/O (`IO:BuffileWrite/Read`) samples are a
workload artifact of the DO-block result set, not a pg_xclaim concern.

---

## Hot-path breakdown by scenario

CPU shares are percent of samples in the perf window (system-wide,
postgres process only). Each scenario is one DO block, that is, one
transaction per backend. In scalar, bulk and concurrent each iteration
runs in a `BEGIN ... RAISE EXCEPTION ... EXCEPTION END` subtransaction,
but its rollback does not release claims: they are held until the
transaction ends, and `xclaim_local_cleanup_held` releases them once,
at COMMIT. So in scalar and bulk only the first iteration acquires the
keys, and the rest (4 of 5 and 9 of 10) re-enter keys already held
through the fast path. In concurrent the claims of each backend also
accumulate over all 5 iterations, and with every iteration a growing
share of keys is already held by the backend itself or by other
backends.

### Scalar acquire - 5 iterations x 750k `xclaim.try`

-> [`flamegraphs/scalar-acquire.svg`](flamegraphs/scalar-acquire.svg)

| % | Function | Where time goes |
|--:|----------|-----------------|
| 35.9% | `xclaim_local_lookup_with_hash` | reentrancy fast-path simplehash lookup by a precomputed hash. In 4 of 5 iterations the key is already held and the call ends here |
| 11.1% | `hash_search_with_hash_value` | HASH_ENTER_NULL of the first iteration (one call covers lookup + insert) plus HASH_FIND + HASH_REMOVE of the COMMIT cleanup |
|  5.0% | `ExecInterpExpr` | PG executor expression interpreter (function-call dispatch) |
|  3.1% | `xclaim_local_cleanup_held` | COMMIT cleanup: the transaction callback releases all 750k claims once |
|  3.0% | `[libc.so.6]` | libc symbols without debug (memcpy/memset/strlen - install `libc6-dbg` to resolve) |
|  2.3% | `AllocSetFree` | pfree in the tuplestore and executor slot (`generate_series` rows) |
|  1.8% | `AllocSetAlloc` | palloc in the tuplestore and executor (in the SVG - under `tuplestore_gettupleslot` and `heap_form_minimal_tuple`) |
|  1.8% | `ExecMakeTableFunctionResult` | SRF dispatch for `generate_series` |
|  1.8% | `generate_series_step_int4` | generator step |
|  1.7% | `xclaim_try_internal` | self-time of the 12-step driver |
|  1.5% | `BufFileWrite` | tuplestore tuple write |
|  1.5% | `BufFileReadCommon` | tuplestore read (plpgsql DO block result) |
|  1.4% | `writetup_heap` | tuplestore tuple write |
|  1.4% | `heap_form_minimal_tuple` | tuple formation |
|  1.4% | `hash_bytes` | the key hash, one per call: `xclaim_compute_hash` (`get_hash_value` -> `tag_hash` -> `hash_bytes`) in Step 5, before the local-set lookup |

Where the time goes. Pure xclaim work dominates: 35.9% in
`xclaim_local_lookup_with_hash` - fast-path reentrancy lookup for
each of 750k keys x 5 iterations, and in 4 of the 5 iterations it
finds the key and ends the call. The key hash arrives precomputed:
`xclaim_try_internal` computes it beforehand (`xclaim_compute_hash`,
Step 5), and `hash_bytes` shows up in the profile as its own leaf
(1.4%).

Next biggest line item: `hash_search_with_hash_value` (11.1%). The
repeated iterations do not touch the shared hash: this covers the
750k HASH_ENTER_NULL calls of the first iteration plus the HASH_FIND
and HASH_REMOVE calls of the COMMIT cleanup.

`xclaim_local_cleanup_held` (3.1%) is the only cleanup in this
scenario: the subtransaction rollback via `RAISE EXCEPTION` does not
release claims, and all 750k entries are released in one pass at the
COMMIT of the DO block.

Kernel frames (`clear_page_rep`, `asm_exc_page_fault`) do not appear
in the scalar top-15: a 5-iteration loop over the same 750k keyspace
does not churn palloc pages, everything works inside a reused arena.
`LWLockRelease` is also not in the top 15: the partition lock is
cheap and does not dominate even under the scalar API.

### Bulk acquire - 10 iterations x 750k `xclaim.try_many`

-> [`flamegraphs/bulk-try-many.svg`](flamegraphs/bulk-try-many.svg)

| % | Function | Where time goes |
|--:|----------|-----------------|
| 11.7% | `xclaim_local_lookup_with_hash` | reentrancy check per slot by the hash computed while unpacking the array. In 9 of 10 iterations the key is already held |
|  5.1% | `[libc.so.6]` | libc symbols without debug. In the SVG the callers are mostly the tuplestore (`writetup_heap`, `tuplestore_gettuple`, `readtup_heap`) and `xclaim_try_many_pair` |
|  4.7% | `hash_search_with_hash_value` | HASH_ENTER_NULL of the first iteration under partition lock plus HASH_FIND + HASH_REMOVE of the COMMIT cleanup |
|  4.0% | `ExecInterpExpr` | PG executor (expressions around `unnest`/`generate_series`) |
|  3.5% | `AllocSetFree` | pfree in the tuplestore and executor slot |
|  2.7% | `xclaim_try_many_internal` | self-time of the bulk driver (between sub-calls) |
|  2.6% | `ExecMakeTableFunctionResult` | SRF dispatch for `unnest` results |
|  2.6% | `BufFileReadCommon` | tuplestore read (DO-block results) |
|  2.5% | `AllocSetAlloc` | palloc in the tuplestore and executor (in the SVG - under `heap_form_minimal_tuple` and `tuplestore_gettupleslot`) |
|  2.5% | `BufFileWrite` | tuplestore tuple write |
|  2.3% | `clear_page_rep` | kernel zero-fill for fresh palloc pages (rep stosq on x86_64) |
|  2.3% | `ExecStoreMinimalTuple` | output bool[] tuple assembly |
|  2.2% | `writetup_heap` | tuplestore tuple write |
|  2.2% | `AllocSetGetChunkSpace` | AllocSet chunk-size lookup (free-path helper) |
|  2.1% | `heap_form_minimal_tuple` | tuple formation |

Dominant user-space cost: `xclaim_local_lookup_with_hash` (11.7%) +
`hash_search_with_hash_value` (4.7%) + `xclaim_try_many_internal`
(2.7%) ~ 19% - pure xclaim work. The pre-sort by partition
(counting sort, O(N + num_partitions)) is too fast to surface as a
separate leaf. It's amortized across the per-key work and part of
it lands in `xclaim_try_many_internal` self-time.

`clear_page_rep` (2.3%) is kernel page-zero for fresh palloc
allocations. The bulk path allocates large arrays in each of the 10
iterations: `slots` alone is 750k x sizeof(XClaimBulkSlot) (40 bytes)
~ 29 MiB. The kernel gives zeroed pages on first touch, and that
surface area is visible here. The scalar path allocates no such
per-call arrays, so `clear_page_rep` is not in the top 15 there.

Bulk vs scalar: `xclaim_local_lookup_with_hash` is 11.7% in bulk vs
35.9% in scalar - shares of two profiles with different work, which
do not compare the cost per key. The time comparison comes from the
Mac run: 378 ms for scalar and 288 ms for bulk on 750k keys.

### Cleanup callback - one transaction: 50 x 50k acquire, then COMMIT

-> [`flamegraphs/cleanup-commit.svg`](flamegraphs/cleanup-commit.svg)

| % | Function | Where time goes |
|--:|----------|-----------------|
| 25.9% | `hash_search_with_hash_value` | HASH_FIND + HASH_REMOVE in cleanup loop + HASH_ENTER_NULL during acquire (dominates because cleanup walks all 2.5M entries) |
| 20.0% | `xclaim_local_lookup_with_hash` | reentrancy lookup in the acquire phase, one for each of the 2.5M keys. The cleanup walks the local set with the simplehash iterator, which is not counted here |
|  6.6% | `xclaim_local_cleanup_held` | self-time of the group-by-partition cleanup driver (gather + sort + per-partition sweep) |
|  2.7% | `xclaim_local_insert_held` | local-set insert after successful shared insert |
|  2.7% | `ExecInterpExpr` | executor expression dispatch |
|  2.4% | `xclaim_try_many_internal` | self-time of the bulk driver |
|  2.1% | `[libc.so.6]` | libc symbols without debug |
|  1.9% | `ExecMakeTableFunctionResult` | SRF dispatch |
|  1.6% | `hash_bytes` | hashes of the acquire phase: `xclaim_compute_hash` per element while unpacking the array, and simplehash recomputing hashes on local-set inserts and growth. The cleanup computes no hashes |
|  1.5% | `clear_page_rep` | kernel zero-fill for fresh palloc pages |
|  1.2% | `heap_form_minimal_tuple` | tuple formation |
|  1.1% | `tts_minimal_getsomeattrs` | tuple slot deformation |
|  1.1% | `asm_exc_page_fault` | kernel page-fault entry (assembly stub) |
|  1.1% | `tuplestore_gettuple` | tuplestore tuple read |
|  1.1% | `AllocSetFree` | palloc cleanup |

The cleanup scenario is the only one where
`hash_search_with_hash_value` dominates at 25.9%. That's expected:
the whole scenario is one transaction without subtransactions. Its
50 `try_many` calls, 50k fresh keys each, accumulate 2.5M claims
(2.5M HASH_ENTER_NULL calls), and the cleanup callback at COMMIT walks
all 2.5M entries once, calling HASH_FIND and HASH_REMOVE for each.
Counting sort + group-by-partition (see `xclaim_local_cleanup_held`
6.6%) keeps the number of LWLock cycles bounded by `num_partitions`
(128 at default), but per-key HASH_REMOVE doesn't go away - it's
the fundamental cost of freeing N entries.

`xclaim_local_lookup_with_hash` (20.0%) is the acquire phase only:
the reentrancy check for each of the 2.5M keys, and every one of them
misses because the keys are fresh. The cleanup walks the local set
with the simplehash iterator in `xclaim_local_gather_pointers`, not
through this function: in the SVG `xclaim_local_lookup_with_hash`
never appears under `xclaim_local_cleanup_held`.

Kernel page-zero (`clear_page_rep` 1.5% + `asm_exc_page_fault`
1.1% = 2.6%) is visible in the cleanup scenario: the transaction
makes many large allocations, and the kernel zeroes their fresh pages
on first touch. The largest is the local set: the simplehash bucket
array is created for `pg_xclaim.expected_claims_per_backend` (1048576
in the profile recording scripts, which is 96 MiB) and doubles at
least once on the way to 2.5M entries. On top of it come the working
arrays of every `try_many` call for its 50k keys and the cleanup's
pointer arrays for all 2.5M entries. `LWLockRelease` is not in the
top 15 - the lock/unlock cost bounded by `num_partitions=128` is
cheap relative to hash and memory-mapping work.

### Concurrent contention - 10 backends x 5 iterations x 100k overlapping

-> [`flamegraphs/concurrent-contention.svg`](flamegraphs/concurrent-contention.svg)

| % | Function | Where time goes |
|--:|----------|-----------------|
| 14.6% | `hash_search_with_hash_value` | shared dynahash under contention. One combined HASH_ENTER_NULL covers FIND-or-INSERT |
|  ~4.2% | `xclaim_is_stale_owner` | **stale-owner check under conflict - the defining difference from single-backend.** (inclusive width from the published SVG.) 10 backends keep colliding on the same keys in the overlap pool, and the loser walks the stale-owner check every time |
|  5.6% | `xclaim_try_many_internal` | self-time of the bulk driver (between sub-calls, and the conflict path costs more due to extra branches) |
|  5.4% | `[libc.so.6]` | libc symbols without debug. In the SVG the callers are the COMMIT path (`CommitTransaction`), the tuplestore, `xclaim_local_init` and `xclaim_try_many_pair` |
|  4.7% | `xclaim_local_lookup_with_hash` | reentrancy lookup over 100k x 5 iters x 10 backends = 5M calls |
|  3.8% | `ExecInterpExpr` | PG executor (dispatch of `unnest`/`xclaim.try_many`/`random`) |
|  2.6% | `xclaim_local_cleanup_held` | COMMIT cleanup: once per backend, over all claims accumulated in 5 iterations |
|  1.9% | `clear_page_rep` | kernel page-zero of fresh pages. In the SVG about half of it is the first touch of the local-set array, which every backend creates zeroed (96 MiB) |
|  1.8% | `AllocSetAlloc` | palloc in the tuplestore and executor (in the SVG - under `tuplestore_gettupleslot` and `heap_form_minimal_tuple`) |
|  1.8% | `AllocSetFree` | pfree in the tuplestore and executor slot |
|  1.7% | `BufFileReadCommon` | tuplestore read |
|  1.6% | `ExecMakeTableFunctionResult` | SRF dispatch |
|  1.5% | `ExecScan` | scan of tuplestore result |
|  1.2% | `tuplestore_puttuple_common` | tuple write to tuplestore |
|  1.2% | `native_queued_spin_lock_slowpath` | **kernel mm LRU vector lock** - `folio_lruvec_lock_irqsave` when a fresh page is added to the LRU after a page fault. In the SVG most of these frames come from zeroing the local set, which 10 backends do at the same time. This is a kernel spinlock, not a pg_xclaim LWLock. |

Under the 10-backend overlapping workload the picture shifts:
`hash_search_with_hash_value` jumps to 14.6%. There are fewer
distinct keys here than in the other scenarios: all 10 backends draw
them at random from a 200k pool (`pool_size = 200000`), while scalar
and bulk work with 750k keys and cleanup with 2.5M.

**`xclaim_is_stale_owner` rises to ~4%** (inclusive width from the
published flamegraph) - this is the lazy-reaper path. When two
backends race for the same key in the overlap pool, the loser checks
whether the entry is held by an already-dead owner
(procno -> owner's PGPROC -> pid and owner_token check). Under high-overlap workloads
this happens often and surfaces as its own leaf. **Architecturally
that means the lazy reaper carries real load under contention - it
is not a "free fallback" but an active path.** If at larger
workloads (N > 16, K > 200k) this percentage keeps growing, a
batched-validation or background sweeper would be worth considering.

Kernel page-zero (`clear_page_rep` 1.9%, while `asm_exc_page_fault` falls
below the top-15 floor of 1.2% and so is not listed as its own row)
comes mostly from the local set: on its first call each of the 10
backends creates a simplehash bucket array of 2^21 x 48 bytes =
96 MiB (`expected_claims_per_backend = 1048576` in the profile
recording scripts), and simplehash allocates it with
`MCXT_ALLOC_ZERO`. In the SVG more than half of `asm_exc_page_fault`
sits under `xclaim_local_init`, and the rest is shared by the
`try_many` working arrays, `hash_search_with_hash_value` and the
tuplestore.

Atomic ops (`__atomic_*`, on x86_64 these are `lock add`/`cmpxchg`)
are inlined and have no frames of their own in the flamegraph: their
cost sits inside the frames of the calling functions, and the profile
cannot measure it separately. The stat counters are per-backend: each
backend writes its own slot `XClaimBackendInfos[procno]`, not a shared
counter.

---

## Where time goes - by category

| Category | Scalar | Bulk | Cleanup | Contention | What it is |
|----------|-------:|-----:|--------:|-----------:|------------|
| **Local simplehash** (`xclaim_local_lookup_with_hash`, `xclaim_local_insert_held`, `xclaim_local_cleanup_held`) | ~39% | ~12% | ~29% | ~7% | reentrancy fast-path + local-set insert + group-by-partition cleanup. The key hash is not here: `hash_bytes` is counted in the shared dynahash row |
| **Shared dynahash** (`hash_search_with_hash_value` + `hash_bytes`) | ~12.5% | ~5% | ~28% | ~16% | partitioned shared hash under partition LWLock |
| **PG executor / plpgsql** (`ExecInterpExpr`, tuplestore, SRF dispatch) | - | - | - | - | function-call dispatch, FOR-loop machinery, tuplestore I/O. The category is open-ended, and its share cannot be recovered from the published profiles |
| **xclaim driver self-time** (`xclaim_try_internal`, `xclaim_try_many_internal`, `xclaim_is_stale_owner`) | ~2% | ~3% | ~3% | **~10%** | self-time + stale-owner reaper (the latter spikes under contention) |
| **Memory alloc** (`AllocSetAlloc`, `AllocSetFree`, `AllocSetGetChunkSpace`) | ~4% | ~8% | ~1% | ~4% | palloc/pfree of the tuplestore and executor. Local-set entries live in the simplehash bucket array, with no palloc per entry |
| **Kernel page-zero + faults** (`clear_page_rep`, `asm_exc_page_fault`) | <1% | ~2% | ~3% | ~3% | first-touch zero-fill on fresh palloc pages + page-fault entry |
| **libc opaque** (`[libc.so.6]`) | ~3% | ~5% | ~2% | ~5% | memcpy/memset/strlen - install `libc6-dbg` to resolve |
| **Atomic counters** (`__atomic_*`) | - | - | - | - | per-backend stat slots + live_capacity. On x86_64 these are inline `lock`-prefixed instructions inside the calling functions: no frames of their own, so the profile gives no share for them |
| **LWLock acquire/release** | not in top 15 | not in top 15 | not in top 15 | not in top 15 | partition lock cycles (<= num_partitions=128). `LWLockAcquire` and `LWLockRelease` are not in the top 15, so each is at most the 15th row of the scenario table: 1.4% in scalar, 2.1% in bulk, 1.1% in cleanup, 1.2% in concurrent |

---

## Architectural validation

The profile confirms three core promises and cannot check item 2:

1. **LWLock cycles are bounded by `num_partitions`, not by entry
   count.** `LWLockRelease` does not appear in the top 15 of any of
   the four scenarios, so it is at most the 15th row of each table:
   1.4% in scalar, 2.1% in bulk, 1.1% in cleanup, 1.2% in concurrent.
   That is a lower bound on the group-cleanup cost: the 2.5M entries
   of the cleanup scenario pass through <= 128 LWLock cycles (default
   `num_partitions`), not 2.5M. The group-by-partition cleanup
   invariant holds - confirmed directly with resolved pg_xclaim
   symbols.

2. **The profile does not show the atomic counters.** The
   `__atomic_*` operations (the x86_64 lock prefix) are inlined into
   the calling functions, their cost sits inside the callers' frames,
   and their absence from the top 15 says nothing about it. The stat
   counters are per-backend (`XClaimBackendInfos[procno]`): each
   backend writes its own cache line. Shared counters on a single
   cache line would ping-pong between sockets under concurrent
   writes, and per-backend slots avoid that by design.

3. **`hash_search_with_hash_value` stays the proportional principal
   shared-hash cost.** 5-27% in acquire-heavy and cleanup scenarios,
   with no unexpected collision storms or long chain walks. In the
   cleanup scenario its share rises to 25.9% precisely because the
   cleanup walks every entry (2.5M HASH_REMOVE in one transaction),
   but that's the baseline cost - not a pathological contention
   pattern.

4. **The key hash is computed once per key, and the cleanup computes
   none.** `xclaim_compute_hash` (`get_hash_value` -> `tag_hash` ->
   `hash_bytes`) runs before the reentrancy check: on the scalar path
   as Step 5 of `xclaim_try_internal`, on the bulk path while
   `xclaim_try_many_solo`/`xclaim_try_many_pair` unpack the array.
   The same `hashvalue` feeds the local-set lookup,
   `hash_search_with_hash_value` and the local-set insert, and the
   cleanup reads the `hashvalue` saved in each local-set entry.
   Besides that, simplehash itself calls `hash_bytes` in the profiled
   build, where `SH_STORE_HASH` is not defined: an insert recomputes
   the hashes of the entries in the occupied buckets it passes while
   looking for a slot, and a grow recomputes the hashes of all
   entries. The current code defines `SH_STORE_HASH`: the hash lives in
   the entry and simplehash does not recompute it. In the profile
   `hash_bytes` is a leaf of its own: 1.4% in scalar, 1.6% in cleanup,
   and below the top-15 floor (2.1%) in bulk. No SVG shows it under
   `xclaim_local_cleanup_held`.

---

## Bench results on macOS PG 17.10 / Apple M-series

The platform here is a macOS dev box, not the Linux/x86_64 from the
"Profile setup" table above. That's intentional: `perf` flamegraphs
are only available on Linux, while the latency budgets are gated on
the same machine where day-to-day development happens. These numbers
are for regression control, not for direct comparison with the Linux
profile.

| Workload | Latency | Budget | Headroom |
|----------|--------:|-------:|---------:|
| 750k single-backend scalar `xclaim.try` | 378 ms | 2000 ms | 5.3x |
| 750k bulk `xclaim.try_many` | 288 ms | 500 ms | 1.74x |
| 50k acquire+COMMIT (group-by-partition cleanup) | <100 ms | 100 ms | gated by `test/concurrency/grouped_cleanup_50k.sh` |
| 10 backends x 100k disjoint (1M total) | sub-second wall | - | no threshold: `test/concurrency/stress_10x100k.sh` records the time with PASS |

`pg_locks.advisory` count is **0** for migrated paths - confirming the
extension runs without LockManager entries on those specific paths in
this synthetic workload. This is a property of the extension, not a
universal claim about advisory locks. For most workloads the standard
LockManager is the right tool (see README §Alternatives).

---

## Reproduction

```bash
# Linux x86_64 (Ubuntu 24.04 / PGDG):
sudo apt-get install -y postgresql-17 postgresql-server-dev-17 \
                        postgresql-17-dbgsym \
                        linux-tools-generic build-essential
sudo git clone https://github.com/brendangregg/FlameGraph /opt/FlameGraph

# Build pg_xclaim with frame pointers + debug info
PG=/usr/lib/postgresql/17/bin/pg_config
PG_CFLAGS="-O2 -g -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer" \
  make PG_CONFIG=$PG -j"$(nproc)"
sudo make PG_CONFIG=$PG install

# Record all four scenarios in one shot (as root, initdb/pg_ctl/psql
# are delegated to the `postgres` OS user via `runuser`):
sudo scripts/record_flamegraphs.sh

# SVGs land in docs/perf/flamegraphs/, top-15 leaves per scenario
# print to stdout.
```

`scripts/record_flamegraphs.sh` sets
`kernel.kptr_restrict=0` and `kernel.perf_event_paranoid=-1` for
the duration of the run and restores the originals on exit. Under
the hood it runs the equivalent of `perf record -F 997 -g -a` over
a 12-second window per scenario (15 seconds for concurrent), drives
the workload via `psql -h /tmp -p <port> ...`, and emits an SVG via
`/opt/FlameGraph/stackcollapse-perf.pl | flamegraph.pl`.

The published data was recorded with `pg_wait_sampling` loaded: the
SVGs contain `[pg_wait_sampling.so]` and `pgws_collector_main` frames,
and only `scripts/record_perf_evidence.sh` writes `perf-stat/` and
`wait-events/`. It runs the same four scenarios, but loads
`pg_xclaim,pg_wait_sampling` (the `postgresql-17-pg-wait-sampling`
package is required) and runs every scenario twice: the first run
writes the SVG and the wait events, the second one `perf stat`.
`record_flamegraphs.sh` loads only `pg_xclaim` and writes only SVGs.

`postgresql-17-dbgsym` installs debug-info to
`/usr/lib/debug/.build-id/...`, where `perf` finds the file by Build-ID
automatically. Without that package, all PG core functions will
collapse into the opaque `[postgres]` leaf and the top-15 will only
be informative for pg_xclaim symbols. For source-level kernel
symbols additionally install `linux-image-$(uname -r)-dbgsym` from
the ubuntu ddebs repo - without it kernel frames carry only function
names (via kallsyms), not file/line.

---

## How to read the SVGs

Each block in the flamegraph is a function on the call stack:
- **Width** = percent of total CPU time (samples)
- **Y axis (vertical)** = call depth (root at the bottom)
- **Colors** = visual differentiation only (no semantic meaning under `--colors hot`)
- **Click to zoom**, **Reset Zoom** to go back, **Search** for a substring across all stacks

Things to look for in `xclaim.try` flamegraphs:
- Wide `xclaim_local_lookup_with_hash` blocks near the top -> reentrancy fast-path dominance (the hash arrives precomputed, `hash_bytes` is a separate block)
- Blocks above `LWLockAcquire`/`LWLockRelease` -> critical-section hot leaves
- `[postgres]` blocks -> PG core (executor, planner, function-call dispatch)
- Anything inside the kernel (`__x64_sys_*`, `do_*`, `entry_*`) -> syscalls / page-fault handlers
