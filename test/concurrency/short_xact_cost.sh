#!/usr/bin/env bash
# test/concurrency/short_xact_cost.sh
# The end of a transaction that took a few claims costs the same whatever
# the size of the backend's local set, and a set enlarged by one large
# transaction goes back to its first size.
#
# Why. The bucket array of the local set is sized by
# pg_xclaim.expected_claims_per_backend and grows with the largest
# transaction the backend has run. Cleanup of a transaction with a few
# claims looks its keys up in the held-key list and deletes them one by
# one, instead of walking and zeroing the whole array, which would cost a
# 750k-claim transaction's worth on every commit. After 64 such cleanups
# an enlarged set shrinks back, and xclaim.session_reset() shrinks it at
# once.
#
# Workloads. Each one runs in a procedure that commits per iteration and
# raises an error when a transaction does not take every claim it asks for.
#   one-claim:  5000 transactions with one xclaim.try each
#   2000-claim: 300 transactions with one xclaim.try_many of 2000 keys each
#
#   Test 1: one backend, default expected_claims_per_backend. Both workloads
#           before and after one transaction that takes 750,000 claims, which
#           must hold exactly 750,000 claims in the local set and in shared
#           memory. After / before <= 3 for each workload. The local set
#           context holds more than 40 MB right after the large transaction
#           and less than 8 MB after the one-claim workload, and again after
#           a second large transaction and xclaim.session_reset(). A set of
#           exactly 4 times its first size (80,000 xclaim.try claims: 131,072
#           buckets, about 6.3 MB) also shrinks below 3 MB after 100 one-claim
#           transactions. After a third large transaction, 100 transactions
#           of one xclaim.try_many over 30,000 keys another session holds
#           plus one new key (one claim each) shrink the set below 8 MB: a
#           call of that size needs a 65,536-bucket set, not the 1M-bucket
#           one, and the shrink happens before the call's first partition
#           LWLock.
#   Test 2: expected_claims_per_backend = 750000 (a 1M-bucket set from the
#           first claim, which never shrinks). Both workloads cost <= 3x the
#           default-set run of Test 1.
#   Test 3: expected_claims_per_backend = 750000. Transactions that take one
#           claim and then fail 17,000 times on a key another session holds:
#           the failed tries do not fill the 16,384-key held-key list, so
#           each COMMIT stays on the list path. 300 such COMMITs cost
#           <= 3x 300 COMMITs of one claim, plus 50 ms (a walk of the
#           1M-bucket array costs a millisecond or more per COMMIT).
#
# Every psql runs with ON_ERROR_STOP: an SQL error ends the test with FAIL.
# Timings come from clock_timestamp() inside the procedures. The ratios leave
# room for scheduling noise: a cleanup that walks the whole set is 30x or
# more slower after the large transaction.
# The 2000-claim workload records the minimum of three samples to reduce
# sensitivity to a scheduling pause in either side of a timing ratio.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="short_xact_cost"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

xclaim_banner "$SCRIPT"

trap pg_xclaim_stop_temp_cluster EXIT INT TERM

PASS=0
FAIL=0
CSV_ROWS=()
N=5000
N_MANY=300
K_MANY=2000
BULK=750000
MISSES=17000

q() { pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 -c "$1"; }

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

# Runs a psql script from stdin with ON_ERROR_STOP and keeps its output in
# SQL_OUT. An SQL error ends the test: the timings after it would describe
# transactions that did not take their claims.
run_sql() {  # label
    if ! SQL_OUT="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 2>&1)"; then
        echo "  FAIL: $1 stopped on an SQL error, output follows:" >&2
        printf '%s\n' "$SQL_OUT" | sed 's/^/    /' >&2
        echo "=== RESULT: PASS=$PASS FAIL=$(( FAIL + 1 )) ==="
        exit 1
    fi
}

# Within 3x of the reference, plus 50 ms of slack for scheduling noise.
within_3x() {  # value, reference
    [[ -n "$1" && -n "$2" ]] && (( $1 <= 3 * $2 + 50 ))
}

