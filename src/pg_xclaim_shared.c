/*-------------------------------------------------------------------------
 *
 * pg_xclaim_shared.c
 *      Shared-memory subsystem:
 *        * `xclaim_shmem_size`  -- exact sizing formula.
 *        * `xclaim_shmem_startup` -- partitioned ShmemInitHash, control
 *          singleton, per-backend info array, named LWLock tranche
 *          pointer; flips `xclaim_state_initialized = true` at the tail.
 *        * Forbidden-pattern comment block warning contributors
 *          that simplehash.h MUST NOT be used in shared memory.
 *
 * Layout summary:
 *   * RequestAddinShmemSpace + RequestNamedLWLockTranche +
 *     shmem_startup_hook contract.
 *   * XClaimKey 16-byte layout (verified via StaticAssertDecl in
 *     pg_xclaim_internal.h).
 *   * HARD invariant: simplehash.h FORBIDDEN in shmem.
 *   * ShmemInitHash flag set: HASH_ELEM | HASH_BLOBS | HASH_PARTITION |
 *     HASH_FIXED_SIZE.
 *   * XClaimBackendInfo array sized at MaxBackends.
 *
 * HARD invariants enforced here:
 *   * `simplehash.h` MUST NOT be used in shmem -- documented in the
 *     forbidden-pattern comment block right next to ShmemInitHash.
 *   * State held in shared memory exclusively (ShmemInitStruct /
 *     ShmemInitHash); no palloc'd state crosses the postmaster boundary.
 *   * AddinShmemInitLock acquired EXCLUSIVE around all ShmemInit*; never
 *     left held through any code that can ereport(ERROR).
 *
 * PG version notes:
 *   PG 16, 17, 18 all expose the same contract:
 *     * RequestAddinShmemSpace, RequestNamedLWLockTranche,
 *       GetNamedLWLockTranche, AddinShmemInitLock, ShmemInitStruct,
 *       ShmemInitHash, hash_estimate_size, get_hash_value.
 *   No version branching is required in this file; the only compat
 *   surface (procno, lxid) lives in pg_xclaim_compat.h.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"              /* MaxBackends */
#include "port/atomics.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/hsearch.h"

#include <string.h>

#include "pg_xclaim.h"
#include "pg_xclaim_compat.h"
#include "pg_xclaim_internal.h"

/* -------------------------------------------------------------------- */
/* Shared-memory globals (declared extern in pg_xclaim_internal.h).     */
/* -------------------------------------------------------------------- */

XClaimControl       *XClaimCtl          = NULL;
HTAB                *XClaimHash         = NULL;
XClaimBackendInfo   *XClaimBackendInfos = NULL;

/*
 * Backend-local cache of the named partition LWLock tranche pointer.
 *
 * PG core lays out the named-tranche LWLocks in the main shmem segment,
 * which every backend attaches at the same base address; calling
 * GetNamedLWLockTranche from each backend's shmem_startup_hook is safe
 * and the conventional pattern (the alternative -- storing the pointer
 * inside our own shmem block -- works in practice on EXEC_BACKEND today
 * but is fragile per PG core guidance, since absolute pointers inside
 * shmem are not generally portable across mapping strategies).
 *
 * This pointer is re-populated for every backend in xclaim_shmem_startup
 * below: under fork() platforms once in the postmaster (children inherit
 * via fork), and on EXEC_BACKEND platforms once per child backend (the
 * hook fires per backend after shmem attach).
 */
LWLockPadded        *XClaimPartitionLocks = NULL;

/*
 * Saved upstream shmem_startup_hook. Installed by xclaim_install_shmem_hook
 * (called from _PG_init in pg_xclaim.c) and chained at the head of
 * xclaim_shmem_startup so other extensions still get to run.
 */
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

/*
 * Total shared-memory request size, in bytes.
 *
 * Computed ONCE on the first `xclaim_shmem_size()` call (from the
 * shmem_request_hook in pg_xclaim.c) and reused verbatim by
 * `xclaim_shmem_startup` for the operator-visible LOG line. Recording
 * the value avoids two divergent answers if the formula is ever modified
 * -- "what was requested" and "what is logged" stay in lock-step. The
 * value is stable for the lifetime of the postmaster: every input GUC
 * is PGC_POSTMASTER (frozen at startup) and MaxBackends is set before
 * shmem_request_hook runs.
 */
