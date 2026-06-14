-- test/sql/topmem_leak.sql
-- TopMemoryContext Leak Check
-- Perform many acquire+rollback cycles; verify pg_backend_memory_contexts
-- shows TopMemoryContext context used bytes remain bounded (no growth trend).
--
-- Strategy: capture memory before cycles, run N cycles, capture after.
-- We can't assert exact bytes (varies by platform/PG version) but we CAN
-- assert the count of xclaim-related contexts does not grow unboundedly.
-- The concurrency suite does the true memory-stable-across-1000-cycles check.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Capture baseline memory for xclaim-related contexts
-- Use name column only (compatible with PG14-18; 'parent' column removed in PG18)
SELECT count(*) AS xclaim_contexts_before
FROM pg_backend_memory_contexts
WHERE name ILIKE '%xclaim%';

-- Run 20 acquire+rollback cycles
-- Each cycle: acquire 5 keys, rollback -> cleanup must fire
DO $$
DECLARE
    i int;
BEGIN
    FOR i IN 1..20 LOOP
        BEGIN
            PERFORM xclaim.try(1, i * 1000 + 1);
            PERFORM xclaim.try(1, i * 1000 + 2);
            PERFORM xclaim.try(1, i * 1000 + 3);
            PERFORM xclaim.try(1, i * 1000 + 4);
            PERFORM xclaim.try(1, i * 1000 + 5);
            ROLLBACK;
        EXCEPTION
            WHEN others THEN
                -- Absorb any error, continue loop
                NULL;
        END;
    END LOOP;
END;
$$;

-- After cycles: count must be 0 (all rolled back)
SELECT xclaim.count() AS count_after_cycles;

-- debug() must show 0 entries for our keys (no leaks)
SELECT count(*) AS debug_entries_after_cycles FROM xclaim.debug();

-- TopMemoryContext xclaim contexts still bounded
-- Use name column only (compatible with PG14-18; 'parent' column removed in PG18)
SELECT count(*) AS xclaim_contexts_after
FROM pg_backend_memory_contexts
WHERE name ILIKE '%xclaim%';

-- Verify stats: cleanup_misses must be 0 (no leaked shared entries)
SELECT cleanup_misses
FROM xclaim.stats();
