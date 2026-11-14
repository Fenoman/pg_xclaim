/*-------------------------------------------------------------------------
 *
 * pg_xclaim_local.c
 *      Backend-local hashset (simplehash.h template) + owner-identity
 *      helpers.
 *
 * Hosts:
 *   * SH_DECLARE / SH_DEFINE for the per-backend simplehash<XClaimKey,
 *     XClaimLocalEntry> instantiation.
 *   * TopMemoryContext-anchored allocator (HARD invariant).
 *   * Lazy `owner_token` issuance from XClaimCtl->next_token, published
 *     into XClaimBackendInfos[procno].current_token.
 *   * Saved-acquisition-time identity capture so cleanup reads stable
 *     values, not transient MyProc fields cleared by
 *     ProcArrayEndTransaction() before the xact callback fires.
 *
 *======================================================================
 * HARD INVARIANT:
 *   ALL local entries MUST be allocated in `XClaimLocalContext`, which
 *   is a child of `TopMemoryContext`. NEVER `CurTransactionContext`,
 *   NEVER a subtransaction context.
 *
 *   If allocated in a subtransaction context AND a plpgsql `EXCEPTION`
 *   rolls that subtransaction back, the local cleanup metadata is freed
 *   while the shared entry remains alive -- orphan leak ("memory
 *   context trap").
 *
 *   The simplehash itself is created via xcl_local_create() with
 *   XClaimLocalContext passed explicitly, so SH_ALLOCATE routes every
 *   grow/rehash palloc through that context independently of the
 *   current memory context. Direct pallocs in this TU (the cleanup
 *   scratch arrays) still MemoryContextSwitchTo(XClaimLocalContext)
 *   around the allocation. Reviewers MUST verify this on every diff
 *   that touches this file.
 *======================================================================
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <string.h>                     /* memcpy */

#include "common/hashfn.h"              /* hash_bytes */
#include "miscadmin.h"                  /* MyProcPid, MaxBackends */
#include "port/atomics.h"
#include "storage/ipc.h"                /* on_shmem_exit */
#include "storage/lwlock.h"
#include "storage/proc.h"
#include "storage/shmem.h"
#include "utils/hsearch.h"              /* hash_search_with_hash_value */
#include "utils/memutils.h"             /* TopMemoryContext, AllocSetContextCreate */

#include "pg_xclaim.h"
#include "pg_xclaim_compat.h"           /* xclaim_get_current_procno / lxid */
#include "pg_xclaim_internal.h"         /* XClaimCtl, XClaimBackendInfos */
#include "pg_xclaim_local.h"

/* -------------------------------------------------------------------- */
/* simplehash.h template instantiation.                                 */
/*                                                                      */
/* SH_PREFIX        xcl_local                                           */
/* SH_ELEMENT_TYPE  XClaimLocalEntry  (declared in pg_xclaim_local.h)   */
/* SH_KEY_TYPE      XClaimKey         (declared in pg_xclaim_internal.h)*/
/* SH_KEY           key                                                 */
/* SH_HASH_KEY      hash_bytes over the 16-byte key footprint           */
/* SH_EQUAL         memcmp() of 16 bytes                                */
/* SH_SCOPE         static inline (this TU only)                        */
/* SH_USE_NONDEFAULT_ALLOCATOR  bucket arrays from xcl_local_allocate() */
/* SH_DEFINE        emit definitions                                    */
/* SH_DECLARE       emit declarations                                   */
/*                                                                      */
/* The hash function uses `hash_bytes((const unsigned char *) &key,    */
/* sizeof(XClaimKey))`, which is BIT-FOR-BIT identical to dynahash's   */
/* `get_hash_value()` for the shared HTAB: dynahash with HASH_BLOBS    */
/* routes through tag_hash -> hash_bytes over the same 16-byte key     */
/* image, and SH_HASH_KEY does the same. This identity is intentional  */
/* and load-bearing: the precomputed dynahash value is fed straight    */
/* into the simplehash `_hash` variants (xcl_local_lookup_hash /       */
/* xcl_local_insert_hash), so the two functions MUST agree or the      */
/* reused value would probe the wrong simplehash bucket.               */
/*                                                                      */
/* SH_STORE_HASH points simplehash at the entry's own `hashvalue`      */
/* member, the dynahash value cleanup uses against the shared HTAB. By */
/* the identity above it is also the simplehash hash of the key, so    */
/* the entry does not grow. simplehash then compares the hash before   */
/* the key and does not recompute hash_bytes for the entries it moves  */
/* when the set grows or an entry is deleted.                          */
/* -------------------------------------------------------------------- */

#define SH_PREFIX               xcl_local
#define SH_ELEMENT_TYPE         XClaimLocalEntry
#define SH_KEY_TYPE             XClaimKey
#define SH_KEY                  key
#define SH_HASH_KEY(tb, key)    \
    hash_bytes((const unsigned char *) &(key), sizeof(XClaimKey))
#define SH_EQUAL(tb, a, b)      \
    (memcmp(&(a), &(b), sizeof(XClaimKey)) == 0)
#define SH_STORE_HASH
#define SH_GET_HASH(tb, a)      ((a)->hashvalue)
#define SH_SCOPE                static inline
#define SH_USE_NONDEFAULT_ALLOCATOR
#define SH_DECLARE
#define SH_DEFINE
#include "lib/simplehash.h"

/* -------------------------------------------------------------------- */
/* File-scope state.                                                    */
/*                                                                      */
/* All globals are TU-private (`static`). The header exposes a         */
/* small read-only API instead of the raw pointers so refactors (e.g.  */
/* dynahash fallback) do not break consumers.                          */
/* -------------------------------------------------------------------- */

static xcl_local_hash *XClaimLocalSet      = NULL;          /* simplehash */
static MemoryContext   XClaimLocalContext  = NULL;          /* child of Top */
static uint64          XClaimMyOwnerToken  = 0;             /* 0 = unallocated */
static uint64          XClaimMyLocalCount  = 0;             /* live entries */
static uint64          XClaimMyPeakCount   = 0;             /* high-water-mark */
static bool            XClaimMyPeakWarned  = false;         /* per-session, one-shot */
static bool            XClaimMyPeakWarnPending = false;     /* LOG due after LWLockRelease */
static uint64          XClaimMyPeakWarnCount = 0;           /* live claims at the crossing */
static bool            XClaimMyExitCbRegistered = false;    /* once per backend */

/* -------------------------------------------------------------------- */
/* Held-key list: the keys inserted into the set since its last         */
/* cleanup, in insertion order.                                         */
/*                                                                      */
/* Why. The bucket array of the set is sized by                         */
/* expected_claims_per_backend and by the largest transaction the       */
/* backend has run recently (xclaim_local_shrink). A cleanup that walks */
/* and zeroes the whole array costs the same for one claim as for the   */
/* largest transaction. With the list, a transaction that took at most  */
/* 1/XCLAIM_HELD_LIST_RATIO of the buckets in claims finds them by key  */
/* and deletes them one by one.                                         */
/*                                                                      */
/* What it holds. Up to XClaimHeldListCap keys with their hashes: at    */
/* least XCLAIM_HELD_LIST_MIN, and 1/XCLAIM_HELD_LIST_RATIO of the      */
/* buckets once the set grows (xclaim_local_reserve sizes it before the */
/* partition LWLock). xclaim_local_note_held() appends without          */
/* allocating (try_many records under a partition LWLock) and marks the */
/* list overflowed once it is full. xclaim.try lists a key only after   */
/* it took the shared row, so a conflict or a capacity miss leaves the  */
/* list as it was.                                                      */
/* A key removed by a rollback stays in the list: the lookup at         */
/* cleanup misses it. A key removed and taken again in the same         */
/* transaction appears twice: the `held` mark of the entry makes        */
/* cleanup visit it once.                                               */
/*                                                                      */
/* XClaimCleanupBuf holds the entry pointers of a list cleanup, so that */
/* cleanup allocates nothing at transaction end.                        */
/* -------------------------------------------------------------------- */

#define XCLAIM_HELD_LIST_MIN    1024

/*
 * A list cleanup costs a lookup and a delete per claim, a full cleanup a
 * walk and a memset over every bucket. The list is used while the claims
 * are at most 1/XCLAIM_HELD_LIST_RATIO of the buckets.
 */
#define XCLAIM_HELD_LIST_RATIO  64

/* `held` values of a local entry. */
#define XCLAIM_LOCAL_HELD       1   /* taken, not yet visited by cleanup */
#define XCLAIM_LOCAL_VISITED    2   /* gathered by the current list cleanup */

