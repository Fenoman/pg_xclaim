/*-------------------------------------------------------------------------
 *
 * pg_xclaim_stats.c
 *      Atomic-counter stats, capacity watermark logging, backend-local
 *      count, debug introspection (shared-state snapshots), and
 *      the test-only stale-entry injector.
 *
 * Surface summary:
 *   xclaim.count             -- backend-local count, PARALLEL RESTRICTED
 *                               STABLE.
 *   xclaim.debug             -- consistent, all-partition LWLock,
 *                               superuser only; PARALLEL UNSAFE STABLE.
 *   xclaim.debug_snapshot    -- all-partition shared LWLock snapshot,
 *                               pg_monitor; PARALLEL RESTRICTED STABLE.
 *   xclaim.stats             -- 14 columns (counters / gauges); 80/90/95%
 *                               capacity watermark logging with 60s
 *                               suppression. PARALLEL RESTRICTED STABLE.
 *   pg_xclaim.enabled = off  -- count, stats, debug, debug_snapshot all
 *                               return zero/empty without touching shared
 *                               state and bump `disabled_calls`.
 *   xclaim.debug_inject_stale -- superuser-only test helper that seeds
 *                                an XClaimEntry with a guaranteed-stale
 *                                owner triple so the reaper test can
 *                                observe a successful reap.
 *                                PARALLEL UNSAFE VOLATILE.
 *
 * HARD invariants enforced here:
 *   * stats counters read via pg_atomic_read_u64 (lock-free atomic load).
 *   * watermark logging uses static last-warn timestamp + threshold
 *     comparisons; emits at most one message per 60s per backend.
 *   * debug_snapshot holds ALL partition LWLocks SHARED for the entire
 *     scan because dynahash has no "scan one partition" iterator.
 *   * debug holds ALL partition LWLocks SHARED for the entire scan and
 *     releases them on PG_CATCH (LWLockReleaseAll for ERROR paths).
 *   * Tuplestore SRF MaterializeMode pattern; per-query memory context
 *     for tuplestore allocation; rsinfo ReturnSetInfo validated.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <string.h>

#include "access/parallel.h"            /* IsParallelWorker */
#include "access/htup_details.h"
#include "catalog/pg_type_d.h"          /* INT8OID, BOOLOID, NUMERICOID */
#include "datatype/timestamp.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"                  /* MyDatabaseId, MaxBackends */
#include "port/atomics.h"
#include "storage/lwlock.h"
#include "utils/builtins.h"
#include "utils/elog.h"
#include "utils/hsearch.h"
#include "utils/numeric.h"
#include "utils/timestamp.h"
#include "utils/tuplestore.h"

#include "pg_xclaim.h"
#include "pg_xclaim_compat.h"
#include "pg_xclaim_internal.h"
#include "pg_xclaim_local.h"

/* -------------------------------------------------------------------- */
/* Watermark logging.                                                   */
/*                                                                      */
/* Emit a LOG-level message when capacity_pct crosses one of three     */
/* bands: the configurable warn band (pg_xclaim.capacity_warn_pct,    */
/* default 80), 90%, or 95%. A 60-second suppression window prevents  */
/* a sustained burst from flooding the log. 90% and 95% are hardcoded */
/* (the WARNING ladder kicks in at 95%).                              */
/*                                                                      */
/* Statics are PER BACKEND -- this is intentional. Multiple backends   */
/* observing capacity pressure will each emit ONE message per 60s,    */
/* which is the operator-observability behaviour we want (a single    */
/* shared timestamp would silence the leader once and never wake up).  */
/*                                                                      */
/* Precomputed absolute thresholds.                                    */
/* The acquisition hot path used to evaluate                            */
/*   pct = (100 * capacity_used) / max_claims                           */
/* on every successful HASH_ENTER -- a 64-bit integer division costs   */
/* 10-40 cycles on aarch64/amd64. max_claims is PGC_POSTMASTER (frozen */
/* for the cluster's lifetime) and warn_pct is PGC_SIGHUP, so we cache */
/* the absolute trip points and reload `warn` only when warn_pct       */
/* actually moves under us. The watermark check reduces to three       */
/* int64 comparisons against per-backend statics.                       */
/* -------------------------------------------------------------------- */

static int64 xcl_threshold_95   = INT64_MAX;    /* 95% of max_claims   */
static int64 xcl_threshold_90   = INT64_MAX;    /* 90% of max_claims   */
static int64 xcl_threshold_warn = INT64_MAX;    /* warn_pct * max_claims / 100 */
static int   xcl_threshold_warn_seen_pct = -1;  /* last warn_pct used  */

#define XCLAIM_WATERMARK_SUPPRESSION_USEC ((int64) 60 * USECS_PER_SEC)

/* Per-backend last-emit timestamp; persists for the backend's lifetime. */
static TimestampTz xclaim_last_watermark_log = 0;

