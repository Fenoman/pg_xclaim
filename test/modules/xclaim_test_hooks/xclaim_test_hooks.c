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
 *   xclaim_test_call_with_lwlocks_held(fn regprocedure, key int8) RETURNS bool
 *      Calls fn(key) while every slot of the backend's held-LWLock array is
 *      in use (MAX_SIMUL_LWLOCKS of lwlock.c: 200 in PostgreSQL, more in
 *      some forks), so an LWLockAcquire inside it raises "too many LWLocks
 *      taken". Returns true when the call raised an ERROR, which it catches.
 *
 *   xclaim_test_hooks.call_on_warning (int, user-settable)
 *   xclaim_test_hooks.call_on_log (int, user-settable)
 *      The OID of a function without arguments. The module's emit_log_hook
 *      calls it once, on the next WARNING or on the next LOG message (LOG
 *      or LOG_SERVER_ONLY, the level of pg_log_backend_memory_contexts),
 *      and resets the setting. An ERROR it raises propagates from the
 *      message.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/xact.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/elog.h"
#include "utils/guc.h"
#include "utils/memutils.h"

#include "pg_xclaim.h"
#include "pg_xclaim_internal.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(xclaim_test_published_token);
PG_FUNCTION_INFO_V1(xclaim_test_set_published_token);
PG_FUNCTION_INFO_V1(xclaim_test_call_with_lwlocks_held);
PG_FUNCTION_INFO_V1(xclaim_test_inject_stale);
PG_FUNCTION_INFO_V1(xclaim_test_set_live_capacity);
PG_FUNCTION_INFO_V1(xclaim_test_pair_partition);

static bool fail_abort_at_exit = false;
static int  call_on_warning = 0;
static int  call_on_log = 0;
static emit_log_hook_type prev_emit_log_hook = NULL;

/*
 * EmitErrorReport() runs the hook in ErrorContext. The function runs in
 * the memory context of the running transaction instead, as SQL does
 * (an EXCEPTION block of a PL/pgSQL function copies its error data out of
 * ErrorContext). Outside a transaction the call is skipped.
 */
static void
xclaim_test_call_from_hook(Oid fn)
{
    MemoryContext oldcxt;

    if (!IsTransactionState())
        return;
    oldcxt = MemoryContextSwitchTo(CurTransactionContext);
    (void) OidFunctionCall0(fn);
    MemoryContextSwitchTo(oldcxt);
}

static void
xclaim_test_emit_log_hook(ErrorData *edata)
{
    if (prev_emit_log_hook)
        prev_emit_log_hook(edata);

    if (call_on_warning != 0 && edata->elevel == WARNING)
    {
        Oid         fn = (Oid) call_on_warning;

        call_on_warning = 0;
        xclaim_test_call_from_hook(fn);
    }
    if (call_on_log != 0 &&
        (edata->elevel == LOG || edata->elevel == LOG_SERVER_ONLY))
    {
        Oid         fn = (Oid) call_on_log;

        call_on_log = 0;
        xclaim_test_call_from_hook(fn);
    }
}

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
    DefineCustomIntVariable("xclaim_test_hooks.call_on_warning",
                            "OID of a function the emit_log_hook calls once, on the next WARNING.",
                            NULL,
                            &call_on_warning,
                            0, 0, INT_MAX,
                            PGC_USERSET,
                            0,
                            NULL, NULL, NULL);
    DefineCustomIntVariable("xclaim_test_hooks.call_on_log",
                            "OID of a function the emit_log_hook calls once, on the next LOG message.",
                            NULL,
                            &call_on_log,
                            0, 0, INT_MAX,
                            PGC_USERSET,
                            0,
                            NULL, NULL, NULL);
    MarkGUCPrefixReserved("xclaim_test_hooks");
    RegisterXactCallback(xclaim_test_xact_callback, NULL);
    prev_emit_log_hook = emit_log_hook;
    emit_log_hook = xclaim_test_emit_log_hook;
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