typedef struct XClaimHeldKey
{
    XClaimKey   key;
    uint32      hashvalue;
} XClaimHeldKey;

static XClaimHeldKey     *XClaimHeldList     = NULL;
static uint32             XClaimHeldListCap  = 0;       /* entries of both arrays */
static uint32             XClaimHeldListLen  = 0;
static bool               XClaimHeldListFull = false;
static XClaimLocalEntry **XClaimCleanupBuf   = NULL;    /* XClaimHeldListCap */

/* -------------------------------------------------------------------- */
/* Shrinking after a burst.                                             */
/*                                                                      */
/* The first bucket array of the set is sized by                        */
/* expected_claims_per_backend. A large transaction grows it, and the   */
/* array stays allocated for the next one. When the last                */
/* XCLAIM_SHRINK_AFTER cleanups each released no more claims than the  */
/* first array holds below its grow threshold, and the set is at least  */
/* XCLAIM_SHRINK_FACTOR times its first size, the next acquisition      */
/* gives the empty set an array of its first size and the large array   */
/* goes back to the allocator. A backend that runs a large transaction  */
/* every time keeps its array. xclaim.session_reset() shrinks an        */
/* enlarged set at once.                                                */
/*                                                                      */
/* A later xclaim.try_many whose keys take half of the first array or  */
/* more grows the set toward the largest size it shrank from, before    */
/* its first partition LWLock (xclaim_local_prepare_bulk): its runs     */
/* would otherwise grow the set again under their locks. Such a call    */
/* restarts the streak only while the set is less than                  */
/* XCLAIM_SHRINK_FACTOR times the size the call needs.                  */
/* -------------------------------------------------------------------- */

#define XCLAIM_SHRINK_AFTER     64
#define XCLAIM_SHRINK_FACTOR    4

static uint64 XClaimLocalFirstSize      = 0;    /* buckets of the first array */
static uint64 XClaimLocalFirstThreshold = 0;    /* its grow threshold */
static uint32 XClaimSmallCleanups       = 0;    /* consecutive, capped */
static uint64 XClaimLocalShrunkFrom     = 0;    /* largest size before a shrink */

/* -------------------------------------------------------------------- */
/* Bucket-array allocator (SH_ALLOCATE / SH_FREE).                      */
/*                                                                      */
/* A growth of the set allocates a bucket array twice the size of the   */
/* current one, and that allocation can fail with an out-of-memory      */
/* ERROR. PostgreSQL 16's simplehash sets the new size, mask and grow   */
/* threshold BEFORE the allocation, so the failure would leave the      */
/* current array under the doubled size: a later lookup, delete,        */
/* iteration or reset would read and write past its end. PostgreSQL 17  */
/* and later allocate first, but the long-probe path zeroes the grow    */
/* threshold before it grows, so the failure would leave it at zero     */
/* and every later insert would try to grow again, even into an empty   */
/* set.                                                                 */
/*                                                                      */
/* Every bucket array of a growth or of the creation comes from        */
/* xcl_local_allocate(), and XClaimLocalArraySize holds the bucket      */
/* count of the array the set uses. xclaim_local_shrink() puts its own  */
/* smaller array into the empty set and records its count as well.      */
/* When the allocation for a growth fails, the allocator gives the set  */
/* the size, mask and grow threshold of that array back, the way        */
/* simplehash computes them, BEFORE the out-of-memory ERROR is raised.  */
/* The ERROR can turn into FATAL (exit_on_error = on), which skips      */
/* every PG_CATCH, and the cleanup at backend exit walks the set. One   */
/* insert can grow the set more than once (a long probe right after a   */
/* growth grows it again), and every growth allocates here, so the set  */
/* comes back to the array it uses whichever growth fails.              */
/*                                                                      */
/* The first attempt does not raise the ERROR (MCXT_ALLOC_NO_OOM). With */
/* the geometry restored, a second attempt raises the server's own      */
/* out-of-memory ERROR when memory is still short, and when it          */
/* succeeds, the set takes the geometry of the new array again.         */
/* -------------------------------------------------------------------- */

static uint64 XClaimLocalArraySize = 0;

#if PG_VERSION_NUM >= 170000
#define xclaim_local_set_geometry(tb, size) \
    xcl_local_update_parameters((tb), (size))
#else
#define xclaim_local_set_geometry(tb, size) \
    xcl_local_compute_parameters((tb), (size))
#endif

static inline void *
xcl_local_allocate(xcl_local_hash *tb, Size size)
{
    void       *data;

    data = MemoryContextAllocExtended(tb->ctx, size,
                                      MCXT_ALLOC_HUGE | MCXT_ALLOC_ZERO |
                                      MCXT_ALLOC_NO_OOM);
    if (unlikely(data == NULL))
    {
        /* tb->data is NULL only while xcl_local_create() builds the set. */
        if (tb->data != NULL)
            xclaim_local_set_geometry(tb, XClaimLocalArraySize);
        data = MemoryContextAllocExtended(tb->ctx, size,
                                          MCXT_ALLOC_HUGE | MCXT_ALLOC_ZERO);
        if (tb->data != NULL)
            xclaim_local_set_geometry(tb, size / sizeof(XClaimLocalEntry));
    }

    XClaimLocalArraySize = size / sizeof(XClaimLocalEntry);
    return data;
}

static inline void
xcl_local_free(xcl_local_hash *tb, void *pointer)
{
    pfree(pointer);
}

/* -------------------------------------------------------------------- */
/* xclaim_local_init                                                    */
/*                                                                      */
/* Lazy, idempotent. Called from each SQL entry point AFTER             */
/* XCLAIM_REQUIRE_INIT(). Creates a child MemoryContext anchored to     */
/* TopMemoryContext (HARD invariant -- see comment block at file top)   */
/* and instantiates the simplehash with `expected_claims_per_backend`   */
/* slots so steady-state acquisition does not pay rehash cost. Sessions */
/* that legitimately exceed the GUC value (e.g. >16k concurrent claims  */
/* on the default) WILL trigger simplehash growth. A GUC of about twice */
/* the peak claim count keeps the burst path rehash-free, the runs of   */
/* xclaim.try_many included: their long probes grow a set filled above  */
/* about 0.76 (see below).                                              */
/* -------------------------------------------------------------------- */

void
xclaim_local_init(void)
{
    MemoryContext old;

    if (XClaimLocalSet != NULL)
        return;                         /* already initialised */

    /*
     * TopMemoryContext (HARD invariant). The child context survives
     * subtransaction abort because it is a sibling of
     * CurTransactionContext, NOT a descendent. It is a plain AllocSet
     * that lives for the whole backend lifetime and is never reset:
     * cleanup deletes the keys of a short transaction one by one or
     * truncates the set via xcl_local_reset() (a memset over the
     * simplehash bucket array), and the bucket array stays for the next
     * acquisition burst until xclaim_local_shrink() gives a grown one
     * back. Once the set exists, the context is torn down only at
     * backend exit with TopMemoryContext.
     */
    XClaimLocalContext = AllocSetContextCreate(TopMemoryContext,
                                               "xclaim local set",
                                               ALLOCSET_DEFAULT_SIZES);

    old = MemoryContextSwitchTo(XClaimLocalContext);

    /*
     * Pre-grow to xclaim_expected_claims_per_backend (default 16384).
     * Avoids rehash during steady-state acquisition for sessions that
     * stay below the GUC value. High-cardinality sessions (e.g. >16k
     * simultaneous claims at the default) WILL hit the simplehash
     * grow path. Raise the GUC for those workloads. simplehash grows
     * at SH_FILLFACTOR (0.9), so rehash-free capacity actually extends
     * somewhat ABOVE the GUC value. The 75%-of-GUC peak warning emitted
     * elsewhere is a deliberately early heads-up before that
     * 0.9-fillfactor grow point. A long probe can grow the set earlier.
     *
     * When the first bucket array or the held-key list does not fit, the
     * context with the half-built set is dropped, so every failed attempt
     * leaves nothing under TopMemoryContext and the next claim starts from
     * scratch.
     */
    PG_TRY();
    {
        XClaimHeldList = (XClaimHeldKey *)
            palloc(XCLAIM_HELD_LIST_MIN * sizeof(XClaimHeldKey));
        XClaimCleanupBuf = (XClaimLocalEntry **)
            palloc(XCLAIM_HELD_LIST_MIN * sizeof(XClaimLocalEntry *));
        XClaimLocalSet = xcl_local_create(XClaimLocalContext,
                                          (uint32) xclaim_expected_claims_per_backend,
                                          NULL);
    }
    PG_CATCH();
    {
        MemoryContextSwitchTo(old);
        MemoryContextDelete(XClaimLocalContext);
        XClaimLocalContext = NULL;
        XClaimHeldList = NULL;
        XClaimCleanupBuf = NULL;
        XClaimLocalSet = NULL;
        PG_RE_THROW();
    }
    PG_END_TRY();

    MemoryContextSwitchTo(old);

    XClaimHeldListCap  = XCLAIM_HELD_LIST_MIN;
    XClaimHeldListLen  = 0;
    XClaimHeldListFull = false;
    XClaimLocalFirstSize      = XClaimLocalSet->size;
    XClaimLocalFirstThreshold = XClaimLocalSet->grow_threshold;
    XClaimSmallCleanups       = 0;

    /* Counters reset for a fresh local-state lifetime. */
    XClaimMyLocalCount = 0;
    /* XClaimMyPeakCount intentionally NOT reset here -- the peak is a
     * session-lifetime high-water-mark. It is reset implicitly only
     * when the backend exits and a fresh process starts (the file-
     * scope statics are initialised to 0 in the new process). Within a
     * single backend's lifetime the peak is monotonic. */
}

