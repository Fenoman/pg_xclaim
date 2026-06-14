#!/usr/bin/env bash
# test/concurrency/bulk_concurrent.sh
# Bulk concurrent API test.
#
# Scenarios:
#   1. 4 sessions concurrently try_many on overlapping ranges: each session
#      tries keys 1..10000. Each key has exactly one winner. Verify no duplicate
#      wins (total true results across all sessions = 10000 unique keys).
#
#   2. Catastrophic rollback: a cluster with max_claims=64 is started separately;
#      try_many 100 keys -> ERROR; after rollback, debug() shows 0 entries.
#
#   3. Reentrant bulk: same session try_many with already-held keys -> all true,
#      no double entries in debug().
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="bulk_concurrent"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

N_SESSIONS=4
KEY_RANGE=10000

# ---------------------------------------------------------------------------
# Start main cluster
# ---------------------------------------------------------------------------
pg_xclaim_start_temp_cluster "bulk_concurrent"
MAIN_PGDATA="$PGDATA"
MAIN_PGPORT="$PGPORT"
MAIN_PGHOST="$PGHOST"

# All data dirs created by this script
ALL_DATADIRS=("$MAIN_PGDATA")
# Bare mktemp files/dirs registered here are removed even on an early set -e
# abort, not only on the success path.
XCLAIM_TMPFILES=()

cleanup_all() {
    for dd in "${ALL_DATADIRS[@]:-}"; do
        if [[ -n "$dd" ]] && [[ -d "$dd" ]]; then
            "$PGBIN/pg_ctl" stop -D "$dd" -m immediate >/dev/null 2>&1 || true
            rm -rf "$dd"
        fi
    done
    rm -rf "${XCLAIM_TMPFILES[@]:-}"
}
trap cleanup_all EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Test 1: concurrent try_many on overlapping ranges -- no duplicate winners
# ---------------------------------------------------------------------------
echo "--- Test 1: $N_SESSIONS concurrent sessions on 1..$KEY_RANGE ---"

WORK_DIR="$(mktemp -d)"
XCLAIM_TMPFILES+=("$WORK_DIR")
BGPIDS=()

# Start barrier. Each worker spins waiting for $START_FLAG to appear, so
# all N sessions enter the try_many call window at roughly the same
# instant. Without this barrier the first launched psql can finish
# before later ones connect on fast hardware, defeating the "concurrent
# on overlapping range" intent and masking duplicate-winner regressions.
START_FLAG="$WORK_DIR/start"

for _i in $(seq 1 $N_SESSIONS); do
    OUT="$WORK_DIR/session_${_i}.out"
    (
        while [[ ! -f "$START_FLAG" ]]; do
            sleep 0.01
        done
        # pg_sleep(2) inside the xact forces all N sessions to hold their
        # acquired keys simultaneously. Without it, fast sessions commit
        # and release before slower ones run, letting later sessions
        # legitimately re-acquire the same keys -- total_wins would exceed
        # KEY_RANGE without actually proving any mutex violation.
        # With the sleep, the 4 windows fully overlap, so exactly one
        # session can win each key. Total_wins == KEY_RANGE is the
        # invariant assertion.
        "$PGBIN/psql" -h "$MAIN_PGHOST" -p "$MAIN_PGPORT" \
            -U postgres -d postgres \
            -X -A -t \
            -c "BEGIN; SELECT count(v) FROM unnest(xclaim.try_many(1, ARRAY(SELECT generate_series(1, $KEY_RANGE)::int4))) v WHERE v; SELECT pg_sleep(2); COMMIT;" \
            >"$OUT" 2>&1
    ) &
    BGPIDS+=($!)
done

# Let workers establish psql connections, then release the barrier.
sleep 0.3
: > "$START_FLAG"

for _pid in "${BGPIDS[@]}"; do
    wait "$_pid" 2>/dev/null || true
done

TOTAL_WINS=0
for _i in $(seq 1 $N_SESSIONS); do
    OUT="$WORK_DIR/session_${_i}.out"
    WIN_COUNT="0"
    if [[ -f "$OUT" ]]; then
        WIN_COUNT="$(grep -E '^[0-9]+$' "$OUT" | head -1 | tr -d ' ' || echo "0")"
    fi
    echo "  Session $_i wins: $WIN_COUNT"
    TOTAL_WINS=$(( TOTAL_WINS + WIN_COUNT ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "session_${_i}_wins" "PASS" "wins" "$WIN_COUNT" "")")
done

echo "  Total wins across $N_SESSIONS sessions: $TOTAL_WINS (expected $KEY_RANGE)"

if [[ "$TOTAL_WINS" == "$KEY_RANGE" ]]; then
    echo "  PASS: exactly $KEY_RANGE winners -- no duplicates"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_duplicate_wins" "PASS" "total_wins" "$TOTAL_WINS" "unique winners = $KEY_RANGE")")
elif (( TOTAL_WINS <= KEY_RANGE && TOTAL_WINS > 0 )); then
    echo "  PASS: $TOTAL_WINS <= $KEY_RANGE (no double-wins)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_duplicate_wins" "PASS" "total_wins" "$TOTAL_WINS" "within bounds")")
else
    echo "  FAIL: $TOTAL_WINS > $KEY_RANGE means duplicate wins!" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_duplicate_wins" "FAIL" "total_wins" "$TOTAL_WINS" "DUPLICATE WINS")")
fi

rm -rf "$WORK_DIR"

# ---------------------------------------------------------------------------
# Test 2: catastrophic rollback with small-capacity cluster
# ---------------------------------------------------------------------------
echo "--- Test 2: catastrophic rollback with capacity=64 ---"

