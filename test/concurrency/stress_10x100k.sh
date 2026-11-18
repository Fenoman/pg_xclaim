#!/usr/bin/env bash
# test/concurrency/stress_10x100k.sh
# Stress test: 10 backends x 100k claims concurrent.
#
# Scenario:
#   10 backends in parallel, each: BEGIN; xclaim.try_many(1, <its own 100k keys>); COMMIT
#   Verify: no crash, no advisory lock bleed-through, no leaked entries.
#   Additionally: per-partition occupancy histogram for hash distribution sanity.
#
# Pass criterion and output:
#   * 10 concurrent backends x 100k claims MUST sustain without errors.
#   * Metrics go to baseline-<UTC date>.csv in $XCLAIM_BASELINE_DIR (default
#     $TMPDIR or /tmp) for perf-trend tracking. A later run on the same date
#     overwrites the file.
#
# NOTE: This is an accept/reject test. The actual latency numbers depend heavily
# on hardware. We record metrics but only fail on correctness violations.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="stress_10x100k"
N_BACKENDS=10
KEYS_PER_BACKEND=100000
SCOPE=1

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

# Temp files/dirs registered here are removed even when an assertion aborts
# the script early (set -e), not only on the success path.
XCLAIM_TMPFILES=()
cleanup_stress() {
    rm -rf "${XCLAIM_TMPFILES[@]:-}"
    pg_xclaim_stop_temp_cluster
}
trap cleanup_stress EXIT INT TERM

# Need max_claims >= N_BACKENDS * KEYS_PER_BACKEND = 1,000,000 for all to fit
# Use 1,100,000 to have headroom
XCLAIM_MAX_CLAIMS=1100000 pg_xclaim_start_temp_cluster "stress10x100k"

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Pre-flight: stats before
# ---------------------------------------------------------------------------
STATS_BEFORE="$(pg_xclaim_psql -X -A -t \
    -c "SELECT capacity_errors, cleanup_misses, disabled_calls FROM xclaim.stats();" \
    2>/dev/null || echo "0|0|0")"
echo "Stats before: $STATS_BEFORE"

# ---------------------------------------------------------------------------
# Launch N_BACKENDS parallel workers
# ---------------------------------------------------------------------------
echo "--- Stress: $N_BACKENDS backends x $KEYS_PER_BACKEND keys ---"

WORK_DIR="$(mktemp -d)"
XCLAIM_TMPFILES+=("$WORK_DIR")
BGPIDS=()

T_STRESS_START="$(xclaim_now_ms)"

for i in $(seq 1 $N_BACKENDS); do
    OUT="$WORK_DIR/backend_${i}.out"
    START_KEY=$(( (i - 1) * KEYS_PER_BACKEND + 1 ))
    END_KEY=$(( i * KEYS_PER_BACKEND ))
    # lc_messages=C (via PGOPTIONS, the server translates its diagnostics,
    # not psql) keeps the "^(ERROR|FATAL|PANIC):" scan below independent of
    # the temp cluster's ru_RU.UTF-8 locale. ON_ERROR_STOP makes an error
    # visible in the exit status of psql as well.
    PGOPTIONS='-c lc_messages=C' "$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" \
        -U postgres -d postgres \
        -X -A -t -v ON_ERROR_STOP=1 \
        -c "BEGIN; SELECT count(v) FROM unnest(xclaim.try_many($SCOPE, ARRAY(SELECT generate_series($START_KEY, $END_KEY)::int4))) v WHERE v; COMMIT;" \
        >"$OUT" 2>&1 &
    BGPIDS+=($!)
done

# Wait for all backends to complete and keep each exit status.
BG_RCS=()
for pid in "${BGPIDS[@]}"; do
    if wait "$pid"; then BG_RCS+=(0); else BG_RCS+=($?); fi
done

T_STRESS_END="$(xclaim_now_ms)"
STRESS_WALL_MS=$(( T_STRESS_END - T_STRESS_START ))

echo "  Wall time for $N_BACKENDS x $KEYS_PER_BACKEND: ${STRESS_WALL_MS}ms"
CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "stress_wall_time" "PASS" "wall_ms" "$STRESS_WALL_MS" "$N_BACKENDS x $KEYS_PER_BACKEND keys")")

