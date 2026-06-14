/*-------------------------------------------------------------------------
 *
 * pg_xclaim.c
 *      Module entry point: PG_MODULE_MAGIC, _PG_init, GUC registration,
 *      preload / recovery / ABI gates.
 *
 * Init-path summary (the recovery gate runs at SQL call time, never at
 * preload, because XLogCtl may be NULL during _PG_init):
 *   * Two mandatory _PG_init gates (see the comment above _PG_init for
 *     the full rationale):
 *       1. !process_shared_preload_libraries_in_progress -> silent
 *          return (pg_stat_statements pattern). SQL functions raise
 *          ERROR via XCLAIM_REQUIRE_INIT at first call.
 *       2. ABI compat: PG_VERSION_NUM/100 must equal the value the .so
 *          was compiled against -- catches mismatched server upgrades.
 *   * RecoveryInProgress() rejection is enforced lazily inside
 *     XCLAIM_REQUIRE_INIT() (pg_xclaim.h). XLogCtl is NULL at preload
 *     time and unreliable from xclaim_shmem_startup, so the recovery
 *     check MUST run from a regular backend at SQL-call time.
 *   * Six GUCs. Three single-variable check_hooks enforce max_claims
 *     >= 32, num_partitions power-of-two, and
 *     expected_claims_per_backend > 0. Two further cross-GUC rules
 *     (num_partitions <= max_claims; expected_claims_per_backend <=
 *     max_claims) are validated by a FATAL check at the tail of
 *     xclaim_define_gucs, since a check_hook sees only one variable.
 *   * Shared-memory request stubs (RequestAddinShmemSpace,
 *     RequestNamedLWLockTranche, shmem_startup_hook) wired up; real
 *     allocation lives in pg_xclaim_shared.c.
 *   * Lifecycle callback registration (RegisterXactCallback,
 *     before_shmem_exit) wired up; real callbacks live in
 *     pg_xclaim_callbacks.c.
 *
 * HARD invariants enforced here:
 *   * GUC validation `max_claims >= 32` lives in a check_hook (returns
 *     false on invalid; never ereport(ERROR) directly -- PG GUC
 *     machinery requires bool return).
 *   * `before_shmem_exit` (NOT on_shmem_exit / on_proc_exit).
 *   * Acquisition entry points (xclaim.try, xclaim.try_many,
 *     xclaim.session_reset) MUST be EXACTLY
 *     VOLATILE PARALLEL RESTRICTED CALLED ON NULL INPUT. The
 *     observability surface uses per-function attributes: xclaim.stats,
 *     xclaim.debug_snapshot, and xclaim.count are STABLE PARALLEL
 *     RESTRICTED (each touches per-backend state that workers do not
 *     inherit), and xclaim.debug is STABLE PARALLEL UNSAFE; see
 *     sql/pg_xclaim--1.0.0-rc1.sql.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <string.h>

#include "fmgr.h"
#include "miscadmin.h"
#include "access/xact.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/guc.h"

#include "pg_xclaim.h"
#include "pg_xclaim_compat.h"
#include "pg_xclaim_internal.h"     /* XClaimKey, XClaimForm */

PG_MODULE_MAGIC;

/*
 * COMPILED_PG_VERSION_NUM_PREFIX is `PG_VERSION_NUM / 100` captured at
 * compile time. The runtime ABI check in _PG_init compares this against
 * the *running* server's `PG_VERSION_NUM / 100` to detect a server
 * upgrade that left a stale .so behind (FATAL refuses to load).
 */
#define COMPILED_PG_VERSION_NUM_PREFIX (PG_VERSION_NUM / 100)

/* -------------------------------------------------------------------- */
/* GUC backing variables.                                               */
/* -------------------------------------------------------------------- */

int  xclaim_max_claims                  = 4194304;  /* 4M default */
int  xclaim_num_partitions              = 128;
int  xclaim_expected_claims_per_backend = 16384;
bool xclaim_enabled                     = true;
int  xclaim_capacity_warn_pct           = 80;
int  xclaim_capacity_behavior           = XCLAIM_CAP_ERROR;

/* -------------------------------------------------------------------- */
/* Initialization flag -- flipped to true by shmem_startup_hook.        */
/* SQL entry points refuse to operate while this is false (see          */
/* XCLAIM_REQUIRE_INIT in pg_xclaim.h).                                 */
/* -------------------------------------------------------------------- */

bool xclaim_state_initialized = false;

/* -------------------------------------------------------------------- */
/* Saved upstream shmem_request_hook so we can chain. The matching      */
/* shmem_startup_hook chain lives in pg_xclaim_shared.c (next to the    */
/* hook body that consumes it).                                         */
/* -------------------------------------------------------------------- */

