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

PRIMARY_DATA=""
STANDBY_DATA=""

stop_and_remove_cluster() {
    local dir="$1"
    local st=0
    if [[ -z "$dir" ]] || [[ ! -d "$dir" ]]; then
        return 0
    fi
    "$PGBIN/pg_ctl" stop -D "$dir" -m immediate -w >/dev/null 2>&1 || true
    if [[ ! -e "$dir/postmaster.pid" ]]; then
        rm -rf "$dir"
        return 0
    fi
    "$PGBIN/pg_ctl" status -D "$dir" >/dev/null 2>&1 || st=$?
    if [[ "$st" -eq 3 ]]; then
        rm -rf "$dir"
    fi
}

cleanup_both() {
    local _rc=$?
    stop_and_remove_cluster "${STANDBY_DATA:-}"
    stop_and_remove_cluster "${PRIMARY_DATA:-}"
    return $_rc
}
trap cleanup_both EXIT INT TERM

PRIMARY_DATA="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.primary.XXXXXX")"
PRIMARY_PORT="$(xclaim_free_port)"
PRIMARY_SOCKET="$PRIMARY_DATA"

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
    -X -q -v ON_ERROR_STOP=1 \
    -c "CREATE EXTENSION IF NOT EXISTS pg_xclaim;"

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

# Start standby and wait for readiness
if ! LC_ALL=ru_RU.UTF-8 LANG=ru_RU.UTF-8 \
    "$PGBIN/pg_ctl" start -D "$STANDBY_DATA" -w \
        -l "$STANDBY_LOG" \
        -o "-p $STANDBY_PORT" \
        >/dev/null 2>&1; then
    STANDBY_STARTED=false
else
    STANDBY_STARTED=true
fi

if $STANDBY_STARTED && "$PGBIN/pg_isready" -h "$STANDBY_SOCKET" -p "$STANDBY_PORT" -U postgres -q 2>/dev/null; then
    echo "  Standby started (checking SQL-level 0A000 rejection across all 9 xclaim.* functions)"

    REJECT_SUMMARY="$("$PGBIN/psql" -h "$STANDBY_SOCKET" -p "$STANDBY_PORT" \
        -U postgres -d postgres -X -A -t -q -v ON_ERROR_STOP=1 <<'SQLS'
DO $$
DECLARE
    fn_calls text[] := ARRAY[
        'SELECT xclaim.try(1::int8)',
        'SELECT xclaim.try(1, 1)',
        'SELECT xclaim.try_many(ARRAY[1]::int8[])',
        'SELECT xclaim.try_many(1, ARRAY[1]::int4[])',
        'SELECT xclaim.count()',
        'SELECT * FROM xclaim.stats()',
        'SELECT * FROM xclaim.debug_snapshot()',
        'SELECT * FROM xclaim.debug()',
        'SELECT xclaim.session_reset()'
    ];
    stmt text;
    err_msg text;
    rejected int := 0;
BEGIN
    FOREACH stmt IN ARRAY fn_calls LOOP
        BEGIN
            EXECUTE stmt;
            RAISE EXCEPTION 'function succeeded on hot standby: %', stmt;
        EXCEPTION WHEN feature_not_supported THEN
            GET STACKED DIAGNOSTICS err_msg = MESSAGE_TEXT;
            IF SQLSTATE <> '0A000' OR position('pg_xclaim does not support hot-standby/recovery mode' in err_msg) = 0 THEN
                RAISE EXCEPTION 'unexpected 0A000 message for %: [%] %', stmt, SQLSTATE, err_msg;
            END IF;
            rejected := rejected + 1;
        END;
    END LOOP;
    IF rejected <> 9 THEN
        RAISE EXCEPTION 'expected 9 rejections, got %', rejected;
    END IF;
