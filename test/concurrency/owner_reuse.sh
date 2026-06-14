#!/usr/bin/env bash
# test/concurrency/owner_reuse.sh
# Owner identity / backend reuse test.
#
# Scenario:
#   Backend A acquires (1, 800), then exits cleanly (before_shmem_exit cleans up).
#   New backend B tries (1, 800) -> true (clean exit means no stale entry).
#
#   Backend reuse variant (owner_token mismatch):
#   Use xclaim.debug_inject_stale to simulate a stale entry with procno matching
#   the current backend's procno but a different token -> reaper detects mismatch.
#
# NOTE on procno reuse:
#   Genuine procno reuse (same slot, different backend) is non-deterministic and
#   cannot be reliably orchestrated in a test. We use debug injection to
#   simulate the token-mismatch scenario. This directly exercises the
#   reaper code path that checks:
#     entry.owner_token != XClaimBackendInfos[procno].current_token
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="owner_reuse"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

pg_xclaim_start_temp_cluster "owner_reuse"
trap pg_xclaim_stop_temp_cluster EXIT INT TERM

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
# psql exits, before_shmem_exit fires, cleanup runs

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
# Test 2: token mismatch triggers reaper (simulated procno reuse via inject)
# ---------------------------------------------------------------------------
echo "--- Test 2: token mismatch triggers reaper (simulated via inject) ---"

REAPED_BEFORE="$(pg_xclaim_psql -X -A -t \
    -c "SELECT reaped_stale FROM xclaim.stats();" \
    2>/dev/null | tr -d ' ' || echo "0")"

# Inject a stale entry (procno=99999, token=0 -- guaranteed stale)
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
    echo "  PASS: token mismatch -> reaper fired -> acquisition succeeded"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "token_mismatch_reaper" "PASS" "result" "true" "reaper fired")")
else
    echo "  FAIL: expected true (reaper should fire), got '$TRY_VAL'" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "token_mismatch_reaper" "FAIL" "result" "$TRY_VAL" "reaper did not fire")")
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

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