#if PG_VERSION_NUM >= 150000
static shmem_request_hook_type prev_shmem_request_hook = NULL;
#endif

/*
 * Enum option list for `pg_xclaim.on_capacity_exhaustion`. NULL-terminated
 * by `{ NULL, 0, false }` per DefineCustomEnumVariable contract.
 */
static const struct config_enum_entry xclaim_capacity_options[] = {
    { "error",              XCLAIM_CAP_ERROR,             false },
    { "warn",               XCLAIM_CAP_WARN,              false },
    { NULL, 0, false }
};

/* -------------------------------------------------------------------- */
/* GUC check_hook helpers.                                              */
/* -------------------------------------------------------------------- */

/*
 * is_power_of_two
 *      Returns true iff `v` is a positive integer power of two.
 *      Used by num_partitions check_hook -- HASH_PARTITION mandates
 *      power-of-two so partition_id = hashvalue & (num_partitions - 1)
 *      is a correct uniform map.
 */
static inline bool
is_power_of_two(int v)
{
    return v > 0 && (v & (v - 1)) == 0;
}

/*
 * check_max_claims
 *      HARD invariant: dynahash preallocates 32 freelists for partitioned
 *      tables (dynahash.c:127-148). Smaller values do not behave as
 *      HASH_FIXED_SIZE documents. Reject any setting below 32 at GUC
 *      parse time.
 */
static bool
check_max_claims(int *newval, void **extra, GucSource source)
{
    if (*newval < 32)
    {
        GUC_check_errdetail("pg_xclaim.max_claims must be >= 32 (dynahash 32-freelist floor for partitioned tables).");
        return false;
    }
    return true;
}

/*
 * check_num_partitions
 *      HASH_PARTITION requires a power-of-two partition count -- otherwise
 *      partition selection via bitwise AND is biased.
 */
static bool
check_num_partitions(int *newval, void **extra, GucSource source)
{
    if (!is_power_of_two(*newval))
    {
        GUC_check_errdetail("pg_xclaim.num_partitions must be a power of two (HASH_PARTITION requirement).");
        return false;
    }
    return true;
}

/*
 * check_expected_claims_per_backend
 *      Pre-grow target for the per-backend simplehash. Must be strictly
 *      positive; upper bound vs max_claims is checked cross-GUC after
 *      both are parsed (see _PG_init tail).
 */
static bool
check_expected_claims_per_backend(int *newval, void **extra, GucSource source)
{
    if (*newval <= 0)
    {
        GUC_check_errdetail("pg_xclaim.expected_claims_per_backend must be > 0.");
        return false;
    }
    return true;
}

/* -------------------------------------------------------------------- */
/* GUC registration -- invoked once from _PG_init after the preload     */
/* gate has confirmed we are running inside postmaster startup.         */
/* -------------------------------------------------------------------- */

