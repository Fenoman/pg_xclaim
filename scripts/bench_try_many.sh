#!/usr/bin/env bash
# scripts/bench_try_many.sh -- performance budget gate.
#
# Validates the two latency budgets against the current build:
#   - Single-backend SCALAR API at 750k cardinality:  total acquire <= 2000ms
#   - Single-backend BULK   API at 750k cardinality:  total acquire <=  500ms
#
# Semantic gate: a timing counts only when the run really took N claims.
# Each timed transaction reports the number of true results, the local
# claim count (xclaim.count()) and the shared one (capacity_used of
# xclaim.stats()), and all three must equal N. capacity_errors must stay 0.
#
# Also benchmarks the `pg_try_advisory_xact_lock` baseline at 750k for
# delta reporting.
#
# Output:
#   - human-readable pass/fail to stdout
#   - CSV row appended to docs/perf/bench-{date}-pg{major}.csv
#
# Usage:
#   scripts/bench_try_many.sh                     # auto-discover PG 17
#   scripts/bench_try_many.sh /path/to/pg_config  # explicit
#   N=750000 scripts/bench_try_many.sh            # override cardinality
#   scripts/bench_try_many.sh --soft              # don't exit non-zero on
#                                                   budget overruns (CI noise),
#                                                   errors and the semantic
#                                                   gate still fail
#
# Exit:
#   0   all budgets met (or --soft) and the semantic gate passed
#   1   one or more budgets exceeded, or the semantic gate failed
#   2   bench infrastructure failure (cluster, psql, an SQL error)
#
# HARD INVARIANTS:
#   - set -euo pipefail
#   - /tmp temp cluster only, trap cleanup
#   - locale ru_RU.UTF-8

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SOFT_FAIL=0
PG_CONFIG_BIN=""
N="${N:-750000}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --soft) SOFT_FAIL=1; shift ;;
        -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
        *)
            if [[ -z "$PG_CONFIG_BIN" ]]; then
                PG_CONFIG_BIN="$1"; shift
            else
                echo "unknown arg: $1" >&2; exit 2
            fi
            ;;
    esac
done

if [[ -z "$PG_CONFIG_BIN" ]]; then
    PG_CONFIG_BIN="${PG_CONFIG:-}"
fi
if [[ -z "$PG_CONFIG_BIN" ]]; then
    PG_CONFIG_BIN="$("$SCRIPT_DIR/find_pg_config.sh" 17)"
fi
[[ -x "$PG_CONFIG_BIN" ]] || { echo "no usable pg_config: $PG_CONFIG_BIN" >&2; exit 2; }

PG_MAJOR="$("$PG_CONFIG_BIN" --version 2>/dev/null | awk '{print $2}' | awk -F. '{print $1}')"
PERF_DIR="$ROOT_DIR/docs/perf"
mkdir -p "$PERF_DIR"
DATE_TAG="$(date -u +%Y%m%d)"
CSV_OUT="$PERF_DIR/bench-${DATE_TAG}-pg${PG_MAJOR}.csv"

# Locale preflight: initdb dies with an opaque error if ru_RU.UTF-8 is
# absent. Probe up-front so the failure message names the actual cause.
if ! { locale -a 2>/dev/null || true; } | grep -qiE "ru_RU\.(UTF-8|utf8)"; then
    echo "bench_try_many: locale ru_RU.UTF-8 not installed (required by initdb)" >&2
    echo "  install it (e.g. 'localedef -i ru_RU -f UTF-8 ru_RU.UTF-8') and retry" >&2
    exit 2
fi

# Performance budgets -- milliseconds.
BUDGET_SCALAR_MS=2000
BUDGET_BULK_MS=500

echo "bench_try_many: PG_CONFIG=$PG_CONFIG_BIN  PG_MAJOR=$PG_MAJOR  N=$N"
echo "bench_try_many: budgets scalar<=${BUDGET_SCALAR_MS}ms bulk<=${BUDGET_BULK_MS}ms"
echo "bench_try_many: CSV=$CSV_OUT"

