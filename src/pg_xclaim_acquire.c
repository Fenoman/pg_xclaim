/*-------------------------------------------------------------------------
 *
 * pg_xclaim_acquire.c
 *      The acquisition algorithm implementing the high-cardinality claim
 *      acquisition surface, plus the bulk (array) driver built on top of it.
 *
 * Hosts:
 *   * `xclaim_try_internal`               -- the scalar acquisition body.
 *   * `xclaim_try_many_internal`          -- the bulk driver (partition
 *                                            pre-sort + single-pass loop).
 *   * `xclaim_try_many_solo`              -- SQL entry point
 *                                            `xclaim.try_many(int8[])`.
 *   * `xclaim_try_many_pair`              -- SQL entry point
 *                                            `xclaim.try_many(int4, int4[])`.
 *   * `xclaim_handle_capacity_exhaustion` -- 2-mode dispatch on the
 *                                            `pg_xclaim.on_capacity_exhaustion`
 *                                            GUC (ERROR / WARN).
 *   * `xclaim_check_capacity_watermark`   -- thin call site, body lives
 *                                            in pg_xclaim_stats.c.
 *
 * The two SCALAR SQL-callable C entry points (`xclaim_try_solo`,
 * `xclaim_try_pair`) live in pg_xclaim.c -- those entry points handle
 * PG_FUNCTION_ARGS marshalling + NULL-arg policy + key construction (with
 * the MANDATORY `memset`) and then call into `xclaim_try_internal` here.
 * The two BULK entry points (`xclaim_try_many_solo`, `xclaim_try_many_pair`)
 * live in this TU and call `xclaim_try_many_internal`.
 *
 * Step mapping. Each "Step N" comment in the body marks the corresponding
 * step, and the list below is in EXECUTION order. Two numbering notes that
 * hold for both the scalar and the bulk path:
 *   * Step 5 (hash compute) runs BEFORE Step 4 (reentrancy probe): the hash
 *     is hoisted so the same precomputed value feeds the local-set lookup
 *     and, on miss, the shared insert -- the numeric labels are kept stable
 *     even though Step 5 physically precedes Step 4.
 *   * There is no Step 9: Step 8b falls through directly to Step 10. The gap
 *     is intentional, and "Step 9" does not appear anywhere in the body.
 *
 *   Step 0     single CHECK_FOR_INTERRUPTS (only valid cancel point), before
 *              any state is read
 *   Step 1     feature-flag short-circuit + transaction-state + parallel-
 *              worker guards
 *   Step 2     lazy init (local hash + owner_token)
 *   Step 3     key already constructed by caller (entry point), no-op here
 *   Step 5     hashvalue + partition_id compute (one get_hash_value call)
 *   Step 4     reentrancy fast-path -- O(1) local lookup, NO LWLock
 *   Step 6     local entry added, NO LWLock: a growth of the local set
 *              (which may ERROR on out of memory) runs before any shared
 *              change. The entry is recorded as held only at Step 12
 *   Step 7     LWLockAcquire(partition_lock, LW_EXCLUSIVE). Its ERROR
 *              ("too many LWLocks taken") drops the Step 6 entry
 *   Step 8     combined lookup-or-insert (single HASH_ENTER_NULL under
 *              partition lock: *found distinguishes existing vs fresh,
 *              NULL signals capacity exhaustion on not-found path)
 *   Step 8a    own entry (found && matches_self) -> the Step 6 entry
 *              restores the local side, release, record, return true
 *   Step 8b    conflict (found && !matches_self) -> stale-owner reaper:
 *              if stale, take over via overwrite-in-place at Step 10,
 *              else release, drop the Step 6 entry, return false.
 *              Capacity exhaustion (NULL) also releases and drops it
 *   Step 10    populate shared XClaimEntry owner_* fields (saved triple) --
 *              writes fresh-insert slot OR overwrites a stale-reap'd slot
 *   Step 12    LWLockRelease (LINEARIZATION POINT), the Step 6 entry is
 *              recorded as held, counter increment
 *
 * HARD invariants enforced here:
 *   * `XCLAIM_REQUIRE_INIT()` is the FIRST executable statement of every
 *     SQL-callable C entry point (the entry points in pg_xclaim.c, NOT this
 *     internal helper -- the macro must run before any code path that could
 *     deref shared state).
 *   * Interrupt points (`CHECK_FOR_INTERRUPTS()`):
 *       - Scalar (`xclaim_try_internal`): Step 0 only, never between the
 *         Step 4 reentrancy probe and the Step 12 lock release.
 *       - Bulk (`xclaim_try_many_internal`): preflight, Phase A before each
 *         staged slot (no lock held), and before re-taking the lock after a
 *         WARN-mode capacity miss.
 *     Why. Processing an interrupt between local lookup and shared insert
 *     could invoke an `emit_log_hook` that runs SQL on the same key, or
 *     cancel after one half of the local/shared pair was written (leaving a
 *     ghost local claim or an orphaned shared row invisible to xact cleanup
 *     until the lazy reaper meets a conflict after backend exit or token
 *     rotation).
 *   * LWLock acquire/release pairing 1:1 and zero allocations under lock --
 *     both scalar and bulk pre-stage local entries before `LWLockAcquire`,
 *     promote held entries in place under the lock, and drop unacquired
 *     staged entries after `LWLockRelease`. Bulk wraps its partition loop in
 *     `PG_TRY`/`PG_CATCH` (`HOLD_INTERRUPTS()` before `LWLockRelease`,
 *     unstaging owned slots and rolling back shared inserts per partition).
 *   * Linearization point = `LWLockRelease` at Step 12 (success) or Step 8b
 *     (conflict) -- documented inline.
 *   * Capacity exhaustion is NOT logical conflict: default mode is
 *     `ereport(ERROR, ERRCODE_CONFIGURATION_LIMIT_EXCEEDED)`.
 *   * The stale-owner reaper is invoked LAZILY on the conflict path
 *     (Step 8b). If `xclaim_is_stale_owner()` returns true the entry's
 *     owner triple is overwritten in place at Step 10 under the SAME
 *     partition lock (linearizes correctly, no HASH_REMOVE+HASH_ENTER
 *     cycle needed since the HASH_ENTER_NULL at Step 8 already returned
 *     the existing entry pointer).
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <string.h>

#include "miscadmin.h"                  /* MyDatabaseId, MyProcPid */
#include "access/xact.h"                /* IsTransactionState */
#include "catalog/pg_type_d.h"          /* INT4OID, INT8OID, BOOLOID */
#include "fmgr.h"
#include "port/atomics.h"
#include "storage/lock.h"               /* LOCKTAG, SET_LOCKTAG_ADVISORY */
#include "storage/lockdefs.h"           /* ExclusiveLock */
#include "storage/lwlock.h"
#include "storage/proc.h"               /* MyProc */
#include "utils/array.h"                /* deconstruct_array, construct_md_array */
#include "utils/elog.h"
#include "utils/hsearch.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"             /* MaxAllocSize */

#include "pg_xclaim.h"
#include "pg_xclaim_compat.h"
#include "pg_xclaim_internal.h"
#include "pg_xclaim_local.h"

/* IsParallelWorker() lives in access/parallel.h on PG 16/17/18. */
#include "access/parallel.h"

/* -------------------------------------------------------------------- */
/* Per-call WARN suppression state for the bulk path.                   */
/*                                                                      */
/* WARN-mode capacity exhaustion in xclaim.try_many would otherwise     */
/* emit one WARNING per failed slot. For a 1000-key bulk past capacity  */
/* that is 1000 client + 1000 server WARNINGs -- log noise that hides   */
/* the actual signal ("you ran out of room"). The flags below collapse  */
/* the per-slot stream into one detail WARNING + one tail summary       */
/* WARNING, set/reset at the bulk driver's entry, normal exit, and the  */
/* PG_CATCH error path. Single-key xclaim.try is unaffected (each call  */
/* is its own statement, so no rate-limit is needed).                   */
/*                                                                      */
/* The `capacity_warnings` stats counter is INTENTIONALLY incremented   */
/* on every failed slot regardless of suppression: operators sizing     */
/* against `xclaim.stats()` need the exact slot-failure count, not the  */
/* emit-event count.                                                    */
/* -------------------------------------------------------------------- */
static bool xclaim_bulk_warn_context_active = false;
static bool xclaim_bulk_warn_emitted_this_call = false;
static int  xclaim_bulk_warn_suppressed_count = 0;

