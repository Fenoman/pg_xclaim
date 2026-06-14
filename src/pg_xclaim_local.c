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
/* SH_STORE_HASH is intentionally NOT defined: SH_HASH_KEY is cheap    */
/* (single hash_bytes call over 16 bytes) and storing would inflate    */
/* the entry. We DO carry our own `hashvalue` member, but that is the  */
/* DYNAHASH precomputed value (used by cleanup against the shared      */
/* HTAB), which -- by the identity above -- is also a valid simplehash */
/* hash for the same key.                                              */
/* -------------------------------------------------------------------- */

#define SH_PREFIX               xcl_local
#define SH_ELEMENT_TYPE         XClaimLocalEntry
#define SH_KEY_TYPE             XClaimKey
#define SH_KEY                  key
#define SH_HASH_KEY(tb, key)    \
    hash_bytes((const unsigned char *) &(key), sizeof(XClaimKey))
#define SH_EQUAL(tb, a, b)      \
    (memcmp(&(a), &(b), sizeof(XClaimKey)) == 0)
#define SH_SCOPE                static inline
#define SH_DECLARE
#define SH_DEFINE
#include "lib/simplehash.h"

/* -------------------------------------------------------------------- */
/* File-scope state.                                                    */
/*                                                                      */
/* All four globals are TU-private (`static`). The header exposes a    */
/* small read-only API instead of the raw pointers so refactors (e.g.  */
/* dynahash fallback) do not break consumers.                          */
/* -------------------------------------------------------------------- */

static xcl_local_hash *XClaimLocalSet      = NULL;          /* simplehash */
static MemoryContext   XClaimLocalContext  = NULL;          /* child of Top */
static uint64          XClaimMyOwnerToken  = 0;             /* 0 = unallocated */
static uint64          XClaimMyLocalCount  = 0;             /* live entries */
static uint64          XClaimMyPeakCount   = 0;             /* high-water-mark */
static bool            XClaimMyPeakWarned  = false;         /* per-session, one-shot */

/* -------------------------------------------------------------------- */
/* xclaim_local_init                                                    */
/*                                                                      */
/* Lazy, idempotent. Called from each SQL entry point AFTER             */
/* XCLAIM_REQUIRE_INIT(). Creates a child MemoryContext anchored to     */
/* TopMemoryContext (HARD invariant -- see comment block at file top)   */
/* and instantiates the simplehash with `expected_claims_per_backend`   */
/* slots so steady-state acquisition does not pay rehash cost. Sessions */
/* that legitimately exceed the GUC value (e.g. >16k concurrent claims  */
/* on the default) WILL trigger simplehash growth; raise the GUC to     */
/* keep the burst path rehash-free.                                     */
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
     * cleanup truncates the live set via xcl_local_reset() (a memset
     * over the simplehash bucket array), leaving the underlying chunks
     * pinned to this context so the next acquisition burst reuses
     * already-allocated pages. The context is torn down only at backend
     * exit with TopMemoryContext.
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
     * grow path; raise the GUC for those workloads. simplehash grows
     * at SH_FILLFACTOR (0.9), so rehash-free capacity actually extends
     * somewhat ABOVE the GUC value. The 75%-of-GUC peak warning emitted
     * elsewhere is a deliberately early heads-up, well before that
     * 0.9-fillfactor grow point.
     */
    XClaimLocalSet = xcl_local_create(XClaimLocalContext,
                                      (uint32) xclaim_expected_claims_per_backend,
                                      NULL);

    MemoryContextSwitchTo(old);

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
/* first fetch_add returns 1, never 0; 0 is the reserved sentinel for   */
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
     * Atomic fetch-and-add. next_token starts at 1, so the first reader
     * gets 1; subsequent readers get 2, 3, ... A token is issued at most
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
     * to decide whether a row owned by `token` is stale; if the reaper
     * ran while XClaimMyOwnerToken=token but the slot still held the
     * inactive sentinel (0), it would treat freshly-acquired rows as
     * stale and reap them -- a false positive that silently releases
     * a valid claim.
     *
     * Any ereport between issuing the token and publishing it (Assert
     * failure on a corrupted procno, a CHECK_FOR_INTERRUPTS in this
     * path) would leave us with a token that was never published.
     * Publishing before recording XClaimMyOwnerToken keeps the slot
     * consistent on every unwind path. If a retry occurs, the next
     * fetch_add issues a FRESH token (the counter only moves forward);
     * that is safe because the failed attempt never published the
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
/* TOP-LEVEL lxid; subtxn lxid would not match the shared entry's      */
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
/* xclaim_local_insert_held                                             */
/*                                                                      */
/* PRECONDITIONS:                                                       */
/*   * xclaim_local_init()           ran.                               */
/*   * xclaim_ensure_owner_token()   ran (XClaimMyOwnerToken != 0).     */
/*   * caller verified absence via xclaim_local_lookup() -- the assert  */
/*     `!found` enforces this.                                          */
/*                                                                      */
/* MEMORY-CONTEXT WRAPPING (HARD invariant -- see file-top comment):    */
/*   simplehash.h's xcl_local_insert() palloc's any growth segments    */
/*   from CurrentMemoryContext. We MemoryContextSwitchTo the child     */
/*   context BEFORE invoking it and restore AFTER -- dropping this     */
/*   wrapper would let a subtxn-rolled allocation                      */
/*   leak the shared entry.                                            */
/* -------------------------------------------------------------------- */

