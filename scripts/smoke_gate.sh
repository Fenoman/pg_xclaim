#!/usr/bin/env bash
# scripts/smoke_gate.sh -- pre-deploy smoke gate.
#
# Verifies that `_PG_init` does not crash when the freshly-built `.so` is
# preloaded. Uses `postgres --single`, which executes preload (and runs
# init) but accepts no client work. Exit 0 means the server initialized
# and shut down cleanly. Non-zero means the postgres process exited with a
# non-zero status (a signal included) or logged ERROR/FATAL/PANIC during
# shared_preload_libraries processing.
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
#   0  PASS  -- postgres exited 0, no ERROR/FATAL/PANIC in smoke.log
#   1  FAIL  -- non-zero exit status of postgres, or ERROR/FATAL/PANIC logged
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

# `postgres --single` runs preload and `_PG_init`, then reads commands
# from stdin. Empty stdin makes it shut down right away.
#
# How a failure shows.
#   The exit status of the postgres process is the primary signal. A crash
#   in `_PG_init` (SIGSEGV, abort) prints nothing and leaves a status above
#   128, FATAL exits with 1.
#
# Why lc_messages=C.
#   The cluster locale is ru_RU.UTF-8, so the server would translate its
#   severity tags. lc_messages=C keeps them in English and makes the scan
#   below independent of translations. The process environment keeps
#   ru_RU.UTF-8, as every postgres start in this project does.
SMOKE_LOG="$DATADIR/smoke.log"
if LC_ALL=ru_RU.UTF-8 LANG=ru_RU.UTF-8 \
    "$POSTGRES" --single -D "$DATADIR" -c lc_messages=C postgres \
    </dev/null >"$SMOKE_LOG" 2>&1; then
    rc=0
else
    rc=$?
fi

if (( rc != 0 )); then
    if (( rc > 128 )); then
        echo "SMOKE GATE FAILED: postgres --single killed by signal $(( rc - 128 ))" >&2
    else
        echo "SMOKE GATE FAILED: postgres --single exited with status $rc" >&2
    fi
    echo "--- full smoke.log ---" >&2
    cat "$SMOKE_LOG" >&2
    exit 1
fi

if grep -qE '(ERROR|FATAL|PANIC):' "$SMOKE_LOG"; then
    echo "SMOKE GATE FAILED: ERROR/FATAL/PANIC logged during _PG_init" >&2
    grep -E '(ERROR|FATAL|PANIC):' "$SMOKE_LOG" | head -20 >&2
    echo "--- full smoke.log ---" >&2
    cat "$SMOKE_LOG" >&2
    exit 1
fi

echo "SMOKE GATE PASS"
exit 0
