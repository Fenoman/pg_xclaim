-- pg_xclaim 1.0.0-rc3 -> 1.0.0-rc4 update script
--
-- No SQL object changes other than the five comments below. 1.0.0-rc4
-- changes the shared library, which is replaced separately: install the
-- new build and restart the server, because pg_xclaim is loaded through
-- shared_preload_libraries.
--
-- The comments describe the 1.0.0-rc4 library. CREATE EXTENSION runs this
-- script after the base script too, so a fresh install and an updated one
-- carry the same text.

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_xclaim UPDATE TO '1.0.0-rc4'" to load this file. \quit

COMMENT ON FUNCTION xclaim.try_many(int4, int4[]) IS
    'Bulk high-cardinality claim acquisition. API mirrors pg_try_advisory_xact_lock(int4, int4) over an array of objids. Pre-sorts by partition: at most num_partitions LWLock cycles per call, plus one per capacity miss with pg_xclaim.on_capacity_exhaustion = warn.';

COMMENT ON FUNCTION xclaim.try_many(int8[]) IS
    'Bulk high-cardinality claim acquisition. API mirrors pg_try_advisory_xact_lock(bigint) over an array of keys. Pre-sorts by partition: at most num_partitions LWLock cycles per call, plus one per capacity miss with pg_xclaim.on_capacity_exhaustion = warn.';

COMMENT ON FUNCTION xclaim.debug_snapshot() IS
    'Snapshot of pg_xclaim shared state. Copies the entries under every partition LWLock (SHARED) and builds the result after releasing them. Refuses num_partitions > 192. Use xclaim.stats() for routine monitoring. Granted to pg_monitor.';

COMMENT ON FUNCTION xclaim.session_reset() IS
    'pg_xclaim reactive triage tool. Releases the claims the calling backend still holds outside a transaction, gives an enlarged local set back to the allocator and rotates its owner_token. Refuses inside a transaction block, in a parallel worker, inside an xclaim.try_many call and while the running transaction holds claims. Backend-local: only affects the session that invoked it. Not needed in routine operation: the xact callback releases claims at every transaction end, and the backend-exit callback at backend exit. Claims still held outside a transaction (xclaim.count() > 0 in autocommit) mean the xact callback did not release them, which normal operation never does. Do NOT wire into pooler server_reset_query. Granted to PUBLIC like pg_advisory_unlock_all. Do NOT additionally grant to pg_monitor (observational role).';

COMMENT ON FUNCTION xclaim.debug() IS
    'Consistent snapshot of pg_xclaim shared state. Copies the entries under every partition LWLock (SHARED) and builds the result after releasing them. Refuses num_partitions > 192. Superuser only.';
