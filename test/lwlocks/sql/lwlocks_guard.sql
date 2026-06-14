-- test/lwlocks/sql/lwlocks_guard.sql
-- Guard for the all-partition LWLock budget in xclaim.debug() and
-- xclaim.debug_snapshot().
--
-- Both functions iterate the shared dynahash under SHARED locks on
-- EVERY partition simultaneously. PG core caps a single backend at
-- ~200 concurrent LWLocks (MAX_SIMUL_LWLOCKS); xclaim caps at 192 to
-- leave headroom for catalog access. With num_partitions=256 (this
-- cluster's config) the cap is exceeded and both functions must
-- refuse with ERRCODE_FEATURE_NOT_SUPPORTED + an actionable hint.
--
-- A regression in this guard would either (a) tip PG into its own
-- LWLock-overflow assertion or (b) leak the partial set of acquired
-- partition locks across the ereport unwind. The asserts below
-- exercise both code paths (debug() under EXCLUSIVE, debug_snapshot()
-- under SHARED) and verify that a normal acquisition still works
-- after the failed snapshot calls (i.e., no orphaned partition lock).

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Sanity: confirm the cluster is configured at the over-limit value.
SHOW pg_xclaim.num_partitions;

-- 1. debug_snapshot() refuses cleanly.
\set ON_ERROR_STOP off
SELECT count(*) FROM xclaim.debug_snapshot();
\set ON_ERROR_STOP on

-- 2. debug() refuses cleanly.
\set ON_ERROR_STOP off
SELECT count(*) FROM xclaim.debug();
\set ON_ERROR_STOP on

-- 3. The acquisition path is unaffected -- after both refusals we can
--    still take and release a normal claim. This proves no partition
--    LWLock leaked across the ereport(ERROR) unwind in either helper.
BEGIN;
SELECT xclaim.try(7000) AS acquired_after_guard;
SELECT xclaim.count() AS count_after_guard;
ROLLBACK;

-- 4. xclaim.stats() is unaffected (it does not iterate dynahash, so
--    the 192-cap does not apply).
SELECT capacity_used FROM xclaim.stats();
