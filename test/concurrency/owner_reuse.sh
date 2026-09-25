#!/usr/bin/env bash
# test/concurrency/owner_reuse.sh
# Owner identity / backend reuse test.
#
# Scenario:
#   Backend A acquires (1, 800), commits (the xact callback releases the claim)
#   and exits cleanly (its exit callback invalidates its owner token).
#   New backend B tries (1, 800) -> true (clean exit means no stale entry).
#
#   Out-of-range owner:
#   xclaim.debug_inject_stale writes a row with owner_procno = INT32_MAX and
#   owner_token 0. The reaper takes it over at the procno bounds check,
#   before it compares pids or tokens.
#
#   Token mismatch:
#   Backend A holds (1, 810) in an open transaction. The hooks module
#   (test/modules/xclaim_test_hooks) overwrites the owner_token published in
#   A's slot, as a new backend in the same slot would. A stays alive, so the
#   procno and pid checks pass and the reaper takes the row over on the
#   token check:
#     entry.owner_token != XClaimBackendInfos[procno].current_token
#   Genuine slot reuse by another backend cannot be orchestrated reliably.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="owner_reuse"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

trap pg_xclaim_stop_temp_cluster EXIT INT TERM
xclaim_build_test_hooks
pg_xclaim_start_temp_cluster "owner_reuse"
xclaim_create_test_hooks_functions

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Test 1: clean exit path -- no stale entry after normal backend exit
# ---------------------------------------------------------------------------
echo "--- Test 1: clean backend exit releases entry ---"

# Backend A acquires then exits cleanly
pg_xclaim_psql -X -A -t 2>/dev/null <<'SQLA'
BEGIN;
SELECT xclaim.try(1, 800);
COMMIT;
SQLA
# COMMIT released the claim. psql exits and the exit callback invalidates
# the owner token.

# New backend B: should succeed
B_RESULT="$(pg_xclaim_psql -X -A -t 2>/dev/null <<'SQLB'
BEGIN;
SELECT xclaim.try(1, 800);
ROLLBACK;
SQLB
)"
B_VAL="$(echo "$B_RESULT" | grep -E '^(t|f)$' | head -1 || echo "unknown")"
echo "  New backend after clean exit: xclaim.try(1,800) = $B_VAL"

if [[ "$B_VAL" == "t" ]]; then
    echo "  PASS: new backend acquired after clean exit"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "clean_exit_no_stale" "PASS" "result" "true" "clean exit path")")
else
    echo "  FAIL: expected true, got '$B_VAL'" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "clean_exit_no_stale" "FAIL" "result" "$B_VAL" "clean exit should release")")
fi

# ---------------------------------------------------------------------------
# Test 2: out-of-range owner triggers the reaper (debug injection)
# ---------------------------------------------------------------------------
echo "--- Test 2: out-of-range owner triggers the reaper (debug injection) ---"

REAPED_BEFORE="$(pg_xclaim_psql -X -A -t \
    -c "SELECT reaped_stale FROM xclaim.stats();" \
    2>/dev/null | tr -d ' ' || echo "0")"

# Inject a stale entry (owner_procno = INT32_MAX, owner_token 0)
pg_xclaim_psql -X -A -t \
    -c "SELECT xclaim.debug_inject_stale(1, 801);" \
    >/dev/null 2>&1

STALE_VISIBLE="$(pg_xclaim_psql -X -A -t \
    -c "SELECT count(*) FROM xclaim.debug() WHERE key = 801;" \
    2>/dev/null | tr -d ' ' || echo "0")"
echo "  Injected stale entry visible: $STALE_VISIBLE"

if [[ "$STALE_VISIBLE" == "1" ]]; then
    echo "  PASS: stale entry injected and visible"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "stale_injected_visible" "PASS" "count" "1" "inject ok")")
else
    echo "  FAIL: stale entry not visible, count=$STALE_VISIBLE" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "stale_injected_visible" "FAIL" "count" "$STALE_VISIBLE" "inject failed")")
fi

# Try on stale key -- reaper fires
TRY_STALE_RESULT="$(pg_xclaim_psql -X -A -t 2>/dev/null <<'SQL'
BEGIN;
SELECT xclaim.try(1, 801);
ROLLBACK;
SQL
)"
TRY_VAL="$(echo "$TRY_STALE_RESULT" | grep -E '^(t|f)$' | head -1 || echo "unknown")"
echo "  xclaim.try(1,801) on stale entry: $TRY_VAL"

if [[ "$TRY_VAL" == "t" ]]; then
    echo "  PASS: out-of-range owner -> reaper fired -> acquisition succeeded"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "out_of_range_owner_reaper" "PASS" "result" "true" "reaper fired")")
else
    echo "  FAIL: expected true (reaper should fire), got '$TRY_VAL'" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "out_of_range_owner_reaper" "FAIL" "result" "$TRY_VAL" "reaper did not fire")")
