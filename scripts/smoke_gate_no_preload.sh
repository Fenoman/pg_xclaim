#!/usr/bin/env bash
# scripts/smoke_gate_no_preload.sh -- no-preload coverage.
#
# Verifies that a server WITHOUT pg_xclaim in shared_preload_libraries can
# still run `LOAD 'pg_xclaim'` (no FATAL), but any `xclaim.try` call raises
# `ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE` (SQLSTATE 55000, see
# src/pg_xclaim.h XCLAIM_REQUIRE_INIT) -- the documented behaviour.
#
# This is the symmetric companion to scripts/smoke_gate.sh: smoke_gate.sh
# proves preloaded init does not panic, and this script proves the no-preload
# fallback path raises the documented user-error code instead of crashing.
#
# Usage:
#   scripts/smoke_gate_no_preload.sh                    # auto-discover PG 17
#   scripts/smoke_gate_no_preload.sh /path/to/pg_config # explicit
#
# The server runs with lc_messages=C, so severity tags and messages are in
# English whatever the cluster locale is. Every step checks the exit status
# of psql: 0 is success, 1 or 3 an SQL error, 2 a lost connection (the
# backend crashed).
#
# Exit:
#   0  PASS  -- LOAD ok, xclaim.try raises SQLSTATE 55000 (object_not_in_prerequisite_state)
#   1  FAIL  -- start, CREATE EXTENSION or LOAD failed, FATAL/PANIC logged,
#               xclaim.try succeeded, lost its connection or raised another error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PG_CONFIG_BIN="${1:-${PG_CONFIG_BIN:-}}"
if [[ -z "$PG_CONFIG_BIN" ]]; then
    PG_CONFIG_BIN="$("$SCRIPT_DIR/find_pg_config.sh" 17)"
fi
[[ -x "$PG_CONFIG_BIN" ]] || { echo "no usable pg_config: $PG_CONFIG_BIN" >&2; exit 2; }

BIN="$("$PG_CONFIG_BIN" --bindir)"
INITDB="$BIN/initdb"
PGCTL="$BIN/pg_ctl"
PSQL="$BIN/psql"

DATADIR="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.smoke_np.XXXXXX")"

PORT="$(python3 -c '
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(("127.0.0.1", 0)); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    print(s.getsockname()[1])
')"

cleanup() {
    "$PGCTL" stop -D "$DATADIR" -m immediate >/dev/null 2>&1 || true
    rm -rf "$DATADIR"
}
trap cleanup EXIT INT TERM

echo "smoke_gate_no_preload: PG_CONFIG=$PG_CONFIG_BIN  PORT=$PORT  DATADIR=$DATADIR"

"$INITDB" -D "$DATADIR" --locale=ru_RU.UTF-8 -E UTF8 --auth=trust -U postgres >/dev/null

# NOTE: explicitly do NOT set shared_preload_libraries.
{
    echo "port = $PORT"
    echo "unix_socket_directories = '$DATADIR'"
    echo "log_min_messages = warning"
    echo "logging_collector = off"
} >> "$DATADIR/postgresql.conf"

# Inline locale, as in run_temp_cluster.sh: on macOS a postmaster started
# without one exits with FATAL "postmaster became multithreaded during
# startup".
LC_ALL=ru_RU.UTF-8 LANG=ru_RU.UTF-8 \
"$PGCTL" start -D "$DATADIR" -w -l "$DATADIR/server.log" \
    -o "-p $PORT -c lc_messages=C" >/dev/null || {
    echo "FAIL: server did not start without preload" >&2
    cat "$DATADIR/server.log" >&2
    exit 1
}

if grep -qE '(FATAL|PANIC):' "$DATADIR/server.log"; then
    echo "FAIL: FATAL during start without preload (should start clean)" >&2
    grep -E '(FATAL|PANIC):' "$DATADIR/server.log" | head -10 >&2
    exit 1
fi

# Step 0: CREATE EXTENSION (installs SQL objects, .so loaded lazily on first call).
# Without this the schema "xclaim" doesn't exist and we'd get 3F000 instead of 55000.
if ! CE_OUT="$("$PSQL" -h "$DATADIR" -p "$PORT" -U postgres -d postgres \
    -X -At -v ON_ERROR_STOP=1 \
    -c "CREATE EXTENSION IF NOT EXISTS pg_xclaim;" 2>&1)"; then
    echo "FAIL: CREATE EXTENSION failed: $CE_OUT" >&2
    exit 1
fi

# Step 1: LOAD must succeed.
if ! LOAD_OUT="$("$PSQL" -h "$DATADIR" -p "$PORT" -U postgres -d postgres \
    -X -At -v ON_ERROR_STOP=1 -c "LOAD 'pg_xclaim';" 2>&1)"; then
    echo "FAIL: LOAD 'pg_xclaim' failed: $LOAD_OUT" >&2
    exit 1
fi

# Step 2: xclaim.try must raise SQLSTATE 55000 (object_not_in_prerequisite_state).
# VERBOSITY=verbose prints the SQLSTATE after the severity tag. psql exits
# with 1 on the SQL error, 0 would mean xclaim.try succeeded and 2 that the
# backend crashed.
if TRY_OUT="$(PGOPTIONS='--client-min-messages=warning' \
    "$PSQL" -h "$DATADIR" -p "$PORT" -U postgres -d postgres \
    -X -At -v ON_ERROR_STOP=1 -v VERBOSITY=verbose \
    -c "SELECT xclaim.try(1, 1);" 2>&1)"; then
    TRY_RC=0
else
    TRY_RC=$?
fi

if (( TRY_RC == 1 )) && grep -qE '^ERROR:  55000:' <<<"$TRY_OUT"; then
    echo "PASS: xclaim.try raised SQLSTATE 55000 (object_not_in_prerequisite_state)"
else
    echo "FAIL: xclaim.try did not raise the expected XCLAIM_REQUIRE_INIT error (psql exit status $TRY_RC)." >&2
    echo "--- output ---" >&2
    echo "$TRY_OUT" >&2
    exit 1
fi

echo "SMOKE GATE NO-PRELOAD PASS"
exit 0