/* -------------------------------------------------------------------- */
/* xclaim_ensure_owner_token                                            */
/*                                                                      */
/* Lazy, idempotent. On first call: atomically increment                */
/* XClaimCtl->next_token (initialised to 1 in shared startup -- so the  */
/* first fetch_add returns 1 and never 0, the reserved sentinel for     */
/* `XClaimBackendInfo.current_token`). Publish the value into our       */
/* per-backend slot so the stale-owner reaper can consult it.           */
/*                                                                      */
/* Token regeneration on session reset clears XClaimMyOwnerToken (back  */
/* to 0) so the next acquisition reissues a fresh value via this        */
/* helper.                                                              */
/* -------------------------------------------------------------------- */

void
xclaim_ensure_owner_token(void)
{
    int procno;
    uint64 token;

    if (XClaimMyOwnerToken != 0)
        return;                         /* already published */

    /*
     * Register the backend-exit callback before the first token is
     * published, so every backend with a published token also has the
     * callback that releases leftover claims and invalidates the token
     * at exit. The registration has to happen here, in the backend: in
     * fork-based builds InitPostmasterChild() calls on_exit_reset(), so
     * nothing _PG_init registers in the postmaster reaches a backend.
     *
     * on_shmem_exit, not before_shmem_exit: this call can run inside a
     * PG_ENSURE_ERROR_CLEANUP scope (a claim taken by an opclass
     * comparator during btbulkdelete, for example), and such a scope
     * removes its own before_shmem_exit entry with
     * cancel_before_shmem_exit(), which fails unless that entry is the
     * latest one. on_shmem_exit entries have no such removal.
     *
     * session_reset() rotates the token but keeps the registration,
     * which therefore happens once per backend.
     */
    if (!XClaimMyExitCbRegistered)
    {
        on_shmem_exit(xclaim_shmem_exit_cb, (Datum) 0);
        XClaimMyExitCbRegistered = true;
    }

    /*
     * Atomic fetch-and-add. next_token starts at 1, so the first reader
     * gets 1, and subsequent readers get 2, 3, ... A token is issued at most
     * once per backend session (plus once per session_reset), so the
     * counter advances very slowly. Even at an absurd 1e6 tokens/sec the
     * 64-bit space (2^64 ~= 1.8e19) lasts ~585,000 years before
     * wrapping. Sentinel `0` is therefore unreachable in practice.
     */
    token = pg_atomic_fetch_add_u64(&XClaimCtl->next_token, 1);
    Assert(token != 0);

    /*
     * Publish before record. Write the per-backend slot's
     * `current_token` BEFORE assigning XClaimMyOwnerToken. A reaper
     * in another backend reads `XClaimBackendInfos[procno].current_token`
     * to decide whether a row owned by `token` is stale. If the reaper
     * ran while XClaimMyOwnerToken=token but the slot still held the
     * inactive sentinel (0), it would treat freshly-acquired rows as
     * stale and reap them -- a false positive that silently releases
     * a valid claim.
     *
     * Any ereport between issuing the token and publishing it (the
     * FATAL on an out-of-range procno below, for example) would leave
     * us with a token that was never published.
     * Publishing before recording XClaimMyOwnerToken keeps the slot
     * consistent on every unwind path. If a retry occurs, the next
     * fetch_add issues a FRESH token (the counter only moves forward).
     * That is safe because the failed attempt never published the
     * previous value, so no row was ever stamped with it.
     *
     * Slot index = procno (0..MaxBackends-1). The compat helper picks
     * the right PG-version-specific source (MyProcNumber on PG 17+,
     * MyProc->pgprocno on PG 16). MyProc->vxid.procNumber is
     * intentionally NOT used as the compat surface -- PG 17+ exposes
     * process identity through the MyProcNumber extern.
     */
    procno = xclaim_get_current_procno();
    /*
     * Defense-in-depth at the shared-memory boundary: Assert is a no-op
     * in release builds. An out-of-range procno would write past
     * XClaimBackendInfos[] (sized to MaxBackends in shmem_startup) and
     * corrupt adjacent shared-memory regions. Fail loudly instead.
     */
    if (unlikely(procno < 0 || procno >= MaxBackends))
        elog(FATAL, "pg_xclaim: invalid procno %d (MaxBackends=%d)",
             procno, MaxBackends);

    XClaimBackendInfos[procno].pid = MyProcPid;
    pg_atomic_write_u64(&XClaimBackendInfos[procno].current_token, token);

    /*
     * pg_write_barrier ensures the slot publish is globally visible
     * before XClaimMyOwnerToken records `token` locally. PG's atomic
     * reads carry NO barrier semantics, so the reaper's unlocked
     * pg_atomic_read_u64 on the slot is a plain atomic load -- the
     * design tolerates a stale read (a missed reap is retried later) and
     * does not rely on it being an acquire load. The pg_write_barrier
     * below, paired with the atomic write above, is the sole ordering
     * guarantee: if compiler inlining / reordering moved the
     * XClaimMyOwnerToken store ahead of the slot write, the barrier
     * prevents it.
     */
    pg_write_barrier();
    XClaimMyOwnerToken = token;
}

/* -------------------------------------------------------------------- */
/* xclaim_capture_acquisition_identity                                  */
/*                                                                      */
/* Snapshot the (procno, lxid, owner_token) triple at acquisition time. */
/* MUST be called AFTER xclaim_ensure_owner_token() so the token is     */
/* non-zero. The caller stores this triple in BOTH the local entry's   */
/* saved_* fields AND the shared XClaimEntry's owner_* fields. At      */
/* cleanup time, both copies are compared via                           */
/* xclaim_shared_matches_saved_owner() -- the local copy is the SOLE    */
/* source of truth.                                                     */
/*                                                                      */
/* `lxid` is read VIA the compat helper which selects MyProc->lxid on   */
/* PG 16 and MyProc->vxid.lxid on PG 17+. We deliberately read the     */
/* TOP-LEVEL lxid. A subtxn lxid would not match the shared entry's    */
/* owner_lxid (cleanup runs at top-level xact end).                    */
/* -------------------------------------------------------------------- */

void
xclaim_capture_acquisition_identity(int32 *out_procno,
                                    LocalTransactionId *out_lxid,
                                    uint64 *out_token)
{
    Assert(out_procno != NULL);
    Assert(out_lxid != NULL);
    Assert(out_token != NULL);
    Assert(XClaimMyOwnerToken != 0);    /* caller must ensure_owner_token first */

    *out_procno = (int32) xclaim_get_current_procno();
    *out_lxid   = xclaim_get_current_top_lxid();
    *out_token  = XClaimMyOwnerToken;
}

/* -------------------------------------------------------------------- */
/* xclaim_local_lookup                                                  */
/*                                                                      */
/* O(1) probe used by the reentrancy fast-path. Returning `false` when */
/* the local set has not been initialised lets the caller             */
/* unconditionally probe before init -- the first acquisition then     */
/* runs xclaim_local_init() and proceeds.                              */
/* -------------------------------------------------------------------- */

bool
xclaim_local_lookup(const XClaimKey *key, XClaimLocalEntry **out)
{
    XClaimLocalEntry *entry;

    if (XClaimLocalSet == NULL)
        return false;                   /* uninitialised => not held */

    Assert(key != NULL);

    entry = xcl_local_lookup(XClaimLocalSet, *key);
    if (entry == NULL)
        return false;

    if (out != NULL)
        *out = entry;

    return true;
}

