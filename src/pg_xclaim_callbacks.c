/*-------------------------------------------------------------------------
 *
 * pg_xclaim_callbacks.c
 *      Xact callback (group-by-partition cleanup) and
 *      `before_shmem_exit` cleanup, with 2PC reject in
 *      `XACT_EVENT_PRE_PREPARE`.
 *
 * Lifecycle contract:
 *
 *   xclaim_xact_callback fires on EVERY top-level xact transition. We
 *   filter to the canonical end-of-transaction events:
 *
 *     XACT_EVENT_COMMIT          -- normal COMMIT
 *     XACT_EVENT_PARALLEL_COMMIT -- parallel-leader COMMIT
 *     XACT_EVENT_ABORT           -- normal ROLLBACK / ERROR-driven abort
 *     XACT_EVENT_PARALLEL_ABORT  -- parallel-leader abort
 *
 *   We do NOT clean on PRE_COMMIT / PRE_PREPARE / PREPARE. Cleanup is
 *   deliberately tied to the post-outcome COMMIT/ABORT callbacks so we
 *   never release a claim before the transaction outcome is known. The
 *   PRE_PREPARE event is used ONLY to reject 2PC (PREPARE TRANSACTION)
 *   when claims are held; the subsequent ABORT re-entry then runs
 *   cleanup.
 *
 *   xclaim_shmem_exit_cb is `before_shmem_exit` -- shared memory and
 *   LWLocks are still live at that point. The xact callback usually
 *   ran first (normal disconnect / FATAL re-driven abort), but on
 *   pathological exit paths cleanup may have been skipped; this hook
 *   is the safety net. It is idempotent with the xact callback (early-
 *   return when local set is empty).
 *
 *   Hard-process-death caveat: SIGKILL/segfault does NOT fire
 *   `before_shmem_exit`. PostgreSQL treats unexpected backend death as
 *   a child crash and crash-restarts shared memory, so ordinary hard
 *   backend death does not leave rows for the lazy reaper. The reaper is
 *   a defensive path for extension-level stale-owner signals (slot reuse
 *   after normal proc cleanup, PID mismatch, token mismatch).
 *
 * 2PC reject:
 *   PREPARE TRANSACTION is incompatible with our xact-scoped cleanup
 *   model -- the prepared transaction's entries would survive backend
 *   exit with no owner to attribute them to, and a subsequent COMMIT
 *   PREPARED would attempt cleanup from a different backend's xact
 *   callback (where MyProcNumber / lxid / owner_token would not match
 *   the saved triple). We reject up front in PRE_PREPARE with
 *   ERRCODE_FEATURE_NOT_SUPPORTED. The ERROR triggers ABORT, which
 *   re-enters the same callback; cleanup runs on that ABORT pass
 *   (idempotent re-entry).
 *
 * Performance contract:
 *   * 50000 claims COMMIT cleanup latency MUST be < 100ms.
 *   * Group-by-partition (delegated to xclaim_local_cleanup_held in
 *     pg_xclaim_local.c) bounds the work to num_partitions LWLock
 *     cycles regardless of claim count -- 128 cycles for the default
 *     pg_xclaim.num_partitions=128 vs 750000 cycles per-key (~5860x
 *     speedup).
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/xact.h"
#include "miscadmin.h"
#include "storage/ipc.h"
#include "utils/elog.h"

#include "pg_xclaim.h"
#include "pg_xclaim_compat.h"           /* xclaim_get_current_procno */
#include "pg_xclaim_internal.h"
#include "pg_xclaim_local.h"

