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
 *   * `xclaim_check_capacity_watermark`   -- thin call site; body lives
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
 * step; the list below is in EXECUTION order. Two numbering notes that hold
 * for both the scalar and the bulk path:
 *   * Step 5 (hash compute) runs BEFORE Step 4 (reentrancy probe): the hash
 *     is hoisted so the same precomputed value feeds the local-set lookup
 *     and, on miss, the shared insert -- the numeric labels are kept stable
 *     even though Step 5 physically precedes Step 4.
 *   * There is no Step 9: Step 8b falls through directly to Step 10. The gap
 *     is intentional; "Step 9" does not appear anywhere in the body.
 *
 *   Step 1     feature-flag short-circuit + transaction-state + parallel-
 *              worker guards
 *   Step 2     lazy init (local hash + owner_token)
 *   Step 3     key already constructed by caller (entry point); no-op here
 *   Step 5     hashvalue + partition_id compute (one get_hash_value call)
 *   Step 4     reentrancy fast-path -- O(1) local lookup, NO LWLock
 *   Step 4b    single CHECK_FOR_INTERRUPTS (only valid cancel point)
 *   Step 6     stack-only metadata: resolve `plock` from the hash -- no
 *              allocation (the local-set palloc is deferred to Step 11)
 *   Step 7     LWLockAcquire(partition_lock, LW_EXCLUSIVE)
 *   Step 8     combined lookup-or-insert (single HASH_ENTER_NULL under
 *              partition lock; *found distinguishes existing vs fresh;
 *              NULL signals capacity exhaustion on not-found path)
 *   Step 8a    own entry (found && matches_self) -> re-add to local set,
 *              release, return true
 *   Step 8b    conflict (found && !matches_self) -> stale-owner reaper:
 *              if stale, take over via overwrite-in-place at Step 10;
 *              else release + return false
 *   Step 10    populate shared XClaimEntry owner_* fields (saved triple) --
 *              writes fresh-insert slot OR overwrites a stale-reap'd slot
 *   Step 11    LAST FALLIBLE STEP UNDER LOCK -- PG_TRY/PG_CATCH around
 *              `xclaim_local_insert_held` (palloc may ERROR; rollback
 *              shared insert + release + PG_RE_THROW on failure)
 *   Step 12    LWLockRelease (LINEARIZATION POINT) + counter increment
 *
 * HARD invariants enforced here:
 *   * `XCLAIM_REQUIRE_INIT()` is the FIRST executable statement of every
 *     SQL-callable C entry point (the entry points in pg_xclaim.c, NOT this
 *     internal helper -- the macro must run before any code path that could
 *     deref shared state).
 *   * `CHECK_FOR_INTERRUPTS()` ONLY in Step 4b -- never between Step 8
 *     (shared insert) and Step 12. Cancel between shared insert and local
 *     insert would leak the shared entry: the xact callback iterates the
 *     local set to find rows to remove, so an orphaned shared-without-local
 *     entry is invisible to it. Recovery in that scenario relies on the lazy
 *     stale-owner reaper (which can only fire once ANOTHER backend conflicts
 *     on the same key AND the owning backend has since exited or rotated its
 *     owner_token -- it never reaps an entry whose owner backend is still
 *     alive and holding it) or `before_shmem_exit` at backend exit.
 *   * LWLock acquire/release pairing 1:1 -- Step 11 wraps the fallible
 *     allocation in PG_TRY/PG_CATCH and rolls back the shared insert before
 *     PG_RE_THROW, so PostgreSQL's error path always fires LWLockRelease.
 *   * Linearization point = `LWLockRelease` at Step 12 (success) or Step 8b
 *     (conflict) -- documented inline.
 *   * Capacity exhaustion is NOT logical conflict: default mode is
 *     `ereport(ERROR, ERRCODE_CONFIGURATION_LIMIT_EXCEEDED)`.
 *   * The stale-owner reaper is invoked LAZILY on the conflict path
 *     (Step 8b). If `xclaim_is_stale_owner()` returns true the entry's
 *     owner triple is overwritten in place at Step 10 under the SAME
 *     partition lock (linearizes correctly; no HASH_REMOVE+HASH_ENTER
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
#include "utils/array.h"                /* deconstruct_array, construct_array */
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

/* -------------------------------------------------------------------- */
/* xclaim_handle_capacity_exhaustion                                    */
/*                                                                      */
/* 2-mode dispatch on pg_xclaim.on_capacity_exhaustion. Caller has      */
/* already released the partition LWLock; this function does not touch */
/* the shared dynahash.                                                 */
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
             * pg_try_advisory_xact_lock); a caller would treat the false as
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
             * In the bulk path, subsequent slot failures within the
             * same xclaim.try_many call have their ereport suppressed
             * (see xclaim_bulk_warn_* statics at the top of this TU).
             * The slot-failure COUNTER still increments unconditionally
             * -- xclaim.stats().capacity_warnings remains exact for
             * sizing-pressure observability.
             */
            pg_atomic_fetch_add_u64(&XClaimCtl->capacity_warnings, 1);

            if (xclaim_bulk_warn_context_active &&
                xclaim_bulk_warn_emitted_this_call)
            {
                /*
                 * Detail WARNING for THIS bulk call already fired.
                 * Tally for the post-loop summary; stay quiet.
                 */
                xclaim_bulk_warn_suppressed_count++;
                return false;
            }

            ereport(WARNING,
                    (errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
                     errmsg("pg_xclaim: max_claims (%d) exhausted; "
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
    uint32              hashvalue;
    uint32              partition_id;
    LWLock             *plock;
    XClaimEntry        *new_entry;
    bool                found;

    Assert(lk != NULL);
    Assert(lk->form == XCLAIM_FORM_SOLO || lk->form == XCLAIM_FORM_PAIR);

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
    if (!xclaim_enabled)
    {
        pg_atomic_fetch_add_u64(&XClaimCtl->disabled_calls, 1);
        return true;
    }

    if (!IsTransactionState())
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("pg_xclaim: xclaim.try requires an active transaction state")));

    if (IsParallelWorker())
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("pg_xclaim: xclaim.try cannot be called from a parallel worker")));

    /* ----------------------------------------------------------------
     * Step 2: lazy + idempotent init. Both helpers are no-op after the
     * first call so the steady-state cost is two comparisons. (Xact
     * callbacks and before_shmem_exit hooks are installed once in
     * _PG_init, before any backend reaches an SQL entry point.)
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
     * hash_bytes(bytes, size); simplehash's SH_HASH_KEY hashes the
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
     * claim; we are reaffirming.
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
     * Step 4b: single cancel point.
     *
     * `CHECK_FOR_INTERRUPTS()` ONLY here -- after the reentrancy
     * fast-path and BEFORE any shared-state mutation. Placing it
     * between Step 8 (shared insert) and Step 11 (local insert)
     * would leave the shared entry orphaned on cancel: the xact
     * callback's cleanup walks the LOCAL SET, so a shared-without-
     * local row is invisible to it. Recovery in that case relies on
     * the lazy stale-owner reaper -- which cannot fire while THIS
     * backend is still alive and owns the token, so it only helps
     * after the backend exits or rotates its owner_token -- or on
     * `before_shmem_exit` at backend exit. That ordering is forbidden.
     * ---------------------------------------------------------------- */
    CHECK_FOR_INTERRUPTS();

    /* ----------------------------------------------------------------
     * Step 6: stack-only metadata. No allocation -- the local-set
     * `palloc` happens in Step 11, AFTER the shared insert. This
     * ordering is what makes the PG_TRY/PG_CATCH wrap necessary (a
     * palloc-ERROR after the shared insert needs to roll back).
     * ---------------------------------------------------------------- */
    plock = xclaim_partition_lock(hashvalue);
    Assert(plock != NULL);

    /* ----------------------------------------------------------------
     * Step 7: acquire partition LWLock EXCLUSIVE.
     *
     * From here through Step 12 the lock is held. Every code path
     * MUST end with `LWLockRelease(plock)` -- the PG_TRY/PG_CATCH at
     * Step 11 enforces this even on `palloc(... )` -> ERROR.
     * ---------------------------------------------------------------- */
    LWLockAcquire(plock, LW_EXCLUSIVE);

    /* ----------------------------------------------------------------
     * Step 8: combined lookup-or-insert under partition LWLock.
     *
     * Single HASH_ENTER_NULL covers both "find existing" and "insert
     * fresh" semantics:
     *   - returns existing entry pointer with *foundPtr=true if the
     *     key is already in the partition (does not touch contents);
     *   - returns fresh entry with *foundPtr=false if the key is not
     *     present and capacity allows;
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
     * slot was occupied by the stale owner, now occupied by us); a
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
         * refuses to allocate. Release the LWLock BEFORE dispatching
         * capacity policy: `XCLAIM_CAP_ERROR` calls ereport(ERROR),
         * which unwinds through PG_TRY frames -- MUST NOT happen with
         * the partition lock still held.
         */
        LWLockRelease(plock);
        return xclaim_handle_capacity_exhaustion(lk);
    }

    if (found)
    {
        /* ------------------------------------------------------------
         * Step 8a: own entry recovered.
         *
         * The shared entry exists AND its owner triple matches our
         * saved triple (procno + lxid + token). This covers the rare
         * case where the local set lost the entry (e.g. a hypothetical
         * session_reset bug or a missed xact callback) but the shared
         * row is still ours. Re-add to the local set and return true.
         *
         * We do NOT modify `new_entry` here -- HASH_ENTER_NULL returned
         * the existing entry pointer without touching its contents.
         * The `xclaim_local_insert_held` palloc is fallible -- wrap in
         * PG_TRY/PG_CATCH to roll back to a clean state on ERROR. We
         * do NOT remove the shared row in CATCH here because the row
         * was already ours BEFORE this call -- removing on ERROR would
         * silently release a claim we held coming in. Re-throw the
         * error after releasing the lock; the operator sees the
         * palloc-ERROR and the shared row remains owned by us.
         * ------------------------------------------------------------ */
        if (xclaim_shared_owner_matches_self(new_entry))
        {
            PG_TRY();
            {
                xclaim_local_insert_held(lk, hashvalue, partition_id);
            }
            PG_CATCH();
            {
                LWLockRelease(plock);
                PG_RE_THROW();
            }
            PG_END_TRY();

            /*
             * LINEARIZATION POINT (own-entry recovery): the lock release
             * below makes the local-set re-insertion visible-to-caller
             * atomically with the shared row state.
             */
            LWLockRelease(plock);
            /* Per-backend stat slot (avoids shared cache-line ping-pong). */
            pg_atomic_fetch_add_u64(
                &XClaimBackendInfos[xclaim_get_current_procno()].reentrant_hits_local,
                1);
            return true;
        }

        /* ------------------------------------------------------------
         * Step 8b: different owner -- conflict OR stale-reap.
         *
         * Lazy stale-owner reaper: if the owner is dead/reused/token-
         * stale, take over the slot in place. Otherwise it is a
         * logical conflict; return false without modifying the entry.
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
             * existing pointer -- so no rollback needed.
             */
            LWLockRelease(plock);
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
         * increment with a matching SUB at the two scalar HASH_REMOVE
         * sites -- the xact-callback cleanup and this function's own
         * PG_CATCH rollback below. (The BULK rollback helper deliberately
         * does NOT decrement per removed row: its batched end-of-loop
         * flush never ran, so those rows were never added to the counter
         * in the first place -- see xclaim_bulk_rollback_inserted.) The
         * atomic load by the watermark check is then a single-cache-line
         * read instead of a num_partitions-wide hash walk.
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
     * Step 11: commit local -- LAST FALLIBLE STEP UNDER LWLOCK.
     *
     * `xclaim_local_insert_held` does palloc inside
     * MemoryContextSwitchTo(XClaimLocalContext) for the simplehash
     * grow path. palloc can ereport(ERROR) on OOM. If it does, we MUST
     * roll back the shared insert (HASH_REMOVE under same lock) and
     * release the LWLock before re-throwing -- otherwise the shared
     * row leaks until the xact callback fires (which we do not
     * guarantee on ERROR-during-acquisition paths).
     *
     * `PG_RE_THROW` propagates the original error up the elog stack
     * unchanged.
     * ---------------------------------------------------------------- */
    PG_TRY();
    {
        xclaim_local_insert_held(lk, hashvalue, partition_id);
    }
    PG_CATCH();
    {
        (void) hash_search_with_hash_value(XClaimHash,
                                           lk,
                                           hashvalue,
                                           HASH_REMOVE,
                                           NULL);
        pg_atomic_fetch_sub_u64(&XClaimCtl->live_capacity, 1);
        LWLockRelease(plock);

        /*
         * Drop any local entry that landed in XClaimLocalSet before the
         * throw. xclaim_local_insert_held inserts into the simplehash
         * BEFORE its own watermark ereport(LOG) -- if that ereport
         * happens to longjmp (errmsg formatting OOM, QueryCancelPending
         * delivered between the insert and the message emission, or an
         * emit_log_hook that elevates LOG to ERROR), the local entry
         * survives the throw while we have already HASH_REMOVE'd the
         * shared row above. If the caller is a plpgsql block with
         * EXCEPTION WHEN OTHERS, the transaction continues with a ghost
         * local entry whose shared row is gone -- the next reentrancy
         * probe via xclaim_local_lookup returns true (silently
         * "reentrant hit") while a concurrent backend can simultaneously
         * acquire the same key against the empty shared hash, breaking
         * mutual exclusion.
         *
         * xclaim_local_remove is idempotent: if the throw fired BEFORE
         * the local insert (e.g. xcl_local_insert palloc OOM during
         * grow), it is a no-op. The bulk path's xclaim_bulk_rollback_-
         * inserted helper applies the same defense for the same reason.
         */
        xclaim_local_remove(lk);

        PG_RE_THROW();
    }
    PG_END_TRY();

    /* ----------------------------------------------------------------
     * Step 12: success.
     *
     * LINEARIZATION POINT: the `LWLockRelease` immediately below is
     * the moment another backend can observe our newly-inserted row.
     * Every state mutation (shared insert + local insert) is atomic
     * with respect to other backends as of this release.
     *
     * After the release we increment `total_acquires` and feed the
     * watermark trigger; both touch only atomic counters and are not
     * order-sensitive vs other backends.
     * ---------------------------------------------------------------- */
    LWLockRelease(plock);

    {
        /*
         * Per-backend stat slot (avoids shared cache-line ping-pong).
         * xclaim_check_capacity_watermark reads live_capacity from its
         * own atomic and ignores its argument, so we pass 0 to avoid an
         * extra atomic load on the hot path.
         */
        pg_atomic_fetch_add_u64(
            &XClaimBackendInfos[xclaim_get_current_procno()].total_acquires_local,
            1);

        xclaim_check_capacity_watermark(0);
    }

    /*
     * Update the global per-backend peak high-water-mark. CAS loop bounded
     * by the (rare) case of a higher backend's concurrent update; never
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

    return true;
}

/* =====================================================================
 * Bulk API (xclaim.try_many).
 *
 * Per-element semantics identical to scalar xclaim.try; result
 * boolean[] preserves input order; pre-sort by partition_id so the inner
 * loop acquires each partition LWLock at most once per partition in the
 * normal path (a WARN-mode capacity miss releases the lock mid-partition,
 * so a later slot in the same partition re-acquires it -- bounded but not
 * strictly once). At default num_partitions=128 that is ~128 LWLock cycles
 * for 750k keys vs 750k cycles for the scalar API -- ~5860x reduction.
 *
 * Catastrophic rollback:
 *   - "all-or-nothing for the acquisition path" applies ONLY to
 *     CATASTROPHIC errors (palloc OOM, capacity ERROR mode, etc.). On
 *     such errors we MUST roll back any shared inserts already made
 *     before re-throwing. Logical conflicts (per-element FALSE) are
 *     normal and DO NOT trigger rollback.
 *
 * Memory:
 *   - Working buffers (XClaimBulkSlot[], result bool[]) are palloc'd
 *     into the current memory context (per-call); they vanish when the
 *     fmgr call frame unwinds. The local-set entries pallocs land in
 *     XClaimLocalContext (HARD invariant) inside
 *     xclaim_local_insert_held.
 *
 * MUST-CHECK invariants ENFORCED BY THE ENTRY POINTS
 * (xclaim_try_many_solo / xclaim_try_many_pair) BEFORE calling this
 * driver, and re-asserted here at the relevant code sites:
 *   - HASH_BLOBS: memset before each XClaimKey build (per slot) is
 *     done by the entry points (see the per-element loop in
 *     xclaim_try_many_solo / xclaim_try_many_pair).
 *   - PARALLEL RESTRICTED: IsParallelWorker reject (this driver
 *     repeats the check defensively after the kill-switch
 *     short-circuit).
 *   - kill switch: enabled=off returns array of trues with no shared-
 *     state change (handled here).
 *   - capacity dispatch per slot (error/warn) is applied here on
 *     HASH_ENTER_NULL miss.
 *   - reentrancy fast-path per slot via xclaim_local_lookup happens
 *     here in the inner loop.
 *   - watermark check after each successful per-slot insert (and
 *     observability re-checks at end of batch).
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
    bool        is_null_input;  /* defensive: SQL entry points reject
                                 * NULL elements up front, so this is
                                 * always false on the reachable path  */
} XClaimBulkSlot;