/* -------------------------------------------------------------------- */
/* xclaim_local_lookup_with_hash                                        */
/*                                                                      */
/* Same contract as xclaim_local_lookup, but the caller supplies the   */
/* dynahash-precomputed hash for `key` (identical to what SH_HASH_KEY  */
/* would compute, because both eventually call hash_bytes over the     */
/* same XClaimKey byte image). Used by the bulk path to fold out the  */
/* redundant simplehash hash_bytes pass -- slots[i].hashvalue is       */
/* already populated by the unpack loop. Scalar callers that already  */
/* have a precomputed hash from xclaim_compute_hash benefit too.       */
/* -------------------------------------------------------------------- */

bool
xclaim_local_lookup_with_hash(const XClaimKey *key,
                              uint32 hashvalue,
                              XClaimLocalEntry **out)
{
    XClaimLocalEntry *entry;

    if (XClaimLocalSet == NULL)
        return false;

    Assert(key != NULL);

    entry = xcl_local_lookup_hash(XClaimLocalSet, *key, hashvalue);
    if (entry == NULL)
        return false;

    if (out != NULL)
        *out = entry;

    return true;
}

/* -------------------------------------------------------------------- */
/* Inserting a claim.                                                   */
/*                                                                      */
/*   xclaim_local_add()          puts the entry into the set            */
/*   xclaim_local_note_held()    records it as held: live count, peak,  */
/*                               held-key list and the 75% hint         */
/*   xclaim_local_insert_held()  both, for xclaim.try_many, which       */
/*                               inserts after it took the shared row   */
/*   xclaim_local_drop()         deletes an entry that was added and    */
/*                               not recorded                           */
/*                                                                      */
/* xclaim.try adds the entry before it takes the partition LWLock, so   */
/* that a growth of the set runs without the lock, and records it after */
/* the shared insert succeeded. On a conflict or a capacity miss it     */
/* drops the entry, and the backend's held-key list, peak and 75% hint  */
/* stay as they were: they count only claims the backend took.          */
/*                                                                      */
/* PRECONDITIONS of xclaim_local_add():                                 */
/*   * xclaim_local_init()           ran.                               */
/*   * xclaim_ensure_owner_token()   ran (XClaimMyOwnerToken != 0).     */
/*   * caller verified absence via xclaim_local_lookup() -- the assert  */
/*     `!found` enforces this.                                          */
/*                                                                      */
/* MEMORY-CONTEXT WRAPPING (HARD invariant -- see file-top comment):    */
/*   simplehash.h allocates growth segments from the context passed    */
/*   to xcl_local_create() (XClaimLocalContext), independently of      */
/*   CurrentMemoryContext. The MemoryContextSwitchTo to the child      */
/*   context BEFORE the insert and the restore AFTER are a second      */
/*   guard for the same invariant.                                     */
/* -------------------------------------------------------------------- */

XClaimLocalEntry *
xclaim_local_add(const XClaimKey *key,
                 uint32 hashvalue,
                 uint32 partition_id)
{
    MemoryContext old;
    XClaimLocalEntry *entry;
    bool found;

    Assert(XClaimLocalSet != NULL);     /* xclaim_local_init() must precede */
    Assert(XClaimMyOwnerToken != 0);    /* ensure_owner_token first */
    Assert(key != NULL);

    /*
     * TopMemoryContext (HARD invariant). XClaimLocalContext is a child
     * of TopMemoryContext, so any palloc inside the simplehash grow
     * path is anchored to the backend lifetime, not a subtxn that
     * could be rolled back by plpgsql EXCEPTION.
     */
    old = MemoryContextSwitchTo(XClaimLocalContext);

    /*
     * Pass the dynahash-precomputed `hashvalue` directly to simplehash's
     * `_hash` variant. dynahash with HASH_BLOBS routes through tag_hash,
     * which is `hash_bytes(bytes, size)` -- byte-for-byte identical to
     * our SH_HASH_KEY macro. Reusing the value keeps the simplehash
     * insert at one hash compute per slot, shared with the dynahash
     * insert. On bulk paths every slot already holds its hashvalue
     * in `slots[i].hashvalue` from the unpack loop.
     */
    entry = xcl_local_insert_hash(XClaimLocalSet, *key, hashvalue, &found);
    Assert(!found);                     /* caller verified absence */

    /*
     * Populate the entry. Field order matches the struct layout in
     * pg_xclaim_local.h (key already populated by SH_INSERT).
     */
    entry->hashvalue    = hashvalue;
    entry->partition_id = partition_id;

    /* Owner identity captured here -- saved fields are the SOLE source
     * of truth at cleanup time. */
    entry->saved_procno = (int32) xclaim_get_current_procno();
    entry->saved_lxid   = xclaim_get_current_top_lxid();
    entry->saved_token  = XClaimMyOwnerToken;

    entry->held = XCLAIM_LOCAL_HELD;
    /* `status` is already set by simplehash to SH_STATUS_IN_USE. */

    MemoryContextSwitchTo(old);

    return entry;
}

void
xclaim_local_note_held(const XClaimKey *key, uint32 hashvalue)
{
    Assert(key != NULL);

    /* Per-backend bookkeeping. */
    XClaimMyLocalCount++;
    if (XClaimMyLocalCount > XClaimMyPeakCount)
        XClaimMyPeakCount = XClaimMyLocalCount;

    /* Held-key list (see the file-scope comment). No allocation here. */
    if (XClaimHeldListLen < XClaimHeldListCap)
    {
        XClaimHeldList[XClaimHeldListLen].key       = *key;
        XClaimHeldList[XClaimHeldListLen].hashvalue = hashvalue;
        XClaimHeldListLen++;
    }
    else
        XClaimHeldListFull = true;

    /*
     * One-shot hint when this session's *live* count first crosses 75% of
     * the GUC. simplehash grows at SH_FILLFACTOR (0.9) of its
     * power-of-two-rounded capacity, so 75% of the GUC is an early signal
     * before the growth by the fill threshold, giving the DBA actionable
     * lead time to raise pg_xclaim.expected_claims_per_backend. A long
     * probe can grow the set earlier, and xclaim.try_many writes the hint
     * only after its loop.
     *
     * xclaim.try_many records its claims under a partition LWLock, so the
     * LOG is only marked pending: xclaim_local_emit_peak_warning() writes
     * it after the release. Writing a message can block on the client
     * socket or the log pipe, and an emit_log_hook can run arbitrary code.
     *
     * The check uses XClaimMyLocalCount (not XClaimMyPeakCount). Peak is
     * a session-lifetime high-water-mark intentionally not reset by
     * session_reset(), so using it would suppress legitimate re-warnings
     * after a session_reset followed by a fresh accumulation cycle. The
     * one-shot guard is the per-session XClaimMyPeakWarned flag, which
     * IS reset by session_reset().
     */
    if (unlikely(!XClaimMyPeakWarned))
    {
        uint64 threshold =
            (uint64) xclaim_expected_claims_per_backend * 3 / 4;

        if (XClaimMyLocalCount > threshold)
        {
            XClaimMyPeakWarned = true;
            XClaimMyPeakWarnPending = true;
            XClaimMyPeakWarnCount = XClaimMyLocalCount;
        }
    }
}

void
xclaim_local_insert_held(const XClaimKey *key,
                         uint32 hashvalue,
                         uint32 partition_id)
{
    (void) xclaim_local_add(key, hashvalue, partition_id);
    xclaim_local_note_held(key, hashvalue);
}

void
xclaim_local_drop(XClaimLocalEntry *entry)
{
    Assert(XClaimLocalSet != NULL);
    Assert(entry != NULL);

    /*
     * The entry pointer from xclaim_local_add() is still valid: nothing
     * inserts into or deletes from the set in between. The delete uses the
     * stored hash, allocates nothing and raises no ERROR.
     */
    xcl_local_delete_item(XClaimLocalSet, entry);
}

/* -------------------------------------------------------------------- */
/* xclaim_local_emit_peak_warning                                       */
/*                                                                      */
/* Writes the 75% hint marked by xclaim_local_note_held(), with the     */
/* live count at the crossing. The acquisition paths call it after the  */
/* partition LWLock is released. A hint marked before an ERROR (the     */
/* claims of the call may be gone by then) is written by the next call: */
/* the set did reach that count and grew for it.                        */
/* -------------------------------------------------------------------- */

