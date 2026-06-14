#!/usr/bin/env bash
# scripts/record_flamegraphs.sh
#
# Record perf-based CPU flamegraphs for the four pg_xclaim scenarios that
# `docs/perf/hot-path-analysis.md` discusses:
#   1. scalar-acquire        -- single-backend scalar `xclaim.try`
#   2. bulk-try-many         -- single-backend bulk `xclaim.try_many`
#   3. cleanup-commit        -- 50 transactions x 50k commit cleanup
#   4. concurrent-contention -- 10 backends x 100k overlapping keys
#
# Output: docs/perf/flamegraphs/<scenario>.svg + top-15 leaf summary on stdout.
#
# Usage:
#   sudo scripts/record_flamegraphs.sh                # auto pg_config 17
#   sudo scripts/record_flamegraphs.sh /path/to/pg_config
#
# Requirements:
#   - Linux (perf record); the script aborts on non-Linux.
#   - Run as root (initdb/pg_ctl/psql delegated to a non-privileged user via
#     `runuser`). perf record needs CAP_PERFMON, and kernel symbol resolution
#     needs root visibility into /proc/kallsyms.
#   - sysctl kernel.kptr_restrict=0 (the script enforces it at startup).
#   - sysctl kernel.perf_event_paranoid <= 1 (the script lowers to -1 if needed).
#   - FlameGraph repo (Brendan Gregg) cloned -- set FLAMEGRAPH_DIR if not at
#     /opt/FlameGraph.
#   - A regular OS user under which to run psql/initdb. Defaults to `postgres`
#     (created by the PGDG postgresql-17 package). Override via RUN_USER=...
#
# Exit:
#   0  all four scenarios captured; SVGs written.
#   1  infrastructure failure (cluster, perf, FlameGraph not found, ...).
#   2  bad arguments.
#
# HARD INVARIANTS:
#   - set -euo pipefail
#   - /tmp temp cluster only; trap cleanup
#   - locale ru_RU.UTF-8

set -euo pipefail

# --- Platform guard -------------------------------------------------------
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "record_flamegraphs: Linux-only (perf is unavailable on $(uname -s))" >&2
    exit 1
fi

# --- Root check -----------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    echo "record_flamegraphs: must run as root (need CAP_PERFMON + kallsyms access)" >&2
    exit 1
fi

# --- Paths ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$ROOT_DIR/docs/perf/flamegraphs"
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-/opt/FlameGraph}"
RUN_USER="${RUN_USER:-postgres}"

if [[ ! -d "$FLAMEGRAPH_DIR" ]]; then
    echo "record_flamegraphs: FlameGraph not found at $FLAMEGRAPH_DIR" >&2
    echo "  git clone https://github.com/brendangregg/FlameGraph $FLAMEGRAPH_DIR" >&2
    exit 1
fi
if [[ ! -x "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" ]] || [[ ! -x "$FLAMEGRAPH_DIR/flamegraph.pl" ]]; then
    echo "record_flamegraphs: FlameGraph scripts missing in $FLAMEGRAPH_DIR" >&2
    exit 1
fi

if ! id "$RUN_USER" >/dev/null 2>&1; then
    echo "record_flamegraphs: RUN_USER=$RUN_USER does not exist" >&2
    exit 1
fi

# --- Discover pg_config ---------------------------------------------------
PG_CONFIG_BIN="${1:-${PG_CONFIG:-}}"
if [[ -z "$PG_CONFIG_BIN" ]]; then
    if [[ -x "$SCRIPT_DIR/find_pg_config.sh" ]]; then
        PG_CONFIG_BIN="$("$SCRIPT_DIR/find_pg_config.sh" 17 2>/dev/null || true)"
    fi
fi
if [[ -z "$PG_CONFIG_BIN" || ! -x "$PG_CONFIG_BIN" ]]; then
    echo "record_flamegraphs: no usable pg_config; pass as argument or set PG_CONFIG" >&2
    exit 2
fi

# Locale preflight: initdb dies with an opaque error if ru_RU.UTF-8 is
# absent. Probe up-front so the failure message names the actual cause.
if ! { locale -a 2>/dev/null || true; } | grep -qiE "ru_RU\.(UTF-8|utf8)"; then
    echo "record_flamegraphs: locale ru_RU.UTF-8 not installed (required by initdb)" >&2
    echo "  install it (e.g. 'localedef -i ru_RU -f UTF-8 ru_RU.UTF-8') and retry" >&2
    exit 1
fi

PGBIN="$("$PG_CONFIG_BIN" --bindir)"
PG_MAJOR="$("$PG_CONFIG_BIN" --version 2>/dev/null | awk '{print $2}' | awk -F. '{print $1}')"
PGDATA="$(mktemp -d "/tmp/pg_xclaim_flame_${USER:-root}_$$.XXXXXX")"

# Free-port probe -- python3 is available on Linux CI/dev hosts. A blind
# 55780+RANDOM%200 pick can collide with an in-use port and fail boot.
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

mkdir -p "$OUT_DIR"
chown -R "$RUN_USER":"$(id -gn "$RUN_USER")" "$PGDATA"

