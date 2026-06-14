#!/usr/bin/env bash
# scripts/record_perf_evidence.sh
#
# Comprehensive performance evidence pack for pg_xclaim. Per scenario it
# captures THREE measurement layers in a single cluster lifecycle:
#
#   1. CPU attribution -- `perf record -g`, rendered as a FlameGraph SVG +
#      top-15 leaves summary. Answers "where does CPU burn while the
#      process is ON-CPU?".
#   2. Hardware counters -- `perf stat -e <events>` over the same workload.
#      Answers "is this CPU-bound, memory-bound, or branch-bound?".
#      Events: cycles, instructions, cache-misses, LLC-load-misses,
#      branch-misses, page-faults, context-switches, cpu-migrations.
#   3. Wait events -- `pg_wait_sampling` profile snapshot. Answers
#      "what was the backend WAITING on when it was OFF-CPU?". A pure
#      FlameGraph cannot see this; this is the critical complementary
#      data point.
#
# The four scenarios mirror `record_flamegraphs.sh`:
#   1. scalar-acquire        -- single-backend scalar `xclaim.try`
#   2. bulk-try-many         -- single-backend bulk `xclaim.try_many`
#   3. cleanup-commit        -- 50 transactions x 50k commit cleanup
#   4. concurrent-contention -- 10 backends x 100k overlapping keys
#
# Output layout:
#   docs/perf/flamegraphs/<scenario>.svg          -- existing path
#   docs/perf/perf-stat/<scenario>.txt            -- new: HW counters
#   docs/perf/wait-events/<scenario>.csv          -- new: wait_event profile
#
# Usage:
#   sudo scripts/record_perf_evidence.sh                # auto pg_config 17
#   sudo scripts/record_perf_evidence.sh /path/to/pg_config
#
# Requirements:
#   - Linux (perf record); the script aborts on non-Linux.
#   - Run as root (perf needs CAP_PERFMON, kernel symbol resolution needs
#     root, pg_wait_sampling capture queries are unprivileged).
#   - sysctl kernel.kptr_restrict / kernel.perf_event_paranoid handled
#     automatically (lowered, then restored on exit).
#   - FlameGraph repo at /opt/FlameGraph (set FLAMEGRAPH_DIR to override).
#   - pg_wait_sampling installed (postgresql-N-pg-wait-sampling apt package).
#   - A regular OS user under which to run psql/initdb. Defaults to `postgres`.
#     Override via RUN_USER=...
#
# Exit:
#   0  all four scenarios captured.
#   1  infrastructure failure.
#   2  bad arguments.
#
# HARD INVARIANTS:
#   - set -euo pipefail
#   - /tmp temp cluster only; trap cleanup
#   - locale ru_RU.UTF-8

set -euo pipefail

# --- Platform guard -------------------------------------------------------
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "record_perf_evidence: Linux-only (perf is unavailable on $(uname -s))" >&2
    exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
    echo "record_perf_evidence: must run as root (need CAP_PERFMON + kallsyms access)" >&2
    exit 1
fi

# --- Paths ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FLAME_DIR="$ROOT_DIR/docs/perf/flamegraphs"
PERFSTAT_DIR="$ROOT_DIR/docs/perf/perf-stat"
WAITEV_DIR="$ROOT_DIR/docs/perf/wait-events"
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-/opt/FlameGraph}"
RUN_USER="${RUN_USER:-postgres}"

if [[ ! -d "$FLAMEGRAPH_DIR" ]]; then
    echo "record_perf_evidence: FlameGraph not found at $FLAMEGRAPH_DIR" >&2
    echo "  git clone https://github.com/brendangregg/FlameGraph $FLAMEGRAPH_DIR" >&2
    exit 1
fi
if ! id "$RUN_USER" >/dev/null 2>&1; then
    echo "record_perf_evidence: RUN_USER=$RUN_USER does not exist" >&2
    exit 1
fi

# Locale preflight: initdb dies with an opaque error if ru_RU.UTF-8 is
# absent. Probe up-front so the failure message names the actual cause.
if ! { locale -a 2>/dev/null || true; } | grep -qiE "ru_RU\.(UTF-8|utf8)"; then
    echo "record_perf_evidence: locale ru_RU.UTF-8 not installed (required by initdb)" >&2
    echo "  install it (e.g. 'localedef -i ru_RU -f UTF-8 ru_RU.UTF-8') and retry" >&2
    exit 1
fi

mkdir -p "$FLAME_DIR" "$PERFSTAT_DIR" "$WAITEV_DIR"

