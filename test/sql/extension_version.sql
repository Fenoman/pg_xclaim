-- test/sql/extension_version.sql
-- Extension version and catalog surface checks for 1.0.0-rc5.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;
SELECT extversion FROM pg_extension WHERE extname = 'pg_xclaim';
SELECT default_version FROM pg_available_extensions WHERE name = 'pg_xclaim';
SELECT version FROM pg_available_extension_versions
 WHERE name = 'pg_xclaim' ORDER BY version;

-- Test-only debug_inject_stale is NOT present in the production schema.
SELECT to_regprocedure('xclaim.debug_inject_stale(int4, int4)') IS NULL
    AS no_debug_inject_stale_in_prod;

-- Catalog comments match the 1.0.0-rc5 contract and carry no prose semicolons.
SELECT obj_description('xclaim.session_reset()'::regprocedure, 'pg_proc')
    AS session_reset_comment \gset
SELECT :'session_reset_comment' LIKE '%xclaim.count() > 0%' AS points_to_count,
       :'session_reset_comment' NOT LIKE '%cleanup_misses > 0%' AS no_cleanup_misses_advice,
       :'session_reset_comment' LIKE '%running transaction holds claims%'
           AND :'session_reset_comment' LIKE '%inside the xclaim.try_many acquisition loop%'
           AS reset_names_its_refusals;

SELECT obj_description('xclaim.try_many(int8[])'::regprocedure, 'pg_proc')
           LIKE '%warn-mode capacity misses%' AS try_many_names_warn_mode,
       obj_description('xclaim.try_many(int4, int4[])'::regprocedure, 'pg_proc')
           LIKE '%warn-mode capacity misses%' AS pair_try_many_names_warn_mode,
       obj_description('xclaim.debug()'::regprocedure, 'pg_proc')
           LIKE '%after releasing them%' AS debug_builds_after_release,
       obj_description('xclaim.debug()'::regprocedure, 'pg_proc')
           LIKE '%delegable via GRANT EXECUTE%' AS debug_names_acl_delegation,
       obj_description('xclaim.debug_snapshot()'::regprocedure, 'pg_proc')
           LIKE '%after releasing them%' AS snapshot_builds_after_release;

SELECT count(*) AS comments_with_semicolons
FROM pg_proc p
WHERE p.pronamespace = 'xclaim'::regnamespace
  AND position(';' in coalesce(obj_description(p.oid, 'pg_proc'), '')) > 0;
