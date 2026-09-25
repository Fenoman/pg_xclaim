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
       :'session_reset_comment' LIKE '%cleanup_misses > 0%' AS points_to_cleanup_misses;

-- An installation created at 1.0.0-rc1 updates to 1.0.0-rc2 in place.
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
-- The functions work after the update.
BEGIN;
SELECT xclaim.try(1, 950);
SELECT xclaim.count();
ROLLBACK;
\c :main_db
DROP DATABASE xclaim_version_update;
