-- pg_xclaim 1.0.0-rc1 install script
--
-- Declares the xclaim schema and all SQL-callable surfaces:
-- xclaim.try / try_many / count / debug / debug_snapshot / stats /
-- session_reset / debug_inject_stale.
--
-- HARD INVARIANTS:
--   * All SQL objects live in the dedicated `xclaim` schema (NEVER public,
--     NEVER pg_catalog).
--   * Acquisition entry points (xclaim.try, xclaim.try_many,
--     xclaim.session_reset) MUST be EXACTLY:
--         VOLATILE PARALLEL RESTRICTED CALLED ON NULL INPUT.
--   * Observability entry points (xclaim.count, xclaim.stats,
--     xclaim.debug_snapshot) use STABLE PARALLEL RESTRICTED -- their
--     C bodies bump per-backend atomic counters as a side effect and
--     must run only on the leader. The all-partition consistent
--     xclaim.debug is STABLE PARALLEL UNSAFE for the same reason plus
--     its long shared-LWLock hold. The test-only
--     xclaim.debug_inject_stale uses VOLATILE PARALLEL UNSAFE
--     (superuser-only).
--   * Schema ownership stays with the extension (relocatable=false in
--     pg_xclaim.control).

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_xclaim" to load this file. \quit

-- The `xclaim` namespace is auto-created by the extension framework because
-- pg_xclaim.control declares `schema = xclaim`. Issuing CREATE SCHEMA here
-- in addition would conflict ("schema already exists"). We therefore only
-- annotate / re-grant the namespace.

COMMENT ON SCHEMA xclaim IS
    'pg_xclaim - experimental high-cardinality transaction-level claims; see README for use cases and alternatives.';

-- Lock down the schema; individual functions add explicit GRANTs below
-- (xclaim.stats / xclaim.debug_snapshot are granted to pg_monitor).
REVOKE ALL ON SCHEMA xclaim FROM PUBLIC;
GRANT USAGE ON SCHEMA xclaim TO PUBLIC;

-- ----------------------------------------------------------------------
-- xclaim.try overloads (API compatible with pg_try_advisory_xact_lock for
-- ergonomic legacy migration; semantics are not interchangeable -- see README).
--
-- Function attributes:
--     LANGUAGE c
--     VOLATILE                    -> provolatile = 'v'
--     PARALLEL RESTRICTED         -> proparallel = 'r'
--     CALLED ON NULL INPUT        -> proisstrict = 'f' (NOT STRICT)
--
-- Comparison vs pg_try_advisory_xact_lock (verified on PG 17):
--     PG core    : v / r / t  (VOLATILE / RESTRICTED / STRICT)
--     xclaim.try : v / r / f  (VOLATILE / RESTRICTED / CALLED ON NULL)
-- volatility + parallel mode match; strictness DIFFERS deliberately:
-- PG core silently maps NULL args to NULL result, while xclaim.try's
-- C body raises ERROR with ERRCODE_NULL_VALUE_NOT_ALLOWED so programming
-- bugs surface loudly instead of slipping through as no-op nulls.
--
-- Two distinct C entry points (no INT32_MIN sentinel). The XClaimForm
-- enum (SOLO=1, PAIR=2) is the out-of-band discriminator; SQL surface
-- cannot influence it.
-- ----------------------------------------------------------------------

CREATE FUNCTION xclaim.try(classid int4, objid int4) RETURNS boolean
    LANGUAGE c
    VOLATILE
    PARALLEL RESTRICTED
    CALLED ON NULL INPUT
    AS '$libdir/pg_xclaim', 'xclaim_try_pair';

COMMENT ON FUNCTION xclaim.try(int4, int4) IS
    'High-cardinality transaction-level claim; API compatible with pg_try_advisory_xact_lock(int4, int4) for legacy migration.';

CREATE FUNCTION xclaim.try(key int8) RETURNS boolean
    LANGUAGE c
    VOLATILE
    PARALLEL RESTRICTED
    CALLED ON NULL INPUT
    AS '$libdir/pg_xclaim', 'xclaim_try_solo';

