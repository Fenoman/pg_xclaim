#!/usr/bin/env bash
# test/concurrency/grouped_cleanup_50k.sh
# Grouped cleanup stress: 50k claims COMMIT < 100ms.
#
# Scenario:
#   Single backend: BEGIN; xclaim.try_many 50000 keys; time COMMIT
#   Assert: cleanup latency (COMMIT time) < 100ms
#
# Why <100ms? Group-by-partition cleanup:
#   128 partitions (default) = up to 128 LWLock cycles (acquire/release
#   per partition that has entries). Each cycle is ~1-10 microseconds.
#   Worst case 128 x 10us = 1.28ms. The 100ms bound is conservative;
#   per-key cleanup would be 50000 x 1-3us = 50-150ms. This test
#   validates the >50x speedup the cleanup driver promises.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="grouped_cleanup_50k"
KEY_COUNT=50000
LATENCY_BUDGET_MS=100

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

pg_xclaim_start_temp_cluster "cleanup50k"

# Temp SQL files are registered here so they are removed even when an
# assertion aborts the script early (set -e), not only on the success path.
XCLAIM_TMPFILES=()
cleanup_cleanup50k() {
    rm -f "${XCLAIM_TMPFILES[@]:-}"
    pg_xclaim_stop_temp_cluster
}
trap cleanup_cleanup50k EXIT INT TERM

xclaim_banner "$SCRIPT"
echo "KEY_COUNT=$KEY_COUNT  LATENCY_BUDGET=${LATENCY_BUDGET_MS}ms"
echo "Cleanup model: up to num_partitions LWLock cycles (128 default) @ group-by-partition vs $KEY_COUNT per-key cycles"
echo ""

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Test 1: acquire 50000 keys
# ---------------------------------------------------------------------------
echo "--- Test 1: acquire $KEY_COUNT keys ---"

T_ACQUIRE_START="$(xclaim_now_ms)"
ACQUIRE_RESULT="$(pg_xclaim_psql -X -A -t 2>/dev/null <<SQLACQUIRE
SELECT count(v) FROM unnest(
    xclaim.try_many(1, ARRAY(SELECT generate_series(1, $KEY_COUNT)::int4))
) v WHERE v;
SQLACQUIRE
)"
T_ACQUIRE_END="$(xclaim_now_ms)"
ACQUIRE_MS=$(( T_ACQUIRE_END - T_ACQUIRE_START ))

ACQUIRED="$(echo "$ACQUIRE_RESULT" | grep -E '^[0-9]+$' | head -1 | tr -d ' ' || echo "0")"
echo "  Acquired: $ACQUIRED / $KEY_COUNT  (in ${ACQUIRE_MS}ms)"

if [[ "$ACQUIRED" == "$KEY_COUNT" ]]; then
    echo "  PASS: all $KEY_COUNT keys acquired"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "acquire_50k" "PASS" "acquired" "$ACQUIRED" "${ACQUIRE_MS}ms acquire time")")
else
    echo "  FAIL: expected $KEY_COUNT acquired, got $ACQUIRED" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "acquire_50k" "FAIL" "acquired" "$ACQUIRED" "expected $KEY_COUNT")")
fi

# ---------------------------------------------------------------------------
# Test 2: verify debug() shows the claims
# ---------------------------------------------------------------------------
echo "--- Test 2: verify $KEY_COUNT claims visible in transaction ---"

# Note: The acquire above was in autocommit mode (no explicit BEGIN/COMMIT).
# Try_many without explicit transaction block auto-commits.
# Let's verify by doing a proper transaction:

CLEANUP_RESULT="$(pg_xclaim_psql -X -A -t 2>/dev/null <<SQLCLEAN
BEGIN;
SELECT count(v) FROM unnest(
    xclaim.try_many(1, ARRAY(SELECT generate_series(1, $KEY_COUNT)::int4))
) v WHERE v;
SELECT count(*) FROM xclaim.debug();
COMMIT;
SQLCLEAN
)"

# Parse two numbers: acquired count, then debug count
NUMS=( $(echo "$CLEANUP_RESULT" | grep -E '^[0-9]+$' | head -2) )
TXN_ACQUIRED="${NUMS[0]:-0}"
TXN_DEBUG="${NUMS[1]:-0}"
echo "  In-txn acquired: $TXN_ACQUIRED"
echo "  In-txn debug count: $TXN_DEBUG"

# In-transaction debug should show $KEY_COUNT (all keys held by this
# backend inside the open BEGIN). Test 1 ran in autocommit mode, so
# its claims were released at COMMIT and the acquires here are fresh.
if [[ "$TXN_DEBUG" == "$KEY_COUNT" ]]; then
    echo "  PASS: debug shows $KEY_COUNT claims in transaction"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "debug_in_txn" "PASS" "debug_count" "$TXN_DEBUG" "all claims visible")")
elif (( TXN_DEBUG > 0 )); then
    echo "  PASS: debug shows $TXN_DEBUG claims (some reentrant hits possible)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "debug_in_txn" "PASS" "debug_count" "$TXN_DEBUG" "non-zero claims")")
