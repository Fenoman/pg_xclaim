#!/usr/bin/env bash
# test/concurrency/bulk_concurrent.sh
# Bulk concurrent API test.
#
# Scenarios:
#   1. 4 sessions concurrently try_many on overlapping ranges: each session
#      tries keys 1..10000 and records the keys it won in a table. No session
#      commits before all of them have reported, so every key has exactly one
#      winner: the table holds each key 1..10000 exactly once and every
#      session exits successfully.
#
#   2. Catastrophic rollback: a cluster with max_claims=64 is started separately.
#      try_many 100 keys -> ERROR with SQLSTATE 53400. After rollback, debug()
#      shows 0 entries.
#
#   3. Reentrant bulk: same session try_many with already-held keys -> all true,
#      no double entries in debug().
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="bulk_concurrent"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

N_SESSIONS=4
KEY_RANGE=10000

# ---------------------------------------------------------------------------
# Start main cluster
# ---------------------------------------------------------------------------
pg_xclaim_start_temp_cluster "bulk_concurrent"
MAIN_PGDATA="$PGDATA"
MAIN_PGPORT="$PGPORT"
MAIN_PGHOST="$PGHOST"

# All data dirs created by this script
ALL_DATADIRS=("$MAIN_PGDATA")
# Bare mktemp files/dirs registered here are removed even on an early set -e
# abort, not only on the success path.
XCLAIM_TMPFILES=()

# Sessions of Test 1 (index -> psql pid).
SESSION_PIDS=()

cleanup_all() {
    for pid in "${SESSION_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    for dd in "${ALL_DATADIRS[@]:-}"; do
        if [[ -n "$dd" ]] && [[ -d "$dd" ]]; then
            "$PGBIN/pg_ctl" stop -D "$dd" -m immediate >/dev/null 2>&1 || true
            rm -rf "$dd"
        fi
    done
    rm -rf "${XCLAIM_TMPFILES[@]:-}"
}
trap cleanup_all EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
CSV_ROWS=()

# ---------------------------------------------------------------------------
# Sessions the test feeds statement by statement: psql number I reads from
# its own FIFO on file descriptor 20 + I, so all of them stay inside their
# transactions until the test sends COMMIT. Same pattern as xclaim_holder_*
# in _lib.sh, which keeps a single session only.
#   bulk_session_open I       start psql I (ON_ERROR_STOP, lc_messages=C)
#   bulk_session_sql I SQL    send one statement
#   bulk_session_wait I REGEX wait up to 60 s until the output matches REGEX,
#                             return 1 at once if psql has exited without it
#   bulk_session_close I      close the input, return the exit status of psql
# ---------------------------------------------------------------------------
#
# psql closes the write ends of the other sessions' FIFOs it inherits:
# otherwise an earlier session would never see EOF on close.
bulk_session_open() {
    local i="$1" fifo="$WORK_DIR/session_$1.in"
    mkfifo "$fifo"
    (
        for j in $(seq 1 "$N_SESSIONS"); do
            eval "exec $(( 20 + j ))>&-"
        done
        export PGOPTIONS='-c lc_messages=C'
        exec "$PGBIN/psql" -h "$MAIN_PGHOST" -p "$MAIN_PGPORT" \
            -U postgres -d postgres -X -A -t -q -v ON_ERROR_STOP=1
    ) <"$fifo" >"$WORK_DIR/session_$i.out" 2>&1 &
    SESSION_PIDS[i]=$!
    eval "exec $(( 20 + i ))>\"\$fifo\""
}

# The write runs in a subshell: if psql has already exited (ON_ERROR_STOP),
# SIGPIPE ends the subshell, not the test.
bulk_session_sql() {
    ( printf '%s\n' "$2" >&$(( 20 + $1 )) ) 2>/dev/null || true
}