COMMENT ON FUNCTION xclaim.try(int8) IS
    'High-cardinality transaction-level claim; API compatible with pg_try_advisory_xact_lock(bigint) for legacy migration.';

-- Public can EXECUTE both overloads (matches advisory_lock default).
GRANT EXECUTE ON FUNCTION xclaim.try(int4, int4) TO PUBLIC;
GRANT EXECUTE ON FUNCTION xclaim.try(int8)       TO PUBLIC;

-- ----------------------------------------------------------------------
-- xclaim.session_reset() -- OPTIONAL reactive triage tool.
--
-- NOT REQUIRED for normal operation. Claims are released automatically
-- by the xact callback on every COMMIT/ABORT, and that callback fires
-- regardless of how the transaction ends (commit, rollback, client
-- disconnect, idle-in-tx timeout, FATAL backend exit). Tx-mode poolers
-- (pg_doorman, odyssey, PgBouncer) all issue ROLLBACK before reusing a
-- backend on unhealthy disconnect, which triggers the same cleanup path.
--
-- DO NOT wire into pooler server_reset_query / server_reset_query_always.
-- That would add an RTT per backend handoff (potentially thousands per
-- second on hot clusters) just to defend against a hypothetical bug
-- with no observable symptom in production.
--
-- Use this function only when xclaim.stats().cleanup_misses > 0 in
-- production -- that is the signal that some xact callback path was
-- bypassed and reactive cleanup may be warranted.
--
-- Behaviour:
--   1. Force-clear any leftover local-set entries (idempotent no-op
--      when empty, the common case).
--   2. Force-release any shared dynahash rows owned by this backend
--      via the group-by-partition cleanup path (at most num_partitions
--      LWLock cycles -- 128 at the default -- for the 4M-claim worst
--      case; O(max_claims) full-scan explicitly REJECTED).
--   3. Rotate the per-backend owner_token so any survivor row becomes
--      reapable by the stale-owner reaper on the next conflict.
--   4. Increment xclaim.stats().session_resets.
--
-- Function attributes:
--   LANGUAGE c
--   VOLATILE                  -> mutates per-backend + shared state
--   PARALLEL RESTRICTED       -> leader-only (defense-in-depth runtime
--                                guard via IsParallelWorker check)
--   CALLED ON NULL INPUT      -> zero arguments; attribute kept for
--                                consistency with xclaim.try.
-- ----------------------------------------------------------------------

CREATE FUNCTION xclaim.session_reset() RETURNS void
    LANGUAGE c
    VOLATILE
    PARALLEL RESTRICTED
    CALLED ON NULL INPUT
    AS '$libdir/pg_xclaim', 'xclaim_session_reset';

COMMENT ON FUNCTION xclaim.session_reset() IS
    'pg_xclaim optional reactive triage tool. Force-clears the calling backend''s local claims and rotates its owner_token. Backend-local: only affects the session that invoked it. NOT required for routine operation (xact callback handles cleanup automatically). Use only when xclaim.stats().cleanup_misses > 0 in production. Do NOT wire into pooler server_reset_query. Granted to PUBLIC like pg_advisory_unlock_all; do NOT additionally grant to pg_monitor (observational role).';

-- Privilege model. session_reset is the same shape as the rest of the
-- mutating xclaim API (xclaim.try, xclaim.try_many): it operates only
-- on state owned by the calling backend. It cannot reach into another
-- backend, cannot leak data, and cannot escalate privileges. The
-- security profile matches pg_advisory_unlock_all() in PG core, which
-- is GRANTed to PUBLIC by default. We follow the same default.
--
-- One observation, not a security boundary: pg_monitor is an
-- observational role; granting EXECUTE on a state-mutating function
-- to it would conflate observation with control. PUBLIC has no such
-- semantic -- every regular user already calls mutating xclaim.try*.
-- So: PUBLIC EXECUTE is the default, and pg_monitor should not get
-- an additional explicit GRANT.
GRANT EXECUTE ON FUNCTION xclaim.session_reset() TO PUBLIC;