# Procedures: n transactions with one claim each, and n transactions with
# one try_many of k keys each. The elapsed time goes to timings(label). They
# run in the backend of the calling session. conflict_xacts(n, misses, ...)
# runs n transactions that take one claim and then try key 424242 `misses`
# times, which another session holds, and times only the COMMITs.
setup_sql() {
    run_sql "setup" <<'SQL'
CREATE TABLE timings (label text PRIMARY KEY, ms numeric);
CREATE PROCEDURE conflict_xacts(n int, misses int, label text) LANGUAGE plpgsql AS $$
DECLARE
    commit_ms numeric := 0;
    t0 timestamptz;
BEGIN
    FOR i IN 1..n LOOP
        IF NOT xclaim.try(3, i) THEN
            RAISE EXCEPTION 'xclaim.try(3, %) returned false', i;
        END IF;
        FOR j IN 1..misses LOOP
            IF xclaim.try(424242::int8) THEN
                RAISE EXCEPTION 'xclaim.try(424242) returned true, the holder must hold it';
            END IF;
        END LOOP;
        t0 := clock_timestamp();
        COMMIT;
        commit_ms := commit_ms + extract(epoch FROM clock_timestamp() - t0) * 1000;
    END LOOP;
    INSERT INTO timings VALUES (label, commit_ms);
    COMMIT;
END $$;
CREATE PROCEDURE one_claim_xacts(n int, label text) LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
    FOR i IN 1..n LOOP
        IF NOT xclaim.try(1, i) THEN
            RAISE EXCEPTION 'xclaim.try(1, %) returned false', i;
        END IF;
        COMMIT;
    END LOOP;
    INSERT INTO timings
    VALUES (label, extract(epoch FROM clock_timestamp() - t0) * 1000);
    COMMIT;
END $$;
CREATE PROCEDURE candidate_xacts(n int, held_from int8, held int) LANGUAGE plpgsql AS $$
DECLARE
    keys int8[];
    taken int;
BEGIN
    FOR i IN 1..n LOOP
        keys := ARRAY(SELECT g FROM generate_series(held_from, held_from + held - 1) g)
                || (held_from + held + i)::int8;
        SELECT count(*) INTO taken FROM unnest(xclaim.try_many(keys)) t WHERE t;
        IF taken <> 1 THEN
            RAISE EXCEPTION 'xclaim.try_many took % keys in transaction %, expected 1', taken, i;
        END IF;
        COMMIT;
    END LOOP;
END $$;
CREATE PROCEDURE many_claim_xacts(n int, k int, label text) LANGUAGE plpgsql AS $$
DECLARE
    keys int4[] := ARRAY(SELECT generate_series(1, k));
    taken int;
    t0 timestamptz;
    elapsed_ms numeric;
    best_ms numeric;
BEGIN
    FOR sample IN 1..3 LOOP
        t0 := clock_timestamp();
        FOR i IN 1..n LOOP
            SELECT count(*) INTO taken FROM unnest(xclaim.try_many(2, keys)) t WHERE t;
            IF taken <> k THEN
                RAISE EXCEPTION 'xclaim.try_many took % of % keys in transaction %', taken, k, i;
            END IF;
            COMMIT;
        END LOOP;
        elapsed_ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
        IF best_ms IS NULL OR elapsed_ms < best_ms THEN
            best_ms := elapsed_ms;
        END IF;
    END LOOP;
    INSERT INTO timings VALUES (label, best_ms);
    COMMIT;
END $$;
SQL
}

# ---------------------------------------------------------------------------
# Test 1: before and after a 750k-claim transaction in the same backend
# ---------------------------------------------------------------------------
echo "--- Test 1: both workloads before and after a $BULK-claim transaction ---"

XCLAIM_MAX_CLAIMS=2097152
pg_xclaim_start_temp_cluster "short_xact_default"
setup_sql

# Bytes of this backend's local set context.
LOCAL_SET_BYTES="SELECT total_bytes FROM pg_backend_memory_contexts WHERE name = 'xclaim local set'"