# ---------------------------------------------------------------------------
# Validate worker results
# ---------------------------------------------------------------------------
echo "--- Validating worker results ---"
TOTAL_WINS=0
ALL_OK=true

for i in $(seq 1 $N_BACKENDS); do
    OUT="$WORK_DIR/backend_${i}.out"
    if [[ -f "$OUT" ]]; then
        # Extract the numeric count (psql -A -t outputs raw values, and "BEGIN",
        # "COMMIT" are not numeric). Take the first numeric line as-is: a 0 win
        # count is a legitimate result that must not be silently discarded.
        WIN_COUNT="$(grep -E '^[0-9]+$' "$OUT" | head -1 | tr -d ' ' 2>/dev/null || true)"
        WIN_COUNT="${WIN_COUNT:-0}"
        # Count actual ERROR/FATAL/PANIC lines
        ERROR_LINES=0
        if grep -qE "^(ERROR|FATAL|PANIC):" "$OUT" 2>/dev/null; then
            ERROR_LINES="$(grep -cE "^(ERROR|FATAL|PANIC):" "$OUT" 2>/dev/null || echo "0")"
        fi
        BG_RC="${BG_RCS[i - 1]}"
        echo "  Backend $i: wins=$WIN_COUNT errors=$ERROR_LINES psql_rc=$BG_RC"

        if [[ "$ERROR_LINES" != "0" ]] || [[ "$BG_RC" != "0" ]]; then
            echo "  FAIL: backend $i had errors (psql exit status $BG_RC)" >&2
            grep -E "^(ERROR|FATAL|PANIC):|connection" "$OUT" | head -3 | sed 's/^/    /' >&2 || true
            ALL_OK=false
            CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "backend_${i}_errors" "FAIL" "errors" "$ERROR_LINES" "backend errored")")
        else
            CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "backend_${i}_wins" "PASS" "wins" "$WIN_COUNT" "no errors")")
        fi
        TOTAL_WINS=$(( TOTAL_WINS + WIN_COUNT ))
    else
        echo "  WARN: no output file for backend $i" >&2
        ALL_OK=false
    fi
done

EXPECTED_TOTAL=$(( N_BACKENDS * KEYS_PER_BACKEND ))
echo "  Total wins: $TOTAL_WINS / $EXPECTED_TOTAL"

# Each backend acquires keys (i-1)*KEYS_PER_BACKEND+1 .. i*KEYS_PER_BACKEND.
# Those ranges are disjoint by construction, so on a clean run every key has
# exactly one winner and TOTAL_WINS == EXPECTED_TOTAL. A short count therefore
# means real lost acquisitions, not benign overlap -- it is a FAIL.
if $ALL_OK && [[ "$TOTAL_WINS" == "$EXPECTED_TOTAL" ]]; then
    echo "  PASS: all backends acquired all expected keys, no errors"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "total_wins" "PASS" "total_wins" "$TOTAL_WINS" "all workers clean")")
elif $ALL_OK; then
    echo "  FAIL: no errors but wins=$TOTAL_WINS != expected $EXPECTED_TOTAL (disjoint ranges must all win)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "total_wins" "FAIL" "total_wins" "$TOTAL_WINS" "expected $EXPECTED_TOTAL")")
else
    echo "  FAIL: some backends errored" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "total_wins" "FAIL" "total_wins" "$TOTAL_WINS" "errors detected")")
fi

# ---------------------------------------------------------------------------
# No advisory lock bleed-through
# ---------------------------------------------------------------------------
echo "--- Checking: zero advisory locks in pg_locks ---"
ADVISORY_COUNT="$(pg_xclaim_psql -X -A -t \
    -c "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory';" \
    2>/dev/null | tr -d ' ' || echo "-1")"
echo "  pg_locks advisory count: $ADVISORY_COUNT"

if [[ "$ADVISORY_COUNT" == "0" ]]; then
    echo "  PASS: zero advisory locks (xclaim does not use advisory lock mechanism)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_advisory_locks" "PASS" "advisory_count" "0" "clean")")
else
    echo "  FAIL: $ADVISORY_COUNT advisory locks visible" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_advisory_locks" "FAIL" "advisory_count" "$ADVISORY_COUNT" "bleed-through detected")")
fi

