/*-------------------------------------------------------------------------
 *
 * pg_xclaim.h
 *      Internal header shared by pg_xclaim translation units.
 *
 * Contents:
 *   * GUC backing variable declarations (definitions are in pg_xclaim.c).
 *   * `xclaim_state_initialized` flag set by shmem startup hook,
 *     read by SQL entry-point preflight macro `XCLAIM_REQUIRE_INIT`.
 *   * Capacity-exhaustion enum (XClaimCapBehavior) used by the
 *     acquisition path but defined here so GUC machinery can reference
 *     it.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PG_XCLAIM_H
#define PG_XCLAIM_H

#include "postgres.h"

#include "access/xact.h"
#include "access/xlog.h"            /* RecoveryInProgress() -- used by XCLAIM_REQUIRE_INIT */
#include "fmgr.h"
#include "miscadmin.h"
#include "utils/elog.h"

/* -------------------------------------------------------------------- */
/* GUC-backed variables (defined in pg_xclaim.c).                       */
/* -------------------------------------------------------------------- */

extern int  xclaim_max_claims;                  /* >= 32 (HARD invariant)   */
extern int  xclaim_num_partitions;              /* power of two             */
extern int  xclaim_expected_claims_per_backend; /* > 0 && <= max_claims     */
extern bool xclaim_enabled;                     /* runtime kill switch      */
extern int  xclaim_capacity_warn_pct;           /* watermark log threshold  */
extern int  xclaim_capacity_behavior;           /* XClaimCapBehavior enum   */

/* -------------------------------------------------------------------- */
/* Capacity-exhaustion enum.                                            */
/* Defined here so DefineCustomEnumVariable in _PG_init has access; the */
/* acquisition path is the actual consumer.                             */
/* -------------------------------------------------------------------- */

typedef enum XClaimCapBehavior
{
    XCLAIM_CAP_ERROR = 0,               /* default -- ERRCODE 53400         */
    XCLAIM_CAP_WARN = 2                 /* WARNING + return false           */
} XClaimCapBehavior;

/* -------------------------------------------------------------------- */
/* State flag set in shmem_startup_hook. Until then, every SQL entry    */
/* point must ERROR via XCLAIM_REQUIRE_INIT.                            */
/* -------------------------------------------------------------------- */

extern bool xclaim_state_initialized;

/*
 * XCLAIM_REQUIRE_INIT
 *      Standard preflight check inserted at the very top of each SQL
 *      entry point (xclaim.try, xclaim.try_many, ...). Mirrors the
 *      pg_stat_statements pattern: if the extension was not loaded via
 *      shared_preload_libraries, _PG_init returned silently and shmem
 *      startup never ran -- so xclaim_state_initialized is still false.
 *      Raise a clean user-facing ERROR with the standard
 *      ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE.
 *
 *      Recovery / hot-standby gate:
 *      `RecoveryInProgress()` cannot be called from `_PG_init` (XLogCtl
 *      is NULL at preload time), and it cannot reliably be called from
 *      `shmem_startup_hook` either (a freshly-started primary still
 *      reports `true` until the startup process finishes WAL replay).
 *      The accurate place is at SQL-entry-point time, called from a
 *      regular backend AFTER cluster startup completes. Contrib's
 *      pg_surgery uses the same defer-to-call-time pattern (a
 *      `RecoveryInProgress()` check at call time, not at load).
 */
#define XCLAIM_REQUIRE_INIT()                                               \
    do {                                                                    \
        if (!xclaim_state_initialized)                                      \
            ereport(ERROR,                                                  \
                    (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),     \
                     errmsg("pg_xclaim must be loaded via shared_preload_libraries"), \
                     errhint("Add 'pg_xclaim' to shared_preload_libraries in postgresql.conf and restart"))); \
        if (RecoveryInProgress())                                           \
            ereport(ERROR,                                                  \
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),                \
                     errmsg("pg_xclaim does not support hot-standby/recovery mode"), \
                     errhint("Remove from shared_preload_libraries on standby clusters"))); \
    } while (0)

/* -------------------------------------------------------------------- */
/* Cross-translation-unit prototypes.                                   */
/* -------------------------------------------------------------------- */

/* pg_xclaim_shared.c: shared-memory layout and init. */
extern Size xclaim_shmem_size(void);
extern void xclaim_shmem_startup(void);
extern void xclaim_install_shmem_hook(void);

/* pg_xclaim_callbacks.c: xact callback + before_shmem_exit callback. */
extern void xclaim_xact_callback(XactEvent event, void *arg);
extern void xclaim_shmem_exit_cb(int code, Datum arg);

/* pg_xclaim_acquire.c: main 12-step acquisition algorithm + capacity
 * dispatch. The full XClaimKey / XClaimEntry types live in
 * pg_xclaim_internal.h; we forward-declare here so this header stays
 * free of internal headers and remains includable from any TU. */
struct XClaimKey;
struct XClaimEntry;
extern bool xclaim_try_internal(const struct XClaimKey *lk);
extern bool xclaim_handle_capacity_exhaustion(const struct XClaimKey *lk);

/*
 * pg_xclaim_stats.c: capacity-watermark logging.
 *
 * Both bodies live in pg_xclaim_stats.c (where the static suppression
 * timestamp is colocated with the stats counters they report against);
 * the acquisition path in pg_xclaim_acquire.c is the only caller.
 *
 * xclaim_check_capacity_watermark is the call site exposed to the
 * acquisition path; it reads the live used count and forwards to
 * xclaim_capacity_watermark_check, which does the actual comparison.
 *
 * Called from the acquisition path AFTER a successful HASH_ENTER (so the
 * `used` count just incremented). Compares used / max_claims against the
 * 80/90/95% thresholds, with a 60-second suppression window to avoid log
 * floods during sustained capacity pressure.
 */
extern void xclaim_check_capacity_watermark(uint64 used);
extern void xclaim_capacity_watermark_check(uint64 used);

/* pg_xclaim_reaper.c: lazy stale-owner reaper consulted by the
 * acquisition conflict path under the partition LWLock; true => the
 * caller takes over the entry by overwriting its owner triple in place. */
extern bool xclaim_is_stale_owner(const struct XClaimEntry *entry);

#endif                                  /* PG_XCLAIM_H */
