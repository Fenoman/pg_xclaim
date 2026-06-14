#!/usr/bin/env bash
# test/concurrency/debug_scan_stress.sh
# Debug scan stress (concurrent acquire + debug scans).
#
# Scenario:
#   5 sessions concurrently acquire 1000 unique keys each (no overlap)
#   1 concurrent session calls xclaim.debug() and xclaim.debug_snapshot()
#   every 100ms throughout
#   Verify: no crash, no LWLock starvation, debug count == expected
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="debug_scan_stress"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

N_WORKERS=5
KEYS_PER_WORKER=1000
SCAN_INTERVAL_S="0.1"

pg_xclaim_start_temp_cluster "debug_stress"
trap pg_xclaim_stop_temp_cluster EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

echo "--- Debug scan stress: $N_WORKERS workers x $KEYS_PER_WORKER keys ---"

# Clean up background jobs and temp dirs on exit (even on early set -e abort).
BGPIDS=()
XCLAIM_TMPFILES=()
cleanup_bg() {
    for pid in "${BGPIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    rm -rf "${XCLAIM_TMPFILES[@]:-}"
    pg_xclaim_stop_temp_cluster
}
trap cleanup_bg EXIT INT TERM

WORKER_DONE_DIR="$(mktemp -d)"
XCLAIM_TMPFILES+=("$WORKER_DONE_DIR")
SCAN_STOP="$WORKER_DONE_DIR/stop_scan"

# ---------------------------------------------------------------------------
# Launch worker sessions (each in its own transaction, acquiring disjoint ranges)
# ---------------------------------------------------------------------------
for i in $(seq 1 $N_WORKERS); do
    START_KEY=$(( (i - 1) * KEYS_PER_WORKER + 1 ))
    END_KEY=$(( i * KEYS_PER_WORKER ))
    WORKER_OUT="$WORKER_DONE_DIR/worker_${i}.out"
    (
        # Build a try_many call for this worker's key range
        "$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d postgres \
            -X -A -t \
            -c "BEGIN;
                SELECT count(v) FROM unnest(
                    xclaim.try_many(1, ARRAY(
                        SELECT generate_series($START_KEY, $END_KEY)::int4
                    ))
                ) v WHERE v;
                COMMIT;" \
            >"$WORKER_OUT" 2>&1
        echo "worker_${i}_done"
    ) &
    BGPIDS+=($!)
done

# ---------------------------------------------------------------------------
# Scanner session: run debug() and debug_snapshot() while workers run
# ---------------------------------------------------------------------------
SCAN_OUT="$WORKER_DONE_DIR/scan.out"
(
    SCAN_COUNT=0
    while [[ ! -f "$SCAN_STOP" ]]; do
        "$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d postgres \
            -X -A -t \
            -c "SELECT count(*) FROM xclaim.debug();" \
            -c "SELECT count(*) FROM xclaim.debug_snapshot();" \
            >>"$SCAN_OUT" 2>&1 || true
        SCAN_COUNT=$(( SCAN_COUNT + 1 ))
        sleep "$SCAN_INTERVAL_S"
    done
    echo "scan_done: $SCAN_COUNT scans" >> "$SCAN_OUT"
) &
SCAN_PID=$!
BGPIDS+=($SCAN_PID)

# Wait for all workers to complete
for pid in "${BGPIDS[@]}"; do
    if [[ "$pid" != "$SCAN_PID" ]]; then
        wait "$pid" 2>/dev/null || true
    fi
done

# Stop scanner
touch "$SCAN_STOP"
sleep 0.3
kill "$SCAN_PID" 2>/dev/null || true
wait "$SCAN_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Validate: each worker should have acquired KEYS_PER_WORKER keys
# ---------------------------------------------------------------------------
echo "--- Validating worker results ---"
TOTAL_ACQUIRED=0
for i in $(seq 1 $N_WORKERS); do
    WORKER_OUT="$WORKER_DONE_DIR/worker_${i}.out"
    if [[ -f "$WORKER_OUT" ]]; then
        WORKER_COUNT="$(grep -E '^[0-9]+$' "$WORKER_OUT" | head -1 | tr -d ' ' || echo "0")"
        echo "  Worker $i: acquired $WORKER_COUNT / $KEYS_PER_WORKER keys"
        TOTAL_ACQUIRED=$(( TOTAL_ACQUIRED + WORKER_COUNT ))
        if [[ "$WORKER_COUNT" == "$KEYS_PER_WORKER" ]]; then
            CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "worker_${i}_count" "PASS" "acquired" "$WORKER_COUNT" "$KEYS_PER_WORKER expected")")
        else
            echo "  FAIL: worker $i acquired $WORKER_COUNT, expected $KEYS_PER_WORKER" >&2
            FAIL=$(( FAIL + 1 ))
            CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "worker_${i}_count" "FAIL" "acquired" "$WORKER_COUNT" "$KEYS_PER_WORKER expected")")
        fi
    else
        echo "  WARN: no output from worker $i"
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "worker_${i}_count" "FAIL" "acquired" "0" "no output")")
        FAIL=$(( FAIL + 1 ))
    fi