# --- Discover pg_config ---------------------------------------------------
PG_CONFIG_BIN="${1:-${PG_CONFIG:-}}"
if [[ -z "$PG_CONFIG_BIN" ]]; then
    if [[ -x "$SCRIPT_DIR/find_pg_config.sh" ]]; then
        PG_CONFIG_BIN="$("$SCRIPT_DIR/find_pg_config.sh" 17 2>/dev/null || true)"
    fi
fi
if [[ -z "$PG_CONFIG_BIN" || ! -x "$PG_CONFIG_BIN" ]]; then
    echo "record_perf_evidence: no usable pg_config; pass as argument or set PG_CONFIG" >&2
    exit 2
fi

PGBIN="$("$PG_CONFIG_BIN" --bindir)"
PG_LIBDIR="$("$PG_CONFIG_BIN" --pkglibdir)"
PG_MAJOR="$("$PG_CONFIG_BIN" --version 2>/dev/null | awk '{print $2}' | awk -F. '{print $1}')"
ARCH="$(uname -m)"

# --- pg_wait_sampling availability ---------------------------------------
if [[ ! -f "$PG_LIBDIR/pg_wait_sampling.so" ]]; then
    echo "record_perf_evidence: pg_wait_sampling.so not found in $PG_LIBDIR" >&2
    echo "  apt install postgresql-${PG_MAJOR}-pg-wait-sampling" >&2
    exit 1
fi

# --- Cluster setup --------------------------------------------------------
PGDATA="$(mktemp -d "/tmp/pg_xclaim_evidence_${USER:-root}_$$.XXXXXX")"

# Free-port probe -- python3 is available on Linux CI/dev hosts. A blind
# 55880+RANDOM%200 pick can collide with an in-use port and fail boot.
PGPORT="$(python3 -c '
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(("127.0.0.1", 0))
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    print(s.getsockname()[1])
')"

# Private socket dir == PGDATA: avoids racing or colliding with other
# clusters sharing the /tmp socket directory.
PGSOCKET="$PGDATA"

# PIDs of psql clients we spawn for concurrent scenarios. Killed by exact
# PID at scenario end -- a `pkill -f` pattern would also match unrelated
# psql processes owned by other users on a shared host.
SCENARIO_PSQL_PIDS=()

chown -R "$RUN_USER":"$(id -gn "$RUN_USER")" "$PGDATA"

ORIG_KPTR="$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo 1)"
ORIG_PEP="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 4)"

restore_sysctls() {
    echo "$ORIG_KPTR" > /proc/sys/kernel/kptr_restrict 2>/dev/null || true
    echo "$ORIG_PEP"  > /proc/sys/kernel/perf_event_paranoid 2>/dev/null || true
}

cleanup() {
    runuser -u "$RUN_USER" -- "$PGBIN/pg_ctl" stop -D "$PGDATA" -m immediate >/dev/null 2>&1 || true
    rm -rf "${PGDATA:?}"
}
# Restore sysctls FIRST so a failing rm in cleanup() can never leave the
# kernel with relaxed kptr_restrict / perf_event_paranoid settings.
trap 'restore_sysctls; cleanup' EXIT INT TERM

echo 0  > /proc/sys/kernel/kptr_restrict
echo -1 > /proc/sys/kernel/perf_event_paranoid

echo "record_perf_evidence: PG_CONFIG=$PG_CONFIG_BIN PG_MAJOR=$PG_MAJOR ARCH=$ARCH"
echo "record_perf_evidence: PGDATA=$PGDATA PGPORT=$PGPORT RUN_USER=$RUN_USER"
echo "record_perf_evidence: FLAME_DIR=$FLAME_DIR PERFSTAT_DIR=$PERFSTAT_DIR WAITEV_DIR=$WAITEV_DIR"

# Capture initdb output: a swallowed failure (e.g. missing locale) would
# otherwise die silently with no diagnostic.
if ! INITDB_OUT="$(runuser -u "$RUN_USER" -- "$PGBIN/initdb" -D "$PGDATA" --locale=ru_RU.UTF-8 \
        -E UTF8 --auth=trust -U postgres 2>&1)"; then
    echo "record_perf_evidence: initdb failed; output follows:" >&2
    printf '%s\n' "$INITDB_OUT" >&2
    exit 1
fi