/* -------------------------------------------------------------------- */
/* xclaim_xact_callback                                                 */
/*                                                                      */
/* RegisterXactCallback contract: invoked on every XactEvent. We act    */
/* on five events:                                                      */
/*                                                                      */
/*   PRE_PREPARE                       -> 2PC reject                    */
/*   COMMIT / PARALLEL_COMMIT          -> cleanup                       */
/*   ABORT  / PARALLEL_ABORT           -> cleanup (also the PRE_PREPARE */
/*                                       re-entry path)                 */
/*                                                                      */
/* All other events (PRE_COMMIT / PARALLEL_PRE_COMMIT / PREPARE /       */
/* etc.) are no-ops. Cleanup before the transaction outcome is known    */
/* would release claims too early; using PREPARE (vs PRE_PREPARE) for   */
/* the user-facing reject is also too late -- by then the xact has      */
/* crossed into prepare cleanup paths and the operator gets a much less */
/* actionable error.                                                    */
/* -------------------------------------------------------------------- */

void
xclaim_xact_callback(XactEvent event, void *arg)
{
    (void) arg;

    /*
     * Skip work entirely if the extension never finished initialising
     * (a backend that loaded after a hot-standby promotion, for
     * example). xclaim_state_initialized is flipped to true at the end
     * of xclaim_shmem_startup -- if it is false the local set was never
     * touched, so there is nothing to clean.
     */
    if (!xclaim_state_initialized)
        return;

    switch (event)
    {
        case XACT_EVENT_PRE_PREPARE:
            /*
             * 2PC rejection. PREPARE TRANSACTION cannot coexist with
             * xact-scoped pg_xclaim claims -- the prepared transaction's
             * claims would survive the backend that acquired them, and
             * the eventual COMMIT PREPARED runs in a different backend
             * whose MyProcNumber / lxid / owner_token would never match
             * the saved triple, leaking the shared rows.
             *
             * Raise BEFORE the prepare-cleanup paths run. The ERROR
             * triggers ABORT, which re-enters this callback as
             * XACT_EVENT_ABORT -- the cleanup branch runs idempotently
             * on that re-entry.
             *
             * NOTE: we deliberately keep this event read-only except
             * for ereport(ERROR): xclaim_local_count() and either
             * pass-through (zero held) or reject 2PC.
             */
            if (xclaim_local_count() > 0)
                ereport(ERROR,
                        (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                         errmsg("pg_xclaim: PREPARE TRANSACTION is not allowed while pg_xclaim claims are held"),
                         errhint("Release pg_xclaim claims (or COMMIT/ROLLBACK the transaction) before preparing.")));
            return;

        case XACT_EVENT_COMMIT:
        case XACT_EVENT_PARALLEL_COMMIT:
        case XACT_EVENT_ABORT:
        case XACT_EVENT_PARALLEL_ABORT:
            /*
             * Canonical cleanup path. Group-by-partition gives at most
             * num_partitions LWLock cycles (128 at the default) for any
             * claim count, satisfying the 50k-claims < 100ms acceptance
             * gate.
             *
             * Idempotent: xclaim_local_cleanup_held() early-returns if
             * the local set is empty, so PRE_PREPARE -> ABORT re-entry
             * (which runs cleanup, then before_shmem_exit re-runs the
             * same path) is a no-op on the second pass.
             *
             * MyProc state has already been cleared by
             * ProcArrayEndTransaction() at this point -- the cleanup
             * path uses SAVED owner identity from the local entries,
             * not current MyProc fields, so this is safe.
             */
            xclaim_local_cleanup_held();
            return;

        case XACT_EVENT_PRE_COMMIT:
        case XACT_EVENT_PARALLEL_PRE_COMMIT:
        case XACT_EVENT_PREPARE:
            /*
             * Idempotent no-op. Cleanup before outcome is known would
             * release claims too early; throwing the 2PC ERROR from
             * XACT_EVENT_PREPARE is also too late (the xact has crossed
             * into prepare cleanup).
             */
            return;
    }
}