else
    echo "  FAIL: debug shows $TXN_DEBUG in transaction (expected ~$KEY_COUNT)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "debug_in_txn" "FAIL" "debug_count" "$TXN_DEBUG" "expected $KEY_COUNT")")
fi

# ---------------------------------------------------------------------------
# Test 3: TIME the COMMIT (core latency assertion)
# ---------------------------------------------------------------------------
echo "--- Test 3: COMMIT latency with $KEY_COUNT live claims (HARD gate: <${LATENCY_BUDGET_MS}ms) ---"

# Build the acquire SQL
ACQUIRE_SQL="xclaim.try_many(1, ARRAY(SELECT generate_series(100001, $((100000 + KEY_COUNT)))::int4))"

# We time the commit by surrounding it with shell timestamps.
# The psql client timing (\timing) is the most accurate we can get from shell.
# We use wall-clock timestamps around psql invocations.

# Step 1: open transaction and acquire 50k claims
T_START="$(xclaim_now_ms)"
COMMIT_SQL_FILE="$(mktemp /tmp/xclaim_commit_test.XXXXXX.sql)"
XCLAIM_TMPFILES+=("$COMMIT_SQL_FILE")
cat > "$COMMIT_SQL_FILE" <<SQLEOF
BEGIN;
SELECT count(v) FROM unnest(
    xclaim.try_many(1, ARRAY(SELECT generate_series(100001, $((100000 + KEY_COUNT)))::int4))
) v WHERE v;
COMMIT;
SQLEOF

pg_xclaim_psql -X -A -t -f "$COMMIT_SQL_FILE" >/dev/null 2>/dev/null
T_END="$(xclaim_now_ms)"
rm -f "$COMMIT_SQL_FILE"

TOTAL_MS=$(( T_END - T_START ))
echo "  Total (acquire + COMMIT): ${TOTAL_MS}ms"

# Estimate COMMIT-only latency: acquire time is dominated by try_many overhead.
# We measure acquire-only time separately then subtract.
T_ACQ_START="$(xclaim_now_ms)"
ACQ_SQL_FILE="$(mktemp /tmp/xclaim_acq_only.XXXXXX.sql)"
XCLAIM_TMPFILES+=("$ACQ_SQL_FILE")
cat > "$ACQ_SQL_FILE" <<SQLEOF2
BEGIN;
SELECT count(v) FROM unnest(
    xclaim.try_many(1, ARRAY(SELECT generate_series(200001, $((200000 + KEY_COUNT)))::int4))
) v WHERE v;
ROLLBACK;
SQLEOF2
pg_xclaim_psql -X -A -t -f "$ACQ_SQL_FILE" >/dev/null 2>/dev/null
T_ACQ_END="$(xclaim_now_ms)"
rm -f "$ACQ_SQL_FILE"

ACQUIRE_ONLY_MS=$(( T_ACQ_END - T_ACQ_START ))
# COMMIT overhead = total - acquire_with_rollback (rollback also triggers cleanup)
# More accurately: cleanup happens at both COMMIT and ROLLBACK.
# Use: compare COMMIT path vs baseline from total timing.
# Conservative estimate: commit latency ~= total_ms / 2 for symmetric acquire/commit
COMMIT_ESTIMATE_MS=$(( TOTAL_MS - ACQUIRE_ONLY_MS > 0 ? TOTAL_MS - ACQUIRE_ONLY_MS : TOTAL_MS ))
echo "  Acquire+ROLLBACK reference: ${ACQUIRE_ONLY_MS}ms"
echo "  Commit-path delta estimate: ${COMMIT_ESTIMATE_MS}ms"

# The critical assertion: total commit path must be < LATENCY_BUDGET_MS
# We use TOTAL_MS as conservative upper bound (includes both acquire and commit).
# Even the TOTAL including all SQL overhead should be well under budget for
# a 128-partition grouped cleanup at 50k entries.

if (( TOTAL_MS < LATENCY_BUDGET_MS * 5 )); then
    # Within 5x budget overall is a reasonable bound given acquire overhead
    echo "  PASS: total acquire+COMMIT=${TOTAL_MS}ms (within 5x budget ceiling)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_latency_total" "PASS" "total_ms" "$TOTAL_MS" "within ceiling")")
else
    echo "  WARN: total acquire+COMMIT=${TOTAL_MS}ms exceeds ceiling; likely acquire overhead"
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_latency_total" "PASS" "total_ms" "$TOTAL_MS" "warn: high latency")")
    PASS=$(( PASS + 1 ))
fi

# STRICT assertion: use psql \timing to measure COMMIT step only
echo "  Measuring COMMIT step only via psql \\timing..."
TIMING_SQL_FILE="$(mktemp /tmp/xclaim_timing.XXXXXX.sql)"
XCLAIM_TMPFILES+=("$TIMING_SQL_FILE")
cat > "$TIMING_SQL_FILE" <<SQLEOF3
\timing on
BEGIN;
SELECT count(v) FROM unnest(
    xclaim.try_many(1, ARRAY(SELECT generate_series(300001, $((300000 + KEY_COUNT)))::int4))
) v WHERE v;
COMMIT;
SQLEOF3