-- ----------------------------------------------------------------------
-- Bulk API + observability surface.
--
-- Function attributes:
--   xclaim.try_many(...)      -- VOLATILE PARALLEL RESTRICTED CALLED ON NULL INPUT
--   xclaim.count()            -- STABLE PARALLEL RESTRICTED
--   xclaim.stats()            -- STABLE PARALLEL RESTRICTED
--   xclaim.debug_snapshot()   -- STABLE PARALLEL RESTRICTED  (all-partition shared LWLock scan)
--   xclaim.debug()            -- STABLE PARALLEL UNSAFE (all-partition consistent)
--   xclaim.debug_inject_stale -- VOLATILE PARALLEL UNSAFE (test helper)
--
-- Privilege model:
--   xclaim.try_many        -> PUBLIC (mirrors xclaim.try)
--   xclaim.count           -> PUBLIC
--   xclaim.stats           -> pg_monitor (REVOKE PUBLIC; GRANT pg_monitor)
--   xclaim.debug_snapshot  -> pg_monitor (REVOKE PUBLIC; GRANT pg_monitor)
--   xclaim.debug           -> superuser-only (REVOKE PUBLIC; NO GRANT)
--   xclaim.debug_inject_stale -> superuser-only (REVOKE PUBLIC; NO GRANT)
-- ----------------------------------------------------------------------

CREATE FUNCTION xclaim.try_many(classid int4, objids int4[]) RETURNS boolean[]
    LANGUAGE c
    VOLATILE
    PARALLEL RESTRICTED
    CALLED ON NULL INPUT
    AS '$libdir/pg_xclaim', 'xclaim_try_many_pair';

COMMENT ON FUNCTION xclaim.try_many(int4, int4[]) IS
    'Bulk high-cardinality claim acquisition; API mirrors pg_try_advisory_xact_lock(int4, int4) over an array of objids. Pre-sorts by partition to bound LWLock cycles to <= num_partitions.';

CREATE FUNCTION xclaim.try_many(keys int8[]) RETURNS boolean[]
    LANGUAGE c
    VOLATILE
    PARALLEL RESTRICTED
    CALLED ON NULL INPUT
    AS '$libdir/pg_xclaim', 'xclaim_try_many_solo';

COMMENT ON FUNCTION xclaim.try_many(int8[]) IS
    'Bulk high-cardinality claim acquisition; API mirrors pg_try_advisory_xact_lock(bigint) over an array of keys. Pre-sorts by partition to bound LWLock cycles to <= num_partitions.';

GRANT EXECUTE ON FUNCTION xclaim.try_many(int4, int4[]) TO PUBLIC;
GRANT EXECUTE ON FUNCTION xclaim.try_many(int8[])       TO PUBLIC;

-- ----------------------------------------------------------------------
-- xclaim.count() -- backend-local count, STABLE PARALLEL RESTRICTED.
-- ----------------------------------------------------------------------

CREATE FUNCTION xclaim.count() RETURNS int8
    LANGUAGE c
    STABLE
    PARALLEL RESTRICTED
    AS '$libdir/pg_xclaim', 'xclaim_count';

-- PARALLEL RESTRICTED. Parallel workers do NOT inherit the leader's
-- per-backend local set; a worker invocation would return 0 even when
-- the leader holds claims, producing a wrong-but-plausible result
-- (silent correctness bug). RESTRICTED forces the planner to keep
-- this call in the leader.
COMMENT ON FUNCTION xclaim.count() IS
    'Number of pg_xclaim claims currently held by this backend in this top-level transaction. PARALLEL RESTRICTED -- per-backend local set is not inherited by workers.';

GRANT EXECUTE ON FUNCTION xclaim.count() TO PUBLIC;

