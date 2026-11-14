#!/usr/bin/env bash
# test/concurrency/bulk_fatal_capacity.sh
# xclaim.stats().capacity_used stays equal to the number of shared rows when
# the backend of a running xclaim.try_many is terminated.
#
# Why. A FATAL (pg_terminate_backend, transaction_timeout, a lost client)
# goes to proc_exit without PG_CATCH, and the backend-exit cleanup
# subtracts every row of the local set from live_capacity. try_many adds
# the rows of a partition run to live_capacity before it releases the
# partition lock, so at every interrupt check of the loop the counter
# already holds them.
#
#   Test 1: session A runs try_many on 2,000,000 keys. As soon as
#           capacity_used grows (A is in the loop over partitions and has
#           finished at least one run), A is terminated. After A exits,
#           capacity_used equals the rows in debug_snapshot(), both 0.
#           Three rounds.
#   Test 2: one claim held by a holder session afterwards reads as
#           capacity_used = 1 with one row.
#
# A round fails unless the terminate is sent while capacity_used is above 0
# and below the 2,000,000 keys: the counter has to move while the loop runs.
# It also fails when total_acquires moved: try_many adds its acquisitions
# to it only after the loop, so an unchanged counter shows that the
# terminate was processed at an interrupt check inside the loop, not at the
# first one after it. A round also fails unless session A's output shows
# the terminate ("terminating
# connection due to administrator command", the server runs with
# lc_messages = 'C') and no ERROR: a statement that ends with an SQL error
# goes through PG_CATCH and the abort, not through the exit cleanup.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="bulk_fatal_capacity"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

xclaim_banner "$SCRIPT"

trap pg_xclaim_stop_temp_cluster EXIT INT TERM
XCLAIM_MAX_CLAIMS=4194304
# English server messages, so the terminate lines match the log whitelist.
XCLAIM_EXTRA_CONF="lc_messages = 'C'"
pg_xclaim_start_temp_cluster "bulk_fatal"

PASS=0
FAIL=0
CSV_ROWS=()

q() { pg_xclaim_psql -X -A -t -q -c "$1"; }

pass() {  # test, metric, value, notes
    echo "  PASS: $4"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$1" "PASS" "$2" "$3" "$4")")
}
fail() {  # test, metric, value, notes
    echo "  FAIL: $4 (got $3)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$1" "FAIL" "$2" "$3" "$4")")
}

q "CREATE TABLE keys AS SELECT array_agg(g::int8) AS a FROM generate_series(1, 2000000) g;"

# ---------------------------------------------------------------------------
# Test 1: terminate A inside the loop, then compare the counter with the rows
# ---------------------------------------------------------------------------
echo "--- Test 1: pg_terminate_backend inside try_many ---"

A_OUT="$PGDATA/bulk_fatal_a.out"
TERMINATE_MSG="terminating connection due to administrator command"
for round in 1 2 3; do
    ACQ_BEFORE="$(q "SELECT total_acquires FROM xclaim.stats();")"
    PGAPPNAME="xclaim_bulk_fatal_a" pg_xclaim_psql -X -A -t -q -c \
        "SELECT 'taken=' || cardinality(xclaim.try_many(a)) FROM keys;" \
        > "$A_OUT" 2>&1 &
    A_SHELL=$!

    A_PID=""
    for _ in $(seq 1 500); do
        A_PID="$(q "SELECT pid FROM pg_stat_activity WHERE application_name = 'xclaim_bulk_fatal_a';")"
        [[ -n "$A_PID" ]] && break
        sleep 0.01
    done

    USED_SEEN=0
    if [[ -n "$A_PID" ]]; then
        for _ in $(seq 1 2000); do
            USED_SEEN="$(q "SELECT capacity_used FROM xclaim.stats();")"
            if (( USED_SEEN > 0 )) || ! kill -0 "$A_SHELL" 2>/dev/null; then
                break
            fi
        done
        if (( USED_SEEN > 0 )) && kill -0 "$A_SHELL" 2>/dev/null; then
            q "SELECT pg_terminate_backend($A_PID);" >/dev/null
        fi
    fi
    wait "$A_SHELL" || true
    xclaim_wait_backend_gone "${A_PID:-0}" || true
    # The pid check above sees only processes of this user. The backend
    # leaves pg_stat_activity once its exit cleanup has run.
    for _ in $(seq 1 100); do
        [[ "$(q "SELECT count(*) FROM pg_stat_activity WHERE pid = ${A_PID:-0};")" == "0" ]] && break
        sleep 0.05
    done

    USED="$(q "SELECT capacity_used FROM xclaim.stats();")"
    ROWS="$(q "SELECT count(*) FROM xclaim.debug_snapshot();")"
    TAKEN="$(sed -n 's/^taken=//p' "$A_OUT")"
    ACQ_DELTA=$(( $(q "SELECT total_acquires FROM xclaim.stats();") - ACQ_BEFORE ))
    echo "  round $round: capacity_used during the loop $USED_SEEN, try_many result ${TAKEN:-none}, total_acquires +$ACQ_DELTA, after exit capacity_used=$USED rows=$ROWS"

    if [[ -z "$A_PID" ]]; then
        fail "terminate_round_$round" "pid" "none" "session A did not start"
    elif [[ -n "$TAKEN" ]] || (( USED_SEEN <= 0 || USED_SEEN >= 2000000 )); then
        fail "terminate_round_$round" "progress" "$USED_SEEN" "capacity_used must grow part of the way while try_many runs, so the terminate lands inside the loop"
    elif (( ACQ_DELTA != 0 )); then
        fail "terminate_round_$round" "total_acquires" "+$ACQ_DELTA" "the terminate must be processed inside the loop, before try_many adds its acquisitions"
    elif ! grep -q "$TERMINATE_MSG" "$A_OUT" || grep -q '^ERROR:' "$A_OUT"; then
        sed 's/^/    A: /' "$A_OUT" >&2
        fail "terminate_round_$round" "a_output" "no terminate message or an ERROR" "session A must end by the terminate, not by an SQL error"
    elif [[ "$USED" == "0" && "$ROWS" == "0" ]]; then
        pass "terminate_round_$round" "capacity_used" "$USED" "terminated inside the loop, capacity_used equals the rows (0)"
    else
        fail "terminate_round_$round" "capacity_used" "$USED rows=$ROWS" "capacity_used must equal the shared rows after the terminate"
    fi
done

# ---------------------------------------------------------------------------
# Test 2: the counter still counts a held claim
# ---------------------------------------------------------------------------
echo "--- Test 2: a held claim after the terminations ---"

xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'claim=' || xclaim.try(424242);"
xclaim_holder_wait '^claim=' || true
USED="$(q "SELECT capacity_used FROM xclaim.stats();")"
ROWS="$(q "SELECT count(*) FROM xclaim.debug_snapshot();")"
xclaim_holder_sql "COMMIT;"
xclaim_holder_close
echo "  one held claim: capacity_used=$USED rows=$ROWS"
if [[ "$USED" == "1" && "$ROWS" == "1" ]]; then
    pass "held_claim" "capacity_used" "$USED" "a held claim reads as capacity_used = 1"
else
    fail "held_claim" "capacity_used" "$USED rows=$ROWS" "a held claim must read as capacity_used = 1 with one row"
fi

xclaim_check_server_log "$SCRIPT" "$TERMINATE_MSG" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