cat >> "$PGDATA/postgresql.conf" <<CONF
shared_preload_libraries = 'pg_xclaim,pg_wait_sampling'
port = $PGPORT
unix_socket_directories = '$PGSOCKET'
pg_xclaim.max_claims = 4194304
pg_xclaim.num_partitions = 128
pg_xclaim.expected_claims_per_backend = 1048576
log_min_messages = warning
logging_collector = off
max_connections = 64
# 10ms sampling -> ~100 samples/sec/backend; over 12s = 1200 samples,
# enough for top-10 wait event resolution per backend.
pg_wait_sampling.profile_period = 10
pg_wait_sampling.profile_pid = true
CONF

runuser -u "$RUN_USER" -- "$PGBIN/pg_ctl" start -D "$PGDATA" -w \
    -l "$PGDATA/server.log" -o "-p $PGPORT" >/dev/null

runuser -u "$RUN_USER" -- "$PGBIN/psql" -h "$PGSOCKET" -p "$PGPORT" \
    -U postgres -d postgres -c "CREATE EXTENSION pg_xclaim; CREATE EXTENSION pg_wait_sampling;" >/dev/null

echo "record_perf_evidence: cluster up (PG $PG_MAJOR on port $PGPORT, extensions: pg_xclaim + pg_wait_sampling)"

# --- perf events to track in `perf stat` ---------------------------------
PERF_STAT_EVENTS="cycles,instructions,cache-references,cache-misses,LLC-load-misses,LLC-store-misses,branch-instructions,branch-misses,page-faults,context-switches,cpu-migrations"

