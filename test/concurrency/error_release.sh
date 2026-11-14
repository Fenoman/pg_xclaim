#!/usr/bin/env bash
# test/concurrency/error_release.sh
# Error/abort releases claim.
#
# Scenario:
#   Session A: BEGIN; xclaim.try(1, 400) -> true; RAISE EXCEPTION -> txn aborts
#   Session B: xclaim.try(1, 400) -> true while A is still connected and its
#              transaction block is still open in the aborted state
#
# The xact ABORT callback fires on top-level ERROR abort, releasing all claims
# before the ROLLBACK that ends the block. A is a holder session (_lib.sh)
# and sends its ROLLBACK and closes only after B's check: neither the
# ROLLBACK nor the backend-exit cleanup can then hide an ERROR that does not
# release. B's check requires A's claim (true) and A's error first.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="error_release"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

pg_xclaim_start_temp_cluster "error_release"
trap pg_xclaim_stop_temp_cluster EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Test 1: top-level ERROR aborts txn and releases claim
# ---------------------------------------------------------------------------
echo "--- Test 1: error/abort releases claim ---"

# Session A: acquire, then raise an exception: the transaction aborts and
# the block waits for ROLLBACK.
xclaim_holder_open
xclaim_holder_sql "SELECT 'pid=' || pg_backend_pid();"
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'claim=' || xclaim.try(1, 400);"
xclaim_holder_sql "DO \$\$ BEGIN RAISE EXCEPTION 'test error to abort txn'; END \$\$;"
A_VAL=""
A_PID=""
if xclaim_holder_wait 'test error to abort txn'; then
    A_VAL="$(sed -n 's/^claim=//p' "$XCLAIM_HOLDER_OUT")"
    A_PID="$(sed -n 's/^pid=//p' "$XCLAIM_HOLDER_OUT")"
fi
A_STATE=""
if [[ "$A_PID" =~ ^[0-9]+$ ]]; then
    A_STATE="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 \
        -c "SELECT state FROM pg_stat_activity WHERE pid = $A_PID;")"
fi
echo "  Session A: xclaim.try(1,400) = ${A_VAL:-none}, state after the error '${A_STATE:-gone}'"
if [[ "$A_VAL" == "true" && "$A_STATE" == "idle in transaction (aborted)" ]]; then
    echo "  PASS: A took the claim and its transaction aborted on the error"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "error_abort_a_true" "PASS" "result" "true" "A acquired, aborted block open")")
else
    echo "  FAIL: A must take the claim (true) and stay in an aborted transaction block, output follows:" >&2
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "error_abort_a_true" "FAIL" "result" "${A_VAL:-none}" "state ${A_STATE:-gone}")")
fi

# Session B: should now succeed
B_RESULT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 2>/dev/null <<'SQLB'
BEGIN;
SELECT xclaim.try(1, 400);
ROLLBACK;
SQLB
)"

B_VAL="$(echo "$B_RESULT" | grep -E '^(t|f)$' | head -1 || echo "unknown")"
echo "  Session B after A error-abort, before A's ROLLBACK: xclaim.try(1,400) = $B_VAL"
xclaim_holder_sql "ROLLBACK;"
xclaim_holder_close

if [[ "$B_VAL" == "t" ]]; then
    echo "  PASS: B got true after A's error-abort"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "error_abort_release" "PASS" "result" "true" "B acquired after A error")")
else
    echo "  FAIL: B expected true, got '$B_VAL'" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "error_abort_release" "FAIL" "result" "$B_VAL" "B should have acquired")")
fi

# ---------------------------------------------------------------------------
# Test 2: no leftover entries after error-abort
# ---------------------------------------------------------------------------
echo "--- Test 2: no leaked entries after error-abort ---"
DEBUG_COUNT="$(pg_xclaim_psql -X -A -t -c "SELECT count(*) FROM xclaim.debug();" 2>/dev/null | tr -d ' ' || echo "-1")"
echo "  xclaim.debug() count = $DEBUG_COUNT"

if [[ "$DEBUG_COUNT" == "0" ]]; then
    echo "  PASS: no leaked entries"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_error" "PASS" "debug_count" "0" "clean")")
else
    echo "  FAIL: expected 0 entries, got $DEBUG_COUNT" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_error" "FAIL" "debug_count" "$DEBUG_COUNT" "leaked")")
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
