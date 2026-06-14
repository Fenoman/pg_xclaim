# Hot-path analysis

> **Русская версия:** [`hot-path-analysis.md`](hot-path-analysis.md).

Where `pg_xclaim` spends CPU and why. This document is for anyone
curious — see how the overhead breaks down without spinning up your
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
| Build | gcc 13.3 (`/usr/bin/gcc`); pg_xclaim built with `PG_CFLAGS='-O2 -g -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer'`. `pg_xclaim.so` carries debug-info inline (`with debug_info, not stripped`). |
| Profiler | `perf record -F 997 -g -a` (system-wide CPU sampling), perf 6.8.12 |
| Window | 12 seconds for single-backend scenarios, 15 seconds for concurrent; workloads loop to fully cover the window |
| Stack unwind | DWARF + frame pointers |
| Symbol resolution | **Each layer resolves through its own source:** kernel symbols via `kallsyms`, PG core via dbgsym Build-ID debug-info (`/usr/lib/debug/.build-id/...`), and pg_xclaim via its own inline DWARF in `pg_xclaim.so`. The top-15 leaves below name real functions (`xclaim_local_lookup_with_hash`, `hash_search_with_hash_value`, `clear_page_rep`, `asm_exc_page_fault`). The `[libc.so.6]` bucket (~2-5%) is libc memcpy/memset/strlen without `libc6-dbg` — not critical for user-space hot-path interpretation. Requires `sysctl kernel.kptr_restrict=0` and running `perf record` as root (initdb/pg_ctl/psql delegated to the postgres user via `runuser`); without that, kernel symbols collapse into an `[unknown]` bucket. |

---

## Architectural call chain

A typical `xclaim.try(int4, int4)` in a single backend:

```
PostgresMain
└── exec_simple_query
    └── PortalRun → ExecutorRun
        └── ExecResult → ExecEvalFuncArgs
            └── FunctionCall (V1 trampoline)
                ├── xclaim_try_pair             [SQL entry]
                │   ├── XCLAIM_REQUIRE_INIT     [recovery + preload gate]
                │   ├── memset(&key, 0, sizeof(XClaimKey))   [HASH_BLOBS req]
                │   └── xclaim_try_internal     [12-step algorithm]
                │       ├── xclaim_ensure_owner_token        [lazy, once per backend]
                │       ├── xclaim_local_lookup_with_hash    [reentrancy fast-path]
                │       │   └── xcl_local_lookup_hash (simplehash, hash is passed, not recomputed)
                │       │       └── memcmp (16-byte key)
                │       ├── xclaim_compute_hash             [shared-key hash]
                │       ├── xclaim_partition_lock           [hashvalue & mask]
                │       ├── LWLockAcquire(plock, EXCLUSIVE) ─┐
                │       ├── hash_search_with_hash_value     │ critical
                │       │   (HASH_ENTER_NULL — combined     │ section
                │       │    lookup-or-insert; *found       │
                │       │    distinguishes existing vs      │
                │       │    fresh; NULL on capacity)       │
                │       ├── [if found && !matches_self]     │
                │       │       xclaim_is_stale_owner       │
                │       │   └── xclaim_get_pgproc_by_procno │
                │       │       └── GetPGProcByNumber       [PG core macro;
                │       │                                    storage/proc.h]
                │       ├── populate XClaimEntry owner      │
                │       │   triple (procno+lxid+token)      │ — writes fresh
                │       │                                   │   slot OR
                │       │                                   │   overwrites a
                │       │                                   │   stale-reap'd
                │       │                                   │   slot in place
                │       ├── PG_TRY {                        │
                │       │   xclaim_local_insert_held }      │
                │       └── LWLockRelease(plock)            ─┘
                │       ├── pg_atomic_fetch_add_u64(live_capacity)
                │       ├── pg_atomic_fetch_add_u64(per-backend total_acquires_local)
                │       └── xclaim_check_capacity_watermark
                │           └── pg_atomic_read_u64(live_capacity)
```

Cleanup on COMMIT/ABORT:

