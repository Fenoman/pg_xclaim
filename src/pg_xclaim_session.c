/*-------------------------------------------------------------------------
 *
 * pg_xclaim_session.c
 *      `xclaim.session_reset()` SQL entry for connection-pooler
 *      defense-in-depth.
 *
 * Purpose:
 *   `xclaim.session_reset()` is an OPTIONAL reactive triage tool. It
 *   is NOT required for normal operation: claims are released
 *   automatically by the xact callback on every COMMIT/ABORT, and that
 *   callback fires on PostgreSQL-controlled transaction endings (commit,
 *   rollback, client disconnect, idle-in-tx timeout, FATAL backend
 *   exit). Hard process death is handled by postmaster crash restart,
 *   not by callbacks in the dead backend. Tx-mode poolers (`pg_doorman`,
 *   `odyssey`, `PgBouncer`) all
 *   issue ROLLBACK before reusing a backend on unhealthy disconnect,
 *   which triggers the same xact-callback cleanup path.
 *
 *   DO NOT wire this function into pooler `server_reset_query` /
 *   `server_reset_query_always`. Doing so adds an RTT per backend
 *   handoff (potentially thousands per second on hot clusters) just to
 *   defend against a hypothetical xact-callback skip with no
 *   observable symptom in production. The authoritative guidance lives
 *   in sql/pg_xclaim--1.0.0-rc1.sql (the COMMENT ON FUNCTION text) and
 *   docs/runbook.md section 6 ("Pooler integration").
 *
 *   Use this function ONLY reactively: when
 *   `xclaim.stats().cleanup_misses > 0` is observed in production,
 *   indicating that some xact-callback path was bypassed and reactive
 *   cleanup may be warranted.
 *
 *   Idempotent and cheap when no claims are held (the common case).
 *
 * Behaviour:
 *   1. Sentinel check: if the local set is non-empty after xact end,
 *      that is a callback-skip bug -- log at DEBUG1 and proceed to
 *      defensive force-clear. The cleanup runs regardless.
 *   2. Force-cleanup of any shared rows owned by THIS backend, using
 *      the same group-by-partition path as the xact callback. This
 *      avoids a full-shmem-scan (O(max_claims) per session_reset is
 *      unacceptable at max_claims=4M).
 *   3. The local set is empty once step 2 returns -- cleanup_held
 *      tears down each held entry as part of the group-by-partition
 *      drain.
 *   4. Rotate the owner_token: drop our cached token AND zero our
 *      published-slot token. The next acquisition issues a fresh
 *      token from XClaimCtl->next_token; any leftover shared row
 *      (the "callback skip" case this function defends against)
 *      becomes visible to the stale-owner reaper as a token mismatch
 *      on the next conflict.
 *   5. Increment XClaimCtl->session_resets stat.
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
     * `BEGIN ... COMMIT` / `BEGIN ... ROLLBACK`. A bare `SELECT
     * xclaim.session_reset()` in autocommit mode passes through.
     */
    if (IsTransactionBlock())
        ereport(ERROR,
                (errcode(ERRCODE_ACTIVE_SQL_TRANSACTION),
                 errmsg("pg_xclaim: xclaim.session_reset cannot be called inside an explicit transaction block"),
                 errhint("Call it from an autocommit statement, or COMMIT/ROLLBACK first.")));

    /*
     * Sentinel: the local set SHOULD be empty after the previous xact
     * ended (xact callback ran). Non-empty here means a missed
     * callback -- the most likely cause is a sibling extension whose
     * own callback raised ERROR earlier in the CallXactCallbacks
     * chain, longjmp'ing past us. Log at DEBUG1 -- not WARNING,
     * because this function is supposed to silently clean up exactly
     * this case.
     */
    held_at_entry = xclaim_local_count();
    if (held_at_entry != 0)
        ereport(DEBUG1,
                (errmsg("pg_xclaim: session_reset found %llu local entries after xact end (possible callback skip)",
                        (unsigned long long) held_at_entry)));

    /*
     * Force-cleanup. Reuses the group-by-partition cleanup path (same
     * code as the xact callback) -- bounded LWLock cycles even if 4M
     * claims somehow leaked. Full-shmem-scan is REJECTED here as
     * O(max_claims) per session_reset.
     *
     * If the local set is empty (the common case) this is a single
     * idempotent no-op and returns immediately.
     */
    xclaim_local_cleanup_held();

    /*
     * Rotate the owner_token. After this returns, XClaimMyOwnerToken == 0
     * and XClaimBackendInfos[procno].current_token has been atomically
     * written to 0. The next acquisition's xclaim_ensure_owner_token()
     * issues a FRESH token from XClaimCtl->next_token. Any shared row
     * that survived the cleanup above (because the saved triple did
     * not match -- e.g. cleanup_misses scenarios) becomes visible to
     * the stale-owner reaper as a token mismatch on the next conflict
     * acquired by another backend.
     */
    xclaim_local_clear_owner_token();

    /*
     * Clear the per-session one-shot peak-warning flag. A long-running
     * backend that already logged "peak crossed 75% of
     * expected_claims_per_backend" and then issues session_reset()
     * should be allowed to emit a fresh hint if it grows past the
     * threshold again on the next workload cycle.
     */
    xclaim_local_reset_peak_warning();

    /* Stats. */
    pg_atomic_fetch_add_u64(&XClaimCtl->session_resets, 1);

    PG_RETURN_VOID();
}
