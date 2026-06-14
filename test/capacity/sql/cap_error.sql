-- test/sql_capacity/cap_error.sql
-- Capacity Exhaustion -- error mode
-- Requires max_claims=64 (above dynahash 32-freelist floor).
-- Cluster started with test/capacity.conf: max_claims=64, on_capacity_exhaustion=error (default)
--
-- Acquire 100 unique locks; expect ERRCODE_CONFIGURATION_LIMIT_EXCEEDED
-- after some count between 32 and 64.
-- After rollback: xclaim.debug() shows no leaked entries.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Verify max_claims is 64 (capacity cluster config)
SELECT capacity_max FROM xclaim.stats();

-- Default mode: error
SHOW pg_xclaim.on_capacity_exhaustion;

-- Acquire keys until capacity is exhausted
-- We use a DO block with ON_ERROR_STOP off to catch the capacity error
-- and record how many succeeded before the error
\set ON_ERROR_STOP off

DO $$
DECLARE
    i int;
    ok boolean;
BEGIN
    FOR i IN 1..100 LOOP
        SELECT xclaim.try(1, i) INTO ok;
        IF NOT ok THEN
            RAISE EXCEPTION 'try returned false at i=% (unexpected: should error not false)', i;
        END IF;
    END LOOP;
    RAISE NOTICE 'completed 100 iterations without capacity error (unexpected)';
END;
$$;

\set ON_ERROR_STOP on

-- After capacity exhaustion error: transaction is aborted, count = 0
SELECT xclaim.count() AS count_after_capacity_error;

-- No leaked entries in shared memory
SELECT count(*) AS debug_entries_after_capacity_error FROM xclaim.debug();

-- stats.capacity_errors must be > 0
SELECT capacity_errors > 0 AS has_capacity_errors FROM xclaim.stats();

-- Now verify keys are acquirable again in a fresh transaction (capacity freed)
BEGIN;
SELECT xclaim.try(1, 1) AS acquirable_after_reset;
ROLLBACK;