/*
 * True while an xclaim.try_many loop runs in this backend: the scope above
 * opens before the loop and closes after it. The capacity WARNING inside
 * the loop runs an emit_log_hook, and xclaim.session_reset() refuses to
 * run from there (it would rotate the owner token of the claims the loop
 * is about to take).
 */
bool
xclaim_try_many_in_progress(void)
{
    return xclaim_bulk_warn_context_active;
}

/* -------------------------------------------------------------------- */
/* xclaim_handle_capacity_exhaustion                                    */
/*                                                                      */
/* 2-mode dispatch on pg_xclaim.on_capacity_exhaustion. Caller has      */
/* already released the partition LWLock, and this function does not    */
/* touch the shared dynahash.                                           */
/*                                                                      */
/* Fallback to advisory locks is intentionally not supported.           */
/* Delegating to LockAcquire(LOCKTAG_ADVISORY) on capacity exhaustion   */
/* is unsafe because xclaim cleanup does not see that claim, allowing   */
/* the same key to be subsequently re-acquired through xclaim shmem     */
/* and breaking mutual exclusion. Operators who hit capacity must raise */
/* `max_claims` and restart, or accept WARN-mode false-conflict         */
/* behaviour.                                                          */
/* -------------------------------------------------------------------- */

bool
xclaim_handle_capacity_exhaustion(const XClaimKey *lk)
{
    Assert(lk != NULL);

    switch (xclaim_capacity_behavior)
    {
        case XCLAIM_CAP_ERROR:
        {
            /*
             * Default policy: hard ERROR. Capacity exhaustion is an
             * infrastructure problem distinct from a logical conflict --
             * returning `false` here would silently break the API contract
             * callers expect (signature compatible with
             * pg_try_advisory_xact_lock). A caller would treat the false as
             * a conflict and retry forever.
             *
             * SQLSTATE: 53400 (ERRCODE_CONFIGURATION_LIMIT_EXCEEDED).
             */
            pg_atomic_fetch_add_u64(&XClaimCtl->capacity_errors, 1);
            ereport(ERROR,
                    (errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
                     errmsg("pg_xclaim: max_claims (%d) exhausted",
                            xclaim_max_claims),
                     errhint("Increase pg_xclaim.max_claims and restart, "
                             "or set pg_xclaim.on_capacity_exhaustion to warn.")));
            /* unreachable */
            return false;
        }

        case XCLAIM_CAP_WARN:
        {
            /*
             * Treat as logical conflict + emit WARNING. Caller's retry
             * path (if any) will be triggered. Stats counter increments
             * separately from `conflicts` so operators can distinguish
             * real contention from sizing pressure.
             *
             * In the bulk path, subsequent slot failures while
             * xclaim_bulk_warn_context_active is set (including any
             * nested xclaim.try triggered from emit_log_hook during that
             * bulk call) have their ereport suppressed (see
             * xclaim_bulk_warn_* statics at the top of this TU). The
             * slot-failure COUNTER still increments unconditionally --
             * xclaim.stats().capacity_warnings remains exact for
             * sizing-pressure observability.
             */
            pg_atomic_fetch_add_u64(&XClaimCtl->capacity_warnings, 1);

            if (xclaim_bulk_warn_context_active &&
                xclaim_bulk_warn_emitted_this_call)
            {
                /*
                 * Detail WARNING for THIS bulk call already fired.
                 * Tally for the post-loop summary and stay quiet.
                 */
                xclaim_bulk_warn_suppressed_count++;
                return false;
            }

            ereport(WARNING,
                    (errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
                     errmsg("pg_xclaim: max_claims (%d) exhausted, "
                            "treating as conflict",
                            xclaim_max_claims),
                     errhint("Raise pg_xclaim.max_claims to eliminate "
                             "false-conflict noise.")));

            if (xclaim_bulk_warn_context_active)
                xclaim_bulk_warn_emitted_this_call = true;

            return false;
        }
    }

    /* Defensive: enum exhausted -- treat as conflict. */
    return false;
}

/* -------------------------------------------------------------------- */
/* xclaim_check_capacity_watermark                                      */
/*                                                                      */
/* Body lives in pg_xclaim_stats.c (which owns the static suppression  */
/* timestamp). The forward declaration is in pg_xclaim.h.               */
/* -------------------------------------------------------------------- */

/* -------------------------------------------------------------------- */
/* xclaim_try_internal -- 12-step acquisition algorithm.                */
/*                                                                      */
/* This algorithm is the heart of the extension. Each "Step N" comment  */
/* maps 1:1 to a numbered step in the pipeline.                         */
/* -------------------------------------------------------------------- */