bulk_session_wait() {
    local i="$1" re="$2" out="$WORK_DIR/session_$1.out" n
    for n in $(seq 1 600); do
        grep -qE "$re" "$out" 2>/dev/null && return 0
        if ! kill -0 "${SESSION_PIDS[i]}" 2>/dev/null; then
            grep -qE "$re" "$out" 2>/dev/null
            return
        fi
        sleep 0.1
    done
    return 1
}

bulk_session_close() {
    local i="$1" pid="${SESSION_PIDS[$1]}" rc=0 n
    eval "exec $(( 20 + i ))>&-"
    for n in $(seq 1 300); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        SESSION_PIDS[i]=""
        return 1
    fi
    wait "$pid" || rc=$?
    SESSION_PIDS[i]=""
    return "$rc"
}

# ---------------------------------------------------------------------------
# Test 1: concurrent try_many on overlapping ranges -- one winner per key
# ---------------------------------------------------------------------------
echo "--- Test 1: $N_SESSIONS concurrent sessions on 1..$KEY_RANGE ---"

WORK_DIR="$(mktemp -d)"
XCLAIM_TMPFILES+=("$WORK_DIR")

# Each session inserts the keys it won. No primary key: a key won twice
# shows up as a duplicate row instead of an insert error.
pg_xclaim_psql -X -q -v ON_ERROR_STOP=1 \
    -c "CREATE UNLOGGED TABLE bulk_wins (session int4 NOT NULL, k int4 NOT NULL);"

# Determinism. Every session connects first, then all of them get the
# try_many statement at once, and none of them commits before every session
# has reported its wins. A COMMIT before that would release keys that a
# later session could legitimately take again.
T1_OK=true
for i in $(seq 1 $N_SESSIONS); do
    bulk_session_open "$i"
    bulk_session_sql "$i" "SELECT 'connected';"
done
for i in $(seq 1 $N_SESSIONS); do
    if ! bulk_session_wait "$i" '^connected$'; then
        echo "  FAIL: session $i did not connect" >&2
        T1_OK=false
    fi
done

for i in $(seq 1 $N_SESSIONS); do
    bulk_session_sql "$i" "BEGIN;"
    bulk_session_sql "$i" "INSERT INTO bulk_wins SELECT $i, t.k FROM (SELECT ARRAY(SELECT generate_series(1, $KEY_RANGE)::int4) AS a) keys, unnest(keys.a, xclaim.try_many(1, keys.a)) AS t(k, won) WHERE t.won;"
    bulk_session_sql "$i" "SELECT 'wins=' || count(*) FROM bulk_wins WHERE session = $i;"
done

TOTAL_WINS=0
for i in $(seq 1 $N_SESSIONS); do
    if bulk_session_wait "$i" '^wins=[0-9]+$'; then
        WIN_COUNT="$(sed -n 's/^wins=//p' "$WORK_DIR/session_$i.out")"
    else
        WIN_COUNT="none"
        T1_OK=false
    fi
    echo "  Session $i wins: $WIN_COUNT"
    [[ "$WIN_COUNT" =~ ^[0-9]+$ ]] && TOTAL_WINS=$(( TOTAL_WINS + WIN_COUNT ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "session_${i}_wins" "INFO" "wins" "$WIN_COUNT" "")")
done

for i in $(seq 1 $N_SESSIONS); do
    bulk_session_sql "$i" "COMMIT;"
done
for i in $(seq 1 $N_SESSIONS); do
    if bulk_session_close "$i"; then
        rc=0
    else
        rc=$?
    fi
    if (( rc != 0 )); then
        echo "  FAIL: session $i psql exit status $rc, output follows:" >&2
        sed 's/^/    /' "$WORK_DIR/session_$i.out" >&2
        T1_OK=false
    fi
done

# Exactly one winner per key: KEY_RANGE rows, KEY_RANGE distinct keys, all
# within 1..KEY_RANGE, so every key appears exactly once.
if ! COVERAGE="$(pg_xclaim_psql -X -A -t -v ON_ERROR_STOP=1 \
        -c "SELECT count(*) || '|' || count(DISTINCT k) || '|' || coalesce(min(k), 0) || '|' || coalesce(max(k), 0) FROM bulk_wins;" 2>&1)"; then
    echo "  FAIL: coverage query failed: $COVERAGE" >&2
    COVERAGE="error"
    T1_OK=false
fi
echo "  Total wins across $N_SESSIONS sessions: $TOTAL_WINS (expected $KEY_RANGE)"
echo "  Won keys rows|distinct|min|max: $COVERAGE (expected $KEY_RANGE|$KEY_RANGE|1|$KEY_RANGE)"

if $T1_OK && [[ "$TOTAL_WINS" == "$KEY_RANGE" ]] \
        && [[ "$COVERAGE" == "$KEY_RANGE|$KEY_RANGE|1|$KEY_RANGE" ]]; then
    echo "  PASS: every key 1..$KEY_RANGE won exactly once, all sessions exited 0"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "one_winner_per_key" "PASS" "total_wins" "$TOTAL_WINS" "unique winners = $KEY_RANGE")")
