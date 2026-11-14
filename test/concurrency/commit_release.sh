#!/usr/bin/env bash
# test/concurrency/commit_release.sh
# Commit releases claim, so another session can then acquire.
#
# Scenario:
#   Session A: BEGIN; xclaim.try(1, 200) -> true; COMMIT. A stays connected.
#   Session B: xclaim.try(1, 200) -> true while A's backend is still alive.
#
# A is a holder session (_lib.sh) and closes only after B's check. Were A
# gone before B, the backend-exit cleanup would release the claim and hide
# a COMMIT that does not.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="commit_release"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

pg_xclaim_start_temp_cluster "commit_release"
trap pg_xclaim_stop_temp_cluster EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Test 1: A acquires and COMMITs, then B succeeds
# ---------------------------------------------------------------------------
echo "--- Test 1: commit releases claim ---"

# Session A: acquire + commit, then report its pid and stay connected. A
# must really take the claim, otherwise B's success below proves nothing
# about the release.
xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'claim=' || xclaim.try(1, 200);"
xclaim_holder_sql "COMMIT;"
xclaim_holder_sql "SELECT 'committed=' || pg_backend_pid();"
A_RESULT=""
A_PID=""
if xclaim_holder_wait '^committed='; then
    A_RESULT="$(sed -n 's/^claim=//p' "$XCLAIM_HOLDER_OUT")"
    A_PID="$(sed -n 's/^committed=//p' "$XCLAIM_HOLDER_OUT")"
fi
echo "  Session A: xclaim.try(1,200) = ${A_RESULT:-none}, pid ${A_PID:-none}"
if [[ "$A_RESULT" == "true" ]]; then
    echo "  PASS: A took the claim"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_release_a_true" "PASS" "result" "true" "A acquired")")
else
    echo "  FAIL: A expected true, got '${A_RESULT:-none}', output follows:" >&2
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_release_a_true" "FAIL" "result" "${A_RESULT:-none}" "A should have acquired")")
fi

# A is connected and outside any transaction: its COMMIT is done and its
# backend has not exited.
A_STATE="none"
if [[ "$A_PID" =~ ^[0-9]+$ ]]; then
    A_STATE="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 \
        -c "SELECT state FROM pg_stat_activity WHERE pid = $A_PID;")"
fi
echo "  Session A state before B: ${A_STATE:-gone}"
if [[ "$A_STATE" == "idle" ]]; then
    echo "  PASS: A committed and is still connected"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_release_a_alive" "PASS" "state" "idle" "A alive after COMMIT")")
else
    echo "  FAIL: A must be connected and idle after its COMMIT, state '${A_STATE:-gone}'" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_release_a_alive" "FAIL" "state" "${A_STATE:-gone}" "A must be alive and idle")")
fi

# Session B: try same key (should succeed -- A committed)
B_RESULT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 <<'SQLB' 2>/dev/null
BEGIN;
SELECT xclaim.try(1, 200);
ROLLBACK;
SQLB
)"

B_VAL="$(echo "$B_RESULT" | grep -E '^(t|f)$' | head -1 || echo "unknown")"
echo "  Session B after A COMMIT, A still connected: xclaim.try(1,200) = $B_VAL"
xclaim_holder_close

if [[ "$B_VAL" == "t" ]]; then
    echo "  PASS: B got true after A committed"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_release_b_true" "PASS" "result" "true" "B acquired after A commit")")
else
    echo "  FAIL: B expected true, got '$B_VAL'" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_release_b_true" "FAIL" "result" "$B_VAL" "B should have acquired after A commit")")
fi

# ---------------------------------------------------------------------------
# Test 2: Verify stats.conflicts == 0 (no conflict path taken, just sequential)
# ---------------------------------------------------------------------------
echo "--- Test 2: no spurious conflicts in stats ---"
if ! CONFLICTS="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 \
        -c "SELECT conflicts FROM xclaim.stats();" 2>&1)"; then
    echo "  FAIL: xclaim.stats() query failed: $CONFLICTS" >&2
    CONFLICTS="error"
fi
echo "  xclaim.stats().conflicts = $CONFLICTS"
# A committed before B started, so no try ever met a held key.
if [[ "$CONFLICTS" == "0" ]]; then
    echo "  PASS: no conflicts recorded (sequential access)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_spurious_conflicts" "PASS" "conflicts" "0" "sequential sessions")")
else
    echo "  FAIL: conflicts='$CONFLICTS' in a strictly sequential test (expected 0)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_spurious_conflicts" "FAIL" "conflicts" "$CONFLICTS" "expected 0")")
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
