#!/usr/bin/env bash
# test/concurrency/hot_standby_rejection.sh
# Hot-standby rejection test.
#
# Scenario:
#   1. Start primary cluster with pg_xclaim preloaded
#   2. pg_basebackup to create standby
#   3. Configure standby with shared_preload_libraries='pg_xclaim'
#   4. Start standby. The first xclaim.try call MUST raise ERROR about
#      hot-standby being unsupported.
#   5. Remove pg_xclaim from standby's preload_libraries
#   6. Start standby -> MUST start cleanly
#   7. Put pg_xclaim back into the standby's preload, start it and promote
#      it. Without a restart a claim MUST succeed, and COMMIT MUST release
#      it.
#
# How the rejection fires:
#   pg_xclaim's XCLAIM_REQUIRE_INIT() macro checks RecoveryInProgress() at
#   SQL call time. RecoveryInProgress() is unsafe in _PG_init because
#   XLogCtl is NULL at preload time. The hot-standby check therefore runs
#   at SQL call time, not in _PG_init. We test the documented SQL-call
#   behaviour.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="hot_standby_rejection"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Setup primary cluster
# ---------------------------------------------------------------------------
echo "--- Setup: primary cluster with pg_xclaim ---"

PRIMARY_DATA="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.primary.XXXXXX")"
PRIMARY_PORT="$(xclaim_free_port)"
PRIMARY_SOCKET="$PRIMARY_DATA"

STANDBY_DATA=""

cleanup_both() {
    local _rc=$?
    if [[ -n "${STANDBY_DATA:-}" ]] && [[ -d "${STANDBY_DATA:-}" ]]; then
        "$PGBIN/pg_ctl" stop -D "$STANDBY_DATA" -m immediate >/dev/null 2>&1 || true
        rm -rf "$STANDBY_DATA"
    fi
    if [[ -d "$PRIMARY_DATA" ]]; then
        "$PGBIN/pg_ctl" stop -D "$PRIMARY_DATA" -m immediate >/dev/null 2>&1 || true
        rm -rf "$PRIMARY_DATA"
    fi
    return $_rc
}
trap cleanup_both EXIT INT TERM

# A hot standby refuses to recover unless these settings are at least the
# primary's values. Both configs pin the same values: initdb may tune them
# (Postgres Pro's pgpro_tune raises max_connections), and the standby config
# below is written from scratch.
HOT_STANDBY_LIMITS="max_connections = 100
max_worker_processes = 8
max_wal_senders = 3
max_prepared_transactions = 0
max_locks_per_transaction = 64"

# initdb primary
"$PGBIN/initdb" -D "$PRIMARY_DATA" \
    --locale=ru_RU.UTF-8 \
    -E UTF8 \
    --auth=trust \
    -U postgres \
    >/dev/null 2>&1

cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_xclaim'
port = $PRIMARY_PORT
unix_socket_directories = '$PRIMARY_SOCKET'
pg_xclaim.max_claims = 65536
pg_xclaim.num_partitions = 128
wal_level = replica
$HOT_STANDBY_LIMITS
hot_standby = on
archive_mode = off
log_min_messages = warning
logging_collector = off
EOF

# Allow replication connection from localhost (pg_hba.conf)
echo "local replication postgres trust" >> "$PRIMARY_DATA/pg_hba.conf"
echo "host replication postgres 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"

LC_ALL=ru_RU.UTF-8 LANG=ru_RU.UTF-8 \
"$PGBIN/pg_ctl" start -D "$PRIMARY_DATA" -w \
    -l "$PRIMARY_DATA/server.log" \
    -o "-p $PRIMARY_PORT" \
    >/dev/null 2>&1

"$PGBIN/psql" -h "$PRIMARY_SOCKET" -p "$PRIMARY_PORT" -U postgres -d postgres \
    -c "CREATE EXTENSION IF NOT EXISTS pg_xclaim;" >/dev/null 2>&1

echo "  Primary started on port $PRIMARY_PORT"

# ---------------------------------------------------------------------------
# Create standby via pg_basebackup
# ---------------------------------------------------------------------------
echo "--- Creating standby via pg_basebackup ---"

STANDBY_DATA="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.standby.XXXXXX")"
STANDBY_PORT="$(xclaim_free_port)"
STANDBY_SOCKET="$STANDBY_DATA"
STANDBY_LOG="$STANDBY_DATA/standby.log"

