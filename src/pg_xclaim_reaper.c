/*-------------------------------------------------------------------------
 *
 * pg_xclaim_reaper.c
 *      Lazy stale-owner reaper.
 *
 * The acquisition conflict path consults `xclaim_is_stale_owner` UNDER
 * the partition LWLock. If it returns true, the caller takes over the
 * slot by overwriting the entry's owner triple in place under the same
 * lock (linearizable; no HASH_REMOVE + HASH_ENTER cycle since the
 * combined HASH_ENTER_NULL already returned the existing entry pointer).
 * The reaper is deliberately lazy: no background worker scans shared
 * memory. Stale rows are reclaimed only when a conflicting acquisition
 * proves that the recorded owner identity is no longer live.
 *
 * Three stale signals:
 *   1. Proc slot empty:           ProcGlobal->allProcs[procno].pid == 0
 *      (or procno is out of range -- defensive against corrupted
 *      XClaimEntry).
 *   2. PID mismatch:              live PGPROC at procno has a DIFFERENT
 *      OS pid than entry->owner_pid -- the slot was reused by an
 *      unrelated backend.
 *   3. Token regenerated:         XClaimBackendInfos[procno].current_token
 *      != entry->owner_token. Same OS pid (or NEW backend at same
 *      slot) but session_reset has rotated the token -- any rows owned
 *      by the OLD token are stale.
 *
 * Reads are unlocked -- the published `XClaimBackendInfo.current_token`
 * is an `pg_atomic_uint64` with lock-free atomic load; PGPROC->pid is a
 * stable plain field updated only at backend init/exit. False negatives
 * are tolerated (caller returns false / conflict; next acquisition
 * retries the check). False POSITIVES (reaping a live owner) MUST never
 * occur -- they would silently release a held claim.
 *
 * Hard-process-death caveat: when a backend is SIGKILLed/segfaults,
 * PostgreSQL treats the child exit as a backend crash, terminates the
 * remaining backends, calls shmem_exit(), and recreates shared memory.
 * Ordinary hard backend death therefore does not leave xclaim rows for
 * this lazy reaper. The reaper covers extension-level stale-owner cases:
 * an empty/reused PGPROC slot after normal proc cleanup, PID mismatch,
 * or session_reset-issued token mismatch. There is intentionally no
 * "is this PID alive" syscall (it would be racy and platform-specific).
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"                  /* MaxBackends */
#include "port/atomics.h"
#include "storage/proc.h"               /* PGPROC, ProcGlobal */

#include "pg_xclaim.h"
#include "pg_xclaim_compat.h"           /* xclaim_get_pgproc_by_procno */
#include "pg_xclaim_internal.h"

/*
 * xclaim_is_stale_owner
 *      Returns true iff the shared entry's owner is provably dead/reused
 *      OR has rotated its owner_token via session_reset. Caller (the
 *      acquisition conflict path) overwrites the entry's owner triple
 *      in place under the same partition LWLock when this returns true.
 *
 *      Decision rule:
 *        * Out-of-range procno -> stale (corrupted entry; reap defensively).
 *        * PGPROC slot empty (pid == 0) -> stale.
 *        * PGPROC->pid != entry->owner_pid -> slot reused by different
 *          OS process -> stale.
 *        * XClaimBackendInfos[procno].current_token != entry->owner_token
 *          -> token regenerated (session_reset) -> stale.
 *        * Otherwise alive and current -> NOT stale.
 *
 *      All checks are unlocked atomic / plain reads (the publish path
 *      is atomic; reads tolerate false negatives).
 *
 *      Read-only -- never mutates the shared dynahash. The caller owns
 *      the in-place overwrite (populate of owner triple) under the
 *      partition lock.
 */
bool
xclaim_is_stale_owner(const XClaimEntry *entry)
{
    PGPROC     *p;
    uint64      published_token;

    Assert(entry != NULL);

    /*
     * Defense-in-depth: a procno outside the legal range cannot index a
     * valid PGPROC. Treat as stale (reap the entry; the saved owner
     * identifier is corrupted or from a previous postmaster lifetime).
     */
    if (entry->owner_procno < 0 || entry->owner_procno >= MaxBackends)
        return true;

    /*
     * Compat helper bounds-checks against ProcGlobal->allProcCount and
     * returns NULL on out-of-range. Available unchanged on PG 16/17/18
     * (GetPGProcByNumber is `&ProcGlobal->allProcs[(n)]` in every
     * target release; the wrapper adds the bounds check).
     */
    p = xclaim_get_pgproc_by_procno(entry->owner_procno);
    if (p == NULL)
        return true;                /* slot doesn't exist -> stale */

    /*
     * pid == 0 means "no live backend process owns this PGPROC". PGPROC
     * slots are recycled through ProcGlobal's freeProcs list and pid is
     * set to 0 when a backend exits; prepared-transaction dummy procs
     * also have pid 0, but pg_xclaim rejects PREPARE TRANSACTION while
     * claims are held, so they cannot be valid xclaim owners.
     */
    if (p->pid == 0)
        return true;                /* slot empty -> stale */

    if (p->pid != entry->owner_pid)
        return true;                /* slot reused by different OS pid -> stale */

    /*
     * Token freshness check. The owning backend publishes its
     * `current_token` into XClaimBackendInfos[procno] on the first
     * acquisition, and rotates it on session_reset. A mismatch means
     * the live PGPROC at this slot is the SAME OS process but it has
     * since called session_reset -- any rows owned by the OLD token
     * are stale.
     *
     * Atomic load (unlocked); false negatives tolerated (we'd just
     * return false on this iteration; next conflict retries). XClaim
     * BackendInfos is sized MaxBackends; the procno bounds check above
     * also guards this index.
     */
    published_token = pg_atomic_read_u64(&XClaimBackendInfos[entry->owner_procno].current_token);
    if (published_token != entry->owner_token)
        return true;                /* token regenerated -> stale */

    return false;                   /* alive and current */
}
