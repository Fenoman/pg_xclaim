#!/usr/bin/env bash
# test/concurrency/_lib.sh
# Shared library for pg_xclaim concurrency/stress shell tests.
#
# Usage:
#   source "$(dirname "$0")/_lib.sh"
#   pg_xclaim_start_temp_cluster   # sets PGDATA, PGPORT, PGSOCKET, PGBIN
#   trap pg_xclaim_stop_temp_cluster EXIT INT TERM
#   pg_xclaim_psql -c "SELECT 1"
#
# HARD INVARIANTS:
#   * Clusters under /tmp/pg_xclaim_${USER}_$$.XXX only
#   * Locale ru_RU.UTF-8 in initdb
#   * set -euo pipefail enforced in every caller
#   * trap cleanup set by EACH test script individually (for composability)
#
# PG version: PG 17 is the primary target.
# PG_CONFIG env override wins; falls back to candidate paths for macOS arm64.
#
# Port strategy: a Python-based probe binds port 0 and lets the kernel pick a
# free ephemeral TCP port, avoiding collisions with existing services. Private
# Unix socket under $PGDATA to avoid /tmp permission races.

set -euo pipefail

# ---------------------------------------------------------------------------
# PG binary discovery.
# ---------------------------------------------------------------------------
# Candidate explicit paths via env override + glob-resolved Homebrew Cellar
# paths (latest installed minor version each). Glob keeps the list stable
# across `brew upgrade` -- no hardcoded x.y suffix to bit-rot.
XCLAIM_CANDIDATE_PG_CONFIGS=(
    "${PG17_CONFIG:-}"
    "${PG18_CONFIG:-}"
    "${PG16_CONFIG:-}"
    /opt/homebrew/Cellar/postgresql@17/*/bin/pg_config
    /opt/homebrew/Cellar/postgresql@18/*/bin/pg_config
    /opt/homebrew/Cellar/postgresql@16/*/bin/pg_config
    /usr/lib/postgresql/17/bin/pg_config
    /usr/lib/postgresql/18/bin/pg_config
    /usr/lib/postgresql/16/bin/pg_config
    "pg_config"
)

# Resolve PG_CONFIG once at source time. We want a binary that owns the
# `postgres` server -- the `libpq` Homebrew formula also ships `pg_config`
# (client-only, points at /opt/homebrew/Cellar/libpq/... and exposes only
# bindir for psql/initdb). That bindir has NO `postgres` binary, so
# `pg_ctl start` later silently no-ops and tests hang. Require the
# resolved bindir to contain `postgres` to filter libpq out.
if [[ -z "${PG_CONFIG:-}" ]]; then
    for _cand in "${XCLAIM_CANDIDATE_PG_CONFIGS[@]}"; do
        [[ -z "$_cand" ]] && continue
        if command -v "$_cand" &>/dev/null || [[ -x "$_cand" ]]; then
            _cand_bindir="$("$_cand" --bindir 2>/dev/null || true)"
            if [[ -n "$_cand_bindir" ]] && [[ -x "$_cand_bindir/postgres" ]]; then
                PG_CONFIG="$_cand"
                break
            fi
        fi
    done
fi
: "${PG_CONFIG:?ERROR: could not find a usable pg_config. Set PG_CONFIG or PG17_CONFIG.}"

PGBIN="$("$PG_CONFIG" --bindir)"

# ---------------------------------------------------------------------------
# Free-port probe (no races vs fixed-port assignment in a common range).
# Uses Python3 -- available on macOS and all CI images.
# ---------------------------------------------------------------------------
xclaim_free_port() {
    python3 - <<'EOF'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(('127.0.0.1', 0))
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    print(s.getsockname()[1])
EOF
}

# ---------------------------------------------------------------------------
# Start a temporary single-node cluster.
#
# Sets globals:
#   PGDATA   -- datadir under /tmp/pg_xclaim_${USER}_$$
#   PGPORT   -- chosen free port
#   PGSOCKET -- socket directory == $PGDATA (private, no /tmp race)
#   PGBIN    -- PG binaries dir (already set above)
#   PGHOST   -- set to PGSOCKET for psql unix-socket connections
#
# Optional env:
#   XCLAIM_MAX_CLAIMS       (default 65536)
#   XCLAIM_NUM_PARTITIONS   (default 128)
#   XCLAIM_EXTRA_CONF       (extra lines appended to postgresql.conf verbatim)
#   XCLAIM_NO_PRELOAD       (if set, skip shared_preload_libraries)
# ---------------------------------------------------------------------------
pg_xclaim_start_temp_cluster() {
    local suffix="${1:-main}"
    local _max_claims="${XCLAIM_MAX_CLAIMS:-65536}"
    local _num_partitions="${XCLAIM_NUM_PARTITIONS:-128}"

    PGDATA="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.${suffix}.XXXXXX")"
    PGPORT="$(xclaim_free_port)"
    PGSOCKET="$PGDATA"   # private socket dir -- no race with other users
    PGHOST="$PGDATA"
    export PGDATA PGPORT PGSOCKET PGHOST

    # Preflight: ru_RU.UTF-8 must exist on this host. initdb dies with a
    # cryptic "invalid locale" otherwise, and below we capture its output to
    # a log -- but failing here gives the operator a directly actionable hint.
    if ! { locale -a 2>/dev/null || true; } | grep -qiE "ru_RU\.(UTF-8|utf8)"; then
        echo "[lib] FATAL: locale ru_RU.UTF-8 not available on this host." >&2
        echo "[lib]   Generate it first, e.g.: sudo locale-gen ru_RU.UTF-8" >&2
        echo "[lib]   (macOS ships ru_RU.UTF-8 by default; on Linux install/generate it.)" >&2
        return 1
    fi

    echo "[lib] initdb -> $PGDATA  port=$PGPORT" >&2
    local _initdb_out
    if ! _initdb_out="$("$PGBIN/initdb" -D "$PGDATA" \
        --locale=ru_RU.UTF-8 \
        -E UTF8 \
        --auth=trust \
        -U postgres 2>&1)"; then
        echo "[lib] FATAL: initdb failed; output follows:" >&2
        printf '%s\n' "$_initdb_out" >&2
        return 1
    fi

    # Write postgresql.conf
    {
        [[ -z "${XCLAIM_NO_PRELOAD:-}" ]] && echo "shared_preload_libraries = 'pg_xclaim'"
        echo "port = $PGPORT"
        echo "unix_socket_directories = '$PGSOCKET'"
        echo "pg_xclaim.max_claims = $_max_claims"
        echo "pg_xclaim.num_partitions = $_num_partitions"
        echo "log_min_messages = warning"
        echo "log_destination = 'stderr'"
        echo "logging_collector = off"
        # hot_standby related (default on, needed for standby test)
        echo "wal_level = replica"
        echo "max_wal_senders = 3"
        echo "hot_standby = on"
        # recovery after crash: leave enabled by default; sigkill_stale.sh
        # overrides this via XCLAIM_EXTRA_CONF
        [[ -n "${XCLAIM_EXTRA_CONF:-}" ]] && echo "${XCLAIM_EXTRA_CONF}"
    } >> "$PGDATA/postgresql.conf"

    # LC_ALL/LANG must be exported in the calling env: on macOS the
    # postmaster inherits the parent's locale at startup, and an unset
    # LC_ALL triggers "postmaster became multithreaded during startup"
    # FATAL on PG 17.10+. Inline-prefix keeps the locale scoped to pg_ctl.
    LC_ALL=ru_RU.UTF-8 LANG=ru_RU.UTF-8 \
    "$PGBIN/pg_ctl" start -D "$PGDATA" -w \
        -l "$PGDATA/server.log" \
        -o "-p $PGPORT" \
        >/dev/null 2>&1

    # Create extension (unless caller opted out for non-preload tests)
    if [[ -z "${XCLAIM_NO_EXTENSION:-}" ]] && [[ -z "${XCLAIM_NO_PRELOAD:-}" ]]; then
        "$PGBIN/psql" -h "$PGSOCKET" -p "$PGPORT" -U postgres -d postgres \
            -c "CREATE EXTENSION IF NOT EXISTS pg_xclaim;" \
            >/dev/null 2>&1
    fi

    echo "[lib] cluster up: PGDATA=$PGDATA PGPORT=$PGPORT" >&2
}

# ---------------------------------------------------------------------------
# Stop and remove the temp cluster.
# Safe to call multiple times (idempotent).
# ---------------------------------------------------------------------------
pg_xclaim_stop_temp_cluster() {
    local _rc=$?
    if [[ -n "${PGDATA:-}" ]] && [[ -d "${PGDATA:-}" ]]; then
        echo "[lib] stopping cluster $PGDATA" >&2
        "$PGBIN/pg_ctl" stop -D "$PGDATA" -m immediate >/dev/null 2>&1 || true
        rm -rf "$PGDATA"
        unset PGDATA PGPORT PGSOCKET PGHOST
    fi
    return $_rc
}

# ---------------------------------------------------------------------------
# Convenience psql wrapper -- always connects to the temp cluster.
# PGHOST/PGPORT are REQUIRED: an unset value means no temp cluster is running.
# Hard-fail rather than falling back to a default port/host -- a default could
# silently connect to a real user cluster and mutate it.
# ---------------------------------------------------------------------------
pg_xclaim_psql() {
    "$PGBIN/psql" -h "${PGHOST:?pg_xclaim temp cluster not running}" \
        -p "${PGPORT:?pg_xclaim temp cluster not running}" \
        -U postgres -d postgres \
        "$@"
}

# ---------------------------------------------------------------------------
# Run a SQL string in the background psql; write output to a tmpfile.
# Returns the tmpfile path.  Caller must manage lifecycle.
# ---------------------------------------------------------------------------
pg_xclaim_psql_bg() {
    local tmpout
    tmpout="$(mktemp)"
    "$PGBIN/psql" -h "${PGHOST:?pg_xclaim temp cluster not running}" \
        -p "${PGPORT:?pg_xclaim temp cluster not running}" \
        -U postgres -d postgres \
        "$@" >"$tmpout" 2>&1 &
    echo "$tmpout"
}

# ---------------------------------------------------------------------------
# Assert helper -- prints PASS/FAIL and exits on failure.
# Usage: xclaim_assert <condition_description> <actual_value> <expected_value>
# ---------------------------------------------------------------------------
xclaim_assert_eq() {
    local desc="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  ASSERT PASS: $desc (got '$actual')"
    else
        echo "  ASSERT FAIL: $desc -- expected='$expected' got='$actual'" >&2
        return 1
    fi
}

xclaim_assert_gt() {
    local desc="$1" actual="$2" threshold="$3"
    if (( actual > threshold )); then
        echo "  ASSERT PASS: $desc ($actual > $threshold)"
    else
        echo "  ASSERT FAIL: $desc -- expected > $threshold, got $actual" >&2
        return 1
    fi
}

xclaim_assert_lt() {
    local desc="$1" actual="$2" threshold="$3"
    if (( actual < threshold )); then
        echo "  ASSERT PASS: $desc ($actual < $threshold)"
    else
        echo "  ASSERT FAIL: $desc -- expected < $threshold, got $actual" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Check server log for unexpected FATAL/PANIC after a test.
# Usage: xclaim_check_server_log [label] [whitelist_regex]
#
# The temp cluster runs under ru_RU.UTF-8, so on an NLS-enabled build the
# severity tags are localized: FATAL renders as "ВАЖНО" and PANIC as "ПАНИКА"
# (per PostgreSQL ru.po). Matching English-only would no-op on those builds,
# so both forms are matched.
#
# whitelist_regex (optional): an ERE matching log lines that are EXPECTED for
# this test (e.g. a deliberate pg_terminate_backend message). Matching lines
# are dropped before the FATAL/PANIC scan so they do not produce a false FAIL.
# Exits non-zero if any non-whitelisted FATAL/PANIC line remains.
# ---------------------------------------------------------------------------
xclaim_check_server_log() {
    local label="${1:-}"
    local whitelist="${2:-}"
    local sev='FATAL|PANIC|ВАЖНО|ПАНИКА'
    if [[ -f "${PGDATA:-}/server.log" ]]; then
        local hits
        hits="$(grep -E "$sev" "$PGDATA/server.log" 2>/dev/null || true)"
        if [[ -n "$whitelist" ]]; then
            hits="$(printf '%s\n' "$hits" | grep -vE "$whitelist" || true)"
        fi
        if [[ -n "$hits" ]]; then
            echo "  SERVER LOG FATAL/PANIC detected${label:+ in $label}:" >&2
            printf '%s\n' "$hits" | tail -10 >&2
            return 1
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Millisecond wall-clock timer (uses python3 for sub-second precision).
# Usage:
#   T0=$(xclaim_now_ms)
#   ... do work ...
#   T1=$(xclaim_now_ms)
#   ELAPSED=$(( T1 - T0 ))
# ---------------------------------------------------------------------------
xclaim_now_ms() {
    python3 -c "import time; print(int(time.time() * 1000))"
}

# ---------------------------------------------------------------------------
# CSV output helper -- emit one result row for downstream CI.
# Format: TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES
# ---------------------------------------------------------------------------
xclaim_csv_row() {
    local script="$1" test="$2" result="$3" metric_name="$4" metric_value="$5" notes="${6:-}"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "${ts},${script},${test},${result},${metric_name},${metric_value},${notes}"
}

# ---------------------------------------------------------------------------
# Version banner
# ---------------------------------------------------------------------------
xclaim_banner() {
    local script="$1"
    local pg_ver
    pg_ver="$("$PGBIN/postgres" --version 2>/dev/null | head -1 || echo unknown)"
    echo "=== pg_xclaim concurrency test: $script ==="
    echo "    PG: $pg_ver"
    echo "    PG_CONFIG: $PG_CONFIG"
    echo "    Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""
}
