-- test/sql/function_attributes.sql
-- Function Attribute Parity
-- Verifies xclaim.try overloads EXACTLY match pg_try_advisory_xact_lock:
--   VOLATILE PARALLEL RESTRICTED CALLED ON NULL INPUT
-- Also verifies exactly two overloads exist (pronargs=1 int8, pronargs=2 int4+int4)

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Test 0: Exactly two overloads with correct arg types
SELECT pronargs, proargtypes::regtype[]
FROM pg_proc
WHERE proname = 'try' AND pronamespace = 'xclaim'::regnamespace
ORDER BY pronargs;

-- Verify function attributes match pg_try_advisory_xact_lock:
-- provolatile='v' (VOLATILE), proparallel='r' (RESTRICTED), proisstrict='f' (CALLED ON NULL INPUT)
SELECT
    proname,
    pronargs,
    provolatile,
    proparallel,
    proisstrict
FROM pg_proc
WHERE proname = 'try' AND pronamespace = 'xclaim'::regnamespace
ORDER BY pronargs;

-- Test 1: bare int literal => implicit cast int4->int8 => xclaim.try(int8)
BEGIN;
SELECT xclaim.try(99) AS bare_int_literal;
COMMIT;

-- Test 2: explicit ::int (int4) => implicit cast int4->int8
BEGIN;
SELECT xclaim.try(99::int) AS explicit_int4_cast;
COMMIT;

-- Test 3: explicit ::bigint => direct match xclaim.try(int8)
BEGIN;
SELECT xclaim.try(99::bigint) AS explicit_bigint;
COMMIT;

-- Test 4: two int literals => direct match xclaim.try(int4, int4)
BEGIN;
SELECT xclaim.try(99, 100) AS two_int_literals;
COMMIT;

-- Test 5: explicit (int, int) => direct match xclaim.try(int4, int4)
BEGIN;
SELECT xclaim.try(99::int, 100::int) AS explicit_int_int;
COMMIT;

-- Test 6: NULL handling (CALLED ON NULL INPUT -> ERROR, not silent NULL)
\set ON_ERROR_STOP off

BEGIN;
SELECT xclaim.try(NULL::bigint);
ROLLBACK;

BEGIN;
SELECT xclaim.try(NULL::int, 100);
ROLLBACK;

BEGIN;
SELECT xclaim.try(99, NULL::int);
ROLLBACK;

-- Test 6b: xclaim.try_many raises ERROR on NULL inputs, symmetric with
-- the scalar try() overloads. NULL is a programming bug -- silent NULL
-- return would mask it; loud ERROR surfaces it at call site.
BEGIN;
SELECT xclaim.try_many(NULL::int8[]);
ROLLBACK;

BEGIN;
SELECT xclaim.try_many(NULL::int4, ARRAY[1,2,3]::int4[]);
ROLLBACK;

BEGIN;
SELECT xclaim.try_many(1::int4, NULL::int4[]);
ROLLBACK;

-- Test 6c: NULL ELEMENT inside an otherwise-valid array also raises.
-- This is the symmetry that the silent-skip behavior used to break.
-- Without the rejection, README's recommended `bool_and(unnest)` idiom
-- silently passes a partially-NULL result (bool_and ignores NULL by
-- SQL semantics), fail-opening the whole bulk call on a caller bug.
BEGIN;
SELECT xclaim.try_many(ARRAY[1, NULL, 3]::int8[]);
ROLLBACK;

BEGIN;
SELECT xclaim.try_many(99::int4, ARRAY[1, NULL, 3]::int4[]);
ROLLBACK;

-- Test 6d: bool_and(unnest) idiom from README -- given the new contract,
-- a NULL element raises BEFORE the idiom even sees a row. Demonstrates
-- the fail-open path is closed.
BEGIN;
SELECT bool_and(ok)
FROM unnest(xclaim.try_many(ARRAY[10, NULL, 20]::int8[])) AS ok;
ROLLBACK;

\set ON_ERROR_STOP on

-- Test 7: keyspace separation (SOLO vs PAIR with same numeric value)
BEGIN;
SELECT xclaim.try(99::bigint), xclaim.try(0, 99);
ROLLBACK;

-- Final: verify advisory lock baseline for advisory parity doc
SELECT
    proname     AS advisory_name,
    provolatile AS volatile,
    proparallel AS parallel,
    proisstrict AS strict
FROM pg_proc
WHERE proname = 'pg_try_advisory_xact_lock'
  AND pronargs = 2
LIMIT 1;
