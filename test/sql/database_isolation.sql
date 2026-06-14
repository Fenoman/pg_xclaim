-- test/sql/database_isolation.sql
-- Database Isolation
-- XClaimKey includes dbid (MyDatabaseId) so claims are database-scoped.
-- This single-session test verifies:
--   1. The database_oid field in debug_snapshot() matches current db OID
--   2. Claims acquired in this db cannot be observed as cross-db entries
-- Cross-database multi-session conflict testing lives in the concurrency suite.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- Acquire a claim and verify database_oid in debug output matches current db
BEGIN;
SELECT xclaim.try(1, 3001) AS acquired;

-- debug_snapshot() must show database_oid = MyDatabaseId
SELECT
    database_oid = (SELECT oid FROM pg_database WHERE datname = current_database()) AS db_oid_matches
FROM xclaim.debug_snapshot()
WHERE key = 3001;

COMMIT;

-- Another sanity check: after commit, no lingering entries
SELECT count(*) AS entries_after_commit FROM xclaim.debug_snapshot();

-- Verify that acquiring same (scope, key) in SAME db/session reuses reentrancy
BEGIN;
SELECT xclaim.try(1, 3002) AS first;
SELECT xclaim.try(1, 3002) AS reentrant;
-- Only 1 shared entry (reentrancy)
SELECT count(*) AS one_shared_entry FROM xclaim.debug_snapshot() WHERE key = 3002;
COMMIT;