/* Per-backend "highest observed band" (0=none, warn_pct=warn band,
 * 90=90%, 95=95%; warn_pct comes from pg_xclaim.capacity_warn_pct).
 * Resets when capacity drops below warn_pct so a subsequent climb
 * re-fires. */
static int         xclaim_last_watermark_band = 0;

/*
 * xclaim_capacity_watermark_check
 *      Called from the acquisition path after a successful HASH_ENTER
 *      (and thus after the dynahash entry-count has incremented). Cheap
 *      no-op when capacity is below the configured warn percentage.
 *
 *      The `used` argument is unused; the body reads `capacity_used`
 *      directly from `XClaimCtl->live_capacity` (atomic counter
 *      mirroring HASH_ENTER/HASH_REMOVE). Callers may pass 0 to skip
 *      a redundant atomic load on the hot path. The argument stays
 *      in the signature to keep the internal call surface stable
 *      across modules.
 *
 *      live_capacity is preferred over `hash_get_num_entries(XClaimHash)`
 *      -- the latter walks all partitions; the atomic counter is a
 *      single-cache-line read and reflects the live count exactly.
 *
 *      Bands are 80/90/95%. The 80% band emits LOG, 90% LOG, 95% WARNING
 *      (95 escalates to WARNING).
 */
void
xclaim_capacity_watermark_check(uint64 used)
{
    int64           capacity_used;
    int             pct;
    int             warn_pct;
    int             band;
    TimestampTz     now;
    int             level;

    (void) used;                            /* hook contract; we read live count */

    if (XClaimCtl == NULL || XClaimHash == NULL)
        return;                             /* not yet initialized */

    capacity_used = (int64) pg_atomic_read_u64(&XClaimCtl->live_capacity);
    if (capacity_used <= 0 || xclaim_max_claims <= 0)
        return;

    warn_pct = xclaim_capacity_warn_pct;    /* GUC, default 80 */

    /*
     * Lazy threshold cache.
     *
     * max_claims is PGC_POSTMASTER so the 90% / 95% trip points are
     * frozen for the cluster's lifetime; they are computed once and
     * never revisited. warn_pct is PGC_SIGHUP so the warn trip point
     * is recomputed on the (rare) reload that actually moves it.
     *
     * Replacing `(100 * used) / max_claims` with three int64 compares
     * skips a 64-bit integer division (10-40 cycles on aarch64/amd64)
     * on every acquisition that reaches this function -- the hot path
     * for xclaim.try and the per-bulk-call tail of xclaim.try_many.
     */
    /*
     * Ceiling division: the watermark fires exactly when
     * `floor(100 * used / max_claims) >= pct`, equivalently
     * `used >= ceil(pct * max_claims / 100)`. Truncating integer
     * division would fire one slot too early at the band boundary;
     * `+ 99` carries the ceiling without floating point. The cap_warn
     * and cap_error regress baselines pin the exact slot at which
     * each band's message lands.
     */
    if (unlikely(xcl_threshold_95 == INT64_MAX))
    {
        xcl_threshold_95 = ((int64) xclaim_max_claims * 95 + 99) / 100;
        xcl_threshold_90 = ((int64) xclaim_max_claims * 90 + 99) / 100;
    }
    if (unlikely(warn_pct != xcl_threshold_warn_seen_pct))
    {
        xcl_threshold_warn          = ((int64) xclaim_max_claims * warn_pct + 99) / 100;
        xcl_threshold_warn_seen_pct = warn_pct;
    }

    /*
     * Decide the highest band currently crossed. The warn ladder starts
     * at the configured capacity_warn_pct; the hardcoded escalation bands
     * (90, 95) only apply when they sit strictly ABOVE warn_pct. A band
     * below warn_pct must never fire -- otherwise raising warn_pct past 90
     * would let the 90 band emit before the operator-configured floor.
     * Higher bands take precedence. Reset to 0 below the warn threshold so
     * a later re-climb fires again.
     */
    if (warn_pct < 95 && capacity_used >= xcl_threshold_95)
        band = 95;
    else if (warn_pct < 90 && capacity_used >= xcl_threshold_90)
        band = 90;
    else if (capacity_used >= xcl_threshold_warn)
        band = warn_pct;
    else
        band = 0;

    if (band == 0)
    {
        /*
         * Below threshold -- reset our "last seen" band so a subsequent
         * climb back into 80%+ territory re-emits.
         */
        xclaim_last_watermark_band = 0;
        return;
    }

    /*
     * Suppression: only emit if (a) we've crossed into a HIGHER band than
     * the last observed, OR (b) 60s have elapsed since the last emit at
     * the same band. Either condition produces actionable signal:
     *  - band escalation = capacity is getting worse (informs operator)
     *  - re-emit every 60s = sustained pressure (visible in logs)
     */
    now = GetCurrentTimestamp();

    if (band <= xclaim_last_watermark_band &&
        (now - xclaim_last_watermark_log) < XCLAIM_WATERMARK_SUPPRESSION_USEC)
        return;                             /* suppressed */

    /*
     * About to emit. Compute the exact integer percentage now -- the
     * threshold-based hot path above never needs it, so the single
     * idiv lands on the rare emit path instead of every acquisition.
     */
    pct = (int) ((100 * capacity_used) / (int64) xclaim_max_claims);

    /* WARNING at 95%; LOG at 80% / 90%. */
    level = (band >= 95) ? WARNING : LOG;

    /*
     * Log prefix matches `docs/runbook.md` §3.1 verbatim
     * ("pg_xclaim: capacity watermark crossed -- NN%% (used / max
     * claims)") so an operator's `grep "capacity watermark crossed"`
     * over the server log catches every occurrence regardless of the
     * band/level. Integer percentage (computed at integer precision
     * above) avoids float-jitter in regression tests.
     */
    ereport(level,
            (errmsg("pg_xclaim: capacity watermark crossed -- %d%% (%lld / %d claims)",
                    pct,
                    (long long) capacity_used,
                    xclaim_max_claims),
             errhint("Raise pg_xclaim.max_claims or investigate "
                     "long-running transactions holding claims.")));

    xclaim_last_watermark_log  = now;
    xclaim_last_watermark_band = band;
}

