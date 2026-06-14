#!/usr/bin/env bash
# test/concurrency/error_release.sh
# Error/abort releases claim.
#
# Scenario:
#   Session A: BEGIN; xclaim.try(1, 400) -> true; RAISE EXCEPTION -> txn aborts
#   Session B: xclaim.try(1, 400) -> true (A's txn was aborted, entry released)
#
# The xact ABORT callback fires on top-level ERROR abort, releasing all claims.
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

# Session A: acquire then raise exception (txn aborts)
# We use a DO block with a RAISE EXCEPTION at the top level of the transaction.
# Note: the outer transaction is aborted by the exception.
pg_xclaim_psql -X -A -t 2>/dev/null <<'SQLA' || true
BEGIN;
SELECT xclaim.try(1, 400);
DO $$ BEGIN RAISE EXCEPTION 'test error to abort txn'; END $$;
SQLA
# The above errors; psql returns non-zero but we captured with || true.
# The transaction is now aborted. The ABORT xact callback should have fired.

# Session B: should now succeed
B_RESULT="$(pg_xclaim_psql -X -A -t 2>/dev/null <<'SQLB'
BEGIN;
SELECT xclaim.try(1, 400);
ROLLBACK;
SQLB
)"

B_VAL="$(echo "$B_RESULT" | grep -E '^(t|f)$' | head -1 || echo "unknown")"
echo "  Session B after A error-abort: xclaim.try(1,400) = $B_VAL"

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