# ---------------------------------------------------------------------------
# Stats: capacity_errors and cleanup_misses must be 0
# ---------------------------------------------------------------------------
echo "--- Checking stats for correctness ---"
# A failed query yields "error", which fails both checks below.
if ! STATS_AFTER="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 \
        -c "SELECT capacity_errors, cleanup_misses, disabled_calls FROM xclaim.stats();" 2>&1)"; then
    echo "  FAIL: xclaim.stats() query failed: $STATS_AFTER" >&2
    STATS_AFTER="error|error|error"
fi
echo "  Stats after (capacity_errors|cleanup_misses|disabled_calls): $STATS_AFTER"

CAP_ERRORS="$(cut -d'|' -f1 <<<"$STATS_AFTER")"
CLEANUP_MISSES="$(cut -d'|' -f2 <<<"$STATS_AFTER")"

if [[ "$CAP_ERRORS" == "0" ]]; then
    echo "  PASS: no capacity_errors"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_capacity_errors" "PASS" "capacity_errors" "0" "")")
else
    echo "  FAIL: capacity_errors=$CAP_ERRORS (increase max_claims?)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_capacity_errors" "FAIL" "capacity_errors" "$CAP_ERRORS" "need larger max_claims")")
fi

if [[ "$CLEANUP_MISSES" == "0" ]]; then
    echo "  PASS: no cleanup_misses"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_cleanup_misses" "PASS" "cleanup_misses" "0" "")")
else
    echo "  FAIL: cleanup_misses=$CLEANUP_MISSES (expected 0)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_cleanup_misses" "FAIL" "cleanup_misses" "$CLEANUP_MISSES" "expected 0")")
fi

# ---------------------------------------------------------------------------
# Per-partition occupancy histogram
# ---------------------------------------------------------------------------
echo "--- Per-partition histogram (hash distribution sanity) ---"

if [[ "$(printf '\001\000' | od -An -tu2 | tr -d ' ')" == "1" ]]; then
    LE_INT4() { echo "regexp_replace(lpad(to_hex(($1)::bigint & 4294967295), 8, '0'), '(..)(..)(..)(..)', '\\4\\3\\2\\1')"; }
    LE_INT8() { echo "regexp_replace(lpad(to_hex($1), 16, '0'), '(..)(..)(..)(..)(..)(..)(..)(..)', '\\8\\7\\6\\5\\4\\3\\2\\1')"; }
    KEY_UUID_EXPR="(($(LE_INT4 'd.database_oid') || '02000000' || $(LE_INT8 '(((d.scope::bigint & 4294967295) << 32) | (d.key & 4294967295))'))::uuid)"
else
    KEY_UUID_EXPR="((lpad(to_hex(d.database_oid::bigint), 8, '0') || '00000002' || lpad(to_hex(((d.scope::bigint & 4294967295) << 32) | (d.key & 4294967295)), 16, '0'))::uuid)"
fi

HIST_STATS="$(pg_xclaim_psql -X -A -t -q -F'|' -v ON_ERROR_STOP=1 <<SQLHIST
BEGIN;
SELECT count(v) > 0 AS ok FROM unnest(
    xclaim.try_many(1, ARRAY(SELECT generate_series(1, 100000)::int4))
) v WHERE v;
WITH cfg AS (
    SELECT current_setting('pg_xclaim.num_partitions')::int AS nparts
),
part_counts AS (
    SELECT (uuid_hash($KEY_UUID_EXPR) & (cfg.nparts - 1)) AS part_id, count(*) AS cnt
    FROM xclaim.debug() d
    CROSS JOIN cfg
    WHERE d.scope = 1
    GROUP BY 1
)
SELECT
    (SELECT sum(cnt) FROM part_counts),
    count(*),
    (SELECT nparts FROM cfg),
    min(cnt),
    max(cnt),
    round(stddev_pop(cnt), 2)