# ---------------------------------------------------------------------------
# Bring up temp cluster
# ---------------------------------------------------------------------------
PGBIN="$("$PG_CONFIG_BIN" --bindir)"
PGCTL="$PGBIN/pg_ctl"
PSQL="$PGBIN/psql"
INITDB="$PGBIN/initdb"

PGDATA="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.bench.XXXXXX")"
PGPORT="$(python3 -c '
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(("127.0.0.1", 0)); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    print(s.getsockname()[1])
')"
PGSOCKET="$PGDATA"

cleanup() {
    "$PGCTL" stop -D "$PGDATA" -m immediate >/dev/null 2>&1 || true
    rm -rf "${PGDATA:?}"
}
trap cleanup EXIT INT TERM

# Capture initdb output: a swallowed failure (e.g. missing locale) would
# otherwise die silently with no diagnostic.
if ! INITDB_OUT="$("$INITDB" -D "$PGDATA" --locale=ru_RU.UTF-8 -E UTF8 --auth=trust -U postgres 2>&1)"; then
    echo "bench: initdb failed, output follows:" >&2
    printf '%s\n' "$INITDB_OUT" >&2
    exit 2
fi

# Sized for 750k acquisitions in a single backend: bump above default.
{
    echo "shared_preload_libraries = 'pg_xclaim'"
    echo "port = $PGPORT"
    echo "unix_socket_directories = '$PGSOCKET'"
    echo "pg_xclaim.max_claims = 1048576"
    echo "pg_xclaim.num_partitions = 128"
    echo "pg_xclaim.expected_claims_per_backend = 16384"
    echo "log_min_messages = warning"
    echo "logging_collector = off"
} >> "$PGDATA/postgresql.conf"

# The locale is passed inline, so callers need not export it: on macOS a
# postmaster started with LC_ALL and LANG unset exits with FATAL
# "postmaster became multithreaded during startup".
LC_ALL=ru_RU.UTF-8 LANG=ru_RU.UTF-8 \
"$PGCTL" start -D "$PGDATA" -w -l "$PGDATA/server.log" -o "-p $PGPORT" >/dev/null 2>&1 || {
    echo "bench: pg_ctl start failed" >&2
    tail -50 "$PGDATA/server.log" >&2 || true
    exit 2
}

"$PSQL" -h "$PGSOCKET" -p "$PGPORT" -U postgres -d postgres \
    -v ON_ERROR_STOP=1 \
    -c "CREATE EXTENSION pg_xclaim;" >/dev/null

# ---------------------------------------------------------------------------
# Single timed run wrapper -- emits ms (integer) on stdout.
# Uses python3 monotonic clock around a single psql invocation. We also
# check the count to ensure no false-positive (e.g. function returning NULL).
# ---------------------------------------------------------------------------
run_query_ms() {
    # Args: <sql> [allow_fail=0|1]
    # Emits on stdout:
    #   line 1:  elapsed milliseconds (or empty on an allowed failure)
    #   line 2+: every non-empty data line of the psql output
    local sql="$1"
    local allow_fail="${2:-0}"
    python3 - "$sql" "$allow_fail" <<EOF
import os, subprocess, sys, time
sql = sys.argv[1]
allow_fail = sys.argv[2] == "1"
t0 = time.monotonic()
r = subprocess.run(
    ["$PSQL", "-h", "$PGSOCKET", "-p", "$PGPORT", "-U", "postgres", "-d", "postgres",
     "-X", "-At", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql],
    capture_output=True, text=True)
t1 = time.monotonic()
elapsed_ms = int(round((t1 - t0) * 1000))
if r.returncode != 0:
    if not allow_fail:
        sys.stderr.write(r.stderr)
        sys.exit(2)
    # Fall through with empty timing -- caller will see ""
    print("")
    sys.stderr.write("[bench] (allowed failure) " + r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "[bench] failure with empty stderr")
    sys.stderr.write("\n")
    sys.exit(0)
print(elapsed_ms)
# Data lines (skip BEGIN/COMMIT/ROLLBACK echoes from psql -q).
for l in r.stdout.splitlines():
    if l.strip() and l.strip() not in ("BEGIN", "COMMIT", "ROLLBACK"):
        print(l)
EOF
}

