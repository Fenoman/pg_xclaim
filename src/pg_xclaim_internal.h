/*-------------------------------------------------------------------------
 *
 * pg_xclaim_internal.h
 *      Internal-only header -- shared-memory layout and per-backend slot
 *      data structures used by the shared-state setup and consumed by
 *      the acquisition / cleanup paths.
 *
 * Layout summary:
 *   * XClaimKey: sizeof == 16 -- HASH_BLOBS hashes raw bytes.
 *   * XClaimEntry: key + saved-acquisition-time owner identity.
 *   * Memory layout: TopMemoryContext for local; HASH_FIXED_SIZE for
 *     shared. FORBIDDEN to use simplehash.h in shmem.
 *   * ShmemInitHash flag set: HASH_ELEM | HASH_BLOBS | HASH_PARTITION |
 *     HASH_FIXED_SIZE; init_size == max_size == max_claims.
 *   * Saved-acquisition-time identity (procno + lxid + token).
 *   * Stale-owner reaper consults XClaimBackendInfo[procno] for the
 *     current owner_token; readers do unlocked atomic loads.
 *
 * HARD invariants:
 *   * `memset(&key, 0, sizeof(key))` MANDATORY before any field assignment
 *     (HASH_BLOBS hashes raw bytes including padding bytes).
 *   * `simplehash.h` MUST NOT be used for shared memory -- linear probing
 *     plus grow-on-collision is incompatible with fixed-size shared.
 *   * Never store raw `PGPROC *`; use procno + saved lxid + saved token.
 *   * `next_token` starts at 1; 0 is the reserved-invalid sentinel for
 *     XClaimBackendInfo.current_token.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PG_XCLAIM_INTERNAL_H
#define PG_XCLAIM_INTERNAL_H

#include "postgres.h"

#include "pg_config_manual.h"       /* PG_CACHE_LINE_SIZE */
#include "port/atomics.h"
#include "storage/lock.h"           /* LocalTransactionId */
#include "storage/lwlock.h"         /* LWLockPadded */
#include "utils/hsearch.h"

#include <stddef.h>                 /* offsetof */

/* -------------------------------------------------------------------- */
/* Shared key & entry.                                                  */
/* -------------------------------------------------------------------- */

/*
 * XClaimForm
 *      Out-of-band discriminator (mirrors pg_locks.objsubid pattern). Set
 *      by every key-construction site: the scalar entry points
 *      (xclaim_try_solo / xclaim_try_pair), the bulk try_many unpack
 *      loops, and the xclaim.debug_inject_stale test helper. The enum
 *      value 0 is intentionally invalid so a forgotten populate of a
 *      memset'd key fails closed instead of colliding with a real form.
 */
typedef enum XClaimForm
{
    XCLAIM_FORM_INVALID = 0,            /* defends against unpopulated keys */
    XCLAIM_FORM_SOLO    = 1,            /* xclaim_try_solo C entry point    */
    XCLAIM_FORM_PAIR    = 2             /* xclaim_try_pair C entry point    */
} XClaimForm;

/*
 * XClaimKey
 *      Exactly 16 bytes, no padding. HASH_BLOBS hashes raw bytes -- if any
 *      ABI change introduces a hole we get silent false-negatives in
 *      lookups. The compile-time asserts at the bottom of this header are
 *      our defense.
 *
 *      Field layout (verified for aarch64 + amd64; also asserted below):
 *        offset 0   uint32 dbid
 *        offset 4   int32  form (XClaimForm)
 *        offset 8   int64  k1   (solo: full int8 key; pair: (classid<<32)|objid)
 *
 *      Construction MUST always be:
 *          XClaimKey lk;
 *          memset(&lk, 0, sizeof(lk));   -- mandatory
 *          lk.dbid = MyDatabaseId;
 *          lk.form = XCLAIM_FORM_SOLO; / XCLAIM_FORM_PAIR;
 *          lk.k1   = ...;
 */
typedef struct XClaimKey
{
    Oid     dbid;                       /* offset 0,  4 bytes -- MyDatabaseId */
    int32   form;                       /* offset 4,  4 bytes -- XClaimForm   */
    int64   k1;                         /* offset 8,  8 bytes                */
} XClaimKey;

/*
 * Layout invariants -- compile-time fail-stop. Any ABI change that
 * grows the key, reorders fields, or introduces padding will refuse to
 * compile rather than silently breaking HASH_BLOBS lookups.
 */
StaticAssertDecl(sizeof(XClaimKey) == 16,
                 "XClaimKey size changed; check HASH_BLOBS compat");
StaticAssertDecl(offsetof(XClaimKey, dbid) == 0,
                 "XClaimKey dbid offset changed");
