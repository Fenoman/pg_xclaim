-- test/sql/debug_inject_stale_hardening.sql
-- Hardening contract for the test-only backdoor xclaim.debug_inject_stale.
--
-- This helper exists ONLY to seed reaper test cases. It ships in the
-- public install script (REVOKE FROM PUBLIC, superuser-gated), so a
-- regression in its guard logic could let it become a vector for
-- corrupting live claims. The asserts below pin down the contract
-- documented in src/pg_xclaim_stats.c.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- 1. NULL args raise ERRCODE_NULL_VALUE_NOT_ALLOWED.
--    The function declares CALLED ON NULL INPUT so it must body-check.
\set ON_ERROR_STOP off
BEGIN;
SELECT xclaim.debug_inject_stale(NULL::int4, 100);
ROLLBACK;
BEGIN;
SELECT xclaim.debug_inject_stale(42, NULL::int4);
ROLLBACK;
\set ON_ERROR_STOP on

-- 2. Injection into a fresh key succeeds and is visible in debug().
BEGIN;
SELECT xclaim.debug_inject_stale(101, 7) IS NULL AS injected;
SELECT count(*) > 0 AS visible_in_debug
FROM xclaim.debug() WHERE scope = 101 AND key = 7;
ROLLBACK;
-- The synthetic entry persists past ROLLBACK because it lives in the
-- shared dynahash, not the per-backend local set. Clean it up in this
-- same test so the suite's shared cluster does NOT leak `capacity_used`
-- bookkeeping into any subsequent test that asserts `capacity_used=0`
-- on entry. The lazy stale-owner reaper does this for free on the
-- next conflicting acquisition: synthetic owner_procno = INT32_MAX
-- fails the procno bounds check inside xclaim_is_stale_owner, so the
-- conflicting xclaim.try() removes the row, increments `reaped_stale`,
-- and itself succeeds. ROLLBACK then releases the now-real claim via
-- the xact callback.
SELECT reaped_stale AS reaped_before FROM xclaim.stats() \gset
BEGIN;
SELECT xclaim.try(101, 7) AS conflict_triggers_reaper;
ROLLBACK;
SELECT
    reaped_stale - :reaped_before AS reaped_delta,
    capacity_used                 AS capacity_after_reap
FROM xclaim.stats();
SELECT count(*) AS lingering_synthetic_rows
FROM xclaim.debug() WHERE scope = 101 AND key = 7;

-- 3. Injection over a live entry is REFUSED.
--    Acquire (102, 7) for real, then attempt to inject over it. The
--    helper must raise ERRCODE_OBJECT_IN_USE; the owner triple must
--    survive intact; a concurrent try() in this same backend must
--    still see the row as held (reentrant hit).
--
--    A SAVEPOINT isolates the expected ERROR from the surrounding
--    assertion block -- without it the failed inject would leave the
--    outer xact in 'aborted' state and the later SELECTs would all
--    short-circuit with "current transaction is aborted".
BEGIN;
SELECT xclaim.try(102, 7) AS acquired_real;

SAVEPOINT inject_attempt;
\set ON_ERROR_STOP off
SELECT xclaim.debug_inject_stale(102, 7);
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT inject_attempt;

-- The owner triple must NOT be the injection sentinel
-- (sentinel: owner_procno = INT32_MAX, owner_token = 0). It is still
-- ours. We assert "not sentinel" rather than the absolute procno
-- because backend's actual procno depends on the cluster's slot
-- assignment, which is unstable across pg_regress runs.
SELECT
    owner_procno <> 2147483647 AS owner_procno_not_sentinel,
    owner_token  <> 0          AS owner_token_not_sentinel
FROM xclaim.debug() WHERE scope = 102 AND key = 7;

-- Reentrant probe still works.
SELECT xclaim.try(102, 7) AS reentrant_hit;
ROLLBACK;

-- 4. Runtime non-superuser gate (C-body `superuser()` check).
--    The ACL grants are verified by sql_surface.sql (table view of
--    has_function_privilege). Here we also exercise the defense-in-depth
--    C-level guard: a role granted EXECUTE at the SQL layer must STILL
--    be refused with `requires superuser` because the function body
--    checks superuser() before doing any work. Granting EXECUTE
--    simulates an operator who explicitly tried to expose the
--    helper to a non-superuser; the C-side guard is the safety net.
CREATE ROLE xclaim_hardening_nosuper NOSUPERUSER NOLOGIN;
GRANT EXECUTE ON FUNCTION xclaim.debug_inject_stale(int4, int4)
    TO xclaim_hardening_nosuper;
SET ROLE xclaim_hardening_nosuper;
\set ON_ERROR_STOP off
SELECT xclaim.debug_inject_stale(999, 1);
\set ON_ERROR_STOP on
RESET ROLE;
REVOKE EXECUTE ON FUNCTION xclaim.debug_inject_stale(int4, int4)
    FROM xclaim_hardening_nosuper;
DROP ROLE xclaim_hardening_nosuper;
