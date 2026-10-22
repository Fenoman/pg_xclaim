-- pg_xclaim 1.0.0-rc2 -> 1.0.0-rc3 update script
--
-- No SQL object changes. 1.0.0-rc3 changes only the shared library, which
-- is replaced separately: install the new build and restart the server,
-- because pg_xclaim is loaded through shared_preload_libraries.

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_xclaim UPDATE TO '1.0.0-rc3'" to load this file. \quit
