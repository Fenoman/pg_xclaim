#!/usr/bin/env bash
# scripts/run_temp_cluster.sh
#
# Bring up a temporary PostgreSQL cluster under /tmp with pg_xclaim preloaded
# (or not, see --no-preload). Standalone wrapper that mirrors the
# test/concurrency/_lib.sh helpers but is invocable from CI / smoke /
# bench scripts that don't want to source the full test library.
#
# Usage:
#   scripts/run_temp_cluster.sh <PG_CONFIG> [--no-preload] [--no-extension]
#                               [--max-claims N] [--num-partitions N]
#                               [--extra-conf 'line']
#
#   PG_CONFIG: absolute path to a pg_config binary (use scripts/find_pg_config.sh).
#
# Behaviour:
#   - initdb under /tmp/pg_xclaim_${USER}_$$.XXXXXX with locale ru_RU.UTF-8
#   - free TCP port via Python socket probe
#   - private unix socket directory == PGDATA (no /tmp race)
#   - pg_ctl start with -w (wait for ready)
#   - emits PGDATA/PGPORT/PGSOCKET on stdout (KEY=VALUE lines, sourceable)
#   - on TRAP: pg_ctl stop -m immediate + rm -rf $PGDATA
#
# Exit codes:
#   0  cluster healthy, KEY=VALUE printed
#   1  failure (initdb / pg_ctl / extension creation)
#
# HARD INVARIANTS:
#   - set -euo pipefail
#   - locale ru_RU.UTF-8
#   - /tmp clusters only; trap-based cleanup
#   - never operates against an existing user cluster
#
# This script is INTENDED to be backgrounded or sourced by callers. By default
# it stays in foreground and tears down the cluster on signal -- pass
# --keep-running to skip cleanup (caller assumes ownership; useful for
# benchmarks that need the cluster alive after this script returns).

set -euo pipefail

PG_CONFIG_BIN="${1:-}"
[[ -n "$PG_CONFIG_BIN" ]] || { echo "usage: $0 <PG_CONFIG> [opts]" >&2; exit 2; }
shift

NO_PRELOAD=0
NO_EXTENSION=0
KEEP_RUNNING=0
MAX_CLAIMS=65536
NUM_PARTITIONS=128
EXTRA_CONF=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-preload)     NO_PRELOAD=1; shift ;;
        --no-extension)   NO_EXTENSION=1; shift ;;
        --keep-running)   KEEP_RUNNING=1; shift ;;
        --max-claims)     MAX_CLAIMS="$2"; shift 2 ;;
        --num-partitions) NUM_PARTITIONS="$2"; shift 2 ;;
        --extra-conf)     EXTRA_CONF="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[[ -x "$PG_CONFIG_BIN" ]] || { echo "PG_CONFIG not executable: $PG_CONFIG_BIN" >&2; exit 1; }

PGBIN="$("$PG_CONFIG_BIN" --bindir)"
INITDB="$PGBIN/initdb"
PGCTL="$PGBIN/pg_ctl"
PSQL="$PGBIN/psql"

PGDATA="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.tempcluster.XXXXXX")"
PGSOCKET="$PGDATA"
PGHOST="$PGDATA"

# Free-port probe -- python3 is available on macOS + ubuntu-latest CI runners.
PGPORT="$(python3 -c '
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(("127.0.0.1", 0))
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    print(s.getsockname()[1])
')"

# Locale preflight: initdb dies with an opaque error if ru_RU.UTF-8 is
# absent. Probe up-front so the failure message names the actual cause.
if ! { locale -a 2>/dev/null || true; } | grep -qiE "ru_RU\.(UTF-8|utf8)"; then
    echo "run_temp_cluster: locale ru_RU.UTF-8 not installed (required by initdb)" >&2
    echo "  install it (e.g. 'localedef -i ru_RU -f UTF-8 ru_RU.UTF-8') and retry" >&2
    exit 1
fi

cleanup() {
    local rc=$?
    if [[ "$KEEP_RUNNING" -eq 1 ]]; then
        return $rc
    fi
    if [[ -d "$PGDATA" ]]; then
        "$PGCTL" stop -D "$PGDATA" -m immediate >/dev/null 2>&1 || true
        rm -rf "${PGDATA:?}"
    fi
    return $rc
}
trap cleanup EXIT INT TERM

# Capture initdb output: a swallowed failure (e.g. missing locale) would
# otherwise die silently with no diagnostic.
if ! INITDB_OUT="$("$INITDB" -D "$PGDATA" \
        --locale=ru_RU.UTF-8 \
        -E UTF8 \
        --auth=trust \
        -U postgres 2>&1)"; then
    echo "run_temp_cluster: initdb failed; output follows:" >&2
    printf '%s\n' "$INITDB_OUT" >&2
    exit 1
fi

{
    if [[ "$NO_PRELOAD" -eq 0 ]]; then
        echo "shared_preload_libraries = 'pg_xclaim'"
    fi
    echo "port = $PGPORT"
    echo "unix_socket_directories = '$PGSOCKET'"
    echo "pg_xclaim.max_claims = $MAX_CLAIMS"
    echo "pg_xclaim.num_partitions = $NUM_PARTITIONS"
    echo "log_min_messages = warning"
    echo "logging_collector = off"
    [[ -n "$EXTRA_CONF" ]] && echo "$EXTRA_CONF"
} >> "$PGDATA/postgresql.conf"

# LC_ALL/LANG must be exported in the calling env: on macOS the postmaster
# inherits the parent's locale at startup, and an unset LC_ALL triggers
# "postmaster became multithreaded during startup" FATAL on PG 17.10+.
LC_ALL=ru_RU.UTF-8 LANG=ru_RU.UTF-8 \
"$PGCTL" start -D "$PGDATA" -w \
    -l "$PGDATA/server.log" \
    -o "-p $PGPORT" \
    >/dev/null 2>&1 || {
        echo "pg_ctl start failed; tail of server.log:" >&2
        tail -50 "$PGDATA/server.log" >&2 || true
        exit 1
    }

if [[ "$NO_PRELOAD" -eq 0 ]] && [[ "$NO_EXTENSION" -eq 0 ]]; then
    "$PSQL" -h "$PGSOCKET" -p "$PGPORT" -U postgres -d postgres \
        -v ON_ERROR_STOP=1 \
        -c "CREATE EXTENSION IF NOT EXISTS pg_xclaim;" \
        >/dev/null
fi

# Sourceable output
printf 'PGDATA=%s\n' "$PGDATA"
printf 'PGPORT=%s\n' "$PGPORT"
printf 'PGSOCKET=%s\n' "$PGSOCKET"
printf 'PGHOST=%s\n' "$PGHOST"
printf 'PGBIN=%s\n' "$PGBIN"

if [[ "$KEEP_RUNNING" -eq 1 ]]; then
    # Caller owns the cluster lifecycle; emit a hint with cleanup commands.
    cat <<EOF
# To stop:
#   "$PGCTL" stop -D "$PGDATA" -m immediate
#   rm -rf "$PGDATA"
EOF
fi