cleanup() {
    runuser -u "$RUN_USER" -- "$PGBIN/pg_ctl" stop -D "$PGDATA" -m immediate >/dev/null 2>&1 || true
    rm -rf "${PGDATA:?}"
}
trap cleanup EXIT INT TERM

echo "record_flamegraphs: PG_CONFIG=$PG_CONFIG_BIN PG_MAJOR=$PG_MAJOR"
echo "record_flamegraphs: PGDATA=$PGDATA PGPORT=$PGPORT RUN_USER=$RUN_USER"
echo "record_flamegraphs: OUT_DIR=$OUT_DIR FLAMEGRAPH_DIR=$FLAMEGRAPH_DIR"

# --- Kernel tunables for full symbol resolution ---------------------------
# Save originals so we can restore at exit (best-effort).
ORIG_KPTR="$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo 1)"
ORIG_PEP="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 4)"
restore_sysctls() {
    echo "$ORIG_KPTR" > /proc/sys/kernel/kptr_restrict 2>/dev/null || true
    echo "$ORIG_PEP"  > /proc/sys/kernel/perf_event_paranoid 2>/dev/null || true
}
# Restore sysctls FIRST so a failing rm in cleanup() can never leave the
# kernel with relaxed kptr_restrict / perf_event_paranoid settings.
trap 'restore_sysctls; cleanup' EXIT INT TERM

echo 0  > /proc/sys/kernel/kptr_restrict
echo -1 > /proc/sys/kernel/perf_event_paranoid

# --- Bring up the cluster -------------------------------------------------
# Capture initdb output: a swallowed failure (e.g. missing locale) would
# otherwise die silently with no diagnostic.
if ! INITDB_OUT="$(runuser -u "$RUN_USER" -- "$PGBIN/initdb" -D "$PGDATA" --locale=ru_RU.UTF-8 \
        -E UTF8 --auth=trust -U postgres 2>&1)"; then
    echo "record_flamegraphs: initdb failed; output follows:" >&2
    printf '%s\n' "$INITDB_OUT" >&2
    exit 1
fi

cat >> "$PGDATA/postgresql.conf" <<CONF
shared_preload_libraries = 'pg_xclaim'
port = $PGPORT
unix_socket_directories = '$PGSOCKET'
pg_xclaim.max_claims = 4194304
pg_xclaim.num_partitions = 128
pg_xclaim.expected_claims_per_backend = 1048576
log_min_messages = warning
logging_collector = off
max_connections = 64
CONF

runuser -u "$RUN_USER" -- "$PGBIN/pg_ctl" start -D "$PGDATA" -w \
    -l "$PGDATA/server.log" -o "-p $PGPORT" >/dev/null
runuser -u "$RUN_USER" -- "$PGBIN/psql" -h "$PGSOCKET" -p "$PGPORT" \
    -U postgres -d postgres -c "CREATE EXTENSION pg_xclaim;" >/dev/null

echo "record_flamegraphs: cluster up (PG $PG_MAJOR on port $PGPORT)"

# --- Scenario runner ------------------------------------------------------
run_scenario() {
    local NAME="$1" SQL="$2" WINDOW="$3" CONCURRENT="${4:-0}"
    local PERF="/tmp/${NAME}_${$}.perf.data"
    local SVG="$OUT_DIR/$NAME.svg"

    echo ""
    echo "=== Scenario: $NAME (window ${WINDOW}s, concurrent=$CONCURRENT) ==="
    perf record -F 997 -g -a -o "$PERF" -- sleep "$WINDOW" &
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

    echo "  perf data: $(stat -c%s "$PERF") bytes"

    perf script -i "$PERF" 2>/dev/null \
        | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
        | grep "^postgres" \
        | "$FLAMEGRAPH_DIR/flamegraph.pl" --colors hot --width 1600 \
            --title "$NAME (PG $PG_MAJOR, $(uname -m) Linux)" \
        > "$SVG"
    echo "  SVG: $SVG ($(stat -c%s "$SVG") bytes)"

    echo "  Top-15 leaves:"
    perf script -i "$PERF" 2>/dev/null \
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
    rm -f "$PERF"
}

# --- Scenario 1: scalar acquire (5 x 750k via subxact rollback) ----------
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

# --- Scenario 2: bulk try_many (10 x 750k via subxact rollback) ----------
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

# --- Scenario 3: cleanup (50 transactions x 50k acquire+COMMIT) ----------
run_scenario "cleanup-commit" "
DO \$\$ DECLARE i int; BEGIN
  FOR i IN 1..50 LOOP
    PERFORM count(*) FROM unnest(
      xclaim.try_many(1, ARRAY(SELECT g FROM generate_series((i-1)*50000+1, i*50000) g)::int4[])
    ) AS v WHERE v;
  END LOOP;
END \$\$;
" 12 0

# --- Scenario 4: concurrent overlap (10 backends x 5 x 100k random keys) -
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
echo "record_flamegraphs: done. SVGs in $OUT_DIR/"
ls -la "$OUT_DIR"/*.svg
