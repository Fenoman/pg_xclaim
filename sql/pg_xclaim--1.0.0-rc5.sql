-- pg_xclaim 1.0.0-rc5 install script
--
-- Declares the xclaim schema and all SQL-callable surfaces:
-- xclaim.try / try_many / count / debug / debug_snapshot / stats /
-- session_reset.
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
--     its shared-LWLock copy across all partitions.
--   * Schema ownership stays with the extension (relocatable=false in
--     pg_xclaim.control).

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_xclaim" to load this file. \quit

COMMENT ON SCHEMA xclaim IS
    'pg_xclaim - high-cardinality transaction-level claims. See README for use cases and alternatives.';

-- Lock down the schema. Individual functions add explicit GRANTs below
-- (xclaim.stats / xclaim.debug_snapshot are granted to pg_monitor).
REVOKE ALL ON SCHEMA xclaim FROM PUBLIC;
GRANT USAGE ON SCHEMA xclaim TO PUBLIC;

-- ----------------------------------------------------------------------
-- xclaim.try overloads (API compatible with pg_try_advisory_xact_lock for
-- ergonomic legacy migration, while semantics differ on subtransactions
-- and NULL handling -- see README).
-- ----------------------------------------------------------------------

CREATE FUNCTION xclaim.try(classid int4, objid int4) RETURNS boolean
    LANGUAGE c
    VOLATILE
    PARALLEL RESTRICTED
    CALLED ON NULL INPUT
    AS '$libdir/pg_xclaim', 'xclaim_try_pair';

COMMENT ON FUNCTION xclaim.try(int4, int4) IS
    'High-cardinality transaction-level claim. API compatible with pg_try_advisory_xact_lock(int4, int4) for legacy migration.';

CREATE FUNCTION xclaim.try(key int8) RETURNS boolean
    LANGUAGE c
    VOLATILE
    PARALLEL RESTRICTED
    CALLED ON NULL INPUT
    AS '$libdir/pg_xclaim', 'xclaim_try_solo';

COMMENT ON FUNCTION xclaim.try(int8) IS
    'High-cardinality transaction-level claim. API compatible with pg_try_advisory_xact_lock(bigint) for legacy migration.';

GRANT EXECUTE ON FUNCTION xclaim.try(int4, int4) TO PUBLIC;
GRANT EXECUTE ON FUNCTION xclaim.try(int8)       TO PUBLIC;

-- ----------------------------------------------------------------------
-- xclaim.session_reset() -- reactive triage tool.
-- ----------------------------------------------------------------------

CREATE FUNCTION xclaim.session_reset() RETURNS void
    LANGUAGE c
    VOLATILE
    PARALLEL RESTRICTED
    CALLED ON NULL INPUT
    AS '$libdir/pg_xclaim', 'xclaim_session_reset';

COMMENT ON FUNCTION xclaim.session_reset() IS
    'pg_xclaim reactive triage tool. Releases the claims the calling backend still holds outside a transaction, gives an enlarged local set back to the allocator and rotates its owner_token. Refuses inside a transaction block, in a parallel worker, inside the xclaim.try_many acquisition loop and while the running transaction holds claims. Backend-local: only affects the session that invoked it. Not needed in routine operation: the xact callback releases claims at every transaction end, and the backend-exit callback at backend exit. Claims still held outside a transaction (xclaim.count() > 0 in autocommit) mean the xact callback did not release them, which normal operation never does. Do NOT wire into pooler server_reset_query. Granted to PUBLIC like pg_advisory_unlock_all. Do NOT additionally grant to pg_monitor (observational role).';

GRANT EXECUTE ON FUNCTION xclaim.session_reset() TO PUBLIC;

-- ----------------------------------------------------------------------
-- Bulk API + observability surface.
-- ----------------------------------------------------------------------

CREATE FUNCTION xclaim.try_many(classid int4, objids int4[]) RETURNS boolean[]
    LANGUAGE c
    VOLATILE
    PARALLEL RESTRICTED
    CALLED ON NULL INPUT
    AS '$libdir/pg_xclaim', 'xclaim_try_many_pair';

COMMENT ON FUNCTION xclaim.try_many(int4, int4[]) IS
    'Bulk high-cardinality claim acquisition. API mirrors pg_try_advisory_xact_lock(int4, int4) over an array of objids. Pre-sorts by partition: at most num_partitions LWLock cycles when per-partition new keys fit in max_claims + 64, plus extra cycles on warn-mode capacity misses or larger per-partition chunks.';

CREATE FUNCTION xclaim.try_many(keys int8[]) RETURNS boolean[]
    LANGUAGE c
    VOLATILE
    PARALLEL RESTRICTED
    CALLED ON NULL INPUT
    AS '$libdir/pg_xclaim', 'xclaim_try_many_solo';

COMMENT ON FUNCTION xclaim.try_many(int8[]) IS
    'Bulk high-cardinality claim acquisition. API mirrors pg_try_advisory_xact_lock(bigint) over an array of keys. Pre-sorts by partition: at most num_partitions LWLock cycles when per-partition new keys fit in max_claims + 64, plus extra cycles on warn-mode capacity misses or larger per-partition chunks.';

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
-- xclaim.debug_snapshot() and xclaim.debug() -- all-partition snapshots.
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
    'Snapshot of pg_xclaim shared state. Copies the entries under every partition LWLock (SHARED) and builds the result after releasing them. Refuses num_partitions > 192. Use xclaim.stats() for routine monitoring. Granted to pg_monitor.';

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
    'Consistent snapshot of pg_xclaim shared state. Copies the entries under every partition LWLock (SHARED) and builds the result after releasing them. Refuses num_partitions > 192. Restricted by default via REVOKE FROM PUBLIC, delegable via GRANT EXECUTE.';

REVOKE ALL ON FUNCTION xclaim.debug() FROM PUBLIC;