static Size xclaim_shmem_total_bytes = 0;

/*
 * xclaim_install_shmem_hook
 *      Capture the existing shmem_startup_hook (if any) and replace it
 *      with our own. Called once from _PG_init AFTER the preload gate
 *      and ABI check have passed.
 */
void
xclaim_install_shmem_hook(void)
{
    prev_shmem_startup_hook = shmem_startup_hook;
    shmem_startup_hook = xclaim_shmem_startup;
}

/* -------------------------------------------------------------------- */
/* Shmem size.                                                          */
/*                                                                      */
/* Formula:                                                             */
/*    sz  = MAXALIGN(sizeof(XClaimControl))                             */
/*        + hash_estimate_size(max_claims, sizeof(XClaimEntry))         */
/*        + num_partitions * sizeof(LWLockPadded)                       */
/*        + MaxBackends    * sizeof(XClaimBackendInfo)                  */
/*        + 25% headroom for dynahash freelist/segment growth           */
/*                                                                      */
/* Note: the stride is `sizeof(LWLockPadded)`, not `sizeof(LWLock)`.    */
/* `RequestNamedLWLockTranche` returns a cache-line-padded array (see   */
/* `storage/lwlock.h`); using the bare LWLock size would under-count   */
/* the actual allocation by ~7 MB at the 65536-partition GUC ceiling.   */
/* The 25% headroom would absorb the drift, but the formula MUST       */
/* match the real stride for the LOG-line accounting to be honest.     */
/*                                                                      */
/* Memory size at default GUCs (max_claims=4M, num_partitions=128,      */
/* MaxBackends=100):                                                    */
/*    XClaimControl                  ~120 bytes (negligible)            */
/*    hash_estimate_size(4M, 48B)    ~270-320 MB (depends on PG ver)    */
/*    128 * sizeof(LWLockPadded)     ~16-32 KB (cache-line-padded)      */
/*    100 * sizeof(XClaimBackendInfo) ~12.5 KB (cache-line padded)      */
/*    + 25% headroom                                                    */
/*    ----------------                                                  */
/*    ~340-400 MB shared memory total at defaults.                      */
/*                                                                      */
/* At max_claims=16M (high-concurrency clusters): ~1.2-1.6 GB.          */
/* DBA must size shared_buffers + shmem reservation accordingly. The    */
/* number is logged at LOG level in xclaim_shmem_startup (below) using  */
/* the cached value computed here, so the request and the log line     */
/* never disagree.                                                      */
/* -------------------------------------------------------------------- */

Size
xclaim_shmem_size(void)
{
    Size    sz;
    int     mb;

    /*
     * Memoize. The first call (from `xclaim_shmem_request_hook`) computes
     * the formula; subsequent calls (e.g. the LOG line in
     * `xclaim_shmem_startup`) reuse the cached value so both code paths
     * agree byte-for-byte across formula edits. All inputs
     * (PGC_POSTMASTER GUCs, MaxBackends) are immutable for the lifetime
     * of the postmaster.
     */
    if (xclaim_shmem_total_bytes != 0)
        return xclaim_shmem_total_bytes;

    /*
     * MaxBackends is initialized before shared_preload_libraries fires
     * shmem_request_hook, so it is safe to read here. (For paranoid
     * defense-in-depth we Max() with 1 below; this also keeps
     * mul_size happy if a PG version ever zero-initializes it.)
     */
    mb = MaxBackends > 0 ? MaxBackends : 1;

    sz = MAXALIGN(sizeof(XClaimControl));
    sz = add_size(sz, hash_estimate_size(xclaim_max_claims, sizeof(XClaimEntry)));
    sz = add_size(sz, mul_size(xclaim_num_partitions, sizeof(LWLockPadded)));
    sz = add_size(sz, mul_size(mb, sizeof(XClaimBackendInfo)));

    /* 25% headroom (rounded up to MAXALIGN). */
    sz = add_size(sz, MAXALIGN(sz / 4));

    xclaim_shmem_total_bytes = sz;
    return sz;
}