# --- Per-scenario driver --------------------------------------------------
run_scenario() {
    local NAME="$1" SQL="$2" WINDOW="$3" CONCURRENT="${4:-0}"

    local PERF_REC="/tmp/${NAME}_rec_$$.perf.data"
    local PERF_STAT_OUT="$PERFSTAT_DIR/$NAME.txt"
    local SVG="$FLAME_DIR/$NAME.svg"
    local WAIT_CSV="$WAITEV_DIR/$NAME.csv"

    echo ""
    echo "============================================"
    echo "Scenario: $NAME (window ${WINDOW}s, concurrent=$CONCURRENT)"
    echo "============================================"

    # --- Pass 1: perf record + pg_wait_sampling capture ------------------
    runuser -u "$RUN_USER" -- "$PGBIN/psql" -h "$PGSOCKET" -p "$PGPORT" \
        -U postgres -d postgres -c "SELECT pg_wait_sampling_reset_profile();" >/dev/null

    perf record -F 997 -g -a -o "$PERF_REC" -- sleep "$WINDOW" &
    local PERF_PID=$!
    sleep 1

    SCENARIO_PSQL_PIDS=()
    if [[ "$CONCURRENT" -eq 0 ]]; then
        runuser -u "$RUN_USER" -- "$PGBIN/psql" -h "$PGSOCKET" -p "$PGPORT" \
            -U postgres -d postgres -c "$SQL" >/dev/null 2>&1 || true
    else
        local w
        for w in $(seq 1 "$CONCURRENT"); do
            runuser -u "$RUN_USER" -- "$PGBIN/psql" -h "$PGSOCKET" -p "$PGPORT" \
                -U postgres -d postgres -c "$SQL" >/dev/null 2>&1 &
            SCENARIO_PSQL_PIDS+=("$!")
        done
    fi
    wait "$PERF_PID" 2>/dev/null || true
    # Kill exactly the psql clients this scenario spawned (by PID), never a
    # `pkill -f` pattern that could also match unrelated psql processes.
    if [[ "${#SCENARIO_PSQL_PIDS[@]}" -gt 0 ]]; then
        kill "${SCENARIO_PSQL_PIDS[@]}" 2>/dev/null || true
        wait "${SCENARIO_PSQL_PIDS[@]}" 2>/dev/null || true
        SCENARIO_PSQL_PIDS=()
    fi
    sleep 1

    # Snapshot the cumulative pg_wait_sampling profile (reset above, so
    # this captures only THIS scenario's waits). Filter out the
    # `Activity:*` wait_event_type -- those are background workers (and
    # idle client backends) parked on their main loops, not real waits
    # during our workload. We want LWLock, Lock, IO, IPC, etc.
    runuser -u "$RUN_USER" -- "$PGBIN/psql" -h "$PGSOCKET" -p "$PGPORT" \
        -U postgres -d postgres -A -F',' -c "
            COPY (
                SELECT event_type, event, sum(count) AS samples
                FROM pg_wait_sampling_profile
                WHERE event IS NOT NULL
                  AND event_type IS NOT NULL
                  AND event_type NOT IN ('Activity', 'Client', 'Timeout', 'Extension')
                GROUP BY event_type, event
                ORDER BY samples DESC
                LIMIT 20
            ) TO STDOUT WITH CSV HEADER
        " > "$WAIT_CSV"

    echo "  perf.data: $(stat -c%s "$PERF_REC") bytes"

    # FlameGraph SVG + top-15 leaves
    perf script -i "$PERF_REC" 2>/dev/null \
        | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
        | grep "^postgres" \
        | "$FLAMEGRAPH_DIR/flamegraph.pl" --colors hot --width 1600 \
            --title "$NAME (PG $PG_MAJOR, $ARCH Linux)" \
        > "$SVG"
    echo "  SVG: $SVG ($(stat -c%s "$SVG") bytes)"

    echo "  Top-15 leaves:"
    perf script -i "$PERF_REC" 2>/dev/null \
        | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
        | grep "^postgres" \
        | python3 -c "
import sys
from collections import Counter
agg = Counter(); total = 0
for line in sys.stdin:
    parts = line.rstrip().rsplit(' ', 1)
    if len(parts) != 2: continue
    cnt = int(parts[1]); total += cnt
    agg[parts[0].rsplit(';', 1)[-1]] += cnt
for leaf, cnt in agg.most_common(15):
    print(f'    {cnt*100/total:5.1f}%  {leaf}')
"
    rm -f "$PERF_REC"

    echo "  pg_wait_sampling: $WAIT_CSV ($(wc -l < "$WAIT_CSV") lines)"
    echo "  Top wait events:"
    awk -F',' 'NR>1 {printf "    %6d  %s:%s\n", $3, $1, $2}' "$WAIT_CSV" | head -5

    # --- Pass 2: perf stat for HW counters (no -g, no record overhead) ---
    echo ""
    echo "  --- perf stat (HW counters, ${WINDOW}s window) ---"
    {
        echo "# Scenario: $NAME"
        echo "# PG $PG_MAJOR on $ARCH Linux, $(date -Iseconds)"
        echo "# Window: ${WINDOW}s, concurrent=$CONCURRENT"
        echo "# Events: $PERF_STAT_EVENTS"
        echo ""
    } > "$PERF_STAT_OUT"

    perf stat -e "$PERF_STAT_EVENTS" -a -o /tmp/perfstat_$$.txt --append -- sleep "$WINDOW" &
    local STAT_PID=$!
    sleep 1

    SCENARIO_PSQL_PIDS=()
    if [[ "$CONCURRENT" -eq 0 ]]; then
        runuser -u "$RUN_USER" -- "$PGBIN/psql" -h "$PGSOCKET" -p "$PGPORT" \
            -U postgres -d postgres -c "$SQL" >/dev/null 2>&1 || true
    else
        local w
        for w in $(seq 1 "$CONCURRENT"); do
            runuser -u "$RUN_USER" -- "$PGBIN/psql" -h "$PGSOCKET" -p "$PGPORT" \
                -U postgres -d postgres -c "$SQL" >/dev/null 2>&1 &
            SCENARIO_PSQL_PIDS+=("$!")
        done
    fi
    wait "$STAT_PID" 2>/dev/null || true
    # Kill exactly the psql clients this scenario spawned (by PID), never a
    # `pkill -f` pattern that could also match unrelated psql processes.
    if [[ "${#SCENARIO_PSQL_PIDS[@]}" -gt 0 ]]; then
        kill "${SCENARIO_PSQL_PIDS[@]}" 2>/dev/null || true
        wait "${SCENARIO_PSQL_PIDS[@]}" 2>/dev/null || true
        SCENARIO_PSQL_PIDS=()
    fi
    sleep 1

    cat /tmp/perfstat_$$.txt >> "$PERF_STAT_OUT"
    rm -f /tmp/perfstat_$$.txt

    # Parse + echo headline metrics. The `|| true` keeps the loop alive
    # even if parsing hits an unexpected `perf stat` layout (e.g. a
    # counter labeled "<not counted>" or "<not supported>" on a kernel
    # that lacks the event); the raw .txt is always preserved.
    python3 - "$PERF_STAT_OUT" 2>&1 <<'PYEOF' || true
import re, sys
path = sys.argv[1]
counters = {}
# perf stat line layout (one event per line):
#   "     12,345,678,901      cycles ..."
#   "     <not counted>       LLC-load-misses ..."
LINE_RE = re.compile(r'^\s*([0-9,]+|<[^>]+>)\s+([A-Za-z][A-Za-z0-9\-_:]+)')
for line in open(path):
    m = LINE_RE.match(line)
    if not m: continue
    val_s, name = m.group(1), m.group(2)
    if val_s.startswith('<'):
        continue
    try:
        counters[name] = int(val_s.replace(',', ''))
    except ValueError:
        continue

def g(k): return counters.get(k)
def fmt(n):
    if n is None: return 'n/a'
    if n >= 1e9: return f'{n/1e9:.2f}G'
    if n >= 1e6: return f'{n/1e6:.2f}M'
    if n >= 1e3: return f'{n/1e3:.2f}K'
    return str(n)

cycles  = g('cycles')
instrs  = g('instructions')
crefs   = g('cache-references')
cmiss   = g('cache-misses')
llcload = g('LLC-load-misses')
brmiss  = g('branch-misses')
pfaults = g('page-faults')
ctxsw   = g('context-switches')
cpumigr = g('cpu-migrations')

line1 = f"    cycles={fmt(cycles)} instructions={fmt(instrs)}"
if cycles and instrs:
    line1 += f"  IPC={instrs/cycles:.2f}"
print(line1)
if cmiss is not None and crefs:
    print(f"    cache-misses={fmt(cmiss)} ({100.0*cmiss/crefs:.2f}% of cache-refs)")
print(f"    LLC-load-misses={fmt(llcload)}  branch-misses={fmt(brmiss)}")
print(f"    page-faults={fmt(pfaults)}  context-switches={fmt(ctxsw)}  cpu-migrations={fmt(cpumigr)}")
PYEOF

    echo "  perf-stat: $PERF_STAT_OUT"
}

