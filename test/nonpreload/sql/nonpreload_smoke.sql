-- test/nonpreload/sql/nonpreload_smoke.sql
-- Non-preloaded Call Failure
-- Server started WITHOUT pg_xclaim in shared_preload_libraries.
-- LOAD 'pg_xclaim' succeeds silently (no FATAL).
-- Every SQL entry point in xclaim.* ERRORs with ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;
LOAD 'pg_xclaim';

\set ON_ERROR_STOP off

BEGIN;
SELECT xclaim.try(1::int8);
ROLLBACK;

BEGIN;
SELECT xclaim.try(1, 1);
ROLLBACK;

BEGIN;
SELECT xclaim.try_many(ARRAY[1]::int8[]);
ROLLBACK;

BEGIN;
SELECT xclaim.try_many(1, ARRAY[1]::int4[]);
ROLLBACK;

SELECT xclaim.count();
SELECT * FROM xclaim.stats();
SELECT * FROM xclaim.debug_snapshot();
SELECT * FROM xclaim.debug();
SELECT xclaim.session_reset();

\set ON_ERROR_STOP on

-- Verify exact SQLSTATE 55000 (ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE)
-- across every public entry point, not only message text.
DO $$
DECLARE
    fn_calls text[] := ARRAY[
        'SELECT xclaim.try(1::int8)',
        'SELECT xclaim.try(1, 1)',
        'SELECT xclaim.try_many(ARRAY[1]::int8[])',
        'SELECT xclaim.try_many(1, ARRAY[1]::int4[])',
        'SELECT xclaim.count()',
        'SELECT * FROM xclaim.stats()',
        'SELECT * FROM xclaim.debug_snapshot()',
        'SELECT * FROM xclaim.debug()',
        'SELECT xclaim.session_reset()'
    ];
    stmt text;
    matched int := 0;
BEGIN
    FOREACH stmt IN ARRAY fn_calls LOOP
        BEGIN
            EXECUTE stmt;
            RAISE EXCEPTION 'unexpected success without preload: %', stmt;
        EXCEPTION WHEN object_not_in_prerequisite_state THEN
            IF SQLSTATE <> '55000' THEN
                RAISE EXCEPTION 'expected exact SQLSTATE 55000, got % for %', SQLSTATE, stmt;
            END IF;
            matched := matched + 1;
        END;
    END LOOP;
    IF matched <> 9 THEN
        RAISE EXCEPTION 'expected 9 SQLSTATE 55000 rejections, got %', matched;
    END IF;
END;
$$;
SELECT 'sqlstate_55000_all_9' AS verified;
