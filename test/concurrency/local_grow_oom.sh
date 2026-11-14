#!/usr/bin/env bash
# test/concurrency/local_grow_oom.sh
# An out-of-memory ERROR while the backend-local claim set grows leaves the
# set usable.
#
# A growth of the set allocates a bucket array twice the size of the current
# one. PostgreSQL 16's simplehash raises the size and the mask of the table
# before that allocation, and the long-probe path of every version zeroes the
# grow threshold before it grows. pg_xclaim allocates the bucket arrays itself
# and, when an allocation fails, puts back the size, mask and grow threshold
# of the array the set still uses. The test caps the address space of one
# backend with prlimit and makes an allocation of the set fail:
#   Test 1: the ERROR aborts the transaction cleanly. The backend and the
#           server survive, no claim stays behind in shared memory, and the
#           set serves new claims.
#   Test 2: a plpgsql EXCEPTION block catches the ERROR. The claims taken
#           before it stay held and reachable (a held key re-enters), the end
#           of the transaction releases them, and the next transaction takes
#           and releases a new claim.
#   Test 3: one insert grows the set twice, and the second growth fails. The
#           first growth replaced the bucket array, so the set has to come
#           back to the grown array, not to the one the insert started with.
#           The insert comes from xclaim.try_many, which inserts under the
#           partition LWLock, so the ERROR reaches its PG_CATCH with the lock
#           held. Afterwards statement_timeout still cancels a statement of
#           the same session: the handler restored the interrupt holdoff
#           count before it released the lock.
#   Test 4: the first bucket array of a session does not fit. Every failed
#           attempt leaves no memory context behind, and the first claim
#           after the cap is lifted creates the set.
#   Test 5: exit_on_error = on turns the ERROR into FATAL, which skips every
#           PG_CATCH. The cleanup at backend exit walks the set, so the set
#           has to be back at the geometry of its array before the ERROR is
#           raised (PostgreSQL 16 sets the doubled geometry before the
#           allocation). The server survives the exit, and no claim of the
#           session stays in shared memory.
# The cluster runs with restart_after_crash = off, so a crashed backend
# stops the server instead of hiding in a crash restart.
#
# Linux only: it needs prlimit and /proc. Elsewhere, and when prlimit cannot
# cap the backend, it exits with 77, which run_concurrency_suite.sh reports as
# skipped.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="local_grow_oom"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

xclaim_banner "$SCRIPT"

if [[ "$(uname -s)" != "Linux" ]] || ! command -v prlimit >/dev/null 2>&1; then
    echo "  SKIP: needs Linux with prlimit to cap the address space of one backend"
    exit 77
fi

trap pg_xclaim_stop_temp_cluster EXIT INT TERM
XCLAIM_MAX_CLAIMS=2097152
# 100000 expected claims give every session a first bucket array of 2^17
# entries (100000 / 0.9 rounded up to a power of two). Test 3 relies on it.
XCLAIM_EXTRA_CONF="restart_after_crash = off
pg_xclaim.expected_claims_per_backend = 100000"
pg_xclaim_start_temp_cluster "grow_oom"

PASS=0
FAIL=0
CSV_ROWS=()

q() { pg_xclaim_psql -X -A -t -q -c "$1"; }

