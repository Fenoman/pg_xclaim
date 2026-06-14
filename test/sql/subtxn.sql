-- test/sql/subtxn.sql
-- Subtransaction Documented Behavior
-- SAVEPOINT and EXCEPTION blocks do NOT release claims; claims acquired
-- inside a subtransaction survive until the surrounding top-level xact
-- COMMITs or ABORTs.
--
-- DIVERGENCE FROM pg_advisory_xact_lock: this is a documented stronger-
-- than-subxact lifetime. PG core's advisory xact lock IS released by
-- `ROLLBACK TO SAVEPOINT`; pg_xclaim's xact callback fires only at
-- top-level xact end, so subxact rollback leaves claims in place. The
-- HARD invariant `local set lives in TopMemoryContext, not a subtxn
-- context` is what makes this safe -- entries are not freed by subtxn
-- abort and therefore not orphaned in shared memory either. Advisory
-- subxact parity would require SubXactCallback bookkeeping plus subxid
-- ownership in each local/shared entry; pg_xclaim deliberately exposes
-- the simpler "top-level lifetime" contract instead.
--
-- NOTE: plpgsql EXCEPTION compat is tested in plpgsql_exception.sql

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Test 1: SAVEPOINT + ROLLBACK TO SAVEPOINT -- claim STILL held
BEGIN;
SELECT xclaim.try(1, 7001) AS acquired_before_savepoint;
SAVEPOINT sp1;
-- Acquire another key inside savepoint
SELECT xclaim.try(1, 7002) AS acquired_in_savepoint;
SELECT xclaim.count() AS count_with_two_claims;
ROLLBACK TO SAVEPOINT sp1;
-- After subtxn rollback: BOTH claims still held (advisory semantics)
SELECT xclaim.count() AS count_after_subtxn_rollback;
-- Key 7001 still held (acquired before savepoint)
SELECT count(*) AS entries_in_debug FROM xclaim.debug();
COMMIT;

-- Test 2: After top-level ROLLBACK, all claims released
BEGIN;
SELECT xclaim.try(1, 7003) AS outer_claim;
SAVEPOINT sp2;
SELECT xclaim.try(1, 7004) AS inner_claim;
ROLLBACK TO SAVEPOINT sp2;
-- Both still held: 7003 from the outer xact, 7004 NOT released by
-- ROLLBACK TO SAVEPOINT (top-level lifetime; see header note and
-- README "Subtransaction lifetime" section).
SELECT xclaim.count() AS still_held_after_subtxn;
ROLLBACK;

-- All released after top-level rollback
SELECT xclaim.count() AS all_released;
SELECT count(*) AS debug_empty FROM xclaim.debug();

-- Test 3: RELEASE SAVEPOINT -- no effect on claims
BEGIN;
SELECT xclaim.try(1, 7005) AS claim_before_savepoint;
SAVEPOINT sp3;
SELECT xclaim.try(1, 7006) AS claim_in_savepoint;
RELEASE SAVEPOINT sp3;
-- Claims still held after RELEASE SAVEPOINT
SELECT xclaim.count() AS after_release_savepoint;
COMMIT;
SELECT xclaim.count() AS after_final_commit;