static void
xclaim_define_gucs(void)
{
    DefineCustomIntVariable("pg_xclaim.max_claims",
                            "Maximum number of in-flight claims tracked in shared memory.",
                            "Capacity ceiling of the partitioned shared dynahash. "
                            "Operators MUST raise this for clusters running multiple "
                            "concurrent calculation backends.",
                            &xclaim_max_claims,
                            4194304,        /* default 4M */
                            32,             /* min -- HARD invariant floor */
                            INT_MAX,        /* max */
                            PGC_POSTMASTER,
                            0,
                            check_max_claims,
                            NULL, NULL);

    DefineCustomIntVariable("pg_xclaim.num_partitions",
                            "Number of LWLock partitions for the shared claim hash.",
                            "Must be a power of two; entries are mapped via "
                            "(hashvalue & (num_partitions-1)). Default 128 keeps "
                            "xclaim.debug() / debug_snapshot() working out-of-the-box "
                            "(both refuse to run above 192 partitions to stay under PG "
                            "MAX_SIMUL_LWLOCKS); raise to 256 only on >100-core "
                            "deployments where partition LWLock contention is "
                            "empirically measured, and accept that xclaim.debug() / "
                            "debug_snapshot() then stop working at that partition count.",
                            &xclaim_num_partitions,
                            128,            /* default */
                            1,              /* min -- power-of-two check enforces real floor */
                            65536,          /* max -- sane upper bound, well below shmem cost */
                            PGC_POSTMASTER,
                            0,
                            check_num_partitions,
                            NULL, NULL);

    DefineCustomIntVariable("pg_xclaim.expected_claims_per_backend",
                            "Pre-grow size for the per-backend local hash set.",
                            "Avoids rehash during the 500-750k acquisition burst "
                            "typical of the calculation workload.",
                            &xclaim_expected_claims_per_backend,
                            16384,          /* default */
                            1,              /* min */
                            INT_MAX,        /* max */
                            PGC_POSTMASTER,
                            0,
                            check_expected_claims_per_backend,
                            NULL, NULL);

    DefineCustomBoolVariable("pg_xclaim.enabled",
                             "Enable pg_xclaim acquisition; off short-circuits to no-op.",
                             "Runtime kill switch. When off, xclaim.try / "
                             "xclaim.try_many return true unconditionally without "
                             "touching shared state.",
                             &xclaim_enabled,
                             true,          /* default */
                             PGC_SUSET,
                             0,
                             NULL, NULL, NULL);

    DefineCustomIntVariable("pg_xclaim.capacity_warn_pct",
                             "Capacity utilisation threshold (percent) above which "
                             "watermark LOG messages are emitted.",
                             "First watermark fires at this value; further warnings at "
                             "90% and 95% suppressed for 60 seconds.",
                             &xclaim_capacity_warn_pct,
                             80,            /* default */
                             1,             /* min */
                             100,           /* max */
                             PGC_SIGHUP,
                             0,
                             NULL, NULL, NULL);

    DefineCustomEnumVariable("pg_xclaim.on_capacity_exhaustion",
                             "What to do when the shared dynahash hits max_claims capacity.",
                             "error: raise ERRCODE_CONFIGURATION_LIMIT_EXCEEDED. "
                             "warn: log WARNING and return false.",
                             &xclaim_capacity_behavior,
                             XCLAIM_CAP_ERROR,
                             xclaim_capacity_options,
                             PGC_SUSET,
                             0,
                             NULL, NULL, NULL);

    /*
     * Reserve the entire `pg_xclaim.*` GUC prefix. After this call PG
     * raises a WARNING for any `pg_xclaim.<unknown>` placeholder set in
     * postgresql.conf or via ALTER SYSTEM, so operator typos in our GUC
     * names surface instead of being silently accepted as custom
     * placeholders.
     */
    MarkGUCPrefixReserved("pg_xclaim");

    /*
     * Cross-GUC validation that cannot live in a single-variable
     * check_hook: num_partitions <= max_claims AND
     * expected_claims_per_backend <= max_claims. Both are
     * PGC_POSTMASTER, so values are now frozen for cluster lifetime.
     * If a user lowered max_claims below either, refuse to start the
     * cluster -- safer than silent over-allocation.
     */
    if (xclaim_num_partitions > xclaim_max_claims)
        ereport(FATAL,
                (errcode(ERRCODE_CONFIG_FILE_ERROR),
                 errmsg("pg_xclaim.num_partitions (%d) must be <= pg_xclaim.max_claims (%d)",
                        xclaim_num_partitions, xclaim_max_claims)));

    if (xclaim_expected_claims_per_backend > xclaim_max_claims)
        ereport(FATAL,
                (errcode(ERRCODE_CONFIG_FILE_ERROR),
                 errmsg("pg_xclaim.expected_claims_per_backend (%d) must be <= pg_xclaim.max_claims (%d)",
                        xclaim_expected_claims_per_backend, xclaim_max_claims)));
}

/* -------------------------------------------------------------------- */
/* Shared-memory request hook (PG 15+) -- wraps RequestAddinShmemSpace +*/
/* RequestNamedLWLockTranche. PG <15 calls these directly from          */
/* _PG_init.                                                            */
/* -------------------------------------------------------------------- */

#if PG_VERSION_NUM >= 150000
static void
xclaim_shmem_request_hook(void)
{
    if (prev_shmem_request_hook)
        prev_shmem_request_hook();

    RequestAddinShmemSpace(xclaim_shmem_size());
    RequestNamedLWLockTranche("xclaim_partition", xclaim_num_partitions);
}
#endif

/* -------------------------------------------------------------------- */
/* _PG_init                                                             */
/* -------------------------------------------------------------------- */

