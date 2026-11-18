#!/usr/bin/env bash
# test/concurrency/extension_upgrade.sh
# Cross-session keyspace/DB isolation + in-place ALTER EXTENSION UPDATE
# from 1.0.0-rc1 -> 1.0.0-rc5 (dropping debug_inject_stale, aligning
# comments and preserving custom OmniX_DB-style ACL grants).
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="extension_upgrade"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

trap pg_xclaim_stop_temp_cluster EXIT INT TERM
XCLAIM_EXTRA_CONF="lc_messages = 'C'"
pg_xclaim_start_temp_cluster "ext_upgrade"

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

pass() {
    echo "  PASS: $4"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$1" "PASS" "$2" "$3" "$4")")
}
fail() {
    echo "  FAIL: $4 (got $3)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$1" "FAIL" "$2" "$3" "$4")")
}

echo "--- Test 1: concurrent cross-database isolation and solo(99) vs pair(0, 99) ---"
pg_xclaim_psql -X -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE db_iso_b;"
"$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d db_iso_b -X -q -v ON_ERROR_STOP=1 \
    -c "CREATE EXTENSION pg_xclaim;"

xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'held=' || xclaim.try(1, 500) || ':' || xclaim.try(99::int8);"
xclaim_holder_wait '^held=true:true$'

OTHER_DB_RES="$("$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d db_iso_b -X -A -t -q -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SELECT xclaim.try(1, 500) || ':' || xclaim.try(99::int8);
COMMIT;
SQL
)"
SAME_DB_RES="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SELECT xclaim.try(0, 99) || ':' || xclaim.try(99::int8) || ':' || xclaim.try(1, 500);
COMMIT;
SQL
)"

xclaim_holder_sql "COMMIT;"
xclaim_holder_close

if [[ "$OTHER_DB_RES" == "true:true" && "$SAME_DB_RES" == "true:false:false" ]]; then
    pass "cross_session_keyspace_db_isolation" "res" "${OTHER_DB_RES}|${SAME_DB_RES}" "concurrent cross-DB (1,500) and cross-form solo(99) vs pair(0,99) isolated"
else
    fail "cross_session_keyspace_db_isolation" "res" "${OTHER_DB_RES}|${SAME_DB_RES}" "expected true:true and true:false:false"
fi

echo "--- Test 2: ALTER EXTENSION pg_xclaim UPDATE 1.0.0-rc1 -> 1.0.0-rc5 full catalog + ACL parity ---"
SIG_SQL="
SELECT md5(
    string_agg(
        p.proname || ':' ||
        pg_get_function_identity_arguments(p.oid) || ':' ||
        pg_get_function_result(p.oid) || ':' ||
        p.provolatile::text || ':' ||
        p.proparallel::text || ':' ||
        p.proisstrict::text || ':' ||
        p.prosecdef::text || ':' ||
        coalesce(p.proacl::text, '') || ':' ||
        coalesce(obj_description(p.oid, 'pg_proc'), ''),
        '|' ORDER BY p.proname, pg_get_function_identity_arguments(p.oid)
    )
    || '||' || coalesce((SELECT nspacl::text FROM pg_namespace WHERE oid = 'xclaim'::regnamespace), '')
    || '||' || coalesce(obj_description('xclaim'::regnamespace, 'pg_namespace'), '')
)
FROM pg_proc p
WHERE p.pronamespace = 'xclaim'::regnamespace"

FRESH_SIG="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 -c "$SIG_SQL")"

pg_xclaim_psql -X -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE db_upg_clean;"
CLEAN_UPG_OUT="$("$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d db_upg_clean -X -A -t -q -v ON_ERROR_STOP=1 <<SQL
CREATE EXTENSION pg_xclaim;
CREATE FUNCTION xclaim.debug_inject_stale(scope int4, key int4) RETURNS void
    LANGUAGE sql VOLATILE PARALLEL UNSAFE CALLED ON NULL INPUT AS '';