# Value of the "name=value" line in the output of run_query_ms, empty if absent.
result_value() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

# All work happens inside a single transaction so cleanup happens at
# ROLLBACK. Before the ROLLBACK the transaction reports the true results
# (wins), the local claim count and the shared one: the semantic gate
# expects each to equal $N.
CLAIM_COUNTS_SQL="SELECT 'local=' || xclaim.count(); SELECT 'shared=' || capacity_used FROM xclaim.stats();"

# ---------------------------------------------------------------------------
# Bench 1: SCALAR API -- xclaim.try(1, g) over generate_series(1, N)
# ---------------------------------------------------------------------------
SCALAR_SQL="BEGIN; SELECT 'wins=' || count(*) FROM generate_series(1, $N) g WHERE xclaim.try(1, g::int); $CLAIM_COUNTS_SQL ROLLBACK;"

echo ""
echo "[bench] SCALAR xclaim.try(1, g) x $N ..."
if ! SCALAR_RESULT="$(run_query_ms "$SCALAR_SQL")"; then
    echo "bench: SCALAR query failed" >&2
    exit 2
fi
SCALAR_MS="$(printf '%s\n' "$SCALAR_RESULT" | sed -n '1p')"
SCALAR_COUNT="$(result_value "$SCALAR_RESULT" wins)"
SCALAR_LOCAL="$(result_value "$SCALAR_RESULT" local)"
SCALAR_SHARED="$(result_value "$SCALAR_RESULT" shared)"
echo "  -> ${SCALAR_MS}ms  true=$SCALAR_COUNT local=$SCALAR_LOCAL shared=$SCALAR_SHARED"

# ---------------------------------------------------------------------------
# Bench 2: BULK API -- xclaim.try_many(1, ARRAY(1..N))
# The true results are counted by removing false and NULL elements from
# the result array: a C-level pass, so it adds little to the timing.
# ---------------------------------------------------------------------------
BULK_SQL="BEGIN; SELECT 'wins=' || cardinality(array_remove(array_remove(xclaim.try_many(1, array_agg(g::int)), false), NULL)) FROM generate_series(1, $N) g; $CLAIM_COUNTS_SQL ROLLBACK;"

echo "[bench] BULK   xclaim.try_many(1, [1..$N]) ..."
if ! BULK_RESULT="$(run_query_ms "$BULK_SQL")"; then
    echo "bench: BULK query failed" >&2
    exit 2
fi
BULK_MS="$(printf '%s\n' "$BULK_RESULT" | sed -n '1p')"
BULK_COUNT="$(result_value "$BULK_RESULT" wins)"
BULK_LOCAL="$(result_value "$BULK_RESULT" local)"
BULK_SHARED="$(result_value "$BULK_RESULT" shared)"
echo "  -> ${BULK_MS}ms  true=$BULK_COUNT local=$BULK_LOCAL shared=$BULK_SHARED"

# ---------------------------------------------------------------------------
# Bench 3: BASELINE -- pg_try_advisory_xact_lock(1, g) over generate_series
# Reference for delta reporting, NOT budget-gated.
#
# Allow-fail rationale: 750k advisory locks blow `max_locks_per_transaction`
# on default settings -- this is exactly the LockManager failure mode that
# pg_xclaim was designed to avoid. If the baseline OOMs the lock table, we
# capture "n/a" and continue. CI runners get the same behaviour.
# ---------------------------------------------------------------------------
ADV_SQL="BEGIN; SELECT count(*) FROM generate_series(1, $N) g WHERE pg_try_advisory_xact_lock(1::int, g::int); ROLLBACK;"

echo "[bench] BASELINE pg_try_advisory_xact_lock x $N (allow-fail) ..."
ADV_RESULT="$(run_query_ms "$ADV_SQL" 1 || true)"
ADV_MS="$(printf '%s\n' "$ADV_RESULT" | sed -n '1p')"
ADV_COUNT="$(printf '%s\n' "$ADV_RESULT" | sed -n '$p')"
if [[ -z "$ADV_MS" ]]; then
    ADV_MS="n/a"
    ADV_COUNT="oom"
fi
echo "  -> ${ADV_MS}ms  count=$ADV_COUNT"

