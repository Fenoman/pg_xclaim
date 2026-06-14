#!/usr/bin/env bash
# scripts/smoke_gate_multi_preload.sh
#
# Boot-time guarantee: pg_xclaim must chain cleanly with other
# AddinShmemInitLock-using extensions in shared_preload_libraries
# (pg_stat_statements is the canonical example).
#
# Why this is non-trivial: pg_xclaim's xclaim_shmem_startup runs under
# AddinShmemInitLock (required to serialize ShmemInit* across postmaster
# children). Many other shmem_startup_hook implementations -- including
# pgss_shmem_startup -- ALSO acquire that same lock EXCLUSIVE inside their
# body. If the chain is wired to acquire the lock BEFORE invoking the
# previous hook, the previous hook self-deadlocks the chained call and
# cluster boot hangs forever. The canonical pattern (matched here) is to
# call prev_shmem_startup_hook() FIRST, then acquire AddinShmemInitLock
# for our own ShmemInit* calls.
#
# This script proves the multi-extension preload chain does not
# deadlock by:
#   1. Initializing a fresh data directory.
#   2. Setting shared_preload_libraries='pg_stat_statements,pg_xclaim'
#      AND vice versa to verify both chain orders.
#   3. Booting `postgres --single` (preload runs, hooks fire).
#   4. Detecting hang via timeout; FATAL/PANIC via log grep.
#
# Exit:
#   0  PASS  -- both orders boot cleanly
#   1  FAIL  -- timeout (deadlock) OR FATAL/PANIC during boot
#   2  bad usage / missing pg_config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PG_CONFIG_BIN="${1:-${PG_CONFIG_BIN:-}}"
if [[ -z "$PG_CONFIG_BIN" ]]; then
    if PG_CONFIG_BIN="$("$SCRIPT_DIR/find_pg_config.sh" 17 2>/dev/null)"; then
        :
    else
        echo "smoke_gate_multi_preload: no PG_CONFIG provided" >&2
        exit 2
    fi
fi
[[ -x "$PG_CONFIG_BIN" ]] || { echo "smoke_gate_multi_preload: pg_config not executable" >&2; exit 2; }

BIN="$("$PG_CONFIG_BIN" --bindir)"
INITDB="$BIN/initdb"
POSTGRES="$BIN/postgres"

# Track the data directory of the run currently in flight so a signal
# (Ctrl-C / SIGTERM) still removes it. The per-function RETURN trap below
# handles the normal sequential path; this global trap is the safety net
# for an interrupt mid-run.
CURRENT_DATADIR=""
smoke_cleanup() {
    # Preserve the script's real exit status: an EXIT trap whose last
    # command returns non-zero (here `[[ -n "" ]]` once the datadir is
    # already cleared) would otherwise OVERRIDE `exit 0` and fail the run.
    local rc=$?
    [[ -n "$CURRENT_DATADIR" ]] && rm -rf "${CURRENT_DATADIR:?}"
    return $rc
}
trap smoke_cleanup EXIT INT TERM

# pg_stat_statements ships with PG core in the same lib dir; sanity-
# check it is present in this install.
PKGLIB="$("$PG_CONFIG_BIN" --pkglibdir)"
if [[ ! -e "$PKGLIB/pg_stat_statements.dylib" && ! -e "$PKGLIB/pg_stat_statements.so" ]]; then
    echo "smoke_gate_multi_preload: pg_stat_statements not installed in $PKGLIB -- SKIPPED" >&2
    exit 0
fi

run_one() {
    local preload_value="$1"
    local label="$2"

    local datadir
    datadir="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.multi.XXXXXX")"
    CURRENT_DATADIR="$datadir"
    # Remove the datadir on normal return AND clear the global tracker so
    # the EXIT/INT/TERM trap does not re-remove an already-gone path.
    # Shellcheck disable=SC2064 -- intentional early variable expansion.
    trap "rm -rf '${datadir:?}'; CURRENT_DATADIR=''" RETURN

    echo "smoke_gate_multi_preload [$label]: DATADIR=$datadir"

    "$INITDB" -D "$datadir" --locale=ru_RU.UTF-8 -E UTF8 --auth=trust -U postgres >/dev/null

    {
        echo "shared_preload_libraries = '$preload_value'"
        echo "unix_socket_directories = '$datadir'"
        echo "pg_xclaim.max_claims = 65536"
        echo "pg_xclaim.num_partitions = 64"
    } >> "$datadir/postgresql.conf"

    local smoke_log="$datadir/smoke.log"

    # `postgres --single` runs preload + _PG_init + shmem_startup + hooks
    # then idles on stdin. \q exits cleanly. If the chain self-deadlocks,
    # the outer `gtimeout 30s` (or built-in timeout via background +
    # wait) kills the process and reports failure. macOS lacks GNU
    # timeout(1); use the perl fallback `perl -e 'alarm 30; exec @ARGV'`.
    set +e
    perl -e 'alarm 30; exec @ARGV or die "exec failed: $!"' \
        "$POSTGRES" --single -D "$datadir" postgres <<<'\q' >"$smoke_log" 2>&1
    local rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
        echo "FAIL [$label]: postgres --single exited rc=$rc (likely deadlock or panic)" >&2
        echo "--- smoke.log ---" >&2
        cat "$smoke_log" >&2
        return 1
    fi

    if grep -qE 'FATAL|PANIC' "$smoke_log"; then
        echo "FAIL [$label]: FATAL/PANIC during preload" >&2
        grep -E 'FATAL|PANIC' "$smoke_log" >&2 | head -20
        echo "--- smoke.log ---" >&2
        cat "$smoke_log" >&2
        return 1
    fi

    echo "PASS [$label]: chain booted cleanly"
    return 0
}

# Test both orderings. The xact-callback ordering rationale (documented
# in README.md) prefers pg_xclaim FIRST in the preload list, but the
# shmem_startup chain MUST be correct regardless of order -- this gate
# catches regressions where one direction silently deadlocks while the
# other still boots.
run_one 'pg_xclaim,pg_stat_statements' 'pg_xclaim,pg_stat_statements'
run_one 'pg_stat_statements,pg_xclaim' 'pg_stat_statements,pg_xclaim'

echo "SMOKE GATE MULTI-PRELOAD PASS"
exit 0
