#!/usr/bin/env bash
# test/concurrency/grouped_cleanup_50k.sh
# Grouped cleanup stress: 50k claims COMMIT < 100ms.
#
# Scenario:
#   Single backend: BEGIN, xclaim.try_many 50000 keys, time COMMIT
#   Assert: cleanup latency (COMMIT time) < 100ms
#
# Why <100ms? Group-by-partition cleanup:
#   128 partitions (default) = up to 128 LWLock cycles (acquire/release
#   per partition that has entries). Each cycle is ~1-10 microseconds.
#   Worst case 128 x 10us = 1.28ms. This counts the lock cycles only:
#   the 50000 HASH_FIND + HASH_REMOVE pairs made under those locks come
#   on top. The 100ms bound is conservative.
#   Per-key cleanup would be 50000 x 1-3us = 50-150ms. The latency
#   checks are absolute bounds (see Test 3): the test runs no per-key
#   cleanup to compare against, so it measures no speedup ratio.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="grouped_cleanup_50k"
KEY_COUNT=50000
LATENCY_BUDGET_MS=100

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

XCLAIM_TMPFILES=()
cleanup_cleanup50k() {
    rm -f "${XCLAIM_TMPFILES[@]:-}"
    pg_xclaim_stop_temp_cluster
}
trap cleanup_cleanup50k EXIT INT TERM

pg_xclaim_start_temp_cluster "cleanup50k"

xclaim_banner "$SCRIPT"
echo "KEY_COUNT=$KEY_COUNT  LATENCY_BUDGET=${LATENCY_BUDGET_MS}ms"
echo "Cleanup model: up to num_partitions LWLock cycles (128 default) @ group-by-partition vs $KEY_COUNT per-key cycles"
echo ""

PASS=0
FAIL=0
CSV_ROWS=()

# Measured transactions.
#
# measured_psql runs a SQL file with ON_ERROR_STOP and keeps the exit status
# in MEASURED_RC and the output in MEASURED_OUT, so the caller takes the end
# timestamp right after psql. The C locale keeps the \timing label "Time:"
# (under ru_RU it is "Время:").
#
# check_measured requires exit status 0 and the line acquired=KEY_COUNT,
# printed inside the measured transaction: a transaction that failed or took
# fewer claims has no cleanup cost worth timing.
measured_psql() {  # sql file
    MEASURED_RC=0
    MEASURED_OUT="$(LC_ALL=C LC_MESSAGES=C pg_xclaim_psql -X -A -t \
        -v ON_ERROR_STOP=1 -f "$1" 2>&1)" || MEASURED_RC=$?
}
check_measured() {  # label
    local got
    got="$(sed -n 's/^acquired=//p' <<<"$MEASURED_OUT" | head -1)"
    if (( MEASURED_RC == 0 )) && [[ "$got" == "$KEY_COUNT" ]]; then
        return 0
    fi
    echo "  FAIL: $1: psql exit $MEASURED_RC, acquired '${got:-none}' (expected $KEY_COUNT), output follows:" >&2
    printf '%s\n' "$MEASURED_OUT" | sed 's/^/    /' >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$1" "FAIL" "acquired" "${got:-none}" "psql exit $MEASURED_RC")")
    return 1
}

# ---------------------------------------------------------------------------
# Test 1: acquire 50000 keys
# ---------------------------------------------------------------------------
echo "--- Test 1: acquire $KEY_COUNT keys ---"

T_ACQUIRE_START="$(xclaim_now_ms)"
ACQUIRE_RESULT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 <<SQLACQUIRE
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

CLEANUP_RESULT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 <<SQLCLEAN
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
else
    echo "  FAIL: debug shows $TXN_DEBUG in transaction (expected $KEY_COUNT)" >&2
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
SELECT 'acquired=' || count(v) FROM unnest(
    xclaim.try_many(1, ARRAY(SELECT generate_series(100001, $((100000 + KEY_COUNT)))::int4))
) v WHERE v;
COMMIT;
SQLEOF

