#!/usr/bin/env bash
# test/concurrency/debug_scan_stress.sh
# Debug scan stress (concurrent acquire + debug scans).
#
# Scenario:
#   5 sessions concurrently acquire 1000 unique keys each (no overlap)
#   1 concurrent session calls xclaim.debug() and xclaim.debug_snapshot()
#   every 100ms while the workers run.
#
# Barrier. Each worker keeps its transaction open after its try_many until
# the scanner has seen claims in both functions (a row in table scan_seen,
# at most 20 s), so the scans copy a non-empty table whatever the
# scheduling.
#
# Checks:
#   * every worker psql exits 0 and its try_many takes all 1000 keys
#   * the scanner sees at least one claim in xclaim.debug() and in
#     xclaim.debug_snapshot(), every scanner psql exits 0 and its output
#     has no ERROR, FATAL or PANIC line
#   * the scanner exits within 10 s of the stop signal
#   * after all workers commit, xclaim.debug() shows no entries
#   * the server log has no FATAL or PANIC line
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

pg_xclaim_psql -X -q -v ON_ERROR_STOP=1 -c "CREATE TABLE scan_seen (ok int);"

# ---------------------------------------------------------------------------
# Launch worker sessions (each in its own transaction, acquiring disjoint
# ranges). psql itself is the background job, so wait returns its status.
# ---------------------------------------------------------------------------
WORKER_PIDS=()
for i in $(seq 1 $N_WORKERS); do
    START_KEY=$(( (i - 1) * KEYS_PER_WORKER + 1 ))
    END_KEY=$(( i * KEYS_PER_WORKER ))
    WORKER_OUT="$WORKER_DONE_DIR/worker_${i}.out"
    "$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d postgres \
        -X -A -t -v ON_ERROR_STOP=1 \
        -c "BEGIN;
            SELECT count(v) FROM unnest(
                xclaim.try_many(1, ARRAY(
                    SELECT generate_series($START_KEY, $END_KEY)::int4
                ))
            ) v WHERE v;
            DO \$\$ BEGIN
                FOR i IN 1..400 LOOP
                    EXIT WHEN EXISTS (SELECT 1 FROM scan_seen);
                    PERFORM pg_sleep(0.05);
                END LOOP;
            END \$\$;
            COMMIT;" \
        >"$WORKER_OUT" 2>&1 &
    WORKER_PIDS+=($!)
    BGPIDS+=($!)
done

# ---------------------------------------------------------------------------
# Scanner session: run debug() and debug_snapshot() while workers run. The
# stop file is checked after each scan, so the scanner scans at least once.
# A successful call prints debug=N or snapshot=N, a failed psql prints its
# exit status as scan_rc=N. The first scan in which both functions return
# claims releases the workers (scan_seen).
# ---------------------------------------------------------------------------
SCAN_OUT="$WORKER_DONE_DIR/scan.out"
(
    released=false
    while :; do
        if out="$("$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d postgres \
                -X -A -t -v ON_ERROR_STOP=1 \
                -c "SELECT 'debug=' || count(*) FROM xclaim.debug();" \
                -c "SELECT 'snapshot=' || count(*) FROM xclaim.debug_snapshot();" 2>&1)"; then
            rc=0
        else
            rc=$?
        fi
        printf '%s\n' "$out" >>"$SCAN_OUT"
        (( rc == 0 )) || echo "scan_rc=$rc" >>"$SCAN_OUT"
        if ! $released && grep -qE '^debug=[1-9]' <<<"$out" && grep -qE '^snapshot=[1-9]' <<<"$out"; then
            "$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U postgres -d postgres \
                -X -q -v ON_ERROR_STOP=1 -c "INSERT INTO scan_seen VALUES (1);" \
                >>"$SCAN_OUT" 2>&1 || echo "scan_rc=$?" >>"$SCAN_OUT"
            released=true
        fi
        [[ -f "$SCAN_STOP" ]] && break
        sleep "$SCAN_INTERVAL_S"
    done
) &
SCAN_PID=$!
BGPIDS+=($SCAN_PID)

# Wait for all workers to complete and keep each exit status.
WORKER_RCS=()
for idx in "${!WORKER_PIDS[@]}"; do
    if wait "${WORKER_PIDS[idx]}"; then rc=0; else rc=$?; fi
    WORKER_RCS[idx]=$rc
done

# Stop the scanner: it finishes its current scan and exits.
touch "$SCAN_STOP"
SCAN_STOPPED=false
for _ in $(seq 1 100); do
    if ! kill -0 "$SCAN_PID" 2>/dev/null; then
        SCAN_STOPPED=true
        break
    fi
    sleep 0.1