bool
xclaim_try_internal(const XClaimKey *lk)
{
    XClaimLocalEntry   *existing_local = NULL;
    XClaimLocalEntry   *added;
    bool                pre_staged = false;
    uint32              hashvalue;
    uint32              partition_id;
    LWLock             *plock;
    XClaimEntry        *new_entry;
    bool                found;

    Assert(lk != NULL);
    Assert(lk->form == XCLAIM_FORM_SOLO || lk->form == XCLAIM_FORM_PAIR);

    /* ----------------------------------------------------------------
     * Step 0: single cancel point, before any state is read.
     *
     * `CHECK_FOR_INTERRUPTS()` ONLY here. The interrupts processed here
     * can write messages, and an emit_log_hook can run SQL: an
     * xclaim.try of the same key, or xclaim.session_reset(), which
     * rotates the owner token to 0. Every step below reads the state
     * after them: the guards, the owner token, the reentrancy probe
     * and the local insert.
     *
     * Nothing below processes interrupts until the release in Step 12.
     * From the local insert in Step 6 to that release the local entry
     * and the shared row must change together: a cancel or terminate
     * processed in between would leave a local entry without its shared
     * row (another backend could take the key while this one believes
     * it holds it), or a shared row without its local entry (the cleanup
     * walks the LOCAL SET and would never release it). LWLockAcquire,
     * HASH_ENTER_NULL, the populate and LWLockRelease do not process
     * interrupts, and no step before them writes a message. Only
     * LWLockAcquire raises an ERROR, before it takes the lock (Step 7).
     * ---------------------------------------------------------------- */
    CHECK_FOR_INTERRUPTS();

    /* ----------------------------------------------------------------
     * Step 1: feature-flag + transaction-state guards.
     *
     * `xclaim_enabled = off` is the operator kill switch. When
     * disabled, return true unconditionally -- the extension is a
     * no-op. Stats counter `disabled_calls` increments so operators
     * can confirm the kill switch is actually short-circuiting.
     *
     * `IsTransactionState()` rejects utility-statement contexts where
     * no top-level xact exists (e.g. some autovacuum paths). We MUST
     * NOT acquire claims with no xact-end hook firing -- the entry
     * would never be cleaned up.
     *
     * `IsParallelWorker()` rejects workers. Parallel RESTRICTED tells
     * the planner to keep us in the leader, but defense-in-depth:
     * the runtime check is the correctness safety net.
     * ---------------------------------------------------------------- */
    if (!IsTransactionState())
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("pg_xclaim: xclaim.try requires an active transaction state")));

    if (IsParallelWorker())
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("pg_xclaim: xclaim.try cannot be called from a parallel worker")));

    if (!xclaim_enabled)
    {
        pg_atomic_fetch_add_u64(&XClaimCtl->disabled_calls, 1);
        return true;
    }

    /* ----------------------------------------------------------------
     * Step 2: lazy + idempotent init. Both helpers are no-op after the
     * first call so the steady-state cost is two comparisons. (The xact
     * callback is registered once in _PG_init. The first
     * xclaim_ensure_owner_token() call in a backend registers the
     * backend-exit callback.)
     * ---------------------------------------------------------------- */
    xclaim_local_init();
    xclaim_ensure_owner_token();

    /* ----------------------------------------------------------------
     * Step 3: key already constructed by the SQL entry point
     * (xclaim_try_solo / xclaim_try_pair) using the MANDATORY
     * `memset(&lk, 0, sizeof(lk))` pattern. Nothing to do here.
     * ---------------------------------------------------------------- */

    /* ----------------------------------------------------------------
     * Step 5: hash + partition compute (one call per acquisition).
     *
     * Hoisted above the reentrancy probe so the same precomputed value
     * feeds both the local-set lookup (xclaim_local_lookup_with_hash)
     * AND, on miss, the downstream simplehash insert and the shared
     * dynahash insert -- three hash_bytes() calls collapsed into one.
     *
     * dynahash with HASH_BLOBS routes through tag_hash, which is
     * hash_bytes(bytes, size), and simplehash's SH_HASH_KEY hashes the
     * same XClaimKey byte image with the same hash_bytes function.
     * The numeric values are interchangeable.
     * ---------------------------------------------------------------- */
    hashvalue    = xclaim_compute_hash(lk);
    partition_id = xclaim_partition_id_for_hash(hashvalue);

    /* ----------------------------------------------------------------
     * Step 4: reentrancy fast-path.
     *
     * O(1) lookup in the per-backend simplehash. NO LWLock, NO shared
     * state mutation. Reentrant calls (same backend, same xact, same
     * key) short-circuit with `true` and increment
     * `stats.reentrant_hits` so observability sees the optimisation
     * actually firing.
     *
     * If the key is held: return true. The caller already owns the
     * claim, so this call only reaffirms it.
     * ---------------------------------------------------------------- */
    if (xclaim_local_lookup_with_hash(lk, hashvalue, &existing_local))
    {
        /*
         * Per-backend stat slot: each backend writes ONLY its own slot,
         * avoiding cache-line ping-pong on the shared control block under
         * concurrent contention. xclaim.stats() sums across MaxBackends
         * slots in the SRF reader.
         */
        pg_atomic_fetch_add_u64(
            &XClaimBackendInfos[xclaim_get_current_procno()].reentrant_hits_local,
            1);
        return true;
    }

    /* ----------------------------------------------------------------
     * Step 6: local insert, BEFORE the partition LWLock.
     *
     * A growth of the local set allocates and rehashes the whole set.
     * simplehash grows by its fill threshold and, earlier, when a key
     * probes too far from its bucket. Under the partition lock every
     * backend that needs the partition would wait for that growth, so
     * the local entry goes in first, with no lock held. An out-of-memory
     * ERROR here leaves no shared state behind.
     *
     * The entry is only added here. Step 12 records it as held (live
     * count, peak, held-key list, 75% hint) once the shared row is ours.
     * When the shared insert fails (conflict, capacity), Step 8 drops a
     * newly staged entry after the release (leaving an outer pre-staged
     * entry intact) and the backend's state is as before the call.
     * ---------------------------------------------------------------- */
    xclaim_local_reserve(1);
    added = xclaim_local_add(lk, hashvalue, partition_id, &pre_staged);

    plock = xclaim_partition_lock(hashvalue);
    Assert(plock != NULL);

    /* ----------------------------------------------------------------
     * Step 7: acquire partition LWLock EXCLUSIVE.
     *
     * From here through Step 12 the lock is held. Every code path
     * MUST end with `LWLockRelease(plock)`, and none of them raises an
     * ERROR before it.
     *
     * LWLockAcquire raises "too many LWLocks taken" when the backend
     * already holds MAX_SIMUL_LWLOCKS, before it takes the lock. The
     * Step 6 entry is dropped then: a subtransaction that catches the
     * ERROR must not find the key in the local set, where the reentrancy
     * fast path would report a claim that has no shared row.
     * ---------------------------------------------------------------- */
    PG_TRY();
    {
        LWLockAcquire(plock, LW_EXCLUSIVE);
    }
    PG_CATCH();
    {
        if (!pre_staged)
            xclaim_local_drop(added);
        PG_RE_THROW();
    }
    PG_END_TRY();

    /* ----------------------------------------------------------------
     * Step 8: combined lookup-or-insert under partition LWLock.
     *
     * Single HASH_ENTER_NULL covers both "find existing" and "insert
     * fresh" semantics:
     *   - returns existing entry pointer with *foundPtr=true if the
     *     key is already in the partition (does not touch contents)
     *   - returns fresh entry with *foundPtr=false if the key is not
     *     present and capacity allows
     *   - returns NULL if not present AND HASH_FIXED_SIZE refuses to
     *     allocate (capacity exhausted).
     *
     * dynahash walks the bucket chain once per call, so a single
     * HASH_ENTER_NULL costs one chain walk regardless of whether the
     * key exists -- exactly the work needed under the partition
     * LWLock.
     *
     * Stale-reap is an in-place overwrite of the existing entry's
     * owner triple. live_capacity is unchanged in that branch (the
     * slot was occupied by the stale owner, now occupied by us). A
     * HASH_REMOVE-then-HASH_ENTER cycle would mutate the live count
     * twice for the same net-zero effect.
     * ---------------------------------------------------------------- */
    new_entry = (XClaimEntry *) hash_search_with_hash_value(XClaimHash,
                                                            lk,
                                                            hashvalue,
                                                            HASH_ENTER_NULL,
                                                            &found);

    if (new_entry == NULL)
    {
        /*
         * Capacity exhaustion: key is not present AND HASH_FIXED_SIZE
         * refuses to allocate. Release the LWLock and drop the local
         * entry of Step 6 BEFORE dispatching capacity policy:
         * `XCLAIM_CAP_ERROR` calls ereport(ERROR).
         */
        LWLockRelease(plock);
        if (!pre_staged)
            xclaim_local_drop(added);
        return xclaim_handle_capacity_exhaustion(lk);
    }

    if (found)
    {
        /* ------------------------------------------------------------
         * Step 8a: own entry recovered.
         *
         * The shared entry exists AND its owner triple matches our
         * live triple (procno + lxid + token). This covers a local set
         * that lost the entry while the shared row is still ours, which
         * only a defect can cause. Step 6 put the local entry back, so
         * both agree again: return true.
         *
         * We do NOT modify `new_entry` here -- HASH_ENTER_NULL returned
         * the existing entry pointer without touching its contents.
         * ------------------------------------------------------------ */
        if (xclaim_shared_owner_matches_self(new_entry))
        {
            xclaim_local_note_held(added);
            LWLockRelease(plock);
            /* Per-backend stat slot (avoids shared cache-line ping-pong). */
            pg_atomic_fetch_add_u64(
                &XClaimBackendInfos[xclaim_get_current_procno()].reentrant_hits_local,
                1);
            xclaim_local_emit_peak_warning();
            return true;
        }

        /* ------------------------------------------------------------
         * Step 8b: different owner -- conflict OR stale-reap.
         *
         * Lazy stale-owner reaper: if the owner is dead/reused/token-
         * stale, take over the slot in place. Otherwise it is a
         * logical conflict: return false without modifying the entry.
         *
         * Both decisions are linearizable under the same partition
         * LWLock: a concurrent backend either observes the old owner
         * (before this branch released the lock) or our new owner
         * triple (after Step 10 populate + release).
         * ------------------------------------------------------------ */
        if (xclaim_is_stale_owner(new_entry))
        {
            /*
             * Stale-reap in place: the entry stays, but we overwrite
             * its owner triple below in Step 10. live_capacity is
             * unchanged (one occupant replaced another, net zero).
             */
            pg_atomic_fetch_add_u64(&XClaimCtl->reaped_stale, 1);
            /* fall through to Step 10 populate */
        }
        else
        {
            /*
             * LINEARIZATION POINT (conflict): the lock release below
             * publishes the "we did not modify the row" decision.
             * HASH_ENTER_NULL did not allocate -- it returned the
             * existing pointer -- so the shared side needs no rollback.
             * The local entry of Step 6 goes away after the release.
             */
            LWLockRelease(plock);
            if (!pre_staged)
                xclaim_local_drop(added);
            /* Per-backend stat slot (avoids shared cache-line ping-pong). */
            pg_atomic_fetch_add_u64(
                &XClaimBackendInfos[xclaim_get_current_procno()].conflicts_local,
                1);
            return false;
        }
    }
    else
    {
        /*
         * Fresh insert (`!found`): track live entry count for the
         * capacity-watermark hot path. This scalar insert pairs its
         * increment with the SUB of the xact-callback cleanup. (The BULK
         * path adds its inserts at each partition lock release and its
         * PG_CATCH subtracts what it had added -- see
         * xclaim_try_many_internal.) The atomic load by the watermark
         * check is then a single-cache-line read instead of a
         * num_partitions-wide hash walk.
         */
        pg_atomic_fetch_add_u64(&XClaimCtl->live_capacity, 1);
    }

    /* ----------------------------------------------------------------
     * Step 10: populate the shared XClaimEntry.
     *
     * Field order matches the struct declaration in
     * pg_xclaim_internal.h. The owner triple (procno + lxid + token)
     * is saved at acquisition time and is NEVER re-read from MyProc
     * at cleanup time. owner_pid is debug/display only.
     *
     * `dynahash` does not zero entries on HASH_ENTER, so we must
     * populate every consumed field explicitly.
     * ---------------------------------------------------------------- */
    {
        int32                   procno;
        LocalTransactionId      lxid;
        uint64                  token;

        xclaim_capture_acquisition_identity(&procno, &lxid, &token);

        /* `key` is already populated by dynahash via HASH_BLOBS. */
        new_entry->owner_pid     = MyProcPid;
        new_entry->owner_procno  = procno;
        new_entry->owner_lxid    = lxid;
        new_entry->owner_token   = token;
        new_entry->lifetime_kind = XCLAIM_LIFETIME_XACT;
    }

    /* ----------------------------------------------------------------
     * Step 12: success.
     *
     * LINEARIZATION POINT: the `LWLockRelease` immediately below is
     * the moment another backend can observe our newly-inserted row.
     * Every state mutation (local insert + shared insert) is atomic
     * with respect to other backends as of this release.
     *
     * The Step 6 entry is recorded as held right before releasing the
     * partition lock, and after the release we increment `total_acquires`,
     * publish the peak and write any pending messages of the call. These
     * touch only backend-local state and atomic counters.
     * ---------------------------------------------------------------- */
    xclaim_local_note_held(added);
    LWLockRelease(plock);

    /* Per-backend stat slot (avoids shared cache-line ping-pong). */
    pg_atomic_fetch_add_u64(
        &XClaimBackendInfos[xclaim_get_current_procno()].total_acquires_local,
        1);

    /*
     * Update the global per-backend peak high-water-mark. CAS loop bounded
     * by the (rare) case of a higher backend's concurrent update. It never
     * spins when our local count is below the published peak. The local
     * count is single-threaded in the leader (parallel workers rejected
     * upstream).
     */
    {
        uint64 cur_local = xclaim_local_count();
        uint64 prev_peak;
        do {
            prev_peak = pg_atomic_read_u64(&XClaimCtl->peak_per_backend);
            if (cur_local <= prev_peak)
                break;
        } while (!pg_atomic_compare_exchange_u64(&XClaimCtl->peak_per_backend,
                                                 &prev_peak, cur_local));
    }

    /*
     * Messages last. Writing one ends with CHECK_FOR_INTERRUPTS() in
     * errfinish(), and a cancel processed there finds every counter of
     * this call updated. xclaim_check_capacity_watermark reads
     * live_capacity from its own atomic and ignores its argument.
     */
    xclaim_local_emit_peak_warning();
    xclaim_check_capacity_watermark(0);

    return true;
}

