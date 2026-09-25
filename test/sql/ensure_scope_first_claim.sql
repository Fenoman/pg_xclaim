-- test/sql/ensure_scope_first_claim.sql
-- First claim of a backend made inside a PG_ENSURE_ERROR_CLEANUP scope.
-- btbulkdelete runs the index vacuum under PG_ENSURE_ERROR_CLEANUP, and page
-- deletion searches for the parent page with the opclass comparator. The
-- comparator below takes a claim, so the VACUUM backend makes its first
-- claim inside that scope. The exit-callback registration done on the first
-- claim must leave the scope's before_shmem_exit entry on top of the stack,
-- otherwise the scope fails with "is not the latest entry".

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

CREATE FUNCTION ensure_scope_cmp(a int4, b int4) RETURNS int4
    LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    PERFORM xclaim.try(424242::int8);
    RETURN btint4cmp(a, b);
END
$$;

CREATE OPERATOR CLASS ensure_scope_ops FOR TYPE int4 USING btree AS
    OPERATOR 1 <,
    OPERATOR 2 <=,
    OPERATOR 3 =,
    OPERATOR 4 >=,
    OPERATOR 5 >,
    FUNCTION 1 ensure_scope_cmp(int4, int4);

CREATE TABLE ensure_scope_t (k int4) WITH (autovacuum_enabled = off);
INSERT INTO ensure_scope_t SELECT g FROM generate_series(1, 5000) g;
CREATE INDEX ensure_scope_idx ON ensure_scope_t (k ensure_scope_ops);
-- Empty several whole leaf pages in the middle of the index.
DELETE FROM ensure_scope_t WHERE k BETWEEN 1000 AND 4000;

-- A fresh backend that has not taken a claim yet.
\c
SELECT total_acquires AS acquires_before FROM xclaim.stats() \gset
VACUUM (PARALLEL 0, INDEX_CLEANUP ON) ensure_scope_t;
-- The comparator took a claim inside the vacuum, so page deletion ran.
SELECT total_acquires > :acquires_before AS claimed_inside_vacuum FROM xclaim.stats();

DROP TABLE ensure_scope_t;
DROP OPERATOR FAMILY ensure_scope_ops USING btree;
DROP FUNCTION ensure_scope_cmp(int4, int4);