/* -------------------------------------------------------------------- */
/* `xclaim_check_capacity_watermark` is forward-declared in pg_xclaim.h */
/* and called from the acquisition path; the body delegates to the     */
/* real implementation here.                                            */
/* -------------------------------------------------------------------- */

void
xclaim_check_capacity_watermark(uint64 used)
{
    xclaim_capacity_watermark_check(used);
}

/* -------------------------------------------------------------------- */
/* xclaim.count() -- backend-local count.                               */
/*                                                                      */
/* PARALLEL RESTRICTED STABLE: reads this backend's local count via     */
/* xclaim_local_count() -- per-backend state. Parallel workers do not   */
/* inherit the leader's local set, so the SQL wrapper keeps execution   */
/* in the leader backend.                                               */
/*                                                                      */
/* enabled=off: return 0 (no claims held under kill switch). The caller */
/* sees zero for the count; stats.disabled_calls increments.            */
/* -------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(xclaim_count);

Datum
xclaim_count(PG_FUNCTION_ARGS)
{
    XCLAIM_REQUIRE_INIT();

    if (!xclaim_enabled)
    {
        pg_atomic_fetch_add_u64(&XClaimCtl->disabled_calls, 1);
        PG_RETURN_INT64(0);
    }

    PG_RETURN_INT64((int64) xclaim_local_count());
}

/* -------------------------------------------------------------------- */
/* xclaim.stats() -- 14-column composite SRF (single row).              */
/*                                                                      */
/* Columns (in declared order):                                          */
/*   capacity_max int8                                                   */
/*   capacity_used int8                                                  */
/*   capacity_pct  numeric(5,2)                                          */
/*   total_acquires int8                                                 */
/*   reentrant_hits int8                                                 */
/*   conflicts int8                                                      */
/*   capacity_errors int8                                                */
/*   capacity_warnings int8                                              */
/*   reaped_stale int8                                                   */
/*   cleanup_misses int8                                                 */
/*   disabled_calls int8                                                 */
/*   peak_per_backend int8                                               */
/*   debug_scans int8                                                    */
/*   session_resets int8                                                 */
/*                                                                      */
/* PARALLEL RESTRICTED: counters are pg_atomic_uint64 (lock-free       */
/* reads) and the dynahash entry count is a plain counter load, but    */
/* the per-backend slot sums in xclaim.stats() read per-backend memory  */
/* that parallel workers do not inherit. Keeping execution in the      */
/* leader gives a consistent view of leader-local counters; stale      */
/* (slightly out-of-date) values across backends are acceptable --      */
/* this is observability, not correctness.                              */
/* -------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(xclaim_stats);

#define XCLAIM_STATS_COLS 14

Datum
xclaim_stats(PG_FUNCTION_ARGS)
{
    ReturnSetInfo  *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    TupleDesc       tupdesc;
    Tuplestorestate *tupstore;
    MemoryContext   per_query_ctx;
    MemoryContext   oldcontext;
    Datum           values[XCLAIM_STATS_COLS];
    bool            nulls[XCLAIM_STATS_COLS];
    int64           capacity_max;
    int64           capacity_used;
    Numeric         capacity_pct_num;
    int64           total_acquires;
    int64           reentrant_hits;
    int64           conflicts;
    int64           capacity_errors;
    int64           capacity_warnings;
    int64           reaped_stale;
    int64           cleanup_misses;
    int64           disabled_calls;
    int64           debug_scans;
    int64           peak_per_backend;
    int64           session_resets;

    XCLAIM_REQUIRE_INIT();

    /* Tuplestore SRF preflight (MaterializeMode -- standard pattern). */
    if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("set-valued function called in context that cannot accept a set")));
    if (!(rsinfo->allowedModes & SFRM_Materialize))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("materialize mode required, but it is not allowed in this context")));

    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("xclaim.stats: function returning record called in context "
                        "that cannot accept type record")));

    /*
     * enabled=off: still produce a single row (with zeros for all GAUGES;
     * counters are honest reads from atomics). The caller can detect the
     * disabled state via disabled_calls > 0 (pre-incremented before the
     * read here) and capacity_used = whatever was already in shmem (we
     * don't pretend it is zero -- that would mislead operators).
     */
    /*
     * STABLE function with observability side-effect.
     * SQL declares xclaim.stats() as STABLE; the atomic counter
     * increment below is an observability bump on shared memory,
     * NOT a logical row-set mutation -- functionally equivalent to
     * PG core bumping wait_event counters during a STABLE function
     * call. The planner may collapse repeated xclaim.stats()
     * invocations within a single statement; under such collapse
     * `disabled_calls` increments by however many physical calls
     * actually executed, not by the SQL-visible call count. This is
     * acceptable: the counter's purpose is to detect "did anyone
     * observe enabled=off?" -- a non-zero value is
     * sufficient signal regardless of the exact count. Operators
     * relying on exact counts should use enabled=off + look at
     * absence of acquisition counters instead.
     */
    if (!xclaim_enabled)
        pg_atomic_fetch_add_u64(&XClaimCtl->disabled_calls, 1);

    /* Snapshot all counters atomically (lock-free reads). */
    capacity_max               = (int64) xclaim_max_claims;
    capacity_used              = (int64) pg_atomic_read_u64(&XClaimCtl->live_capacity);

    /*
     * Per-backend stat slots. Hot-path counters live in
     * XClaimBackendInfos[procno] to avoid global cache-line ping-pong;
     * the SRF reader sums across all MaxBackends slots for a global view.
     * Reads are eventually-consistent (a slot may bump between two
     * reads); acceptable for observability. We deliberately include all
     * slots, not just live backends -- a slot whose backend has exited
     * still contains its lifetime counters until cluster restart.
     */
    {
        uint64 sum_acquires = 0;
        uint64 sum_reentrant = 0;
        uint64 sum_conflicts = 0;
        int    bi;

        for (bi = 0; bi < MaxBackends; bi++)
        {
            sum_acquires  += pg_atomic_read_u64(&XClaimBackendInfos[bi].total_acquires_local);
            sum_reentrant += pg_atomic_read_u64(&XClaimBackendInfos[bi].reentrant_hits_local);
            sum_conflicts += pg_atomic_read_u64(&XClaimBackendInfos[bi].conflicts_local);
        }
        total_acquires = (int64) sum_acquires;
        reentrant_hits = (int64) sum_reentrant;
        conflicts      = (int64) sum_conflicts;
    }

    capacity_errors            = (int64) pg_atomic_read_u64(&XClaimCtl->capacity_errors);
    capacity_warnings          = (int64) pg_atomic_read_u64(&XClaimCtl->capacity_warnings);
    reaped_stale               = (int64) pg_atomic_read_u64(&XClaimCtl->reaped_stale);
    cleanup_misses             = (int64) pg_atomic_read_u64(&XClaimCtl->cleanup_misses);
    disabled_calls             = (int64) pg_atomic_read_u64(&XClaimCtl->disabled_calls);
    debug_scans                = (int64) pg_atomic_read_u64(&XClaimCtl->debug_scans);
    session_resets             = (int64) pg_atomic_read_u64(&XClaimCtl->session_resets);

    /* peak_per_backend: combine the global (multi-backend high-water
     * mark, written via CAS in the acquire path) with the per-backend
     * peak so a single-backend session is not silently shadowed. Take
     * max of the two so the stat is monotonic. */
    {
        int64 global_peak  = (int64) pg_atomic_read_u64(&XClaimCtl->peak_per_backend);
        int64 backend_peak = (int64) xclaim_local_peak();
        peak_per_backend = (global_peak > backend_peak) ? global_peak : backend_peak;
    }

    /*
     * capacity_pct as numeric(5,2). Numeric arithmetic avoids the float
     * precision pitfalls that would show up in regression tests
     * (e.g. 99.99% rendered as 99.99000003 by float).
     */
    {
        Datum   used_d   = DirectFunctionCall1(int8_numeric, Int64GetDatum(capacity_used));
        Datum   max_d    = DirectFunctionCall1(int8_numeric, Int64GetDatum(capacity_max));
        Datum   hundred  = DirectFunctionCall1(int8_numeric, Int64GetDatum((int64) 100));
        Datum   numerator = DirectFunctionCall2(numeric_mul, used_d, hundred);
        Datum   pct_raw  = DirectFunctionCall2(numeric_div, numerator, max_d);
        /* Force scale 2 (numeric(5,2) -- typmod = ((5 << 16) | 2) + VARHDRSZ). */
        int32   typmod   = ((5 << 16) | 2) + VARHDRSZ;
        Datum   pct_clamped = DirectFunctionCall2(numeric, pct_raw, Int32GetDatum(typmod));
        capacity_pct_num = DatumGetNumeric(pct_clamped);
    }

    /* Build the single tuplestore row. */
    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    oldcontext = MemoryContextSwitchTo(per_query_ctx);
    tupstore = tuplestore_begin_heap(true, false, work_mem);
    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult  = tupstore;
    rsinfo->setDesc    = tupdesc;
    MemoryContextSwitchTo(oldcontext);

    memset(nulls, 0, sizeof(nulls));
    values[0]  = Int64GetDatum(capacity_max);
    values[1]  = Int64GetDatum(capacity_used);
    values[2]  = NumericGetDatum(capacity_pct_num);
    values[3]  = Int64GetDatum(total_acquires);
    values[4]  = Int64GetDatum(reentrant_hits);
    values[5]  = Int64GetDatum(conflicts);
    values[6]  = Int64GetDatum(capacity_errors);
    values[7]  = Int64GetDatum(capacity_warnings);
    values[8]  = Int64GetDatum(reaped_stale);
    values[9]  = Int64GetDatum(cleanup_misses);
    values[10] = Int64GetDatum(disabled_calls);
    values[11] = Int64GetDatum(peak_per_backend);
    values[12] = Int64GetDatum(debug_scans);
    values[13] = Int64GetDatum(session_resets);

    tuplestore_putvalues(tupstore, tupdesc, values, nulls);

    return (Datum) 0;
}

