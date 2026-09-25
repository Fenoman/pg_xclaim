-- pg_xclaim 1.0.0-rc1 -> 1.0.0-rc2 update script
--
-- Replaces the catalog comment of xclaim.session_reset(). No other SQL
-- object changes. The shared library is replaced separately: install the
-- new build and restart the server, because pg_xclaim is loaded through
-- shared_preload_libraries.

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_xclaim UPDATE TO '1.0.0-rc2'" to load this file. \quit

COMMENT ON FUNCTION xclaim.session_reset() IS
    'pg_xclaim reactive triage tool. Releases the claims the calling backend still holds outside a transaction and rotates its owner_token. Backend-local: only affects the session that invoked it. Not needed in routine operation: the xact callback releases claims at every transaction end, and the backend-exit callback at backend exit. Claims still held outside a transaction (xclaim.count() > 0 in autocommit) mean the xact callback did not release them, which normal operation never does. Do NOT wire into pooler server_reset_query. Granted to PUBLIC like pg_advisory_unlock_all. Do NOT additionally grant to pg_monitor (observational role).';