StaticAssertDecl(offsetof(XClaimKey, form) == 4,
                 "XClaimKey form offset changed");
StaticAssertDecl(offsetof(XClaimKey, k1)   == 8,
                 "XClaimKey k1 alignment changed");

/*
 * XClaimEntry
 *      The shared dynahash element (HASH_BLOBS, HASH_FIXED_SIZE, partitioned).
 *      First member is the XClaimKey; dynahash treats the leading
 *      sizeof(XClaimKey) bytes as the lookup key.
 *
 *      `owner_pid` is debug/display only. Correctness identity is the triple
 *      (owner_procno, owner_lxid, owner_token) saved at acquisition time
 *      -- never read from current MyProc fields at cleanup.
 */
#define XCLAIM_LIFETIME_XACT  ((uint8) 1)   /* only supported lifetime value */

typedef struct XClaimEntry
{
    XClaimKey           key;            /* 16 bytes -- leading hash key     */
    int32               owner_pid;      /* debug/display ONLY; never identity */
    int32               owner_procno;   /* PG-version-abstracted */
    LocalTransactionId  owner_lxid;     /* saved at acquisition */
    uint64              owner_token;    /* extension-owned backend generation */
    uint8               lifetime_kind;  /* XCLAIM_LIFETIME_XACT for v1       */
    /* implicit padding to 8-byte align -- accounted for via sizeof(XClaimEntry) */
} XClaimEntry;

/* -------------------------------------------------------------------- */
/* Per-backend info slot.                                               */
/* -------------------------------------------------------------------- */

/*
 * XClaimBackendInfo
 *      Per-backend slot indexed by procno (0..MaxBackends-1).
 *      Backends publish their `current_token` here on first acquisition
 *      and regenerate on session reset. The stale-owner reaper does an
 *      unlocked atomic load of `current_token` and compares against the
 *      saved owner_token in a conflicting XClaimEntry. False negatives
 *      are tolerated -- a missed reap simply causes the conflict path
 *      to return false; the next attempt will retry.
 *
 *      `pid` is debug/display only (mirrors PGPROC->pid).
 */
typedef struct XClaimBackendInfo
{
    pg_atomic_uint64    current_token;  /* 0 == inactive (sentinel)         */
    pid_t               pid;            /* debug only; PGPROC.pid mirror    */

    /*
     * Per-backend hot-path counters. Bumped from the acquisition path
     * INSTEAD of the global XClaimCtl counters: each backend writes
     * only its own slot, eliminating cache-line ping-pong on
     * concurrently-acquiring workloads. xclaim_stats() sums across all
     * MaxBackends slots for a near-instantaneous global view. Reads
     * are eventually-consistent w.r.t. concurrent writes -- acceptable
     * for observability, never for correctness.
     */
    pg_atomic_uint64    total_acquires_local;
    pg_atomic_uint64    reentrant_hits_local;
    pg_atomic_uint64    conflicts_local;
}
/*
 * Cache-line padding. Adjacent slots in the array MUST NOT share a
 * cache line: two backends with adjacent procnos hammering their own
 * counters would cause false-sharing ping-pong on the shared line
 * even though no other backend writes to a given slot. With
 * PG_CACHE_LINE_SIZE (128 bytes on aarch64 / amd64) padding, each
 * slot occupies its own line and per-backend writes are truly
 * contention-free. The `pg_attribute_aligned(PG_CACHE_LINE_SIZE)`
 * ALSO aligns the array base, so XClaimBackendInfos[0] starts on a
 * cache line.
 *
 * Cost: at MaxBackends=100, the slot array grows from ~3.7 KB to
 * 12.5 KB -- negligible vs the ~360 MB shared dynahash. The
 * `xclaim_shmem_size` formula already uses sizeof(XClaimBackendInfo),
 * which includes any tail padding the compiler inserts to satisfy
 * the alignment, so the request stays in lock-step with the actual
 * allocation size.
 */
pg_attribute_aligned(PG_CACHE_LINE_SIZE) XClaimBackendInfo;

/* -------------------------------------------------------------------- */
/* Shared control block (stats counters + capacity watermarks).         */
/* -------------------------------------------------------------------- */

/*
 * XClaimControl
 *      Single ShmemInitStruct-allocated singleton holding:
 *        * GUC snapshots taken under AddinShmemInitLock (so the cluster's
 *          view stays self-consistent for any PGC_SIGHUP reload path;
 *          today these are PGC_POSTMASTER and never change).
 *        * Atomic owner_token issuer (`next_token`).
 *        * Stats counters (atomic, lock-free).
 *        * Pointer to the named LWLock tranche obtained via
 *          GetNamedLWLockTranche("xclaim_partition").
 *
 *      Counters are pg_atomic_uint64 to avoid spinlock contention on the
 *      control struct under heavy mass-acquisition workloads.
 */
