#!/usr/bin/env bash
# scripts/smoke_gate.sh -- pre-deploy smoke gate.
#
# Verifies that `_PG_init` does not panic when the freshly-built `.so` is
# preloaded. Uses `postgres --single` bootstrap mode, which executes
# preload (and runs init) but accepts no client work. Exit 0 means the
# server initialized cleanly; non-zero means a FATAL/PANIC was emitted
# during shared_preload_libraries processing.
#
# Mandatory before any production postgresql.conf change: without this
# gate, a buggy `_PG_init` will brick the next normal start and require
# manual surgery to recover.
#
# Usage:
#   scripts/smoke_gate.sh                           # auto-discover PG 17
#   scripts/smoke_gate.sh /path/to/pg_config        # explicit
#   PG_CONFIG_BIN=/path scripts/smoke_gate.sh       # via env
#
# Exit:
#   0  PASS  -- no FATAL/PANIC observed
#   1  FAIL  -- FATAL or PANIC found in smoke.log
#   2  bad usage / missing pg_config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolution order: explicit arg -> PG_CONFIG_BIN env -> find_pg_config.sh 17.
PG_CONFIG_BIN="${1:-${PG_CONFIG_BIN:-}}"
if [[ -z "$PG_CONFIG_BIN" ]]; then
    if PG_CONFIG_BIN="$("$SCRIPT_DIR/find_pg_config.sh" 17 2>/dev/null)"; then
        :
    else
        echo "smoke_gate: no PG_CONFIG provided and no PG 17 discovered." >&2
        echo "  pass an explicit path or set PG17_CONFIG / PG_CONFIG_BIN." >&2
        exit 2
    fi
fi

[[ -x "$PG_CONFIG_BIN" ]] || {
    echo "smoke_gate: pg_config not executable: $PG_CONFIG_BIN" >&2
    exit 2
}

DATADIR="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.smoke.XXXXXX")"
trap 'rm -rf "$DATADIR"' EXIT INT TERM

BIN="$("$PG_CONFIG_BIN" --bindir)"
INITDB="$BIN/initdb"
POSTGRES="$BIN/postgres"

[[ -x "$INITDB" ]]    || { echo "smoke_gate: initdb missing at $INITDB" >&2; exit 2; }
[[ -x "$POSTGRES" ]]  || { echo "smoke_gate: postgres missing at $POSTGRES" >&2; exit 2; }

PG_VER_LINE="$("$POSTGRES" --version 2>&1 | head -1 || echo unknown)"
echo "smoke_gate: PG_CONFIG=$PG_CONFIG_BIN"
echo "smoke_gate: postgres --version: $PG_VER_LINE"
echo "smoke_gate: DATADIR=$DATADIR"

"$INITDB" -D "$DATADIR" \
    --locale=ru_RU.UTF-8 \
    -E UTF8 \
    --auth=trust \
    -U postgres \
    >/dev/null

{
    echo "shared_preload_libraries = 'pg_xclaim'"
    echo "unix_socket_directories = '$DATADIR'"
    # Default capacity GUCs -- exercise full _PG_init shmem request path.
    echo "pg_xclaim.max_claims = 65536"
    echo "pg_xclaim.num_partitions = 128"
} >> "$DATADIR/postgresql.conf"

# `postgres --single` bootstrap mode: runs preload + _PG_init, then idles
# on stdin. We feed `\q` to make it exit cleanly. If init faults, FATAL is
# emitted to stderr (captured by tee).
SMOKE_LOG="$DATADIR/smoke.log"
echo '\q' | "$POSTGRES" --single -D "$DATADIR" postgres 2>&1 | tee "$SMOKE_LOG" >/dev/null || true

# Detect any FATAL/PANIC emitted during init.
if grep -qE 'FATAL|PANIC' "$SMOKE_LOG"; then
    echo "SMOKE GATE FAILED: FATAL/PANIC detected during _PG_init" >&2
    grep -E 'FATAL|PANIC' "$SMOKE_LOG" >&2 | head -20
    echo "--- full smoke.log ---" >&2
    cat "$SMOKE_LOG" >&2
    exit 1
fi

echo "SMOKE GATE PASS"
exit 0
