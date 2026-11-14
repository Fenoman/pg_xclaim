#!/usr/bin/env bash
# test/concurrency/disconnect_release.sh
# Backend disconnect releases claim (the exit path aborts the open transaction).
#
# Scenario:
#   Session A: BEGIN; xclaim.try(1, 500) -> true; client disconnects (psql exits)
#   Session B: xclaim.try(1, 500) -> true (A's exit released the claim)
#
# When a backend exits with an open transaction, the core before_shmem_exit
# callback ShutdownPostgres aborts it and the xact callback releases all held
# claims. This is the normal graceful disconnect path.
#
# B's check requires A's claim (true) first. The shared table is checked
# after A's backend has exited and before B runs: a row of A left there
# carries the owner token that A's exit invalidated, so B's try would reap
# it and return true.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="disconnect_release"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

pg_xclaim_start_temp_cluster "disconnect_release"
trap pg_xclaim_stop_temp_cluster EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Test 1: disconnect triggers exit-path cleanup
# ---------------------------------------------------------------------------
echo "--- Test 1: disconnect releases claim ---"

# Session A: BEGIN + try, then the psql process exits normally.
# When psql disconnects gracefully, ShutdownPostgres aborts the open
# transaction and the xact callback releases the claim. pg_xclaim's own exit
# callback (on_shmem_exit) runs after that and finds nothing left.
if ! A_RESULT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 2>&1 <<'SQLA'
SELECT 'pid=' || pg_backend_pid();
BEGIN;
SELECT 'claim=' || xclaim.try(1, 500);
SQLA
)"; then
    echo "  FAIL: session A failed: $A_RESULT" >&2
fi
# psql exited here -- transaction was open (implicit ROLLBACK by disconnect)
# and its abort releases the entry.
A_VAL="$(sed -n 's/^claim=//p' <<<"$A_RESULT")"
A_PID="$(sed -n 's/^pid=//p' <<<"$A_RESULT")"
echo "  Session A: xclaim.try(1,500) = ${A_VAL:-none}, pid ${A_PID:-none}"

# The client can see the connection close before the backend has run its
# exit path, so wait until the backend process is gone.
if [[ "$A_VAL" == "true" && "$A_PID" =~ ^[0-9]+$ ]] && xclaim_wait_backend_gone "$A_PID"; then
    echo "  PASS: A took the claim and its backend exited"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "disconnect_a_true" "PASS" "result" "true" "A acquired and exited")")
else
    echo "  FAIL: A must take the claim (true) and its backend must exit, output follows:" >&2
    printf '%s\n' "$A_RESULT" | sed 's/^/    /' >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "disconnect_a_true" "FAIL" "result" "${A_VAL:-none}" "pid ${A_PID:-none}")")
fi

# No session holds a claim now: A's backend is gone and B has not started.
if ! LEFT_COUNT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 \
        -c "SELECT count(*) FROM xclaim.debug();" 2>&1)"; then
    echo "  FAIL: xclaim.debug() query failed: $LEFT_COUNT" >&2
    LEFT_COUNT="error"
fi
echo "  xclaim.debug() entries after A exited, before B: $LEFT_COUNT"
if [[ "$LEFT_COUNT" == "0" ]]; then
    echo "  PASS: A's exit left no row"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_row_after_exit" "PASS" "debug_count" "0" "before B")")
else
    echo "  FAIL: '$LEFT_COUNT' entries remain after A's backend exited" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_row_after_exit" "FAIL" "debug_count" "$LEFT_COUNT" "left by the exit path")")
fi

# Session B: should now succeed
B_RESULT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 2>/dev/null <<'SQLB'
BEGIN;
SELECT xclaim.try(1, 500);
ROLLBACK;
SQLB
)"

B_VAL="$(echo "$B_RESULT" | grep -E '^(t|f)$' | head -1 || echo "unknown")"
echo "  Session B after A disconnect: xclaim.try(1,500) = $B_VAL"

if [[ "$B_VAL" == "t" ]]; then
    echo "  PASS: B got true after A disconnected"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "disconnect_release" "PASS" "result" "true" "before_shmem_exit fired")")
else
    echo "  FAIL: B expected true, got '$B_VAL'" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "disconnect_release" "FAIL" "result" "$B_VAL" "before_shmem_exit may not have fired")")
fi

# ---------------------------------------------------------------------------
# Test 2: no leaked entries
# ---------------------------------------------------------------------------
echo "--- Test 2: no leaked entries after disconnect ---"
DEBUG_COUNT="$(pg_xclaim_psql -X -A -t -c "SELECT count(*) FROM xclaim.debug();" 2>/dev/null | tr -d ' ' || echo "-1")"
echo "  xclaim.debug() count = $DEBUG_COUNT"

if [[ "$DEBUG_COUNT" == "0" ]]; then
    echo "  PASS: no leaked entries"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_disconnect" "PASS" "debug_count" "0" "clean")")
else
    echo "  FAIL: expected 0 entries, got $DEBUG_COUNT" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_disconnect" "FAIL" "debug_count" "$DEBUG_COUNT" "leaked")")
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
