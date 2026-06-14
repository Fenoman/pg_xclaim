/*-------------------------------------------------------------------------
 *
 * pg_xclaim_local.h
 *      Backend-local hashset (simplehash.h template) + owner-identity
 *      helpers.
 *
 * Public surface (acquisition / cleanup / bulk + obs):
 *   * Lazy initialisation:
 *         xclaim_local_init()              -- creates the simplehash inside
 *                                              XClaimLocalContext (child of
 *                                              TopMemoryContext, HARD
 *                                              invariant).
 *         xclaim_ensure_owner_token()      -- atomically issues this backend's
 *                                              owner_token from
 *                                              XClaimCtl->next_token and
 *                                              publishes it into
 *                                              XClaimBackendInfos[procno].
 *   * Owner identity capture (acquisition):
 *         xclaim_capture_acquisition_identity(out_procno, out_lxid, out_token)
 *   * Lookup / insert / remove:
 *         xclaim_local_lookup(key, &out)
 *         xclaim_local_lookup_with_hash(key, hashvalue, &out)
 *           bulk/precomputed-hash fast path; forwards to simplehash's
 *           `_hash` variant.
 *         xclaim_local_insert_held(key, hashvalue, partition_id)
 *         xclaim_local_remove(key)
 *   * Identity match:
 *         xclaim_shared_matches_saved_owner(shared, saved)
 *           cleanup path -- uses the SAVED triple (procno + lxid + token)
 *           NEVER current MyProc.
 *         xclaim_shared_owner_matches_self(shared)
 *           acquisition own-entry-recovery path -- uses the LIVE triple
 *           (mid-xact, MyProc intact).
 *   * Cleanup:
 *         xclaim_local_cleanup_held()      -- group-by-partition cleanup
 *                                              driver (MANDATORY); truncates
 *                                              the local set in place.
 *         xclaim_local_gather_pointers(buf, cap)
 *                                          -- fills a caller-provided pointer
 *                                              array for the cleanup driver.
 *         xclaim_local_clear_owner_token() -- rotates owner_token on
 *                                              session_reset / pooler handoff.
 *   * Stats / observability:
 *         xclaim_local_count()
 *         xclaim_local_peak()
 *         xclaim_local_reset_peak_warning() -- re-arms the one-shot peak
 *                                              warning after session_reset.
 *         xclaim_local_my_owner_token()    -- test/debug introspection of
 *                                              the current token.
 *
 * HARD invariants:
 *
 *   * ALL local entries are pallocs into XClaimLocalContext (child of
 *     TopMemoryContext) -- never CurTransactionContext, never a subtxn
 *     context. A plpgsql EXCEPTION rolling back a subtxn would otherwise
 *     free the local cleanup metadata while the shared entry remained
 *     alive (orphan leak).
 *
 *   * NEVER store a raw `PGPROC *`. Identity is the saved triple
 *     (saved_procno, saved_lxid, saved_token) populated at acquisition
 *     time and NEVER re-read from MyProc at cleanup -- proc->lxid /
 *     proc->vxid.lxid is cleared by ProcArrayEndTransaction() BEFORE the
 *     xact callback fires.
 *
 *   * MyProc->vxid.procNumber is FORBIDDEN as the compat surface. PG 17+
 *     exposes process identity as MyProcNumber; vxid.procNumber is an
 *     implementation detail embedded in the VXID struct. We use
 *     MyProcNumber (PG 17+) / MyProc->pgprocno (PG 16) via the compat
 *     helper xclaim_get_current_procno().
 *
 *   * simplehash.h is used ONLY here (private memory). Shared memory
 *     uses ShmemInitHash (dynahash).
 *
 *-------------------------------------------------------------------------
 */
#ifndef PG_XCLAIM_LOCAL_H
#define PG_XCLAIM_LOCAL_H

#include "postgres.h"

#include "storage/lock.h"               /* LocalTransactionId */

#include "pg_xclaim_internal.h"         /* XClaimKey, XClaimEntry */

/* -------------------------------------------------------------------- */
/* Local backend entry (private memory).                                */
/*                                                                      */
/* Layout choices:                                                      */
/*   * `key` is the leading member to make SH_KEY/SH_EQUAL trivial.    */
/*   * `hashvalue` and `partition_id` are PRECOMPUTED at acquisition    */
/*     time so the cleanup callback can group by partition_id without   */
/*     recomputing get_hash_value() on every entry (128 LWLock cycles  */
/*     vs 750k = ~5860x speedup).                                      */
/*   * Saved-acquisition-time identity (procno + lxid + token) is the   */
/*     SOLE source of truth for cleanup ownership.                      */
/*   * `status` is mandated by the simplehash.h template (SH_STATUS).  */
/* -------------------------------------------------------------------- */
typedef struct XClaimLocalEntry
{
    XClaimKey           key;            /* SH_KEY -- leading member         */
    uint32              hashvalue;      /* precomputed get_hash_value(...)  */
    uint32              partition_id;   /* precomputed hashvalue & mask     */
    int32               saved_procno;   /* CAPTURED at acquisition time     */
    LocalTransactionId  saved_lxid;     /* CAPTURED at acquisition time     */
    uint64              saved_token;    /* CAPTURED at acquisition time     */
    uint8               held;           /* 1 = held; other values invalid   */
    char                status;         /* SH_STATUS slot (mandated)        */
} XClaimLocalEntry;

