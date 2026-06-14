-- test/sql/keyspace.sql
-- Keyspace Separation, No Sentinel
-- xclaim.try(99::int8)  => FORM_SOLO, k1=99
-- xclaim.try(0, 99)     => FORM_PAIR, k1=(0<<32 | 99)=99  BUT form field differs
-- Both calls return true in same transaction (different hash keys due to form field)
-- debug() shows TWO entries with same key=99 but different form values

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Test 1: solo and pair with numerically same k1 both succeed (different form)
BEGIN;
SELECT xclaim.try(99::int8) AS solo_99;
SELECT xclaim.try(0, 99)    AS pair_0_99;

-- count() must show 2 (not 1 -- they are distinct keyspace entries)
SELECT xclaim.count() AS two_distinct_entries;

-- debug_snapshot() shows two entries, each with key=99, different form
SELECT form, key
FROM xclaim.debug_snapshot()
WHERE key = 99
ORDER BY form;

COMMIT;

-- Test 2: reentrancy within same form (solo repeated = 1 entry, not 2)
BEGIN;
SELECT xclaim.try(99::int8) AS solo_first;
SELECT xclaim.try(99::int8) AS solo_reentrant;
-- Count is still 1 (reentrant, not doubled)
SELECT xclaim.count() AS reentrant_count;
COMMIT;

-- Test 3: verify no INT32_MIN sentinel in form or key columns
-- XClaimForm INVALID=0, SOLO=1, PAIR=2 -- no negative values
BEGIN;
SELECT xclaim.try(1, 42);
SELECT count(*) AS no_negative_form
FROM xclaim.debug_snapshot()
WHERE form NOT IN ('solo', 'pair');
COMMIT;

-- Test 4: solo and pair with scope=0 and key=99 are distinct across commits too
BEGIN;
SELECT xclaim.try(99::int8);
COMMIT;
BEGIN;
SELECT xclaim.try(0, 99);
COMMIT;
-- Both commits clean, no cross-contamination
SELECT xclaim.count() AS final_zero;