"$PGBIN/pg_basebackup" \
    -h "$PRIMARY_SOCKET" \
    -p "$PRIMARY_PORT" \
    -U postgres \
    -D "$STANDBY_DATA" \
    --wal-method=stream \
    --checkpoint=fast \
    >/dev/null 2>&1

echo "  pg_basebackup completed -> $STANDBY_DATA"

# Configure standby
cat > "$STANDBY_DATA/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_xclaim'
port = $STANDBY_PORT
unix_socket_directories = '$STANDBY_SOCKET'
pg_xclaim.max_claims = 65536
pg_xclaim.num_partitions = 128
$HOT_STANDBY_LIMITS
hot_standby = on
primary_conninfo = 'host=$PRIMARY_SOCKET port=$PRIMARY_PORT user=postgres'
log_min_messages = warning
logging_collector = off
EOF

# Create standby.signal (PG 12+)
touch "$STANDBY_DATA/standby.signal"

# ---------------------------------------------------------------------------
# Test 1: standby WITH preload -- must start, the SQL call must raise the
#         hot-standby ERROR
# ---------------------------------------------------------------------------
echo "--- Test 1: standby with pg_xclaim preload ---"

# Start standby and capture log
LC_ALL=ru_RU.UTF-8 LANG=ru_RU.UTF-8 \
"$PGBIN/pg_ctl" start -D "$STANDBY_DATA" -w \
    -l "$STANDBY_LOG" \
    -o "-p $STANDBY_PORT" \
    >/dev/null 2>&1 || true

# Wait briefly for standby to start (or fail)
sleep 2

STANDBY_STARTED=false
if "$PGBIN/pg_isready" -h "$STANDBY_SOCKET" -p "$STANDBY_PORT" -U postgres -q 2>/dev/null; then
    STANDBY_STARTED=true
    echo "  Standby started (checking SQL-level rejection)"

    # Try xclaim.try() on standby -- must ERROR with hot-standby message
    SQL_RESULT="$("$PGBIN/psql" -h "$STANDBY_SOCKET" -p "$STANDBY_PORT" \
        -U postgres -d postgres \
        -X -A -t \
        -c "SELECT xclaim.try(1, 1);" \
        2>&1)" || true

    echo "  xclaim.try() on standby output:"
    echo "$SQL_RESULT" | head -5 | sed 's/^/    /'

    if echo "$SQL_RESULT" | grep -qiE "hot.standby|recovery|ERRCODE_FEATURE_NOT_SUPPORTED|not support"; then
        echo "  PASS: standby correctly rejects xclaim.try() with hot-standby error"
        PASS=$(( PASS + 1 ))
        HOT_STANDBY_MSG="$(echo "$SQL_RESULT" | grep -iE "hot.standby|recovery|not support" | head -1)"
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "standby_rejects_xclaim" "PASS" "result" "error" "hot-standby rejection at SQL level")")
    else
        echo "  FAIL: standby did not reject xclaim.try() with expected error" >&2
        echo "  Output was: $SQL_RESULT" >&2
        FAIL=$(( FAIL + 1 ))
        HOT_STANDBY_MSG="NOT FOUND"
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "standby_rejects_xclaim" "FAIL" "result" "no_error" "expected hot-standby rejection")")
    fi
else
    # pg_xclaim checks for recovery at SQL call time, so a standby with the
    # library preloaded must start. Severity tags are localized in the
    # ru_RU.UTF-8 cluster ("ВАЖНО" for FATAL, "ПАНИКА" for PANIC).
    echo "  FAIL: standby did not start with pg_xclaim preloaded" >&2
    HOT_STANDBY_MSG="$(grep -E 'FATAL|PANIC|ВАЖНО|ПАНИКА' "$STANDBY_LOG" 2>/dev/null | head -3 || true)"
    [[ -n "$HOT_STANDBY_MSG" ]] || HOT_STANDBY_MSG="standby did not start"
    echo "  Standby log tail:" >&2
    tail -n 20 "$STANDBY_LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "standby_starts_with_preload" "FAIL" "result" "no_start" "standby must start with pg_xclaim preloaded")")
fi

# Stop standby if running
if $STANDBY_STARTED; then
    "$PGBIN/pg_ctl" stop -D "$STANDBY_DATA" -m immediate >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Test 2: standby WITHOUT preload -- must start cleanly
