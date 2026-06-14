-- test/sql_capacity/cap_warn.sql
-- Capacity Exhaustion Mode: warn
-- Cluster started with test/capacity.conf: max_claims=64
-- Set on_capacity_exhaustion=warn; 65th+ acquisition returns false + WARNING log
-- xclaim.stats().capacity_warnings > 0

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Set warn mode for this session
SET pg_xclaim.on_capacity_exhaustion = 'warn';
SHOW pg_xclaim.on_capacity_exhaustion;

-- Acquire keys; after capacity fills, further tries return false (not error)
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

ROLLBACK;

-- After rollback: count = 0
SELECT xclaim.count() AS after_rollback;
