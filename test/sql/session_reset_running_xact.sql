-- test/sql/session_reset_running_xact.sql
-- xclaim.session_reset() refuses to release claims of the running
-- transaction, also in autocommit, where the statement is an implicit
-- transaction: a SELECT list, a DO block or a function that takes a claim
-- and then calls session_reset(). A released claim would let another
-- backend take the key while this transaction still relies on it.

\set VERBOSITY terse

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- One statement takes a claim and then calls session_reset().
SELECT xclaim.try(60001) AS took, xclaim.session_reset();

-- A DO block in autocommit.
DO $$
BEGIN
    PERFORM xclaim.try(60002);
    PERFORM xclaim.session_reset();
END $$;

-- A caught refusal leaves the claim held for the rest of the transaction.
DO $$
BEGIN
    PERFORM xclaim.try(60003);
    BEGIN
        PERFORM xclaim.session_reset();
    EXCEPTION WHEN active_sql_transaction THEN
        RAISE NOTICE 'refused, claims still held: %', xclaim.count();
    END;
END $$;

-- The statements above ended, and their transactions released the claims.
SELECT xclaim.count() AS held_after_statements;

-- A statement that holds no claim of its own may call it.
SELECT xclaim.session_reset();