# ---------------------------------------------------------------------------
echo "--- Test 2: standby without pg_xclaim preload ---"

# Remove pg_xclaim from standby's preload_libraries
sed -i.bak "s/^shared_preload_libraries.*=.*'pg_xclaim'/# shared_preload_libraries = 'pg_xclaim'/" \
    "$STANDBY_DATA/postgresql.conf"

# Reset log
: > "$STANDBY_LOG"

LC_ALL=ru_RU.UTF-8 LANG=ru_RU.UTF-8 \
"$PGBIN/pg_ctl" start -D "$STANDBY_DATA" -w \
    -l "$STANDBY_LOG" \
    -o "-p $STANDBY_PORT" \
    >/dev/null 2>&1 || true

sleep 1

if "$PGBIN/pg_isready" -h "$STANDBY_SOCKET" -p "$STANDBY_PORT" -U postgres -q 2>/dev/null; then
    echo "  PASS: standby started cleanly without pg_xclaim preload"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "standby_no_preload_starts" "PASS" "result" "started" "clean start")")
    "$PGBIN/pg_ctl" stop -D "$STANDBY_DATA" -m immediate >/dev/null 2>&1 || true
else
    echo "  FAIL: standby failed to start without pg_xclaim preload" >&2
    echo "  Standby log tail:" >&2
    tail -n 20 "$STANDBY_LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "standby_no_preload_starts" "FAIL" "result" "failed" "should start without preload")")
fi

# ---------------------------------------------------------------------------
# Test 3: promotion -- a standby with pg_xclaim preloaded serves claims after
#         promotion without a restart
# ---------------------------------------------------------------------------
echo "--- Test 3: promotion of a standby with pg_xclaim preload ---"

# Test 2 left the original configuration in postgresql.conf.bak.
mv "$STANDBY_DATA/postgresql.conf.bak" "$STANDBY_DATA/postgresql.conf"
: > "$STANDBY_LOG"

LC_ALL=ru_RU.UTF-8 LANG=ru_RU.UTF-8 \
"$PGBIN/pg_ctl" start -D "$STANDBY_DATA" -w \
    -l "$STANDBY_LOG" \
    -o "-p $STANDBY_PORT" \
    >/dev/null 2>&1 || true

standby_sql() {
    { "$PGBIN/psql" -h "$STANDBY_SOCKET" -p "$STANDBY_PORT" -U postgres -d postgres \
        -X -A -t -q -c "$1" 2>&1 || true; } | tr '\n' ' ' | sed 's/ *$//'
}

IN_RECOVERY="$(standby_sql "SELECT pg_is_in_recovery();")"
"$PGBIN/pg_ctl" promote -D "$STANDBY_DATA" -w >/dev/null 2>&1 || true
PROMOTED="$(standby_sql "SELECT NOT pg_is_in_recovery();")"
CLAIMED="$(standby_sql "BEGIN; SELECT xclaim.try(1, 1); SELECT xclaim.count(); COMMIT;")"
HELD_AFTER="$(standby_sql "SELECT xclaim.count();")"
echo "  in recovery before promote: $IN_RECOVERY, promoted: $PROMOTED"
echo "  try(1, 1) and count() in one transaction: $CLAIMED, count() after COMMIT: $HELD_AFTER"

if [[ "$IN_RECOVERY" == "t" && "$PROMOTED" == "t" && "$CLAIMED" == "t 1" && "$HELD_AFTER" == "0" ]]; then
    echo "  PASS: the promoted standby serves claims without a restart"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "promoted_standby_claims" "PASS" "result" "claimed" "claims work after promotion without a restart")")
else
    echo "  FAIL: the promoted standby did not serve a claim" >&2
    echo "  Standby log tail:" >&2
    tail -n 20 "$STANDBY_LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "promoted_standby_claims" "FAIL" "result" "not_claimed" "claims must work after promotion without a restart")")
fi
"$PGBIN/pg_ctl" stop -D "$STANDBY_DATA" -m immediate >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo ""
echo "=== HOT-STANDBY REJECTION EVIDENCE ==="
echo "  Method: xclaim.try() on standby returns ERROR with hot-standby message"
echo "  Message: $HOT_STANDBY_MSG"
echo "  Code path: XCLAIM_REQUIRE_INIT() macro -> RecoveryInProgress() check"
echo "  Source: src/pg_xclaim.h XCLAIM_REQUIRE_INIT macro"
echo ""

echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