FROM part_counts;
ROLLBACK;
SQLHIST
)"
HIST_LINE="$(echo "$HIST_STATS" | tail -n 1)"
IFS='|' read -r HIST_TOTAL HIST_PARTS HIST_NPARTS HIST_MIN HIST_MAX HIST_STDDEV <<<"$HIST_LINE"
HIST_MEAN=$(( 100000 / ${HIST_NPARTS:-128} ))
HIST_LO=$(( HIST_MEAN * 60 / 100 ))
HIST_HI=$(( HIST_MEAN * 140 / 100 ))
echo "  Histogram (scope=1, 1..100000 across $HIST_NPARTS partitions): total=$HIST_TOTAL parts=$HIST_PARTS min=$HIST_MIN max=$HIST_MAX stddev=$HIST_STDDEV"

if [[ "$HIST_TOTAL" == "100000" && "$HIST_PARTS" == "$HIST_NPARTS" ]] && (( HIST_MIN >= HIST_LO && HIST_MAX <= HIST_HI )); then
    echo "  PASS: uniform per-partition hash distribution (all $HIST_NPARTS partitions active)"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "partition_histogram" "PASS" "min_max_stddev" "${HIST_MIN}/${HIST_MAX}/${HIST_STDDEV}" "${HIST_PARTS}/${HIST_NPARTS} active")")
else
    echo "  FAIL: skewed or incomplete partition histogram: $HIST_LINE" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "partition_histogram" "FAIL" "min_max_stddev" "$HIST_LINE" "expected $HIST_NPARTS partitions within ${HIST_LO}..${HIST_HI}")")
fi

# Write histogram data to perf baseline.
DOCS_PERF_DIR="${XCLAIM_BASELINE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$DOCS_PERF_DIR"
BASELINE_DATE="$(date -u '+%Y%m%d')"
BASELINE_FILE="$DOCS_PERF_DIR/baseline-${BASELINE_DATE}.csv"

{
    echo "# pg_xclaim stress test baseline - $BASELINE_DATE"
    echo "# concurrent stress baseline (10x100k)"
    echo "timestamp,script,metric,value,notes"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$SCRIPT,n_backends,$N_BACKENDS,concurrent backends"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$SCRIPT,keys_per_backend,$KEYS_PER_BACKEND,keys per backend"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$SCRIPT,total_keys,$EXPECTED_TOTAL,total unique keys"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$SCRIPT,wall_ms,$STRESS_WALL_MS,concurrent wall time"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$SCRIPT,total_wins,$TOTAL_WINS,total successful acquires"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$SCRIPT,advisory_locks,$ADVISORY_COUNT,should be 0"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$SCRIPT,capacity_errors,$CAP_ERRORS,should be 0"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$SCRIPT,partition_min,$HIST_MIN,100000-key sample"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$SCRIPT,partition_max,$HIST_MAX,100000-key sample"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$SCRIPT,partition_stddev,$HIST_STDDEV,100000-key sample"
    for row in "${CSV_ROWS[@]}"; do echo "$row"; done
} > "$BASELINE_FILE"

echo "  Baseline CSV written: $BASELINE_FILE"
CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "baseline_csv" "PASS" "file" "$BASELINE_FILE" "perf baseline")")
PASS=$(( PASS + 1 ))

# ---------------------------------------------------------------------------
# No leaked entries
# ---------------------------------------------------------------------------
echo "--- Final: no leaked entries ---"
DEBUG_FINAL="$(pg_xclaim_psql -X -A -t \
    -c "SELECT count(*) FROM xclaim.debug();" \
    2>/dev/null | tr -d ' ' || echo "-1")"
echo "  xclaim.debug() count: $DEBUG_FINAL"

if [[ "$DEBUG_FINAL" == "0" ]]; then
    echo "  PASS: clean state after stress"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_stress" "PASS" "debug_count" "0" "clean")")
else
    echo "  FAIL: $DEBUG_FINAL entries leaked after stress" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "no_leak_after_stress" "FAIL" "debug_count" "$DEBUG_FINAL" "leaked")")
fi

rm -rf "$WORK_DIR"
xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== STRESS SUMMARY ==="
echo "  $N_BACKENDS backends x $KEYS_PER_BACKEND keys = $EXPECTED_TOTAL total"
echo "  Wall time: ${STRESS_WALL_MS}ms"
echo "  Throughput: $(( EXPECTED_TOTAL * 1000 / (STRESS_WALL_MS + 1) )) acquires/sec"
echo "  Advisory locks: $ADVISORY_COUNT (must be 0)"
echo "  Capacity errors: $CAP_ERRORS (must be 0)"
echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
