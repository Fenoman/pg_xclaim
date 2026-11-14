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
 *                                              The first call in a backend
 *                                              also registers
 *                                              xclaim_shmem_exit_cb
 *                                              (on_shmem_exit).
 *   * Owner identity capture (acquisition):
 *         xclaim_capture_acquisition_identity(out_procno, out_lxid, out_token)
 *   * Lookup / insert / remove:
 *         xclaim_local_lookup(key, &out)
 *         xclaim_local_lookup_with_hash(key, hashvalue, &out)
 *           bulk/precomputed-hash fast path that forwards to simplehash's
 *           `_hash` variant.
 *         xclaim_local_add(key, hashvalue, partition_id)
 *           xclaim.try: entry in the set before the partition LWLock
 *         xclaim_local_note_held(key, hashvalue)
 *           records an added entry as held after the shared insert
 *         xclaim_local_drop(entry)
 *           deletes an added entry that was not recorded
 *         xclaim_local_insert_held(key, hashvalue, partition_id)
 *           add + note_held, xclaim.try_many under the partition LWLock
 *         xclaim_local_remove(key)
 *           rollback of a recorded entry (xclaim.try_many PG_CATCH)
 *   * Sizing:
 *         xclaim_local_reserve(additional), xclaim_local_shrink(force),
 *         xclaim_local_prepare_bulk(nkeys)
 *   * Identity match:
 *         xclaim_shared_matches_saved_owner(shared, saved)
 *           cleanup path -- uses the SAVED triple (procno + lxid + token)
 *           NEVER current MyProc.
 *         xclaim_shared_owner_matches_self(shared)
 *           acquisition own-entry-recovery path -- uses the LIVE triple
 *           (mid-xact, MyProc intact).
 *   * Cleanup:
 *         xclaim_local_cleanup_held()      -- group-by-partition cleanup
 *                                              driver (MANDATORY). Truncates
 *                                              the local set in place.
 *         xclaim_local_gather_pointers(buf, cap)
 *                                          -- fills a caller-provided pointer
 *                                              array for the cleanup driver.
 *         xclaim_local_clear_owner_token() -- rotates owner_token on
 *                                              session_reset.
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
 *     exposes process identity as MyProcNumber, while vxid.procNumber is an
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
/*   * `held` and `status` sit next to `saved_procno`, before the       */
/*     8-byte members. LocalTransactionId is 4 bytes on PostgreSQL and  */
/*     Postgres Pro Standard, 8 bytes on Tantor SE and Postgres Pro     */
/*     Enterprise, and with this order the entry takes 48 bytes on      */
/*     both (the StaticAssertDecl below).                               */
/* -------------------------------------------------------------------- */
typedef struct XClaimLocalEntry
{
    XClaimKey           key;            /* SH_KEY -- leading member         */
    uint32              hashvalue;      /* precomputed get_hash_value(...)  */
    uint32              partition_id;   /* precomputed hashvalue & mask     */
    int32               saved_procno;   /* CAPTURED at acquisition time     */
    uint8               held;           /* held / visited by list cleanup   */
    char                status;         /* SH_STATUS slot (mandated)        */
    LocalTransactionId  saved_lxid;     /* CAPTURED at acquisition time     */
    uint64              saved_token;    /* CAPTURED at acquisition time     */
} XClaimLocalEntry;

StaticAssertDecl(sizeof(XClaimLocalEntry) == 48,
                 "XClaimLocalEntry size changed, check the per-backend memory figures in README.md");

/* -------------------------------------------------------------------- */
/* Lazy initialisation entry points (idempotent, callable from every    */
/* SQL entry point AFTER XCLAIM_REQUIRE_INIT()).                        */
/* -------------------------------------------------------------------- */

extern void xclaim_local_init(void);
extern void xclaim_ensure_owner_token(void);

/*
 * xclaim_local_reserve
 *      Shrinks an empty set after a burst (xclaim_local_shrink), then grows
 *      the local set so that `additional` more inserts stay below its grow
 *      threshold. A key that probes too far can still grow the set inside
 *      an insert, below the threshold. Call before taking a partition
 *      LWLock. May ERROR (out of memory) with the set unchanged.
 *
 * xclaim_local_emit_peak_warning
 *      Writes the one-shot 75%-of-expected_claims_per_backend LOG that
 *      xclaim_local_note_held() marked. Call after the partition LWLock is
 *      released.
 */
extern void xclaim_local_reserve(uint64 additional);

/*
 * xclaim_local_shrink
 *      Gives the empty local set a bucket array of its first size after a
 *      burst: after XCLAIM_SHRINK_AFTER small cleanups and from
 *      XCLAIM_SHRINK_FACTOR times the first size, or with `force`
 *      (xclaim.session_reset()) whenever the set is larger. No-op while
 *      claims are held. Raises no ERROR: when the smaller array does not
 *      fit, the set keeps the arrays it has.
 */
