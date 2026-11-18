-- pg_xclaim 1.0.0-rc4 -> 1.0.0-rc5 update script
--
-- Removes the test-only xclaim.debug_inject_stale(int4, int4) helper from
-- the production extension schema (relocated to test/modules/xclaim_test_hooks)
-- and aligns catalog comments with the 1.0.0-rc5 base install script.

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_xclaim UPDATE TO '1.0.0-rc5'" to load this file. \quit

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_depend d
        JOIN pg_catalog.pg_extension e ON e.oid = d.refobjid
        WHERE d.classid = 'pg_catalog.pg_proc'::regclass
          AND d.objid = pg_catalog.to_regprocedure('xclaim.debug_inject_stale(int4, int4)')
          AND d.refclassid = 'pg_catalog.pg_extension'::regclass
          AND e.extname = 'pg_xclaim'
          AND d.deptype = 'e'
    ) THEN
        ALTER EXTENSION pg_xclaim DROP FUNCTION xclaim.debug_inject_stale(int4, int4);
        DROP FUNCTION xclaim.debug_inject_stale(int4, int4);
    END IF;
END;
$$;

COMMENT ON SCHEMA xclaim IS
    'pg_xclaim - high-cardinality transaction-level claims. See README for use cases and alternatives.';

COMMENT ON FUNCTION xclaim.try(int4, int4) IS
    'High-cardinality transaction-level claim. API compatible with pg_try_advisory_xact_lock(int4, int4) for legacy migration.';

COMMENT ON FUNCTION xclaim.try(int8) IS
    'High-cardinality transaction-level claim. API compatible with pg_try_advisory_xact_lock(bigint) for legacy migration.';

COMMENT ON FUNCTION xclaim.try_many(int4, int4[]) IS
    'Bulk high-cardinality claim acquisition. API mirrors pg_try_advisory_xact_lock(int4, int4) over an array of objids. Pre-sorts by partition: at most num_partitions LWLock cycles when per-partition new keys fit in max_claims + 64, plus extra cycles on warn-mode capacity misses or larger per-partition chunks.';

COMMENT ON FUNCTION xclaim.try_many(int8[]) IS
    'Bulk high-cardinality claim acquisition. API mirrors pg_try_advisory_xact_lock(bigint) over an array of keys. Pre-sorts by partition: at most num_partitions LWLock cycles when per-partition new keys fit in max_claims + 64, plus extra cycles on warn-mode capacity misses or larger per-partition chunks.';

COMMENT ON FUNCTION xclaim.count() IS
    'Number of pg_xclaim claims currently held by this backend in this top-level transaction. PARALLEL RESTRICTED -- per-backend local set is not inherited by workers.';

COMMENT ON FUNCTION xclaim.stats() IS
    'pg_xclaim atomic counter snapshot + capacity gauges. pg_monitor read access.';

COMMENT ON FUNCTION xclaim.debug_snapshot() IS
    'Snapshot of pg_xclaim shared state. Copies the entries under every partition LWLock (SHARED) and builds the result after releasing them. Refuses num_partitions > 192. Use xclaim.stats() for routine monitoring. Granted to pg_monitor.';

COMMENT ON FUNCTION xclaim.session_reset() IS
    'pg_xclaim reactive triage tool. Releases the claims the calling backend still holds outside a transaction, gives an enlarged local set back to the allocator and rotates its owner_token. Refuses inside a transaction block, in a parallel worker, inside the xclaim.try_many acquisition loop and while the running transaction holds claims. Backend-local: only affects the session that invoked it. Not needed in routine operation: the xact callback releases claims at every transaction end, and the backend-exit callback at backend exit. Claims still held outside a transaction (xclaim.count() > 0 in autocommit) mean the xact callback did not release them, which normal operation never does. Do NOT wire into pooler server_reset_query. Granted to PUBLIC like pg_advisory_unlock_all. Do NOT additionally grant to pg_monitor (observational role).';

COMMENT ON FUNCTION xclaim.debug() IS
    'Consistent snapshot of pg_xclaim shared state. Copies the entries under every partition LWLock (SHARED) and builds the result after releasing them. Refuses num_partitions > 192. Restricted by default via REVOKE FROM PUBLIC, delegable via GRANT EXECUTE.';
