-- test/capacity/sql/cap_warn.sql
-- Capacity Exhaustion Mode: warn
-- Cluster started with test/capacity.conf: max_claims=64
-- With on_capacity_exhaustion=warn, the 65th+ acquisition returns false + WARNING log
-- xclaim.stats().capacity_warnings > 0

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Set warn mode for this session
SET pg_xclaim.on_capacity_exhaustion = 'warn';
SHOW pg_xclaim.on_capacity_exhaustion;

-- Acquire keys. After capacity fills, further tries return false (not error)
-- We count how many returned true vs false
BEGIN;
WITH results AS (
    SELECT
        g.key,
        xclaim.try(1, g.key::int4) AS acquired
    FROM generate_series(1, 100) AS g(key)
)
SELECT
    count(*) FILTER (WHERE acquired) AS acquired_count,
    count(*) FILTER (WHERE NOT acquired) AS rejected_count,
    count(*) FILTER (WHERE NOT acquired) > 0 AS some_rejected
FROM results;

-- stats.capacity_warnings must be > 0 (warnings were issued)
SELECT capacity_warnings > 0 AS has_warnings FROM xclaim.stats();

-- A key rejected for capacity stays rejected in the same transaction: the
-- failed try left no entry in the local set, so the second try goes to
-- shared memory again, and the local count still equals the shared one.
SELECT xclaim.try(1, 100) AS second_try;
SELECT xclaim.count() AS local_count, capacity_used AS shared_count
FROM xclaim.stats();

ROLLBACK;

-- After rollback: count = 0, and every local entry had its shared row
SELECT xclaim.count() AS after_rollback;
SELECT cleanup_misses FROM xclaim.stats();
