-- test/sql/extension_version.sql
-- Extension version and update path.
-- CREATE EXTENSION reaches default_version through the base install script
-- and the update scripts, and an installation created at an earlier
-- version updates in place with ALTER EXTENSION ... UPDATE.

\set VERBOSITY terse
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_xclaim;
SELECT extversion FROM pg_extension WHERE extname = 'pg_xclaim';
SELECT default_version FROM pg_available_extensions WHERE name = 'pg_xclaim';
SELECT version FROM pg_available_extension_versions
 WHERE name = 'pg_xclaim' ORDER BY version;

-- The session_reset() comment comes from the update script, so a fresh
-- install and an updated 1.0.0-rc1 installation carry the same text.
SELECT obj_description('xclaim.session_reset()'::regprocedure, 'pg_proc')
    AS session_reset_comment \gset
SELECT :'session_reset_comment' LIKE '%xclaim.count() > 0%' AS points_to_count,
       :'session_reset_comment' NOT LIKE '%cleanup_misses > 0%' AS no_cleanup_misses_advice;

-- The try_many and debug comments come from the 1.0.0-rc4 update script.
SELECT obj_description('xclaim.try_many(int8[])'::regprocedure, 'pg_proc')
    AS try_many_comment \gset
SELECT :'try_many_comment' LIKE '%on_capacity_exhaustion = warn%' AS try_many_names_warn_mode,
       obj_description('xclaim.try_many(int4, int4[])'::regprocedure, 'pg_proc')
           LIKE '%on_capacity_exhaustion = warn%' AS pair_try_many_names_warn_mode,
       obj_description('xclaim.debug()'::regprocedure, 'pg_proc')
           LIKE '%after releasing them%' AS debug_builds_after_release,
       obj_description('xclaim.debug_snapshot()'::regprocedure, 'pg_proc')
           LIKE '%after releasing them%' AS snapshot_builds_after_release,
       :'session_reset_comment' LIKE '%running transaction holds claims%'
           AND :'session_reset_comment' LIKE '%inside an xclaim.try_many call%'
           AS reset_names_its_refusals;

-- The five comments of the 1.0.0-rc4 update script, for the update path.
SELECT string_agg(obj_description(f::regprocedure, 'pg_proc'), ' | ' ORDER BY f)
           AS rc4_comments
FROM unnest(ARRAY['xclaim.try_many(int4, int4[])', 'xclaim.try_many(int8[])',
                  'xclaim.debug()', 'xclaim.debug_snapshot()',
                  'xclaim.session_reset()']) AS f \gset

-- An installation created at 1.0.0-rc1 updates in place, through 1.0.0-rc2
-- to the default version.
SELECT current_database() AS main_db \gset
CREATE DATABASE xclaim_version_update;
\c xclaim_version_update
CREATE EXTENSION pg_xclaim VERSION '1.0.0-rc1';
SELECT extversion FROM pg_extension WHERE extname = 'pg_xclaim';
SELECT obj_description('xclaim.session_reset()'::regprocedure, 'pg_proc')
       = :'session_reset_comment' AS same_comment_as_fresh_install;
ALTER EXTENSION pg_xclaim UPDATE TO '1.0.0-rc2';
SELECT extversion FROM pg_extension WHERE extname = 'pg_xclaim';
SELECT obj_description('xclaim.session_reset()'::regprocedure, 'pg_proc')
       = :'session_reset_comment' AS same_comment_as_fresh_install;
ALTER EXTENSION pg_xclaim UPDATE;
SELECT extversion FROM pg_extension WHERE extname = 'pg_xclaim';
SELECT obj_description('xclaim.session_reset()'::regprocedure, 'pg_proc')
       = :'session_reset_comment' AS same_comment_as_fresh_install;
SELECT string_agg(obj_description(f::regprocedure, 'pg_proc'), ' | ' ORDER BY f)
       = :'rc4_comments' AS same_rc4_comments_as_fresh_install
FROM unnest(ARRAY['xclaim.try_many(int4, int4[])', 'xclaim.try_many(int8[])',
                  'xclaim.debug()', 'xclaim.debug_snapshot()',
                  'xclaim.session_reset()']) AS f;
-- The functions work after the update.
BEGIN;
SELECT xclaim.try(1, 950);
SELECT xclaim.count();
ROLLBACK;
\c :main_db
DROP DATABASE xclaim_version_update;
