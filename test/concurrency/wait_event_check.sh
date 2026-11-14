#!/usr/bin/env bash
# test/concurrency/wait_event_check.sh
# Wait event observability test.
#
# Scenario:
#   Backend A holds many claims in an open transaction while calling debug()
#   repeatedly, which holds all partition locks SHARED for each scan.
#   Backends B try to acquire new claims (EXCLUSIVE partition locks) during
#   A's scans.
#   Observer polls pg_stat_activity for an LWLock wait of A or B.
#   Expected: wait_event_type='LWLock' AND wait_event='xclaim_partition'.
#
# What the test proves.
#   The observer looks for LWLock waits named like '%xclaim%' or
#   'extension', the name of an extension tranche the observing backend has
#   not registered. An observed wait with any name but 'xclaim_partition'
#   is a FAIL.
#
#   A wait that is not observed proves nothing: without a FAIL the script
#   then exits 77, which run_concurrency_suite.sh reports as SKIP, not PASS.
#   The scan time grows with the number of claims A holds, which is what
#   makes a wait likely to be caught by a 20 ms poll.
#
# Crashes.
#   Every psql runs with ON_ERROR_STOP and lc_messages=C. Its exit status is
#   the crash check: 0 is success, 1 or 3 an SQL error, 2 a lost connection.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="wait_event_check"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

EXPECTED_TRANCHE="xclaim_partition"
# Claims session A holds during its debug() scans: each scan holds every
# partition lock SHARED for a time that grows with this number.
A_CLAIMS=200000
# Loops of B sessions that try new keys while A scans.
N_B_LOOPS=8
XCLAIM_MAX_CLAIMS=262144 pg_xclaim_start_temp_cluster "wait_event"
# Server messages of every session in English, whatever the cluster locale.
export PGOPTIONS='-c lc_messages=C'

# Temp dirs registered here are removed even when an assertion aborts the
# script early (set -e), not only on the success path.
XCLAIM_TMPFILES=()
cleanup_wait_event() {
    rm -rf "${XCLAIM_TMPFILES[@]:-}"
    pg_xclaim_stop_temp_cluster
}
trap cleanup_wait_event EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

WORK_DIR="$(mktemp -d)"
XCLAIM_TMPFILES+=("$WORK_DIR")

# Session A: open transaction with A_CLAIMS claims, then 20 debug() scans.
SESSION_A_LOG="$WORK_DIR/session_a.log"
{
    echo "BEGIN;"
    echo "SELECT 'held=' || count(v) FROM unnest(xclaim.try_many(1, ARRAY(SELECT generate_series(1, $A_CLAIMS)::int4))) v WHERE v;"
    for _i in $(seq 1 20); do
        echo "SELECT count(*) FROM xclaim.debug();"
    done
    echo "ROLLBACK;"
} > "$WORK_DIR/session_a.sql"
PGAPPNAME=xclaim_wait_a \
    "$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d postgres \
    -X -A -t -v ON_ERROR_STOP=1 -f "$WORK_DIR/session_a.sql" \
    >"$SESSION_A_LOG" 2>&1 &
A_JOB=$!

# The B sessions start once A holds its claims, so their try_many calls
# overlap A's scans, and run until A is done.
for _i in $(seq 1 300); do
    grep -q '^held=' "$SESSION_A_LOG" 2>/dev/null && break
    kill -0 "$A_JOB" 2>/dev/null || break
    sleep 0.1
done

# Sessions B: each loop runs try_many on its own 1000 new keys (EXCLUSIVE
# partition locks) in a fresh connection until $B_STOP appears. A loop
# exits with the first non-zero psql exit status it sees.
B_STOP="$WORK_DIR/b_stop"
B_JOBS=()
for _b in $(seq 1 $N_B_LOOPS); do
    (
        while [[ ! -f "$B_STOP" ]]; do
            PGAPPNAME=xclaim_wait_b \
                "$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d postgres \
                -X -A -t -q -v ON_ERROR_STOP=1 \
                -c "BEGIN;" \
                -c "SELECT count(v) FROM unnest(xclaim.try_many(2, ARRAY(SELECT generate_series($(( _b * 1000 + 1 )), $(( _b * 1000 + 1000 )))::int4))) v WHERE v;" \
                -c "ROLLBACK;" \
                >>"$WORK_DIR/session_b_${_b}.log" 2>&1 || exit $?
        done
    ) &
    B_JOBS+=($!)
done