void
xclaim_local_emit_peak_warning(void)
{
    if (likely(!XClaimMyPeakWarnPending))
        return;

    /* No message under a partition LWLock of this extension. */
    Assert(!LWLockAnyHeldByMe(&XClaimPartitionLocks[0].lock,
                              XClaimCtl->num_partitions,
                              sizeof(LWLockPadded)));

    XClaimMyPeakWarnPending = false;
    ereport(LOG,
            (errmsg("pg_xclaim: per-backend live claims (%llu) crossed "
                    "75%% of pg_xclaim.expected_claims_per_backend (%d) -- "
                    "simplehash will rehash on further growth",
                    (unsigned long long) XClaimMyPeakWarnCount,
                    xclaim_expected_claims_per_backend),
             errhint("Raise pg_xclaim.expected_claims_per_backend to "
                     "your observed peak and restart the cluster.")));
}

/* -------------------------------------------------------------------- */
/* xclaim_local_fit_held_list                                           */
/*                                                                      */
/* Sizes the held-key list for the current set: at least                */
/* XCLAIM_HELD_LIST_MIN keys, and 1/XCLAIM_HELD_LIST_RATIO of the       */
/* buckets, so every transaction that a list cleanup would serve fits   */
/* in it (about 1% of the set's memory). Runs before a partition LWLock */
/* is taken. When the arrays cannot be allocated it keeps the current   */
/* ones: the list then overflows earlier and cleanup takes the full     */
/* path, which is slower but correct.                                   */
/* -------------------------------------------------------------------- */

static void
xclaim_local_fit_held_list(void)
{
    uint64              want;
    XClaimHeldKey      *list;
    XClaimLocalEntry  **buf;

    want = Max((uint64) XCLAIM_HELD_LIST_MIN,
               XClaimLocalSet->size / XCLAIM_HELD_LIST_RATIO);
    if (likely(want <= XClaimHeldListCap))
        return;

    list = (XClaimHeldKey *)
        MemoryContextAllocExtended(XClaimLocalContext, want * sizeof(XClaimHeldKey),
                                   MCXT_ALLOC_HUGE | MCXT_ALLOC_NO_OOM);
    buf = (XClaimLocalEntry **)
        MemoryContextAllocExtended(XClaimLocalContext, want * sizeof(XClaimLocalEntry *),
                                   MCXT_ALLOC_HUGE | MCXT_ALLOC_NO_OOM);
    if (list == NULL || buf == NULL)
    {
        if (list != NULL)
            pfree(list);
        if (buf != NULL)
            pfree(buf);
        return;
    }

    memcpy(list, XClaimHeldList, XClaimHeldListLen * sizeof(XClaimHeldKey));
    pfree(XClaimHeldList);
    pfree(XClaimCleanupBuf);
    XClaimHeldList    = list;
    XClaimCleanupBuf  = buf;
    XClaimHeldListCap = (uint32) want;
}

/* -------------------------------------------------------------------- */
/* xclaim_local_shrink                                                  */
/*                                                                      */
/* Gives the empty set a bucket array of its first size and the large   */
/* one back to the allocator (see "Shrinking after a burst"). With      */
/* `force` the set shrinks whenever it is larger than its first size    */
/* (xclaim.session_reset()), otherwise only after XCLAIM_SHRINK_AFTER   */
/* small cleanups and from XCLAIM_SHRINK_FACTOR times the first size.   */
/*                                                                      */
/* Runs outside every partition LWLock with no claim held, and raises   */
/* no ERROR: the smaller arrays are allocated with MCXT_ALLOC_NO_OOM,   */
/* and when one does not fit the set keeps the arrays it has, which     */
/* serve every acquisition the smaller ones would. The streak of small  */
/* cleanups starts over either way, so a backend short of memory does   */
/* not retry on every acquisition.                                      */
/* -------------------------------------------------------------------- */

void
xclaim_local_shrink(bool force)
{
    XClaimLocalEntry   *data;
    XClaimHeldKey      *list;
    XClaimLocalEntry  **buf;

    if (XClaimLocalSet == NULL || XClaimLocalSet->members != 0)
        return;
    if (force)
    {
        if (XClaimLocalSet->size <= XClaimLocalFirstSize)
            return;
    }
    else if (XClaimSmallCleanups < XCLAIM_SHRINK_AFTER ||
             XClaimLocalSet->size < XClaimLocalFirstSize * XCLAIM_SHRINK_FACTOR)
        return;

    XClaimSmallCleanups = 0;

    /*
     * The set is empty: whatever the held-key list still names (keys of a
     * rolled back try_many, for example) is gone.
     */
    XClaimHeldListLen  = 0;
    XClaimHeldListFull = false;

    /*
     * The set is empty, so a zeroed array of the first size with the
     * geometry simplehash computes for it is the set xcl_local_create()
     * made at init (SH_STATUS_EMPTY is 0).
     */
    data = (XClaimLocalEntry *)
        MemoryContextAllocExtended(XClaimLocalContext,
                                   mul_size((Size) XClaimLocalFirstSize,
                                            sizeof(XClaimLocalEntry)),
                                   MCXT_ALLOC_HUGE | MCXT_ALLOC_ZERO |
                                   MCXT_ALLOC_NO_OOM);
    if (data == NULL)
        return;

    /*
     * Keep the largest size the set ever shrank from: a later, smaller
     * burst and its shrink must not lower what xclaim_local_prepare_bulk
     * restores for a large call.
     */
    XClaimLocalShrunkFrom = Max(XClaimLocalShrunkFrom, XClaimLocalSet->size);
    pfree(XClaimLocalSet->data);
    XClaimLocalSet->data = data;
    XClaimLocalArraySize = XClaimLocalFirstSize;
    xclaim_local_set_geometry(XClaimLocalSet, XClaimLocalFirstSize);

    if (XClaimHeldListCap > XCLAIM_HELD_LIST_MIN)
    {
        list = (XClaimHeldKey *)
            MemoryContextAllocExtended(XClaimLocalContext,
                                       XCLAIM_HELD_LIST_MIN * sizeof(XClaimHeldKey),
                                       MCXT_ALLOC_NO_OOM);
        buf = (XClaimLocalEntry **)
            MemoryContextAllocExtended(XClaimLocalContext,
                                       XCLAIM_HELD_LIST_MIN * sizeof(XClaimLocalEntry *),
                                       MCXT_ALLOC_NO_OOM);
        if (list != NULL && buf != NULL)
        {
            pfree(XClaimHeldList);
            pfree(XClaimCleanupBuf);
            XClaimHeldList    = list;
            XClaimCleanupBuf  = buf;
            XClaimHeldListCap = XCLAIM_HELD_LIST_MIN;
            XClaimHeldListLen = 0;
        }
        else
        {
            if (list != NULL)
                pfree(list);
            if (buf != NULL)
                pfree(buf);
        }
    }
}

/* -------------------------------------------------------------------- */
/* xclaim_local_reserve                                                 */
/*                                                                      */
/* Prepares the set for `additional` more inserts before a partition    */
/* LWLock is taken: shrinks an empty set after a burst, grows the set   */
/* so the inserts stay below its grow threshold, and sizes the          */
/* held-key list for the new size. A growth allocates and rehashes the  */
/* whole set, and under the LWLock every backend that needs the         */
/* partition would wait for it. An out-of-memory ERROR here leaves the  */
/* set as it was (xcl_local_allocate) and no shared state touched.      */
/*                                                                      */
/* No backend holds more claims than the shared table has room for, so  */
/* the reservation stops at pg_xclaim.max_claims.                       */
/*                                                                      */
/* simplehash also grows the set inside an insert, below the threshold, */
/* when a key probes more than SH_GROW_MAX_DIB buckets from its own     */
/* (from a fill of about 0.65 in large sets). xclaim.try inserts its    */
/* local entry before the partition LWLock, so that growth runs without */
/* the lock too. xclaim.try_many inserts under the lock of the          */
/* partition run, where a long-probe growth still holds the partition.  */
/* Its keys arrive partition by partition, and the partition is the low */
/* bits of the hash that also picks the bucket: the keys of one run     */
/* start their probes from 1/num_partitions of the buckets, and a large */
/* call grows the set by long probes from a fill of about 0.1.          */
/* -------------------------------------------------------------------- */