fi

REAPED_AFTER="$(pg_xclaim_psql -X -A -t \
    -c "SELECT reaped_stale FROM xclaim.stats();" \
    2>/dev/null | tr -d ' ' || echo "0")"
echo "  reaped_stale: $REAPED_BEFORE -> $REAPED_AFTER"

if (( REAPED_AFTER > REAPED_BEFORE )); then
    echo "  PASS: reaped_stale counter incremented"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "reaper_counter" "PASS" "reaped_stale" "$REAPED_AFTER" "incremented")")
else
    echo "  FAIL: reaped_stale not incremented" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "reaper_counter" "FAIL" "reaped_stale" "$REAPED_AFTER" "not incremented")")
fi

# ---------------------------------------------------------------------------
# Test 3: token mismatch with a live owner triggers the reaper
# ---------------------------------------------------------------------------
echo "--- Test 3: token mismatch with a live owner triggers the reaper ---"

xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT xclaim.try(1, 810);"
xclaim_holder_sql "SELECT 'pid=' || pg_backend_pid();"
A_ROW=""
if xclaim_holder_wait '^pid='; then
    A_ROW="$(pg_xclaim_psql -X -A -t -q \
        -c "SELECT owner_procno || ' ' || owner_token || ' ' || owner_pid FROM xclaim.debug() WHERE key = 810;")"
fi
read -r A_PROCNO A_TOKEN A_PID <<<"${A_ROW:-x x x}"

if [[ -z "$A_ROW" ]]; then
    xclaim_holder_close
    echo "  FAIL: backend A must hold (1, 810)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "token_mismatch_reaper" "FAIL" "setup" "no row" "backend A must hold (1, 810)")")
else
    REAPED_BEFORE="$(pg_xclaim_psql -X -A -t -q -c "SELECT reaped_stale FROM xclaim.stats();")"
    MISSES_BEFORE="$(pg_xclaim_psql -X -A -t -q -c "SELECT cleanup_misses FROM xclaim.stats();")"
    # The slot now publishes a token other than the row's, while A's pid
    # still owns the slot.
    pg_xclaim_psql -X -A -t -q \
        -c "SELECT xclaim_test_set_published_token($A_PROCNO, $A_TOKEN + 1);" >/dev/null
    PUB="$(pg_xclaim_psql -X -A -t -q -c "SELECT xclaim_test_published_token($A_PROCNO);")"
    A_ALIVE="$(pg_xclaim_psql -X -A -t -q -c "SELECT count(*) FROM pg_stat_activity WHERE pid = $A_PID;")"
    TRY3="$(pg_xclaim_psql -X -A -t -q -c "SELECT xclaim.try(1, 810);")"
    REAPED_AFTER="$(pg_xclaim_psql -X -A -t -q -c "SELECT reaped_stale FROM xclaim.stats();")"
    echo "  A: procno = $A_PROCNO, pid = $A_PID (alive: $A_ALIVE), row token = $A_TOKEN, published now = $PUB"
    echo "  other backend: try(1, 810) = $TRY3, reaped_stale $REAPED_BEFORE -> $REAPED_AFTER"

    if [[ "$A_ALIVE" == "1" ]] && [[ "$PUB" == "$(( A_TOKEN + 1 ))" ]] \
        && [[ "$TRY3" == "t" ]] && (( REAPED_AFTER == REAPED_BEFORE + 1 )); then
        echo "  PASS: token mismatch with a live owner -> reaper fired -> acquisition succeeded"
        PASS=$(( PASS + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "token_mismatch_reaper" "PASS" "result" "true" "reaper fired on the token check")")
    else
        echo "  FAIL: expected a live owner, the new published token, try = t and one reap" >&2
        FAIL=$(( FAIL + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "token_mismatch_reaper" "FAIL" "result" "$TRY3" "reaper did not fire on the token check")")
    fi

    # A's cleanup at COMMIT no longer finds its row, which the reaper handed
    # to the other backend: exactly one cleanup miss.
    xclaim_holder_sql "COMMIT;"
    xclaim_holder_close
    MISSES_AFTER="$(pg_xclaim_psql -X -A -t -q -c "SELECT cleanup_misses FROM xclaim.stats();")"
    echo "  cleanup_misses after A committed: $MISSES_BEFORE -> $MISSES_AFTER"
    if (( MISSES_AFTER == MISSES_BEFORE + 1 )); then
        echo "  PASS: A's cleanup counted its taken-over row as a miss"
        PASS=$(( PASS + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "owner_cleanup_miss" "PASS" "cleanup_misses" "$MISSES_AFTER" "one miss")")
    else
        echo "  FAIL: expected cleanup_misses $MISSES_BEFORE + 1" >&2
        FAIL=$(( FAIL + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "owner_cleanup_miss" "FAIL" "cleanup_misses" "$MISSES_AFTER" "expected one miss")")
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
