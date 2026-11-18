#!/usr/bin/env bash
# test/concurrency/reaper_contention.sh
# 8 concurrent backends race to reap the exact same 500 stale keys.
#
# Scenario:
#   1. Seed 500 stale entries (scope = 7, key = 1..500) via xclaim_test_hooks.
#   2. Gate 8 worker sessions on a shared barrier, then release all 8 at once
#      to execute xclaim.try_many(7, array(1..500)) and hold their claims
#      until a second barrier so no worker releases before others finish.
#   3. Assert: total wins == 500, distinct won keys == 500 (at most 1 winner
#      per key), reaped_stale delta == 500, capacity_used == 500 while held,
#      and 0 rows / 0 capacity_used / 0 cleanup_misses after all 8 COMMIT.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="reaper_contention"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

XCLAIM_TMPFILES=()
cleanup_reaper_race() {
    rm -rf "${XCLAIM_TMPFILES[@]:-}"
    pg_xclaim_stop_temp_cluster
}
trap cleanup_reaper_race EXIT INT TERM

xclaim_build_test_hooks
XCLAIM_EXTRA_CONF="${XCLAIM_EXTRA_CONF:+$XCLAIM_EXTRA_CONF
}lc_messages = 'C'"
pg_xclaim_start_temp_cluster "reaper_race"
xclaim_create_test_hooks_functions

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()
N_WORKERS=8
N_KEYS=500

pass() {
    echo "  PASS: $4"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$1" "PASS" "$2" "$3" "$4")")
}
fail() {
    echo "  FAIL: $4 (got $3)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$1" "FAIL" "$2" "$3" "$4")")
}

pg_xclaim_psql -X -q -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE UNLOGGED TABLE reaper_ready (worker_id int PRIMARY KEY);
CREATE UNLOGGED TABLE reaper_wins (worker_id int NOT NULL, k int NOT NULL);
SELECT xclaim_test_inject_stale(7, g) FROM generate_series(1, $N_KEYS) g;
SQL

REAPED_BEFORE="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 -c "SELECT reaped_stale FROM xclaim.stats();" | tr -d ' ')"

# Gate controller holds two advisory locks (start gate 777001, commit gate 777002).
xclaim_holder_open
xclaim_holder_sql "SELECT pg_advisory_lock(777001), pg_advisory_lock(777002);"
xclaim_holder_sql "SELECT 'gates=locked';"
xclaim_holder_wait '^gates=locked$'

WORKER_PIDS=()
WDIR="$(mktemp -d /tmp/xclaim_reaper_workers.XXXXXX)"
XCLAIM_TMPFILES+=("$WDIR")

for w in $(seq 1 "$N_WORKERS"); do
    pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 >"$WDIR/w_${w}.out" 2>&1 <<SQLW &
INSERT INTO reaper_ready VALUES ($w);
SELECT pg_advisory_lock_shared(777001);
SELECT pg_advisory_unlock_shared(777001);
BEGIN;
WITH res AS (
    SELECT g, ok
    FROM unnest(
        ARRAY(SELECT generate_series(1, $N_KEYS)::int4),
        xclaim.try_many(7, ARRAY(SELECT generate_series(1, $N_KEYS)::int4))
    ) AS t(g, ok)
)
INSERT INTO reaper_wins(worker_id, k)
SELECT $w, g FROM res WHERE ok;
SELECT pg_advisory_lock_shared(777002);
SELECT pg_advisory_unlock_shared(777002);
COMMIT;
SQLW
    WORKER_PIDS+=("$!")
done

# Wait until all 8 workers are parked on start gate 777001.
READY=0
WAITERS=0
for _ in $(seq 1 400); do
    READY="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM reaper_ready;" | tr -d ' ')"
    WAITERS="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = 777001 AND NOT granted;" | tr -d ' ')"
    if [[ "$READY" == "$N_WORKERS" && "$WAITERS" == "$N_WORKERS" ]]; then
        break
    fi
    sleep 0.02
done
START_GATE_OK=no
[[ "$READY" == "$N_WORKERS" && "$WAITERS" == "$N_WORKERS" ]] && START_GATE_OK=yes

# Release start gate simultaneously!
xclaim_holder_sql "SELECT pg_advisory_unlock(777001);"

# Wait until all 8 workers have finished try_many and parked on commit gate 777002.
COMMIT_WAITERS=0
for _ in $(seq 1 400); do
    COMMIT_WAITERS="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = 777002 AND NOT granted;" | tr -d ' ')"
    [[ "$COMMIT_WAITERS" == "$N_WORKERS" ]] && break
    sleep 0.02
done
COMMIT_GATE_OK=no
[[ "$COMMIT_WAITERS" == "$N_WORKERS" ]] && COMMIT_GATE_OK=yes

MID_STATE="$(pg_xclaim_psql -X -A -t -F'|' -v ON_ERROR_STOP=1 \
    -c "SELECT capacity_used, reaped_stale - $REAPED_BEFORE, cleanup_misses FROM xclaim.stats();")"

# Release commit gate and wait for all workers.
xclaim_holder_sql "SELECT pg_advisory_unlock(777002);"
xclaim_holder_close

WORKER_ERR=0
for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid" || WORKER_ERR=$(( WORKER_ERR + 1 ))
done

WINS_STATE="$(pg_xclaim_psql -X -A -t -F'|' -v ON_ERROR_STOP=1 \
    -c "SELECT (SELECT count(*) FROM reaper_wins), count(*), coalesce(max(cnt), 0) FROM (SELECT k, count(*) AS cnt FROM reaper_wins GROUP BY k) s;")"
END_STATE="$(pg_xclaim_psql -X -A -t -F'|' -v ON_ERROR_STOP=1 \
    -c "SELECT capacity_used, cleanup_misses, (SELECT count(*) FROM xclaim.debug_snapshot()) FROM xclaim.stats();")"

echo "  barriers (start_gate|commit_gate): ${START_GATE_OK}|${COMMIT_GATE_OK}, worker errors: $WORKER_ERR"
echo "  while held (capacity_used|reaped_delta|cleanup_misses): $MID_STATE"
echo "  wins (total|distinct_keys|max_winners_per_key): $WINS_STATE"
echo "  after COMMIT (capacity_used|cleanup_misses|snapshot_rows): $END_STATE"

if [[ "$START_GATE_OK" == "yes" && "$COMMIT_GATE_OK" == "yes" ]] && (( WORKER_ERR == 0 )) && [[ "$WINS_STATE" == "${N_KEYS}|${N_KEYS}|1" ]]; then
    pass "single_winner_per_stale_key" "wins" "$WINS_STATE" "all $N_WORKERS workers hit both barriers and each of $N_KEYS stale keys was won by 1 backend"
else
    fail "single_winner_per_stale_key" "wins" "gates=${START_GATE_OK}:${COMMIT_GATE_OK} err=$WORKER_ERR wins=$WINS_STATE" "expected both barriers, 0 errors and ${N_KEYS}|${N_KEYS}|1"
fi

if [[ "$MID_STATE" == "${N_KEYS}|${N_KEYS}|0" && "$END_STATE" == "0|0|0" ]]; then
    pass "reaper_bookkeeping" "mid_end" "${MID_STATE}->${END_STATE}" "exact live_capacity and reaped_stale balance under 8-way contention"
else
    fail "reaper_bookkeeping" "mid_end" "${MID_STATE}->${END_STATE}" "expected ${N_KEYS}|${N_KEYS}|0 -> 0|0|0"
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
