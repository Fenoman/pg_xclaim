-- test/sql/error_keeps_interrupts.sql
-- An ERROR raised inside a pg_xclaim function leaves the backend able to
-- process interrupts: statement_timeout still cancels the next statement.
-- errfinish() zeroes the interrupt holdoff count before an ERROR jumps to
-- a PG_CATCH, so a handler that releases its own LWLocks has to restore
-- the count first, or the backend stops answering cancel, timeouts and
-- terminate until its next ERROR.
--
-- The debug functions copy the shared table under the partition LWLocks
-- and build a tuplestore for their result after releasing them. With
-- temp_file_limit = 0 and a small work_mem, a large result fails with an
-- ERROR (SQLSTATE 53400) while the tuplestore spills to disk, with no
-- partition LWLock held. Only the SQLSTATE is printed: the message text
-- differs between major versions. The PG_CATCH of xclaim.try_many, which
-- releases a partition LWLock, is checked by Test 3 of
-- test/concurrency/local_grow_oom.sh (Linux).

\set VERBOSITY terse

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

BEGIN;
SELECT count(*) AS taken
FROM unnest(xclaim.try_many(ARRAY(SELECT g::int8 FROM generate_series(1, 20000) g))) t
WHERE t;
SET LOCAL work_mem = '64kB';
SET LOCAL temp_file_limit = 0;
\set VERBOSITY sqlstate
SELECT count(*) FROM xclaim.debug_snapshot();
\set VERBOSITY terse
ROLLBACK;

SET statement_timeout = '200ms';
SELECT pg_sleep(3);
RESET statement_timeout;

-- The same for xclaim.debug().
BEGIN;
SELECT count(*) AS taken
FROM unnest(xclaim.try_many(ARRAY(SELECT g::int8 FROM generate_series(1, 20000) g))) t
WHERE t;
SET LOCAL work_mem = '64kB';
SET LOCAL temp_file_limit = 0;
\set VERBOSITY sqlstate
SELECT count(*) FROM xclaim.debug();
\set VERBOSITY terse
ROLLBACK;

SET statement_timeout = '200ms';
SELECT pg_sleep(3);
RESET statement_timeout;

SELECT xclaim.count() AS held_at_end;