# ---------------------------------------------------------------------------
# Stats snapshot
# ---------------------------------------------------------------------------
if ! STATS="$("$PSQL" -h "$PGSOCKET" -p "$PGPORT" -U postgres -d postgres \
    -X -At -F '|' -v ON_ERROR_STOP=1 \
    -c "SELECT capacity_errors, cleanup_misses, reaped_stale FROM xclaim.stats();" 2>&1)"; then
    echo "bench: xclaim.stats() query failed: $STATS" >&2
    exit 2
fi
echo "[bench] xclaim.stats() (capacity_errors|cleanup_misses|reaped_stale): $STATS"
CAPACITY_ERRORS="$(cut -d'|' -f1 <<<"$STATS")"

# ---------------------------------------------------------------------------
# Verdict + CSV
# ---------------------------------------------------------------------------
PASS_SCALAR=0
PASS_BULK=0
[[ "$SCALAR_MS" =~ ^[0-9]+$ ]] && (( SCALAR_MS <= BUDGET_SCALAR_MS )) && PASS_SCALAR=1
[[ "$BULK_MS"   =~ ^[0-9]+$ ]] && (( BULK_MS   <= BUDGET_BULK_MS   )) && PASS_BULK=1

# Semantic gate: every count equals N and no capacity error happened.
# Soft mode does not apply here.
SEMANTIC_OK=1
for check in "scalar true:$SCALAR_COUNT" "scalar local:$SCALAR_LOCAL" "scalar shared:$SCALAR_SHARED" \
             "bulk true:$BULK_COUNT" "bulk local:$BULK_LOCAL" "bulk shared:$BULK_SHARED"; do
    if [[ "${check#*:}" != "$N" ]]; then
        echo "  FAIL  ${check%%:*} = '${check#*:}' (expected $N)" >&2
        SEMANTIC_OK=0
    fi
done
if [[ "$CAPACITY_ERRORS" != "0" ]]; then
    echo "  FAIL  capacity_errors = '$CAPACITY_ERRORS' (expected 0)" >&2
    SEMANTIC_OK=0
fi

echo ""
echo "================================================================"
echo " VERDICT (perf budget)"
echo "================================================================"
if (( SEMANTIC_OK )); then
    echo "  PASS  semantic gate: $N true results, local and shared claim counts, capacity_errors=0"
else
    echo "  FAIL  semantic gate, the timings are not valid" >&2
    exit 1
fi
if (( PASS_SCALAR )); then
    echo "  PASS  scalar 750k = ${SCALAR_MS}ms (budget ${BUDGET_SCALAR_MS}ms)"
else
    echo "  FAIL  scalar 750k = ${SCALAR_MS}ms (budget ${BUDGET_SCALAR_MS}ms)" >&2
fi
if (( PASS_BULK )); then
    echo "  PASS  bulk   750k = ${BULK_MS}ms (budget ${BUDGET_BULK_MS}ms)"
else
    echo "  FAIL  bulk   750k = ${BULK_MS}ms (budget ${BUDGET_BULK_MS}ms)" >&2
fi
echo "  INFO  advisory baseline = ${ADV_MS}ms"

# CSV: timestamp,pg_major,N,scalar_ms,bulk_ms,advisory_ms,scalar_pass,bulk_pass,stats_capacity_errors|cleanup_misses|reaped_stale
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HEADER="timestamp,pg_major,N,scalar_ms,bulk_ms,advisory_ms,scalar_pass,bulk_pass,stats"
ROW="${TS},${PG_MAJOR},${N},${SCALAR_MS},${BULK_MS},${ADV_MS},${PASS_SCALAR},${PASS_BULK},\"${STATS}\""

if [[ ! -f "$CSV_OUT" ]]; then
    echo "$HEADER" > "$CSV_OUT"
fi
echo "$ROW" >> "$CSV_OUT"
echo "  CSV row appended -> $CSV_OUT"

if (( PASS_SCALAR && PASS_BULK )); then
    exit 0
fi
if (( SOFT_FAIL )); then
    echo "  (soft mode: returning 0 despite budget overrun)" >&2
    exit 0
fi
exit 1