run_sql "Test 1" <<SQL
CALL one_claim_xacts($N, 'default_before');
CALL many_claim_xacts($N_MANY, $K_MANY, 'many_before');
BEGIN;
SELECT 'bulk=' || count(*) FROM unnest(xclaim.try_many(ARRAY(SELECT g::int8 FROM generate_series(1, $BULK) g))) t WHERE t;
SELECT 'local=' || xclaim.count();
SELECT 'shared=' || capacity_used FROM xclaim.stats();
COMMIT;
SELECT 'mem_large=' || ($LOCAL_SET_BYTES);
CALL one_claim_xacts($N, 'default_after');
SELECT 'mem_shrunk=' || ($LOCAL_SET_BYTES);
CALL many_claim_xacts($N_MANY, $K_MANY, 'many_after');
BEGIN;
SELECT 'bulk2=' || count(*) FROM unnest(xclaim.try_many(ARRAY(SELECT g::int8 FROM generate_series(1, $BULK) g))) t WHERE t;
COMMIT;
SELECT 'mem_large2=' || ($LOCAL_SET_BYTES);
SELECT xclaim.session_reset();
SELECT 'mem_reset=' || ($LOCAL_SET_BYTES);
BEGIN;
SELECT 'scalar4x=' || count(*) FROM generate_series(10000001, 10080000) g WHERE xclaim.try(g::int8);
COMMIT;
SELECT 'mem_4x=' || ($LOCAL_SET_BYTES);
CALL one_claim_xacts(100, 'four_x');
SELECT 'mem_4x_shrunk=' || ($LOCAL_SET_BYTES);
SQL

TAKEN="$(sed -n 's/^bulk=//p' <<<"$SQL_OUT")"
LOCAL="$(sed -n 's/^local=//p' <<<"$SQL_OUT")"
SHARED="$(sed -n 's/^shared=//p' <<<"$SQL_OUT")"
echo "  large transaction: try_many took ${TAKEN:-none}, local set ${LOCAL:-none}, shared ${SHARED:-none}"
if [[ "$TAKEN" == "$BULK" && "$LOCAL" == "$BULK" && "$SHARED" == "$BULK" ]]; then
    pass "large_xact" "claims" "$TAKEN" "the large transaction holds $BULK claims, local and shared"
else
    fail "large_xact" "claims" "${TAKEN:-none}/${LOCAL:-none}/${SHARED:-none}" "the large transaction must hold $BULK claims (try_many/local/shared)"
fi

MB=1048576
MEM_LARGE="$(sed -n 's/^mem_large=//p' <<<"$SQL_OUT")"
MEM_SHRUNK="$(sed -n 's/^mem_shrunk=//p' <<<"$SQL_OUT")"
MEM_LARGE2="$(sed -n 's/^mem_large2=//p' <<<"$SQL_OUT")"
MEM_RESET="$(sed -n 's/^mem_reset=//p' <<<"$SQL_OUT")"
echo "  local set context: ${MEM_LARGE:-none} bytes after the large transaction, ${MEM_SHRUNK:-none} after $N one-claim transactions"
echo "  local set context: ${MEM_LARGE2:-none} bytes after a second large transaction, ${MEM_RESET:-none} after xclaim.session_reset()"
if [[ -n "$MEM_LARGE" && -n "$MEM_SHRUNK" ]] && (( MEM_LARGE > 40 * MB && MEM_SHRUNK < 8 * MB )); then
    pass "shrink_after_small" "bytes" "$MEM_SHRUNK" "the enlarged set shrinks after the small transactions"
else
    fail "shrink_after_small" "bytes" "${MEM_LARGE:-none}/${MEM_SHRUNK:-none}" "the set must hold > 40 MB after the large transaction and < 8 MB after the small ones"
fi
if [[ -n "$MEM_LARGE2" && -n "$MEM_RESET" ]] && (( MEM_LARGE2 > 40 * MB && MEM_RESET < 8 * MB )); then
    pass "shrink_on_reset" "bytes" "$MEM_RESET" "xclaim.session_reset() shrinks the enlarged set"
else
    fail "shrink_on_reset" "bytes" "${MEM_LARGE2:-none}/${MEM_RESET:-none}" "the set must hold > 40 MB after the large transaction and < 8 MB after session_reset"
fi
TAKEN2="$(sed -n 's/^bulk2=//p' <<<"$SQL_OUT")"
if [[ "$TAKEN2" == "$BULK" ]]; then
    pass "large_xact_after_shrink" "claims" "$TAKEN2" "the large transaction after the shrink takes $BULK claims"
else
    fail "large_xact_after_shrink" "claims" "${TAKEN2:-none}" "the large transaction after the shrink must take $BULK claims"
