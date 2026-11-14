/*-------------------------------------------------------------------------
 *
 * pg_xclaim_session.c
 *      `xclaim.session_reset()` SQL entry for connection-pooler
 *      defense-in-depth.
 *
 * Purpose:
 *   `xclaim.session_reset()` is an OPTIONAL reactive triage tool. It
 *   is NOT required for normal operation: the xact callback releases
 *   claims at every PostgreSQL-controlled transaction ending (commit,
 *   rollback, client disconnect, idle-in-tx timeout, FATAL backend
 *   exit), and the backend-exit callback releases whatever is left
 *   when the backend exits. Hard process death is handled by
 *   postmaster crash restart, not by callbacks in the dead backend.
 *   Tx-mode poolers (`pg_doorman`, `odyssey`, `PgBouncer`) all issue
 *   ROLLBACK before reusing a backend on unhealthy disconnect, which
 *   triggers the same xact-callback cleanup path.
 *
 *   DO NOT wire this function into pooler `server_reset_query` /
 *   `server_reset_query_always`. Doing so adds an RTT per backend
 *   handoff (potentially thousands per second on hot clusters) and
 *   protects against nothing: by the time the pooler resets the
 *   connection, the transaction has ended and its claims are released.
 *   The operator guidance lives in the COMMENT ON FUNCTION set by
 *   sql/pg_xclaim--1.0.0-rc1--1.0.0-rc2.sql and in docs/runbook.md
 *   section 6.
 *
 *   The state it addresses is a session that holds claims outside a
 *   transaction (`xclaim.count() > 0` in autocommit). Normal operation
 *   never produces it: when a sibling extension's xact callback raises
 *   ERROR, PostgreSQL aborts the transaction and calls every xact
 *   callback again with XACT_EVENT_ABORT, ours included. The end of
 *   the session's next transaction releases such claims as well.
 *
 *   Idempotent and cheap when no claims are held (the common case).
 *
 * Behaviour:
 *   1. Refusal: inside an explicit transaction block, from a message
 *      hook inside an xclaim.try_many loop, and whenever the local set
 *      holds a claim of the running transaction (taken earlier in the
 *      same statement, function or DO block).
 *      Sentinel check: a non-empty local set holds claims that outlived
 *      the transaction that took them. The count is kept, the cleanup
 *      runs regardless, and the DEBUG1 line naming it is written after
 *      step 5.
 *   2. Force-cleanup of any shared rows owned by THIS backend, using
 *      the same group-by-partition path as the xact callback. This
 *      avoids a full-shmem-scan (O(max_claims) per session_reset is
 *      unacceptable at max_claims=4M).
 *   3. The local set is empty once step 2 returns -- cleanup_held
 *      tears down each held entry as part of the group-by-partition
 *      drain. A set enlarged by an earlier burst gets an array of its
 *      first size (xclaim_local_shrink), with no ERROR.
 *   4. Rotate the owner_token: drop our cached token AND zero our
 *      published-slot token. The next acquisition issues a fresh
 *      token from XClaimCtl->next_token. A shared row with the old
 *      token that the local set does not track (only a defect can
 *      leave one) becomes visible to the stale-owner reaper as a token
 *      mismatch on the next conflict.
 *   5. Re-arm the one-shot 75% hint and increment
 *      XClaimCtl->session_resets.
 *
 * The function is declared `LANGUAGE c VOLATILE PARALLEL RESTRICTED`
 * (NOT UNSAFE -- session_reset is allowed in any non-worker context).
 * It must NOT run inside a parallel worker (defended by the
 * runtime IsParallelWorker() check).
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/parallel.h"            /* IsParallelWorker */
#include "fmgr.h"
#include "miscadmin.h"
#include "port/atomics.h"
#include "utils/elog.h"

#include "pg_xclaim.h"
#include "pg_xclaim_compat.h"
#include "pg_xclaim_internal.h"
#include "pg_xclaim_local.h"

PG_FUNCTION_INFO_V1(xclaim_session_reset);

