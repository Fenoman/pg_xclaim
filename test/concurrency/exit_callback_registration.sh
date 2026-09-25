#!/usr/bin/env bash
# test/concurrency/exit_callback_registration.sh
# Every backend that acquires a claim registers the pg_xclaim exit callback
# exactly once, as an on_shmem_exit callback, and leaves the before_shmem_exit
# stack alone.
#
# PostgreSQL clears the exit-callback lists it forks from the postmaster
# (on_exit_reset() in InitPostmasterChild), so the backend registers the
# callback itself, on its first claim. It uses on_shmem_exit because core
# code pops its own temporary before_shmem_exit entries with
# cancel_before_shmem_exit(), which requires them to be the latest entry
# (see test/sql/ensure_scope_first_claim.sql).
#
# Observation: with log_min_messages = debug3 an exiting backend logs
#   shmem_exit(<code>): <N> before_shmem_exit callbacks to make
#   shmem_exit(<code>): <M> on_shmem_exit callbacks to make
# A session that never touches pg_xclaim gives the baseline N and M. A
# session that acquired a claim must report N and M + 1:
#   Test 1: xclaim.try, then COMMIT
#   Test 2: xclaim.try_many
#   Test 3: xclaim.try, xclaim.session_reset(), xclaim.try again
#           (one registration per backend, not one per owner token)
#   Test 4: pg_terminate_backend of a session that used pg_xclaim
#           (FATAL exit path, shmem_exit(1))
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="exit_callback_registration"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

# The pid in the line prefix ties each exit line to its backend.
XCLAIM_EXTRA_CONF="log_line_prefix = '%m [%p] '"

pg_xclaim_start_temp_cluster "exit_callback_registration"
trap pg_xclaim_stop_temp_cluster EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()
LOG_FILE="$PGDATA/server.log"

# exit_counts <pid>
#   Prints "<code> <N> <M>" from the backend's shmem_exit lines (exit code,
#   before_shmem_exit count, on_shmem_exit count), or "missing" if they do
#   not appear within 5 seconds. The lines are written before the process
#   exits, so they can lag behind the client seeing the connection close.
exit_counts() {
    local pid="$1" before="" on="" _
    for _ in $(seq 1 100); do
        before="$(grep -E "\[$pid\] .*shmem_exit\([0-9]+\): [0-9]+ before_shmem_exit callbacks to make" \
            "$LOG_FILE" 2>/dev/null | head -1 || true)"
        on="$(grep -E "\[$pid\] .*shmem_exit\([0-9]+\): [0-9]+ on_shmem_exit callbacks to make" \
            "$LOG_FILE" 2>/dev/null | head -1 || true)"
        [[ -n "$before" && -n "$on" ]] && break
        sleep 0.05
    done
    if [[ -z "$before" || -z "$on" ]]; then
        echo "missing"
        return 0
    fi
    echo "$(echo "$before" | sed -E 's/.*shmem_exit\(([0-9]+)\): ([0-9]+) before_shmem_exit.*/\1 \2/') \
$(echo "$on" | sed -E 's/.*shmem_exit\([0-9]+\): ([0-9]+) on_shmem_exit.*/\1/')"
}

# run_session: runs the SQL on stdin in a fresh backend, prints its pid.
# The SQL must print a 'pid=<pid>' row. ON_ERROR_STOP makes any SQL error
# end the session before that row, so the case fails instead of passing on
# a partial script.
run_session() {
    pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 2>/dev/null | sed -n 's/^pid=//p'
}