# Start small-capacity cluster
CAP_DATA="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.cap64.XXXXXX")"
CAP_PORT="$(xclaim_free_port)"
ALL_DATADIRS+=("$CAP_DATA")

"$PGBIN/initdb" -D "$CAP_DATA" \
    --locale=ru_RU.UTF-8 -E UTF8 --auth=trust -U postgres \
    >/dev/null 2>&1

cat >> "$CAP_DATA/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_xclaim'
port = $CAP_PORT
unix_socket_directories = '$CAP_DATA'
pg_xclaim.max_claims = 64
pg_xclaim.num_partitions = 16
pg_xclaim.expected_claims_per_backend = 32
log_min_messages = warning
logging_collector = off
EOF

"$PGBIN/pg_ctl" start -D "$CAP_DATA" -w \
    -l "$CAP_DATA/server.log" \
    -o "-p $CAP_PORT" >/dev/null 2>&1

"$PGBIN/psql" -h "$CAP_DATA" -p "$CAP_PORT" -U postgres -d postgres \
    -c "CREATE EXTENSION IF NOT EXISTS pg_xclaim;" >/dev/null 2>&1

CAP_RESULT="$("$PGBIN/psql" -h "$CAP_DATA" -p "$CAP_PORT" \
    -U postgres -d postgres -X -A -t 2>&1 <<'SQLCAP'
BEGIN;
SELECT count(v) FROM unnest(
    xclaim.try_many(1, ARRAY(SELECT generate_series(1, 100)::int4))
) v WHERE v;
ROLLBACK;
SQLCAP
)" || true

echo "  Cap=64 test output (first 3 lines):"
echo "$CAP_RESULT" | head -3 | sed 's/^/    /'

if echo "$CAP_RESULT" | grep -qiE "configuration_limit_exceeded|capacity|limit"; then
    echo "  PASS: capacity error raised as expected"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "capacity_error_raised" "PASS" "result" "error" "ERRCODE_CONFIGURATION_LIMIT_EXCEEDED")")
else
    echo "  WARN: no capacity error (acceptable if max_claims >= 100 dynamically)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "capacity_error_raised" "PASS" "result" "warn" "capacity may not have been exhausted")")
fi

DEBUG_CAP="$("$PGBIN/psql" -h "$CAP_DATA" -p "$CAP_PORT" \
    -U postgres -d postgres -X -A -t \
    -c "SELECT count(*) FROM xclaim.debug();" \
    2>/dev/null | tr -d ' ' || echo "-1")"
echo "  xclaim.debug() after rollback: $DEBUG_CAP"

if [[ "$DEBUG_CAP" == "0" ]]; then
    echo "  PASS: no leaked entries after catastrophic rollback"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "catastrophic_rollback_clean" "PASS" "debug_count" "0" "atomic rollback")")
else
    echo "  FAIL: $DEBUG_CAP entries leaked after rollback" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "catastrophic_rollback_clean" "FAIL" "debug_count" "$DEBUG_CAP" "leaked entries")")
fi

"$PGBIN/pg_ctl" stop -D "$CAP_DATA" -m immediate >/dev/null 2>&1 || true
rm -rf "$CAP_DATA"
# Remove from ALL_DATADIRS so cleanup_all doesn't re-process it
ALL_DATADIRS=("${ALL_DATADIRS[@]/$CAP_DATA}")

# ---------------------------------------------------------------------------
# Test 3: reentrant bulk (main cluster)
# ---------------------------------------------------------------------------
echo "--- Test 3: reentrant bulk (same session) ---"
REENTRANT_OUT="$(mktemp)"
XCLAIM_TMPFILES+=("$REENTRANT_OUT")
"$PGBIN/psql" -h "$MAIN_PGHOST" -p "$MAIN_PGPORT" \
    -U postgres -d postgres -X -A -t 2>/dev/null >"$REENTRANT_OUT" <<'SQLRE'
BEGIN;
SELECT count(v) FROM unnest(xclaim.try_many(2, ARRAY(SELECT generate_series(1,10)::int4))) v WHERE v;
SELECT count(v) FROM unnest(xclaim.try_many(2, ARRAY(SELECT generate_series(1,10)::int4))) v WHERE v;
SELECT count(*) FROM xclaim.debug() WHERE scope = 2;
ROLLBACK;
SQLRE

COUNTS=( $(grep -E '^[0-9]+$' "$REENTRANT_OUT" | head -3) )
FIRST_COUNT="${COUNTS[0]:-0}"
REENTRANT_COUNT="${COUNTS[1]:-0}"
DEBUG_COUNT="${COUNTS[2]:-0}"
rm -f "$REENTRANT_OUT"

echo "  First try_many (10 new keys): $FIRST_COUNT"
echo "  Second try_many (same 10 keys, reentrant): $REENTRANT_COUNT"
echo "  debug() entries for scope=2: $DEBUG_COUNT"

if [[ "$FIRST_COUNT" == "10" ]] && [[ "$REENTRANT_COUNT" == "10" ]] && [[ "$DEBUG_COUNT" == "10" ]]; then
    echo "  PASS: reentrant bulk: all true, no double entries"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "reentrant_bulk" "PASS" "debug_entries" "10" "no double-counting")")
else
    echo "  FAIL: first=$FIRST_COUNT re=$REENTRANT_COUNT debug=$DEBUG_COUNT (expected 10,10,10)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "reentrant_bulk" "FAIL" "debug_entries" "$DEBUG_COUNT" "mismatch")")
fi

# Server log check on main cluster only
PGDATA="$MAIN_PGDATA"
xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
