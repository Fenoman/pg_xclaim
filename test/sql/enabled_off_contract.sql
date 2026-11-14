-- test/sql/enabled_off_contract.sql
-- Kill-switch contract: pg_xclaim.enabled = off.
--
-- When operators flip the kill switch (PGC_SUSET, no restart):
--   * try/try_many return success unconditionally (no shared insert)
--   * disabled_calls counts one per try call and one per try_many array
--     element, so monitoring sees the switch is active. The observability
--     functions (count, stats, debug, debug_snapshot) do not count
--   * count(), debug() and debug_snapshot() report the real state: claims
--     taken before the switch stay held until their transaction ends and
--     stay visible
--   * After enabled = on the normal path resumes immediately
--
-- This regress locks the operator-visible contract so disabled-path
-- changes can't silently flip its semantics.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Capture a clean baseline before flipping the switch.
SELECT disabled_calls AS disabled_before FROM xclaim.stats() \gset

-- ---- Flip the switch ----
SET pg_xclaim.enabled = off;
SHOW pg_xclaim.enabled;

-- 1. try() and try_many() unconditionally return success while disabled.
BEGIN;
SELECT xclaim.try(50001) AS scalar_solo_disabled;
SELECT xclaim.try(50002, 7) AS scalar_pair_disabled;
SELECT xclaim.try_many(ARRAY[50003, 50004, 50005]::int8[])
       AS bulk_solo_disabled;
SELECT xclaim.try_many(8, ARRAY[50006, 50007]::int4[])
       AS bulk_pair_disabled;

-- 2. Nothing was taken: count() is 0, and neither debug function, which
--    scans the shared table whatever the switch says, finds the keys.
SELECT xclaim.count() AS count_while_disabled;
SELECT count(*) AS snapshot_rows_while_disabled
FROM xclaim.debug_snapshot()
WHERE (form = 'solo' AND key IN (50001, 50003, 50004, 50005))
   OR (form = 'pair' AND ((scope = 50002 AND key = 7)
                          OR (scope = 8 AND key IN (50006, 50007))));
SELECT count(*) AS debug_rows_while_disabled
FROM xclaim.debug()
WHERE (form = 'solo' AND key IN (50001, 50003, 50004, 50005))
   OR (form = 'pair' AND ((scope = 50002 AND key = 7)
                          OR (scope = 8 AND key IN (50006, 50007))));
ROLLBACK;

-- 3. disabled_calls advanced by exactly the acquisitions above: 1 + 1 for
--    the two try calls, 3 + 2 for the try_many elements. The count(),
--    debug_snapshot(), debug() and stats() calls add nothing.
SELECT disabled_calls - :disabled_before AS disabled_delta
FROM xclaim.stats();

-- ---- Flip the switch back ----
SET pg_xclaim.enabled = on;
SHOW pg_xclaim.enabled;

-- 4. Normal path resumes: a fresh acquisition makes a real shared row
--    visible to debug() inside the same xact.
BEGIN;
SELECT xclaim.try(50010) AS reenabled_try;
SELECT xclaim.count() AS count_after_reenable;
SELECT count(*) AS visible_in_debug
FROM xclaim.debug() WHERE form = 'solo' AND key = 50010;
ROLLBACK;

-- 5. Claims taken before the switch stay held, and count(), debug() and
--    debug_snapshot() keep reporting them until the transaction ends.
BEGIN;
SELECT xclaim.try(50020) AS taken_before_switch;
SELECT xclaim.try_many(ARRAY[50021, 50022]::int8[]) AS bulk_taken_before_switch;
SET LOCAL pg_xclaim.enabled = off;
SELECT xclaim.count() AS count_after_switch;
SELECT count(*) AS debug_rows_after_switch
FROM xclaim.debug() WHERE form = 'solo' AND key IN (50020, 50021, 50022);
SELECT count(*) AS snapshot_rows_after_switch
FROM xclaim.debug_snapshot() WHERE form = 'solo' AND key IN (50020, 50021, 50022);
ROLLBACK;
SELECT xclaim.count() AS count_after_rollback;
SELECT count(*) AS debug_rows_after_rollback
FROM xclaim.debug() WHERE form = 'solo' AND key IN (50020, 50021, 50022);