void
xclaim_local_reserve(uint64 additional)
{
    uint64        needed;
    uint64        target;
    MemoryContext old;

    Assert(XClaimLocalSet != NULL);

    if (XClaimLocalSet->members == 0)
        xclaim_local_shrink(false);

    needed = Min(XClaimLocalSet->members + additional, (uint64) xclaim_max_claims);
    if (unlikely(needed >= XClaimLocalSet->grow_threshold))
    {
        /*
         * Double until the grow threshold (simplehash: 0.9 of the size)
         * covers `needed`. simplehash's SH_MAX_SIZE (2^32 buckets, the
         * macro is undefined after the template) caps the size: past it,
         * the insert reports the set as full, as it does without this
         * reservation.
         */
        target = XClaimLocalSet->size;
        while ((uint64) (target * 0.9) <= needed &&
               target < ((uint64) PG_UINT32_MAX) + 1)
            target *= 2;
        if (target > XClaimLocalSet->size)
        {
            old = MemoryContextSwitchTo(XClaimLocalContext);
            xcl_local_grow(XClaimLocalSet, target);
            MemoryContextSwitchTo(old);
        }
    }

    xclaim_local_fit_held_list();
}

/* -------------------------------------------------------------------- */
/* xclaim_local_prepare_bulk                                            */
/*                                                                      */
/* Called by xclaim.try_many with the number of its keys, before its    */
/* first partition LWLock. Nothing to do while the claims the           */
/* transaction holds plus the call's keys take less than half of the    */
/* first bucket array. Otherwise the call needs a set of the smallest   */
/* size, from the first one up by doublings, with twice the room for    */
/* them, and:                                                           */
/*                                                                      */
/*   * a set at least XCLAIM_SHRINK_FACTOR times that size does not     */
/*     count against the streak of small cleanups. When the streak is   */
/*     complete and the set is empty, it shrinks here, before the runs. */
/*     A backend that runs long candidate lists after a burst gets a    */
/*     set of the size its calls need                                   */
/*   * a smaller set restarts the streak, so the reservation of the     */
/*     call's first partition run does not shrink a set the call needs  */
/*   * a set shrunk after an earlier burst grows back, toward the       */
/*     largest size it shrank from, until it has twice the room the     */
/*     claims need. The runs of the call insert under their partition   */
/*     LWLocks, where a growth would rehash the set while other         */
/*     backends wait. The keys of a run start their probes from         */
/*     1/num_partitions of the buckets, and long probes grow a set      */
/*     filled well below the 0.9 threshold, so the room is doubled.     */
/*                                                                      */
/* The keys are counted as given: repeated keys and keys the backend    */
/* holds already count too. The growth stops at a size the backend had  */
/* before, and a later shrink gives it back again.                      */
/*                                                                      */
/* The doubled room is for keys spread over the partitions the way the  */
/* hash spreads them. A backend that never had a set of the needed size */
/* still grows it inside the runs, under their locks (the known limit   */
/* of xclaim_local_reserve), and so can keys that crowd one partition   */
/* run more than that. An out-of-memory ERROR of the growth leaves the  */
/* set at the size before it, shrunk or not.                            */
/* -------------------------------------------------------------------- */

void
xclaim_local_prepare_bulk(uint64 nkeys)
{
    uint64        needed;
    uint64        want;
    uint64        target;
    MemoryContext old;

    Assert(XClaimLocalSet != NULL);

    needed = Min(XClaimLocalSet->members + nkeys, (uint64) xclaim_max_claims);
    if (needed < XClaimLocalFirstSize / 2)
        return;

    want = XClaimLocalFirstSize;
    while (want / 2 <= needed)
        want *= 2;
    if (XClaimLocalSet->size >= want * XCLAIM_SHRINK_FACTOR)
        xclaim_local_shrink(false);
    else
        XClaimSmallCleanups = 0;

    target = XClaimLocalSet->size;
    while (target / 2 <= needed && target < XClaimLocalShrunkFrom)
        target *= 2;
    if (target > XClaimLocalSet->size)
    {
        old = MemoryContextSwitchTo(XClaimLocalContext);
        xcl_local_grow(XClaimLocalSet, target);
        MemoryContextSwitchTo(old);
        xclaim_local_fit_held_list();
    }
}

/* -------------------------------------------------------------------- */
/* xclaim_local_reset_peak_warning                                      */
/*                                                                      */
/* Clear the per-session one-shot peak-warning flag. Called from        */
/* xclaim.session_reset() so that a backend which clears its local set */
/* and starts accumulating again can receive a fresh log hint if it    */
/* once more crosses 75% of the pre-grow target.                       */
/* -------------------------------------------------------------------- */
void
xclaim_local_reset_peak_warning(void)
{
    XClaimMyPeakWarned = false;
    XClaimMyPeakWarnPending = false;
}

/* -------------------------------------------------------------------- */
/* xclaim_local_remove                                                  */
/*                                                                      */
/* No-op when the local set is uninitialised or the key is absent --    */
/* the cleanup path MUST be idempotent (the xact callback and the       */
/* backend-exit callback both reach it with possibly empty state).      */
/* -------------------------------------------------------------------- */

void
xclaim_local_remove(const XClaimKey *key)
{
    bool removed;

    if (XClaimLocalSet == NULL)
        return;

    Assert(key != NULL);

    /*
     * simplehash's SH_DELETE deletes by key. There is no allocation
     * involved, so no MemoryContextSwitchTo wrapper is required for the
     * HARD invariant.
     */
    removed = xcl_local_delete(XClaimLocalSet, *key);
    if (removed && XClaimMyLocalCount > 0)
        XClaimMyLocalCount--;
    /* peak survives -- it is a high-water-mark, not a current count */
}

/* -------------------------------------------------------------------- */
/* xclaim_local_gather_pointers                                         */
/*                                                                      */
/* Used by the group-by-partition cleanup driver: pre-collect          */
/* pointers, then bucket-sort by partition_id, then process partition- */
/* at-a-time under a single LWLock acquire/release per partition (128  */
/* cycles vs 750k).                                                    */
/* -------------------------------------------------------------------- */

uint32
xclaim_local_gather_pointers(XClaimLocalEntry **buf, uint32 cap)
{
    xcl_local_iterator it;
    XClaimLocalEntry *entry;
    uint32 count = 0;

    Assert(buf != NULL || cap == 0);

    if (XClaimLocalSet == NULL)
        return 0;

    xcl_local_start_iterate(XClaimLocalSet, &it);
    while ((entry = xcl_local_iterate(XClaimLocalSet, &it)) != NULL)
    {
        if (count < cap)
            buf[count] = entry;
        count++;
    }

    return count;
}

/* -------------------------------------------------------------------- */
/* Stats helpers                                                        */
/* -------------------------------------------------------------------- */

uint64
xclaim_local_count(void)
{
    return XClaimMyLocalCount;
}

uint64
xclaim_local_peak(void)
{
    return XClaimMyPeakCount;
}

uint64
xclaim_local_my_owner_token(void)
{
    return XClaimMyOwnerToken;
}

/* -------------------------------------------------------------------- */
/* xclaim_shared_owner_matches_self                                     */
/*                                                                      */
/* Used by the acquisition own-entry-recovery branch -- "we hold this   */
/* entry but the local set somehow lost it". Reads CURRENT MyProc state */
/* (live triple) -- safe during acquisition because we are mid-xact.    */
/* The trap that proc->lxid is cleared by ProcArrayEndTransaction does  */
/* not apply on the acquisition path.                                   */
/*                                                                      */
/* Precondition: caller has invoked xclaim_ensure_owner_token() so      */
/* XClaimMyOwnerToken is non-zero. We return false defensively if the  */
/* local token has not been issued yet -- without a token the entry    */
/* cannot be "ours".                                                    */
/* -------------------------------------------------------------------- */

bool
xclaim_shared_owner_matches_self(const XClaimEntry *shared)
{
    Assert(shared != NULL);

    if (XClaimMyOwnerToken == 0)
        return false;

    return shared->owner_procno == (int32) xclaim_get_current_procno()
        && shared->owner_lxid   == xclaim_get_current_top_lxid()
        && shared->owner_token  == XClaimMyOwnerToken;
}