/* -------------------------------------------------------------------- */
/* Lazy initialisation entry points (idempotent, callable from every    */
/* SQL entry point AFTER XCLAIM_REQUIRE_INIT()).                        */
/* -------------------------------------------------------------------- */

extern void xclaim_local_init(void);
extern void xclaim_ensure_owner_token(void);

/* -------------------------------------------------------------------- */
/* Owner identity helpers used by acquisition (Step 11) and cleanup.    */
/* `out_*` arguments must point to caller-owned storage.                */
/* -------------------------------------------------------------------- */

/*
 * xclaim_capture_acquisition_identity
 *      Snapshot the current backend's identity at acquisition time.
 *      Reads MyProcNumber / MyProc->pgprocno via compat helper, the
 *      top-level lxid via compat helper, and the lazily-issued
 *      owner_token. Caller stores the triple in the local-set entry
 *      AND in the shared XClaimEntry's owner_* fields.
 *
 *      Precondition: `xclaim_ensure_owner_token()` has already been
 *      called -- otherwise XClaimMyOwnerToken is 0 (invalid sentinel).
 */
extern void xclaim_capture_acquisition_identity(int32 *out_procno,
                                                LocalTransactionId *out_lxid,
                                                uint64 *out_token);

/*
 * xclaim_shared_matches_saved_owner
 *      Compares SAVED owner triple (from the local entry) against the
 *      shared entry's owner_* fields. NEVER reads
 *      MyProc -- proc->lxid is cleared by ProcArrayEndTransaction()
 *      before the xact callback fires.
 *
 *      Returns true iff the shared entry was acquired by us (this
 *      backend, in this xact) and is therefore safe to remove during
 *      cleanup.
 */
static inline bool
xclaim_shared_matches_saved_owner(const XClaimEntry *shared,
                                  const XClaimLocalEntry *saved)
{
    return shared->owner_procno == saved->saved_procno
        && shared->owner_lxid   == saved->saved_lxid
        && shared->owner_token  == saved->saved_token;
}

/* -------------------------------------------------------------------- */
/* Lookup / insert / clear API.                                         */
/* -------------------------------------------------------------------- */

/*
 * xclaim_local_lookup
 *      O(1) reentrancy fast-path probe. Returns true iff `key` is
 *      currently held by this backend; on hit, *out is set
 *      to the underlying simplehash entry (caller may inspect saved_*
 *      fields for diagnostics; MUST NOT mutate `key`).
 *
 *      On miss *out is left untouched.
 */
extern bool xclaim_local_lookup(const XClaimKey *key,
                                XClaimLocalEntry **out);

/*
 * xclaim_local_lookup_with_hash
 *      Same as xclaim_local_lookup but takes a precomputed dynahash
 *      hash for `key`. Forwards to simplehash's `_hash` variant,
 *      skipping the redundant SH_HASH_KEY pass. Use this on the bulk
 *      path (slots[i].hashvalue is already populated) and from any
 *      scalar caller that has already invoked xclaim_compute_hash.
 *
 *      The precomputed value MUST match what xclaim_compute_hash would
 *      produce for the same key -- dynahash with HASH_BLOBS and
 *      simplehash's SH_HASH_KEY both reduce to hash_bytes over the
 *      same XClaimKey byte image, so they are interchangeable.
 */
extern bool xclaim_local_lookup_with_hash(const XClaimKey *key,
                                          uint32 hashvalue,
                                          XClaimLocalEntry **out);

/*
 * xclaim_local_insert_held
 *      Insert a freshly-acquired entry. PRECONDITION: caller has already
 *      verified the key is NOT present (via xclaim_local_lookup) AND
 *      xclaim_ensure_owner_token() has run. Allocates inside
 *      XClaimLocalContext via the simplehash machinery; status is
 *      initialised by simplehash.
 *
 *      Updates per-backend count and peak watermark.
 */
extern void xclaim_local_insert_held(const XClaimKey *key,
                                     uint32 hashvalue,
                                     uint32 partition_id);

/*
 * xclaim_local_remove
 *      Remove a single entry by key. Used by cleanup when the shared
 *      entry has been HASH_REMOVE'd. No-op if not present (idempotency
 *      for COMMIT-before-ABORT-before-proc-exit cleanup races).
 *
 *      Does NOT free underlying memory -- simplehash uses inline
 *      storage and the per-row chunks are reclaimed at backend exit
 *      (the local context lives in TopMemoryContext for the lifetime
 *      of the backend).
 */
extern void xclaim_local_remove(const XClaimKey *key);