# check_case <test> <desc> <pid> <expected exit code>
check_case() {
    local test_name="$1" desc="$2" pid="$3" want_code="$4"
    local counts code before on
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        echo "  FAIL: $desc -- could not read backend pid ('$pid')" >&2
        FAIL=$(( FAIL + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$test_name" "FAIL" "exit_callbacks" "no_pid" "")")
        return
    fi
    counts="$(exit_counts "$pid")"
    if [[ "$counts" == "missing" ]]; then
        echo "  FAIL: $desc -- no shmem_exit lines for pid $pid" >&2
        FAIL=$(( FAIL + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$test_name" "FAIL" "exit_callbacks" "missing" "")")
        return
    fi
    read -r code before on <<<"$counts"
    echo "  $desc: pid=$pid exit_code=$code before_shmem_exit=$before on_shmem_exit=$on" \
         "(expected exit_code=$want_code before_shmem_exit=$BASE_BEFORE on_shmem_exit=$EXPECTED_ON)"
    if [[ "$code" == "$want_code" && "$before" == "$BASE_BEFORE" && "$on" == "$EXPECTED_ON" ]]; then
        echo "  PASS: $desc"
        PASS=$(( PASS + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$test_name" "PASS" "on_shmem_exit" "$on" "baseline+1")")
    else
        echo "  FAIL: $desc" >&2
        FAIL=$(( FAIL + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$test_name" "FAIL" "on_shmem_exit" "$on" "code=$code before=$before")")
    fi
}

# ---------------------------------------------------------------------------
# Baseline: a session that never touches pg_xclaim
# ---------------------------------------------------------------------------
echo "--- Baseline: session without pg_xclaim calls ---"
BASE_PID="$(run_session <<'SQL'
SET log_min_messages = debug3;
SELECT 'pid=' || pg_backend_pid();
SQL
)"
BASE_COUNTS="$(exit_counts "${BASE_PID:-none}")"
if [[ "$BASE_COUNTS" == "missing" ]]; then
    echo "  FAIL: no shmem_exit lines for the baseline session, nothing to compare with" >&2
    exit 1
fi
read -r BASE_CODE BASE_BEFORE BASE_ON <<<"$BASE_COUNTS"
echo "  baseline: pid=$BASE_PID exit_code=$BASE_CODE before_shmem_exit=$BASE_BEFORE on_shmem_exit=$BASE_ON"
EXPECTED_ON=$(( BASE_ON + 1 ))

# ---------------------------------------------------------------------------
# Test 1: scalar claim, COMMIT
# ---------------------------------------------------------------------------
echo "--- Test 1: xclaim.try then COMMIT ---"
PID1="$(run_session <<'SQL'
SET log_min_messages = debug3;
BEGIN;
SELECT xclaim.try(1, 910);
COMMIT;
SELECT 'pid=' || pg_backend_pid();
SQL
)"
check_case "scalar_commit" "scalar claim + COMMIT" "$PID1" 0

# ---------------------------------------------------------------------------
# Test 2: bulk claim
# ---------------------------------------------------------------------------
echo "--- Test 2: xclaim.try_many ---"
PID2="$(run_session <<'SQL'
SET log_min_messages = debug3;
BEGIN;
SELECT xclaim.try_many(1, ARRAY[920, 921, 922]::int4[]);
COMMIT;
SELECT 'pid=' || pg_backend_pid();
SQL
)"
check_case "bulk_commit" "try_many + COMMIT" "$PID2" 0

# ---------------------------------------------------------------------------
# Test 3: token rotation keeps a single registration
# ---------------------------------------------------------------------------
echo "--- Test 3: xclaim.try, session_reset, xclaim.try ---"
PID3="$(run_session <<'SQL'
SET log_min_messages = debug3;
SELECT xclaim.try(1, 930);
SELECT xclaim.session_reset();
SELECT xclaim.try(1, 931);
SELECT 'pid=' || pg_backend_pid();
SQL
)"
check_case "session_reset_single_registration" "claim, session_reset, claim" "$PID3" 0

# ---------------------------------------------------------------------------
# Test 4: FATAL exit (pg_terminate_backend) after using pg_xclaim
# ---------------------------------------------------------------------------
echo "--- Test 4: pg_terminate_backend of a session that used pg_xclaim ---"
pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 \
    -c "SET log_min_messages = debug3;" \
    -c "SELECT xclaim.try(1, 940);" \
    -c "SELECT pg_sleep(30);" \
    >/dev/null 2>&1 &
SESSION4_PID=$!

PID4=""
for _ in $(seq 1 100); do
    PID4="$(pg_xclaim_psql -X -A -t \
        -c "SELECT pid FROM pg_stat_activity WHERE query LIKE '%pg_sleep(30)%' AND pid <> pg_backend_pid() LIMIT 1;" \
        2>/dev/null | tr -d ' ' || true)"
    [[ -n "$PID4" ]] && break
    sleep 0.05
done

TERMINATED="f"
if [[ -n "$PID4" ]]; then
    TERMINATED="$(pg_xclaim_psql -X -A -t -c "SELECT pg_terminate_backend($PID4);" 2>/dev/null | tr -d ' ' || true)"
fi
# The client sees its connection terminated and exits non-zero.
SESSION4_RC=0
wait "$SESSION4_PID" 2>/dev/null || SESSION4_RC=$?
echo "  pg_terminate_backend(${PID4:-none}) = $TERMINATED, client exit status = $SESSION4_RC"
if [[ "$TERMINATED" != "t" || "$SESSION4_RC" -eq 0 ]]; then
    echo "  FAIL: the session was not terminated by pg_terminate_backend" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "terminate_backend" "FAIL" "terminated" "$TERMINATED" "client rc=$SESSION4_RC")")
else
    check_case "terminate_backend" "pg_terminate_backend after a claim" "$PID4" 1
fi

# pg_terminate_backend makes the target log a FATAL "terminating connection
# due to administrator command" -- the expected outcome of Test 4. Both the
# English and the ru_RU.UTF-8 forms are whitelisted.
TERMINATE_WHITELIST='terminating connection due to administrator command|закрытие подключения по команде администратора'
xclaim_check_server_log "$SCRIPT" "$TERMINATE_WHITELIST" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
