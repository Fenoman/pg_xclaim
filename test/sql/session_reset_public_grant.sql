-- test/sql/session_reset_public_grant.sql
-- Verify xclaim.session_reset() ACL and the "no-unlock-inside-xact"
-- contract.
--
-- ACL: session_reset is GRANTed EXECUTE TO PUBLIC, mirroring
-- pg_advisory_unlock_all() in PG core. Restricting to superuser would
-- force operators into pg_terminate_backend / pool rotation for cases
-- where a self-cleanup from the affected session is sufficient.
--
-- Contract: session_reset MUST refuse with ERRCODE_ACTIVE_SQL_TRANSACTION
-- when called inside an explicit `BEGIN ... COMMIT` block. Without that
-- guard, the function would let unprivileged callers manually release
-- their own xact-scoped claims early, breaking the implicit
-- "xact-scoped lock cannot be released early" contract callers rely on
-- (queues, dedupe, idempotency, leader election). Autocommit mode
-- remains the supported path -- it is the case where the previous
-- xact's callback somehow left state behind.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Test 0: pg_proc-level permission state.
-- session_reset must show pg_xclaim_owner-controlled ACL with PUBLIC=X.
SELECT
    proname,
    has_function_privilege('public', oid, 'EXECUTE') AS public_can_execute
FROM pg_proc
WHERE proname = 'session_reset'
  AND pronamespace = 'xclaim'::regnamespace;

-- Test 1: Create a non-superuser role and verify it can call the function
-- without GRANT-ing anything else (the PUBLIC default must be enough).
DROP ROLE IF EXISTS xclaim_unprivileged_test;
CREATE ROLE xclaim_unprivileged_test LOGIN;

SET ROLE xclaim_unprivileged_test;
SELECT current_user AS effective_role;

-- Autocommit call: session_reset() must succeed for an unprivileged
-- role. We do NOT acquire any claims first -- the autocommit path is
-- the diagnostic case, not the bulk-release case.
SELECT xclaim.session_reset() AS reset_in_autocommit;
SELECT xclaim.count() AS held_after_autocommit_reset;

-- Test 2: session_reset MUST refuse inside an explicit transaction
-- block. Acquire two claims, attempt session_reset inside the same
-- BEGIN/COMMIT; the helper must raise; the claims survive.
\set ON_ERROR_STOP off
BEGIN;
SELECT xclaim.try(21::bigint), xclaim.try(22::bigint);
SELECT xclaim.count() AS held_before_inside_xact_attempt;
SELECT xclaim.session_reset() AS reset_inside_xact;
ROLLBACK;
\set ON_ERROR_STOP on

-- Reset role for cleanup
RESET ROLE;
DROP ROLE xclaim_unprivileged_test;