Datum
xclaim_test_call_with_lwlocks_held(PG_FUNCTION_ARGS)
{
    Oid             fn = PG_GETARG_OID(0);
    int64           key = PG_GETARG_INT64(1);
    FmgrInfo        finfo;
    LWLock         *lock;
    MemoryContext   oldcxt = CurrentMemoryContext;
    uint32          saved_holdoff = InterruptHoldoffCount;
    volatile bool   caught = false;
    volatile int    held = 0;
    int             n;

    fmgr_info(fn, &finfo);

    /*
     * A backend-local LWLock taken in shared mode never waits, and every
     * acquisition takes a slot of the backend's held-lock array. The array
     * has MAX_SIMUL_LWLOCKS slots, which lwlock.c does not export: 200 in
     * PostgreSQL, more in some forks. The lock is taken until LWLockAcquire
     * raises its ERROR, before taking the lock, with every slot in use.
     */
    lock = MemoryContextAllocZero(TopMemoryContext, sizeof(LWLock));
    LWLockInitialize(lock, LWTRANCHE_FIRST_USER_DEFINED);
    PG_TRY();
    {
        for (;;)
        {
            LWLockAcquire(lock, LW_SHARED);
            held++;
        }
    }
    PG_CATCH();
    {
        MemoryContextSwitchTo(oldcxt);
        FlushErrorState();
    }
    PG_END_TRY();
    /*
     * errfinish() zeroed the interrupt holdoff count. The caller's count
     * comes back, and each held lock holds interrupts once more, as
     * LWLockAcquire left it.
     */
    InterruptHoldoffCount = saved_holdoff + held;
    if (held == 0)
    {
        pfree(lock);
        elog(ERROR, "xclaim_test_call_with_lwlocks_held: no LWLock taken");
    }

    PG_TRY();
    {
        (void) FunctionCall1(&finfo, Int64GetDatum(key));
    }
    PG_CATCH();
    {
        MemoryContextSwitchTo(oldcxt);
        FlushErrorState();
        caught = true;
    }
    PG_END_TRY();

    /*
     * An ERROR of the call zeroed the interrupt holdoff count again. Only
     * this function's locks are released, and each release resumes
     * interrupts once, down to the caller's count.
     */
    if (caught)
        InterruptHoldoffCount = saved_holdoff + held;
    for (n = 0; n < held; n++)
        LWLockRelease(lock);
    pfree(lock);

    PG_RETURN_BOOL(caught);
}

static XClaimControl *
attach_xclaim_control(void)
{
    static XClaimControl *cached_ctl = NULL;
    bool                  found;

    if (cached_ctl != NULL)
        return cached_ctl;

    cached_ctl = (XClaimControl *)
        ShmemInitStruct("xclaim_control", sizeof(XClaimControl), &found);
    if (!found)
    {
        cached_ctl = NULL;
        ereport(ERROR,
                (errmsg("xclaim_test_hooks: pg_xclaim shared memory not found")));
    }
    return cached_ctl;
}

static HTAB *
attach_xclaim_hash(const XClaimControl *ctl)
{
    static HTAB *cached_htab = NULL;
    HASHCTL      info;

    if (cached_htab != NULL)
        return cached_htab;

    memset(&info, 0, sizeof(info));
    info.keysize        = sizeof(XClaimKey);
    info.entrysize      = sizeof(XClaimEntry);
    info.num_partitions = ctl->num_partitions;

    cached_htab = ShmemInitHash("xclaim_hash",
                                ctl->max_claims,
                                ctl->max_claims,
                                &info,
                                HASH_ELEM | HASH_BLOBS | HASH_PARTITION | HASH_FIXED_SIZE);
    return cached_htab;
}

/*
 * xclaim_test_inject_stale(scope int4, key int4) RETURNS void
 *      Test-only helper seeding an XClaimEntry with a guaranteed-stale
 *      owner triple (owner_procno = INT32_MAX, owner_token = 0) so reaper
 *      tests can exercise stale takeover without shipping a shared-state
 *      backdoor in production pg_xclaim.so.
 */