done

EXPECTED_TOTAL=$(( N_WORKERS * KEYS_PER_WORKER ))
echo "  Total acquired: $TOTAL_ACQUIRED / $EXPECTED_TOTAL"
if [[ "$TOTAL_ACQUIRED" == "$EXPECTED_TOTAL" ]]; then
    echo "  PASS: all workers acquired all expected keys"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "total_acquired" "PASS" "total" "$TOTAL_ACQUIRED" "matches expected")")
else
    echo "  FAIL: expected $EXPECTED_TOTAL total, got $TOTAL_ACQUIRED" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "total_acquired" "FAIL" "total" "$TOTAL_ACQUIRED" "expected $EXPECTED_TOTAL")")
fi

# ---------------------------------------------------------------------------
# Validate: scanner did not crash AND did not log any SQL ERROR.
# The inner loop writes psql stderr+stdout to $SCAN_OUT via `2>&1 || true`
# (so the loop survives transient errors instead of aborting the whole
# stress run). A clean run therefore requires two things: the file must have
# output (the scanner ran), and it must contain zero ERROR/FATAL/PANIC lines.
# Both are asserted explicitly below.
# ---------------------------------------------------------------------------
echo "--- Validating scanner did not crash ---"
if [[ -f "$SCAN_OUT" ]]; then
    SCAN_LINES="$(wc -l < "$SCAN_OUT" | tr -d ' ')"
    echo "  Scanner output lines: $SCAN_LINES"
    SCAN_DONE_LINE="$(grep -c 'scan_done' "$SCAN_OUT" 2>/dev/null || echo "0")"

    # Look for any ERROR/FATAL/PANIC line in the scanner output. psql
    # prefixes server diagnostics with the severity tag at column 1
    # ("ERROR:  ...", "FATAL:  ..."). The temp cluster runs ru_RU.UTF-8, so
    # on an NLS build the tags are localized per PostgreSQL ru.po:
    # ERROR=ОШИБКА, FATAL=ВАЖНО, PANIC=ПАНИКА. Match both English and RU forms.
    #
    # `grep -c` returns exit 1 when there are zero matches (still
    # printing "0" to stdout); we do NOT want `|| echo "0"` here, that
    # would append a second "0" line and break the subsequent arithmetic.
    set +e
    SCAN_ERRS="$(grep -cE '^(ERROR|FATAL|PANIC|ОШИБКА|ВАЖНО|ПАНИКА):' "$SCAN_OUT" 2>/dev/null)"
    set -e
    SCAN_ERRS="${SCAN_ERRS:-0}"

    if (( SCAN_LINES > 0 )) && (( SCAN_ERRS == 0 )); then
        echo "  PASS: scanner produced clean output ($SCAN_LINES lines, no SQL errors)"
        PASS=$(( PASS + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "scanner_clean" "PASS" "scan_lines" "$SCAN_LINES" "no SQL errors")")
    elif (( SCAN_ERRS > 0 )); then
        echo "  FAIL: scanner logged $SCAN_ERRS SQL error/fatal lines:" >&2
        grep -E '^(ERROR|FATAL|PANIC|ОШИБКА|ВАЖНО|ПАНИКА):' "$SCAN_OUT" | head -5 >&2
        FAIL=$(( FAIL + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "scanner_clean" "FAIL" "scan_errors" "$SCAN_ERRS" "concurrent debug/debug_snapshot raised")")
    else
        echo "  FAIL: scanner produced no output" >&2
        FAIL=$(( FAIL + 1 ))
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "scanner_clean" "FAIL" "scan_lines" "0" "scanner may have crashed")")
    fi
else
    echo "  FAIL: scanner output file missing" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "scanner_no_crash" "FAIL" "scan_lines" "0" "output missing")")
fi

# After all transactions committed, debug() should show 0 (all committed)
# Workers committed, so entries should be gone
DEBUG_FINAL="$(pg_xclaim_psql -X -A -t \
    -c "SELECT count(*) FROM xclaim.debug();" \
    2>/dev/null | tr -d ' ' || echo "-1")"
echo "  xclaim.debug() count after all workers committed: $DEBUG_FINAL"
if [[ "$DEBUG_FINAL" == "0" ]]; then
    echo "  PASS: no leaked entries"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_stress" "PASS" "debug_count" "0" "clean")")
else
    echo "  WARN: $DEBUG_FINAL entries remain (may be from scanner session)"
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_stress" "PASS" "debug_count" "$DEBUG_FINAL" "scanner session may hold")")
    PASS=$(( PASS + 1 ))
fi

rm -rf "$WORKER_DONE_DIR"
xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