/* =====================================================================
 * Bulk API (xclaim.try_many).
 *
 * Per-element semantics are identical to scalar xclaim.try, and the result
 * boolean[] preserves input order. Pre-sort by partition_id so the inner
 * loop acquires each partition LWLock at most once per partition when a
 * partition's freshly staged keys fit in `max_claims + 64` (a chunk split or
 * a WARN-mode capacity miss releases the lock mid-partition so the next
 * unresolved slot re-acquires it -- still linear in input size). At default
 * num_partitions=128 that is ~128 LWLock cycles for 750k keys vs 750k cycles
 * for the scalar API -- ~5860x reduction.
 *
 * Catastrophic rollback:
 *   - The acquisition path is all-or-nothing ONLY for
 *     CATASTROPHIC errors (palloc OOM, capacity ERROR mode, etc.). On
 *     such errors we MUST roll back any shared inserts already made
 *     before re-throwing. Logical conflicts (per-element FALSE) are
 *     normal and DO NOT trigger rollback.
 *
 * Memory:
 *   - Working buffers (XClaimBulkSlot[], result bool[]) are palloc'd
 *     into the current memory context (per-call) and vanish when the
 *     fmgr call frame unwinds. Local-set bucket arrays live inside
 *     XClaimLocalContext (HARD invariant) via xclaim_local_stage.
 *
 * MUST-CHECK invariants ENFORCED BY THE ENTRY POINTS
 * (xclaim_try_many_solo / xclaim_try_many_pair) BEFORE calling this
 * driver, and re-asserted here at the relevant code sites:
 *   - HASH_BLOBS: memset before each XClaimKey build (per slot) is
 *     done by the entry points (see the per-element loop in
 *     xclaim_try_many_solo / xclaim_try_many_pair).
 *   - PARALLEL RESTRICTED & kill switch: both public entry points reject
 *     IsParallelWorker() and short-circuit enabled=off (returning an array
 *     of trues without touching shared state) before calling this driver.
 *   - capacity dispatch per slot (error/warn) is applied here on
 *     HASH_ENTER_NULL miss.
 *   - reentrancy fast-path per slot via xclaim_local_stage
 *     (XCLAIM_STAGE_ALREADY_HELD) happens here in Phase A.
 *   - one watermark check after the loop, once every partition lock is
 *     released (live_capacity moves only at the lock releases).
 * ===================================================================== */

/*
 * XClaimBulkSlot
 *      Per-element working state for the bulk loop. The original input
 *      index is preserved across the bucket sort so the result bool[]
 *      can be written back at orig_index regardless of the
 *      partition-sorted processing order.
 */
typedef struct XClaimBulkSlot
{
    int32       orig_index;     /* original position in input array */
    uint32      hashvalue;      /* dynahash hash of key             */
    uint32      partition_id;   /* hashvalue & (num_partitions - 1) */
    XClaimKey   key;            /* MUST be memset before populate   */
    uint8       needs_probe;    /* 1 if Phase B must probe shared   */
    uint8       owns_stage;     /* 1 if Phase A freshly staged key  */
} XClaimBulkSlot;

/*
 * Bulk-rollback tracker: when a catastrophic error fires mid-bulk, we
 * must HASH_REMOVE every shared row inserted by the SUCCESSFUL slots
 * before re-throwing. Slots are processed in ascending partition_id
 * order, so `inserted[]` is naturally sorted by partition_id as well.
 */
typedef struct XClaimBulkInserted
{
    XClaimKey   key;
    uint32      hashvalue;
    uint32      partition_id;
    uint8       was_pre_staged; /* 1 if an outer call staged this key */
    uint8       was_reaped;     /* 1 if acquired via stale-owner reap */
} XClaimBulkInserted;

StaticAssertDecl(sizeof(XClaimBulkSlot) >= sizeof(XClaimBulkInserted),
                 "MaxAllocSize check on XClaimBulkSlot must bound XClaimBulkInserted");

/*
 * xclaim_bulk_bucket_sort
 *      Counting (bucket) sort of `slots[0..nslots)` by `partition_id`.
 *      Stable within partition (ascending orig_index order is preserved
 *      by the placement pass).
 *
 *      The keyspace is bounded to num_partitions, so total work is
 *      O(N + num_partitions). Beats qsort O(N log N) for large N with
 *      bounded partition_id.
 *
 *      Memory: scratch + bucket arrays come from CurrentMemoryContext
 *      (the fmgr per-call frame), pfree'd before return.
 */