/* -------------------------------------------------------------------- */
/* Iteration interface for the group-by-partition cleanup.              */
/*                                                                      */
/* The simplehash itself supports iteration but does NOT order entries  */
/* by partition_id. The cleanup driver sorts an array of pointers by    */
/* partition_id. We expose a `gather` helper that fills a caller-       */
/* provided pointer array; caller then counting-sorts by partition_id   */
/* (O(N + num_partitions), keyspace bounded to num_partitions) and      */
/* processes one partition at a time.                                   */
/* -------------------------------------------------------------------- */

/*
 * xclaim_local_gather_pointers
 *      Fill `buf` with pointers to all currently-held local entries, up
 *      to `cap` entries. Returns the actual count. If the count exceeds
 *      `cap`, the buffer is filled completely and the surplus is left
 *      ungathered (caller must size buf to xclaim_local_count() to
 *      enumerate everything).
 *
 *      Pointers are stable through the simplehash's lifetime UNTIL a
 *      grow / reset happens. The cleanup driver must not insert or
 *      delete entries while iteration is in progress.
 */
extern uint32 xclaim_local_gather_pointers(XClaimLocalEntry **buf,
                                           uint32 cap);

/* -------------------------------------------------------------------- */
/* Stats helpers (consumed by the xclaim.stats() debug surface).        */
/* -------------------------------------------------------------------- */

extern uint64 xclaim_local_count(void);
extern uint64 xclaim_local_peak(void);

/*
 * xclaim_local_reset_peak_warning
 *      Clear the per-session one-shot peak-warning flag so that a
 *      backend which has already logged "peak crossed 75% of
 *      expected_claims_per_backend" can emit a fresh hint after
 *      session_reset() if it climbs past the threshold again.
 */
extern void xclaim_local_reset_peak_warning(void);

/* -------------------------------------------------------------------- */
/* Test / debug introspection. Returning the bare token is acceptable   */
/* for assert paths -- the value is monotonic & non-secret.             */
/* -------------------------------------------------------------------- */

extern uint64 xclaim_local_my_owner_token(void);

/* -------------------------------------------------------------------- */
/* Cleanup support -- per-partition group + token regeneration.         */
/* -------------------------------------------------------------------- */

/*
 * xclaim_local_cleanup_held
 *      Group-by-partition cleanup driver (MANDATORY). For each
 *      partition with at least one held local entry: acquire the
 *      partition LWLock ONCE, HASH_REMOVE every matching shared entry
 *      (verified via xclaim_shared_matches_saved_owner using the saved
 *      owner identity), release the lock. The local simplehash is
 *      truncated in place via xcl_local_reset once every partition has
 *      been drained.
 *
 *      Idempotent: if local_count() == 0 the function returns
 *      immediately (no allocation, no lock traffic). Repeated calls
 *      after the first are O(1) no-ops.
 *
 *      Perf contract: 128 LWLock cycles for 750k claims (vs 750k
 *      cycles per-key) = ~5860x speedup. The 128-cycle bound matches
 *      the default `pg_xclaim.num_partitions = 128`.
 *
 *      Invoked from:
 *        * xclaim_xact_callback (COMMIT / PARALLEL_COMMIT / ABORT /
 *          PARALLEL_ABORT) -- the canonical xact-end hook.
 *        * xclaim_shmem_exit_cb (before_shmem_exit) -- defensive
 *          backend-exit cleanup; idempotent overlap with xact cleanup
 *          is expected.
 *        * xclaim_session_reset() -- pooler defense-in-depth.
 */
extern void xclaim_local_cleanup_held(void);

/*
 * xclaim_local_clear_owner_token
 *      Drop the cached owner_token so the next acquisition (or the
 *      caller, immediately) re-runs xclaim_ensure_owner_token() and
 *      issues a FRESH token from XClaimCtl->next_token. Used by
 *      xclaim_session_reset() so a pooler-handed-off backend cannot
 *      impersonate the previous logical client.
 *
 *      Side-effect: zeroes XClaimBackendInfos[procno].current_token so
 *      the stale-owner reaper observes the rotation and treats any
 *      leftover shared rows owned by the OLD token as stale.
 */
extern void xclaim_local_clear_owner_token(void);

/* -------------------------------------------------------------------- */
/* Step 8a helper -- "is this shared entry currently mine?".            */
/*                                                                      */
/* Compares the shared entry's owner triple against the CURRENT         */
/* backend's identity (MyProcNumber / top-level lxid / our own token).  */
/* Used by the acquisition own-entry-recovery branch to detect the      */
/* rare case where the local set lost the entry (missed callback,      */
/* session-reset bug) but the shared row is still ours.                 */
/*                                                                      */
/* Distinct from `xclaim_shared_matches_saved_owner` (cleanup path):    */
/*   * cleanup path uses the SAVED triple from the local entry          */
/*     (because MyProc state is wiped by the time the xact callback     */
/*     fires);                                                          */
/*   * acquisition path uses the LIVE triple (we are mid-xact, MyProc   */
/*     state is intact, no local entry exists yet to read from).        */
/* -------------------------------------------------------------------- */
extern bool xclaim_shared_owner_matches_self(const XClaimEntry *shared);

#endif                                  /* PG_XCLAIM_LOCAL_H */