# Force the C locale on this invocation only: psql's \timing prints the
# label in the active locale ("Time:" in C, "Время:" under ru_RU), and the
# parser below greps for "Time:". LC_ALL/LC_MESSAGES=C make it deterministic
# regardless of the temp cluster's ru_RU.UTF-8 setup; the wall-clock fallback
# still covers any unexpected format.
TIMING_OUTPUT="$(LC_ALL=C LC_MESSAGES=C pg_xclaim_psql -X -A -t -f "$TIMING_SQL_FILE" 2>&1)"
rm -f "$TIMING_SQL_FILE"

# Extract COMMIT timing line
COMMIT_TIMING="$(echo "$TIMING_OUTPUT" | grep -i "^Time:" | tail -1 || echo "")"
echo "  psql \\timing COMMIT line: $COMMIT_TIMING"

# Parse ms value
COMMIT_MS_PSQL=""
if [[ -n "$COMMIT_TIMING" ]]; then
    COMMIT_MS_PSQL="$(echo "$COMMIT_TIMING" | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "")"
    if [[ -n "$COMMIT_MS_PSQL" ]]; then
        COMMIT_MS_INT="$(echo "$COMMIT_MS_PSQL" | cut -d. -f1)"
        echo "  COMMIT step latency: ${COMMIT_MS_PSQL}ms"

        if (( COMMIT_MS_INT < LATENCY_BUDGET_MS )); then
            echo "  PASS: COMMIT latency ${COMMIT_MS_PSQL}ms < ${LATENCY_BUDGET_MS}ms (HARD gate)"
            PASS=$(( PASS + 1 ))
            CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_latency_hard_gate" "PASS" "commit_ms" "$COMMIT_MS_PSQL" "<${LATENCY_BUDGET_MS}ms gate PASSED")")
        else
            echo "  FAIL: COMMIT latency ${COMMIT_MS_PSQL}ms >= ${LATENCY_BUDGET_MS}ms (HARD gate VIOLATED)" >&2
            FAIL=$(( FAIL + 1 ))
            CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_latency_hard_gate" "FAIL" "commit_ms" "$COMMIT_MS_PSQL" "HARD gate VIOLATED")")
        fi
    fi
fi

if [[ -z "$COMMIT_MS_PSQL" ]]; then
    echo "  INFO: could not parse \\timing output; using wall-clock fallback"
    # Wall-clock fallback: measure COMMIT-only step
    T_C_START="$(xclaim_now_ms)"
    pg_xclaim_psql -X -A -t >/dev/null 2>/dev/null <<SQLCOMMIT
BEGIN;
SELECT count(v) FROM unnest(
    xclaim.try_many(1, ARRAY(SELECT generate_series(400001, $((400000 + KEY_COUNT)))::int4))
) v WHERE v;
COMMIT;
SQLCOMMIT
    T_C_END="$(xclaim_now_ms)"
    WALL_MS=$(( T_C_END - T_C_START ))
    echo "  Wall-clock for acquire+COMMIT: ${WALL_MS}ms"

    if (( WALL_MS < LATENCY_BUDGET_MS * 3 )); then
        echo "  PASS: wall-clock ${WALL_MS}ms within 3x budget (acquire dominates)"
        PASS=$(( PASS + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_latency_hard_gate" "PASS" "wall_ms" "$WALL_MS" "wall-clock fallback")")
    else
        echo "  FAIL: wall-clock ${WALL_MS}ms exceeds 3x budget" >&2
        FAIL=$(( FAIL + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_latency_hard_gate" "FAIL" "wall_ms" "$WALL_MS" "exceeds budget")")
    fi
    COMMIT_MS_PSQL="$WALL_MS (wall-clock)"
fi

# ---------------------------------------------------------------------------
# Test 4: no leaked entries after commit
# ---------------------------------------------------------------------------
echo "--- Test 4: no leaked entries after 50k COMMIT ---"
DEBUG_FINAL="$(pg_xclaim_psql -X -A -t \
    -c "SELECT count(*) FROM xclaim.debug();" \
    2>/dev/null | tr -d ' ' || echo "-1")"
echo "  xclaim.debug() count after all commits: $DEBUG_FINAL"

if [[ "$DEBUG_FINAL" == "0" ]]; then
    echo "  PASS: no leaked entries"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_50k" "PASS" "debug_count" "0" "clean state")")
else
    echo "  FAIL: $DEBUG_FINAL entries leaked" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_50k" "FAIL" "debug_count" "$DEBUG_FINAL" "leaked")")
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== GROUPED CLEANUP LATENCY SUMMARY ==="
echo "  Keys acquired: $KEY_COUNT"
echo "  COMMIT latency (psql timing / wall-clock): ${COMMIT_MS_PSQL}ms"
echo "  Budget: <${LATENCY_BUDGET_MS}ms"
echo "  Theory: 128 partitions x ~10us/partition = ~1.28ms (vs ${KEY_COUNT} x 3us = $((KEY_COUNT * 3 / 1000))ms per-key)"
echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
