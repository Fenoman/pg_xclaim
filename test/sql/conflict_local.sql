-- test/sql/conflict_local.sql
-- Local reentrancy simulation.
-- Single-backend: same key twice in SAME transaction = reentrancy (both true).
-- Cross-session conflict tests live in the concurrency shell suite.
-- This file covers only what a single pg_regress session can test:
--   * Reentrancy: true, true (not false)
--   * count() shows 1 entry (not 2) after reentrant acquire

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Reentrancy: same backend, same transaction, same key => both return true
BEGIN;
SELECT xclaim.try(10, 1000) AS first;
SELECT xclaim.try(10, 1000) AS reentrant;
-- count shows 1 (reentrancy does not double-count)
SELECT xclaim.count() AS claim_count;
COMMIT;

-- After commit: count is 0
SELECT xclaim.count() AS post_commit_count;

-- Two different keys: both true, count = 2
BEGIN;
SELECT xclaim.try(10, 2000) AS key_2000;
SELECT xclaim.try(10, 2001) AS key_2001;
SELECT xclaim.count() AS two_distinct_claims;
COMMIT;