static void
xclaim_bulk_bucket_sort(XClaimBulkSlot *slots, int nslots)
{
    int                 num_parts = XClaimCtl->num_partitions;
    uint32             *bucket_counts;
    uint32             *bucket_cursor;
    XClaimBulkSlot     *scratch;
    uint32              acc;
    int                 b;
    int                 i;

    Assert(slots != NULL || nslots == 0);
    Assert(num_parts > 0);

    if (nslots <= 1)
        return;

    bucket_counts = (uint32 *) palloc0((Size) num_parts * sizeof(uint32));
    bucket_cursor = (uint32 *) palloc((Size) num_parts * sizeof(uint32));
    scratch       = (XClaimBulkSlot *) palloc((Size) nslots * sizeof(XClaimBulkSlot));

    /* Pass 1: count entries per partition. */
    for (i = 0; i < nslots; i++)
    {
        int bucket = (int) slots[i].partition_id;
        Assert(bucket >= 0 && bucket < num_parts);
        bucket_counts[bucket]++;
    }

    /* Pass 2: exclusive prefix sum -> per-partition starting offset. */
    acc = 0;
    for (b = 0; b < num_parts; b++)
    {
        bucket_cursor[b] = acc;
        acc += bucket_counts[b];
    }
    Assert(acc == (uint32) nslots);

    /* Pass 3: stable placement into partition order. */
    for (i = 0; i < nslots; i++)
    {
        int bucket = (int) slots[i].partition_id;
        scratch[bucket_cursor[bucket]++] = slots[i];
    }

    memcpy(slots, scratch, (Size) nslots * sizeof(XClaimBulkSlot));

    pfree(scratch);
    pfree(bucket_cursor);
    pfree(bucket_counts);
}

/*
 * xclaim_bulk_rollback_inserted
 *      Catastrophic-rollback helper. Removes every shared entry recorded
 *      in `inserted[0..count)` grouped by partition_id (at most
 *      num_partitions LWLock cycles) after verifying saved owner identity,
 *      decrements live_capacity for every removed row whose capacity was
 *      already published (`was_reaped` or `j < flushed_count`), and either
 *      demotes pre-staged local entries back to XCLAIM_LOCAL_STAGED (so an
 *      outer try_many keeps its staged slot) or removes owned local entries.
 */
static void
xclaim_bulk_rollback_inserted(XClaimBulkInserted *inserted, uint32 count,
                              uint32 flushed_count,
                              int32 owner_procno,
                              LocalTransactionId owner_lxid,
                              uint64 owner_token)
{
    uint32 i = 0;
    uint64 removed_capacity = 0;

    while (i < count)
    {
        uint32  run_start = i;
        uint32  pid = inserted[i].partition_id;
        LWLock *plock = &XClaimPartitionLocks[pid].lock;
        uint32  j;

        while (i < count && inserted[i].partition_id == pid)
            i++;

        LWLockAcquire(plock, LW_EXCLUSIVE);
        for (j = run_start; j < i; j++)
        {
            XClaimEntry *shared;
            bool         found;

            shared = (XClaimEntry *) hash_search_with_hash_value(
                XClaimHash,
                &inserted[j].key,
                inserted[j].hashvalue,
                HASH_FIND,
                &found);

            if (found &&
                shared->owner_procno == owner_procno &&
                shared->owner_lxid   == owner_lxid &&
                shared->owner_token  == owner_token)
            {
                (void) hash_search_with_hash_value(XClaimHash,
                                                   &inserted[j].key,
                                                   inserted[j].hashvalue,
                                                   HASH_REMOVE,
                                                   NULL);
                if (inserted[j].was_reaped || j < flushed_count)
                    removed_capacity++;
            }
        }
        LWLockRelease(plock);

        for (j = run_start; j < i; j++)
        {
            if (inserted[j].was_pre_staged)
                xclaim_local_demote_to_staged(&inserted[j].key,
                                              inserted[j].hashvalue);
            else
                xclaim_local_remove(&inserted[j].key);
        }
    }

    if (removed_capacity > 0)
        pg_atomic_fetch_sub_u64(&XClaimCtl->live_capacity, removed_capacity);
}

/*
 * xclaim_try_many_internal
 *      Common driver for both xclaim_try_many_solo and xclaim_try_many_pair.
 *      Caller has already populated `slots[i].key` (memset'd, fields
 *      assigned), `slots[i].hashvalue`, `slots[i].partition_id`, and
 *      `slots[i].orig_index` after rejecting any NULL array elements with
 *      ERRCODE_NULL_VALUE_NOT_ALLOWED.
 *
 *      Writes a true/false result for every slot into
 *      `result_values[orig_index]` with `result_nulls[orig_index]` set to
 *      false, so the caller can construct the output Postgres array via
 *      construct_md_array preserving input dimensions and lower bounds.
 */
/*
 * Adds the fresh rows inserted under the partition lock held now to
 * live_capacity and records how far into inserted[] that publication
 * covers. Runs before every LWLockRelease of the bulk loop.
 */
#define XCLAIM_BULK_FLUSH_CAPACITY() \
    do { \
        if (pending_capacity > 0) \
        { \
            pg_atomic_fetch_add_u64(&XClaimCtl->live_capacity, \
                                    (uint64) pending_capacity); \
            pending_capacity = 0; \
        } \
        inserted_flushed_count = inserted_count; \
    } while (0)