extern void xclaim_local_shrink(bool force);

/*
 * xclaim_local_prepare_bulk
 *      Before the first partition LWLock of an xclaim.try_many of `nkeys`
 *      keys that, with the claims held, take half of the first bucket
 *      array or more. A set less than XCLAIM_SHRINK_FACTOR times the size
 *      the call needs restarts the streak of small cleanups, a larger one
 *      shrinks here once the streak is complete. A set shrunk after a
 *      burst grows toward twice the room the claims need, up to the
 *      largest size it shrank from. May ERROR (out of memory) with the set
 *      at its size before the growth.
 */
extern void xclaim_local_prepare_bulk(uint64 nkeys);
extern void xclaim_local_emit_peak_warning(void);

/*
 * xclaim_local_holds_current_xact
 *      True when the local set holds a claim taken by the running top-level
 *      transaction. Walks the whole set: for xclaim.session_reset() only.
 */
extern bool xclaim_local_holds_current_xact(void);

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
 *      currently held by this backend. On hit, *out is set
 *      to the underlying simplehash entry (caller may inspect saved_*
 *      fields for diagnostics but MUST NOT mutate `key`).
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
 * xclaim_local_add
 *      Put an entry for `key` into the set. PRECONDITION: caller has
 *      already verified the key is NOT present (via xclaim_local_lookup)
 *      AND xclaim_ensure_owner_token() has run. Allocates inside
 *      XClaimLocalContext via the simplehash machinery (a growth can
 *      raise an out-of-memory ERROR), and status is initialised by
 *      simplehash. Changes no count: see xclaim_local_note_held.
 *
 * xclaim_local_note_held
 *      Record an added entry as held, once its shared row is taken:
 *      live count, peak, held-key list and the 75% hint. Allocates
 *      nothing and raises no ERROR.
 *
 * xclaim_local_insert_held
 *      xclaim_local_add followed by xclaim_local_note_held.
 *
 * xclaim_local_drop
 *      Delete the entry that xclaim_local_add returned and
 *      xclaim_local_note_held did not record, before any other insert into
 *      or delete from the set. Raises no ERROR.
 */
extern XClaimLocalEntry *xclaim_local_add(const XClaimKey *key,
                                          uint32 hashvalue,
                                          uint32 partition_id);
extern void xclaim_local_note_held(const XClaimKey *key, uint32 hashvalue);
extern void xclaim_local_insert_held(const XClaimKey *key,
                                     uint32 hashvalue,
                                     uint32 partition_id);
extern void xclaim_local_drop(XClaimLocalEntry *entry);

/*
 * xclaim_local_remove
 *      Remove a single recorded entry by key and decrement the live count.
 *      Used by the xclaim.try_many rollback after the shared row is
 *      HASH_REMOVE'd. No-op if not present.
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
/* provided pointer array. The caller counting-sorts by partition_id    */
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
 *      backend which has already logged "crossed 75% of
 *      pg_xclaim.expected_claims_per_backend" can emit a fresh hint
 *      after session_reset() if it climbs past the threshold again.
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
 *      owner identity), release the lock. The local entries go away
 *      by key when a short transaction's keys are in the held-key list,
 *      otherwise the set is truncated in place via xcl_local_reset once
 *      every partition has been drained.
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
 *        * xclaim_shmem_exit_cb (on_shmem_exit, registered per
 *          backend) -- backend-exit cleanup. It runs after
 *          ShutdownPostgres has aborted any open transaction, so the
 *          set is normally empty. It is not empty when a sibling's xact
 *          callback called ahead of ours failed in that abort: during
 *          exit the ERROR becomes FATAL, which skips the rest of the
 *          chain.
 *        * xclaim_session_reset() -- claims held outside a transaction.
 */
extern void xclaim_local_cleanup_held(void);

/*
 * xclaim_local_clear_owner_token
 *      Drop the cached owner_token so the next acquisition (or the
 *      caller, immediately) re-runs xclaim_ensure_owner_token() and
 *      issues a FRESH token from XClaimCtl->next_token. Used by
 *      xclaim_session_reset().
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
/* Used by the acquisition own-entry-recovery branch to detect a local  */
/* set that lost the entry while the shared row is still ours, which    */
/* only a defect can cause.                                             */
/*                                                                      */
/* Distinct from `xclaim_shared_matches_saved_owner` (cleanup path):    */
/*   * cleanup path uses the SAVED triple from the local entry          */
/*     (because MyProc state is wiped by the time the xact callback     */
/*     fires).                                                          */
/*   * acquisition path uses the LIVE triple (we are mid-xact, MyProc   */
/*     state is intact, no local entry exists yet to read from).        */
/* -------------------------------------------------------------------- */
extern bool xclaim_shared_owner_matches_self(const XClaimEntry *shared);

#endif                                  /* PG_XCLAIM_LOCAL_H */