/* -------------------------------------------------------------------- */
/* xclaim_shmem_exit_cb                                                 */
/*                                                                      */
/* `before_shmem_exit` (NOT on_shmem_exit, NOT on_proc_exit -- HARD     */
/* invariant):                                                          */
/*   * before_shmem_exit: shared memory and LWLocks still live -- safe  */
/*     to acquire partition locks for cleanup.                          */
/*   * on_shmem_exit:    too late, LWLocks may already be torn down.    */
/*   * on_proc_exit:     even later.                                    */
/*                                                                      */
/* On normal disconnect / SIGTERM / FATAL error this fires AFTER the    */
/* xact callback has already cleaned. The local set is empty by then    */
/* and xclaim_local_cleanup_held() returns immediately. Idempotent.     */
/*                                                                      */
/* On hard process death (e.g. SIGKILL/SIGSEGV) this callback does not */
/* fire in the dead backend; PostgreSQL crash-restarts shared memory.  */
/*                                                                      */
/* The lazy stale-owner reaper is therefore a defensive path for       */
/* extension-level stale-owner signals, not the primary hard-crash     */
/* cleanup mechanism. See pg_xclaim_reaper.c for reuse-signal details.*/
/* -------------------------------------------------------------------- */

void
xclaim_shmem_exit_cb(int code, Datum arg)
{
    int procno;

    (void) code;
    (void) arg;

    if (!xclaim_state_initialized)
        return;

    /*
     * Defensive cleanup -- usually a no-op because the xact callback
     * already ran. Idempotent by xclaim_local_cleanup_held()'s
     * early-return when the local set is empty.
     */
    xclaim_local_cleanup_held();

    /*
     * Force-invalidate our published owner_token before releasing the
     * backend slot. Closes a narrow ABA window:
     *
     *   1. This backend's xact callback removed every shared row it
     *      owned; local set is empty.
     *   2. We exit gracefully and our PGPROC slot is freed.
     *   3. A new backend grabs the same procno AND -- on OSes with a
     *      small pid_max and high backend turnover -- coincidentally the
     *      same OS pid. If that backend never invokes pg_xclaim, it
     *      never calls xclaim_ensure_owner_token() and the published
     *      token in our old slot stays at our value.
     *   4. Should any leftover row owned by our OLD token still exist in
     *      shared memory (only possible after an incomplete cleanup path),
     *      the stale-owner reaper would
     *      observe pid_match + token_match and treat the orphan as
     *      live, defeating recovery.
     *
     * Writing 0 (the reserved-invalid token sentinel) into our slot at
     * exit defangs the third signal of xclaim_is_stale_owner: the next
     * conflicting backend's reaper will see published_token == 0 !=
     * entry->owner_token and reap the row. xclaim.session_reset uses
     * the same atomic write for the same reason; this exit-cb mirrors
     * its publication contract for the backend-lifetime boundary.
     *
     * Gate the procno read on MyProc != NULL. `before_shmem_exit` fires
     * in every process that inherited this callback registration via
     * fork() from the postmaster -- including PostgreSQL's auxiliary
     * subprocesses (checkpointer, walwriter, bgwriter, etc.). Those
     * aux procs do not occupy a slot in XClaimBackendInfos[0..MaxBackends),
     * and a process whose MyProc is already NULL (e.g. one exiting before
     * InitProcess, or a re-entrant teardown) has no procno to publish.
     * xclaim_get_current_procno() dereferences MyProc on PG 16; without
     * this guard, an aux-proc shutdown
     * pass would segfault, postmaster would treat it as a child crash
     * and refuse to complete the shutdown sequence, hanging the
     * cluster stop.
     *
     * The same guard also protects against an extremely late teardown
     * where XClaimBackendInfos is mid-detach; observability over
     * correctness, but free.
     */
    if (MyProc == NULL || XClaimBackendInfos == NULL)
        return;

    procno = (int) xclaim_get_current_procno();
    if (procno >= 0 && procno < MaxBackends)
        pg_atomic_write_u64(&XClaimBackendInfos[procno].current_token, 0);
}