END;
$$;
SELECT 'rejected_all=9';
SQLS
)"
    if [[ "$REJECT_SUMMARY" == "rejected_all=9" ]]; then
        echo "  PASS: standby rejects all 9 xclaim.* functions with SQLSTATE 0A000"
        PASS=$(( PASS + 1 ))
        HOT_STANDBY_MSG="SQLSTATE 0A000 across all 9 xclaim.* functions"
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "standby_rejects_xclaim" "PASS" "rejected" "9" "all 9 functions rejected with 0A000")")
    else
        echo "  FAIL: standby did not reject all 9 functions: $REJECT_SUMMARY" >&2
        FAIL=$(( FAIL + 1 ))
        HOT_STANDBY_MSG="INCOMPLETE REJECTION"
        CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "standby_rejects_xclaim" "FAIL" "result" "$REJECT_SUMMARY" "expected 9 rejections")")
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

# Open a persistent session BEFORE promotion, trigger the 0A000 standby
# rejection in that backend, then promote and verify the SAME backend PID
# serves claims without reconnect or restart (proving recovery is not cached).
PROMO_FIFO="$STANDBY_DATA/promo.in"
PROMO_OUT="$STANDBY_DATA/promo.out"
mkfifo "$PROMO_FIFO"
"$PGBIN/psql" -h "$STANDBY_SOCKET" -p "$STANDBY_PORT" -U postgres -d postgres -X -A -t -q \
    < "$PROMO_FIFO" > "$PROMO_OUT" 2>&1 &
PROMO_JOB=$!
exec 8>"$PROMO_FIFO"
cat >&8 <<'SQLPRE'
DO $$
BEGIN
    PERFORM xclaim.try(1, 9);
    PERFORM set_config('xclaim_test.pre_reject', 'unexpected_ok', false);
EXCEPTION WHEN feature_not_supported THEN
    PERFORM set_config('xclaim_test.pre_reject', 'rejected_0A000', false);
END
$$;
SELECT 'pre_state=' || pg_backend_pid() || ':' || pg_is_in_recovery() || ':' || current_setting('xclaim_test.pre_reject');
SQLPRE
for _ in $(seq 1 200); do grep -q '^pre_state=' "$PROMO_OUT" && break; sleep 0.02; done

"$PGBIN/pg_ctl" promote -D "$STANDBY_DATA" -w >/dev/null
PROMOTED="$(standby_sql "SELECT NOT pg_is_in_recovery();")"

echo "BEGIN; SELECT 'existing_sess=' || pg_backend_pid() || ':' || xclaim.try(1, 9) || ':' || cardinality(xclaim.try_many(ARRAY[10, 11]::int8[])) || ':' || xclaim.count(); COMMIT; SELECT 'existing_after=' || xclaim.count();" >&8
exec 8>&-
wait "$PROMO_JOB"

PRE_STATE="$(sed -n 's/^pre_state=//p' "$PROMO_OUT")"
PRE_PID="${PRE_STATE%%:*}"
PRE_REST="${PRE_STATE#*:}"
EXISTING_SESS="$(sed -n 's/^existing_sess=//p' "$PROMO_OUT")"
POST_PID="${EXISTING_SESS%%:*}"
POST_REST="${EXISTING_SESS#*:}"
EXISTING_AFTER="$(sed -n 's/^existing_after=//p' "$PROMO_OUT")"
CLAIMED="$(standby_sql "BEGIN; SELECT xclaim.try(1, 1); SELECT xclaim.count(); COMMIT;")"
HELD_AFTER="$(standby_sql "SELECT capacity_used || ':' || cleanup_misses FROM xclaim.stats();")"
echo "  in recovery before promote: $IN_RECOVERY, promoted: $PROMOTED"
echo "  pre-existing session before->after promote (pid $PRE_PID->$POST_PID): $PRE_REST -> $POST_REST -> $EXISTING_AFTER"
echo "  new session try(1, 1) and count(): $CLAIMED, stats capacity_used:cleanup_misses: $HELD_AFTER"

if [[ "$IN_RECOVERY" == "t" && "$PROMOTED" == "t" && -n "$PRE_PID" && "$PRE_PID" == "$POST_PID" \
      && "$PRE_REST" == "true:rejected_0A000" && "$POST_REST" == "true:2:3" && "$EXISTING_AFTER" == "0" \
      && "$CLAIMED" == "t 1" && "$HELD_AFTER" == "0:0" ]]; then
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