/* -------------------------------------------------------------------- */
/* shmem_startup_hook body.                                             */
/*                                                                      */
/* Order of operations under AddinShmemInitLock:                        */
/*   1. Chain prev_shmem_startup_hook (cooperate with other extensions).*/
/*   2. ShmemInitStruct("xclaim_control", ...) -- allocate or attach.   */
/*   3. ShmemInitStruct("xclaim_backend_infos", ...) -- per-backend     */
/*      slots indexed by procno.                                        */
/*   4. ShmemInitHash("xclaim_hash", init=max, max=max, &info,          */
/*      HASH_ELEM | HASH_BLOBS | HASH_PARTITION | HASH_FIXED_SIZE).     */
/*   5. GetNamedLWLockTranche("xclaim_partition") -- pointer recorded   */
/*      in XClaimCtl->partition_locks for downstream consumers.         */
/*   6. Flip xclaim_state_initialized = true.                           */
/*                                                                      */
/* Steps 2-5 are pure shmem setup that cannot ereport(ERROR) under      */
/* normal conditions. If any underlying call ereport(FATAL)s on         */
/* allocator exhaustion, the postmaster aborts before LWLockRelease     */
/* runs -- which is the correct behaviour (cluster start fails). The    */
/* hook is therefore safe without PG_TRY/PG_CATCH wrapping; LWLock-     */
/* leak concerns apply to ERROR-returning user code paths in the        */
/* acquisition / cleanup hot paths, not to shmem startup.               */
/* -------------------------------------------------------------------- */

/*
 * NOTE -- FORBIDDEN PATTERN -- read before changing the hash setup below
 *
 *   simplehash.h MUST NOT be used for shared memory. Linear probing plus
 *   grow-on-collision is fundamentally incompatible with fixed-size shared
 *   memory: there is no allocator to grow into without PG-wide
 *   coordination, and a probe-sequence shift mid-flight would corrupt
 *   in-flight readers.
 *
 *   Use ShmemInitHash (dynahash) for SHARED state -- it is partitioned,
 *   uses chained buckets, and respects HASH_FIXED_SIZE.
 *
 *   simplehash.h is permitted ONLY for private backend-local state
 *   (`pg_xclaim_local.c`) where the allocator is the backend's
 *   TopMemoryContext and probe re-sequencing is local to one process.
 */