measured_psql "$COMMIT_SQL_FILE"
T_END="$(xclaim_now_ms)"
rm -f "$COMMIT_SQL_FILE"
TOTAL_OK=true
check_measured "commit_latency_total" || TOTAL_OK=false

TOTAL_MS=$(( T_END - T_START ))
echo "  Total (acquire + COMMIT): ${TOTAL_MS}ms"

# Estimate COMMIT-only latency: acquire time is dominated by try_many overhead.
# We measure acquire-only time separately then subtract.
T_ACQ_START="$(xclaim_now_ms)"
ACQ_SQL_FILE="$(mktemp /tmp/xclaim_acq_only.XXXXXX.sql)"
XCLAIM_TMPFILES+=("$ACQ_SQL_FILE")
cat > "$ACQ_SQL_FILE" <<SQLEOF2
BEGIN;
SELECT 'acquired=' || count(v) FROM unnest(
    xclaim.try_many(1, ARRAY(SELECT generate_series(200001, $((200000 + KEY_COUNT)))::int4))
) v WHERE v;
ROLLBACK;
SQLEOF2
measured_psql "$ACQ_SQL_FILE"
T_ACQ_END="$(xclaim_now_ms)"
rm -f "$ACQ_SQL_FILE"
ACQ_REF_OK=true
check_measured "rollback_reference" || ACQ_REF_OK=false

ACQUIRE_ONLY_MS=$(( T_ACQ_END - T_ACQ_START ))
# Both COMMIT and ROLLBACK run cleanup, so clamp scheduling noise at 0ms.
COMMIT_ESTIMATE_MS=$(( TOTAL_MS > ACQUIRE_ONLY_MS ? TOTAL_MS - ACQUIRE_ONLY_MS : 0 ))
echo "  Acquire+ROLLBACK reference: ${ACQUIRE_ONLY_MS}ms"
echo "  Commit-vs-rollback delta:   ${COMMIT_ESTIMATE_MS}ms"

# Ceiling on the whole acquire + COMMIT transaction, connection included:
# 5x LATENCY_BUDGET_MS. TOTAL_MS is a conservative upper bound of the commit
# path, and even with all SQL overhead it stays well under the ceiling for a
# 128-partition grouped cleanup at 50k entries.
if ! $TOTAL_OK; then
    : # check_measured has counted the FAIL
elif (( TOTAL_MS < LATENCY_BUDGET_MS * 5 )); then
    echo "  PASS: total acquire+COMMIT=${TOTAL_MS}ms (within 5x budget ceiling)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_latency_total" "PASS" "total_ms" "$TOTAL_MS" "within ceiling")")
else
    echo "  FAIL: total acquire+COMMIT=${TOTAL_MS}ms exceeds the $(( LATENCY_BUDGET_MS * 5 ))ms ceiling (5x budget)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_latency_total" "FAIL" "total_ms" "$TOTAL_MS" "exceeds 5x budget")")
fi

# STRICT assertion: measure server-side 50k acquire+COMMIT AND pure COMMIT step
# via clock_timestamp() inside a PL/pgSQL PROCEDURE (no psql startup or
# generate_series array-construction overhead). Both must be < 100ms.
echo "  Measuring server-side 50k acquire+COMMIT and COMMIT step via PL/pgSQL PROCEDURE..."
COMMIT_MS_RAW="$(pg_xclaim_psql -X -A -t -q -F'|' -v ON_ERROR_STOP=1 <<SQLPROC
CREATE UNLOGGED TABLE commit_50k_bench (keys int4[], total_srv_ms numeric, commit_ms numeric);
INSERT INTO commit_50k_bench(keys)
SELECT array_agg(g::int4) FROM generate_series(300001, $((300000 + KEY_COUNT))) g;

CREATE PROCEDURE measure_commit_50k() LANGUAGE plpgsql AS \$\$
DECLARE
    k int4[];
    n int;
    t_acq timestamptz;
    t0    timestamptz;
    t1    timestamptz;