# Observer: while A runs, poll pg_stat_activity for an LWLock wait of the
# test sessions on an xclaim tranche or on an unregistered extension
# tranche ('extension').
WAIT_FOUND=""
WAIT_INFO_CAPTURED=""
for _poll in $(seq 1 1500); do
    kill -0 "$A_JOB" 2>/dev/null || break
    WAIT_INFO="$(pg_xclaim_psql -X -A -t 2>/dev/null \
        -c "SELECT pid, wait_event_type, wait_event FROM pg_stat_activity WHERE application_name IN ('xclaim_wait_a', 'xclaim_wait_b') AND wait_event_type = 'LWLock' AND (wait_event LIKE '%xclaim%' OR wait_event = 'extension') LIMIT 3;" \
        || true)"
    if [[ -n "$WAIT_INFO" ]]; then
        WAIT_FOUND="yes"
        WAIT_INFO_CAPTURED="$WAIT_INFO"
        break
    fi
    sleep 0.02
done

# Wait for every session and keep each exit status.
CRASHED=()
if wait "$A_JOB"; then _rc=0; else _rc=$?; fi
(( _rc == 0 )) || CRASHED+=("A:rc=$_rc")
grep -q '^held=' "$SESSION_A_LOG" || CRASHED+=("A:no_claims")
: > "$B_STOP"
for _k in "${!B_JOBS[@]}"; do
    if wait "${B_JOBS[_k]}"; then _rc=0; else _rc=$?; fi
    (( _rc == 0 )) || CRASHED+=("B$(( _k + 1 )):rc=$_rc")
done

# ---------------------------------------------------------------------------
# Test 1: wait_event observability
# ---------------------------------------------------------------------------
echo "--- Test 1: LWLock wait_event named '$EXPECTED_TRANCHE' ---"
if [[ -n "$WAIT_FOUND" ]]; then
    echo "  Observed LWLock wait in pg_stat_activity (pid|type|event):"
    echo "$WAIT_INFO_CAPTURED" | head -5 | sed 's/^/    /'
    WAIT_NAMES="$(cut -d'|' -f3 <<<"$WAIT_INFO_CAPTURED" | sort -u | tr '\n' ' ' | sed 's/ $//')"
    if [[ "$WAIT_NAMES" == "$EXPECTED_TRANCHE" ]]; then
        echo "  PASS: wait_event is '$EXPECTED_TRANCHE'"
        PASS=$(( PASS + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "wait_event_name" "PASS" "wait_event" "$WAIT_NAMES" "LWLock contention observed")")
    else
        echo "  FAIL: wait_event '$WAIT_NAMES', expected '$EXPECTED_TRANCHE'" >&2
        FAIL=$(( FAIL + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "wait_event_name" "FAIL" "wait_event" "$WAIT_NAMES" "expected $EXPECTED_TRANCHE")")
    fi
else
    echo "  SKIP: no LWLock wait observed in the polling window, the tranche name is not proven"
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "wait_event_name" "SKIP" "wait_event" "not_observed" "tranche name not proven")")
fi

# ---------------------------------------------------------------------------
# Test 2: all sessions exited successfully
# ---------------------------------------------------------------------------
echo "--- Test 2: no session errors or crashes ---"
if (( ${#CRASHED[@]} == 0 )); then
    echo "  PASS: session A and all $N_B_LOOPS B loops exited 0"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_session_errors" "PASS" "failed_sessions" "0" "all sessions exited 0")")
else
    echo "  FAIL: sessions with a non-zero psql exit status: ${CRASHED[*]}" >&2
    cat "$SESSION_A_LOG" "$WORK_DIR"/session_b_*.log 2>/dev/null \
        | grep -vE '^[0-9]+$|^held=' | head -10 | sed 's/^/    /' >&2 || true
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_session_errors" "FAIL" "failed_sessions" "${#CRASHED[@]}" "${CRASHED[*]}")")
fi

rm -rf "$WORK_DIR"
xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== WAIT_EVENT EVIDENCE ==="
if [[ -n "$WAIT_FOUND" ]]; then
    echo "  OBSERVED: $WAIT_INFO_CAPTURED"
else
    echo "  NOT OBSERVED in the polling window, tranche name not proven."
    echo "  Expected wait_event: '$EXPECTED_TRANCHE' (LWLock named tranche)"
    echo "  Recommended verification: pg_wait_sampling with 1ms sampling"
fi
echo ""

echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
if (( FAIL > 0 )); then
    echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
    exit 1
fi
if [[ -z "$WAIT_FOUND" ]]; then
    echo "=== RESULT: SKIP (no LWLock wait observed) PASS=$PASS FAIL=$FAIL ==="
    exit 77
fi
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
exit 0