void
xclaim_shmem_startup(void)
{
    bool    found_ctl;
    bool    found_binfo;
    HASHCTL info;
    Size    binfo_bytes;

    /*
     * Recovery / hot-standby disposition.
     *
     * Three observations:
     *
     *   (a) `XLogCtl` is NULL during `process_shared_preload_libraries`
     *       (called BEFORE `CreateSharedMemoryAndSemaphores`). Calling
     *       `RecoveryInProgress()` from `_PG_init` therefore crashes
     *       the postmaster with EXC_BAD_ACCESS. The check MUST move
     *       out of `_PG_init`.
     *
     *   (b) By the time `shmem_startup_hook` runs, `XLogCtl` IS
     *       attached, so `RecoveryInProgress()` is safe to call here.
     *       However, on a freshly-started PRIMARY cluster
     *       `RecoveryInProgress()` ALSO returns `true` here (the
     *       startup process is still replaying the last checkpoint
     *       before promotion). We therefore CANNOT use the value at
     *       shmem-startup time as a primary-vs-standby discriminator;
     *       a `false` from here would be reliable, but a `true`
     *       conflates "standby" with "primary still in startup".
     *
     *   (c) The accurate place to check `RecoveryInProgress()` is at
     *       SQL-entry-point preflight (called from a regular backend
     *       AFTER startup completes). `XCLAIM_REQUIRE_INIT()` consults
     *       it there: SQL functions on a hot-standby raise
     *       ERRCODE_FEATURE_NOT_SUPPORTED -- the operator gets the
     *       diagnostic at the first call rather than at cluster boot.
     *       Contrib's pg_surgery follows the same defer-to-call-time
     *       pattern (a call-time `RecoveryInProgress()` check).
     *
     * The shmem-startup body therefore initializes unconditionally;
     * the per-call recovery check lives in `XCLAIM_REQUIRE_INIT()`
     * (see `pg_xclaim.h`).
     */

    /*
     * Chain previous shmem_startup_hook BEFORE acquiring AddinShmemInitLock.
     *
     * AddinShmemInitLock self-deadlock avoidance: many extensions
     * (canonically pg_stat_statements -- see contrib/pg_stat_statements/
     * pg_stat_statements.c REL_17_STABLE) acquire AddinShmemInitLock
     * EXCLUSIVE inside their own shmem_startup body. If pg_xclaim were to
     * call prev_shmem_startup_hook() while ALREADY holding the lock, and
     * the chained hook is pg_stat_statements (or any other extension
     * following the canonical pattern), the chained acquire would
     * self-deadlock against our own hold.
     *
     * Mitigation: invoke the previous hook FIRST (no lock held), then
     * acquire AddinShmemInitLock EXCLUSIVE for our own ShmemInit* calls,
     * then release. The chained extension's lock acquire/release is
     * fully nested inside its own body and serialized w.r.t. our region
     * by the postmaster's single-threaded shmem-startup phase on regular
     * starts; on EXEC_BACKEND / Windows per-backend re-entry, each
     * extension still serializes its own ShmemInit* under its own
     * AddinShmemInitLock acquire.
     */
    if (prev_shmem_startup_hook != NULL)
        prev_shmem_startup_hook();

    LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

    /* ----------------------------------------------------------------
     * 1. Control singleton.
     *
     * `ShmemInitStruct` already cache-line-aligns (CACHELINEALIGN) the
     * size argument internally, so we pass `sizeof(XClaimControl)`
     * directly here. The MAXALIGN in `xclaim_shmem_size()` is the
     * load-bearing one for the running total.
     * ---------------------------------------------------------------- */
    XClaimCtl = (XClaimControl *) ShmemInitStruct("xclaim_control",
                                                   sizeof(XClaimControl),
                                                   &found_ctl);
    if (!found_ctl)
    {
        memset(XClaimCtl, 0, sizeof(*XClaimCtl));

        /* GUC snapshots (HARD invariant: validated in GUC check_hooks). */
        XClaimCtl->num_partitions = xclaim_num_partitions;
        XClaimCtl->max_claims     = xclaim_max_claims;

        /*
         * next_token starts at 1. 0 is the reserved sentinel for an
         * inactive backend slot in XClaimBackendInfo.current_token, so
         * a fresh issuance can never collide with the inactive reading.
         */
        pg_atomic_init_u64(&XClaimCtl->next_token, 1);

        /* All counters start at zero.
         *
         * total_acquires / reentrant_hits / conflicts are ABI/layout
         * reserves (see pg_xclaim_internal.h): acquisition bumps
         * per-backend slots instead, while the global fields stay zero
         * to preserve the shared-control layout. */
        pg_atomic_init_u64(&XClaimCtl->total_acquires,             0);
        pg_atomic_init_u64(&XClaimCtl->reentrant_hits,             0);
        pg_atomic_init_u64(&XClaimCtl->conflicts,                  0);
        pg_atomic_init_u64(&XClaimCtl->capacity_errors,            0);
        pg_atomic_init_u64(&XClaimCtl->capacity_warnings,          0);
        pg_atomic_init_u64(&XClaimCtl->reaped_stale,               0);
        pg_atomic_init_u64(&XClaimCtl->cleanup_misses,             0);
        pg_atomic_init_u64(&XClaimCtl->disabled_calls,             0);
        pg_atomic_init_u64(&XClaimCtl->debug_scans,                0);
        pg_atomic_init_u64(&XClaimCtl->session_resets,             0);
        pg_atomic_init_u64(&XClaimCtl->peak_per_backend,           0);
        pg_atomic_init_u64(&XClaimCtl->live_capacity,              0);

        XClaimCtl->partition_locks = NULL;      /* filled in below */
    }

    /* ----------------------------------------------------------------
     * 2. Per-backend info array. MaxBackends slots; a backend at
     *    procno i publishes its current owner_token in
     *    XClaimBackendInfos[i].current_token.
     * ---------------------------------------------------------------- */
    binfo_bytes = mul_size((Size) MaxBackends, sizeof(XClaimBackendInfo));
    XClaimBackendInfos = (XClaimBackendInfo *)
        ShmemInitStruct("xclaim_backend_infos", binfo_bytes, &found_binfo);
    if (!found_binfo)
    {
        int     i;

        memset(XClaimBackendInfos, 0, binfo_bytes);
        for (i = 0; i < MaxBackends; i++)
        {
            pg_atomic_init_u64(&XClaimBackendInfos[i].current_token,        0);
            XClaimBackendInfos[i].pid = 0;
            /*
             * Per-backend hot-path counters. Initialized once at cluster
             * start; never zeroed at session_reset (cumulative stats
             * survive backend reuse).
             */
            pg_atomic_init_u64(&XClaimBackendInfos[i].total_acquires_local, 0);
            pg_atomic_init_u64(&XClaimBackendInfos[i].reentrant_hits_local, 0);
            pg_atomic_init_u64(&XClaimBackendInfos[i].conflicts_local,      0);
        }
    }

    /* ----------------------------------------------------------------
     * 3. Partitioned shared dynahash.
     *
     *    info.num_partitions is the number of internal hash partitions
     *    dynahash maintains; we pair this with our own `num_partitions`
     *    LWLocks via partition_id = hashvalue & (num_partitions - 1).
     *
     *    init_size == max_size for HASH_FIXED_SIZE -- both equal
     *    xclaim_max_claims so there is no growth path; the table is a
     *    hard ceiling and capacity exhaustion is signalled via
     *    HASH_ENTER_NULL in the acquisition path.
     * ---------------------------------------------------------------- */
    memset(&info, 0, sizeof(info));
    info.keysize        = sizeof(XClaimKey);
    info.entrysize      = sizeof(XClaimEntry);
    info.num_partitions = xclaim_num_partitions;

    XClaimHash = ShmemInitHash("xclaim_hash",
                               xclaim_max_claims,           /* init_size */
                               xclaim_max_claims,           /* max_size  */
                               &info,
                               HASH_ELEM | HASH_BLOBS |
                               HASH_PARTITION | HASH_FIXED_SIZE);

    /* ----------------------------------------------------------------
     * 4. Named LWLock tranche pointer. RequestNamedLWLockTranche was
     *    already issued from the shmem_request_hook in pg_xclaim.c;
     *    GetNamedLWLockTranche returns the LWLockPadded array PG carved
     *    out for us.
     *
     *    Tranche name "xclaim_partition" appears in pg_stat_activity
     *    as `LWLock: xclaim_partition` in the wait_event column.
     * ---------------------------------------------------------------- */
    /*
     * Resolve the named-tranche pointer into the backend-local cache.
     * The same shmem-resident pointer slot in XClaimControl is kept in
     * sync for backwards-compatibility with any in-tree reader that
     * still goes through XClaimCtl, but the hot path (xclaim_partition_lock
     * inline) reads the backend-local cache directly to avoid storing or
     * dereferencing an absolute pointer that lives inside our own shmem
     * block.
     */
    XClaimPartitionLocks       = GetNamedLWLockTranche("xclaim_partition");
    XClaimCtl->partition_locks = XClaimPartitionLocks;

    /*
     * Final flag flip INSIDE the lock. On EXEC_BACKEND / Windows,
     * `shmem_startup_hook` runs per-backend on attach; bracketing the
     * flag set with `AddinShmemInitLock` ensures a sibling-extension
     * hook in the same per-backend invocation cannot observe
     * `xclaim_state_initialized = true` before our ShmemInit calls
     * publish their results.
     */
    xclaim_state_initialized = true;

    LWLockRelease(AddinShmemInitLock);

    /*
     * Operator-visible memory accounting -- DBA sizing math is
     * otherwise opaque ("hash_estimate_size" is internal). Logged once
     * per postmaster startup at LOG level (per backend on EXEC_BACKEND
     * builds, where each child re-runs the startup hook). Reuses the cached value
     * computed by `xclaim_shmem_size()` during the request hook so the
     * log line and the actual `RequestAddinShmemSpace` argument are
     * guaranteed to agree.
     */
    ereport(LOG,
            (errmsg("pg_xclaim: shared memory initialized "
                    "(max_claims=%d, num_partitions=%d, MaxBackends=%d, total=%zu bytes)",
                    xclaim_max_claims, xclaim_num_partitions,
                    MaxBackends, (size_t) xclaim_shmem_size())));
}