/*
 * IMPORTANT -- recovery-gate ordering rationale.
 *
 * `_PG_init` runs from `process_shared_preload_libraries()`, which
 * executes BEFORE `CreateSharedMemoryAndSemaphores()`. At that point
 * `XLogCtl` (the shared struct that `RecoveryInProgress()` dereferences
 * via `XLogCtl->SharedRecoveryState`) is still NULL -- calling
 * `RecoveryInProgress()` from `_PG_init` would crash the postmaster
 * with EXC_BAD_ACCESS before any log line is emitted.
 *
 * Correct ordering, matching the pg_stat_statements precedent:
 *   1. preload gate (`process_shared_preload_libraries_in_progress`) --
 *      this only checks a globally-set boolean; no shmem deref.
 *   2. ABI compat check.
 *   3. GUC define / shmem request / hook installs / lifecycle callbacks.
 *   4. Recovery gate is enforced in `XCLAIM_REQUIRE_INIT()`
 *      (`pg_xclaim.h`), which every SQL entry point invokes. At
 *      SQL-call time -- from a regular backend, after cluster startup
 *      completes -- `RecoveryInProgress()` accurately distinguishes
 *      hot-standby (true) from a primary that finished its own
 *      startup-recovery pass (false). Calling it from
 *      `xclaim_shmem_startup` would not work either: a primary in
 *      its initial WAL replay reports `true` there too, so the
 *      shmem-startup body cannot use the value as a primary-vs-standby
 *      discriminator. Contrib's pg_surgery uses the same
 *      defer-to-call-time pattern (a `RecoveryInProgress()` check inside
 *      its SQL functions, not at load).
 */
void
_PG_init(void)
{
    /*
     * Gate 1: pg_stat_statements-style preload check. If we got here via
     * LOAD or implicit load from CREATE EXTENSION on a *running* server
     * (not preload), return silently. SQL entry points raise the
     * customary ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE through
     * XCLAIM_REQUIRE_INIT at first call.
     *
     * This MUST be a silent return -- raising ERROR here would crash
     * `LOAD 'pg_xclaim'` smoke tests and confuse operators.
     *
     * This check is safe at preload time: it only consults a global
     * `bool` set by the postmaster before invoking
     * `process_shared_preload_libraries()`. No shared-memory deref.
     */
    if (!process_shared_preload_libraries_in_progress)
        return;

    /*
     * Gate 2: ABI compat. The shared-library disk file may have been
     * built against a different major (e.g. PG 17.x .so loaded into a
     * PG 18 server after a binary upgrade left the contrib dir behind).
     * Major-version is `PG_VERSION_NUM / 100` (e.g. 170009 -> 1700).
     */
    if (PG_VERSION_NUM / 100 != COMPILED_PG_VERSION_NUM_PREFIX)
    {
        /*
         * ERRCODE_FEATURE_NOT_SUPPORTED (0A000), not INTERNAL_ERROR (XX000).
         * ABI mismatch is operator-actionable misconfiguration (deploy
         * pipeline pointed the wrong .so at the wrong PG major), not a
         * bug in PostgreSQL or in pg_xclaim. The SQLSTATE should classify
         * accordingly so logs do not lead operators down a "where is the
         * internal bug" rabbit hole.
         */
        ereport(FATAL,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("pg_xclaim compiled against PG %d but running on PG %d -- refusing load",
                        COMPILED_PG_VERSION_NUM_PREFIX,
                        PG_VERSION_NUM / 100)));
    }

    /* GUC registration -- six variables. */
    xclaim_define_gucs();

    /*
     * Shared-memory request. PG 15 introduced shmem_request_hook; on
     * older releases the calls go directly from _PG_init. We support
     * PG 16+, so always go through the hook.
     */
#if PG_VERSION_NUM >= 150000
    prev_shmem_request_hook = shmem_request_hook;
    shmem_request_hook = xclaim_shmem_request_hook;
#else
    /* Fallback for PG versions without shmem_request_hook. */
    RequestAddinShmemSpace(xclaim_shmem_size());
    RequestNamedLWLockTranche("xclaim_partition", xclaim_num_partitions);
#endif

    /*
     * shmem_startup_hook chain. Implementation in pg_xclaim_shared.c
     * captures the previous hook itself (state stays local to that TU)
     * and installs xclaim_shmem_startup as the new hook.
     */
    xclaim_install_shmem_hook();

    /*
     * Lifecycle callbacks. RegisterXactCallback drives transaction-end
     * cleanup; before_shmem_exit guards against backend-exit races
     * where cleanup needs LWLocks still alive (HARD invariant: prefer
     * before_shmem_exit over on_shmem_exit / on_proc_exit).
     */
    RegisterXactCallback(xclaim_xact_callback, NULL);
    before_shmem_exit(xclaim_shmem_exit_cb, (Datum) 0);
}

/* -------------------------------------------------------------------- */
/* Real bodies for xclaim_shmem_size, xclaim_shmem_startup, and         */
/* xclaim_install_shmem_hook live in pg_xclaim_shared.c.                */
/* -------------------------------------------------------------------- */