done
$SCAN_STOPPED || kill "$SCAN_PID" 2>/dev/null || true
wait "$SCAN_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Validate: each worker should have acquired KEYS_PER_WORKER keys
# ---------------------------------------------------------------------------
echo "--- Validating worker results ---"
TOTAL_ACQUIRED=0
for i in $(seq 1 $N_WORKERS); do
    WORKER_OUT="$WORKER_DONE_DIR/worker_${i}.out"
    WORKER_RC="${WORKER_RCS[i - 1]}"
    if [[ -f "$WORKER_OUT" ]]; then
        WORKER_COUNT="$(grep -E '^[0-9]+$' "$WORKER_OUT" | head -1 | tr -d ' ' || true)"
        WORKER_COUNT="${WORKER_COUNT:-0}"
        echo "  Worker $i: psql exit $WORKER_RC, acquired $WORKER_COUNT / $KEYS_PER_WORKER keys"
        TOTAL_ACQUIRED=$(( TOTAL_ACQUIRED + WORKER_COUNT ))
        if [[ "$WORKER_RC" == "0" && "$WORKER_COUNT" == "$KEYS_PER_WORKER" ]]; then
            CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "worker_${i}_count" "PASS" "acquired" "$WORKER_COUNT" "$KEYS_PER_WORKER expected")")
        else
            echo "  FAIL: worker $i: psql exit $WORKER_RC, acquired $WORKER_COUNT, expected exit 0 and $KEYS_PER_WORKER, output follows:" >&2
            sed 's/^/    /' "$WORKER_OUT" >&2
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
# Validate the scanner: at least one successful call of each function, no
# failed psql, no ERROR/FATAL/PANIC line, and an exit after the stop signal.
#
# psql prefixes server diagnostics with the severity tag at column 1
# ("ERROR:  ...", "FATAL:  ..."). On an NLS build the ru_RU.UTF-8 cluster
# localizes the tags per PostgreSQL ru.po (ERROR=ОШИБКА, FATAL=ВАЖНО,
# PANIC=ПАНИКА), so both forms are matched.
# ---------------------------------------------------------------------------
echo "--- Validating the scanner ---"
DEBUG_CALLS="$(grep -cE '^debug=[1-9][0-9]*$' "$SCAN_OUT" 2>/dev/null || true)"
SNAPSHOT_CALLS="$(grep -cE '^snapshot=[1-9][0-9]*$' "$SCAN_OUT" 2>/dev/null || true)"
SCAN_FAILS="$(grep -cE '^scan_rc=' "$SCAN_OUT" 2>/dev/null || true)"
SCAN_ERRS="$(grep -cE '^(ERROR|FATAL|PANIC|ОШИБКА|ВАЖНО|ПАНИКА):' "$SCAN_OUT" 2>/dev/null || true)"
DEBUG_CALLS="${DEBUG_CALLS:-0}"
SNAPSHOT_CALLS="${SNAPSHOT_CALLS:-0}"
SCAN_FAILS="${SCAN_FAILS:-0}"
SCAN_ERRS="${SCAN_ERRS:-0}"
echo "  Scanner: debug() $DEBUG_CALLS calls with claims, debug_snapshot() $SNAPSHOT_CALLS calls with claims, failed psql runs $SCAN_FAILS, error lines $SCAN_ERRS, stopped on signal: $SCAN_STOPPED"

if (( DEBUG_CALLS >= 1 && SNAPSHOT_CALLS >= 1 && SCAN_FAILS == 0 && SCAN_ERRS == 0 )) && $SCAN_STOPPED; then
    echo "  PASS: scanner saw claims in both functions with no errors"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "scanner_clean" "PASS" "debug_calls" "$DEBUG_CALLS" "snapshot calls $SNAPSHOT_CALLS")")
else
    echo "  FAIL: the scanner needs >= 1 debug() and debug_snapshot() call that returns claims, no failed psql, no error lines and an exit on the stop signal. The workers hold their claims at most 20 s waiting for such a scan. Output follows:" >&2
    head -20 "$SCAN_OUT" 2>/dev/null | sed 's/^/    /' >&2 || true
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "scanner_clean" "FAIL" "debug_calls" "$DEBUG_CALLS" "snapshot $SNAPSHOT_CALLS failed $SCAN_FAILS errors $SCAN_ERRS stopped $SCAN_STOPPED")")
fi

# Every worker has committed and the scanner never takes a claim, so the
# shared table must be empty. A failed query is a FAIL, not a count.
if ! DEBUG_FINAL="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 \
        -c "SELECT count(*) FROM xclaim.debug();" 2>&1)"; then
    echo "  FAIL: xclaim.debug() query failed: $DEBUG_FINAL" >&2
    DEBUG_FINAL="error"
fi
echo "  xclaim.debug() count after all workers committed: $DEBUG_FINAL"
if [[ "$DEBUG_FINAL" == "0" ]]; then
    echo "  PASS: no leaked entries"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_stress" "PASS" "debug_count" "0" "clean")")
else
    echo "  FAIL: '$DEBUG_FINAL' entries remain after all workers committed" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_stress" "FAIL" "debug_count" "$DEBUG_FINAL" "leaked or query failed")")
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