static void
xclaim_try_many_internal(XClaimBulkSlot *slots, int nslots,
                         bool *result_values, bool *result_nulls)
{
    /*
     * PG_TRY/PG_CATCH is implemented via sigsetjmp/siglongjmp. C99
     * 7.13.2.1 says non-volatile automatic variables modified between
     * setjmp and longjmp have indeterminate values after the longjmp.
     * Every local mutated inside PG_TRY and read from PG_CATCH or after
     * PG_END_TRY is marked volatile.
     */
    XClaimBulkInserted      * volatile inserted = NULL;
    volatile uint32          inserted_count = 0;
    volatile int             max_staged_end = 0;
    LWLock                  * volatile current_plock = NULL;
    volatile bool            have_partition_lock = false;
    volatile int32           call_procno = 0;
    volatile LocalTransactionId call_lxid = InvalidLocalTransactionId;
    volatile uint64          call_token = 0;
    int                      procno;            /* cached for per-slot stat slot */
    uint64                   bulk_target;

    volatile bool            saved_warn_active     = false;
    volatile bool            saved_warn_emitted    = false;
    volatile int             saved_warn_suppressed = 0;

    volatile uint32          pending_capacity = 0;
    volatile uint32          inserted_flushed_count = 0;
    volatile uint32          total_inserted = 0;    /* fresh rows of this call */
    volatile uint64          acquires = 0;          /* per-backend stat deltas, */
    volatile uint64          reentrant_hits = 0;    /* added once after the loop */
    volatile uint64          conflicts = 0;

    Assert(xclaim_enabled);
    Assert(nslots > 0);
    Assert(slots != NULL);
    Assert(result_values != NULL);
    Assert(result_nulls != NULL);

    xclaim_local_init();
    procno = xclaim_get_current_procno();

    /*
     * Pre-sort by partition_id (mandatory). Bounds LWLock cycles to
     * <= num_partitions on normal runs within `max_claims + 64` freshly
     * staged keys per partition (with extra cycles only at chunk boundaries
     * or WARN-mode capacity misses). Counting sort is O(N + num_partitions).
     */
    xclaim_bulk_bucket_sort(slots, nslots);

    /*
     * Check shrink state and compute any deferred post-shrink re-expansion
     * target before the first partition run without allocating upfront.
     */
    bulk_target = xclaim_local_prepare_bulk((uint64) nslots);

    inserted = (XClaimBulkInserted *) palloc(sizeof(XClaimBulkInserted) * (Size) nslots);

    saved_warn_active      = xclaim_bulk_warn_context_active;
    saved_warn_emitted     = xclaim_bulk_warn_emitted_this_call;
    saved_warn_suppressed  = xclaim_bulk_warn_suppressed_count;

    xclaim_bulk_warn_context_active     = true;
    xclaim_bulk_warn_emitted_this_call  = false;
    xclaim_bulk_warn_suppressed_count   = 0;

    PG_TRY();
    {
        int         run_start = 0;
        int         stage_budget = (xclaim_max_claims <= PG_INT32_MAX - 64)
                                   ? (xclaim_max_claims + 64)
                                   : PG_INT32_MAX;
        int32       tmp_procno;
        LocalTransactionId tmp_lxid;
        uint64      tmp_token;

        /*
         * Ensure owner_token inside the try_many scope so no emit_log_hook
         * before this point can call xclaim.session_reset() and rotate it.
         */
        xclaim_ensure_owner_token();
        xclaim_capture_acquisition_identity(&tmp_procno, &tmp_lxid, &tmp_token);
        call_procno = tmp_procno;
        call_lxid   = tmp_lxid;
        call_token  = tmp_token;

        while (run_start < nslots)
        {
            uint32  pid = slots[run_start].partition_id;
            int     run_end = run_start + 1;
            int     chunk_start;

            while (run_end < nslots && slots[run_end].partition_id == pid)
                run_end++;

            chunk_start = run_start;
            while (chunk_start < run_end)
            {
                int     chunk_end = chunk_start;
                int     chunk_staged_end = chunk_start;
                int     fresh_staged = 0;
                int     need_lock_first = -1;
                bool    had_non_acquired = false;
                int     b_cur;
                int     j;

                /*
                 * Phase A (no LWLock held): check interrupts and pre-stage at
                 * most `stage_budget` freshly staged keys of this partition
                 * run into XClaimLocalSet. xclaim_local_stage reserves room
                 * only when a distinct new key approaches grow_threshold, so
                 * repeating already-held keys never enlarges the bucket array.
                 * On normal workloads (fresh keys per partition <=
                 * max_claims + 64) the entire partition run forms one chunk,
                 * while capping `fresh_staged` prevents huge calls against a
                 * tiny `max_claims` table from bloating `XClaimLocalSet`.
                 */
                CHECK_FOR_INTERRUPTS();

                while (chunk_end < run_end && fresh_staged < stage_budget)
                {
                    XClaimBulkSlot  *slot = &slots[chunk_end];
                    int              oi = slot->orig_index;
                    XClaimStageState st;

                    CHECK_FOR_INTERRUPTS();
                    st = xclaim_local_stage(&slot->key,
                                            slot->hashvalue,
                                            slot->partition_id,
                                            &bulk_target);
                    if (st == XCLAIM_STAGE_ALREADY_HELD)
                    {
                        slot->needs_probe = 0;
                        slot->owns_stage  = 0;
                        reentrant_hits++;
                        result_nulls[oi]  = false;
                        result_values[oi] = true;
                    }
                    else if (st == XCLAIM_STAGE_ALREADY_STAGED)
                    {
                        slot->needs_probe = 1;
                        slot->owns_stage  = 0;
                        if (need_lock_first < 0)
                            need_lock_first = chunk_end;
                    }
                    else
                    {
                        slot->needs_probe = 1;
                        slot->owns_stage  = 1;
                        fresh_staged++;
                        chunk_staged_end = chunk_end + 1;
                        max_staged_end   = chunk_staged_end;
                        if (need_lock_first < 0)
                            need_lock_first = chunk_end;
                    }
                    chunk_end++;
                }

                if (need_lock_first < 0)
                {
                    chunk_start = chunk_end;
                    continue;
                }

                /*
                 * Phase B (under partition LWLock): probe/insert into
                 * XClaimHash and promote acquired local entries in O(1) with
                 * zero allocations and zero ereports. In WARN mode a capacity
                 * miss releases the lock, emits/suppresses its WARNING, and
                 * resumes from the next slot of the ALREADY-STAGED chunk
                 * without re-staging, keeping full-table WARN scans O(N).
                 */
                current_plock = &XClaimPartitionLocks[pid].lock;
                b_cur = need_lock_first;
                while (b_cur < chunk_end)
                {
                    int cap_miss_at = -1;

                    if (b_cur > need_lock_first)
                        CHECK_FOR_INTERRUPTS();

                    while (b_cur < chunk_end && !slots[b_cur].needs_probe)
                        b_cur++;
                    if (b_cur >= chunk_end)
                        break;

                    LWLockAcquire(current_plock, LW_EXCLUSIVE);
                    have_partition_lock = true;

                    for (j = b_cur; j < chunk_end; j++)
                    {
                        XClaimBulkSlot   *slot = &slots[j];
                        int               oi = slot->orig_index;
                        XClaimLocalEntry *local_entry;
                        XClaimEntry      *new_entry;
                        bool              found;
                        bool              reaped = false;

                        if (!slot->needs_probe)
                            continue;

                        local_entry = xclaim_local_find_entry(&slot->key,
                                                              slot->hashvalue);
                        Assert(local_entry != NULL);
                        if (unlikely(local_entry == NULL))
                        {
                            result_nulls[oi]  = false;
                            result_values[oi] = false;
                            had_non_acquired  = true;
                            continue;
                        }

                        /* Duplicate key in chunk or acquired by reentrant hook. */
                        if (local_entry->held == XCLAIM_LOCAL_HELD)
                        {
                            reentrant_hits++;
                            result_nulls[oi]  = false;
                            result_values[oi] = true;
                            continue;
                        }

                        new_entry = (XClaimEntry *) hash_search_with_hash_value(
                            XClaimHash,
                            &slot->key,
                            slot->hashvalue,
                            HASH_ENTER_NULL,
                            &found);

                        if (new_entry == NULL)
                        {
                            cap_miss_at = j;
                            had_non_acquired = true;
                            break;
                        }

                        if (found)
                        {
                            if (xclaim_shared_owner_matches_self(new_entry))
                            {
                                xclaim_local_note_held(local_entry);
                                reentrant_hits++;
                                result_nulls[oi]  = false;
                                result_values[oi] = true;
                                continue;
                            }

                            if (xclaim_is_stale_owner(new_entry))
                            {
                                /*
                                 * In-place takeover replaces one occupant
                                 * with another, leaving live_capacity net
                                 * unchanged (no transient decrement).
                                 */
                                reaped = true;
                                pg_atomic_fetch_add_u64(&XClaimCtl->reaped_stale, 1);
                            }
                            else
                            {
                                conflicts++;
                                result_nulls[oi]  = false;
                                result_values[oi] = false;
                                had_non_acquired  = true;
                                continue;
                            }
                        }

                        if (!reaped)
                        {
                            total_inserted++;
                            pending_capacity++;
                        }

                        new_entry->owner_pid     = MyProcPid;
                        new_entry->owner_procno  = local_entry->saved_procno;
                        new_entry->owner_lxid    = local_entry->saved_lxid;
                        new_entry->owner_token   = local_entry->saved_token;
                        new_entry->lifetime_kind = XCLAIM_LIFETIME_XACT;

                        inserted[inserted_count].key            = slot->key;
                        inserted[inserted_count].hashvalue      = slot->hashvalue;
                        inserted[inserted_count].partition_id   = slot->partition_id;
                        inserted[inserted_count].was_pre_staged = !slot->owns_stage;
                        inserted[inserted_count].was_reaped     = reaped ? 1 : 0;
                        inserted_count++;

                        xclaim_local_note_held(local_entry);

                        result_nulls[oi]  = false;
                        result_values[oi] = true;
                        acquires++;
                    }

                    XCLAIM_BULK_FLUSH_CAPACITY();
                    LWLockRelease(current_plock);
                    have_partition_lock = false;

                    if (unlikely(cap_miss_at >= 0))
                    {
                        XClaimBulkSlot *miss_slot = &slots[cap_miss_at];
                        int             miss_oi = miss_slot->orig_index;
                        bool            ok = xclaim_handle_capacity_exhaustion(&miss_slot->key);

                        result_nulls[miss_oi]  = false;
                        result_values[miss_oi] = ok;
                        b_cur = cap_miss_at + 1;
                        continue;
                    }

                    b_cur = chunk_end;
                }

                /*
                 * Phase C (no LWLock held): drop any staged entries of this
                 * chunk that were not promoted (conflicts or WARN misses).
                 */
                if (unlikely(had_non_acquired))
                {
                    for (j = need_lock_first; j < chunk_staged_end; j++)
                    {
                        if (slots[j].owns_stage)
                            xclaim_local_unstage(&slots[j].key,
                                                 slots[j].hashvalue);
                    }
                }
                chunk_start = chunk_end;
            }

            run_start = run_end;
        }

        /* Update the global per-backend peak high-water-mark. */
        {
            uint64 cur_local = xclaim_local_count();
            uint64 prev_peak;
            do {
                prev_peak = pg_atomic_read_u64(&XClaimCtl->peak_per_backend);
                if (cur_local <= prev_peak)
                    break;
            } while (!pg_atomic_compare_exchange_u64(&XClaimCtl->peak_per_backend,
                                                     &prev_peak, cur_local));
        }
    }
    PG_CATCH();
    {
        int k;
        int s_end = max_staged_end;

        xclaim_bulk_warn_context_active    = saved_warn_active;
        xclaim_bulk_warn_emitted_this_call = saved_warn_emitted;
        xclaim_bulk_warn_suppressed_count  = saved_warn_suppressed;

        if (have_partition_lock)
        {
            HOLD_INTERRUPTS();
            LWLockRelease(current_plock);
        }
        /*
         * Roll back inserted shared rows first (which demotes any duplicate or
         * pre-staged entries back to XCLAIM_LOCAL_STAGED), then unstage every
         * slot staged across all chunks of this call (0..max_staged_end) so
         * duplicate keys staged in an earlier chunk/partition and inserted via
         * a second slot in the same call are removed cleanly while keys
         * pre-staged by an enclosing outer call remain XCLAIM_LOCAL_STAGED.
         */
        xclaim_bulk_rollback_inserted(inserted, inserted_count,
                                      inserted_flushed_count,
                                      call_procno, call_lxid, call_token);
        for (k = 0; k < s_end; k++)
        {
            if (slots[k].owns_stage)
                xclaim_local_unstage(&slots[k].key, slots[k].hashvalue);
        }

        PG_RE_THROW();
    }
    PG_END_TRY();

    /*
     * Per-backend stat deltas of this call, one atomic add each (the slot
     * has a single writer, the backend itself).
     */
    if (acquires > 0)
        pg_atomic_fetch_add_u64(&XClaimBackendInfos[procno].total_acquires_local,
                                acquires);
    if (reentrant_hits > 0)
        pg_atomic_fetch_add_u64(&XClaimBackendInfos[procno].reentrant_hits_local,
                                reentrant_hits);
    if (conflicts > 0)
        pg_atomic_fetch_add_u64(&XClaimBackendInfos[procno].conflicts_local,
                                conflicts);

    /*
     * Normal-exit tail summary. If the bulk call hit capacity on more
     * than one slot in WARN mode, emit one consolidating WARNING with
     * the total suppressed count (the first failure already produced
     * a detail WARNING from inside the loop). One WARN at the head +
     * one summary at the tail is enough signal for an operator while
     * keeping a 1000-slot bulk past capacity from filling the log.
     *
     * Snapshot-then-reset BEFORE ereport. ereport(WARNING) is non-throwing
     * on the current PG branches, but any path that runs CHECK_FOR_INTERRUPTS
     * en route to message emission (statement_timeout, pg_cancel_backend
     * pending at this exact moment) could elevate to ERROR. If that fires
     * with the suppression flag still TRUE, every subsequent capacity
     * exhaustion in this backend's lifetime would silently increment a
     * stale "additional slot(s)" counter and never emit a WARN. Reading
     * the count into a local + zeroing the statics first leaves the
     * backend's WARN-emit machinery in a clean state regardless of how
     * the ereport call returns (or doesn't).
     */
    {
        int suppressed = xclaim_bulk_warn_suppressed_count;

        /* Restore outer-frame statics BEFORE the summary ereport (see
         * the snapshot-then-reset rationale above, extended to the
         * re-entrant case). */
        xclaim_bulk_warn_context_active    = saved_warn_active;
        xclaim_bulk_warn_emitted_this_call = saved_warn_emitted;
        xclaim_bulk_warn_suppressed_count  = saved_warn_suppressed;

        if (suppressed > 0)
            ereport(WARNING,
                    (errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
                     errmsg("pg_xclaim: %d additional slot(s) hit max_claims (%d) "
                            "in this bulk call, per-slot WARNINGs suppressed",
                            suppressed,
                            xclaim_max_claims),
                     errhint("Raise pg_xclaim.max_claims, or inspect "
                             "xclaim.stats().capacity_warnings for the exact "
                             "slot-failure count.")));
    }

    /*
     * The other messages of the call go out last: after every partition
     * lock is released, outside PG_TRY, and after the WARN-suppression
     * scope above is restored, so an ERROR raised while one is written (a
     * cancel processed at the end of errfinish) leaves no state of this
     * call behind. The claims are taken and counted, and the top-level
     * transaction end releases them (a subtransaction that catches the
     * ERROR keeps them until then). live_capacity moved by this call only at the
     * lock releases, so one watermark check here sees every band the call
     * crossed.
     */
    xclaim_local_emit_peak_warning();
    if (total_inserted > 0)
        xclaim_check_capacity_watermark(0);

    /*
     * Free the rollback tracker now that the bulk call has succeeded.
     * Worst-case footprint is sizeof(XClaimBulkInserted) * nslots, up
     * to ~819 MiB at the ~26.8M-slot limit. Reclaiming it eagerly drops
     * the per-call high-water-mark for plpgsql FOR loops or aggregates
     * that drive xclaim.try_many repeatedly before ExprContext reset.
     * PG_CATCH does not need a matching pfree -- PG_RE_THROW unwinds
     * the memory context anyway.
     */
    pfree((void *) inserted);
}

