#!/usr/bin/env bash
# test/concurrency/sigkill_stale.sh
# Stale-owner reaper + xclaim_test_hooks hardening + stats() clamping test.
#
# Scenario:
#   1. Inject stale entry via xclaim_test_hooks -> visible in debug()
#   2. xclaim.try(1, 700) -> reaper triggers, returns true, reaped_stale++
#   3. xclaim.debug() empty after ROLLBACK (capacity_used = 0)
#   4. Hardening of xclaim_test_inject_stale (NULL, live-key, non-superuser)
#   5. xclaim.stats() capacity_pct clamping on out-of-range live_capacity
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="sigkill_stale"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

trap pg_xclaim_stop_temp_cluster EXIT INT TERM
xclaim_build_test_hooks
XCLAIM_EXTRA_CONF="${XCLAIM_EXTRA_CONF:+$XCLAIM_EXTRA_CONF
}lc_messages = 'C'"
pg_xclaim_start_temp_cluster "sigkill_stale"
xclaim_create_test_hooks_functions

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

echo "--- Test 1: inject stale entry via xclaim_test_hooks ---"
pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 -c "SELECT xclaim_test_inject_stale(1, 700);" >/dev/null

STALE_COUNT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 \
    -c "SELECT count(*) FROM xclaim.debug() WHERE key = 700;" | tr -d ' ')"
if [[ "$STALE_COUNT" == "1" ]]; then
    pass "stale_injected" "debug_count" "1" "stale entry visible in debug()"
else
    fail "stale_injected" "debug_count" "$STALE_COUNT" "expected 1 stale entry"
fi

echo "--- Test 2: try on stale key triggers reaper ---"
REAPED_BEFORE="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 \
    -c "SELECT reaped_stale FROM xclaim.stats();" | tr -d ' ')"
TRY_VAL="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 <<'SQLB'
BEGIN;
SELECT xclaim.try(1, 700);
ROLLBACK;
SQLB
)"
if [[ "$TRY_VAL" == "t" ]]; then
    pass "reaper_allows_try" "result" "true" "reaper allowed acquisition on stale entry"
else
    fail "reaper_allows_try" "result" "$TRY_VAL" "expected true on stale entry"
fi

echo "--- Test 3: reaped_stale counter incremented and no residual entry ---"
STATS_AFTER="$(pg_xclaim_psql -X -A -t -F'|' -v ON_ERROR_STOP=1 \
    -c "SELECT reaped_stale - $REAPED_BEFORE, capacity_used, (SELECT count(*) FROM xclaim.debug() WHERE key = 700) FROM xclaim.stats();")"
if [[ "$STATS_AFTER" == "1|0|0" ]]; then
    pass "reaped_clean" "delta_used_rows" "$STATS_AFTER" "reaped_stale +1, capacity_used 0, debug empty"
else
    fail "reaped_clean" "delta_used_rows" "$STATS_AFTER" "expected 1|0|0"
fi

echo "--- Test 4: xclaim_test_inject_stale hardening ---"
HARDEN_OUT="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 <<'SQLH'
DO $$
DECLARE
    caught_null bool := false;
    caught_live bool := false;
BEGIN
    BEGIN
        PERFORM xclaim_test_inject_stale(NULL, 1);
    EXCEPTION WHEN null_value_not_allowed THEN
        caught_null := true;
    END;

    PERFORM xclaim.try(102, 7);
    BEGIN
        PERFORM xclaim_test_inject_stale(102, 7);
    EXCEPTION WHEN object_in_use THEN
        caught_live := true;
    END;

    IF NOT caught_null OR NOT caught_live THEN
        RAISE EXCEPTION 'hardening failed: null=% live=%', caught_null, caught_live;
    END IF;
END;
$$;
CREATE ROLE xclaim_nosuper NOSUPERUSER NOLOGIN;
GRANT EXECUTE ON FUNCTION xclaim_test_inject_stale(int4, int4) TO xclaim_nosuper;
SET ROLE xclaim_nosuper;
DO $$
BEGIN
    PERFORM xclaim_test_inject_stale(999, 1);
    RAISE EXCEPTION 'non-superuser was allowed';
EXCEPTION WHEN insufficient_privilege THEN
    NULL;
END;
$$;
RESET ROLE;
REVOKE EXECUTE ON FUNCTION xclaim_test_inject_stale(int4, int4) FROM xclaim_nosuper;
DROP ROLE xclaim_nosuper;
SELECT 'ok';
SQLH
)"
if [[ "$HARDEN_OUT" == "ok" ]]; then
    pass "injector_hardening" "guards" "ok" "NULL, live-key and superuser guards enforced"
else
    fail "injector_hardening" "guards" "$HARDEN_OUT" "injector hardening failed"
fi

echo "--- Test 5: xclaim.stats() capacity_pct clamping on out-of-range live_capacity ---"
CLAMP_OUT="$(pg_xclaim_psql -X -A -t -F'|' -v ON_ERROR_STOP=1 <<'SQLC'
SELECT xclaim_test_set_live_capacity(999999999);
SELECT capacity_pct FROM xclaim.stats();
SELECT xclaim_test_set_live_capacity(-50);
SELECT capacity_pct FROM xclaim.stats();
SELECT xclaim_test_set_live_capacity(0);
SELECT capacity_pct FROM xclaim.stats();
SQLC
)"
CLAMP_FLAT="$(echo "$CLAMP_OUT" | grep -E '^[0-9]+\.[0-9]+$' | paste -sd'|' -)"
if [[ "$CLAMP_FLAT" == "999.99|0.00|0.00" ]]; then
    pass "stats_pct_clamp" "pcts" "$CLAMP_FLAT" "xclaim.stats() clamps capacity_pct to [0.00, 999.99]"
else
    fail "stats_pct_clamp" "pcts" "$CLAMP_FLAT" "expected 999.99|0.00|0.00"
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