else
    echo "  FAIL: wins=$TOTAL_WINS coverage=$COVERAGE sessions_ok=$T1_OK" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "one_winner_per_key" "FAIL" "total_wins" "$TOTAL_WINS" "coverage $COVERAGE")")
fi

rm -rf "$WORK_DIR"

# ---------------------------------------------------------------------------
# Test 2: catastrophic rollback with small-capacity cluster
# ---------------------------------------------------------------------------
echo "--- Test 2: catastrophic rollback with capacity=64 ---"

# Start small-capacity cluster
CAP_DATA="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.cap64.XXXXXX")"
CAP_PORT="$(xclaim_free_port)"
ALL_DATADIRS+=("$CAP_DATA")

"$PGBIN/initdb" -D "$CAP_DATA" \
    --locale=ru_RU.UTF-8 -E UTF8 --auth=trust -U postgres \
    >/dev/null 2>&1

cat >> "$CAP_DATA/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_xclaim'
port = $CAP_PORT
unix_socket_directories = '$CAP_DATA'
pg_xclaim.max_claims = 64
pg_xclaim.num_partitions = 16
pg_xclaim.expected_claims_per_backend = 32
log_min_messages = warning
logging_collector = off
EOF

# Inline locale, as in _lib.sh: on macOS a postmaster started without one
# exits with FATAL "postmaster became multithreaded during startup".
LC_ALL=ru_RU.UTF-8 LANG=ru_RU.UTF-8 \
"$PGBIN/pg_ctl" start -D "$CAP_DATA" -w \
    -l "$CAP_DATA/server.log" \
    -o "-p $CAP_PORT" >/dev/null 2>&1

"$PGBIN/psql" -h "$CAP_DATA" -p "$CAP_PORT" -U postgres -d postgres \
    -c "CREATE EXTENSION IF NOT EXISTS pg_xclaim;" >/dev/null 2>&1

# 100 unique keys against max_claims = 64 must raise SQLSTATE 53400
# (configuration_limit_exceeded). lc_messages=C and VERBOSITY=verbose print
# it as "ERROR:  53400: ...". Without ON_ERROR_STOP psql runs the ROLLBACK
# after the error and exits 0: 2 would mean the backend crashed.
if CAP_RESULT="$(PGOPTIONS='-c lc_messages=C' "$PGBIN/psql" -h "$CAP_DATA" -p "$CAP_PORT" \
    -U postgres -d postgres -X -A -t -v VERBOSITY=verbose 2>&1 <<'SQLCAP'
BEGIN;
SELECT 'wins=' || count(v) FROM unnest(
    xclaim.try_many(1, ARRAY(SELECT generate_series(1, 100)::int4))
) v WHERE v;
ROLLBACK;
SQLCAP
)"; then
    CAP_RC=0
else
    CAP_RC=$?
fi

echo "  Cap=64 test output (psql exit status $CAP_RC):"
echo "$CAP_RESULT" | head -3 | sed 's/^/    /'

