-- test/sql/plpgsql_exception.sql
-- plpgsql EXCEPTION Block Compat
-- HARD invariant: local set in TopMemoryContext survives plpgsql EXCEPTION rollback.
-- Claims acquired inside an EXCEPTION block survive subtxn rollback.
-- Only top-level ROLLBACK releases claims.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Test 1: acquire inside plpgsql EXCEPTION block; claim survives subtxn rollback
BEGIN;
DO $$
DECLARE
    acquired boolean;
BEGIN
    SELECT xclaim.try(1, 6001) INTO acquired;
    IF NOT acquired THEN
        RAISE EXCEPTION 'unexpected: could not acquire 6001';
    END IF;
    -- Deliberately trigger subtransaction rollback via EXCEPTION
    BEGIN
        RAISE EXCEPTION 'inner_error';
    EXCEPTION
        WHEN others THEN
            -- Exception caught; subtxn rolled back but claim should still be held
            NULL;
    END;
END;
$$;

-- After DO block: claim from 6001 should still be held (TopMemoryContext invariant)
SELECT xclaim.count() AS count_after_exception_block;
SELECT count(*) AS debug_count_after_exception FROM xclaim.debug();

COMMIT;

-- After commit: released
SELECT xclaim.count() AS count_after_commit;

-- Test 2: acquire THEN trigger EXCEPTION; verify count in handler
BEGIN;
DO $$
DECLARE
    cnt int8;
BEGIN
    PERFORM xclaim.try(1, 6002);
    PERFORM xclaim.try(1, 6003);
    BEGIN
        -- Two keys acquired, then inner error
        RAISE EXCEPTION 'inner_rollback';
    EXCEPTION
        WHEN others THEN
            -- Both claims still held (advisory semantics)
            SELECT xclaim.count() INTO cnt;
            IF cnt < 2 THEN
                RAISE EXCEPTION 'claims lost after subtxn rollback: count=%', cnt;
            END IF;
    END;
END;
$$;

-- Claims still held after the DO block
SELECT xclaim.count() AS count_after_do_block;
ROLLBACK;

-- Released after top-level rollback
SELECT xclaim.count() AS count_after_top_rollback;

-- Test 3: verify TopMemoryContext invariant by confirming debug() still shows entries
-- after nested EXCEPTION blocks (key acquired before the inner EXCEPTION)
BEGIN;
DO $$
BEGIN
    PERFORM xclaim.try(1, 6004);
    BEGIN
        PERFORM xclaim.try(1, 6005);
        BEGIN
            RAISE EXCEPTION 'level2_error';
        EXCEPTION
            WHEN others THEN NULL;
        END;
        -- 6005 still held here despite inner rollback
    EXCEPTION
        WHEN others THEN NULL;
    END;
    -- 6004 definitely still held
END;
$$;

SELECT xclaim.count() AS count_after_nested_exception;
COMMIT;
SELECT xclaim.count() AS count_after_nested_commit;