BEGIN
    SELECT keys INTO k FROM commit_50k_bench;
    t_acq := clock_timestamp();
    SELECT count(v) INTO n FROM unnest(xclaim.try_many(1, k)) v WHERE v;
    IF n <> $KEY_COUNT THEN
        RAISE EXCEPTION 'expected % claims, got %', $KEY_COUNT, n;
    END IF;
    t0 := clock_timestamp();
    COMMIT;
    t1 := clock_timestamp();
    UPDATE commit_50k_bench
       SET total_srv_ms = round(extract(epoch FROM (t1 - t_acq)) * 1000.0, 3),
           commit_ms    = round(extract(epoch FROM (t1 - t0)) * 1000.0, 3);
END;
\$\$;

CALL measure_commit_50k();
SELECT total_srv_ms, commit_ms FROM commit_50k_bench;
DROP PROCEDURE measure_commit_50k();
DROP TABLE commit_50k_bench;
SQLPROC
)"
SRV_LINE="$(echo "$COMMIT_MS_RAW" | grep -E '^[0-9]+(\.[0-9]+)?\|[0-9]+(\.[0-9]+)?$' | tail -1)"
SRV_TOTAL_MS="${SRV_LINE%%|*}"
COMMIT_MS_PSQL="${SRV_LINE##*|}"
echo "  Server-side 50k acquire+COMMIT: ${SRV_TOTAL_MS:-none}ms, COMMIT step: ${COMMIT_MS_PSQL:-none}ms"

ACQ_GATE_STATUS="FAIL"
CMT_GATE_STATUS="FAIL"
[[ -n "$SRV_TOTAL_MS" ]] && awk -v v="$SRV_TOTAL_MS" -v b="$LATENCY_BUDGET_MS" 'BEGIN { exit !(v < b) }' && ACQ_GATE_STATUS="PASS"
[[ -n "$COMMIT_MS_PSQL" ]] && awk -v v="$COMMIT_MS_PSQL" -v b="$LATENCY_BUDGET_MS" 'BEGIN { exit !(v < b) }' && CMT_GATE_STATUS="PASS"
CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "acquire_commit_hard_gate" "$ACQ_GATE_STATUS" "acquire_commit_srv_ms" "${SRV_TOTAL_MS:-0}" "<${LATENCY_BUDGET_MS}ms gate $ACQ_GATE_STATUS")")
CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "commit_step_hard_gate" "$CMT_GATE_STATUS" "commit_step_srv_ms" "${COMMIT_MS_PSQL:-0}" "<${LATENCY_BUDGET_MS}ms gate $CMT_GATE_STATUS")")
if [[ "$ACQ_GATE_STATUS" == "PASS" && "$CMT_GATE_STATUS" == "PASS" ]]; then
    echo "  PASS: server acquire+COMMIT ${SRV_TOTAL_MS}ms and COMMIT ${COMMIT_MS_PSQL}ms both < ${LATENCY_BUDGET_MS}ms (HARD gate)"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: acquire+COMMIT '${SRV_TOTAL_MS:-none}'ms or COMMIT '${COMMIT_MS_PSQL:-none}'ms >= ${LATENCY_BUDGET_MS}ms (HARD gate VIOLATED)" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---------------------------------------------------------------------------
# Test 4: no leaked entries after commit
# ---------------------------------------------------------------------------
echo "--- Test 4: no leaked entries after 50k COMMIT ---"
DEBUG_FINAL="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 \
    -c "SELECT count(*) FROM xclaim.debug();" | tr -d ' ')"
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
echo "  Acquire+COMMIT / COMMIT latency (server clock_timestamp): ${SRV_TOTAL_MS}ms / ${COMMIT_MS_PSQL}ms"
echo "  Budget: <${LATENCY_BUDGET_MS}ms"
echo "  Theory: 128 partitions x ~10us/partition = ~1.28ms (vs ${KEY_COUNT} x 3us = $((KEY_COUNT * 3 / 1000))ms per-key)"
echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
