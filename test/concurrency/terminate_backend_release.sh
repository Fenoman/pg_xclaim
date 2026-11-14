#!/usr/bin/env bash
# test/concurrency/terminate_backend_release.sh
# pg_terminate_backend releases the claim (the backend-exit callback fires).
#
# Scenario:
#   Session A: BEGIN; xclaim.try(1, 600) -> true, the transaction stays open
#   Session C: SELECT pg_terminate_backend(<A's pid>)
#   Session B: xclaim.try(1, 600) -> true (the backend-exit callback released it)
#
# pg_terminate_backend sends SIGTERM, the backend exits and its exit callback
# releases all claims.
#
# Synchronization: session A is a holder session (_lib.sh): the test sends it
# statements one at a time, reads its pid from pg_backend_pid() and keeps
# its transaction open until the terminate. Every step that does not happen
# as described is a FAIL: A not holding the claim, A's pid not read, the
# terminate not delivered or the backend not gone, entries left behind.
#
# The shared table is checked right after A's backend has exited and before
# B runs. A row of A left there carries the owner token that A's exit
# invalidated, so B's try would reap it and return true.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="terminate_backend_release"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

pg_xclaim_start_temp_cluster "terminate_backend_release"

trap pg_xclaim_stop_temp_cluster EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Test 1: pg_terminate_backend releases the claim
# ---------------------------------------------------------------------------
echo "--- Test 1: pg_terminate_backend releases the claim ---"

# Records one check: t_check NAME OK_FLAG METRIC VALUE NOTE
t_check() {
    if [[ "$2" == "true" ]]; then
        PASS=$(( PASS + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$1" "PASS" "$3" "$4" "$5")")
    else
        FAIL=$(( FAIL + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$1" "FAIL" "$3" "$4" "$5")")
    fi
}

xclaim_holder_open
xclaim_holder_sql "SELECT 'pid=' || pg_backend_pid();"
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'claim=' || xclaim.try(1, 600);"

A_BACKEND_PID=""
A_CLAIM=""
if xclaim_holder_wait '^claim=(true|false)$'; then
    A_BACKEND_PID="$(sed -n 's/^pid=//p' "$XCLAIM_HOLDER_OUT")"
    A_CLAIM="$(sed -n 's/^claim=//p' "$XCLAIM_HOLDER_OUT")"
fi
echo "  Session A backend PID: ${A_BACKEND_PID:-none}, xclaim.try(1,600) = ${A_CLAIM:-none}"

if [[ "$A_CLAIM" == "true" ]] && [[ "$A_BACKEND_PID" =~ ^[0-9]+$ ]]; then
    echo "  PASS: session A holds the claim"
    t_check "a_holds_claim" true "result" "true" ""
else
    echo "  FAIL: session A did not take the claim or its pid is unknown, output follows:" >&2
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
    t_check "a_holds_claim" false "result" "${A_CLAIM:-none}" "pid ${A_BACKEND_PID:-none}"
fi

if [[ "$A_BACKEND_PID" =~ ^[0-9]+$ ]]; then
    if ! A_HOLD_COUNT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 \
            -c "SELECT count(*) FROM xclaim.debug() WHERE scope = 1 AND key = 600 AND owner_pid = $A_BACKEND_PID;" 2>&1)"; then
        echo "  FAIL: xclaim.debug() query failed: $A_HOLD_COUNT" >&2
    fi
    echo "  xclaim.debug() entries for key=600 owned by A: $A_HOLD_COUNT"
    if [[ "$A_HOLD_COUNT" == "1" ]]; then
        echo "  PASS: xclaim.debug() shows A's entry"
        t_check "a_entry_in_debug" true "debug_count" "1" ""
    else
        echo "  FAIL: expected 1 entry owned by A, got '$A_HOLD_COUNT'" >&2
        t_check "a_entry_in_debug" false "debug_count" "$A_HOLD_COUNT" "expected 1"
    fi

    # Session C: terminate session A and wait until the backend is gone, so
    # its exit callback has run.
    if ! TERM_RESULT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 \
            -c "SELECT pg_terminate_backend($A_BACKEND_PID);" 2>&1)"; then
        echo "  FAIL: pg_terminate_backend query failed: $TERM_RESULT" >&2
    fi
    echo "  pg_terminate_backend($A_BACKEND_PID) = $TERM_RESULT"
    if [[ "$TERM_RESULT" == "t" ]] && xclaim_wait_backend_gone "$A_BACKEND_PID"; then
        echo "  PASS: backend $A_BACKEND_PID terminated and gone"
        t_check "a_terminated" true "result" "t" ""
    else
        echo "  FAIL: backend $A_BACKEND_PID not terminated (result '$TERM_RESULT') or still running" >&2
        t_check "a_terminated" false "result" "$TERM_RESULT" "backend not gone"
    fi
