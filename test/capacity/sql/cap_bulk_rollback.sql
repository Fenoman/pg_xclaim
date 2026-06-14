-- test/capacity/sql/cap_bulk_rollback.sql
-- Bulk-API capacity-exhaustion rollback consistency test.
--
-- Invariant: when xclaim.try_many hits capacity exhaustion mid-batch
-- under on_capacity_exhaustion='error', the catastrophic rollback path
-- HASH_REMOVE's already-inserted shared rows. The deferred live_capacity
-- flush never runs in that scenario, so the rollback path itself does
-- NOT touch live_capacity. We verify that AFTER the failed transaction
-- aborts, xclaim.stats().capacity_used (sourced from live_capacity) is
-- consistent with the actual number of rows visible in xclaim.debug().
--
-- Cluster started with test/capacity.conf: max_claims=64, num_partitions=4.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Confirm capacity matches the test config.
SELECT capacity_max FROM xclaim.stats();
SHOW pg_xclaim.on_capacity_exhaustion;

-- Pre-test: ensure shared dynahash is empty so capacity_used == 0.
SELECT count(*) AS pre_test_debug_rows FROM xclaim.debug();
SELECT capacity_used AS pre_test_capacity_used FROM xclaim.stats();

-- Run a bulk-acquire that exceeds capacity. ERROR mode raises
-- ERRCODE_CONFIGURATION_LIMIT_EXCEEDED mid-batch; the bulk PG_CATCH path
-- rolls back every shared row inserted before the failure.
\set ON_ERROR_STOP off

BEGIN;
SELECT count(*) FILTER (WHERE r) AS try_many_acquired
  FROM unnest(xclaim.try_many(1, ARRAY(SELECT generate_series(1, 100)::int4))) AS r;
-- Expected: ERROR before result returns; transaction is now aborted.
ROLLBACK;

\set ON_ERROR_STOP on

-- Post-test: xclaim.debug() reports the real number of rows in the shared
-- dynahash; xclaim.stats().capacity_used reads from live_capacity. They MUST
-- agree. After the catastrophic rollback both should be 0.
SELECT count(*) AS post_rollback_debug_rows FROM xclaim.debug();
SELECT capacity_used AS post_rollback_capacity_used FROM xclaim.stats();

-- The strict consistency assertion: live_capacity == real row count.
SELECT (capacity_used = (SELECT count(*) FROM xclaim.debug())) AS live_capacity_matches_real_rows
  FROM xclaim.stats();

-- capacity_errors must have incremented (we hit the ERROR mode at least once).
SELECT capacity_errors > 0 AS capacity_error_was_recorded FROM xclaim.stats();

-- Final sanity: a fresh bulk acquire of a small batch still works (capacity
-- was correctly released by the rollback path).
BEGIN;
SELECT count(*) FILTER (WHERE r) AS small_batch_acquired
  FROM unnest(xclaim.try_many(2, ARRAY[1,2,3,4,5]::int4[])) AS r;
ROLLBACK;

-- After rollback of the small batch: dynahash empty again, counters consistent.
SELECT count(*) AS final_debug_rows FROM xclaim.debug();
SELECT capacity_used AS final_capacity_used FROM xclaim.stats();
