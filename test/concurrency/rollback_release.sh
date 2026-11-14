#!/usr/bin/env bash
# test/concurrency/rollback_release.sh
# Rollback releases claim.
#
# Scenario:
#   Session A: BEGIN; xclaim.try(1, 300) -> true; ROLLBACK. A stays connected.
#   Session B: xclaim.try(1, 300) -> true while A's backend is still alive.
#
# A is a holder session (_lib.sh) and closes only after B's check. Were A
# gone before B, the backend-exit cleanup would release the claim and hide
# a ROLLBACK that does not. B's check requires A's claim (true) first.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="rollback_release"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

pg_xclaim_start_temp_cluster "rollback_release"
trap pg_xclaim_stop_temp_cluster EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Test 1: A acquires + ROLLBACK, then B succeeds
# ---------------------------------------------------------------------------
echo "--- Test 1: rollback releases claim ---"

xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'claim=' || xclaim.try(1, 300);"
xclaim_holder_sql "ROLLBACK;"
xclaim_holder_sql "SELECT 'rolled_back=' || pg_backend_pid();"
A_VAL=""
A_PID=""
if xclaim_holder_wait '^rolled_back='; then
    A_VAL="$(sed -n 's/^claim=//p' "$XCLAIM_HOLDER_OUT")"
    A_PID="$(sed -n 's/^rolled_back=//p' "$XCLAIM_HOLDER_OUT")"
fi
A_STATE=""
if [[ "$A_PID" =~ ^[0-9]+$ ]]; then
    A_STATE="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 \
        -c "SELECT state FROM pg_stat_activity WHERE pid = $A_PID;")"
fi
echo "  Session A: xclaim.try(1,300) = ${A_VAL:-none}, state after ROLLBACK '${A_STATE:-gone}'"
if [[ "$A_VAL" == "true" && "$A_STATE" == "idle" ]]; then
    echo "  PASS: A took the claim, rolled back and is still connected"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "rollback_release_a_true" "PASS" "result" "true" "A acquired, alive after ROLLBACK")")
else
    echo "  FAIL: A must take the claim (true) and stay connected and idle after ROLLBACK, output follows:" >&2
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "rollback_release_a_true" "FAIL" "result" "${A_VAL:-none}" "state ${A_STATE:-gone}")")
fi

B_RESULT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 <<'SQLB' 2>/dev/null
BEGIN;
SELECT xclaim.try(1, 300);
ROLLBACK;
SQLB
)"

B_VAL="$(echo "$B_RESULT" | grep -E '^(t|f)$' | head -1 || echo "unknown")"
echo "  Session B after A ROLLBACK, A still connected: xclaim.try(1,300) = $B_VAL"
xclaim_holder_close

if [[ "$B_VAL" == "t" ]]; then
    echo "  PASS: B got true after A rolled back"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "rollback_release_b_true" "PASS" "result" "true" "B acquired after A rollback")")
else
    echo "  FAIL: B expected true, got '$B_VAL'" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "rollback_release_b_true" "FAIL" "result" "$B_VAL" "B should have acquired after A rollback")")
fi

# ---------------------------------------------------------------------------
# Test 2: After rollback, debug() shows no leftover entries
# ---------------------------------------------------------------------------
echo "--- Test 2: no leaked entries after rollback ---"
DEBUG_COUNT="$(pg_xclaim_psql -X -A -t -c "SELECT count(*) FROM xclaim.debug();" 2>/dev/null | tr -d ' ' || echo "-1")"
echo "  xclaim.debug() count after A rollback + B rollback = $DEBUG_COUNT"

if [[ "$DEBUG_COUNT" == "0" ]]; then
    echo "  PASS: no leaked entries"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_rollback" "PASS" "debug_count" "0" "clean state")")
else
    echo "  FAIL: expected 0 entries, got $DEBUG_COUNT" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_rollback" "FAIL" "debug_count" "$DEBUG_COUNT" "leaked entries")")
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