/*
 * xclaim_try_many_result
 *      Builds the boolean[] result of xclaim.try_many in the shape of the
 *      input array `arr`, from `nelems` flat results.
 *
 * deconstruct_array linearises a multi-dimensional input into a flat
 * element vector and the elements are processed in that linear order, so
 * feeding ARR_NDIM/ARR_DIMS/ARR_LBOUND back into construct_md_array
 * reconstructs a result whose i-th flat position corresponds 1:1 with the
 * i-th flat input position. ARRAY[[1,2],[3,4]] comes back as a 2x2 array,
 * aligned with the input for downstream queries.
 *
 * The SQL entry points free every per-call buffer once it is no longer
 * needed (the element vectors, the slots, the result flags, the datums
 * here, a detoasted copy of the input). PostgreSQL would reclaim them at
 * ExprContext reset, but a plpgsql FOR loop or complex aggregate that
 * invokes xclaim.try_many on large arrays many times before the context
 * tears down would accumulate multi-GB peaks. Freeing keeps the per-call
 * high-water-mark to roughly the response array itself.
 */
static ArrayType *
xclaim_try_many_result(ArrayType *arr, int nelems,
                       const bool *result_values, bool *result_nulls)
{
    int16       bool_len;
    bool        bool_byval;
    char        bool_align;
    Datum      *result_datums;
    ArrayType  *result_arr;
    int         i;

    get_typlenbyvalalign(BOOLOID, &bool_len, &bool_byval, &bool_align);
    result_datums = (Datum *) palloc(sizeof(Datum) * nelems);
    for (i = 0; i < nelems; i++)
        result_datums[i] = BoolGetDatum(result_values[i]);

    result_arr = construct_md_array(result_datums, result_nulls,
                                    ARR_NDIM(arr), ARR_DIMS(arr), ARR_LBOUND(arr),
                                    BOOLOID, bool_len, bool_byval, bool_align);
    pfree(result_datums);
    return result_arr;
}

/*
 * xclaim_try_many_disabled_result
 *      Result of xclaim.try_many while pg_xclaim.enabled = off: every element
 *      true, nothing hashed or acquired, disabled_calls counts one per
 *      element.
 */
static ArrayType *
xclaim_try_many_disabled_result(ArrayType *arr, int nelems)
{
    bool       *result_values;
    bool       *result_nulls;
    ArrayType  *result_arr;

    pg_atomic_fetch_add_u64(&XClaimCtl->disabled_calls, (uint64) nelems);

    result_values = (bool *) palloc(sizeof(bool) * nelems);
    result_nulls  = (bool *) palloc0(sizeof(bool) * nelems);
    memset(result_values, true, sizeof(bool) * nelems);

    result_arr = xclaim_try_many_result(arr, nelems, result_values, result_nulls);
    pfree(result_values);
    pfree(result_nulls);
    return result_arr;
}

static void
xclaim_try_many_preflight(void)
{
    CHECK_FOR_INTERRUPTS();

    if (!IsTransactionState())
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("pg_xclaim: xclaim.try_many requires an active transaction state")));

    if (IsParallelWorker())
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("pg_xclaim: xclaim.try_many cannot be called from a parallel worker")));
}

