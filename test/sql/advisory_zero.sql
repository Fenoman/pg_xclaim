-- test/sql/advisory_zero.sql
-- No Advisory Locks
-- Verifies that xclaim.try does NOT create pg_locks.locktype='advisory' entries.
-- This is the core value proposition vs pg_try_advisory_xact_lock.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Baseline: no advisory locks held
SELECT count(*) AS advisory_locks_before
FROM pg_locks
WHERE locktype = 'advisory' AND pid = pg_backend_pid();

-- Acquire multiple claims -- none should create advisory lock entries
BEGIN;
SELECT xclaim.try(1, 5001);
SELECT xclaim.try(2, 5002);
SELECT xclaim.try(3, 5003);

-- Advisory lock count MUST be 0
SELECT count(*) AS advisory_locks_while_held
FROM pg_locks
WHERE locktype = 'advisory' AND pid = pg_backend_pid();

-- xclaim.count() confirms 3 claims held
SELECT xclaim.count() AS xclaim_count;

COMMIT;

-- Advisory locks still 0 after commit
SELECT count(*) AS advisory_locks_after_commit
FROM pg_locks
WHERE locktype = 'advisory' AND pid = pg_backend_pid();

-- Cross-check: xclaim.count() = 0 after commit
SELECT xclaim.count() AS xclaim_count_after_commit;