fi
SCALAR4X="$(sed -n 's/^scalar4x=//p' <<<"$SQL_OUT")"
MEM_4X="$(sed -n 's/^mem_4x=//p' <<<"$SQL_OUT")"
MEM_4X_SHRUNK="$(sed -n 's/^mem_4x_shrunk=//p' <<<"$SQL_OUT")"
echo "  local set context: ${MEM_4X:-none} bytes after ${SCALAR4X:-none} xclaim.try claims (4x set), ${MEM_4X_SHRUNK:-none} after 100 one-claim transactions"
if [[ "$SCALAR4X" == "80000" && -n "$MEM_4X" && -n "$MEM_4X_SHRUNK" ]] &&
   (( MEM_4X > 5 * MB && MEM_4X < 10 * MB && MEM_4X_SHRUNK < 3 * MB )); then
    pass "shrink_at_4x" "bytes" "$MEM_4X_SHRUNK" "a set of exactly 4 times its first size shrinks"
else
    fail "shrink_at_4x" "bytes" "${SCALAR4X:-none}/${MEM_4X:-none}/${MEM_4X_SHRUNK:-none}" "80000 claims must make a 5-10 MB set that shrinks below 3 MB"
fi

# A backend that runs xclaim.try_many over long candidate lists after a large
# transaction. The holder keeps the 30,000 candidates, so each call takes
# only its one new key.
HELD_FROM=20000001
HELD=30000
xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'held=' || count(*) FROM unnest(xclaim.try_many(ARRAY(SELECT g FROM generate_series($HELD_FROM::int8, $HELD_FROM + $HELD - 1) g))) t WHERE t;"
if ! xclaim_holder_wait "^held=$HELD\$"; then
    echo "  FAIL: the holder did not take $HELD keys, output follows:" >&2
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
    FAIL=$((FAIL+1))
fi
run_sql "Test 1 candidates" <<SQL
BEGIN;
SELECT 'bulk3=' || count(*) FROM unnest(xclaim.try_many(ARRAY(SELECT g::int8 FROM generate_series(1, $BULK) g))) t WHERE t;
COMMIT;
SELECT 'mem_large3=' || ($LOCAL_SET_BYTES);
CALL candidate_xacts(100, $HELD_FROM, $HELD);
SELECT 'mem_candidates=' || ($LOCAL_SET_BYTES);
SQL
xclaim_holder_sql "ROLLBACK;"
xclaim_holder_close
MEM_LARGE3="$(sed -n 's/^mem_large3=//p' <<<"$SQL_OUT")"
MEM_CAND="$(sed -n 's/^mem_candidates=//p' <<<"$SQL_OUT")"
echo "  local set context: ${MEM_LARGE3:-none} bytes after a third large transaction, ${MEM_CAND:-none} after 100 try_many calls of $((HELD + 1)) keys"
if [[ -n "$MEM_LARGE3" && -n "$MEM_CAND" ]] && (( MEM_LARGE3 > 40 * MB && MEM_CAND < 8 * MB )); then
    pass "shrink_after_candidates" "bytes" "$MEM_CAND" "long try_many candidate lists do not keep the enlarged set"
else
    fail "shrink_after_candidates" "bytes" "${MEM_LARGE3:-none}/${MEM_CAND:-none}" "the set must hold > 40 MB after the large transaction and < 8 MB after the candidate calls"
fi

BEFORE="$(q "SELECT round(ms) FROM timings WHERE label = 'default_before';")"
AFTER="$(q "SELECT round(ms) FROM timings WHERE label = 'default_after';")"
MANY_BEFORE="$(q "SELECT round(ms) FROM timings WHERE label = 'many_before';")"
MANY_AFTER="$(q "SELECT round(ms) FROM timings WHERE label = 'many_after';")"
LEFT="$(q "SELECT capacity_used FROM xclaim.stats();")"
echo "  $N one-claim transactions: ${BEFORE} ms before, ${AFTER} ms after the $BULK transaction"
echo "  $N_MANY transactions of $K_MANY claims: ${MANY_BEFORE} ms before, ${MANY_AFTER} ms after"
echo "  capacity_used at the end: $LEFT"

if within_3x "$AFTER" "$BEFORE"; then
    pass "after_large_xact" "ms" "$AFTER" "one-claim transactions after the large transaction stay within 3x of before ($BEFORE ms)"