# --- Scenario 1: scalar acquire ------------------------------------------
run_scenario "scalar-acquire" "
DO \$\$ DECLARE i int; BEGIN
  FOR i IN 1..5 LOOP
    BEGIN
      PERFORM count(*) FROM generate_series(1, 750000) g
        WHERE xclaim.try(1, g::int);
      RAISE EXCEPTION USING ERRCODE='XBENC';
    EXCEPTION WHEN sqlstate 'XBENC' THEN NULL;
    END;
  END LOOP;
END \$\$;
" 12 0

# --- Scenario 2: bulk try_many -------------------------------------------
run_scenario "bulk-try-many" "
DO \$\$ DECLARE i int; BEGIN
  FOR i IN 1..10 LOOP
    BEGIN
      PERFORM count(*) FROM unnest(
        xclaim.try_many(1, ARRAY(SELECT g FROM generate_series(1, 750000) g)::int4[])
      ) AS v WHERE v;
      RAISE EXCEPTION USING ERRCODE='XBENC';
    EXCEPTION WHEN sqlstate 'XBENC' THEN NULL;
    END;
  END LOOP;
END \$\$;
" 12 0

# --- Scenario 3: cleanup -------------------------------------------------
run_scenario "cleanup-commit" "
DO \$\$ DECLARE i int; BEGIN
  FOR i IN 1..50 LOOP
    PERFORM count(*) FROM unnest(
      xclaim.try_many(1, ARRAY(SELECT g FROM generate_series((i-1)*50000+1, i*50000) g)::int4[])
    ) AS v WHERE v;
  END LOOP;
END \$\$;
" 12 0

# --- Scenario 4: concurrent overlap --------------------------------------
run_scenario "concurrent-contention" "
DO \$\$
DECLARE i int; n_keys int := 100000; pool_size int := 200000;
BEGIN
  FOR i IN 1..5 LOOP
    BEGIN
      PERFORM count(*) FROM unnest(
        xclaim.try_many(1, ARRAY(
          SELECT (random() * pool_size)::int + 1
          FROM generate_series(1, n_keys)
        )::int4[])
      ) AS v WHERE v;
      RAISE EXCEPTION USING ERRCODE='XBENC';
    EXCEPTION WHEN sqlstate 'XBENC' THEN NULL;
    END;
  END LOOP;
END \$\$;
" 15 10

echo ""
echo "============================================"
echo "Performance evidence pack ready:"
echo "============================================"
echo "  FlameGraphs:    $FLAME_DIR/"
ls -1 "$FLAME_DIR"/*.svg 2>/dev/null | sed 's/^/    /'
echo "  perf stat:      $PERFSTAT_DIR/"
ls -1 "$PERFSTAT_DIR"/*.txt 2>/dev/null | sed 's/^/    /'
echo "  wait events:    $WAITEV_DIR/"
ls -1 "$WAITEV_DIR"/*.csv 2>/dev/null | sed 's/^/    /'