/* -------------------------------------------------------------------- */
/* Debug column count: 8 columns.                                       */
/*   database_oid oid, form text ('solo'|'pair'),                       */
/*   scope int4, key int8, owner_pid int4,                              */
/*   owner_procno int4, owner_lxid int8, owner_token int8.              */
/*                                                                      */
/* The `form` column is mandatory: without it FORM_SOLO / FORM_PAIR     */
/* entries with the same numeric k1 are indistinguishable.              */
/* -------------------------------------------------------------------- */

#define XCLAIM_DEBUG_COLS 8

/*
 * xclaim_emit_debug_row
 *      Build one tuple from an XClaimEntry and push it into the
 *      tuplestore. Decomposes (form, k1) into (form_text, scope, key):
 *        FORM_PAIR -> form='pair', scope=k1>>32, key=k1 & 0xFFFFFFFF
 *        FORM_SOLO -> form='solo', scope=0,      key=k1
 *
 *      Caller already switched to the tuplestore-owning memory context
 *      so palloc inside CStringGetTextDatum is anchored correctly.
 */
static void
xclaim_emit_debug_row(Tuplestorestate *tupstore, TupleDesc tupdesc,
                      const XClaimEntry *e)
{
    Datum   values[XCLAIM_DEBUG_COLS];
    bool    nulls[XCLAIM_DEBUG_COLS];
    int32   scope;
    int64   keyval;
    const char *form_text;

    memset(nulls, 0, sizeof(nulls));

    if (e->key.form == XCLAIM_FORM_PAIR)
    {
        form_text = "pair";
        scope     = (int32) ((uint64) e->key.k1 >> 32);
        keyval    = (int64) (int32) (e->key.k1 & 0xFFFFFFFFLL);
    }
    else
    {
        form_text = "solo";
        scope     = 0;
        keyval    = e->key.k1;
    }

    values[0] = ObjectIdGetDatum(e->key.dbid);
    values[1] = CStringGetTextDatum(form_text);
    values[2] = Int32GetDatum(scope);
    values[3] = Int64GetDatum(keyval);
    values[4] = Int32GetDatum(e->owner_pid);
    values[5] = Int32GetDatum(e->owner_procno);
    values[6] = Int64GetDatum((int64) e->owner_lxid);
    values[7] = Int64GetDatum((int64) e->owner_token);

    tuplestore_putvalues(tupstore, tupdesc, values, nulls);
    pfree(DatumGetPointer(values[1]));
}