/*
 * xclaim_try_many_solo
 *      SQL: xclaim.try_many(keys int8[]) RETURNS boolean[]
 */
PG_FUNCTION_INFO_V1(xclaim_try_many_solo);

Datum
xclaim_try_many_solo(PG_FUNCTION_ARGS)
{
    ArrayType      *arr;
    Datum          *elements;
    bool           *element_nulls;
    int             nelems;
    int             i;
    XClaimBulkSlot *slots;
    bool           *result_values;
    bool           *result_nulls;
    ArrayType      *result_arr;
    int16           elmlen;
    bool            elmbyval;
    char            elmalign;

    XCLAIM_REQUIRE_INIT();
    xclaim_try_many_preflight();

    if (PG_ARGISNULL(0))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("pg_xclaim: xclaim.try_many array argument must not be NULL")));

    arr = PG_GETARG_ARRAYTYPE_P(0);

    nelems = ArrayGetNItems(ARR_NDIM(arr), ARR_DIMS(arr));
    if ((Size) nelems > MaxAllocSize / sizeof(XClaimBulkSlot))
    {
        PG_FREE_IF_COPY(arr, 0);
        ereport(ERROR,
                (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                 errmsg("pg_xclaim: xclaim.try_many array too large (%d elements)",
                        nelems),
                 errhint("Split the bulk call into chunks of at most %zu elements.",
                         (size_t) (MaxAllocSize / sizeof(XClaimBulkSlot)))));
    }

    /* Empty array -> empty bool[]. */
    if (nelems == 0)
    {
        result_arr = construct_empty_array(BOOLOID);
        PG_FREE_IF_COPY(arr, 0);
        PG_RETURN_ARRAYTYPE_P(result_arr);
    }

    /* int8 elements: pass-by-value on 64-bit, pass-by-ref on 32-bit. */
    get_typlenbyvalalign(INT8OID, &elmlen, &elmbyval, &elmalign);
    deconstruct_array(arr, INT8OID, elmlen, elmbyval, elmalign,
                      &elements, &element_nulls, &nelems);

    for (i = 0; i < nelems; i++)
    {
        if (element_nulls[i])
            ereport(ERROR,
                    (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                     errmsg("pg_xclaim: xclaim.try_many array element "
                            "at position %d is NULL", i + 1),
                     errhint("Filter out NULL elements before calling "
                             "xclaim.try_many, or use xclaim.try for "
                             "single-key acquisition.")));
    }

    if (!xclaim_enabled)
    {
        pfree(elements);
        pfree(element_nulls);
        result_arr = xclaim_try_many_disabled_result(arr, nelems);
        PG_FREE_IF_COPY(arr, 0);
        PG_RETURN_ARRAYTYPE_P(result_arr);
    }

    slots         = (XClaimBulkSlot *) palloc0(sizeof(XClaimBulkSlot) * nelems);
    result_values = (bool *) palloc0(sizeof(bool) * nelems);
    result_nulls  = (bool *) palloc0(sizeof(bool) * nelems);

    for (i = 0; i < nelems; i++)
    {
        slots[i].orig_index = i;

        /*
         * MANDATORY memset before key field assignment (HASH_BLOBS
         * hashes raw bytes including padding bytes).
         */
        memset(&slots[i].key, 0, sizeof(XClaimKey));
        slots[i].key.dbid = MyDatabaseId;
        slots[i].key.form = XCLAIM_FORM_SOLO;
        slots[i].key.k1   = DatumGetInt64(elements[i]);

        /* Compute hashvalue + partition_id while the slot is hot in L1. */
        slots[i].hashvalue    = xclaim_compute_hash(&slots[i].key);
        slots[i].partition_id = xclaim_partition_id_for_hash(slots[i].hashvalue);
    }

    /* The keys are in the slots now. */
    pfree(elements);
    pfree(element_nulls);

    xclaim_try_many_internal(slots, nelems, result_values, result_nulls);

    result_arr = xclaim_try_many_result(arr, nelems, result_values, result_nulls);
    pfree(slots);
    pfree(result_values);
    pfree(result_nulls);
    PG_FREE_IF_COPY(arr, 0);

    PG_RETURN_ARRAYTYPE_P(result_arr);
}

/*
 * xclaim_try_many_pair
 *      SQL: xclaim.try_many(classid int4, objids int4[]) RETURNS boolean[]
 */
PG_FUNCTION_INFO_V1(xclaim_try_many_pair);

Datum
xclaim_try_many_pair(PG_FUNCTION_ARGS)
{
    int32           classid;
    ArrayType      *arr;
    Datum          *elements;
    bool           *element_nulls;
    int             nelems;
    int             i;
    XClaimBulkSlot *slots;
    bool           *result_values;
    bool           *result_nulls;
    ArrayType      *result_arr;
    int16           elmlen;
    bool            elmbyval;
    char            elmalign;

    XCLAIM_REQUIRE_INIT();
    xclaim_try_many_preflight();

    if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("pg_xclaim: xclaim.try_many arguments must not be NULL")));

    classid = PG_GETARG_INT32(0);
    arr     = PG_GETARG_ARRAYTYPE_P(1);

    nelems = ArrayGetNItems(ARR_NDIM(arr), ARR_DIMS(arr));
    if ((Size) nelems > MaxAllocSize / sizeof(XClaimBulkSlot))
    {
        PG_FREE_IF_COPY(arr, 1);
        ereport(ERROR,
                (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                 errmsg("pg_xclaim: xclaim.try_many array too large (%d elements)",
                        nelems),
                 errhint("Split the bulk call into chunks of at most %zu elements.",
                         (size_t) (MaxAllocSize / sizeof(XClaimBulkSlot)))));
    }

    if (nelems == 0)
    {
        result_arr = construct_empty_array(BOOLOID);
        PG_FREE_IF_COPY(arr, 1);
        PG_RETURN_ARRAYTYPE_P(result_arr);
    }

    get_typlenbyvalalign(INT4OID, &elmlen, &elmbyval, &elmalign);
    deconstruct_array(arr, INT4OID, elmlen, elmbyval, elmalign,
                      &elements, &element_nulls, &nelems);

    for (i = 0; i < nelems; i++)
    {
        if (element_nulls[i])
            ereport(ERROR,
                    (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                     errmsg("pg_xclaim: xclaim.try_many array element "
                            "at position %d is NULL", i + 1),
                     errhint("Filter out NULL elements before calling "
                             "xclaim.try_many, or use xclaim.try for "
                             "single-key acquisition.")));
    }

    if (!xclaim_enabled)
    {
        pfree(elements);
        pfree(element_nulls);
        result_arr = xclaim_try_many_disabled_result(arr, nelems);
        PG_FREE_IF_COPY(arr, 1);
        PG_RETURN_ARRAYTYPE_P(result_arr);
    }

    slots         = (XClaimBulkSlot *) palloc0(sizeof(XClaimBulkSlot) * nelems);
    result_values = (bool *) palloc0(sizeof(bool) * nelems);
    result_nulls  = (bool *) palloc0(sizeof(bool) * nelems);

    for (i = 0; i < nelems; i++)
    {
        int32 objid = DatumGetInt32(elements[i]);

        slots[i].orig_index = i;

        memset(&slots[i].key, 0, sizeof(XClaimKey));
        slots[i].key.dbid = MyDatabaseId;
        slots[i].key.form = XCLAIM_FORM_PAIR;
        slots[i].key.k1   = (int64) (((uint64) (uint32) classid << 32) | (uint32) objid);

        slots[i].hashvalue    = xclaim_compute_hash(&slots[i].key);
        slots[i].partition_id = xclaim_partition_id_for_hash(slots[i].hashvalue);
    }

    /* The keys are in the slots now. */
    pfree(elements);
    pfree(element_nulls);

    xclaim_try_many_internal(slots, nelems, result_values, result_nulls);

    result_arr = xclaim_try_many_result(arr, nelems, result_values, result_nulls);
    pfree(slots);
    pfree(result_values);
    pfree(result_nulls);
    PG_FREE_IF_COPY(arr, 1);

    PG_RETURN_ARRAYTYPE_P(result_arr);
}
