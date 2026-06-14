#!/usr/bin/env bash
# test/concurrency/disconnect_release.sh
# Backend disconnect releases claim (before_shmem_exit fires).
#
# Scenario:
#   Session A: BEGIN; xclaim.try(1, 500) -> true; client disconnects (psql exits)
#   Session B: xclaim.try(1, 500) -> true (before_shmem_exit fired on A's exit)
#
# The before_shmem_exit callback runs when a backend exits normally, releasing
# all held claims. This is the normal graceful disconnect path.
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
# Test 1: disconnect triggers before_shmem_exit cleanup
# ---------------------------------------------------------------------------
echo "--- Test 1: disconnect releases claim ---"

# Session A: BEGIN + try, then the psql process exits normally.
# When psql disconnects gracefully, the backend calls before_shmem_exit which
# runs our shmem_exit callback.  The transaction abort path also fires first.
pg_xclaim_psql -X -A -t 2>/dev/null <<'SQLA'
BEGIN;
SELECT xclaim.try(1, 500);
SQLA
# psql exited here -- transaction was open (implicit ROLLBACK by disconnect)
# before_shmem_exit fires, our callback cleans up the entry.

# Brief pause to let backend finish cleanup (before_shmem_exit is synchronous
# within the same process but we need to ensure the shared state is updated)
sleep 0.1

# Session B: should now succeed
B_RESULT="$(pg_xclaim_psql -X -A -t 2>/dev/null <<'SQLB'
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