```
CommitTransactionCommand / AbortTransaction
└── CallXactCallbacks(XACT_EVENT_COMMIT | _ABORT)
    └── xclaim_xact_callback
        └── xclaim_local_cleanup_held
            ├── xclaim_local_gather_pointers     [O(N) walk simplehash]
            ├── counting sort by partition_id    [O(N + num_partitions)]
            └── for each partition (≤ num_partitions cycles):
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
the code CPU-bound, memory-bound, or branch-bound?". This changes the
optimization direction.

Raw data: [`perf-stat/<scenario>.txt`](perf-stat/) (system-wide
`perf stat -e cycles,instructions,cache-references,cache-misses,
LLC-load-misses,LLC-store-misses,branch-instructions,branch-misses,
page-faults,context-switches,cpu-migrations`).

| Scenario | cycles | instructions | IPC | cache-miss% | branch-miss% | page-faults | ctx-sw |
|----------|------:|-------------:|----:|------------:|-------------:|------------:|-------:|
| scalar-acquire | 20.7G | 13.1G | **0.63** | 39.31% | 5.84% | 117K | 86K |
| bulk-try-many | 29.3G | 33.1G | 1.13 | 33.97% | 2.90% | 264K | 77K |
| cleanup-commit | 24.0G | 14.8G | **0.62** | 37.51% | 6.03% | 229K | 89K |
| concurrent-contention | 39.1G | 29.4G | 0.75 | 32.38% | 4.55% | 527K | 104K |

**Bottom line: pg_xclaim is memory-bound on this hardware (AMD EPYC).**
All four scenarios show IPC < 1.13 with cache-miss rate > 32%. The
CPU spends more cycles waiting on cache misses than executing
instructions.

What this means for optimization:
- **Algorithmic micro-tweaks (loop unrolling, branchless code) won't
  help much** — we are stalled on memory, not ALU.
- **Cache-line layout, prefetching, working-set reduction** — the
  right optimization direction for the memory-bound hot path.
- **scalar 750k: 378 ms / bulk 750k: 288 ms on Mac M-series PG 17.10.**
  One cache miss per dynahash bucket walk is the dominant cost on this
  hardware. The combined single HASH_ENTER_NULL per acquire (covering
  both lookup and insert) is a direct response to this memory-bound
  profile — one bucket walk per acquire, not two.

The bulk scenario has the highest IPC (1.13): a tight loop over 750k
slots without plpgsql harness between iterations, branch predictor
hits hard (2.90% miss rate). This explains why the bulk API delivers
the ~2.5x relative win over scalar.

The cleanup scenario has the highest branch-miss rate (6.03%):
HASH_REMOVE walks heterogeneous keys with unpredictable chain
traversals. Fundamentally hard to accelerate without changing the
dynahash API.

`LLC-load-misses` shows `<not supported>` — on the test AMD EPYC the
Linux perf subsystem does not enumerate the LLC perf event; the
general `cache-misses` counter covers the same memory-pressure
analysis.

---

## Off-CPU wait evidence (`pg_wait_sampling`)

FlameGraph sees ON-CPU samples — a backend blocked on an LWLock or IO
is **invisible** there. `pg_wait_sampling` samples
`pg_stat_activity.wait_event` every 10ms, providing wait attribution
that complements the FlameGraph.

Raw data: [`wait-events/<scenario>.csv`](wait-events/) (filter:
`event_type NOT IN ('Activity', 'Client', 'Timeout', 'Extension')` —
excludes idle background workers and clients parked on ClientRead).

| Scenario | Top wait events (samples × 10ms each) |
|----------|---------------------------------------|
| scalar-acquire | IO:BuffileWrite 2, IO:BuffileRead 1 — negligible |
| bulk-try-many | IO:BuffileWrite 22, IO:BuffileRead 4 — plpgsql tuplestore I/O |
| cleanup-commit | (empty — no measurable waits) |
| **concurrent-contention** | **LWLock:xclaim_partition 11**, IO:BuffileWrite 12, IO:BuffileRead 5 |

**Bottom line #1:** scalar / bulk / cleanup have no significant waits —
single-backend paths do not block. All CPU time is on-CPU work, and
the FlameGraph gives the full picture for those scenarios.

**Bottom line #2 (new):** under the 10-backend concurrent overlap
workload, **real LWLock contention on `xclaim_partition` is
visible for the first time**. 11 samples × 10ms ≈ 110ms cumulative
wait against a capacity of 10 backends × 15s = 150s — that is
~0.07% wait time. Small in absolute terms, but **the first direct
evidence** that our partition lock IS a wait point under contention.

This validates the architectural choice:
- group-by-partition cleanup (≤ `num_partitions=128` lock/unlock
  cycles) holds wait time well under 0.1% as designed;
- if this share grows on larger workloads (N > 16 backends), consider
  partition-level prefetching or finer-grained sharding.

The plpgsql tuplestore I/O (`IO:BuffileWrite/Read`) samples are a
workload artifact of the DO-block result set, not a pg_xclaim concern.

---

## Hot-path breakdown by scenario

CPU shares are percent of samples in the perf window (system-wide;
postgres process only). Workloads run inside an outer transaction with
per-iteration `BEGIN ... RAISE EXCEPTION ... EXCEPTION END` subtxn
blocks for controlled state release.

### Scalar acquire — 5 iterations × 750k `xclaim.try` (subtxn release)

→ [`flamegraphs/scalar-acquire.svg`](flamegraphs/scalar-acquire.svg)

| % | Function | Where time goes |
|--:|----------|-----------------|
| 35.9% | `xclaim_local_lookup_with_hash` | reentrancy fast-path simplehash lookup; `hash_bytes` is inlined into this function |
| 11.1% | `hash_search_with_hash_value` | single combined HASH_ENTER_NULL under partition lock covers lookup + insert |
|  5.0% | `ExecInterpExpr` | PG executor expression interpreter (function-call dispatch) |
|  3.1% | `xclaim_local_cleanup_held` | subxact rollback caller — clears local-set entries not committed by the subtxn |
|  3.0% | `[libc.so.6]` | libc symbols without debug (memcpy/memset/strlen — install `libc6-dbg` to resolve) |
|  2.3% | `AllocSetFree` | pfree in end-of-iteration cleanup |
|  1.8% | `AllocSetAlloc` | palloc for local-set entries |
|  1.8% | `ExecMakeTableFunctionResult` | SRF dispatch for `generate_series` |
|  1.8% | `generate_series_step_int4` | generator step |
|  1.7% | `xclaim_try_internal` | self-time of the 12-step driver |
|  1.5% | `BufFileWrite` | tuplestore tuple write |
|  1.5% | `BufFileReadCommon` | tuplestore read (plpgsql DO block result) |
|  1.4% | `writetup_heap` | tuplestore tuple write |
|  1.4% | `heap_form_minimal_tuple` | tuple formation |
|  1.4% | `hash_bytes` | standalone hash computation only in cleanup path; acquire paths inline hash via `xclaim_local_lookup_with_hash` |

Where the time goes. Pure xclaim work dominates: 35.9% in
`xclaim_local_lookup_with_hash` — fast-path reentrancy lookup for
each of 750k keys × 5 iterations. `hash_bytes` is computed inside
this call, so a standalone `hash_bytes` frame is only visible in the
cleanup path (~1.4% there).

Next biggest line item: `hash_search_with_hash_value` (11.1%) —
HASH_ENTER in the shared dynahash under the partition LWLock. This
is the baseline cost of a shared-state lookup per key.

`xclaim_local_cleanup_held` (3.1%) shows up here because each
subtxn-rollback iteration via `RAISE EXCEPTION` invalidates local-set
entries and they get swept — that's not a bug, it's the workload's
natural behavior.

Kernel frames (`clear_page_rep`, `asm_exc_page_fault`) do not appear
in the scalar top-15: a 5-iteration loop over the same 750k keyspace
does not churn palloc pages, everything works inside a reused arena.
`LWLockRelease` is also not in the top 15: the partition lock is
cheap and does not dominate even under the scalar API.

### Bulk acquire — 10 iterations × 750k `xclaim.try_many`

→ [`flamegraphs/bulk-try-many.svg`](flamegraphs/bulk-try-many.svg)

| % | Function | Where time goes |
|--:|----------|-----------------|
| 11.7% | `xclaim_local_lookup_with_hash` | reentrancy check per slot + inline `hash_bytes` |
|  5.1% | `[libc.so.6]` | libc symbols without debug (memcpy/memset around construct_md_array) |
|  4.7% | `hash_search_with_hash_value` | shared dynahash HASH_ENTER under partition lock |
|  4.0% | `ExecInterpExpr` | PG executor (expressions around `unnest`/`generate_series`) |
|  3.5% | `AllocSetFree` | per-batch palloc free chain |
|  2.7% | `xclaim_try_many_internal` | self-time of the bulk driver (between sub-calls) |
|  2.6% | `ExecMakeTableFunctionResult` | SRF dispatch for `unnest` results |
|  2.6% | `BufFileReadCommon` | tuplestore read (DO-block results) |
|  2.5% | `AllocSetAlloc` | palloc for local-set entries + bulk slots array |
|  2.5% | `BufFileWrite` | tuplestore tuple write |
|  2.3% | `clear_page_rep` | kernel zero-fill for fresh palloc pages (rep stosq on x86_64) |
|  2.3% | `ExecStoreMinimalTuple` | output bool[] tuple assembly |
|  2.2% | `writetup_heap` | tuplestore tuple write |
|  2.2% | `AllocSetGetChunkSpace` | AllocSet chunk-size lookup (free-path helper) |
|  2.1% | `heap_form_minimal_tuple` | tuple formation |

Dominant user-space cost: `xclaim_local_lookup_with_hash` (11.7%) +
`hash_search_with_hash_value` (4.7%) + `xclaim_try_many_internal`
(2.7%) ≈ 19% — pure xclaim work. The pre-sort by partition
(counting sort, O(N + num_partitions)) is too fast to surface as a
separate leaf; it's amortized across the per-key work and part of
it lands in `xclaim_try_many_internal` self-time.

`clear_page_rep` (2.3%) is kernel page-zero for fresh palloc
allocations. The bulk path allocates large arrays (750k slots ×
sizeof(XClaimBulkSlot) ≈ 25 MiB) per each of 10 iterations; the
kernel gives zeroed pages on first touch, and that surface area is
visible here. On the scalar path those pages are reused across
iterations (one iterative buffer), so `clear_page_rep` is not in
the top 15 there.

Bulk vs scalar: `xclaim_local_lookup_with_hash` is 11.7% in bulk vs
35.9% in scalar — ~3.1× lower share — because the PG executor /
plpgsql harness cost is amortized across 750k keys within one SQL
call, not across N iterations of a plpgsql FOR loop. That's exactly
the saving the bulk API was built for.

### Cleanup callback — 50 transactions × 50k acquire+COMMIT

→ [`flamegraphs/cleanup-commit.svg`](flamegraphs/cleanup-commit.svg)

| % | Function | Where time goes |
|--:|----------|-----------------|
| 25.9% | `hash_search_with_hash_value` | HASH_REMOVE in cleanup loop + HASH_ENTER during acquire (dominates because cleanup walks every entry) |
| 20.0% | `xclaim_local_lookup_with_hash` | reentrancy lookup in acquire phase + walk over local-set in cleanup |
|  6.6% | `xclaim_local_cleanup_held` | self-time of the group-by-partition cleanup driver (gather + sort + per-partition sweep) |
|  2.7% | `xclaim_local_insert_held` | local-set insert after successful shared insert |
|  2.7% | `ExecInterpExpr` | executor expression dispatch |
|  2.4% | `xclaim_try_many_internal` | self-time of the bulk driver |
|  2.1% | `[libc.so.6]` | libc symbols without debug |
|  1.9% | `ExecMakeTableFunctionResult` | SRF dispatch |
|  1.6% | `hash_bytes` | standalone hash computation in the cleanup path (acquire paths inline hash into `xclaim_local_lookup_with_hash`) |
|  1.5% | `clear_page_rep` | kernel zero-fill for fresh palloc pages |
|  1.2% | `heap_form_minimal_tuple` | tuple formation |
|  1.1% | `tts_minimal_getsomeattrs` | tuple slot deformation |
|  1.1% | `asm_exc_page_fault` | kernel page-fault entry (assembly stub) |
|  1.1% | `tuplestore_gettuple` | tuplestore tuple read |
|  1.1% | `AllocSetFree` | palloc cleanup |

The cleanup scenario is the only one where
`hash_search_with_hash_value` dominates at 25.9%. That's expected:
the cleanup callback calls HASH_REMOVE on every one of 50k entries
per transaction × 50 transactions = 2.5M dynahash operations.
Counting sort + group-by-partition (see `xclaim_local_cleanup_held`
6.6%) keeps the number of LWLock cycles bounded by `num_partitions`
(128 at default), but per-key HASH_REMOVE doesn't go away — it's
the fundamental cost of freeing N entries.

`xclaim_local_lookup_with_hash` (20.0%) covers both the acquire
fast-path (for 50k acquires per transaction) and the walk over the
local-set during cleanup (`gather pointers` is inlined into this
function).

Kernel page-zero (`clear_page_rep` 1.5% + `asm_exc_page_fault`
1.1% = 2.6%) is visible in the cleanup scenario: each transaction
allocates 50k entries in TopMemoryContext, and some of the pages
have to be zeroed on first touch. `LWLockRelease` is not in the
top 15 — the lock/unlock cost bounded by `num_partitions=128` is
cheap relative to hash and memory-mapping work.

### Concurrent contention — 10 backends × 5 iterations × 100k overlapping

→ [`flamegraphs/concurrent-contention.svg`](flamegraphs/concurrent-contention.svg)

| % | Function | Where time goes |
|--:|----------|-----------------|
| 14.6% | `hash_search_with_hash_value` | shared dynahash under contention; one combined HASH_ENTER_NULL covers FIND-or-INSERT |
|  ~4.2% | `xclaim_is_stale_owner` | **stale-owner check under conflict — the defining difference from single-backend.** (inclusive width from the published SVG.) 10 backends keep colliding on the same keys in the overlap pool, and the loser walks the stale-owner check every time |
|  5.6% | `xclaim_try_many_internal` | self-time of the bulk driver (between sub-calls; conflict path costs more due to extra branches) |
|  5.4% | `[libc.so.6]` | libc symbols (memcpy + bytecode for random()) |
|  4.7% | `xclaim_local_lookup_with_hash` | reentrancy lookup over 100k × 5 iters × 10 backends = 5M calls |
|  3.8% | `ExecInterpExpr` | PG executor (dispatch of `unnest`/`xclaim.try_many`/`random`) |
|  2.6% | `xclaim_local_cleanup_held` | subxact rollback cleanup per iteration |
|  1.9% | `clear_page_rep` | kernel page-zero — palloc churn is worse on 10 backends than single |
|  1.8% | `AllocSetAlloc` | palloc for local-set entries |
|  1.8% | `AllocSetFree` | pfree after a batch |
|  1.7% | `BufFileReadCommon` | tuplestore read |
|  1.6% | `ExecMakeTableFunctionResult` | SRF dispatch |
|  1.5% | `ExecScan` | scan of tuplestore result |
|  1.2% | `tuplestore_puttuple_common` | tuple write to tuplestore |
|  1.2% | `native_queued_spin_lock_slowpath` | **kernel mm LRU vector lock** — `folio_lruvec_lock_irqsave` under heavy palloc churn from 10 backends. This is a workload-induced kernel cost (random() + per-iteration palloc), not pg_xclaim LWLock. |

Under the 10-backend overlapping workload the picture shifts:
`hash_search_with_hash_value` jumps to 14.6% because every
HASH_ENTER into the shared dynahash under a partition LWLock now
contends with 9 other backends, hash-chain walks get longer due to
higher occupancy, and some of the time is spent spinning inside
`LWLockAcquire`.

**`xclaim_is_stale_owner` rises to ~4%** (inclusive width from the
published flamegraph) — this is the lazy-reaper path. When two
backends race for the same key in the overlap pool, the loser checks
whether the entry is held by an already-dead owner
(procno → MyProc → live xact check). Under high-overlap workloads
this happens often and surfaces as its own leaf. **Architecturally
that means the lazy reaper carries real load under contention — it
is not a "free fallback" but an active path.** If at larger
workloads (N > 16, K > 200k) this percentage keeps growing, a
batched-validation or background sweeper would be worth considering.

Kernel page-zero (`clear_page_rep` 1.9%; `asm_exc_page_fault` falls
below the top-15 floor of 1.2% and so is not listed as its own row)
is exactly here: 10 backends × 5 iterations × 100k keys × random()
input churn lots of fresh palloc pages, which the kernel zeroes on
first touch.

Atomic ops (`__atomic_*`; on x86_64 these are inlined `lock add`/`cmpxchg`) do not appear in
the top 15 — total spend on shared atomic counters is < 1.2%. That
confirms the per-backend stat slot design: each backend writes its
own slot `XClaimBackendInfos[procno]`, not a shared counter. On a
shared counter, 10 backends would ping-pong the cache line between
NUMA nodes and the row would show ~15-20% atomic overhead in the
top 15.

---

## Where time goes — by category

| Category | Scalar | Bulk | Cleanup | Contention | What it is |
|----------|-------:|-----:|--------:|-----------:|------------|
| **Local simplehash** (`xclaim_local_lookup_with_hash`, `xclaim_local_insert_held`, `xclaim_local_cleanup_held`) | ~37% | ~12% | ~29% | ~7% | reentrancy fast-path + group-by-partition cleanup; hash computation is inlined into this category |
| **Shared dynahash** (`hash_search_with_hash_value` + `hash_bytes`) | ~12.5% | ~5% | ~28% | ~16% | partitioned shared hash; under partition LWLock |
| **PG executor / plpgsql** (`ExecInterpExpr`, tuplestore, SRF dispatch) | ~12% | ~15% | ~10% | ~13% | function-call dispatch, FOR-loop machinery, tuplestore I/O |
| **xclaim driver self-time** (`xclaim_try_internal`, `xclaim_try_many_internal`, `xclaim_is_stale_owner`) | ~2% | ~3% | ~3% | **~10%** | self-time + stale-owner reaper (the latter spikes under contention) |
| **Memory alloc** (`AllocSetAlloc`, `AllocSetFree`, `AllocSetGetChunkSpace`) | ~4% | ~9% | ~1% | ~4% | palloc/pfree plumbing for locals and tuplestore |
| **Kernel page-zero + faults** (`clear_page_rep`, `asm_exc_page_fault`) | <1% | ~2% | ~3% | ~3% | first-touch zero-fill on fresh palloc pages + page-fault entry |
| **libc opaque** (`[libc.so.6]`) | ~3% | ~5% | ~2% | ~5% | memcpy/memset/strlen — install `libc6-dbg` to resolve |
| **Atomic counters** (`__atomic_*`) | <1% | <1% | <1% | <1.2% | per-backend stat slots + live_capacity; inline `lock`-prefixed instructions on x86_64 |
| **LWLock acquire/release** | <1% | <1% | <1% | <1% | partition lock cycles (≤ num_partitions=128); not in top 15 |

---

## Architectural validation

The profile confirms four core promises:

1. **LWLock cycles are bounded by `num_partitions`, not by entry
   count.** `LWLockRelease` does not appear in the top 15 of any of
   the four scenarios (i.e., <1% of samples everywhere). That is a
   lower bound on the group-cleanup cost: the 50k entries in the
   cleanup scenario pass through ≤ 128 LWLock cycles (default
   `num_partitions`), not 50k. The group-by-partition cleanup
   invariant holds — confirmed directly with resolved pg_xclaim
   symbols.

2. **Cache-line contention is minimal.** Under 10-backend contention
   none of the `__atomic_*` operations (the x86_64 lock prefix)
   appear in the top 15 (<1.3%) thanks to per-backend stat slots
   (`XClaimBackendInfos[procno]`): each backend writes its own
   cache line. Shared counters on a single cache line would
   ping-pong between sockets under concurrent writes; per-backend
   slots avoid that by design.

3. **`hash_search_with_hash_value` stays the proportional principal
   shared-hash cost.** 5–27% in acquire-heavy and cleanup scenarios,
   with no unexpected collision storms or long chain walks. In the
   cleanup scenario its share rises to 25.9% precisely because the
   cleanup walks every entry (50k × 50 tx = 2.5M HASH_REMOVE), but
   that's the baseline cost — not a pathological contention pattern.

4. **The standalone `hash_bytes` frame is visible only in the
   cleanup path (≤ 1.5%).** Acquire paths (scalar and bulk) inline
   the hash computation inside `xclaim_local_lookup_with_hash`, so
   there is no separate top-leaf frame for hash there. Cleanup uses
   the hashvalue saved in each local-set entry, so `hash_bytes` is
   not called along that path either; the residual 1.5% comes from
   the few remaining hash-compute call sites not yet inlined.

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
| 750k single-backend scalar `xclaim.try` | 378 ms | 2000 ms | 5.3× |
| 750k bulk `xclaim.try_many` | 288 ms | 500 ms | 1.74× |
| 50k acquire+COMMIT (group-by-partition cleanup) | <100 ms | 100 ms | gated by `test/concurrency/grouped_cleanup_50k.sh` |
| 10 backends × 100k overlapping (1M total) | sub-second wall | — | gated by `test/concurrency/stress_10x100k.sh` |

`pg_locks.advisory` count is **0** for migrated paths — confirming the
extension runs without LockManager entries on those specific paths in
this synthetic workload. This is a property of the extension, not a
universal claim about advisory locks; for most workloads the standard
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

# Record all four scenarios in one shot (as root; initdb/pg_ctl/psql
# are delegated to the `postgres` OS user via `runuser`):
sudo scripts/record_flamegraphs.sh

# SVGs land in docs/perf/flamegraphs/, top-15 leaves per scenario
# print to stdout.
```

