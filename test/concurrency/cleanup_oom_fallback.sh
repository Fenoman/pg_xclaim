#!/usr/bin/env bash
# test/concurrency/cleanup_oom_fallback.sh
# Transaction end releases every claim in linear time when the cleanup
# cannot allocate its arrays.
#
# Why. A cleanup of more claims than the held-key list covers gathers
# pointers to all entries into arrays allocated with MCXT_ALLOC_NO_OOM. When
# the allocation fails, one walk over the local set releases each shared row
# under its own partition LWLock, without allocating and without modifying
# the set. A walk that restarted for every entry would be quadratic, and it
# runs inside COMMIT with interrupts held, with the remaining keys taken.
#
#   Test 1: a session takes 100,000 claims one by one (no large array
#           freed before COMMIT whose memory the allocator could reuse),
#           its address space is capped at what it maps (the arrays need
#           800 kB each), and it commits. COMMIT ends within 5 s, no shared row is left,
#           capacity_used is 0 and cleanup_misses stays 0.
#
# Linux only: it needs prlimit and /proc. Elsewhere, and when prlimit cannot
# cap the backend, it exits with 77, which run_concurrency_suite.sh reports as
# skipped.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="cleanup_oom_fallback"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

xclaim_banner "$SCRIPT"

if [[ "$(uname -s)" != "Linux" ]] || ! command -v prlimit >/dev/null 2>&1; then
    echo "  SKIP: needs Linux with prlimit to cap the address space of one backend"
    exit 77
fi

trap pg_xclaim_stop_temp_cluster EXIT INT TERM
XCLAIM_MAX_CLAIMS=1048576
XCLAIM_EXTRA_CONF="restart_after_crash = off"
pg_xclaim_start_temp_cluster "cleanup_oom"

PASS=0
FAIL=0
CSV_ROWS=()
N=100000

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

echo "--- Test 1: COMMIT of $N claims with the cleanup arrays out of reach ---"

MISSES_BEFORE="$(q "SELECT cleanup_misses FROM xclaim.stats();")"

xclaim_holder_open
xclaim_holder_sql "SET lc_messages = 'C';"
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'taken=' || count(*) FROM generate_series(1, $N) g WHERE xclaim.try(g::int8);"
xclaim_holder_sql "SELECT 'pid=' || pg_backend_pid();"
if ! xclaim_holder_wait '^pid='; then
    fail "setup" "holder" "no pid" "the holder session did not start"
else
    PID="$(sed -n 's/^pid=//p' "$XCLAIM_HOLDER_OUT")"
    TAKEN="$(sed -n 's/^taken=//p' "$XCLAIM_HOLDER_OUT")"
    VM_KB="$(awk '/^VmSize:/ {print $2}' "/proc/$PID/status")"
    if ! prlimit --pid "$PID" --as=$(( VM_KB * 1024 )); then
        echo "  SKIP: prlimit cannot cap the address space of backend $PID"
        xclaim_holder_close
        exit 77
    fi
    echo "  backend $PID holds $TAKEN claims, VmSize ${VM_KB} kB, address space capped there"

    T0="$(date +%s.%N)"
    xclaim_holder_sql "COMMIT;"
    xclaim_holder_sql "SELECT 'committed';"
    DONE=0
    for _ in $(seq 1 1200); do
        if grep -q '^committed$' "$XCLAIM_HOLDER_OUT" 2>/dev/null; then
            DONE=1
            break
        fi
        sleep 0.05
    done
    T1="$(date +%s.%N)"
    ELAPSED_MS="$(awk -v a="$T0" -v b="$T1" 'BEGIN { printf "%d", (b - a) * 1000 }')"
    xclaim_holder_close

    ROWS="$(q "SELECT count(*) FROM xclaim.debug_snapshot();")"
    USED="$(q "SELECT capacity_used FROM xclaim.stats();")"
    MISSES="$(q "SELECT cleanup_misses - $MISSES_BEFORE FROM xclaim.stats();")"
    echo "  COMMIT took ${ELAPSED_MS} ms (finished: $DONE), rows left $ROWS, capacity_used $USED, new cleanup_misses $MISSES"

    if [[ "$TAKEN" != "$N" ]]; then
        fail "setup" "taken" "${TAKEN:-none}" "the session must take $N claims"
    elif [[ "$DONE" == "1" ]] && (( ELAPSED_MS <= 5000 )); then
        pass "commit_time" "ms" "$ELAPSED_MS" "COMMIT of $N claims without the cleanup arrays ended within 5 s"
    else
        fail "commit_time" "ms" "$ELAPSED_MS finished=$DONE" "COMMIT of $N claims without the cleanup arrays must end within 5 s"
    fi
    if [[ "$ROWS" == "0" && "$USED" == "0" && "$MISSES" == "0" ]]; then
        pass "released" "rows" "$ROWS" "every shared row is gone, capacity_used 0, no cleanup miss"
    else
        fail "released" "rows" "$ROWS used=$USED misses=$MISSES" "every shared row must be released with capacity_used 0 and no cleanup miss"
    fi
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
