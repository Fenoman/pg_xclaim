/*-------------------------------------------------------------------------
 *
 * pg_xclaim_callbacks.c
 *      Xact callback (group-by-partition cleanup) and
 *      `on_shmem_exit` backend-exit cleanup, with 2PC reject in
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
 *   when claims are held. The subsequent ABORT re-entry then runs
 *   cleanup.
 *
 *   xclaim_shmem_exit_cb is an `on_shmem_exit` callback. Each backend
 *   registers it on its first claim (xclaim_ensure_owner_token()),
 *   because in fork-based builds InitPostmasterChild() clears the
 *   exit-callback lists a backend would otherwise inherit from the
 *   postmaster. It runs after every before_shmem_exit callback, so
 *   ShutdownPostgres has already aborted a transaction left open at
 *   exit and the xact callback has released its claims. It runs before
 *   ProcKill(), which InitProcess() registered earlier, so MyProc and
 *   the partition LWLocks are still usable. It releases the claims that
 *   abort did not: when a sibling extension's xact callback called
 *   ahead of ours raises ERROR in it, the ERROR becomes FATAL during
 *   exit and skips the rest of the chain. It then invalidates the
 *   backend's published owner_token. It is idempotent with the xact
 *   callback (early return when the local set is empty).
 *
 *   A failing sibling callback does not leave claims behind in a
 *   running backend: PostgreSQL aborts the transaction and calls every
 *   xact callback again with XACT_EVENT_ABORT, or, when the transaction
 *   has an xid and the failure hit XACT_EVENT_COMMIT, ends in PANIC.
 *
 *   Hard-process-death caveat: SIGKILL/segfault does NOT fire exit
 *   callbacks. PostgreSQL treats unexpected backend death as
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
 *   re-enters the same callback, and cleanup runs on that ABORT pass
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
/* would release claims too early. Using PREPARE (vs PRE_PREPARE) for   */
/* the user-facing reject is also too late -- by then the xact has      */
/* crossed into prepare cleanup paths and the operator gets a much less */
/* actionable error.                                                    */
/*                                                                      */
/* Tantor SE adds PRE_ABORT / PARALLEL_PRE_ABORT, both no-ops here. It  */
/* fires them at the start of AbortTransaction, after the LWLocks are   */
/* released and before the abort is recorded. The same AbortTransaction */
/* call delivers ABORT / PARALLEL_ABORT after ProcArrayEndTransaction,  */
/* on the same condition as in PostgreSQL, so claims are released at    */
/* the same point of the abort on both servers.                         */
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
             * the local set is empty, so a second pass is a no-op. That
             * covers the ABORT re-entry after a rejected PRE_PREPARE and
             * xclaim_shmem_exit_cb, which runs after the final abort at
             * backend exit.
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
             * release claims too early. Throwing the 2PC ERROR from
             * XACT_EVENT_PREPARE is also too late (the xact has crossed
             * into prepare cleanup).
             */
            return;

#ifdef XCLAIM_HAVE_XACT_EVENT_PRE_ABORT
        case XACT_EVENT_PRE_ABORT:
        case XACT_EVENT_PARALLEL_PRE_ABORT:
            /*
             * No-op (Tantor SE). ABORT / PARALLEL_ABORT of the same
             * AbortTransaction call releases the claims.
             */
            return;
#endif
    }
}

/* -------------------------------------------------------------------- */
/* xclaim_shmem_exit_cb                                                 */
/*                                                                      */
/* `on_shmem_exit`, registered by the backend after InitProcess() (HARD */
/* invariant), once per backend, by xclaim_ensure_owner_token() on the  */
/* first claim. Every before_shmem_exit callback runs before any        */
/* on_shmem_exit callback, and each list runs in reverse registration   */
/* order:                                                               */
/*   * ShutdownPostgres (before_shmem_exit) has already aborted a       */
/*     transaction left open at exit, and the xact callback has         */
/*     released its claims.                                             */
/*   * ProcKill (on_shmem_exit, registered by InitProcess() before this */
/*     callback) has not run yet, so MyProc is set and the partition    */
/*     LWLocks can be taken, as core's RemoveProcFromArray does from    */
/*     the same list.                                                   */
/*   * Not before_shmem_exit: a PG_ENSURE_ERROR_CLEANUP scope around    */
/*     the first claim removes its own before_shmem_exit entry with     */
/*     cancel_before_shmem_exit(), which fails if a newer entry sits on */
/*     top. Not on_proc_exit: it runs after ProcKill().                 */
/*                                                                      */
/* Never registered from _PG_init: in fork-based builds                 */
/* InitPostmasterChild() calls on_exit_reset(), so no exit callback the */
/* postmaster registers survives into a backend.                        */
/*                                                                      */
/* The local set is normally empty here and the cleanup call returns    */
/* immediately. It still holds entries when a sibling's xact callback   */
/* called ahead of ours failed in the abort at exit (the ERROR becomes  */
/* FATAL and skips the rest of the chain). The cleanup releases them.   */
/* Idempotent.                                                          */
/*                                                                      */
/* On hard process death (e.g. SIGKILL/SIGSEGV) this callback does not */
/* fire in the dead backend. PostgreSQL crash-restarts shared memory.  */
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
     * Release the claims the abort at exit did not: a sibling's xact
     * callback called ahead of ours that fails in that abort ends the
     * chain with FATAL. Normally the abort released them and the set
     * is empty here. Idempotent by xclaim_local_cleanup_held()'s
     * early-return when the local set is empty.
     */
    xclaim_local_cleanup_held();

    /*
     * Invalidate our published owner_token before the backend slot is
     * released. The stale-owner reaper judges a leftover row by the
     * PGPROC slot of its owner (pid) and by the token published in
     * XClaimBackendInfos. On PG 16 ProcKill() leaves the exited
     * backend's pid in its PGPROC slot until the slot is reused, so the
     * pid checks keep treating a leftover row of this backend as live.
     * On PG 17+ the pid is cleared, but a new backend that reuses the
     * slot with the same OS pid and never calls pg_xclaim would pass the
     * pid checks the same way. Leftover rows are only possible after an
     * incomplete cleanup path, and writing 0 (the reserved-invalid token
     * sentinel) makes the token check fail for all of them: the next
     * conflicting backend's reaper sees published_token == 0 !=
     * entry->owner_token and reaps the row. xclaim.session_reset uses
     * the same atomic write for the same reason.
     *
     * MyProc is set here: ProcKill(), which clears it, is an
     * on_shmem_exit callback that InitProcess() registered before this
     * one, so it runs after this one. The check stays as a guard for
     * xclaim_get_current_procno(), which dereferences MyProc on PG 16.
     */
    if (MyProc == NULL || XClaimBackendInfos == NULL)
        return;

    procno = (int) xclaim_get_current_procno();
    if (procno >= 0 && procno < MaxBackends)
        pg_atomic_write_u64(&XClaimBackendInfos[procno].current_token, 0);
}
