/*-------------------------------------------------------------------------
 *
 * xclaim_test_hooks.c
 *      Test-only module for the pg_xclaim concurrency suite.
 *
 * test/concurrency/_lib.sh builds it into a temporary directory for the
 * PostgreSQL under test and preloads it by absolute path after pg_xclaim.
 * It is not part of the installed extension.
 *
 *   xclaim_test_hooks.fail_abort_at_exit (bool, user-settable)
 *      The module's xact callback raises ERROR on XACT_EVENT_ABORT while
 *      proc_exit is in progress. Preloaded after pg_xclaim, its callback
 *      runs before pg_xclaim's. During proc_exit the ERROR becomes FATAL
 *      and skips the rest of the callback chain, so the claims of a
 *      transaction left open at exit reach pg_xclaim's backend-exit
 *      callback instead of its xact callback.
 *
 *   xclaim_test_published_token(procno int4) RETURNS int8
 *   xclaim_test_set_published_token(procno int4, token int8) RETURNS void
 *      Read or overwrite the owner_token published in
 *      XClaimBackendInfos[procno], the value the stale-owner reaper
 *      compares with a row's owner_token.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/xact.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "storage/ipc.h"
#include "storage/shmem.h"
#include "utils/guc.h"

#include "pg_xclaim_internal.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(xclaim_test_published_token);
PG_FUNCTION_INFO_V1(xclaim_test_set_published_token);

static bool fail_abort_at_exit = false;

static void
xclaim_test_xact_callback(XactEvent event, void *arg)
{
    if (event == XACT_EVENT_ABORT && proc_exit_inprogress && fail_abort_at_exit)
        ereport(ERROR,
                (errmsg("xclaim_test_hooks: failing the abort at backend exit")));
}

void
_PG_init(void)
{
    DefineCustomBoolVariable("xclaim_test_hooks.fail_abort_at_exit",
                             "Raise ERROR in this module's xact callback on the abort at backend exit.",
                             NULL,
                             &fail_abort_at_exit,
                             false,
                             PGC_USERSET,
                             0,
                             NULL, NULL, NULL);
    MarkGUCPrefixReserved("xclaim_test_hooks");
    RegisterXactCallback(xclaim_test_xact_callback, NULL);
}

/*
 * Attach to pg_xclaim's per-backend slot array by its shared memory name,
 * with the size pg_xclaim requests for it (ShmemInitStruct rejects any
 * other size). pg_xclaim must be preloaded: when the name is missing,
 * ShmemInitStruct allocates a new array before this function raises
 * ERROR.
 */
static XClaimBackendInfo *
attach_backend_infos(int32 procno)
{
    bool        found;
    XClaimBackendInfo *infos;

    if (procno < 0 || procno >= MaxBackends)
        ereport(ERROR,
                (errmsg("xclaim_test_hooks: procno %d is out of range", procno)));

    infos = (XClaimBackendInfo *)
        ShmemInitStruct("xclaim_backend_infos",
                        mul_size((Size) MaxBackends, sizeof(XClaimBackendInfo)),
                        &found);
    if (!found)
        ereport(ERROR,
                (errmsg("xclaim_test_hooks: pg_xclaim shared memory not found")));
    return infos;
}

Datum
xclaim_test_published_token(PG_FUNCTION_ARGS)
{
    int32       procno = PG_GETARG_INT32(0);
    XClaimBackendInfo *infos = attach_backend_infos(procno);

    PG_RETURN_INT64((int64) pg_atomic_read_u64(&infos[procno].current_token));
}

Datum
xclaim_test_set_published_token(PG_FUNCTION_ARGS)
{
    int32       procno = PG_GETARG_INT32(0);
    int64       token = PG_GETARG_INT64(1);
    XClaimBackendInfo *infos = attach_backend_infos(procno);

    pg_atomic_write_u64(&infos[procno].current_token, (uint64) token);
    PG_RETURN_VOID();
}