void
xclaim_local_insert_held(const XClaimKey *key,
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
     * insert; on bulk paths every slot already holds its hashvalue
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

    entry->held = 1;
    /* `status` is already set by simplehash to SH_STATUS_IN_USE. */

    MemoryContextSwitchTo(old);

    /* Per-backend bookkeeping. */
    XClaimMyLocalCount++;
    if (XClaimMyLocalCount > XClaimMyPeakCount)
        XClaimMyPeakCount = XClaimMyLocalCount;

    /*
     * One-shot LOG hint when this session's *live* count first crosses
     * 75% of the GUC. simplehash grows at SH_FILLFACTOR (0.9) of its
     * power-of-two-rounded capacity, so 75% of the GUC is an early
     * signal that lands well before the first rehash, giving the DBA
     * actionable lead time to raise pg_xclaim.expected_claims_per_backend.
     *
     * The check uses XClaimMyLocalCount (not XClaimMyPeakCount). Peak is
     * a session-lifetime high-water-mark intentionally not reset by
     * session_reset(); using it would suppress legitimate re-warnings
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
            ereport(LOG,
                    (errmsg("pg_xclaim: per-backend live claims (%llu) crossed "
                            "75%% of pg_xclaim.expected_claims_per_backend (%d) -- "
                            "simplehash will rehash on further growth",
                            (unsigned long long) XClaimMyLocalCount,
                            xclaim_expected_claims_per_backend),
                     errhint("Raise pg_xclaim.expected_claims_per_backend to "
                             "your observed peak and restart the cluster.")));
            XClaimMyPeakWarned = true;
        }
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
}

/* -------------------------------------------------------------------- */
/* xclaim_local_remove                                                  */
/*                                                                      */
/* No-op when the local set is uninitialised or the key is absent --    */
/* the cleanup path MUST be idempotent (xact callback may run before    */
/* before_shmem_exit; both must tolerate already-empty state).          */
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
     * HARD invariant -- still, kept inside the local-context for
     * symmetry with insert.
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
/* (live triple) -- safe during acquisition because we are mid-xact;    */
/* the trap that proc->lxid is cleared by ProcArrayEndTransaction does  */
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
/*   * The ratio of cycles vs per-key cleanup at 750k claims is         */
/*     750000 / 128 = ~5860 entries/partition; 128 cycles vs 750000     */
/*     cycles == 2900x speedup.                                         */
/*                                                                      */
/* Algorithm:                                                           */
/*   1. Gather all live local-set pointers into a transient array       */
/*      (palloc inside the local context).                              */
/*   2. Counting (bucket) sort the array by precomputed partition_id    */
/*      (saved at acquire time -- never recomputed under lock). The     */
/*      keyspace is bounded to num_partitions (128 default), so the     */
/*      sort is O(N + num_partitions) -- beats qsort O(N log N) for     */
/*      typical N.                                                      */
/*   3. Walk the sorted array; for each contiguous run with the same    */
/*      partition_id, acquire its LWLock ONCE, HASH_REMOVE every entry  */
/*      whose shared row matches our SAVED owner triple, then release.  */
/*   4. xcl_local_reset() truncates the simplehash in-place. This       */
/*      avoids the MemoryContextReset->munmap->TLB-shootdown chain that */
/*      would otherwise dominate cleanup latency for large batches.     */
/*                                                                      */
/* Why precomputed partition_id? At acquire time the local entry        */
/* records `partition_id = hashvalue & (num_partitions - 1)`; cleanup   */
/* would otherwise need to recompute hash + mask per entry under load.  */
/* The saved value is the SOLE input to the bucket-sort key.            */
/*                                                                      */
/* Idempotency: if the local set is empty (count == 0) the function     */
/* returns immediately. xact callback may run before before_shmem_exit; */
/* both must tolerate already-empty state. ABORT re-entry after a 2PC   */
/* PRE_PREPARE ERROR also lands here twice -- the second call is a     */
/* no-op.                                                               */
/* -------------------------------------------------------------------- */

void
xclaim_local_cleanup_held(void)
{
    XClaimLocalEntry  **buf;
    uint32              count;
    uint32              i;
    uint32              total_removed = 0;  /* aggregated for batched live_capacity decrement */
    MemoryContext       old;

    /* Idempotent no-op: nothing held -> nothing to do. */
    if (XClaimLocalSet == NULL)
        return;
    if (XClaimMyLocalCount == 0)
        return;

    count = (uint32) XClaimMyLocalCount;

    /*
     * Allocate the pointer array inside XClaimLocalContext using the
     * NO_OOM allocator. This callback runs from xact-end
     * (XACT_EVENT_COMMIT/ABORT) and `before_shmem_exit`; ereport(ERROR)
     * from inside an xact callback escalates to FATAL because there is
     * no transaction frame to roll back into. A FATAL here orphans the
     * shared dynahash rows -- they will eventually be reaped by the
     * stale-owner reaper, but we want to do better than that.
     *
     * Strategy: try the bulk-grouped fast path (palloc with NO_OOM
     * returns NULL on failure); on NULL, fall back to the per-entry
     * slow path that does NO additional palloc -- it iterates the
     * simplehash directly and HASH_REMOVEs each shared row under its
     * own partition LWLock. The slow path is O(N * lwlock_cost) instead
     * of O(N + num_partitions), but it cannot ereport(ERROR) due to
     * memory pressure.
     *
     * MemoryContextSwitchTo restore safety: every switch into
     * XClaimLocalContext is paired with a switch back to `old` BEFORE
     * any code path that can ereport. The fast path's palloc calls use
     * MCXT_ALLOC_NO_OOM, so they cannot ereport -- they return NULL.
     * The simplehash iteration helpers do not allocate. Net: no PG_TRY
     * is required around the body; control flow always reaches the
     * MemoryContextSwitchTo(old) before any ereport-prone code.
     */
    old = MemoryContextSwitchTo(XClaimLocalContext);
    buf = (XClaimLocalEntry **) palloc_extended(count * sizeof(XClaimLocalEntry *),
                                                MCXT_ALLOC_NO_OOM);
    MemoryContextSwitchTo(old);

    if (buf == NULL)
    {
        /*
         * OOM fast-path allocation failed. Fall back to a per-entry
         * sweep that reuses the simplehash iterator -- one LWLock cycle
         * per entry instead of per-partition, slower but reliably
         * non-throwing. live_capacity bookkeeping stays consistent: we
         * still SUB once per actual HASH_REMOVE.
         *
         * We MUST NOT iterate the simplehash while mutating it, so
         * we collect at most one entry per pass and remove until the
         * count reaches zero. simplehash's iteration is safe under
         * delete only via xcl_local_delete; we use the latter.
         */
        while (XClaimMyLocalCount > 0)
        {
            xcl_local_iterator  it;
            XClaimLocalEntry    *probe;
            XClaimKey            saved_key;
            uint32               saved_hash;
            uint32               saved_pid;
            int32                saved_procno;
            LocalTransactionId   saved_lxid;
            uint64               saved_token;
            LWLock              *plock;

            xcl_local_start_iterate(XClaimLocalSet, &it);
            probe = xcl_local_iterate(XClaimLocalSet, &it);
            if (probe == NULL)
                break;                  /* count out-of-sync; defensive exit */

            saved_key    = probe->key;
            saved_hash   = probe->hashvalue;
            saved_pid    = probe->partition_id;
            saved_procno = probe->saved_procno;
            saved_lxid   = probe->saved_lxid;
            saved_token  = probe->saved_token;

            Assert(saved_pid < (uint32) XClaimCtl->num_partitions);
            plock = &XClaimPartitionLocks[saved_pid].lock;

            LWLockAcquire(plock, LW_EXCLUSIVE);
            {
                XClaimEntry *shared;
                bool         found;

                shared = (XClaimEntry *)
                    hash_search_with_hash_value(XClaimHash, &saved_key,
                                                saved_hash, HASH_FIND, &found);
                if (found
                    && shared->owner_procno == saved_procno
                    && shared->owner_lxid   == saved_lxid
                    && shared->owner_token  == saved_token)
                {
                    (void) hash_search_with_hash_value(XClaimHash, &saved_key,
                                                       saved_hash, HASH_REMOVE,
                                                       NULL);
                    /*
                     * Per-row atomic SUB is intentional on the slow path
                     * (vs the fast path's batched flush). If a FATAL or
                     * panic interrupts the loop mid-flight, each row
                     * already removed has already had its capacity
                     * decremented; live_capacity stays consistent with
                     * the actual dynahash row count without needing a
                     * post-loop reconciliation. Do NOT consistency-
                     * refactor this into a deferred batch.
                     */
                    pg_atomic_fetch_sub_u64(&XClaimCtl->live_capacity, 1);
                }
                else
                {
                    pg_atomic_fetch_add_u64(&XClaimCtl->cleanup_misses, 1);
                }
            }
            LWLockRelease(plock);

            (void) xcl_local_delete(XClaimLocalSet, saved_key);
            if (XClaimMyLocalCount > 0)
                XClaimMyLocalCount--;
        }
        /* Fall through to xcl_local_reset below for arena truncation. */
        xcl_local_reset(XClaimLocalSet);
        XClaimMyLocalCount = 0;
        return;
    }

    {
        uint32 gathered = xclaim_local_gather_pointers(buf, count);
        Assert(gathered == count);
        (void) gathered;            /* silence -Wunused-but-set in NDEBUG builds */
    }

    /*
     * Group-by-partition_id via counting sort: O(N + num_parts) vs
     * qsort's O(N log N). The keyspace is bounded to num_partitions
     * (128 default) -- a single linear pass to count, a prefix sum, and
     * a placement pass yield a stable bucket-ordered array. Allocation
     * is pfree-balanced inside the local context. NO_OOM fast-fail
     * cascades to per-entry slow path identical to the buf NULL branch
     * above.
     */
    {
        int                 num_parts = XClaimCtl->num_partitions;
        uint32             *partition_counts;
        uint32             *partition_cursor;
        XClaimLocalEntry  **scratch;
        uint32              acc;
        int                 p;

        old = MemoryContextSwitchTo(XClaimLocalContext);
        partition_counts = (uint32 *) palloc_extended(num_parts * sizeof(uint32),
                                                      MCXT_ALLOC_NO_OOM | MCXT_ALLOC_ZERO);
        partition_cursor = (uint32 *) palloc_extended(num_parts * sizeof(uint32),
                                                      MCXT_ALLOC_NO_OOM);
        scratch = (XClaimLocalEntry **) palloc_extended(count * sizeof(*scratch),
                                                        MCXT_ALLOC_NO_OOM);
        MemoryContextSwitchTo(old);

        if (partition_counts == NULL || partition_cursor == NULL || scratch == NULL)
        {
            /*
             * Couldn't allocate scratch arrays. Free what we have and
             * fall back to per-entry slow path (same code as the buf
             * NULL branch). pfree does NOT accept NULL (it reads the
             * chunk header just before the pointer), hence the explicit
             * NULL guards below.
             */
            if (scratch != NULL)
                pfree(scratch);
            if (partition_cursor != NULL)
                pfree(partition_cursor);
            if (partition_counts != NULL)
                pfree(partition_counts);
            pfree(buf);

            while (XClaimMyLocalCount > 0)
            {
                xcl_local_iterator  it;
                XClaimLocalEntry    *probe;
                XClaimKey            saved_key;
                uint32               saved_hash;
                uint32               saved_pid;
                int32                saved_procno;
                LocalTransactionId   saved_lxid;
                uint64               saved_token;
                LWLock              *plock_local;

                xcl_local_start_iterate(XClaimLocalSet, &it);
                probe = xcl_local_iterate(XClaimLocalSet, &it);
                if (probe == NULL)
                    break;

                saved_key    = probe->key;
                saved_hash   = probe->hashvalue;
                saved_pid    = probe->partition_id;
                saved_procno = probe->saved_procno;
                saved_lxid   = probe->saved_lxid;
                saved_token  = probe->saved_token;

                Assert(saved_pid < (uint32) XClaimCtl->num_partitions);
                plock_local = &XClaimPartitionLocks[saved_pid].lock;

                LWLockAcquire(plock_local, LW_EXCLUSIVE);
                {
                    XClaimEntry *shared;
                    bool         found;

                    shared = (XClaimEntry *)
                        hash_search_with_hash_value(XClaimHash, &saved_key,
                                                    saved_hash, HASH_FIND, &found);
                    if (found
                        && shared->owner_procno == saved_procno
                        && shared->owner_lxid   == saved_lxid
                        && shared->owner_token  == saved_token)
                    {
                        (void) hash_search_with_hash_value(XClaimHash, &saved_key,
                                                           saved_hash, HASH_REMOVE,
                                                           NULL);
                        pg_atomic_fetch_sub_u64(&XClaimCtl->live_capacity, 1);
                    }
                    else
                    {
                        pg_atomic_fetch_add_u64(&XClaimCtl->cleanup_misses, 1);
                    }
                }
                LWLockRelease(plock_local);

                (void) xcl_local_delete(XClaimLocalSet, saved_key);
                if (XClaimMyLocalCount > 0)
                    XClaimMyLocalCount--;
            }
            xcl_local_reset(XClaimLocalSet);
            XClaimMyLocalCount = 0;
            return;
        }

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

        memcpy(buf, scratch, count * sizeof(*buf));

        pfree(scratch);
        pfree(partition_cursor);
        pfree(partition_counts);
    }

    /*
     * Sweep contiguous partition runs. Each run = exactly ONE LWLock
     * cycle. The cycle invariant holds: total LWLock cycles <=
     * num_partitions (128 default). ABSOLUTE upper bound regardless of
     * claim count.
     *
     * For each entry whose shared row matches our SAVED owner triple
     * (saved_procno + saved_lxid + saved_token -- never read MyProc
     * here; MyProc->lxid was cleared by ProcArrayEndTransaction() before
     * the xact callback fired), HASH_REMOVE under the partition lock.
     * Mismatches increment cleanup_misses (the stale-owner reaper may
     * have already removed the row, or session_reset regenerated our
     * token -- both are valid, non-leak conditions).
     */
    i = 0;
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
         * acquisition time; same mask is applied below to map the
         * partition_id to its lock. partition_locks[] is indexed
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
                /*
                 * Defer the live_capacity decrement out of the
                 * partition-local hot loop. A non-atomic local counter
                 * accumulates removals across ALL partitions; a SINGLE
                 * pg_atomic_fetch_sub_u64 fires after the partition sweep
                 * completes. For a 50000-entry batch this collapses
                 * 50000 atomic ops on the shared live_capacity cache
                 * line into 1.
                 *
                 * Correctness: live_capacity is a free-running counter not
                 * protected by any partition lock; the eventual aggregate
                 * delta is identical whether each row decrements
                 * separately or the whole batch decrements once at the
                 * end. Concurrent readers (xclaim.stats(), watermark
                 * check) see a slightly stale value during the sweep, no
                 * different from the per-row case.
                 */
                total_removed++;
            }
            else
            {
                /*
                 * Defensive cleanup miss: shared row already gone (reaper
                 * raced us, or different owner now -- e.g. previous
                 * session_reset rotated our token and another backend
                 * reaped the entry, then re-acquired). Counter is for
                 * diagnostic only; SHOULD remain 0 under normal load.
                 */
                pg_atomic_fetch_add_u64(&XClaimCtl->cleanup_misses, 1);
            }
        }

        LWLockRelease(plock);
    }

    /*
     * Single batched decrement of live_capacity. Issued OUTSIDE every
     * partition lock: live_capacity is a lock-free counter and the
     * algebra is associative, so the aggregate delta is correct
     * regardless of when individual removals were observed by other
     * backends. Avoids a per-row atomic on the hot cleanup path.
     */
    if (total_removed > 0)
        pg_atomic_fetch_sub_u64(&XClaimCtl->live_capacity, total_removed);

    /*
     * Truncate the simplehash in-place. xcl_local_reset() is a single
     * memset over the bucket array; it preserves the arena so the next
     * acquisition burst reuses already-allocated pages. We deliberately
     * AVOID MemoryContextReset on the hot path because returning blocks
     * to glibc invokes munmap for large allocations, triggering a TLB
     * shootdown across cores. The per-row chunks remain pinned to the
     * backend-lifetime context and are reclaimed only when the backend
     * exits (TopMemoryContext teardown).
     *
     * `buf` was palloc'd in this context, so pfree it explicitly.
     */
    xcl_local_reset(XClaimLocalSet);
    pfree(buf);
    XClaimMyLocalCount = 0;
    /* peak intentionally retained -- session-lifetime stat */
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
     * the slot are unlocked atomic loads; we use atomic write here for
     * publication consistency.
     */
    procno = xclaim_get_current_procno();
    if (procno >= 0 && procno < MaxBackends)
        pg_atomic_write_u64(&XClaimBackendInfos[procno].current_token, 0);
}