/* -------------------------------------------------------------------- */
/* Group-by-partition cleanup driver.                                   */
/*                                                                      */
/* Performance contract:                                                */
/*   * 50000 claims COMMIT cleanup latency MUST be < 100ms.             */
/*   * For 750k claims with default num_partitions=128, the bound is    */
/*     EXACTLY num_partitions LWLock acquire/release cycles -- per-key  */
/*     LWLock cycles are FORBIDDEN (MANDATORY group-by-partition).      */
/*   * The cost of a transaction that took a few claims does not depend */
/*     on the size of the set's bucket array.                           */
/*                                                                      */
/* Paths:                                                               */
/*   List    The claims fit in the held-key list, and they are at most  */
/*           1/XCLAIM_HELD_LIST_RATIO of the buckets. Each key is       */
/*           looked up, the entries are sorted by partition_id, the     */
/*           shared rows are released per partition run, and the keys  */
/*           are deleted from the set one by one. Nothing is allocated  */
/*           and nothing walks the bucket array.                        */
/*   Full    Otherwise. All live entries are gathered by walking the    */
/*           bucket array, bucket-sorted by partition_id (counting      */
/*           sort, O(N + num_partitions)), released per partition run,  */
/*           and xcl_local_reset() truncates the set with one memset.   */
/*   One by one                                                         */
/*           The full path could not allocate its arrays. One walk over */
/*           the set releases each shared row under its own partition   */
/*           LWLock, without allocating and without modifying the set,  */
/*           then xcl_local_reset() truncates it.                       */
/*                                                                      */
/* The set keeps its bucket array: the next acquisition burst reuses    */
/* the pages, and no cleanup path returns memory to the allocator       */
/* (MemoryContextReset -> munmap -> TLB shootdown on large arrays). A   */
/* grown array goes back later, through xclaim_local_shrink().          */
/*                                                                      */
/* Why precomputed partition_id? At acquire time the local entry        */
/* records `partition_id = hashvalue & (num_partitions - 1)`. Cleanup   */
/* would otherwise need to recompute hash + mask per entry under load.  */
/* The saved value is the SOLE input to the sort key.                   */
/*                                                                      */
/* Allocation at transaction end. This runs from the xact callback      */
/* (XACT_EVENT_COMMIT/ABORT) and from the backend-exit callback         */
/* (`on_shmem_exit`), where an ereport(ERROR) must not escape. At xact  */
/* end it ends in PANIC and a crash restart of the cluster: PostgreSQL  */
/* either refuses to abort an already committed transaction or retries  */
/* the abort until the error stack overflows. During proc_exit it       */
/* escalates to FATAL, which skips the rest of the cleanup and the      */
/* owner_token invalidation, so the remaining shared rows stay held     */
/* until the stale-owner reaper can take them over (on PG 16 only after */
/* the PGPROC slot is reused). The list path allocates nothing, the     */
/* full path allocates with MCXT_ALLOC_NO_OOM and falls back to the     */
/* one-by-one path on NULL.                                             */
/*                                                                      */
/* The pointer arrays are allocated with MCXT_ALLOC_HUGE: from         */
/* 134217728 held claims (2^27 on 64-bit) they pass MaxAllocSize, and   */
/* without it the request would raise an ERROR instead of returning     */
/* NULL to the one-by-one path.                                         */
/*                                                                      */
/* Idempotency: if the local set is empty (count == 0) the function     */
/* returns immediately. The xact callback and the backend-exit callback */
/* both call it with possibly empty state. ABORT re-entry after a 2PC   */
/* PRE_PREPARE ERROR also lands here twice -- the second call is a     */
/* no-op.                                                               */
/* -------------------------------------------------------------------- */

/* Empties the held-key list: the set is empty or about to be. */
static inline void
xclaim_local_forget_held_list(void)
{
    XClaimHeldListLen  = 0;
    XClaimHeldListFull = false;
}

/* qsort comparator: local entry pointers by partition_id. */
static int
xclaim_local_cmp_partition(const void *a, const void *b)
{
    uint32 pa = (*(XClaimLocalEntry *const *) a)->partition_id;
    uint32 pb = (*(XClaimLocalEntry *const *) b)->partition_id;

    return (pa > pb) - (pa < pb);
}

/*
 * xclaim_local_release_sorted
 *      Releases the shared rows of `count` local entries sorted by
 *      partition_id and returns how many were removed.
 *
 * Each contiguous run with the same partition_id is exactly ONE LWLock
 * cycle, so the cycles are bounded by num_partitions (128 default)
 * regardless of the claim count.
 *
 * For each entry whose shared row matches our SAVED owner triple
 * (saved_procno + saved_lxid + saved_token -- never read MyProc here, as
 * MyProc->lxid was cleared by ProcArrayEndTransaction() before the xact
 * callback fired), HASH_REMOVE under the partition lock. A mismatch (row
 * gone, or owned by someone else) increments cleanup_misses. Normal
 * operation never produces one: the reaper takes over only rows whose
 * owner exited or rotated its token, and session_reset releases the held
 * entries before it rotates the token. A non-zero counter means an entry
 * left its live owner (a reaper false positive or corrupted shared state).
 *
 * The caller subtracts the result from live_capacity once: a single
 * pg_atomic_fetch_sub_u64 instead of one per row on the shared cache line.
 */
static uint32
xclaim_local_release_sorted(XClaimLocalEntry **buf, uint32 count)
{
    uint32      removed = 0;
    uint32      i = 0;

    while (i < count)
    {
        uint32      run_start = i;
        uint32      pid = buf[i]->partition_id;
        LWLock     *plock;
        uint32      j;

        /* Find run end: next partition_id boundary. */
        while (i < count && buf[i]->partition_id == pid)
            i++;

        /*
         * pid was computed as `hashvalue & (num_partitions - 1)` at
         * acquisition time, and partition_locks[] is indexed
         * [0, num_partitions).
         */
        Assert(pid < (uint32) XClaimCtl->num_partitions);
        plock = &XClaimPartitionLocks[pid].lock;

        /*
         * Single LWLock acquire per partition. From here through release
         * we do ONLY HASH_FIND / HASH_REMOVE (no allocation, no
         * ereport-prone code) -- safe under lock.
         */
        LWLockAcquire(plock, LW_EXCLUSIVE);

        for (j = run_start; j < i; j++)
        {
            const XClaimLocalEntry  *saved = buf[j];
            XClaimEntry             *shared;
            bool                     found;

            shared = (XClaimEntry *) hash_search_with_hash_value(
                XClaimHash,
                &saved->key,
                saved->hashvalue,
                HASH_FIND,
                &found);

            if (found && xclaim_shared_matches_saved_owner(shared, saved))
            {
                (void) hash_search_with_hash_value(
                    XClaimHash,
                    &saved->key,
                    saved->hashvalue,
                    HASH_REMOVE,
                    NULL);
                removed++;
            }
            else
                pg_atomic_fetch_add_u64(&XClaimCtl->cleanup_misses, 1);
        }

        LWLockRelease(plock);
    }

    return removed;
}

/*
 * xclaim_local_release_one_by_one
 *      Out-of-memory path of the full cleanup: releases the shared row of
 *      every entry in one walk over the set, each under its own partition
 *      LWLock. Allocates nothing and leaves the set unmodified, so the
 *      walk is linear in the bucket count. The caller truncates the set.
 *
 * live_capacity is decremented per row here, not once at the end: each
 * removed row has its capacity already returned, so the counter stays
 * equal to the shared row count whatever stops the walk.
 */
static void
xclaim_local_release_one_by_one(void)
{
    xcl_local_iterator  it;
    XClaimLocalEntry   *saved;

    xcl_local_start_iterate(XClaimLocalSet, &it);
    while ((saved = xcl_local_iterate(XClaimLocalSet, &it)) != NULL)
    {
        LWLock      *plock;
        XClaimEntry *shared;
        bool         found;

        Assert(saved->partition_id < (uint32) XClaimCtl->num_partitions);
        plock = &XClaimPartitionLocks[saved->partition_id].lock;

        LWLockAcquire(plock, LW_EXCLUSIVE);
        shared = (XClaimEntry *)
            hash_search_with_hash_value(XClaimHash, &saved->key,
                                        saved->hashvalue, HASH_FIND, &found);
        if (found && xclaim_shared_matches_saved_owner(shared, saved))
        {
            (void) hash_search_with_hash_value(XClaimHash, &saved->key,
                                               saved->hashvalue, HASH_REMOVE,
                                               NULL);
            pg_atomic_fetch_sub_u64(&XClaimCtl->live_capacity, 1);
        }
        else
            pg_atomic_fetch_add_u64(&XClaimCtl->cleanup_misses, 1);
        LWLockRelease(plock);
    }
}

/*
 * xclaim_local_cleanup_by_list
 *      List path. Returns false, with the set untouched, when the list does
 *      not cover every live entry, and the caller takes the full path.
 */