/* -------------------------------------------------------------------- */
/* xclaim.debug_snapshot() -- shared-state snapshot for pg_monitor.    */
/*                                                                      */
/* PARALLEL RESTRICTED STABLE. Acquires SHARED LWLocks on ALL partitions for */
/* the scan. The result is consistent with respect to concurrent        */
/* xclaim writers for the duration of the scan, but the function may    */
/* refuse to run when num_partitions exceeds the MAX_SIMUL_LWLOCKS      */
/* safety margin.                                                       */
/*                                                                      */
/* Concurrency: dynahash hash_seq_init/hash_seq_search visits ALL       */
/* entries. Since we hold all partition locks, the loop can emit every  */
/* row directly; no per-partition filtering is attempted.               */
/*                                                                      */
/* Memory: tuplestore is created in per-query context; per-row palloc   */
/* (CStringGetTextDatum) lands there too.                               */
/* -------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(xclaim_debug_snapshot);

Datum
xclaim_debug_snapshot(PG_FUNCTION_ARGS)
{
    ReturnSetInfo  *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    TupleDesc       tupdesc;
    Tuplestorestate *tupstore;
    MemoryContext   per_query_ctx;
    MemoryContext   oldcontext;
    int             num_partitions;
    int             p;

    XCLAIM_REQUIRE_INIT();

    if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("set-valued function called in context that cannot accept a set")));
    if (!(rsinfo->allowedModes & SFRM_Materialize))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("materialize mode required, but it is not allowed in this context")));

    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("xclaim.debug_snapshot: function returning record called in context "
                        "that cannot accept type record")));

    /*
     * enabled=off short-circuit: return empty tuplestore; bump counter.
     * The caller observes zero rows; xclaim.stats().disabled_calls > 0
     * is the diagnostic.
     */
    if (!xclaim_enabled)
        pg_atomic_fetch_add_u64(&XClaimCtl->disabled_calls, 1);

    pg_atomic_fetch_add_u64(&XClaimCtl->debug_scans, 1);

    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    oldcontext = MemoryContextSwitchTo(per_query_ctx);
    tupstore = tuplestore_begin_heap(true, false, work_mem);
    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult  = tupstore;
    rsinfo->setDesc    = tupdesc;
    MemoryContextSwitchTo(oldcontext);

    if (!xclaim_enabled)
        return (Datum) 0;

    num_partitions = XClaimCtl->num_partitions;

    /*
     * dynahash safety:
     *
     * `hash_seq_search` walks ALL buckets of the hash table -- not just
     * one partition's slice. With HASH_PARTITION, the partition LWLocks
     * synchronise per-partition mutators only; a writer modifying
     * partition X's bucket linked list concurrently with our scan that
     * happens to traverse a bucket in partition X observes inconsistent
     * state (bucket pointer torn between dynahash's segment-pointer
     * write and the ELEMENT->link assignment). The original
     * implementation here held ONLY the current `p`'s partition lock
     * SHARED while running a full hash_seq_search and filtering by
     * partition_id -- that is incorrect: writers in partitions != p
     * are NOT serialised with us, and dynahash does not document a
     * "scan one partition" mode.
     *
     * The minimal correct behavior is to acquire ALL partition LWLocks
     * SHARED for the entire scan, identical to xclaim.debug(). This
     * does collapse the two functions to the same lock pressure
     * profile -- documented below.
     *
     * MAX_SIMUL_LWLOCKS guard mirrors xclaim.debug() -- PG limits
     * concurrent LWLocks per backend to ~200; we cap at 192 to leave
     * headroom for catalog access etc.
     */
    if (num_partitions > 192)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("xclaim.debug_snapshot() cannot acquire %d partition LWLocks "
                        "simultaneously (PG MAX_SIMUL_LWLOCKS = ~200)",
                        num_partitions),
                 errhint("Set pg_xclaim.num_partitions <= 192 in test "
                         "clusters that use xclaim.debug_snapshot().")));

    /*
     * Acquire ALL partition LWLocks SHARED. Errors inside the scan loop
     * are wrapped with PG_TRY/PG_CATCH so the locks are released even
     * on ereport (e.g. tuplestore palloc OOM). `seq_initialized` gates
     * `hash_seq_term` in PG_CATCH so we only call it when the iterator
     * was actually started.
     */
    {
        HASH_SEQ_STATUS seq_ds;
        volatile bool   seq_ds_initialized = false;
        XClaimEntry    *entry_ds;

        PG_TRY();
        {
            for (p = 0; p < num_partitions; p++)
                LWLockAcquire(&XClaimPartitionLocks[p].lock, LW_SHARED);

            hash_seq_init(&seq_ds, XClaimHash);
            seq_ds_initialized = true;
            while ((entry_ds = (XClaimEntry *) hash_seq_search(&seq_ds)) != NULL)
            {
                MemoryContextSwitchTo(per_query_ctx);
                xclaim_emit_debug_row(tupstore, tupdesc, entry_ds);
                MemoryContextSwitchTo(oldcontext);
            }
            /* hash_seq_search NULL return deregisters automatically. */
            seq_ds_initialized = false;

            for (p = num_partitions - 1; p >= 0; p--)
                LWLockRelease(&XClaimPartitionLocks[p].lock);
        }
        PG_CATCH();
        {
            int q;

            if (seq_ds_initialized)
                hash_seq_term(&seq_ds);

            for (q = num_partitions - 1; q >= 0; q--)
            {
                LWLock *l = &XClaimPartitionLocks[q].lock;
                if (LWLockHeldByMe(l))
                    LWLockRelease(l);
            }
            PG_RE_THROW();
        }
        PG_END_TRY();
    }

    return (Datum) 0;
}

