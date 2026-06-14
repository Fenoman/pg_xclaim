#!/usr/bin/env bash
# test/concurrency/conflict.sh
# Cross-session conflict test.
#
# Scenario:
#   Session A: BEGIN; xclaim.try(1, 100) -> true; stays in transaction (idle)
#   Session B: BEGIN; xclaim.try(1, 100) -> false  (conflict with A)
#   Session A: ROLLBACK
#   Session B (new): xclaim.try(1, 100) -> true  (now available)
#
# Synchronization strategy:
#   Session A holds the transaction open using pg_sleep. Session B connects
#   during that sleep window. This avoids named-pipe race conditions.
#
# CSV output: TIMESTAMP,script,test,PASS/FAIL,metric,value,notes
#
# HARD INVARIANTS:
#   set -euo pipefail
#   temp cluster under /tmp/pg_xclaim_${USER}_$$
#   locale ru_RU.UTF-8
#   trap cleanup
set -euo pipefail

SCRIPT="conflict"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

pg_xclaim_start_temp_cluster "conflict"

# Temp files registered here are removed even when an assertion aborts the
# script early (set -e), not only on the success path.
XCLAIM_TMPFILES=()
cleanup_conflict() {
    rm -f "${XCLAIM_TMPFILES[@]:-}"
    pg_xclaim_stop_temp_cluster
}
trap cleanup_conflict EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Test 1: Session A acquires (1,100), stays in txn (via pg_sleep 3s).
#         Session B immediately tries same key -> should get false.
# ---------------------------------------------------------------------------
echo "--- Test 1: conflict between two sessions ---"

# Session A: BEGIN, acquire, sleep for 3 seconds to hold the transaction open,
# then ROLLBACK. The sleep gives Session B time to attempt the same key.
SESSION_A_OUT="$(mktemp)"
XCLAIM_TMPFILES+=("$SESSION_A_OUT")
(
    "$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d postgres \
        -X -A -t \
        -c "BEGIN;" \
        -c "SELECT xclaim.try(1, 100);" \
        -c "SELECT pg_sleep(3);" \
        -c "ROLLBACK;" \
        >"$SESSION_A_OUT" 2>&1
) &
SESSION_A_PID=$!

# Wait briefly for Session A to acquire the lock
sleep 0.5

# Session B: try to acquire same key while A is sleeping (holding the lock)
# xclaim.try is non-blocking: returns false immediately if conflict
SESSION_B_RESULT="$(pg_xclaim_psql -X -A -t 2>/dev/null <<'SQLB'
BEGIN;
SELECT xclaim.try(1, 100);
ROLLBACK;
SQLB
)"
B_TRY_RESULT="$(echo "$SESSION_B_RESULT" | grep -E '^(t|f)$' | head -1 || echo "unknown")"
echo "  Session A: acquiring (1,100) and sleeping 3s..."
echo "  Session B xclaim.try(1,100) while A holds: $B_TRY_RESULT"

if [[ "$B_TRY_RESULT" == "f" ]]; then
    echo "  PASS: Session B correctly got false (conflict)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflict_b_false" "PASS" "result" "false" "B saw conflict as expected")")
else
    echo "  FAIL: Session B expected false, got '$B_TRY_RESULT'" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflict_b_false" "FAIL" "result" "$B_TRY_RESULT" "B should have seen conflict")")
fi

# Wait for Session A to finish (pg_sleep 3s + rollback)
wait "$SESSION_A_PID" 2>/dev/null || true
rm -f "$SESSION_A_OUT"

# ---------------------------------------------------------------------------
# Test 2: After A releases (ROLLBACK after sleep), B can acquire
# ---------------------------------------------------------------------------
echo "--- Test 2: after A releases, B succeeds ---"

# A is now done (sleep finished, rollback executed). B should succeed.
SESSION_B2_RESULT="$(pg_xclaim_psql -X -A -t 2>/dev/null <<'SQLB2'
BEGIN;
SELECT xclaim.try(1, 100);
ROLLBACK;
SQLB2
)"
B2_TRY_RESULT="$(echo "$SESSION_B2_RESULT" | grep -E '^(t|f)$' | head -1 || echo "unknown")"
echo "  Session B xclaim.try(1,100) after A released: $B2_TRY_RESULT"

if [[ "$B2_TRY_RESULT" == "t" ]]; then
    echo "  PASS: Session B got true after A released"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflict_b_after_release" "PASS" "result" "true" "B succeeded after A released")")
else
    echo "  FAIL: Session B expected true after release, got '$B2_TRY_RESULT'" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflict_b_after_release" "FAIL" "result" "$B2_TRY_RESULT" "B should have succeeded")")
fi

# ---------------------------------------------------------------------------
# Test 3: stats.conflicts incremented from session A's conflict with B
# ---------------------------------------------------------------------------
echo "--- Test 3: stats.conflicts incremented ---"
CONFLICTS="$(pg_xclaim_psql -X -A -t \
    -c "SELECT conflicts FROM xclaim.stats();" \
    2>/dev/null | tr -d ' ' || echo "0")"
echo "  xclaim.stats().conflicts = $CONFLICTS"
# There should have been exactly 1 conflict (Session B tried while A held)
if (( CONFLICTS > 0 )); then
    echo "  PASS: conflicts counter incremented ($CONFLICTS)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflicts_incremented" "PASS" "conflicts" "$CONFLICTS" "conflict recorded")")
else
    echo "  FAIL: conflicts counter not incremented" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflicts_incremented" "FAIL" "conflicts" "0" "should be > 0")")
fi

# ---------------------------------------------------------------------------
# Server log check
# ---------------------------------------------------------------------------
xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do
    echo "$row"
done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