Datum
xclaim_session_reset(PG_FUNCTION_ARGS)
{
    uint64      held_at_entry;

    /*
     * Standard preflight (the macro expands to two ereport gates --
     * shared_preload_libraries presence + hot-standby). No NULL handling
     * needed: the function is declared CALLED ON NULL INPUT but takes
     * zero arguments.
     */
    XCLAIM_REQUIRE_INIT();

    /*
     * Defense-in-depth runtime check. session_reset() should never run
     * inside a parallel worker -- the parallel leader only handoffs
     * cleanup. The PARALLEL RESTRICTED attribute already keeps the
     * planner from scheduling us on a worker, but plan-shape changes
     * must not silently break this.
     */
    if (IsParallelWorker())
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("pg_xclaim: xclaim.session_reset cannot be called from a parallel worker")));

    /*
     * Refuse to run inside an explicit transaction block. This is the
     * "manual unlock inside active xact" footgun: with the helper open
     * to PUBLIC, any user could call it during their own BEGIN ... COMMIT
     * to drop their own held claims early, breaking the implicit
     * "xact-scoped lock cannot be released early" contract that callers
     * lean on (queues, dedupe, idempotency, leader election). The helper
     * remains useful as a session-level triage tool in autocommit mode
     * (when the previous xact's callback somehow left state behind),
     * which is exactly the case `enabled = off` cannot cover.
     *
     * IsTransactionBlock() returns true only inside an explicit
     * `BEGIN ... COMMIT` / `BEGIN ... ROLLBACK`. An autocommit statement
     * is an implicit transaction that can take claims too: a function or
     * DO block that calls xclaim.try and then session_reset, or
     * `SELECT xclaim.try(1), xclaim.session_reset()`. The second check
     * refuses whenever the set holds a claim of the running transaction,
     * so session_reset releases only claims left by earlier transactions.
     */
    if (IsTransactionBlock())
        ereport(ERROR,
                (errcode(ERRCODE_ACTIVE_SQL_TRANSACTION),
                 errmsg("pg_xclaim: xclaim.session_reset cannot be called inside an explicit transaction block"),
                 errhint("Call it from an autocommit statement, or COMMIT/ROLLBACK first.")));

    if (xclaim_try_many_in_progress())
        ereport(ERROR,
                (errcode(ERRCODE_ACTIVE_SQL_TRANSACTION),
                 errmsg("pg_xclaim: xclaim.session_reset cannot be called during xclaim.try_many")));

    if (xclaim_local_holds_current_xact())
        ereport(ERROR,
                (errcode(ERRCODE_ACTIVE_SQL_TRANSACTION),
                 errmsg("pg_xclaim: xclaim.session_reset cannot release claims of the running transaction"),
                 errhint("The transaction releases them when it ends. Call xclaim.session_reset() from a separate statement.")));

    /*
     * Sentinel: the xact callback empties the local set at every
     * transaction end, so entries from an earlier transaction mean its
     * callback did not release them. A sibling extension's failing
     * xact callback does not cause this: PostgreSQL then aborts the
     * transaction and calls every xact callback again with
     * XACT_EVENT_ABORT, ours included. The DEBUG1 line (not WARNING:
     * this function is supposed to silently clean up exactly this case)
     * is written last, after the reset: a message can reach an
     * emit_log_hook that runs SQL, and a claim it takes between the
     * refusal checks above and the cleanup below would be released at
     * once.
     */
    held_at_entry = xclaim_local_count();

    /*
     * Force-cleanup. Reuses the group-by-partition cleanup path (same
     * code as the xact callback) -- bounded LWLock cycles even if 4M
     * claims somehow leaked. A full scan of shared memory would cost
     * O(max_claims) per session_reset.
     *
     * If the local set is empty (the common case) this is a single
     * idempotent no-op and returns immediately.
     */
    xclaim_local_cleanup_held();

    /*
     * Give a set enlarged by an earlier burst back to the allocator: the
     * session asked for a clean state. The shrink raises no ERROR, so the
     * token rotation below always runs. When the smaller array does not
     * fit, the set keeps the one it has.
     */
    xclaim_local_shrink(true);

    /*
     * Rotate the owner_token. After this returns, XClaimMyOwnerToken == 0
     * and XClaimBackendInfos[procno].current_token has been atomically
     * written to 0. The next acquisition's xclaim_ensure_owner_token()
     * issues a FRESH token from XClaimCtl->next_token. A shared row
     * with our old token that the cleanup above did not release,
     * because the local set does not track it (only a defect leaves
     * such a row), fails the reaper's token check from now on and goes
     * to the next conflicting acquisition by another backend.
     */
    xclaim_local_clear_owner_token();

    /*
     * Clear the per-session one-shot peak-warning flag. A long-running
     * backend that already logged "crossed 75% of
     * pg_xclaim.expected_claims_per_backend" and then issues
     * session_reset() should be allowed to emit a fresh hint if it grows
     * past the threshold again on the next workload cycle.
     */
    xclaim_local_reset_peak_warning();

    /* Stats. */
    pg_atomic_fetch_add_u64(&XClaimCtl->session_resets, 1);

    if (held_at_entry != 0)
        ereport(DEBUG1,
                (errmsg("pg_xclaim: session_reset released %llu held claims",
                        (unsigned long long) held_at_entry)));

    PG_RETURN_VOID();
}