else
    echo "  FAIL: no pid for session A, terminate skipped" >&2
    t_check "a_terminated" false "result" "skipped" "no pid for session A"
fi
xclaim_holder_close

# No session holds a claim now: A's backend is gone and B has not started.
if ! LEFT_COUNT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 \
        -c "SELECT count(*) FROM xclaim.debug();" 2>&1)"; then
    echo "  FAIL: xclaim.debug() query failed: $LEFT_COUNT" >&2
    LEFT_COUNT="error"
fi
echo "  xclaim.debug() entries after A exited, before B: $LEFT_COUNT"
if [[ "$LEFT_COUNT" == "0" ]]; then
    echo "  PASS: A's exit left no row"
    t_check "no_row_after_exit" true "debug_count" "0" "before B"
else
    echo "  FAIL: '$LEFT_COUNT' entries remain after A's backend exited" >&2
    t_check "no_row_after_exit" false "debug_count" "$LEFT_COUNT" "left by the exit path"
fi

# Session B: try the same key
if ! SESSION_B_RESULT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 2>&1 <<'SQLB'
BEGIN;
SELECT xclaim.try(1, 600);
ROLLBACK;
SQLB
)"; then
    echo "  FAIL: session B query failed: $SESSION_B_RESULT" >&2
fi
B_VAL="$(echo "$SESSION_B_RESULT" | grep -E '^(t|f)$' | head -1 || echo "unknown")"
echo "  Session B after terminate: xclaim.try(1,600) = $B_VAL"

if [[ "$B_VAL" == "t" ]]; then
    echo "  PASS: B got true after pg_terminate_backend"
    t_check "terminate_release" true "result" "true" "exit callback released the claim"
else
    echo "  FAIL: B expected true, got '$B_VAL'" >&2
    t_check "terminate_release" false "result" "$B_VAL" "claim not released on terminate"
fi

# ---------------------------------------------------------------------------
# Test 2: no leaked entries
# ---------------------------------------------------------------------------
echo "--- Test 2: no leaked entries after terminate ---"
if ! DEBUG_COUNT="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 \
        -c "SELECT count(*) FROM xclaim.debug();" 2>&1)"; then
    echo "  FAIL: xclaim.debug() query failed: $DEBUG_COUNT" >&2
fi
echo "  xclaim.debug() count = $DEBUG_COUNT"

if [[ "$DEBUG_COUNT" == "0" ]]; then
    echo "  PASS: no leaked entries"
    t_check "no_leak_after_terminate" true "debug_count" "0" "clean"
else
    echo "  FAIL: '$DEBUG_COUNT' entries remain after the terminated backend exited" >&2
    t_check "no_leak_after_terminate" false "debug_count" "$DEBUG_COUNT" "leaked"
fi

# pg_terminate_backend sends SIGTERM, which makes the target backend log a
# FATAL "terminating connection due to administrator command" -- that line is
# the expected outcome of this test, not a failure. Whitelist both the English
# and the ru_RU.UTF-8 forms so the log scan does not flag it on either build.
TERMINATE_WHITELIST='terminating connection due to administrator command|закрытие подключения по команде администратора'
xclaim_check_server_log "$SCRIPT" "$TERMINATE_WHITELIST" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
