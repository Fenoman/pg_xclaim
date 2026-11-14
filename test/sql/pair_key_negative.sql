-- test/sql/pair_key_negative.sql
-- A pair key with a negative classid or objid packs into the same 64-bit
-- image as its unsigned bit pattern, and debug() decomposes it back into
-- the values the caller passed.

\set VERBOSITY terse

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

BEGIN;
SELECT xclaim.try(-1, 0) AS minus_one_zero,
       xclaim.try(-2147483648, -1) AS int_min_minus_one,
       xclaim.try(2147483647, -2147483648) AS int_max_int_min;
SELECT xclaim.try_many(-1, ARRAY[1, -1, 2147483647]) AS bulk_minus_one;
-- Reentrant: the same pairs again.
SELECT xclaim.try(-1, 0) AS reentrant_scalar,
       xclaim.try_many(-1, ARRAY[1, -1]) AS reentrant_bulk;
SELECT form, scope, key
FROM xclaim.debug()
WHERE form = 'pair'
ORDER BY scope, key;
SELECT xclaim.count() AS held;
ROLLBACK;
SELECT xclaim.count() AS held_after_rollback;