`scripts/record_flamegraphs.sh` sets
`kernel.kptr_restrict=0` and `kernel.perf_event_paranoid=-1` for
the duration of the run and restores the originals on exit. Under
the hood it runs the equivalent of `perf record -F 997 -g -a` over
a 12-second window per scenario, drives the workload via
`psql -h /tmp -p <port> ...`, and emits an SVG via
`/opt/FlameGraph/stackcollapse-perf.pl | flamegraph.pl`.

`postgresql-17-dbgsym` installs debug-info to
`/usr/lib/debug/.build-id/...`; `perf` finds the file by Build-ID
automatically. Without that package, all PG core functions will
collapse into the opaque `[postgres]` leaf and the top-15 will only
be informative for pg_xclaim symbols. For source-level kernel
symbols additionally install `linux-image-$(uname -r)-dbgsym` from
the ubuntu ddebs repo — without it kernel frames carry only function
names (via kallsyms), not file/line.

---

## How to read the SVGs

Each block in the flamegraph is a function on the call stack:
- **Width** = percent of total CPU time (samples)
- **Y axis (vertical)** = call depth (root at the bottom)
- **Colors** = visual differentiation only (no semantic meaning under `--colors hot`)
- **Click to zoom**, **Reset Zoom** to go back, **Search** for a substring across all stacks

Things to look for in `xclaim.try` flamegraphs:
- Wide `xclaim_local_lookup_with_hash` blocks near the top → reentrancy fast-path dominance (`hash_bytes` is inlined here)
- Blocks above `LWLockAcquire`/`LWLockRelease` → critical-section hot leaves
- `[postgres]` blocks → PG core (executor, planner, function-call dispatch)
- Anything inside the kernel (`__x64_sys_*`, `do_*`, `entry_*`) → syscalls / page-fault handlers