/* -------------------------------------------------------------------- */
/* xclaim.debug() -- consistent all-partition snapshot.                */
/*                                                                      */
/* PARALLEL UNSAFE STABLE. Holds SHARED LWLock on EVERY partition for  */
/* the entire scan -- serializes the whole extension under load. SQL   */
/* surface restricted to superuser via REVOKE PUBLIC (no GRANT).       */
/*                                                                      */
/* Use case: regression tests that need a single consistent snapshot   */
/* across all partitions. NOT for routine production polling; use      */
/* xclaim.stats() for steady observability.                            */
/*                                                                      */
/* Lock ordering: ascending partition index. Other code paths (acquire,*/
/* cleanup) lock at most ONE partition at a time, so cross-partition  */
/* deadlock cannot occur regardless of our order; we use ascending so  */
/* any multi-partition operation has a documented total order.         */
/* -------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(xclaim_debug);

Datum
xclaim_debug(PG_FUNCTION_ARGS)
{
    ReturnSetInfo  *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    TupleDesc       tupdesc;
    Tuplestorestate *tupstore;
    MemoryContext   per_query_ctx;
    MemoryContext   oldcontext;
    int             num_partitions;
    int             p;
    HASH_SEQ_STATUS seq;
    /*
     * `seq_initialized`: hash_seq_term dereferences `seq.hashp`, which
     * is set by hash_seq_init. Calling hash_seq_term before init
     * touches uninitialised stack memory. The flag lets PG_CATCH
     * decide whether to terminate the iterator -- LWLockAcquire on
     * the success path doesn't ereport, but defensive against code
     * added between init and the scan loop.
     */
    volatile bool   seq_initialized = false;
    XClaimEntry    *entry;

    XCLAIM_REQUIRE_INIT();

    if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("set-valued function called in context that cannot accept a set")));
    if (!(rsinfo->allowedModes & SFRM_Materialize))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("materialize mode required, but it is not allowed in this context")));

    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("xclaim.debug: function returning record called in context "
                        "that cannot accept type record")));

    if (!xclaim_enabled)
        pg_atomic_fetch_add_u64(&XClaimCtl->disabled_calls, 1);

    pg_atomic_fetch_add_u64(&XClaimCtl->debug_scans, 1);

    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    oldcontext = MemoryContextSwitchTo(per_query_ctx);
    tupstore = tuplestore_begin_heap(true, false, work_mem);
    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult  = tupstore;
    rsinfo->setDesc    = tupdesc;
    MemoryContextSwitchTo(oldcontext);

    if (!xclaim_enabled)
        return (Datum) 0;

    num_partitions = XClaimCtl->num_partitions;

    /*
     * MAX_SIMUL_LWLOCKS guard: PG limits each backend to at most 200
     * simultaneous LWLocks (`MAX_SIMUL_LWLOCKS` in lwlock.c). The
     * production default `num_partitions = 128` stays comfortably
     * inside this budget; clusters that raise it above 192 (e.g. to
     * 256 on >100-core deployments) will see this function refuse with
     * the message below. xclaim.debug_snapshot() has the same all-lock
     * scan guard; use xclaim.stats() for routine production
     * observability.
     *
     * 192 is a safe margin -- PG core may take a handful of LWLocks on
     * its own during the call (catalog access, snapshot, etc).
     */
    if (num_partitions > 192)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("xclaim.debug() cannot acquire %d partition LWLocks "
                        "simultaneously (PG MAX_SIMUL_LWLOCKS = ~200)",
                        num_partitions),
                 errhint("Set pg_xclaim.num_partitions <= 192 in test "
                         "clusters that use xclaim.debug(); use xclaim.stats() "
                         "for routine production observability.")));

    /*
     * Acquire ALL partition LWLocks SHARED in ascending index order. On
     * PG_CATCH we release them in REVERSE order (LIFO) for cleanliness.
     * Errors inside the scan loop are wrapped with PG_TRY/PG_CATCH so
     * the locks are guaranteed released.
     */
    PG_TRY();
    {
        for (p = 0; p < num_partitions; p++)
            LWLockAcquire(&XClaimPartitionLocks[p].lock, LW_SHARED);

        hash_seq_init(&seq, XClaimHash);
        seq_initialized = true;
        while ((entry = (XClaimEntry *) hash_seq_search(&seq)) != NULL)
        {
            MemoryContextSwitchTo(per_query_ctx);
            xclaim_emit_debug_row(tupstore, tupdesc, entry);
            MemoryContextSwitchTo(oldcontext);
        }
        /*
         * hash_seq_search returning NULL deregisters the seq itself
         * (dynahash convention). Mark our flag false so PG_CATCH
         * does NOT double-deregister.
         */
        seq_initialized = false;

        for (p = num_partitions - 1; p >= 0; p--)
            LWLockRelease(&XClaimPartitionLocks[p].lock);
    }
    PG_CATCH();
    {
        /*
         * Terminate the hash_seq iterator first. dynahash tracks
         * in-flight scans in a process-global fixed-size array
         * (seq_scan_tables[MAX_SEQ_SCANS]); an abandoned hash_seq_search
         * leaves the HTAB registered there, so the next hash_seq_init
         * for the SAME HTAB can assert (or worse, silently corrupt
         * iteration). hash_seq_term requires
         * hash_seq_init to have populated `seq.hashp` first, so we
         * gate on the `seq_initialized` flag tracked in the TRY body.
         *
         * Then release every lock we may have acquired so far. We do
         * not know which partition failed; iterate all and let
         * LWLockHeldByMe release silently if we never acquired it
         * (LWLockReleaseAll is the canonical contrib-module pattern;
         * we replicate the safe subset by iterating in reverse).
         */
        int q;

        if (seq_initialized)
            hash_seq_term(&seq);

        for (q = num_partitions - 1; q >= 0; q--)
        {
            LWLock *l = &XClaimPartitionLocks[q].lock;
            if (LWLockHeldByMe(l))
                LWLockRelease(l);
        }
        PG_RE_THROW();
    }
    PG_END_TRY();

    return (Datum) 0;
}