if (( CAP_RC == 0 )) && grep -qE '^ERROR:  53400:' <<<"$CAP_RESULT" \
        && ! grep -qE '^wins=' <<<"$CAP_RESULT"; then
    echo "  PASS: capacity error raised with SQLSTATE 53400"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "capacity_error_raised" "PASS" "sqlstate" "53400" "ERRCODE_CONFIGURATION_LIMIT_EXCEEDED")")
else
    echo "  FAIL: expected ERROR 53400 from try_many of 100 keys at max_claims=64" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "capacity_error_raised" "FAIL" "psql_rc" "$CAP_RC" "no SQLSTATE 53400")")
fi

DEBUG_CAP="$("$PGBIN/psql" -h "$CAP_DATA" -p "$CAP_PORT" \
    -U postgres -d postgres -X -A -t \
    -c "SELECT count(*) FROM xclaim.debug();" \
    2>/dev/null | tr -d ' ' || echo "-1")"
echo "  xclaim.debug() after rollback: $DEBUG_CAP"

if [[ "$DEBUG_CAP" == "0" ]]; then
    echo "  PASS: no leaked entries after catastrophic rollback"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "catastrophic_rollback_clean" "PASS" "debug_count" "0" "atomic rollback")")
else
    echo "  FAIL: $DEBUG_CAP entries leaked after rollback" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "catastrophic_rollback_clean" "FAIL" "debug_count" "$DEBUG_CAP" "leaked entries")")
fi

"$PGBIN/pg_ctl" stop -D "$CAP_DATA" -m immediate >/dev/null 2>&1 || true
rm -rf "$CAP_DATA"
# Remove from ALL_DATADIRS so cleanup_all doesn't re-process it
ALL_DATADIRS=("${ALL_DATADIRS[@]/$CAP_DATA}")

# ---------------------------------------------------------------------------
# Test 3: reentrant bulk (main cluster)
# ---------------------------------------------------------------------------
echo "--- Test 3: reentrant bulk (same session) ---"
REENTRANT_OUT="$(mktemp)"
XCLAIM_TMPFILES+=("$REENTRANT_OUT")
"$PGBIN/psql" -h "$MAIN_PGHOST" -p "$MAIN_PGPORT" \
    -U postgres -d postgres -X -A -t 2>/dev/null >"$REENTRANT_OUT" <<'SQLRE'
BEGIN;
SELECT count(v) FROM unnest(xclaim.try_many(2, ARRAY(SELECT generate_series(1,10)::int4))) v WHERE v;
SELECT count(v) FROM unnest(xclaim.try_many(2, ARRAY(SELECT generate_series(1,10)::int4))) v WHERE v;
SELECT count(*) FROM xclaim.debug() WHERE scope = 2;
ROLLBACK;
SQLRE

COUNTS=( $(grep -E '^[0-9]+$' "$REENTRANT_OUT" | head -3) )
FIRST_COUNT="${COUNTS[0]:-0}"
REENTRANT_COUNT="${COUNTS[1]:-0}"
DEBUG_COUNT="${COUNTS[2]:-0}"
rm -f "$REENTRANT_OUT"

echo "  First try_many (10 new keys): $FIRST_COUNT"
echo "  Second try_many (same 10 keys, reentrant): $REENTRANT_COUNT"
echo "  debug() entries for scope=2: $DEBUG_COUNT"

if [[ "$FIRST_COUNT" == "10" ]] && [[ "$REENTRANT_COUNT" == "10" ]] && [[ "$DEBUG_COUNT" == "10" ]]; then
    echo "  PASS: reentrant bulk: all true, no double entries"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "reentrant_bulk" "PASS" "debug_entries" "10" "no double-counting")")
else
    echo "  FAIL: first=$FIRST_COUNT re=$REENTRANT_COUNT debug=$DEBUG_COUNT (expected 10,10,10)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "reentrant_bulk" "FAIL" "debug_entries" "$DEBUG_COUNT" "mismatch")")
fi

# Server log check on main cluster only
PGDATA="$MAIN_PGDATA"
xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