-- ----------------------------------------------------------------------
-- xclaim.stats() -- 14-column composite SRF (single row), PARALLEL RESTRICTED.
-- ----------------------------------------------------------------------

CREATE FUNCTION xclaim.stats()
RETURNS TABLE (
    capacity_max int8,
    capacity_used int8,
    capacity_pct numeric(5,2),
    total_acquires int8,
    reentrant_hits int8,
    conflicts int8,
    capacity_errors int8,
    capacity_warnings int8,
    reaped_stale int8,
    cleanup_misses int8,
    disabled_calls int8,
    peak_per_backend int8,
    debug_scans int8,
    session_resets int8
)
    LANGUAGE c
    STABLE
    PARALLEL RESTRICTED
    AS '$libdir/pg_xclaim', 'xclaim_stats';

COMMENT ON FUNCTION xclaim.stats() IS
    'pg_xclaim atomic counter snapshot + capacity gauges. pg_monitor read access.';

REVOKE ALL ON FUNCTION xclaim.stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION xclaim.stats() TO pg_monitor;

-- ----------------------------------------------------------------------
-- xclaim.debug_snapshot() -- all-partition SHARED LWLock snapshot.
-- xclaim.debug()          -- consistent all-partition snapshot (test only).
--
-- RETURNS TABLE includes a `form text` column ('solo'|'pair') so SOLO/
-- PAIR entries with the same numeric k1 (e.g. xclaim.try(99::int8) vs
-- xclaim.try(0, 99)) are distinguishable in the output.
-- ----------------------------------------------------------------------

CREATE FUNCTION xclaim.debug_snapshot()
RETURNS TABLE (
    database_oid oid,
    form text,
    scope int4,
    key int8,
    owner_pid int4,
    owner_procno int4,
    owner_lxid int8,
    owner_token int8
)
    LANGUAGE c
    STABLE
    PARALLEL RESTRICTED
    AS '$libdir/pg_xclaim', 'xclaim_debug_snapshot';

COMMENT ON FUNCTION xclaim.debug_snapshot() IS
    'All-partition SHARED LWLock snapshot of pg_xclaim shared state; holds every partition lock for the scan duration; refuses num_partitions > 192; use xclaim.stats() for routine monitoring. Granted to pg_monitor.';

REVOKE ALL ON FUNCTION xclaim.debug_snapshot() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION xclaim.debug_snapshot() TO pg_monitor;

CREATE FUNCTION xclaim.debug()
RETURNS TABLE (
    database_oid oid,
    form text,
    scope int4,
    key int8,
    owner_pid int4,
    owner_procno int4,
    owner_lxid int8,
    owner_token int8
)
    LANGUAGE c
    STABLE
    PARALLEL UNSAFE
    AS '$libdir/pg_xclaim', 'xclaim_debug';

COMMENT ON FUNCTION xclaim.debug() IS
    'Consistent all-partition snapshot of pg_xclaim shared state. Holds ALL partition LWLocks SHARED for the entire scan -- superuser only.';

REVOKE ALL ON FUNCTION xclaim.debug() FROM PUBLIC;

-- ----------------------------------------------------------------------
-- xclaim.debug_inject_stale -- test-only superuser helper.
-- Seeds an XClaimEntry with a guaranteed-stale owner triple so the
-- reaper test can observe a successful reap. NOT FOR PRODUCTION.
-- ----------------------------------------------------------------------

CREATE FUNCTION xclaim.debug_inject_stale(scope int4, key int4) RETURNS void
    LANGUAGE c
    VOLATILE
    PARALLEL UNSAFE
    CALLED ON NULL INPUT
    AS '$libdir/pg_xclaim', 'xclaim_debug_inject_stale';

COMMENT ON FUNCTION xclaim.debug_inject_stale(int4, int4) IS
    'TEST-ONLY: inject an XClaimEntry with a guaranteed-stale owner triple. Superuser only. NOT FOR PRODUCTION.';

REVOKE ALL ON FUNCTION xclaim.debug_inject_stale(int4, int4) FROM PUBLIC;