else
    fail "after_large_xact" "ms" "${AFTER:-none} vs ${BEFORE:-none}" "one-claim transactions after a $BULK transaction must stay within 3x of before"
fi
if within_3x "$MANY_AFTER" "$MANY_BEFORE"; then
    pass "many_after_large_xact" "ms" "$MANY_AFTER" "$K_MANY-claim transactions after the large transaction stay within 3x of before ($MANY_BEFORE ms)"
else
    fail "many_after_large_xact" "ms" "${MANY_AFTER:-none} vs ${MANY_BEFORE:-none}" "$K_MANY-claim transactions after a $BULK transaction must stay within 3x of before"
fi
if [[ "$LEFT" == "0" ]]; then
    pass "default_released" "capacity_used" "$LEFT" "every claim was released"
else
    fail "default_released" "capacity_used" "$LEFT" "every claim must be released"
fi

pg_xclaim_stop_temp_cluster
trap pg_xclaim_stop_temp_cluster EXIT INT TERM

# ---------------------------------------------------------------------------
# Test 2: a 1M-bucket set from the first claim
# ---------------------------------------------------------------------------
echo "--- Test 2: expected_claims_per_backend = 750000 ---"

XCLAIM_EXTRA_CONF="pg_xclaim.expected_claims_per_backend = 750000"
pg_xclaim_start_temp_cluster "short_xact_large"
setup_sql

run_sql "Test 2" <<SQL
CALL one_claim_xacts($N, 'large_set');
CALL many_claim_xacts($N_MANY, $K_MANY, 'many_large_set');
SQL
LARGE="$(q "SELECT round(ms) FROM timings WHERE label = 'large_set';")"
MANY_LARGE="$(q "SELECT round(ms) FROM timings WHERE label = 'many_large_set';")"
echo "  $N one-claim transactions with a 750000-claim set: ${LARGE} ms (default set: ${BEFORE} ms)"
echo "  $N_MANY transactions of $K_MANY claims with a 750000-claim set: ${MANY_LARGE} ms (default set: ${MANY_BEFORE} ms)"

if within_3x "$LARGE" "$BEFORE"; then
    pass "large_set" "ms" "$LARGE" "a large expected_claims_per_backend does not raise the cost of a one-claim transaction"
else
    fail "large_set" "ms" "${LARGE:-none} vs ${BEFORE:-none}" "one-claim transactions with a large set must stay within 3x of the default set"
fi
if within_3x "$MANY_LARGE" "$MANY_BEFORE"; then
    pass "many_large_set" "ms" "$MANY_LARGE" "a large expected_claims_per_backend does not raise the cost of a $K_MANY-claim transaction"
else
    fail "many_large_set" "ms" "${MANY_LARGE:-none} vs ${MANY_BEFORE:-none}" "$K_MANY-claim transactions with a large set must stay within 3x of the default set"
fi

# ---------------------------------------------------------------------------
# Test 3: failed tries do not fill the held-key list
# ---------------------------------------------------------------------------
echo "--- Test 3: one claim and $MISSES conflicts per transaction, expected_claims_per_backend = 750000 ---"

xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'claim=' || xclaim.try(424242::int8);"
if ! xclaim_holder_wait '^claim=true$'; then
    echo "  FAIL: the holder did not take key 424242, output follows:" >&2
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
    FAIL=$(( FAIL + 1 ))
fi

run_sql "Test 3" <<SQL
CALL conflict_xacts(300, 0, 'commit_plain');
CALL conflict_xacts(300, $MISSES, 'commit_after_misses');
SQL

xclaim_holder_sql "ROLLBACK;"
xclaim_holder_close

PLAIN="$(q "SELECT round(ms) FROM timings WHERE label = 'commit_plain';")"
MISSED="$(q "SELECT round(ms) FROM timings WHERE label = 'commit_after_misses';")"
echo "  300 COMMITs of one claim: ${PLAIN} ms, after $MISSES failed tries each: ${MISSED} ms"
if within_3x "$MISSED" "$PLAIN"; then
    pass "commit_after_misses" "ms" "$MISSED" "failed tries leave the COMMIT of one claim on the list path"
else
    fail "commit_after_misses" "ms" "${MISSED:-none} vs ${PLAIN:-none}" "COMMIT after failed tries must stay within 3x of a plain one"
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
