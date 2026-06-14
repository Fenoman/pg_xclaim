-- test/sql/enabled_off_contract.sql
-- Kill-switch contract: pg_xclaim.enabled = off.
--
-- When operators flip the kill switch (PGC_SUSET, no restart), the
-- acquisition and observability paths must behave per
-- src/pg_xclaim_acquire.c + src/pg_xclaim_stats.c:
--   * try/try_many return success unconditionally (no shared insert)
--   * count() returns 0 (no claim is "held" in the user-facing sense)
--   * debug() / debug_snapshot() return zero rows
--   * disabled_calls counter increments per call so monitoring sees
--     the switch is active
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

-- 2. count() and debug_snapshot() show no claims (none were actually
--    taken).
SELECT xclaim.count() AS count_while_disabled;
SELECT count(*) AS debug_rows_while_disabled
FROM xclaim.debug_snapshot()
WHERE scope IN (50001, 50002, 50003, 50004, 50005, 50006, 50007, 8);
ROLLBACK;

-- 3. disabled_calls counter advanced. The exact delta is the count
--    of disabled-mode entry-points entered above; pinning it down in
--    the baseline catches changes that silently skip a
--    `disabled_calls` increment on one of the four acquisition surfaces.
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
