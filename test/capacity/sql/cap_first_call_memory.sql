-- test/capacity/sql/cap_first_call_memory.sql
-- The first pg_xclaim call of a backend returns in the memory context it
-- was called in. A fresh backend whose first call is an xclaim.try_many
-- that fails on capacity allocates its rollback tracker (24 bytes a key)
-- in the statement's context, which the ERROR frees. The local set
-- context keeps only the set and its held-key list.
--
-- Cluster started with test/capacity.conf: max_claims=64.

\set VERBOSITY terse

CREATE EXTENSION IF NOT EXISTS pg_xclaim;

-- A new backend: its first pg_xclaim call creates the local set.
\c

SELECT count(*) AS local_set_contexts
FROM pg_backend_memory_contexts WHERE name = 'xclaim local set';

SELECT xclaim.try_many(ARRAY(SELECT g::int8 FROM generate_series(1, 200000) g)) IS NOT NULL;

-- 200,000 keys of tracker would be 4.8 MB.
SELECT total_bytes < 1048576 AS local_set_small
FROM pg_backend_memory_contexts WHERE name = 'xclaim local set';

SELECT xclaim.count() AS after_error;