REVOKE ALL ON FUNCTION xclaim.debug_inject_stale(int4, int4) FROM PUBLIC;
ALTER EXTENSION pg_xclaim ADD FUNCTION xclaim.debug_inject_stale(int4, int4);
COMMENT ON SCHEMA xclaim IS 'legacy rc1 schema comment';
COMMENT ON FUNCTION xclaim.try(int4, int4) IS 'legacy rc1 pair comment';
COMMENT ON FUNCTION xclaim.try(int8) IS 'legacy rc1 solo comment';
COMMENT ON FUNCTION xclaim.try_many(int4, int4[]) IS 'legacy rc1 pair bulk comment';
COMMENT ON FUNCTION xclaim.try_many(int8[]) IS 'legacy rc1 solo bulk comment';
COMMENT ON FUNCTION xclaim.count() IS 'legacy rc1 count comment';
COMMENT ON FUNCTION xclaim.stats() IS 'legacy rc1 stats comment';
COMMENT ON FUNCTION xclaim.debug() IS 'legacy rc1 debug comment';
COMMENT ON FUNCTION xclaim.debug_snapshot() IS 'legacy rc1 snapshot comment';
COMMENT ON FUNCTION xclaim.session_reset() IS 'legacy rc1 reset comment';
UPDATE pg_catalog.pg_extension SET extversion = '1.0.0-rc1' WHERE extname = 'pg_xclaim';
ALTER EXTENSION pg_xclaim UPDATE;
SELECT (SELECT extversion FROM pg_extension WHERE extname = 'pg_xclaim') || '|' ||
       (to_regprocedure('xclaim.debug_inject_stale(int4, int4)') IS NULL)::text || '|' ||
       ($SIG_SQL);
SQL
)"

pg_xclaim_psql -X -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE db_upg_acl;"
ACL_UPG_OUT="$("$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d db_upg_acl -X -A -t -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE customer_dev NOLOGIN;
CREATE EXTENSION pg_xclaim;
-- Standalone user-owned function NOT attached to pg_xclaim must survive UPDATE!
CREATE FUNCTION xclaim.debug_inject_stale(scope int4, key int4) RETURNS void
    LANGUAGE sql VOLATILE PARALLEL UNSAFE CALLED ON NULL INPUT AS '';
UPDATE pg_catalog.pg_extension SET extversion = '1.0.0-rc1' WHERE extname = 'pg_xclaim';

REVOKE EXECUTE ON FUNCTION xclaim.session_reset() FROM PUBLIC;
GRANT USAGE ON SCHEMA xclaim TO customer_dev;
GRANT EXECUTE ON FUNCTION xclaim.session_reset(), xclaim.stats(), xclaim.debug_snapshot(), xclaim.debug() TO customer_dev;

ALTER EXTENSION pg_xclaim UPDATE;

SELECT
    (SELECT extversion FROM pg_extension WHERE extname = 'pg_xclaim') || '|' ||
    (to_regprocedure('xclaim.debug_inject_stale(int4, int4)') IS NOT NULL)::text || '|' ||
    has_function_privilege('public', 'xclaim.session_reset()'::regprocedure, 'EXECUTE')::text || '|' ||
    has_function_privilege('customer_dev', 'xclaim.debug()'::regprocedure, 'EXECUTE')::text || '|' ||
    has_function_privilege('customer_dev', 'xclaim.session_reset()'::regprocedure, 'EXECUTE')::text;
SQL
)"

pg_xclaim_psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
DROP DATABASE db_upg_clean;
DROP DATABASE db_upg_acl;
DROP DATABASE db_iso_b;
DROP ROLE customer_dev;
SQL

EXPECTED_CLEAN="1.0.0-rc5|true|${FRESH_SIG}"
EXPECTED_ACL="1.0.0-rc5|true|false|true|true"
echo "  clean upgrade state: $CLEAN_UPG_OUT"
echo "  ACL + non-member survival state: $ACL_UPG_OUT"
if [[ "$CLEAN_UPG_OUT" == "$EXPECTED_CLEAN" && "$ACL_UPG_OUT" == "$EXPECTED_ACL" ]]; then
    pass "rc1_to_rc5_update_and_acls" "state" "1.0.0-rc5" "rc1->rc5 update matched full fresh catalog+ACL signature, dropped member debug_inject_stale, kept non-member function and preserved custom ACLs"
else
    fail "rc1_to_rc5_update_and_acls" "state" "clean=$CLEAN_UPG_OUT acl=$ACL_UPG_OUT" "expected $EXPECTED_CLEAN and $EXPECTED_ACL"
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
