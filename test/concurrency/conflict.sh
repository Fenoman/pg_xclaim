#!/usr/bin/env bash
# test/concurrency/conflict.sh
# Cross-session conflict test.
#
# Scenario:
#   Session A: BEGIN; xclaim.try(1, 100) -> true; stays in transaction (idle)
#   Session B: BEGIN; xclaim.try(1, 100) -> false  (conflict with A),
#              the same try again -> false, xclaim.count() -> 0: the
#              failed try leaves nothing in B's local set
#   Session A: ROLLBACK
#   Session B (new): xclaim.try(1, 100) -> true  (now available)
#
# Synchronization strategy:
#   Session A is a holder session (_lib.sh): the test sends it statements one
#   at a time and waits for each result, so A holds the claim exactly from
#   its try until its ROLLBACK, whatever the machine speed.
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

trap pg_xclaim_stop_temp_cluster EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Test 1: Session A acquires (1,100) and stays in its transaction.
#         Session B tries the same key -> should get false.
# ---------------------------------------------------------------------------
echo "--- Test 1: conflict between two sessions ---"

xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'claim=' || xclaim.try(1, 100);"
A_CLAIM=""
if xclaim_holder_wait '^claim=(true|false)$'; then
    A_CLAIM="$(sed -n 's/^claim=//p' "$XCLAIM_HOLDER_OUT")"
fi
echo "  Session A xclaim.try(1,100): ${A_CLAIM:-none}"
if [[ "$A_CLAIM" == "true" ]]; then
    echo "  PASS: Session A holds the claim"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflict_a_true" "PASS" "result" "true" "A acquired")")
else
    echo "  FAIL: Session A expected true, got '${A_CLAIM:-none}', output follows:" >&2
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflict_a_true" "FAIL" "result" "${A_CLAIM:-none}" "A should have acquired")")
fi

# Session B: try to acquire same key while A holds it, twice in one
# transaction. xclaim.try is non-blocking: returns false immediately if
# conflict. The second try must reach shared memory again: an entry left
# in B's local set by the first one would make it return true without
# a shared row.
SESSION_B_RESULT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 2>&1 <<'SQLB'
BEGIN;
SELECT 'try1=' || xclaim.try(1, 100);
SELECT 'try2=' || xclaim.try(1, 100);
SELECT 'count=' || xclaim.count();
ROLLBACK;
SQLB
)" || true
B_TRY_RESULT="$(sed -n 's/^try1=//p' <<<"$SESSION_B_RESULT")"
B_RETRY_RESULT="$(sed -n 's/^try2=//p' <<<"$SESSION_B_RESULT")"
B_COUNT="$(sed -n 's/^count=//p' <<<"$SESSION_B_RESULT")"
echo "  Session B xclaim.try(1,100) while A holds: ${B_TRY_RESULT:-none}, again: ${B_RETRY_RESULT:-none}, xclaim.count(): ${B_COUNT:-none}"

if [[ "$B_TRY_RESULT" == "false" ]]; then
    echo "  PASS: Session B correctly got false (conflict)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflict_b_false" "PASS" "result" "false" "B saw conflict as expected")")
else
    echo "  FAIL: Session B expected false, got '${B_TRY_RESULT:-none}', output follows:" >&2
    printf '%s\n' "$SESSION_B_RESULT" | sed 's/^/    /' >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflict_b_false" "FAIL" "result" "${B_TRY_RESULT:-none}" "B should have seen conflict")")
fi

if [[ "$B_RETRY_RESULT" == "false" && "$B_COUNT" == "0" ]]; then
    echo "  PASS: the second try in the same transaction is false and B holds nothing"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflict_b_retry" "PASS" "result" "false/0" "failed try left no local entry")")
else
    echo "  FAIL: the second try must be false with xclaim.count() 0 (got ${B_RETRY_RESULT:-none}/${B_COUNT:-none})" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflict_b_retry" "FAIL" "result" "${B_RETRY_RESULT:-none}/${B_COUNT:-none}" "failed try must leave no local entry")")
fi

# Session A releases: ROLLBACK, then a marker that shows the ROLLBACK is done.
xclaim_holder_sql "ROLLBACK;"
xclaim_holder_sql "SELECT 'rolled_back';"
if ! xclaim_holder_wait '^rolled_back$'; then
    echo "  FAIL: Session A did not finish its ROLLBACK, output follows:" >&2
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflict_a_rollback" "FAIL" "result" "none" "ROLLBACK not confirmed")")
fi
xclaim_holder_close

# ---------------------------------------------------------------------------
# Test 2: After A releases (ROLLBACK), B can acquire
# ---------------------------------------------------------------------------
echo "--- Test 2: after A releases, B succeeds ---"

# A has rolled back. B should succeed.
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
# Session B conflicted twice while A held the key.
if [[ "$CONFLICTS" == "2" ]]; then
    echo "  PASS: conflicts counter incremented ($CONFLICTS)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflicts_incremented" "PASS" "conflicts" "$CONFLICTS" "conflict recorded")")
else
    echo "  FAIL: conflicts counter must be 2 (got ${CONFLICTS:-none})" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "conflicts_incremented" "FAIL" "conflicts" "${CONFLICTS:-none}" "should be 2")")
fi

# Every local entry released at transaction end had its shared row: a
# failed try that left a local entry would show up here as a miss.
MISSES="$(pg_xclaim_psql -X -A -t -c "SELECT cleanup_misses FROM xclaim.stats();" 2>/dev/null | tr -d ' ')"
echo "  xclaim.stats().cleanup_misses = ${MISSES:-none}"
if [[ "$MISSES" == "0" ]]; then
    echo "  PASS: no cleanup misses"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "cleanup_misses" "PASS" "cleanup_misses" "0" "every local entry had its shared row")")
else
    echo "  FAIL: cleanup_misses must be 0 (got ${MISSES:-none})" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "cleanup_misses" "FAIL" "cleanup_misses" "${MISSES:-none}" "should be 0")")
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