pass() {  # test, metric, value, notes
    echo "  PASS: $4"
    PASS=$(( PASS + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$1" "PASS" "$2" "$3" "$4")")
}
fail() {  # test, metric, value, notes
    echo "  FAIL: $4 (got $3)" >&2
    FAIL=$(( FAIL + 1 ))
    CSV_ROWS+=("$(xclaim_csv_row "$SCRIPT" "$1" "FAIL" "$2" "$3" "$4")")
}

server_alive() {
    "$PGBIN/pg_isready" -h "$PGHOST" -p "$PGPORT" -U postgres -d postgres -q
}
server_down() {  # test
    fail "$1" "server" "down" "the server stopped: a backend crashed, and restart_after_crash is off"
    tail -n 30 "$PGDATA/server.log" 2>/dev/null | sed 's/^/    /' >&2 || true
}

# Tests 1 and 2 leave 64 MB above what the backend maps once its local set
# exists. With the 48-byte entries of 64-bit platforms the growth from 2^19
# to 2^20 entries needs more than that, with smaller entries a later growth
# does. Only an allocation of at least 1 MB in the local set counts as a
# growth: a smaller failed request means the cap hit something else.
MARGIN_KB=$(( 64 * 1024 ))
MIN_GROWTH_BYTES=1048576

# Opens a session, creates its local set, caps its address space at $1 kB
# above what the backend maps and sends the SQL in $2 followed by a 'done'
# marker. Output lands in $XCLAIM_HOLDER_OUT. Returns 77 when prlimit cannot
# set the cap.
capped_session() {
    local margin_kb="$1" sql="$2" pid vm_kb i
    xclaim_holder_open
    xclaim_holder_sql "SET lc_messages = 'C';"
    xclaim_holder_sql "SELECT 'init=' || xclaim.try(0::bigint);"
    xclaim_holder_sql "SELECT 'pid=' || pg_backend_pid();"
    if ! xclaim_holder_wait '^pid='; then
        return 1
    fi
    pid="$(sed -n 's/^pid=//p' "$XCLAIM_HOLDER_OUT")"
    vm_kb="$(awk '/^VmSize:/ {print $2}' "/proc/$pid/status")"
    if ! prlimit --pid "$pid" --as=$(( (vm_kb + margin_kb) * 1024 )); then
        echo "  SKIP: prlimit cannot cap the address space of backend $pid"
        return 77
    fi
    echo "  backend $pid: VmSize ${vm_kb} kB, address space capped at +${margin_kb} kB"
    xclaim_holder_sql "$sql"
    xclaim_holder_sql "SELECT 'done';"
    # Growing the set to half a million entries takes a few seconds. A
    # session that ends on FATAL closes psql before the marker.
    for i in $(seq 1 600); do
        grep -q '^done$' "$XCLAIM_HOLDER_OUT" 2>/dev/null && return 0
        kill -0 "$XCLAIM_HOLDER_JOB" 2>/dev/null || return 2
        server_alive || return 1
        sleep 0.1
    done
    return 1
}

# Runs capped_session, closes the session and prints its output. A session
# that cannot be capped skips the whole script.
run_capped() {  # margin_kb, sql
    local rc=0
    capped_session "$1" "$2" || rc=$?
    xclaim_holder_close
    if (( rc == 77 )); then
        exit 77
    fi
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" | grep -v -E '^    (init|pid)=' | head -14
}

# Prints the size of the failed request from the out-of-memory DETAIL line,
# when the request was for the local set.
failed_request_size() {
    sed -n 's/.*Failed on request of size \([0-9][0-9]*\) in memory context "xclaim local set".*/\1/p' "$XCLAIM_HOLDER_OUT" | head -1
}

GROW_LOOP="FOR i IN 1..2000000 LOOP PERFORM xclaim.try(i::bigint); END LOOP;"

# ---------------------------------------------------------------------------
# Test 1: the ERROR aborts the transaction
# ---------------------------------------------------------------------------
echo "--- Test 1: out of memory while growing aborts the transaction cleanly ---"

run_capped "$MARGIN_KB" "DO \$\$ BEGIN $GROW_LOOP END \$\$;
SELECT 'count=' || xclaim.count();
BEGIN;
SELECT 'retry=' || xclaim.try(42::bigint);
SELECT 'held=' || xclaim.count();
COMMIT;
SELECT 'after=' || xclaim.count();"

SIZE="$(failed_request_size)"
if ! server_alive; then
    server_down "abort_after_oom"
elif [[ -z "$SIZE" ]] || (( SIZE < MIN_GROWTH_BYTES )); then
    fail "abort_after_oom" "request_size" "${SIZE:-none}" "an allocation of at least $MIN_GROWTH_BYTES bytes in the local set must fail while the set grows"
else
    COUNT="$(sed -n 's/^count=//p' "$XCLAIM_HOLDER_OUT")"
    RETRY="$(sed -n 's/^retry=//p' "$XCLAIM_HOLDER_OUT")"
    HELD="$(sed -n 's/^held=//p' "$XCLAIM_HOLDER_OUT")"
    AFTER="$(sed -n 's/^after=//p' "$XCLAIM_HOLDER_OUT")"
    ROWS="$(q "SELECT count(*) FROM xclaim.debug_snapshot();")"
    echo "  failed request: $SIZE bytes, count after abort: $COUNT, retry: $RETRY, held: $HELD, after COMMIT: $AFTER, shared rows: $ROWS"
    if [[ "$COUNT" == "0" && "$RETRY" == "true" && "$HELD" == "1" && "$AFTER" == "0" && "$ROWS" == "0" ]]; then
        pass "abort_after_oom" "request_size" "$SIZE" "the abort released every claim and the set serves new claims"
    else
        fail "abort_after_oom" "state" "count=$COUNT retry=$RETRY held=$HELD after=$AFTER rows=$ROWS" "the abort must release every claim and the set must serve new claims"
    fi
fi

# ---------------------------------------------------------------------------
# Test 2: a plpgsql EXCEPTION block catches the ERROR
# ---------------------------------------------------------------------------
echo "--- Test 2: out of memory caught by an EXCEPTION block keeps the set usable ---"

if ! server_alive; then
    server_down "caught_oom"
else
    run_capped "$MARGIN_KB" "DO \$\$
DECLARE
    err_detail text;
BEGIN
    BEGIN
        $GROW_LOOP
    EXCEPTION WHEN out_of_memory THEN
        GET STACKED DIAGNOSTICS err_detail = PG_EXCEPTION_DETAIL;
        RAISE NOTICE 'caught=%', SQLERRM;
        RAISE NOTICE 'detail=%', err_detail;
    END;
    RAISE NOTICE 'reenter=%', xclaim.try(1::bigint);
    RAISE NOTICE 'held=%', xclaim.count();
END \$\$;
SELECT 'after=' || xclaim.count();
BEGIN;
SELECT 'fresh=' || xclaim.try(2000001::bigint);
SELECT 'fresh_held=' || xclaim.count();
COMMIT;
SELECT 'fresh_after=' || xclaim.count();"

    if ! server_alive; then
        server_down "caught_oom"
    else
        CAUGHT="$(sed -n 's/^NOTICE: *caught=//p' "$XCLAIM_HOLDER_OUT")"
        SIZE="$(failed_request_size)"
        REENTER="$(sed -n 's/^NOTICE: *reenter=//p' "$XCLAIM_HOLDER_OUT")"
        HELD="$(sed -n 's/^NOTICE: *held=//p' "$XCLAIM_HOLDER_OUT")"
        AFTER="$(sed -n 's/^after=//p' "$XCLAIM_HOLDER_OUT")"
        FRESH="$(sed -n 's/^fresh=//p' "$XCLAIM_HOLDER_OUT")"
        FRESH_HELD="$(sed -n 's/^fresh_held=//p' "$XCLAIM_HOLDER_OUT")"
        FRESH_AFTER="$(sed -n 's/^fresh_after=//p' "$XCLAIM_HOLDER_OUT")"
        ROWS="$(q "SELECT count(*) FROM xclaim.debug_snapshot();")"
        echo "  caught: $CAUGHT, failed request: ${SIZE:-none} bytes, reenter: $REENTER, held: $HELD, after: $AFTER, next transaction: $FRESH held $FRESH_HELD after $FRESH_AFTER, shared rows: $ROWS"
        if [[ "$CAUGHT" == "out of memory" && -n "$SIZE" && "$REENTER" == "t" && "${HELD:-0}" -gt 1 && "$AFTER" == "0" \
              && "$FRESH" == "true" && "$FRESH_HELD" == "1" && "$FRESH_AFTER" == "0" && "$ROWS" == "0" ]]; then
            pass "caught_oom" "held" "$HELD" "the held claims stay reachable, the transaction end releases them and the next transaction takes a new claim"
        else
            fail "caught_oom" "state" "caught=$CAUGHT size=${SIZE:-none} reenter=$REENTER held=$HELD after=$AFTER fresh=$FRESH/$FRESH_HELD/$FRESH_AFTER rows=$ROWS" "the held claims must stay reachable, be released at the transaction end, and the next transaction must take a new claim"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Test 3: the second growth of one insert fails
# ---------------------------------------------------------------------------
echo "--- Test 3: an insert that grows twice and fails the second growth keeps the set usable ---"

# The set hashes a key as hash_bytes() over its 16-byte image in native byte
# order: the database OID and the form (1 for an int8 key) as int4, then the
# key as int8. uuid_hash() is hash_bytes() over the 16 bytes of a uuid, so the
# image written as a uuid has the same hash. A candidate j gives the key bytes
# as its big-endian hex, and K_OF_J reads them back as the int8 that
# xclaim.try receives.
#
# 27 colliders share bucket 0 of the 2^18 array and so of the 2^17 array.
# 26 of them fill buckets 0..25, and the 27th probes past the long-probe limit
# (25) in both arrays: it grows the set from 2^17 to 2^18 entries, and then
# from 2^18 to 2^19. 30000 fillers lie outside buckets -64..63 of both arrays
# and keep the fill at or above 0.1, the minimum for a long-probe growth, in
# the 2^18 array. The cap is 20 MB. With 48-byte entries the first growth
# needs 12 MB, the second 24 MB while the 12 MB array is still in use.
if [[ "$(printf '\001\000' | od -An -tu2 | tr -d ' ')" == "1" ]]; then
    PREFIX="$(q "SELECT lpad(to_hex(((oid::bigint & 255) << 24) | (((oid::bigint >> 8) & 255) << 16)
                         | (((oid::bigint >> 16) & 255) << 8) | ((oid::bigint >> 24) & 255)), 8, '0') || '01000000'
                 FROM pg_database WHERE datname = current_database();")"
    K_OF_J="('x' || regexp_replace(lpad(to_hex(j), 16, '0'), '(..)(..)(..)(..)(..)(..)(..)(..)', '\\8\\7\\6\\5\\4\\3\\2\\1'))::bit(64)::bigint"
else
    PREFIX="$(q "SELECT lpad(to_hex(oid::bigint), 8, '0') || '00000001' FROM pg_database WHERE datname = current_database();")"
    K_OF_J="j"
fi
HASH_OF_J="uuid_hash(('$PREFIX' || lpad(to_hex(j), 16, '0'))::uuid)"
q "CREATE TABLE grow_keys (role text NOT NULL, k bigint NOT NULL);"
q "INSERT INTO grow_keys
   SELECT 'collider', $K_OF_J FROM (SELECT generate_series(1::bigint, 1000000000::bigint) AS j) s
   WHERE ($HASH_OF_J & 262143) = 0 LIMIT 27;"
q "INSERT INTO grow_keys
   SELECT 'filler', $K_OF_J FROM (SELECT generate_series(1::bigint, 1000000::bigint) AS j) s
   WHERE ($HASH_OF_J & 131071) BETWEEN 64 AND 131007 LIMIT 30000;"
q "INSERT INTO grow_keys
   SELECT 'fresh', $K_OF_J FROM (SELECT generate_series(2000001::bigint, 3000000::bigint) AS j) s
   WHERE ($HASH_OF_J & 131071) BETWEEN 64 AND 131007 LIMIT 2;"
KEYS="$(q "SELECT count(*) FILTER (WHERE role = 'collider') || '/' || count(*) FILTER (WHERE role = 'filler')
           || '/' || count(*) FILTER (WHERE role = 'fresh') || '/' || count(DISTINCT k) FROM grow_keys;")"

if [[ "$KEYS" != "27/30000/2/30029" ]]; then
    fail "second_growth_oom" "keys" "$KEYS" "27 colliders, 30000 fillers and 2 fresh keys, all distinct"
elif ! server_alive; then
    server_down "second_growth_oom"
else
    run_capped $(( 20 * 1024 )) "DO \$\$
DECLARE
    r record;
    err_detail text;
BEGIN
    FOR r IN SELECT k FROM grow_keys WHERE role = 'collider' ORDER BY k OFFSET 1 LOOP
        PERFORM xclaim.try(r.k);
    END LOOP;
    FOR r IN SELECT k FROM grow_keys WHERE role = 'filler' LOOP
        PERFORM xclaim.try(r.k);
    END LOOP;
    RAISE NOTICE 'before_bytes=%', (SELECT total_bytes FROM pg_backend_memory_contexts WHERE name = 'xclaim local set');
    BEGIN
        PERFORM xclaim.try_many(ARRAY[(SELECT k FROM grow_keys WHERE role = 'collider' ORDER BY k LIMIT 1)]);
        RAISE NOTICE 'trigger=inserted';
    EXCEPTION WHEN out_of_memory THEN
        GET STACKED DIAGNOSTICS err_detail = PG_EXCEPTION_DETAIL;
        RAISE NOTICE 'detail=%', err_detail;
    END;
    RAISE NOTICE 'after_bytes=%', (SELECT total_bytes FROM pg_backend_memory_contexts WHERE name = 'xclaim local set');
    RAISE NOTICE 'reenter=%', xclaim.try((SELECT k FROM grow_keys WHERE role = 'collider' ORDER BY k OFFSET 1 LIMIT 1));
    RAISE NOTICE 'fresh=%', xclaim.try((SELECT k FROM grow_keys WHERE role = 'fresh' ORDER BY k LIMIT 1));
    RAISE NOTICE 'held=%', xclaim.count();
END \$\$;
SELECT 'after=' || xclaim.count();
BEGIN;
SELECT 'fresh2=' || xclaim.try((SELECT k FROM grow_keys WHERE role = 'fresh' ORDER BY k OFFSET 1 LIMIT 1));
SELECT 'held2=' || xclaim.count();
COMMIT;
SELECT 'after2=' || xclaim.count();
SET statement_timeout = '300ms';
SELECT 'sleep=' || pg_sleep(3);
RESET statement_timeout;"

    if ! server_alive; then
        server_down "second_growth_oom"
    else
        BEFORE_BYTES="$(sed -n 's/^NOTICE: *before_bytes=//p' "$XCLAIM_HOLDER_OUT")"
        SIZE="$(failed_request_size)"
        AFTER_BYTES="$(sed -n 's/^NOTICE: *after_bytes=//p' "$XCLAIM_HOLDER_OUT")"
        REENTER="$(sed -n 's/^NOTICE: *reenter=//p' "$XCLAIM_HOLDER_OUT")"
        FRESH="$(sed -n 's/^NOTICE: *fresh=//p' "$XCLAIM_HOLDER_OUT")"
        HELD="$(sed -n 's/^NOTICE: *held=//p' "$XCLAIM_HOLDER_OUT")"
        AFTER="$(sed -n 's/^after=//p' "$XCLAIM_HOLDER_OUT")"
        FRESH2="$(sed -n 's/^fresh2=//p' "$XCLAIM_HOLDER_OUT")"
        HELD2="$(sed -n 's/^held2=//p' "$XCLAIM_HOLDER_OUT")"
        AFTER2="$(sed -n 's/^after2=//p' "$XCLAIM_HOLDER_OUT")"
        TIMEOUT_OK="$(grep -c 'canceling statement due to statement timeout' "$XCLAIM_HOLDER_OUT" || true)"
        SLEPT="$(grep -c '^sleep=' "$XCLAIM_HOLDER_OUT" || true)"
        ROWS="$(q "SELECT count(*) FROM xclaim.debug_snapshot();")"
        # The context holds the 2^17 array and less than one entry per
        # bucket of small blocks, so its size gives the entry size.
        ENTRY_BYTES=$(( ${BEFORE_BYTES:-0} / 131072 ))
        GROWN_BYTES=$(( 262144 * ENTRY_BYTES ))
        SECOND_GROWTH_BYTES=$(( 524288 * ENTRY_BYTES ))
        echo "  set bytes before: ${BEFORE_BYTES:-none} (entry $ENTRY_BYTES bytes), failed request: ${SIZE:-none} bytes, set bytes after: ${AFTER_BYTES:-none}"
        echo "  reenter: $REENTER, fresh: $FRESH, held: $HELD, after: $AFTER, next transaction: $FRESH2 held $HELD2 after $AFTER2, shared rows: $ROWS"
        echo "  statement_timeout after the error: cancelled $TIMEOUT_OK, pg_sleep finished $SLEPT"
        if [[ -z "$BEFORE_BYTES" || -z "$AFTER_BYTES" ]] || (( ENTRY_BYTES < 16 )); then
            fail "second_growth_oom" "set_bytes" "before=${BEFORE_BYTES:-none}" "the set must start from the 2^17 array"
        elif [[ "$SIZE" != "$SECOND_GROWTH_BYTES" ]] || (( AFTER_BYTES < GROWN_BYTES || AFTER_BYTES >= SECOND_GROWTH_BYTES )); then
            fail "second_growth_oom" "request_size" "size=${SIZE:-none} after=$AFTER_BYTES" "the first growth must succeed and the second ($SECOND_GROWTH_BYTES bytes) must fail"
        elif [[ "$REENTER" == "t" && "$FRESH" == "t" && "$HELD" == "30027" && "$AFTER" == "0" \
                && "$FRESH2" == "true" && "$HELD2" == "1" && "$AFTER2" == "0" && "$ROWS" == "0" \
                && "$TIMEOUT_OK" == "1" && "$SLEPT" == "0" ]]; then
            pass "second_growth_oom" "request_size" "$SIZE" "the set stays usable after the second growth of one insert fails, and statement_timeout still cancels"
        else
            fail "second_growth_oom" "state" "reenter=$REENTER fresh=$FRESH held=$HELD after=$AFTER next=$FRESH2/$HELD2/$AFTER2 rows=$ROWS timeout=$TIMEOUT_OK slept=$SLEPT" "the set must serve lookups and new claims after the second growth fails, the transaction ends must release everything, and statement_timeout must still cancel"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Test 4: the first bucket array of a session does not fit
# ---------------------------------------------------------------------------
echo "--- Test 4: a failed creation of the local set leaves nothing behind ---"

# The first array has 2^17 entries (6 MB with 48-byte entries), and the cap
# leaves 2 MB. Only the soft limit is lowered, and the test puts the original
# soft limit back afterwards. Every failure has to be the request for that
# array in the local set's context: an earlier out-of-memory would fail
# before the context exists, and the count would prove nothing.
if ! server_alive; then
    server_down "create_oom"
else
    xclaim_holder_open
    xclaim_holder_sql "SET lc_messages = 'C';"
    xclaim_holder_sql "SELECT 'pid=' || pg_backend_pid();"
    if ! xclaim_holder_wait '^pid='; then
        fail "create_oom" "session" "none" "the session must start"
    else
        PID="$(sed -n 's/^pid=//p' "$XCLAIM_HOLDER_OUT")"
        VM_KB="$(awk '/^VmSize:/ {print $2}' "/proc/$PID/status")"
        SOFT_AS="$(prlimit --pid "$PID" --as --noheadings --output SOFT | tr -d ' ')"
        if [[ -z "$SOFT_AS" ]] || ! prlimit --pid "$PID" --as=$(( (VM_KB + 2048) * 1024 )):; then
            echo "  SKIP: prlimit cannot cap the address space of backend $PID"
            xclaim_holder_close
            exit 77
        fi
        echo "  backend $PID: VmSize ${VM_KB} kB, soft address space limit at +2048 kB"
        for i in 1 2 3; do
            xclaim_holder_sql "SELECT 'attempt$i=' || xclaim.try(1::bigint);"
        done
        xclaim_holder_sql "SELECT 'contexts=' || count(*) FROM pg_backend_memory_contexts WHERE name = 'xclaim local set';"
        xclaim_holder_wait '^contexts=' || true
        if ! prlimit --pid "$PID" --as="$SOFT_AS":; then
            echo "  SKIP: prlimit cannot restore the soft address space limit ($SOFT_AS) of backend $PID"
            xclaim_holder_close
            exit 77
        fi
        xclaim_holder_sql "SELECT 'retry=' || xclaim.try(1::bigint);"
        xclaim_holder_sql "SELECT 'contexts2=' || count(*) FROM pg_backend_memory_contexts WHERE name = 'xclaim local set';"
        xclaim_holder_wait '^contexts2=' || true
        xclaim_holder_close
        sed 's/^/    /' "$XCLAIM_HOLDER_OUT" | grep -v -E '^    pid=' | head -12

        if ! server_alive; then
            server_down "create_oom"
        else
            FAILED="$(grep -c '^ERROR:  out of memory' "$XCLAIM_HOLDER_OUT" || true)"
            ARRAY_FAILED="$(sed -n 's/.*Failed on request of size \([0-9][0-9]*\) in memory context "xclaim local set".*/\1/p' "$XCLAIM_HOLDER_OUT" \
                            | awk -v min="$MIN_GROWTH_BYTES" '$1 >= min' | wc -l | tr -d ' ')"
            CONTEXTS="$(sed -n 's/^contexts=//p' "$XCLAIM_HOLDER_OUT")"
            RETRY="$(sed -n 's/^retry=//p' "$XCLAIM_HOLDER_OUT")"
            CONTEXTS2="$(sed -n 's/^contexts2=//p' "$XCLAIM_HOLDER_OUT")"
            echo "  failed attempts: $FAILED ($ARRAY_FAILED on the first array), contexts after them: $CONTEXTS, claim after the cap is lifted: $RETRY, contexts then: $CONTEXTS2"
            if [[ "$FAILED" == "3" && "$ARRAY_FAILED" == "3" && "$CONTEXTS" == "0" && "$RETRY" == "true" && "$CONTEXTS2" == "1" ]]; then
                pass "create_oom" "contexts" "$CONTEXTS" "failed creations leave no context and the next claim creates the set"
            else
                fail "create_oom" "state" "failed=$FAILED array=$ARRAY_FAILED contexts=$CONTEXTS retry=$RETRY contexts2=$CONTEXTS2" "every creation must fail on the first array and drop its context, and the claim after the cap is lifted must create the set"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Test 5: the ERROR turns into FATAL
# ---------------------------------------------------------------------------
echo "--- Test 5: out of memory while growing with exit_on_error = on ---"

if ! server_alive; then
    server_down "fatal_oom"
else
    MISSES_BEFORE="$(q "SELECT cleanup_misses FROM xclaim.stats();")"
    run_capped "$MARGIN_KB" "SET exit_on_error = on;
DO \$\$ BEGIN $GROW_LOOP END \$\$;"
    # The exit callbacks have run once the backend process is gone.
    FATAL_PID="$(sed -n 's/^pid=//p' "$XCLAIM_HOLDER_OUT")"
    GONE=no
    if [[ -n "$FATAL_PID" ]] && xclaim_wait_backend_gone "$FATAL_PID"; then
        GONE=yes
    fi
    if ! server_alive; then
        server_down "fatal_oom"
    elif [[ "$GONE" != "yes" ]]; then
        fail "fatal_oom" "backend" "${FATAL_PID:-none}" "the backend of the session must exit after the FATAL"
    else
        SIZE="$(failed_request_size)"
        FATAL_SEEN="$(grep -c '^FATAL:  out of memory' "$XCLAIM_HOLDER_OUT" || true)"
        STATE="$(q "SELECT (SELECT count(*) FROM xclaim.debug_snapshot()) || '/' || capacity_used || '/' || (cleanup_misses - ${MISSES_BEFORE:-0}) FROM xclaim.stats();")"
        echo "  FATAL lines: $FATAL_SEEN, failed request: ${SIZE:-none} bytes, shared rows/capacity_used/new cleanup_misses after the exit: $STATE"
        if [[ "$FATAL_SEEN" == "1" && -n "$SIZE" ]] && (( SIZE >= MIN_GROWTH_BYTES )) && [[ "$STATE" == "0/0/0" ]]; then
            pass "fatal_oom" "rows" "0" "the backend exits on FATAL during a growth, the server survives and no claim stays behind"
        else
            fail "fatal_oom" "state" "fatal=$FATAL_SEEN size=${SIZE:-none} state=$STATE" "a growth must fail with FATAL, the server must survive and the exit must release every claim"
        fi
    fi
fi

xclaim_check_server_log "$SCRIPT" "out of memory|Failed on request" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
