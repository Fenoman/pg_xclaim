-- test/sql/sql_surface.sql
-- Full SQL surface attribute + ACL matrix.
--
-- Locks in the function-attribute contract for every xclaim.* function
-- and the ACL grants/revokes from sql/pg_xclaim--1.0.0-rc5.sql.
-- Changes that flip PARALLEL SAFE / RESTRICTED, mutate
-- volatility, or leak an admin-only function to PUBLIC fail this
-- test before it reaches a release branch.
--
-- function_attributes.sql already covers the xclaim.try overload
-- matrix and NULL handling in depth. This file adds the remaining 7
-- functions plus the privilege model.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- 1. Volatility / parallel / strictness for every xclaim function.
SELECT
    proname,
    pronargs,
    provolatile  AS volatile,
    proparallel  AS parallel,
    proisstrict  AS strict
FROM pg_proc
WHERE pronamespace = 'xclaim'::regnamespace
ORDER BY proname, pronargs;

-- 2. Privilege model:
--    PUBLIC                 : try, try_many, count, session_reset
--    pg_monitor             : stats, debug_snapshot
--    REVOKE FROM PUBLIC     : debug (delegable via GRANT EXECUTE)
--
-- has_function_privilege(role, oid, 'EXECUTE') = TRUE iff the role can
-- call the function under default ACL. We do not assume any test role
-- exists -- we probe PUBLIC ("public" role identifier) and pg_monitor
-- (a predefined role since PG 10) directly.
SELECT
    p.proname,
    p.pronargs,
    has_function_privilege('public',     p.oid, 'EXECUTE') AS pub,
    has_function_privilege('pg_monitor', p.oid, 'EXECUTE') AS mon
FROM pg_proc p
WHERE p.pronamespace = 'xclaim'::regnamespace
ORDER BY p.proname, p.pronargs;

-- 3. xclaim.debug() is controlled via SQL ACL (delegable to non-superuser).
CREATE ROLE xclaim_debug_delegate NOSUPERUSER NOLOGIN;
GRANT USAGE ON SCHEMA xclaim TO xclaim_debug_delegate;
GRANT EXECUTE ON FUNCTION xclaim.debug() TO xclaim_debug_delegate;
SET ROLE xclaim_debug_delegate;
SELECT count(*) >= 0 AS debug_delegated_ok FROM xclaim.debug();
RESET ROLE;
REVOKE EXECUTE ON FUNCTION xclaim.debug() FROM xclaim_debug_delegate;
REVOKE USAGE ON SCHEMA xclaim FROM xclaim_debug_delegate;
DROP ROLE xclaim_debug_delegate;