/* -------------------------------------------------------------------- */
/* SQL-callable C entry points.                                         */
/*                                                                      */
/* `xclaim.try(int4, int4)` -> xclaim_try_pair                          */
/* `xclaim.try(int8)`       -> xclaim_try_solo                          */
/*                                                                      */
/* Function attributes (in sql/pg_xclaim--1.0.0-rc1.sql) are:           */
/*    LANGUAGE c                                                        */
/*    VOLATILE                                                          */
/*    PARALLEL RESTRICTED                                                */
/*    CALLED ON NULL INPUT                                               */
/*                                                                      */
/* Comparison vs `pg_try_advisory_xact_lock` (verified on PG 17 via     */
/* pg_proc.provolatile / proparallel / proisstrict):                    */
/*    PG core   -> v / r / t  (VOLATILE / RESTRICTED / STRICT)          */
/*    xclaim.try -> v / r / f  (VOLATILE / RESTRICTED / CALLED ON NULL) */
/* The volatility and parallel mode match exactly; the strictness       */
/* DIFFERS deliberately. PG core's STRICT lets the planner short-       */
/* circuit a NULL arg to a NULL result silently -- xclaim wants loud   */
/* failure on NULL inputs because a NULL key is a programming bug,     */
/* not a no-op; silent NULL would mask the bug at call site. The C    */
/* body raises `ereport(ERROR, ERRCODE_NULL_VALUE_NOT_ALLOWED)`.       */
/* README + README_EN document this delta in the parity table.        */
/*                                                                      */
/* The 12-step acquisition algorithm is implemented in                 */
/* pg_xclaim_acquire.c. The entry points are thin: marshal args, build */
/* the XClaimKey with the MANDATORY `memset` before field assignment   */
/* (HASH_BLOBS hashes raw bytes including padding bytes), and          */
/* dispatch.                                                           */
/* -------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(xclaim_try_pair);
PG_FUNCTION_INFO_V1(xclaim_try_solo);

/*
 * xclaim_try_pair(classid int4, objid int4) RETURNS bool
 *      High-cardinality claim acquire; signature mirrors
 *      `pg_try_advisory_xact_lock(int4, int4)` for legacy migration.
 *
 *      Key construction:
 *          k1 = ((int64)(uint32) classid << 32) | (uint32) objid
 *      The cast-through-uint32 prevents sign-extension when negative
 *      classid or objid values are supplied -- callers may legitimately
 *      pass any int4, including INT_MIN.
 */
Datum
xclaim_try_pair(PG_FUNCTION_ARGS)
{
    int32       classid;
    int32       objid;
    XClaimKey   lk;

    /*
     * MUST be the FIRST executable statement: gates against
     * shared_preload_libraries omission and hot-standby state.
     */
    XCLAIM_REQUIRE_INIT();

    /*
     * CALLED ON NULL INPUT contract: the C body sees NULL args and
     * must reject them. Advisory-parity behaviour (ereport ERROR,
     * NOT silent NULL return).
     */
    if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("pg_xclaim: xclaim.try arguments must not be NULL")));

    classid = PG_GETARG_INT32(0);
    objid   = PG_GETARG_INT32(1);

    /*
     * MANDATORY memset before field assignment. HASH_BLOBS hashes raw
     * bytes including padding bytes -- without memset an
     * ABI-introduced hole would silently break key equality.
     */
    memset(&lk, 0, sizeof(lk));
    lk.dbid = MyDatabaseId;
    lk.form = XCLAIM_FORM_PAIR;
    lk.k1   = ((int64) (uint32) classid << 32) | (uint32) objid;

    PG_RETURN_BOOL(xclaim_try_internal(&lk));
}

/*
 * xclaim_try_solo(key int8) RETURNS bool
 *      High-cardinality claim acquire; signature mirrors
 *      `pg_try_advisory_xact_lock(int8)` for legacy migration.
 *
 *      Key construction:
 *          k1 = full int8 key (no packing)
 *      Distinct keyspace from the (int4, int4) form via the `form`
 *      discriminator -- xclaim.try(99::bigint) and xclaim.try(0, 99)
 *      hash to different XClaimEntries even though the numeric value
 *      of k1 is identical (the form byte differs).
 */
Datum
xclaim_try_solo(PG_FUNCTION_ARGS)
{
    int64       key;
    XClaimKey   lk;

    XCLAIM_REQUIRE_INIT();

    if (PG_ARGISNULL(0))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("pg_xclaim: xclaim.try argument must not be NULL")));

    key = PG_GETARG_INT64(0);

    memset(&lk, 0, sizeof(lk));
    lk.dbid = MyDatabaseId;
    lk.form = XCLAIM_FORM_SOLO;
    lk.k1   = key;

    PG_RETURN_BOOL(xclaim_try_internal(&lk));
}
