/*-------------------------------------------------------------------------
 *
 * pg_xclaim_compat.h
 *      PostgreSQL 16 / 17 / 18 compatibility shims.
 *
 * Encapsulates ABI differences between PG 16 and PG 17+:
 *   * `procnumber.h` only exists in PG 17+.
 *   * Process identity moved from `MyProc->pgprocno` (PG 16) to the
 *     extern `MyProcNumber` (PG 17+, declared in `storage/procnumber.h`).
 *   * The top-level local transaction id moved from `MyProc->lxid`
 *     (PG 16) to `MyProc->vxid.lxid` (PG 17+).
 *
 * IMPORTANT: do NOT use `MyProc->vxid.procNumber` as the compat surface
 * even in PG 17+. PG 17+ exposes process identity as the extern
 * `MyProcNumber`; `vxid.procNumber` is an implementation detail embedded
 * in the VXID struct. The cleanup path needs process identity captured at
 * acquisition time. Use `MyProcNumber` (or `MyProc->pgprocno` on PG 16)
 * only.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PG_XCLAIM_COMPAT_H
#define PG_XCLAIM_COMPAT_H

#include "postgres.h"
#include "storage/proc.h"
#include "storage/lock.h"           /* LocalTransactionId */
#include "access/transam.h"

#if PG_VERSION_NUM >= 170000
/*
 * PG 17 introduced storage/procnumber.h, carrying the ProcNumber typedef
 * and the `MyProcNumber` extern. PG 16 has neither: process identity
 * there is the `pgprocno` int field on PGPROC (storage/proc.h), which the
 * #else branch below reads directly.
 */
#include "storage/procnumber.h"

static inline int
xclaim_get_current_procno(void)
{
    return (int) MyProcNumber;
}

static inline LocalTransactionId
xclaim_get_current_top_lxid(void)
{
    /*
     * Read MyProc->vxid.lxid -- the *top-level* local xid. PG core
     * clears it back to InvalidLocalTransactionId in
     * ProcArrayEndTransaction() BEFORE the xact callback fires:
     * CommitTransaction() calls ProcArrayEndTransaction() and only then
     * CallXactCallbacks(); AbortTransaction() follows the same order.
     * That ordering is what makes the saved-acquisition-time identity
     * pattern necessary -- by the time our cleanup callback runs, the
     * live lxid is already gone.
     *
     * For process identity we use MyProcNumber (extern), not
     * MyProc->vxid.procNumber. The two are equal during the lifetime of
     * a regular backend (set together in InitProcess(), cleared only at
     * backend exit in ProcKill()), but the extern is preferred -- no
     * MyProc deref required, and it matches PG core conventions.
     */
    return MyProc->vxid.lxid;
}

#else                               /* PG_VERSION_NUM < 170000 -> PG 16 */

static inline int
xclaim_get_current_procno(void)
{
    return MyProc->pgprocno;
}

static inline LocalTransactionId
xclaim_get_current_top_lxid(void)
{
    return MyProc->lxid;
}

#endif                              /* PG_VERSION_NUM >= 170000 */

/*
 * Stale-owner reaper helper. All three target versions
 * (PG 16/17/18) expose `GetPGProcByNumber(n)` from storage/proc.h. The
 * macro is defined as `(&ProcGlobal->allProcs[(n)])` in every target
 * release -- no rename, no signature change. We wrap it in an inline
 * helper that bounds-checks the procno against `ProcGlobal->allProcCount`
 * before dereferencing, so an invalid (negative or out-of-range) procno
 * captured by a corrupted XClaimEntry returns NULL rather than reading
 * past the array.
 *
 * Returns the bare PGPROC * (caller treats NULL as "stale"). The caller
 * MUST NOT cache the pointer across LWLock release boundaries -- the
 * slot may be reused by a different backend at any time. The reaper
 * dereferences only `pid`, which is a stable atomic-load proxy for "is
 * this slot occupied", and immediately releases the inspection.
 *
 * Note: `ProcGlobal` and the `allProcs` array live in shared memory and
 * are valid for the postmaster lifetime. `allProcCount` is set during
 * `InitProcGlobal()` (postmaster startup) and never changes thereafter,
 * so unlocked reads here are safe.
 */
static inline PGPROC *
xclaim_get_pgproc_by_procno(int procno)
{
    if (procno < 0)
        return NULL;
    if (ProcGlobal == NULL)
        return NULL;
    /* allProcCount is uint32 in PG 16/17/18 -- cast both sides for the
     * compare so -Wsign-compare stays clean under -Werror. */
    if ((uint32) procno >= ProcGlobal->allProcCount)
        return NULL;
    return GetPGProcByNumber(procno);
}

#endif                              /* PG_XCLAIM_COMPAT_H */