typedef struct XClaimControl
{
    /* GUC snapshots (consistency under AddinShmemInitLock). */
    int                 num_partitions;     /* power-of-two; mask = N - 1   */
    int                 max_claims;         /* >= 32 (HARD invariant)       */

    /* Owner-token issuer -- atomic counter; 0 reserved invalid. */
    pg_atomic_uint64    next_token;

    /*
     * Stats (atomic, lock-free).
     *
     *   ABI/layout-reserved global mirrors:
     *      total_acquires, reentrant_hits, conflicts -- the
     *      acquisition path bumps per-backend slot counters
     *      (XClaimBackendInfo.total_acquires_local / reentrant_hits_local /
     *      conflicts_local) instead of these globals to avoid
     *      cache-line ping-pong; xclaim.stats() sums the per-backend
     *      slots for the SQL surface. The shared fields are kept in the
     *      control block as stable layout reserves, initialised to zero
     *      at shmem startup and never mutated thereafter.
     *
     *   live counters (acquisition path):
     *      capacity_errors, capacity_warnings, disabled_calls
     *   live counters (cleanup path):
     *      reaped_stale, cleanup_misses, session_resets
     *   live counters (debug/admin):
     *      debug_scans, peak_per_backend, live_capacity
     */
    pg_atomic_uint64    total_acquires;             /* ABI/layout reserve; always zero */
    pg_atomic_uint64    reentrant_hits;             /* ABI/layout reserve; always zero */
    pg_atomic_uint64    conflicts;                  /* ABI/layout reserve; always zero */
    pg_atomic_uint64    capacity_errors;
    pg_atomic_uint64    capacity_warnings;
    pg_atomic_uint64    reaped_stale;
    pg_atomic_uint64    cleanup_misses;
    pg_atomic_uint64    disabled_calls;
    pg_atomic_uint64    debug_scans;
    pg_atomic_uint64    session_resets;
    pg_atomic_uint64    peak_per_backend;       /* high-water-mark */
    pg_atomic_uint64    live_capacity;          /* current entries in shared dynahash; single-load alternative to walking all partitions */

    /*
     * Named LWLock tranche pointer obtained from
     * GetNamedLWLockTranche("xclaim_partition") inside the shmem startup
     * hook (after RequestNamedLWLockTranche in shmem_request_hook). Indexed
     * by partition id ([0, num_partitions)).
     */
    LWLockPadded       *partition_locks;
} XClaimControl;

/* -------------------------------------------------------------------- */
/* Shared-memory globals (set by xclaim_shmem_startup, defined in       */
/* pg_xclaim_shared.c).                                                 */
/* -------------------------------------------------------------------- */

extern XClaimControl       *XClaimCtl;
extern HTAB                *XClaimHash;
extern XClaimBackendInfo   *XClaimBackendInfos;     /* MaxBackends entries */
extern LWLockPadded        *XClaimPartitionLocks;   /* backend-local cache */

/* -------------------------------------------------------------------- */
/* Inline helpers shared by the acquisition and cleanup paths.          */
/* -------------------------------------------------------------------- */

/*
 * xclaim_partition_lock
 *      Maps a precomputed dynahash hash value to one of the named-tranche
 *      partition LWLocks. `num_partitions` is power-of-two (validated in
 *      GUC check_hook), so a single AND replaces the modulo and is uniform.
 */
static inline LWLock *
xclaim_partition_lock(uint32 hashvalue)
{
    uint32  mask = (uint32) XClaimCtl->num_partitions - 1;
    uint32  part = hashvalue & mask;
    /*
     * Read through the backend-local cache (populated in every backend
     * by xclaim_shmem_startup) rather than dereferencing the absolute
     * pointer stored inside our shmem block. See LWLockPadded comment
     * in pg_xclaim_shared.c for the rationale.
     */
    return &XClaimPartitionLocks[part].lock;
}

/*
 * xclaim_partition_id_for_hash
 *      Same mapping but returning the integer index (used by the
 *      group-by-partition cleanup ordering).
 */
static inline uint32
xclaim_partition_id_for_hash(uint32 hashvalue)
{
    uint32  mask = (uint32) XClaimCtl->num_partitions - 1;
    return hashvalue & mask;
}

/*
 * xclaim_compute_hash
 *      Wrap dynahash get_hash_value with our concrete HTAB so callers
 *      do not need to know the global's identity.
 */
static inline uint32
xclaim_compute_hash(const XClaimKey *key)
{
    return get_hash_value(XClaimHash, key);
}

#endif                                  /* PG_XCLAIM_INTERNAL_H */