Datum
xclaim_test_inject_stale(PG_FUNCTION_ARGS)
{
    int32          scope;
    int32          key;
    XClaimKey      lk;
    XClaimControl *ctl;
    HTAB          *htab;
    LWLockPadded  *plocks;
    uint32         hashvalue;
    uint32         part;
    LWLock        *plock;
    XClaimEntry   *new_entry;
    bool           found;

    CHECK_FOR_INTERRUPTS();

    if (RecoveryInProgress())
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("xclaim_test_inject_stale does not support recovery mode")));

    if (!superuser())
        ereport(ERROR,
                (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
                 errmsg("xclaim_test_inject_stale requires superuser")));

    if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("xclaim_test_inject_stale arguments must not be NULL")));

    scope = PG_GETARG_INT32(0);
    key   = PG_GETARG_INT32(1);

    ctl    = attach_xclaim_control();
    htab   = attach_xclaim_hash(ctl);
    plocks = GetNamedLWLockTranche("xclaim_partition");

    memset(&lk, 0, sizeof(lk));
    lk.dbid = MyDatabaseId;
    lk.form = XCLAIM_FORM_PAIR;
    lk.k1   = (int64) (((uint64) (uint32) scope << 32) | (uint32) key);

    hashvalue = get_hash_value(htab, &lk);
    part      = hashvalue & ((uint32) ctl->num_partitions - 1);
    plock     = &plocks[part].lock;

    LWLockAcquire(plock, LW_EXCLUSIVE);

    new_entry = (XClaimEntry *) hash_search_with_hash_value(htab,
                                                            &lk,
                                                            hashvalue,
                                                            HASH_ENTER_NULL,
                                                            &found);
    if (new_entry == NULL)
    {
        LWLockRelease(plock);
        ereport(ERROR,
                (errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
                 errmsg("xclaim_test_inject_stale: max_claims exhausted")));
    }

    if (found)
    {
        LWLockRelease(plock);
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_IN_USE),
                 errmsg("xclaim_test_inject_stale: key (%d,%d) already exists in shared table, refusing to overwrite",
                        scope, key)));
    }

    pg_atomic_fetch_add_u64(&ctl->live_capacity, 1);

    new_entry->owner_pid     = 999999;
    new_entry->owner_procno  = INT32_MAX;
    new_entry->owner_lxid    = 0;
    new_entry->owner_token   = 0;
    new_entry->lifetime_kind = XCLAIM_LIFETIME_XACT;

    LWLockRelease(plock);

    PG_RETURN_VOID();
}

/*
 * xclaim_test_set_live_capacity(val int8) RETURNS void
 *      Test-only helper overwriting XClaimCtl->live_capacity to exercise
 *      xclaim.stats() clamping on out-of-range gauge values.
 */
Datum
xclaim_test_set_live_capacity(PG_FUNCTION_ARGS)
{
    int64          val = PG_GETARG_INT64(0);
    XClaimControl *ctl = attach_xclaim_control();

    if (!superuser())
        ereport(ERROR,
                (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
                 errmsg("xclaim_test_set_live_capacity requires superuser")));

    pg_atomic_write_u64(&ctl->live_capacity, (uint64) val);
    PG_RETURN_VOID();
}

Datum
xclaim_test_pair_partition(PG_FUNCTION_ARGS)
{
    int32          scope = PG_GETARG_INT32(0);
    int32          key   = PG_GETARG_INT32(1);
    XClaimControl *ctl   = attach_xclaim_control();
    HTAB          *htab  = attach_xclaim_hash(ctl);
    XClaimKey      lk;
    uint32         hashvalue;

    memset(&lk, 0, sizeof(lk));
    lk.dbid = MyDatabaseId;
    lk.form = XCLAIM_FORM_PAIR;
    lk.k1   = (int64) (((uint64) (uint32) scope << 32) | (uint32) key);

    hashvalue = get_hash_value(htab, &lk);
    PG_RETURN_INT32((int32) (hashvalue & ((uint32) ctl->num_partitions - 1)));
}