/*
 * Bulk-rollback tracker: when a catastrophic error fires mid-bulk, we
 * must HASH_REMOVE every shared row inserted by the SUCCESSFUL slots
 * before re-throwing. The tracker is a parallel array of (key, hash)
 * pairs (we cannot reuse XClaimBulkSlot directly because partition-
 * sorting reorders it; we want a dense list of "rows we own and may
 * need to roll back").
 */
typedef struct XClaimBulkInserted
{
    XClaimKey   key;
    uint32      hashvalue;
} XClaimBulkInserted;

/*
 * xclaim_bulk_bucket_sort
 *      Counting (bucket) sort of `slots[0..nslots)` by `partition_id`,
 *      with NULL-input slots placed at the end. Stable within partition
 *      (ascending orig_index order is preserved by the placement pass).
 *
 *      The keyspace is bounded to num_partitions + 1 (the trailing
 *      bucket holds NULL inputs); total work is O(N + num_partitions).
 *      Beats qsort O(N log N) for large N with bounded partition_id.
 *
 *      Memory: scratch + bucket arrays come from CurrentMemoryContext
 *      (the fmgr per-call frame), pfree'd before return.
 */
static void
xclaim_bulk_bucket_sort(XClaimBulkSlot *slots, int nslots)
{
    int                 num_parts = XClaimCtl->num_partitions;
    int                 num_buckets = num_parts + 1;   /* +1 trailing bucket for NULLs */
    int                 null_bucket = num_parts;
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

    bucket_counts = (uint32 *) palloc0((Size) num_buckets * sizeof(uint32));
    bucket_cursor = (uint32 *) palloc((Size) num_buckets * sizeof(uint32));
    scratch       = (XClaimBulkSlot *) palloc((Size) nslots * sizeof(XClaimBulkSlot));

    /* Pass 1: count entries per bucket. */
    for (i = 0; i < nslots; i++)
    {
        int bucket = slots[i].is_null_input
                     ? null_bucket
                     : (int) slots[i].partition_id;
        Assert(bucket >= 0 && bucket < num_buckets);
        bucket_counts[bucket]++;
    }

    /* Pass 2: exclusive prefix sum -> per-bucket starting offset. */
    acc = 0;
    for (b = 0; b < num_buckets; b++)
    {
        bucket_cursor[b] = acc;
        acc += bucket_counts[b];
    }
    Assert(acc == (uint32) nslots);

    /* Pass 3: stable placement into bucket order. */
    for (i = 0; i < nslots; i++)
    {
        int bucket = slots[i].is_null_input
                     ? null_bucket
                     : (int) slots[i].partition_id;
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
 *      in `inserted[0..count)` under brief partition LWLocks. Used from
 *      PG_CATCH inside the bulk loop body.
 *
 *      Best-effort: does NOT re-throw on per-row HASH_REMOVE miss (a
 *      concurrent reaper could have removed the row -- harmless).
 *
 *      Local-set sync:
 *      ---------------------------------------------------------------
 *      For each rolled-back shared insert we ALSO call
 *      `xclaim_local_remove` to drop the corresponding local entry.
 *      Without this paired remove, slots that successfully completed
 *      Step 11 (`xclaim_local_insert_held`) before a later slot's
 *      catastrophic ERROR would leave a "ghost" local entry whose
 *      shared row was just removed. Subsequent reentrancy fast-path
 *      probes (`xclaim_local_lookup`) would return true for the same
 *      key (because the local entry survived), causing
 *      `xclaim.try` to return true while another backend can ALSO
 *      acquire the same key (the shared row is gone, so the conflict
 *      check passes too). That breaks mutual exclusion.
 *
 *      `xclaim_local_remove` is idempotent: it is a no-op when the
 *      local set is uninitialised OR when the key is absent. For slots
 *      where the failure happened INSIDE `xclaim_local_insert_held`
 *      (Step 11 palloc OOM) the local entry never made it in, so
 *      `xclaim_local_remove` is a no-op. For slots where Step 11
 *      succeeded but a LATER slot triggered a catastrophic ERROR, the
 *      local entry IS present and gets cleared. Net: the local set is
 *      kept consistent with the shared dynahash on every code path.
 *
 *      live_capacity bookkeeping: deliberately omitted here. The
 *      end-of-loop batched ADD never executed (PG_CATCH skipped past
 *      it), so the rows we are now removing were never counted in
 *      live_capacity in the first place -- a counter SUB here would
 *      overshoot. Reap-site SUBs fired earlier at their own call sites
 *      and stay applied because the reaped stale rows are gone for
 *      good. See the long-form analysis at the top of
 *      `xclaim_try_many_internal` for the full case enumeration.
 */
static void
xclaim_bulk_rollback_inserted(XClaimBulkInserted *inserted, uint32 count)
{
    uint32 i;
    for (i = 0; i < count; i++)
    {
        LWLock *plock = xclaim_partition_lock(inserted[i].hashvalue);
        LWLockAcquire(plock, LW_EXCLUSIVE);
        (void) hash_search_with_hash_value(XClaimHash,
                                           &inserted[i].key,
                                           inserted[i].hashvalue,
                                           HASH_REMOVE,
                                           NULL);
        LWLockRelease(plock);

        /*
         * Drop the paired local-set entry (idempotent: no-op when the
         * local insert never happened, e.g. the slot failed inside
         * Step 11's palloc itself). Performed OUTSIDE the partition
         * lock -- xclaim_local_remove only mutates backend-local
         * simplehash state.
         */
        xclaim_local_remove(&inserted[i].key);
    }
}

/*
 * xclaim_try_many_internal
 *      Common driver for both xclaim_try_many_solo and xclaim_try_many_pair.
 *      Caller has already populated `slots[i].key` (memset'd, fields
 *      assigned), `slots[i].is_null_input`, and `slots[i].orig_index`.
 *
 *      Writes a true/false result for every slot into
 *      `result_values[orig_index]` with `result_nulls[orig_index]` left
 *      false. The SQL entry points reject NULL array elements with
 *      ERRCODE_NULL_VALUE_NOT_ALLOWED before this driver runs, so in
 *      practice every reachable slot yields a defined boolean. The driver
 *      still handles `slot->is_null_input` defensively (writing a result
 *      NULL at that position) should a future internal caller populate NULL
 *      slots directly. The caller then constructs the Postgres array via
 *      construct_md_array, honouring the result-NULL bitmap.
 */
static void
xclaim_try_many_internal(XClaimBulkSlot *slots, int nslots,
                         bool *result_values, bool *result_nulls)
{
    int                  i;
    /*
     * PG_TRY/PG_CATCH is implemented via sigsetjmp/siglongjmp. C99
     * 7.13.2.1 says non-volatile automatic variables modified between
     * setjmp and longjmp have indeterminate values after the longjmp.
     * The four locals below are mutated inside PG_TRY and READ from
     * PG_CATCH; they MUST be `volatile` or the compiler is free to
     * keep them in registers / re-order writes such that PG_CATCH
     * sees stale or zero values. (Observed at -O2 with clang on
     * arm64: `inserted_count` came back as 0 inside PG_CATCH,
     * skipping the rollback HASH_REMOVEs entirely; the xact callback
     * then ran cleanup against shared rows that were "supposed" to be
     * gone, double-decrementing live_capacity to a negative value.)
     *
     * `total_inserted` (declared below) is `volatile` for the SAME
     * reason: it is mutated inside PG_TRY (incremented per fresh insert)
     * and the C99 setjmp-clobber rule applies to it as well; the batched
     * live_capacity flush that reads it runs at the tail of the PG_TRY
     * body, but keeping it volatile is the safe, rule-conforming choice
     * for any local crossing the sigsetjmp boundary. `procno` is the one
     * local that is genuinely non-volatile: it is assigned ONCE before
     * the PG_TRY and never read from PG_CATCH, so no clobber hazard
     * applies.
     *
     * `current_pid_marker` is also NOT read from PG_CATCH, but it is
     * declared `volatile` to suppress a GCC -Werror=clobbered
     * false-positive on aarch64 (observed with GCC 13.3 / PG 16
     * build). The single extra stack reload per iteration of the
     * bulk loop is negligible vs the partition-LWLock work that
     * follows it.
     */
    XClaimBulkInserted  * volatile inserted = NULL;
    volatile uint32      inserted_count = 0;
    LWLock              * volatile current_plock = NULL;
    volatile bool        have_partition_lock = false;
    volatile uint32      current_pid_marker;
    int                  procno;            /* cached for per-slot stat slot */

    /*
     * Outer-frame snapshot of the WARN-suppression statics. Restored at
     * normal-exit and PG_CATCH so a re-entrant inner xclaim_try_many
     * call (via an emit_log_hook running plpgsql, for example) cannot
     * leak its end-of-scope state into the outer loop. Volatile because
     * PG_CATCH reads these across the sigsetjmp boundary.
     */
    volatile bool        saved_warn_active     = false;
    volatile bool        saved_warn_emitted    = false;
    volatile int         saved_warn_suppressed = 0;
    /*
     * Batched live_capacity increment. `total_inserted` counts fresh
     * HASH_ENTER_NULL successes during the bulk loop; we add the
     * aggregate to live_capacity exactly ONCE after the loop, avoiding
     * per-slot contention on that cache line.
     *
     * Stale-reap path does the per-call atomic SUB at the reap site
     * (the slot's previous, stale occupant is being dropped from the
     * live count) and then OVERWRITES the entry's owner triple in place
     * in Step 10 -- there is no HASH_REMOVE; the dynahash slot itself
     * never leaves the table. The overwrite is recorded in inserted[]
     * just like a fresh insert and bumps total_inserted, so the batched
     * flush re-adds the slot. Aggregate delta is correct for any
     * reap+insert combination.
     *
     * Rollback path (PG_CATCH) consistency analysis:
     *   - The flush at end-of-loop never runs, so the `inserted_count`
     *     fresh inserts contribute 0 to live_capacity.
     *   - `xclaim_bulk_rollback_inserted` HASH_REMOVE's exactly those
     *     recorded inserts, and they were never counted in live_capacity,
     *     so no counter adjustment is needed for them.
     *   - Reap-side SUBs already fired immediately at each reap site.
     *     The reap is an overwrite-in-place: the SUB drops the stale
     *     occupant from the live count while the dynahash slot stays in
     *     the table. That slot is recorded in inserted[], so rollback
     *     HASH_REMOVE's it here -- which is exactly the removal the SUB
     *     anticipated, now made real.
     *   - For a reap-then-insert slot whose overwrite gets rolled back,
     *     the net hash-state change is "row gone" (-1 live entry: it
     *     existed before the call, rollback removed it) and the net
     *     live_capacity change is "-1" (the SUB at reap; no ADD because
     *     no flush). They match.
     *
     * Net: rollback path itself needs no counter work; the per-reap
     * SUBs and the absent flush cooperate to keep live_capacity in sync
     * with the post-rollback shared-hash state -- PROVIDED that
     * `inserted` and `inserted_count` are observed correctly in
     * PG_CATCH (see the `volatile` declarations above; without them
     * the rollback would run with `inserted_count == 0`, leak the
     * shared rows for the xact callback to find, and the cleanup-side
     * SUB would double-count, driving live_capacity negative).
     */
    volatile uint32      total_inserted = 0;

    Assert(nslots >= 0);
    Assert(slots != NULL || nslots == 0);
    Assert(result_values != NULL || nslots == 0);
    Assert(result_nulls != NULL || nslots == 0);

    current_pid_marker = (uint32) -1;       /* sentinel: no partition active */

    /* enabled=off short-circuit: every non-NULL slot returns true. */
    if (!xclaim_enabled)
    {
        pg_atomic_fetch_add_u64(&XClaimCtl->disabled_calls, (uint64) nslots);
        for (i = 0; i < nslots; i++)
        {
            if (slots[i].is_null_input)
            {
                result_nulls[i]  = true;
                result_values[i] = false;
            }
            else
            {
                result_nulls[i]  = false;
                result_values[i] = true;
            }
        }
        return;
    }

    if (!IsTransactionState())
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("pg_xclaim: xclaim.try_many requires an active transaction state")));

    if (IsParallelWorker())
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("pg_xclaim: xclaim.try_many cannot be called from a parallel worker")));

    if (nslots == 0)
        return;                              /* empty array -> empty result */

    /* Lazy init -- same as scalar xclaim_try_internal Step 2. */
    xclaim_local_init();
    xclaim_ensure_owner_token();

    /*
     * Cache the per-backend stat-slot index once for the whole bulk call.
     * MyProcNumber / pgprocno is stable for the backend's lifetime, so a
     * single read here suffices for every per-slot bump.
     */
    procno = xclaim_get_current_procno();

    /*
     * Step 5 (per-slot hashvalue + partition_id) is performed by the
     * caller (xclaim_try_many_solo / _pair) inline with key population,
     * so each slot is hashed while it is still hot in L1 immediately
     * after the key fields are written. Doing the hash here would
     * force a second full pass over the slots[] array, which costs a
     * gigabyte-scale DDR roundtrip on the maximum-size bulk: the slot
     * count is bounded by MaxAllocSize / sizeof(XClaimBulkSlot) =
     * ~26.8M slots, whose slots[] array is a full 1 GB (> L3 on every
     * supported target). The caller already skipped null slots (their
     * result is NULL); the bucket sort routes them into a dedicated
     * trailing bucket, so they land at the end of the array, and we
     * proceed directly to the partition pre-sort.
     *
     * Pre-sort by partition_id (mandatory). Reduces LWLock cycles to
     * <= num_partitions across the whole bulk. Counting (bucket) sort
     * is O(N + num_partitions); the keyspace is small and bounded so
     * this beats qsort O(N log N) for typical N.
     */
    xclaim_bulk_bucket_sort(slots, nslots);

    /*
     * Allocate the rollback tracker. Worst case: every input becomes a
     * fresh shared insert. We size for that here; unused entries are
     * trivially cheap (we are in CurrentMemoryContext, freed at fmgr
     * unwind anyway).
     */
    inserted = (XClaimBulkInserted *) palloc(sizeof(XClaimBulkInserted) * (Size) nslots);

    /*
     * Enter the WARN-suppression scope. Until the matching restore in
     * the normal-exit or PG_CATCH path below, all WARN-mode capacity
     * exhaustions emit at most ONE detail WARNING for this bulk call
     * (subsequent slots tally into xclaim_bulk_warn_suppressed_count
     * and stay quiet); the post-loop summary then names the total.
     *
     * Save the outer-frame statics BEFORE establishing our own scope,
     * so a re-entrant bulk call (e.g. an emit_log_hook that calls a
     * plpgsql function which itself invokes xclaim.try_many on a
     * disjoint keyspace) restores the outer-frame state on its exit
     * instead of unconditionally zeroing it. Without save/restore, the
     * inner call's reset would leave the outer loop running with
     * `active=false`, un-suppressing the outer's subsequent slot
     * WARNINGs for the rest of its array. The saved_warn_* locals are
     * volatile because PG_CATCH reads them across a sigsetjmp boundary;
     * see C99 section 7.13.2.1.
     */
    saved_warn_active      = xclaim_bulk_warn_context_active;
    saved_warn_emitted     = xclaim_bulk_warn_emitted_this_call;
    saved_warn_suppressed  = xclaim_bulk_warn_suppressed_count;

    xclaim_bulk_warn_context_active     = true;
    xclaim_bulk_warn_emitted_this_call  = false;
    xclaim_bulk_warn_suppressed_count   = 0;

    /*
     * Bulk-loop body wrapped in PG_TRY. Catastrophic ERRORs
     * (palloc OOM, capacity-mode ERROR, etc.) trigger rollback of every
     * shared insert recorded in `inserted[0..inserted_count)`, then
     * PG_RE_THROW. Logical conflicts (per-element false) are NOT errors
     * and DO NOT enter the catch path.
     */
    PG_TRY();
    {
        for (i = 0; i < nslots; i++)
        {
            XClaimBulkSlot     *slot = &slots[i];
            int                 oi   = slot->orig_index;
            XClaimEntry        *new_entry;
            bool                found;
            XClaimLocalEntry   *existing_local = NULL;

            if (slot->is_null_input)
            {
                /*
                 * Defensive NULL-slot handling. The SQL entry points
                 * reject NULL array elements before this driver runs, so
                 * this branch is unreachable from the SQL surface; it
                 * stays as a guard for a hypothetical future internal
                 * caller that populates NULL slots. The bucket sort places
                 * any such slots at the tail, so reaching one means the
                 * non-NULL run is done: write result NULL at orig_index
                 * and release any partition lock still held.
                 */
                if (have_partition_lock)
                {
                    LWLockRelease(current_plock);
                    have_partition_lock = false;
                    current_pid_marker  = (uint32) -1;
                }
                result_nulls[oi]  = true;
                result_values[oi] = false;
                continue;
            }

            /*
             * Step 4 reentrancy fast-path. Lookup is O(1) in the local
             * set; no LWLock held. Reentrant slot returns true without a
             * fresh shared insert (and never enters the rollback list).
             * slot->hashvalue was precomputed in the unpack loop, so
             * we feed it straight into simplehash's _hash variant
             * (saves one hash_bytes pass per slot vs xclaim_local_lookup).
             */
            if (xclaim_local_lookup_with_hash(&slot->key,
                                              slot->hashvalue,
                                              &existing_local))
            {
                /* Per-backend stat slot. */
                pg_atomic_fetch_add_u64(
                    &XClaimBackendInfos[procno].reentrant_hits_local, 1);
                result_nulls[oi]  = false;
                result_values[oi] = true;
                continue;
            }

            /*
             * Acquire the partition LWLock once per partition. If we are
             * already holding the lock for this partition (run of slots
             * with the same partition_id), reuse it; otherwise release
             * the previous and take the new.
             *
             * Cancel point: CHECK_FOR_INTERRUPTS at a partition
             * boundary -- AFTER releasing any prior partition lock,
             * BEFORE acquiring the next one. This is the analog of the
             * scalar API's Step 4b cancel point: at this exact instant
             * we hold no LWLock and have no in-flight shared insert
             * that could be orphaned. A query-cancel here is
             * safe -- PG_CATCH below will run xclaim_bulk_rollback_inserted
             * for already-completed slots and re-throw. Without this,
             * a 750k-key bulk acquire would be uncancellable for the
             * duration of the loop, defeating statement_timeout and
             * pg_cancel_backend.
             *
             * Placement justification: putting CHECK_FOR_INTERRUPTS
             * inside a partition run (between two slots with the same
             * partition_id and the lock continuously held) would still
             * be safe re. shared state (no shared insert is ever
             * mid-flight at the top of the loop iteration), but doing
             * it at partition boundaries minimises the latency of the
             * "next CFI" by piggybacking on the natural lock-cycle
             * gap. For a partition run of N slots we still get at
             * least one CFI per partition transition, which is the
             * cancel-responsiveness we need.
             */
            if (!have_partition_lock || slot->partition_id != current_pid_marker)
            {
                if (have_partition_lock)
                {
                    LWLockRelease(current_plock);
                    have_partition_lock = false;
                    current_pid_marker  = (uint32) -1;
                }

                CHECK_FOR_INTERRUPTS();

                current_plock = xclaim_partition_lock(slot->hashvalue);
                LWLockAcquire(current_plock, LW_EXCLUSIVE);
                have_partition_lock = true;
                current_pid_marker  = slot->partition_id;
            }

            /*
             * Step 8: combined lookup-or-insert. One HASH_ENTER_NULL
             * covers both "find existing" and "insert fresh" semantics
             * under the partition lock. See the analogous block in
             * xclaim_try_internal for the full rationale.
             */
            new_entry = (XClaimEntry *) hash_search_with_hash_value(XClaimHash,
                                                                    &slot->key,
                                                                    slot->hashvalue,
                                                                    HASH_ENTER_NULL,
                                                                    &found);

            if (new_entry == NULL)
            {
                /*
                 * Capacity exhaustion (key absent AND HASH_FIXED_SIZE
                 * refuses to allocate). Release the lock BEFORE
                 * dispatching the GUC behavior (ERROR / WARN) because:
                 *   - ERROR mode: ereport(ERROR) unwinds via PG_CATCH;
                 *     locks must be released first.
                 *   - WARN: just emits WARNING + returns false.
                 */
                LWLockRelease(current_plock);
                have_partition_lock = false;
                current_pid_marker  = (uint32) -1;

                {
                    bool ok = xclaim_handle_capacity_exhaustion(&slot->key);
                    /* ERROR mode never returns; WARN mode returns false. */
                    result_nulls[oi]  = false;
                    result_values[oi] = ok;
                }
                continue;
            }

            if (found)
            {
                /* ----------------------------------------------------
                 * Step 8a: own entry recovered.
                 *
                 * Shared entry exists AND its owner triple matches our
                 * saved triple. Re-add to the local set (palloc inside
                 * the outer PG_TRY frame; failure unwinds via the
                 * top-level PG_CATCH below). We do NOT record this slot
                 * in inserted[] because the shared row was already ours
                 * BEFORE this bulk call -- on PG_CATCH we must NOT
                 * remove it.
                 * ---------------------------------------------------- */
                if (xclaim_shared_owner_matches_self(new_entry))
                {
                    xclaim_local_insert_held(&slot->key,
                                             slot->hashvalue,
                                             slot->partition_id);
                    pg_atomic_fetch_add_u64(
                        &XClaimBackendInfos[procno].reentrant_hits_local, 1);
                    result_nulls[oi]  = false;
                    result_values[oi] = true;
                    continue;
                }

                /* ----------------------------------------------------
                 * Step 8b: different owner -- conflict OR stale-reap.
                 *
                 * Lazy stale-owner reaper. If the previous owner is
                 * dead/reused/token-stale, take over the slot in place
                 * (no HASH_REMOVE+HASH_ENTER cycle; the entry already
                 * exists, we just overwrite its owner triple in Step 10).
                 *
                 * Bookkeeping (stale-reap branch):
                 *   - live_capacity -= 1 immediately. The entry was
                 *     counted before reap (occupied by the dead owner).
                 *     After our overwrite the slot is still occupied,
                 *     but by US, and total_inserted++ adds it back to
                 *     the end-of-loop batched flush. Net at happy-path
                 *     end-of-loop: 0 change. On PG_CATCH (before flush),
                 *     the slot ends up HASH_REMOVE'd from the inserted[]
                 *     walk; live_capacity already -1 from this site so
                 *     the final count correctly reflects "entry gone".
                 *   - inserted[] gets this slot, same as a fresh insert,
                 *     so PG_CATCH rolls it back uniformly.
                 *
                 * Conflict (not stale): no mutation to new_entry; just
                 * return false for this slot. HASH_ENTER_NULL returning
                 * an existing entry did not allocate, so no rollback.
                 * ---------------------------------------------------- */
                if (xclaim_is_stale_owner(new_entry))
                {
                    pg_atomic_fetch_sub_u64(&XClaimCtl->live_capacity, 1);
                    pg_atomic_fetch_add_u64(&XClaimCtl->reaped_stale, 1);
                    /* fall through to Step 10 (overwrite-in-place) */
                }
                else
                {
                    pg_atomic_fetch_add_u64(
                        &XClaimBackendInfos[procno].conflicts_local, 1);
                    result_nulls[oi]  = false;
                    result_values[oi] = false;
                    continue;
                }
            }

            /*
             * Reached on fresh insert (!found) or stale-reap (found &&
             * stale). Both contribute one occupant to the shared hash
             * at end-of-loop: fresh insert was 0 immediate / +1 batched;
             * stale-reap was -1 immediate / +1 batched.
             */
            total_inserted++;

            /* Step 10: populate shared entry's owner triple.
             * Use a distinct local name to avoid shadowing the outer
             * `procno` cached at the top of the bulk driver. */
            {
                int32                   slot_procno;
                LocalTransactionId      lxid;
                uint64                  token;

                xclaim_capture_acquisition_identity(&slot_procno, &lxid, &token);

                new_entry->owner_pid     = MyProcPid;
                new_entry->owner_procno  = slot_procno;
                new_entry->owner_lxid    = lxid;
                new_entry->owner_token   = token;
                new_entry->lifetime_kind = XCLAIM_LIFETIME_XACT;
            }

            /*
             * Record the insert BEFORE the fallible local-set palloc so
             * a palloc-OOM rollback removes the shared row.
             */
            inserted[inserted_count].key       = slot->key;
            inserted[inserted_count].hashvalue = slot->hashvalue;
            inserted_count++;

            /*
             * Step 11: commit local. If this palloc-ERRORs, the outer
             * PG_CATCH rolls back every recorded shared insert (including
             * this one) and re-throws.
             */
            xclaim_local_insert_held(&slot->key,
                                     slot->hashvalue,
                                     slot->partition_id);

            result_nulls[oi]  = false;
            result_values[oi] = true;

            /*
             * Bump total_acquires on the per-backend slot + run watermark
             * check. The watermark check ignores its argument (it reads
             * live_capacity from its own atomic), so we pass 0 to skip an
             * unnecessary atomic load on the per-slot hot path.
             */
            pg_atomic_fetch_add_u64(
                &XClaimBackendInfos[procno].total_acquires_local, 1);
            xclaim_check_capacity_watermark(0);
        }   /* for each slot */

        /*
         * Step 12: release any still-held partition lock at end of
         * batch. The bucket-sorted order means we hold at most ONE lock
         * at a time (the one for the current partition_id run); the
         * trailing release happens here.
         */
        if (have_partition_lock)
        {
            LWLockRelease(current_plock);
            have_partition_lock = false;
        }

        /*
         * Batched live_capacity flush. ONE atomic add for the whole
         * bulk-acquire call, regardless of slot count. Concurrent
         * readers (xclaim.stats(), watermark check) see the live_capacity
         * climb in a single jump at end-of-batch; the slight delay vs
         * per-slot increments has no operational impact (watermark
         * suppression is timestamp-driven, not edge-triggered).
         */
        if (total_inserted > 0)
        {
            pg_atomic_fetch_add_u64(&XClaimCtl->live_capacity,
                                    (uint64) total_inserted);

            /*
             * Final watermark check after the batched flush. The per-slot
             * checks inside the inner loop above read live_capacity from
             * its atomic, and that atomic is only updated by THIS call --
             * so without a post-flush check, a bulk acquire that crosses
             * the 80/90/95% bands in a single batch never fires a log.
             * One additional call per bulk acquire is negligible.
             */
            xclaim_check_capacity_watermark(0);
        }

        /*
         * Update the global per-backend peak high-water-mark (CAS loop;
         * single-pass per bulk call, not per slot).
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
    }
    PG_CATCH();
    {
        /*
         * Catastrophic rollback. Release any held partition lock
         * first, then HASH_REMOVE every recorded shared insert AND
         * drop the paired local entry for each one. The paired
         * xclaim_local_remove inside xclaim_bulk_rollback_inserted is
         * what keeps mutual exclusion intact: without it, a slot that
         * had already completed Step 11 (xclaim_local_insert_held)
         * before a later slot's failure would leave a ghost local
         * entry whose shared row is now gone, and the next reentrancy
         * probe would silently succeed alongside a fresh acquisition
         * in another backend. The xact callback would also eventually
         * fire on the PG_RE_THROW below, but by then the ghost would
         * already have allowed a duplicate acquire.
         */
        if (have_partition_lock)
            LWLockRelease(current_plock);
        xclaim_bulk_rollback_inserted(inserted, inserted_count);

        /*
         * Restore the outer-frame WARN-suppression scope on the error
         * path. The incoming ERROR is the operator's signal -- no tail
         * summary required (the ERROR already names the failure mode).
         * Restore rather than clear so a re-entrant inner call doesn't
         * truncate the outer call's WARN state.
         */
        xclaim_bulk_warn_context_active    = saved_warn_active;
        xclaim_bulk_warn_emitted_this_call = saved_warn_emitted;
        xclaim_bulk_warn_suppressed_count  = saved_warn_suppressed;

        PG_RE_THROW();
    }
    PG_END_TRY();

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
                            "in this bulk call; per-slot WARNINGs suppressed",
                            suppressed,
                            xclaim_max_claims),
                     errhint("Raise pg_xclaim.max_claims, or inspect "
                             "xclaim.stats().capacity_warnings for the exact "
                             "slot-failure count.")));
    }

    /*
     * Free the rollback tracker now that the bulk call has succeeded.
     * Worst-case footprint is sizeof(XClaimBulkInserted) * nslots, up
     * to ~615 MB at the ~26.8M-slot limit; reclaiming it eagerly drops
     * the per-call high-water-mark for plpgsql FOR loops or aggregates
     * that drive xclaim.try_many repeatedly before ExprContext reset.
     * PG_CATCH does not need a matching pfree -- PG_RE_THROW unwinds
     * the memory context anyway.
     */
    pfree((void *) inserted);
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
    Datum          *result_datums;
    ArrayType      *result_arr;
    int16           elmlen;
    bool            elmbyval;
    char            elmalign;

    XCLAIM_REQUIRE_INIT();

    /*
     * NULL array argument raises ERRCODE_NULL_VALUE_NOT_ALLOWED.
     * Symmetric with the scalar `xclaim.try` overloads (CALLED ON
     * NULL INPUT + explicit body check) so the parity table holds
     * across both surfaces. Silent NULL return would hide programming
     * bugs (e.g. a caller building the array from a query that yields
     * NULL); a loud error surfaces them at the call site.
     */
    if (PG_ARGISNULL(0))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("pg_xclaim: xclaim.try_many array argument must not be NULL")));

    arr = PG_GETARG_ARRAYTYPE_P(0);

    /*
     * Reject oversized arrays BEFORE deconstruct_array(). The element
     * count is read from the array header (ArrayGetNItems is O(ndim),
     * no allocations), so an adversarial caller passing a 50M-element
     * input fails fast with our typed errcode instead of paying for
     * deconstruct_array's element + null buffers (~600 MB at the
     * 50M-element scale) before we ever look at the result. The slot
     * struct dominates the bool and Datum arrays we would allocate
     * downstream per element, so its MaxAllocSize bound is the tightest.
     *
     * On 32-bit builds this guard is also a correctness gate: the
     * Size-typed multiplication sizeof(XClaimBulkSlot) * nelems can
     * wrap below MaxAllocSize for pathological nelems, letting palloc
     * succeed and the per-slot write loop trample past the end of the
     * allocation. Rejecting up front sidesteps the overflow entirely.
     */
    nelems = ArrayGetNItems(ARR_NDIM(arr), ARR_DIMS(arr));
    if ((Size) nelems > MaxAllocSize / sizeof(XClaimBulkSlot))
        ereport(ERROR,
                (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                 errmsg("pg_xclaim: xclaim.try_many array too large (%d elements)",
                        nelems),
                 errhint("Split the bulk call into chunks of at most %zu elements.",
                         (size_t) (MaxAllocSize / sizeof(XClaimBulkSlot)))));

    /* Empty array -> empty bool[]. */
    if (nelems == 0)
    {
        result_arr = construct_empty_array(BOOLOID);
        PG_RETURN_ARRAYTYPE_P(result_arr);
    }

    /* int8 elements: pass-by-value on 64-bit; pass-by-ref on 32-bit. */
    get_typlenbyvalalign(INT8OID, &elmlen, &elmbyval, &elmalign);
    deconstruct_array(arr, INT8OID, elmlen, elmbyval, elmalign,
                      &elements, &element_nulls, &nelems);

    /*
     * Reject NULL ELEMENTS inside an otherwise-valid array. The scalar
     * xclaim.try() form raises loud ERROR on NULL input; the bulk form
     * must be symmetric or the bool_and(ok) idiom recommended in
     * README ("either all locks acquired or treat as conflict") silently
     * passes a partially-NULL result -- bool_and ignores NULL by SQL
     * semantics, so a single NULL element fail-opens the whole bulk
     * call. ERRCODE_NULL_VALUE_NOT_ALLOWED matches the scalar path.
     */
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

    slots         = (XClaimBulkSlot *) palloc0(sizeof(XClaimBulkSlot) * nelems);
    result_values = (bool *) palloc0(sizeof(bool) * nelems);
    result_nulls  = (bool *) palloc0(sizeof(bool) * nelems);

    for (i = 0; i < nelems; i++)
    {
        slots[i].orig_index    = i;
        slots[i].is_null_input = element_nulls[i];

        /*
         * MANDATORY memset before key field assignment (HASH_BLOBS
         * hashes raw bytes including padding bytes).
         */
        memset(&slots[i].key, 0, sizeof(XClaimKey));
        if (!element_nulls[i])
        {
            slots[i].key.dbid = MyDatabaseId;
            slots[i].key.form = XCLAIM_FORM_SOLO;
            slots[i].key.k1   = DatumGetInt64(elements[i]);

            /*
             * Compute hashvalue + partition_id while the slot is still
             * hot in L1. Deferring it to a second O(N) pass in
             * xclaim_try_many_internal would reload the whole slots[]
             * array through DDR for bulk calls whose footprint exceeds
             * L3 (the worst case is ~26.8M slots = MaxAllocSize /
             * sizeof(XClaimBulkSlot), a full 1 GB array -- one extra
             * memory-bandwidth roundtrip just to read partition_ids
             * already implied by the keys). NULL slots intentionally
             * skip the hash math -- their result is NULL and the bucket
             * sort routes them into its trailing bucket, so they land at
             * the end of the array.
             */
            slots[i].hashvalue    = xclaim_compute_hash(&slots[i].key);
            slots[i].partition_id = xclaim_partition_id_for_hash(slots[i].hashvalue);
        }
    }

    xclaim_try_many_internal(slots, nelems, result_values, result_nulls);

    /* Construct boolean[] result, preserving the NULL bitmap. */
    {
        int16   bool_len;
        bool    bool_byval;
        char    bool_align;

        get_typlenbyvalalign(BOOLOID, &bool_len, &bool_byval, &bool_align);
        result_datums = (Datum *) palloc(sizeof(Datum) * nelems);
        for (i = 0; i < nelems; i++)
            result_datums[i] = BoolGetDatum(result_values[i]);

        /*
         * Preserve the input array's shape (ndim / dims / lbounds).
         * deconstruct_array linearises a multi-dimensional input into a
         * flat element vector and we process elements in that linear
         * order, so feeding ARR_NDIM/ARR_DIMS/ARR_LBOUND back into
         * construct_md_array reconstructs a result whose i-th flat
         * position corresponds 1:1 with the i-th flat input position.
         * Without this, ARRAY[[1,2],[3,4]] would come back as a 1-D
         * 4-element array, breaking downstream queries that rely on
         * dimensional alignment with the input.
         */
        result_arr = construct_md_array(result_datums, result_nulls,
                                        ARR_NDIM(arr),
                                        ARR_DIMS(arr),
                                        ARR_LBOUND(arr),
                                        BOOLOID, bool_len, bool_byval, bool_align);

        /*
         * Defense-in-depth pfree for gigabyte-scale per-call
         * allocations. PostgreSQL would reclaim these at ExprContext
         * reset, but a plpgsql FOR loop or complex aggregate that
         * invokes xclaim.try_many on large arrays many times before
         * the context tears down can accumulate multiple multi-GB
         * peaks, triggering OOM on resource-constrained backends.
         * Freeing immediately keeps the per-call high-water-mark to
         * roughly the response array itself. Order does not matter --
         * all five allocations live in CurrentMemoryContext.
         */
        pfree(result_datums);
    }
    pfree(slots);
    pfree(result_values);
    pfree(result_nulls);

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
    Datum          *result_datums;
    ArrayType      *result_arr;
    int16           elmlen;
    bool            elmbyval;
    char            elmalign;

    XCLAIM_REQUIRE_INIT();

    /*
     * NULL classid OR NULL array raises ERRCODE_NULL_VALUE_NOT_ALLOWED.
     * Symmetric with the scalar `xclaim.try` overloads.
     */
    if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("pg_xclaim: xclaim.try_many arguments must not be NULL")));

    classid = PG_GETARG_INT32(0);
    arr     = PG_GETARG_ARRAYTYPE_P(1);

    /* See xclaim_try_many_solo for the rationale; same guard, same
     * pre-deconstruct ordering. */
    nelems = ArrayGetNItems(ARR_NDIM(arr), ARR_DIMS(arr));
    if ((Size) nelems > MaxAllocSize / sizeof(XClaimBulkSlot))
        ereport(ERROR,
                (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                 errmsg("pg_xclaim: xclaim.try_many array too large (%d elements)",
                        nelems),
                 errhint("Split the bulk call into chunks of at most %zu elements.",
                         (size_t) (MaxAllocSize / sizeof(XClaimBulkSlot)))));

    if (nelems == 0)
    {
        result_arr = construct_empty_array(BOOLOID);
        PG_RETURN_ARRAYTYPE_P(result_arr);
    }

    get_typlenbyvalalign(INT4OID, &elmlen, &elmbyval, &elmalign);
    deconstruct_array(arr, INT4OID, elmlen, elmbyval, elmalign,
                      &elements, &element_nulls, &nelems);

    /* See xclaim_try_many_solo for the rationale of this NULL guard. */
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

    slots         = (XClaimBulkSlot *) palloc0(sizeof(XClaimBulkSlot) * nelems);
    result_values = (bool *) palloc0(sizeof(bool) * nelems);
    result_nulls  = (bool *) palloc0(sizeof(bool) * nelems);

    for (i = 0; i < nelems; i++)
    {
        slots[i].orig_index    = i;
        slots[i].is_null_input = element_nulls[i];

        memset(&slots[i].key, 0, sizeof(XClaimKey));
        if (!element_nulls[i])
        {
            int32 objid = DatumGetInt32(elements[i]);
            slots[i].key.dbid = MyDatabaseId;
            slots[i].key.form = XCLAIM_FORM_PAIR;
            slots[i].key.k1   = ((int64) (uint32) classid << 32) | (uint32) objid;

            /* See xclaim_try_many_solo for the cache-locality rationale. */
            slots[i].hashvalue    = xclaim_compute_hash(&slots[i].key);
            slots[i].partition_id = xclaim_partition_id_for_hash(slots[i].hashvalue);
        }
    }

    xclaim_try_many_internal(slots, nelems, result_values, result_nulls);

    {
        int16   bool_len;
        bool    bool_byval;
        char    bool_align;

        get_typlenbyvalalign(BOOLOID, &bool_len, &bool_byval, &bool_align);
        result_datums = (Datum *) palloc(sizeof(Datum) * nelems);
        for (i = 0; i < nelems; i++)
            result_datums[i] = BoolGetDatum(result_values[i]);

        /* See xclaim_try_many_solo for the shape-preservation rationale. */
        result_arr = construct_md_array(result_datums, result_nulls,
                                        ARR_NDIM(arr),
                                        ARR_DIMS(arr),
                                        ARR_LBOUND(arr),
                                        BOOLOID, bool_len, bool_byval, bool_align);

        /* See xclaim_try_many_solo for the OOM-defense rationale. */
        pfree(result_datums);
    }
    pfree(slots);
    pfree(result_values);
    pfree(result_nulls);

    PG_RETURN_ARRAYTYPE_P(result_arr);
}
