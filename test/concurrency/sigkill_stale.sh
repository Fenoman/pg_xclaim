#!/usr/bin/env bash
# test/concurrency/sigkill_stale.sh
# Stale-owner reaper test.
#
# ============================================================================
# DESIGN CHOICE: debug injection via xclaim.debug_inject_stale.
# ============================================================================
# Real SIGKILL of a backend is NOT used. Rationale:
#
#   When a PostgreSQL backend receives SIGKILL (kill -9), the postmaster detects
#   the crash via SIGCHLD and initiates crash recovery. With default settings
#   (restart_after_crash=on), the postmaster sends SIGQUIT to all remaining
#   backends and restarts shared memory from scratch. This DESTROYS the stale
#   entry we planted in shared memory before the recovery, making it impossible
#   to observe the reaper code path.
#
#   With restart_after_crash=off, the postmaster marks the cluster "degraded"
#   and subsequent backend connections may see inconsistent state; this is too
#   fragile for CI.
#
#   Killing the psql client (not the backend) avoids the postmaster crash
#   path but only if the connection is broken before the backend commits;
#   in that case the txn rolls back normally via before_shmem_exit -- that
#   exercises the disconnect-release path, NOT the stale-reaper code path.
#
#   CONCLUSION: debug-injection is the correct approach for the stale-reaper.
#   xclaim.debug_inject_stale(scope, key) creates an XClaimEntry with
#   owner_procno=99999 (invalid) and owner_token=0 (invalid sentinel) which is
#   guaranteed stale via the token-mismatch detection branch. This directly
#   exercises the reaper code path without cluster-stability concerns.
# ============================================================================
#
# Scenario:
#   1. SELECT xclaim.debug_inject_stale(1, 700) -> entry appears in debug()
#   2. SELECT xclaim.try(1, 700) -> reaper triggers, returns true
#   3. xclaim.stats().reaped_stale > 0
#   4. xclaim.debug() empty (stale entry cleaned up)
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="sigkill_stale"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

pg_xclaim_start_temp_cluster "sigkill_stale"
trap pg_xclaim_stop_temp_cluster EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

echo "NOTE: Using debug injection -- real SIGKILL infeasible due to"
echo "      postmaster crash recovery semantics. See script header for rationale."
echo ""

# ---------------------------------------------------------------------------
# Test 1: inject stale entry, verify it appears in debug()
# ---------------------------------------------------------------------------
echo "--- Test 1: inject stale entry ---"
pg_xclaim_psql -X -A -t -c "SELECT xclaim.debug_inject_stale(1, 700);" >/dev/null 2>&1

STALE_COUNT="$(pg_xclaim_psql -X -A -t \
    -c "SELECT count(*) FROM xclaim.debug() WHERE key = 700;" \
    2>/dev/null | tr -d ' ' || echo "0")"
echo "  xclaim.debug() entries for key=700 after inject: $STALE_COUNT"

if [[ "$STALE_COUNT" == "1" ]]; then
    echo "  PASS: stale entry visible in debug()"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "stale_injected" "PASS" "debug_count" "1" "entry present")")
else
    echo "  FAIL: expected 1 stale entry, got $STALE_COUNT" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "stale_injected" "FAIL" "debug_count" "$STALE_COUNT" "inject failed")")
fi

# ---------------------------------------------------------------------------
# Test 2: try on stale key triggers reaper, returns true
# ---------------------------------------------------------------------------
echo "--- Test 2: try on stale key triggers reaper ---"

REAPED_BEFORE="$(pg_xclaim_psql -X -A -t \
    -c "SELECT reaped_stale FROM xclaim.stats();" \
    2>/dev/null | tr -d ' ' || echo "0")"
echo "  reaped_stale before: $REAPED_BEFORE"

TRY_RESULT="$(pg_xclaim_psql -X -A -t 2>/dev/null <<'SQLB'
BEGIN;
SELECT xclaim.try(1, 700);
ROLLBACK;
SQLB
)"

TRY_VAL="$(echo "$TRY_RESULT" | grep -E '^(t|f)$' | head -1 || echo "unknown")"
echo "  xclaim.try(1,700) on stale entry: $TRY_VAL"

if [[ "$TRY_VAL" == "t" ]]; then
    echo "  PASS: reaper allowed acquisition on stale entry"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "reaper_allows_try" "PASS" "result" "true" "reaper reaped stale")")
else
    echo "  FAIL: expected true (reaper should fire), got '$TRY_VAL'" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "reaper_allows_try" "FAIL" "result" "$TRY_VAL" "reaper did not fire")")
fi

# ---------------------------------------------------------------------------
# Test 3: reaped_stale counter incremented
# ---------------------------------------------------------------------------
echo "--- Test 3: reaped_stale counter incremented ---"
REAPED_AFTER="$(pg_xclaim_psql -X -A -t \
    -c "SELECT reaped_stale FROM xclaim.stats();" \
    2>/dev/null | tr -d ' ' || echo "0")"
echo "  reaped_stale after: $REAPED_AFTER"

if (( REAPED_AFTER > REAPED_BEFORE )); then
    echo "  PASS: reaped_stale incremented ($REAPED_BEFORE -> $REAPED_AFTER)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "reaped_stale_counter" "PASS" "reaped_stale" "$REAPED_AFTER" "counter incremented")")
else
    echo "  FAIL: reaped_stale not incremented ($REAPED_BEFORE -> $REAPED_AFTER)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "reaped_stale_counter" "FAIL" "reaped_stale" "$REAPED_AFTER" "counter not incremented")")
fi

# ---------------------------------------------------------------------------
# Test 4: after reaper + rollback, debug() is clean
# ---------------------------------------------------------------------------
echo "--- Test 4: debug() clean after reaper + rollback ---"
DEBUG_COUNT="$(pg_xclaim_psql -X -A -t \
    -c "SELECT count(*) FROM xclaim.debug();" \
    2>/dev/null | tr -d ' ' || echo "-1")"
echo "  xclaim.debug() count = $DEBUG_COUNT"

if [[ "$DEBUG_COUNT" == "0" ]]; then
    echo "  PASS: no leaked entries after reap"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_reap" "PASS" "debug_count" "0" "clean")")
else
    echo "  FAIL: expected 0 entries, got $DEBUG_COUNT" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_reap" "FAIL" "debug_count" "$DEBUG_COUNT" "leaked")")
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== SIGKILL PATH CHOICE: debug injection ==="
echo "    Real kill -9 is not viable: postmaster crash recovery destroys"
echo "    shared memory before the reaper can observe a stale entry."
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
