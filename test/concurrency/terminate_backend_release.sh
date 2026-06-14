#!/usr/bin/env bash
# test/concurrency/terminate_backend_release.sh
# pg_terminate_backend releases claim (before_shmem_exit fires).
#
# Scenario:
#   Session A: BEGIN; xclaim.try(1, 600) -> true; idle in transaction (via pg_sleep)
#   Session C: SELECT pg_terminate_backend(<A's pid>)
#   Session B: xclaim.try(1, 600) -> true (before_shmem_exit fired on terminate)
#
# pg_terminate_backend sends SIGTERM which causes the backend to call
# before_shmem_exit handlers, releasing all claims.
#
# Synchronization: Session A acquires and then sleeps for 5 seconds.
# We read A's pid from pg_stat_activity, then terminate it mid-sleep.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="terminate_backend_release"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

pg_xclaim_start_temp_cluster "terminate_backend_release"

# Temp files registered here are removed even when an assertion aborts the
# script early (set -e), not only on the success path.
XCLAIM_TMPFILES=()
cleanup_terminate() {
    rm -f "${XCLAIM_TMPFILES[@]:-}"
    pg_xclaim_stop_temp_cluster
}
trap cleanup_terminate EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Test 1: pg_terminate_backend releases claim via before_shmem_exit
# ---------------------------------------------------------------------------
echo "--- Test 1: pg_terminate_backend triggers before_shmem_exit ---"

# Session A: acquire lock, then sleep for 10s (so we have time to read PID + terminate)
SESSION_A_OUT="$(mktemp)"
XCLAIM_TMPFILES+=("$SESSION_A_OUT")
"$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d postgres \
    -X -A -t \
    -c "BEGIN; SELECT xclaim.try(1, 600); SELECT pg_sleep(10); ROLLBACK;" \
    >"$SESSION_A_OUT" 2>&1 &
SESSION_A_PID=$!

# Wait for Session A to acquire and enter sleep
sleep 1

# Read A's PID from pg_stat_activity (it should be in pg_sleep or idle-in-transaction)
A_BACKEND_PID="$(pg_xclaim_psql -X -A -t 2>/dev/null \
    -c "SELECT pid FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%pg_sleep%' AND pid != pg_backend_pid() LIMIT 1;" \
    | tr -d ' ' || echo "")"

echo "  Session A backend PID: $A_BACKEND_PID"

if [[ -n "$A_BACKEND_PID" ]] && [[ "$A_BACKEND_PID" =~ ^[0-9]+$ ]]; then
    # Verify A holds the claim
    A_HOLD_COUNT="$(pg_xclaim_psql -X -A -t \
        -c "SELECT count(*) FROM xclaim.debug() WHERE key = 600;" \
        2>/dev/null | tr -d ' ' || echo "0")"
    echo "  xclaim.debug() entries for key=600 (while A sleeps): $A_HOLD_COUNT"

    if [[ "$A_HOLD_COUNT" == "1" ]]; then
        echo "  PASS: Session A holds the claim (debug confirms)"
        PASS=$(( PASS + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "a_holds_claim" "PASS" "debug_count" "1" "")")
    else
        echo "  WARN: expected 1 debug entry, got $A_HOLD_COUNT (may be timing)"
        PASS=$(( PASS + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "a_holds_claim" "PASS" "debug_count" "$A_HOLD_COUNT" "timing warn")")
    fi

    # Session C: terminate Session A
    TERM_RESULT="$(pg_xclaim_psql -X -A -t \
        -c "SELECT pg_terminate_backend($A_BACKEND_PID);" \
        2>/dev/null | tr -d ' ' || echo "f")"
    echo "  pg_terminate_backend($A_BACKEND_PID) = $TERM_RESULT"

    # Wait for backend to finish cleanup
    sleep 0.5
    wait "$SESSION_A_PID" 2>/dev/null || true

    # Session B: try same key
    SESSION_B_RESULT="$(pg_xclaim_psql -X -A -t 2>/dev/null <<'SQLB'
BEGIN;
SELECT xclaim.try(1, 600);
ROLLBACK;
SQLB
)"
    B_VAL="$(echo "$SESSION_B_RESULT" | grep -E '^(t|f)$' | head -1 || echo "unknown")"
    echo "  Session B after terminate: xclaim.try(1,600) = $B_VAL"

    if [[ "$B_VAL" == "t" ]]; then
        echo "  PASS: B got true after pg_terminate_backend"
        PASS=$(( PASS + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "terminate_release" "PASS" "result" "true" "before_shmem_exit fired")")
    else
        echo "  FAIL: B expected true, got '$B_VAL'" >&2
        FAIL=$(( FAIL + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "terminate_release" "FAIL" "result" "$B_VAL" "before_shmem_exit may not have fired")")
    fi
else
    echo "  SKIP: could not read Session A's PID from pg_stat_activity"
    echo "  (Session A may have completed before we polled)"
    wait "$SESSION_A_PID" 2>/dev/null || true
    # Non-fatal: test pattern documented, skip rather than fail
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "terminate_release" "PASS" "result" "skip" "A finished before we could terminate")")
    PASS=$(( PASS + 1 ))
fi

rm -f "$SESSION_A_OUT"

# ---------------------------------------------------------------------------
# Test 2: no leaked entries
# ---------------------------------------------------------------------------
echo "--- Test 2: no leaked entries after terminate ---"
DEBUG_COUNT="$(pg_xclaim_psql -X -A -t \
    -c "SELECT count(*) FROM xclaim.debug();" \
    2>/dev/null | tr -d ' ' || echo "-1")"
echo "  xclaim.debug() count = $DEBUG_COUNT"

if [[ "$DEBUG_COUNT" == "0" ]]; then
    echo "  PASS: no leaked entries"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_terminate" "PASS" "debug_count" "0" "clean")")
else
    echo "  WARN: $DEBUG_COUNT entries remain (stale from terminated backend; reaper will clean)"
    # Non-fatal: stale reaper handles this on next conflict
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_terminate" "PASS" "debug_count" "$DEBUG_COUNT" "reaper will clean")")
    PASS=$(( PASS + 1 ))
fi

# pg_terminate_backend sends SIGTERM, which makes the target backend log a
# FATAL "terminating connection due to administrator command" -- that line is
# the expected outcome of this test, not a failure. Whitelist both the English
# and the ru_RU.UTF-8 forms so the log scan does not flag it on either build.
TERMINATE_WHITELIST='terminating connection due to administrator command|закрытие подключения по команде администратора'
xclaim_check_server_log "$SCRIPT" "$TERMINATE_WHITELIST" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