/* -------------------------------------------------------------------- */
/* xclaim.debug_inject_stale(scope int4, key int4) -- test helper.      */
/*                                                                      */
/* SUPERUSER ONLY. Used by the stale-owner reaper test to seed an       */
/* XClaimEntry whose owner triple is GUARANTEED stale (procno = INT_MAX */
/* is out of MaxBackends range -> reaper signal "out-of-range procno"). */
/*                                                                      */
/* NOT FOR PRODUCTION (DBA runbook caveat). The function bypasses the   */
/* normal acquisition path -- there is no local-set entry, no owner-    */
/* token-publish, no xact callback registration -- it is a pure shared- */
/* state injection.                                                     */
/* -------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(xclaim_debug_inject_stale);

Datum
xclaim_debug_inject_stale(PG_FUNCTION_ARGS)
{
    int32       scope;
    int32       key;
    XClaimKey   lk;
    uint32      hashvalue;
    LWLock     *plock;
    XClaimEntry *new_entry;
    bool        found;

    XCLAIM_REQUIRE_INIT();

    /*
     * Superuser gate (defense-in-depth; SQL surface also REVOKEs from
     * PUBLIC). Without superuser, refuse to inject stale state.
     */
    if (!superuser())
        ereport(ERROR,
                (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
                 errmsg("xclaim.debug_inject_stale requires superuser")));

    if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("xclaim.debug_inject_stale arguments must not be NULL")));

    scope = PG_GETARG_INT32(0);
    key   = PG_GETARG_INT32(1);

    memset(&lk, 0, sizeof(lk));
    lk.dbid = MyDatabaseId;
    lk.form = XCLAIM_FORM_PAIR;
    lk.k1   = ((int64) (uint32) scope << 32) | (uint32) key;

    hashvalue = xclaim_compute_hash(&lk);
    plock = xclaim_partition_lock(hashvalue);

    LWLockAcquire(plock, LW_EXCLUSIVE);

    new_entry = (XClaimEntry *) hash_search_with_hash_value(XClaimHash,
                                                            &lk,
                                                            hashvalue,
                                                            HASH_ENTER_NULL,
                                                            &found);
    if (new_entry == NULL)
    {
        LWLockRelease(plock);
        ereport(ERROR,
                (errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
                 errmsg("xclaim.debug_inject_stale: max_claims exhausted")));
    }

    /*
     * Refuse to overwrite a live entry. Without this guard, injecting
     * "stale" state on a key that some backend legitimately holds would
     * synthesize a guaranteed-stale owner triple on top of the real
     * owner -- the next caller's reaper would treat the live claim as
     * stale and recycle it, silently violating mutual exclusion.
     *
     * The helper is intended exclusively to seed reaper test cases on
     * keys that no one holds; overwriting a live claim is never a valid
     * use case, so make it loudly fail rather than corrupt state.
     */
    if (found)
    {
        LWLockRelease(plock);
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_IN_USE),
                 errmsg("xclaim.debug_inject_stale: key (%d,%d) is live; refusing to overwrite",
                        scope, key),
                 errhint("Pick a key that is not currently held by any backend.")));
    }
    pg_atomic_fetch_add_u64(&XClaimCtl->live_capacity, 1);

    /*
     * Synthesize a guaranteed-stale owner triple:
     *   - procno = INT32_MAX -> out of [0, MaxBackends) -> hits the
     *     reaper's "out-of-range procno" check, which precedes
     *     signal 1 (proc slot empty) in pg_xclaim_reaper.c.
     *   - owner_pid = 999999 -> sentinel; matched against the dead PGPROC
     *     pid, but the procno bounds check fires first.
     *   - owner_token = 0 -> reserved-invalid; never legitimately issued
     *     (next_token starts at 1).
     *   - owner_lxid = 0 -> never matches a live xact (lxids start at 1).
     */
    new_entry->owner_pid     = 999999;
    new_entry->owner_procno  = INT32_MAX;
    new_entry->owner_lxid    = 0;
    new_entry->owner_token   = 0;
    new_entry->lifetime_kind = XCLAIM_LIFETIME_XACT;

    LWLockRelease(plock);

    PG_RETURN_VOID();
}
