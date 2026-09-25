-- test/sql/topmem_leak.sql
-- Repeated acquire + ROLLBACK cycles do not grow the backend-local memory of
-- pg_xclaim.
--
-- A procedure runs the cycles, so every ROLLBACK ends a real top-level
-- transaction and fires the xact callback cleanup. The local set keeps its
-- bucket array between transactions, so once the first cycle has created
-- the "xclaim local set" memory context, its size stays the same.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

CREATE PROCEDURE xclaim_rollback_cycles(n int)
LANGUAGE plpgsql AS $$
BEGIN
    FOR i IN 1..n LOOP
        PERFORM xclaim.try(1, i * 1000 + 1);
        PERFORM xclaim.try(1, i * 1000 + 2);
        PERFORM xclaim.try(1, i * 1000 + 3);
        PERFORM xclaim.try(1, i * 1000 + 4);
        PERFORM xclaim.try(1, i * 1000 + 5);
        ROLLBACK;
    END LOOP;
END;
$$;

-- One cycle creates the local set and its memory context.
CALL xclaim_rollback_cycles(1);

CREATE TEMP TABLE xclaim_mem AS
SELECT total_bytes AS before_bytes
FROM pg_backend_memory_contexts
WHERE name = 'xclaim local set';

CALL xclaim_rollback_cycles(500);

-- Every cycle released its claims.
SELECT xclaim.count() AS count_after_cycles;
SELECT count(*) AS debug_entries_after_cycles FROM xclaim.debug();

-- The context keeps its size: the cycles do not grow it.
SELECT m.before_bytes = c.total_bytes AS local_bytes_stable
FROM xclaim_mem m, pg_backend_memory_contexts c
WHERE c.name = 'xclaim local set';

-- No shared entry left its owner.
SELECT cleanup_misses
FROM xclaim.stats();

DROP PROCEDURE xclaim_rollback_cycles(int);