static bool
xclaim_local_cleanup_by_list(void)
{
    uint32      members = (uint32) XClaimLocalSet->members;
    uint32      gathered = 0;
    uint32      removed;
    uint32      i;

    for (i = 0; i < XClaimHeldListLen; i++)
    {
        XClaimLocalEntry *entry;

        entry = xcl_local_lookup_hash(XClaimLocalSet,
                                      XClaimHeldList[i].key,
                                      XClaimHeldList[i].hashvalue);
        /* Removed by a rollback, or listed twice and already gathered. */
        if (entry == NULL || entry->held != XCLAIM_LOCAL_HELD)
            continue;
        if (gathered == members)
        {
            gathered++;                 /* more live entries than members */
            break;
        }
        entry->held = XCLAIM_LOCAL_VISITED;
        XClaimCleanupBuf[gathered++] = entry;
    }

    if (gathered != members)
    {
        /* Some live entry is not listed: undo the marks, take the full path. */
        for (i = 0; i < Min(gathered, members); i++)
            XClaimCleanupBuf[i]->held = XCLAIM_LOCAL_HELD;
        return false;
    }

    if (gathered > 1)
        qsort(XClaimCleanupBuf, gathered, sizeof(XClaimLocalEntry *),
              xclaim_local_cmp_partition);

    removed = xclaim_local_release_sorted(XClaimCleanupBuf, gathered);

    /*
     * Delete by key, not through XClaimCleanupBuf: a delete moves the
     * entries that follow it in the bucket array, so the gathered pointers
     * are stale after the first one. A key listed twice or removed by a
     * rollback misses, which is a no-op.
     */
    for (i = 0; i < XClaimHeldListLen; i++)
        (void) xcl_local_delete(XClaimLocalSet, XClaimHeldList[i].key);
    Assert(XClaimLocalSet->members == 0);

    if (removed > 0)
        pg_atomic_fetch_sub_u64(&XClaimCtl->live_capacity, removed);

    return true;
}

/*
 * xclaim_local_cleanup_full
 *      Full path: walk, bucket-sort, release, memset.
 */
static void
xclaim_local_cleanup_full(void)
{
    uint32              members = (uint32) XClaimLocalSet->members;
    int                 num_parts = XClaimCtl->num_partitions;
    XClaimLocalEntry  **buf;
    XClaimLocalEntry  **scratch;
    uint32             *partition_counts;
    uint32             *partition_cursor;
    uint32              count;
    uint32              removed;
    uint32              acc;
    uint32              i;
    int                 p;
    MemoryContext       old;

    /*
     * MemoryContextSwitchTo restore safety: the switch back to `old`
     * happens before any code path that can ereport. Below the known
     * limit these palloc calls cannot ereport -- they return NULL on
     * out-of-memory. The simplehash iteration helpers do not allocate.
     */
    old = MemoryContextSwitchTo(XClaimLocalContext);
    buf = (XClaimLocalEntry **)
        palloc_extended(mul_size(members, sizeof(XClaimLocalEntry *)),
                        MCXT_ALLOC_HUGE | MCXT_ALLOC_NO_OOM);
    scratch = (XClaimLocalEntry **)
        palloc_extended(mul_size(members, sizeof(XClaimLocalEntry *)),
                        MCXT_ALLOC_HUGE | MCXT_ALLOC_NO_OOM);
    partition_counts = (uint32 *)
        palloc_extended(num_parts * sizeof(uint32),
                        MCXT_ALLOC_NO_OOM | MCXT_ALLOC_ZERO);
    partition_cursor = (uint32 *)
        palloc_extended(num_parts * sizeof(uint32), MCXT_ALLOC_NO_OOM);
    MemoryContextSwitchTo(old);

    if (buf == NULL || scratch == NULL ||
        partition_counts == NULL || partition_cursor == NULL)
    {
        /* pfree does not accept NULL. */
        if (buf != NULL)
            pfree(buf);
        if (scratch != NULL)
            pfree(scratch);
        if (partition_counts != NULL)
            pfree(partition_counts);
        if (partition_cursor != NULL)
            pfree(partition_cursor);

        xclaim_local_release_one_by_one();
        xcl_local_reset(XClaimLocalSet);
        return;
    }

    /*
     * The walk returns every live entry and stores at most `members`. If
     * the count of live entries ever disagreed with `members`, only the
     * stored pointers are used.
     */
    count = Min(xclaim_local_gather_pointers(buf, members), members);

    /* Pass 1: count entries per partition. */
    for (i = 0; i < count; i++)
        partition_counts[buf[i]->partition_id]++;

    /* Pass 2: exclusive prefix sum -> per-partition starting offset. */
    acc = 0;
    for (p = 0; p < num_parts; p++)
    {
        partition_cursor[p] = acc;
        acc += partition_counts[p];
    }

    /* Pass 3: stable placement into bucket order. */
    for (i = 0; i < count; i++)
    {
        uint32 pid = buf[i]->partition_id;

        scratch[partition_cursor[pid]++] = buf[i];
    }

    removed = xclaim_local_release_sorted(scratch, count);
    if (removed > 0)
        pg_atomic_fetch_sub_u64(&XClaimCtl->live_capacity, removed);

    /*
     * Truncate the simplehash in-place: one memset over the bucket array,
     * which keeps the array for the next burst.
     */
    xcl_local_reset(XClaimLocalSet);

    pfree(partition_cursor);
    pfree(partition_counts);
    pfree(scratch);
    pfree(buf);
}

void
xclaim_local_cleanup_held(void)
{
    /* Idempotent no-op: nothing held -> nothing to do. */
    if (XClaimLocalSet == NULL)
        return;
    if (XClaimLocalSet->members == 0)
    {
        xclaim_local_forget_held_list();
        XClaimMyLocalCount = 0;
        return;
    }

    /* Small: the claims would have fit in the first bucket array. */
    if (XClaimLocalSet->members < XClaimLocalFirstThreshold)
    {
        if (XClaimSmallCleanups < XCLAIM_SHRINK_AFTER)
            XClaimSmallCleanups++;
    }
    else
        XClaimSmallCleanups = 0;

    if (XClaimHeldListFull ||
        (uint64) XClaimLocalSet->members * XCLAIM_HELD_LIST_RATIO > XClaimLocalSet->size ||
        !xclaim_local_cleanup_by_list())
        xclaim_local_cleanup_full();

    xclaim_local_forget_held_list();
    XClaimMyLocalCount = 0;
    /* peak intentionally retained -- session-lifetime stat */
}

/* -------------------------------------------------------------------- */
/* xclaim_local_holds_current_xact                                      */
/*                                                                      */
/* True when the set holds a claim taken by the running top-level       */
/* transaction of this backend: saved procno, lxid and token equal the  */
/* live ones. xclaim.session_reset() refuses to release such claims.    */
/* Walks the whole set, which only session_reset() needs.               */
/* -------------------------------------------------------------------- */

bool
xclaim_local_holds_current_xact(void)
{
    xcl_local_iterator  it;
    XClaimLocalEntry   *entry;
    int32               procno;
    LocalTransactionId  lxid;

    if (XClaimLocalSet == NULL || XClaimLocalSet->members == 0 ||
        XClaimMyOwnerToken == 0)
        return false;

    procno = (int32) xclaim_get_current_procno();
    lxid   = xclaim_get_current_top_lxid();

    xcl_local_start_iterate(XClaimLocalSet, &it);
    while ((entry = xcl_local_iterate(XClaimLocalSet, &it)) != NULL)
    {
        if (entry->saved_procno == procno &&
            entry->saved_lxid   == lxid &&
            entry->saved_token  == XClaimMyOwnerToken)
            return true;
    }
    return false;
}

/* -------------------------------------------------------------------- */
/* xclaim_local_clear_owner_token                                       */
/*                                                                      */
/* Used by xclaim_session_reset(). Drops the cached token so the next  */
/* acquisition reissues a fresh value via                               */
/* xclaim_ensure_owner_token(). Also clears our published per-backend   */
/* slot so the stale-owner reaper observes the rotation and treats     */
/* any leftover shared rows owned by the OLD token as stale on the     */
/* next conflict.                                                       */
/* -------------------------------------------------------------------- */

void
xclaim_local_clear_owner_token(void)
{
    int procno;

    XClaimMyOwnerToken = 0;

    /*
     * Publish 0 (invalid sentinel) into our slot so any conflicting
     * backend's stale-owner reaper sees a token mismatch on the saved
     * owner_token of any leftover shared row and reaps it. Reads of
     * the slot are unlocked atomic loads, and we use an atomic write here
     * for publication consistency.
     */
    procno = xclaim_get_current_procno();
    if (procno >= 0 && procno < MaxBackends)
        pg_atomic_write_u64(&XClaimBackendInfos[procno].current_token, 0);
}
