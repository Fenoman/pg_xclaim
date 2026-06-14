-- test/sql/basic.sql
-- Basic SQL Tests
-- Tests: extension loads, try returns true, reentrancy, different key/scope,
--        count(), debug()/debug_snapshot(), NULL handling.
--
-- pg_regress runs this against a preloaded cluster (test/regress.conf).
-- All timing-based assertions are exercised in the concurrency suite.

\set VERBOSITY terse
\set ON_ERROR_STOP on

-- Extension loads when preloaded
CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- try(scope, key) returns true
BEGIN;
SELECT xclaim.try(1, 100);
COMMIT;

-- Reentrant same key in same transaction returns true (no new entry)
BEGIN;
SELECT xclaim.try(1, 200) AS first_acquire;
SELECT xclaim.try(1, 200) AS reentrant;
COMMIT;

-- Different key in same transaction returns true
BEGIN;
SELECT xclaim.try(1, 300) AS key_300;
SELECT xclaim.try(1, 301) AS key_301;
COMMIT;

-- Different scope (classid) in same transaction returns true
BEGIN;
SELECT xclaim.try(1, 400) AS scope_1;
SELECT xclaim.try(2, 400) AS scope_2;
COMMIT;

-- count() reflects local claims
BEGIN;
SELECT xclaim.count() AS before_acquire;
SELECT xclaim.try(1, 500);
SELECT xclaim.try(1, 501);
SELECT xclaim.try(1, 502);
SELECT xclaim.count() AS after_three_acquires;
COMMIT;
SELECT xclaim.count() AS after_commit;

-- debug() and debug_snapshot() see held locks
BEGIN;
SELECT xclaim.try(1, 600);
SELECT xclaim.try(1, 601);
-- Use COUNT so output is deterministic (no ordering assumptions)
SELECT count(*) AS debug_count FROM xclaim.debug();
SELECT count(*) AS snapshot_count FROM xclaim.debug_snapshot();
COMMIT;

-- NULL handling: CALLED ON NULL INPUT parity with pg_try_advisory_xact_lock.
-- All NULL inputs should raise ERROR (not return NULL silently).
\set ON_ERROR_STOP off

BEGIN;
SELECT xclaim.try(NULL::int8);
ROLLBACK;

BEGIN;
SELECT xclaim.try(NULL::int4, 100);
ROLLBACK;

BEGIN;
SELECT xclaim.try(99, NULL::int4);
ROLLBACK;

\set ON_ERROR_STOP on
