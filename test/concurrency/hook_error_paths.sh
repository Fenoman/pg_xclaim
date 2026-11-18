#!/usr/bin/env bash
# test/concurrency/hook_error_paths.sh
# Error paths of the acquisition that only C code in the backend reaches,
# driven by the test-only hooks module (test/modules/xclaim_test_hooks).
#
#   Test 1: xclaim.try called while every slot of the backend's held-LWLock
#           array is in use (200 in PostgreSQL, more in some forks). Its
#           LWLockAcquire raises "too many LWLocks taken", and the module
#           catches the ERROR. The local entry xclaim.try added before the
#           lock is gone: a second xclaim.try of the key in the same
#           transaction takes a real claim (xclaim.count() 1, one shared
#           row), and cleanup_misses stays 0 after COMMIT.
#   Test 2: the shared table is full, warn mode, and an emit_log_hook calls
#           xclaim.session_reset() on the capacity WARNING inside an
#           xclaim.try_many loop. session_reset refuses ("cannot be called
#           during xclaim.try_many"): it would rotate the owner token of the
#           claims the loop goes on to take.
#   Test 3: an emit_log_hook calls xclaim.session_reset() on a LOG message
#           written by the interrupt check of xclaim.try (the memory context
#           dump of pg_log_backend_memory_contexts on the own backend). The
#           reset rotates the owner token to 0, and the claim xclaim.try
#           takes right after it carries a published token, never 0.
#   Test 4: the same hook runs xclaim.try of the key the outer xclaim.try
#           is about to take. The backend counts the seed and hook claims.
#           The hook sees one claim on entry, and the outer call records one
#           reentrant hit. The hook's key has one local entry and one shared
#           row. A statement LOG before execution cannot satisfy the check.
#   Test 5: the same for an outer xclaim.try_many of one key. Its array is
#           a constant: a subquery would process the interrupt in the
#           executor, before try_many runs.
#   Test 6: scalar xclaim.try failing inside emit_log_hook on a key already
#           staged by outer xclaim.try_many leaves the outer staged slot intact
#           (verified via capacity_warnings delta = 3).
#   Test 7a/7b: nested xclaim.try_many on ALREADY_STAGED keys (both warn-mode
#           return and error-mode double PG_CATCH rollback + demotion).
#   Test 8: inherited PGDATA and XCLAIM_TEST_HOOKS_DIR survive early failure.
#   Test 9: cross-partition duplicate rollback + PREPARE TRANSACTION leaves
#           zero stale staged entry (verified via owner_lxid equality before
#           finishing the prepared transaction).
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="hook_error_paths"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

xclaim_banner "$SCRIPT"

trap pg_xclaim_stop_temp_cluster EXIT INT TERM
XCLAIM_MAX_CLAIMS=32
XCLAIM_NUM_PARTITIONS=32
XCLAIM_EXTRA_CONF="pg_xclaim.expected_claims_per_backend = 32
max_prepared_transactions = 5
lc_messages = 'C'"
xclaim_build_test_hooks
pg_xclaim_start_temp_cluster "hook_error_paths"
xclaim_create_test_hooks_functions

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Test 1: ERROR from LWLockAcquire inside xclaim.try
# ---------------------------------------------------------------------------
echo "--- Test 1: xclaim.try with every LWLock slot in use ---"
OUT="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 2>&1 <<'SQL'
BEGIN;
SELECT 'caught=' || xclaim_test_call_with_lwlocks_held('xclaim.try(bigint)'::regprocedure, 42);
SELECT 'retry=' || xclaim.try(42::int8);
SELECT 'count=' || xclaim.count() || ' shared=' || capacity_used FROM xclaim.stats();
COMMIT;
SELECT 'after=' || capacity_used || ' misses=' || cleanup_misses FROM xclaim.stats();
SQL
)" || true
echo "$OUT" | sed 's/^/    /'
if grep -q '^caught=true$' <<<"$OUT" && grep -q '^retry=true$' <<<"$OUT" &&
   grep -q '^count=1 shared=1$' <<<"$OUT" && grep -q '^after=0 misses=0$' <<<"$OUT"; then
    echo "  PASS: the caught ERROR left no local entry, the retry took a real claim"
    PASS=$((PASS+1))
else
    echo "  FAIL: expected caught=true, retry=true, count=1 shared=1, after=0 misses=0" >&2
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# Test 2: session_reset from an emit_log_hook inside a try_many loop
# ---------------------------------------------------------------------------
echo "--- Test 2: session_reset on the capacity WARNING inside xclaim.try_many ---"
xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'held=' || count(*) FROM unnest(xclaim.try_many(ARRAY(SELECT g::int8 FROM generate_series(1, 32) g))) t WHERE t;"
if ! xclaim_holder_wait '^held=32$'; then
    echo "  FAIL: the holder did not fill the table, output follows:" >&2
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
    FAIL=$((FAIL+1))
fi

OUT="$(pg_xclaim_psql -X -A -t -q 2>&1 <<'SQL'
SET pg_xclaim.on_capacity_exhaustion = 'warn';
SELECT set_config('xclaim_test_hooks.call_on_warning',
                  ('xclaim.session_reset()'::regprocedure::oid)::text, false);
SELECT 'taken=' || count(*) FILTER (WHERE t)
FROM unnest(xclaim.try_many(ARRAY(SELECT g::int8 FROM generate_series(101, 110) g))) t;
SELECT 'resets=' || session_resets FROM xclaim.stats();
SQL
)" || true

xclaim_holder_sql "ROLLBACK;"
xclaim_holder_close

echo "$OUT" | sed 's/^/    /'
if grep -q 'cannot be called during xclaim.try_many' <<<"$OUT" && grep -q '^resets=0$' <<<"$OUT"; then
    echo "  PASS: session_reset refuses inside the try_many loop"
    PASS=$((PASS+1))
else
    echo "  FAIL: session_reset must refuse inside the try_many loop and count no reset" >&2
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# Test 3: session_reset from an emit_log_hook in the interrupt check of xclaim.try
# ---------------------------------------------------------------------------
echo "--- Test 3: session_reset on a LOG message inside xclaim.try ---"
# One autocommit statement: session_reset refuses inside a transaction
# block. The hook runs on the first LOG of the session, so the session
# writes no statement or duration LOG before it. The expression runs left to right: pg_log_backend_memory_contexts
# signals the own backend, the first interrupt check after it is the one of
# xclaim.try(1), and the scalar subqueries run after both claims are taken.
OUT="$(pg_xclaim_psql -X -A -t -q 2>&1 <<'SQL'
SET log_statement = 'none';
SET log_duration = off;
SET log_min_duration_statement = -1;
SELECT set_config('xclaim_test_hooks.call_on_log',
                  ('xclaim.session_reset()'::regprocedure::oid)::text, false);
SELECT 'signal=' || pg_log_backend_memory_contexts(pg_backend_pid())
       || ' claims=' || xclaim.try(1::int8) || ',' || xclaim.try(2::int8)
       || ' zero_token=' || (SELECT count(*) FROM xclaim.debug() WHERE owner_token = 0)
       || ' rows=' || (SELECT count(*) FROM xclaim.debug());
SELECT 'resets=' || session_resets || ' after=' || capacity_used FROM xclaim.stats();
SQL
)" || true
echo "$OUT" | sed 's/^/    /'
if grep -q '^signal=true claims=true,true zero_token=0 rows=2$' <<<"$OUT" && grep -q '^resets=1 after=0$' <<<"$OUT"; then
    echo "  PASS: the reset ran inside xclaim.try, both claims carry a published token"
    PASS=$((PASS+1))
else
    echo "  FAIL: expected signal=true claims=true,true zero_token=0 rows=2 and resets=1 after=0" >&2
    FAIL=$((FAIL+1))
fi

# Tests 4 and 5: the hook takes the outer call's key on its interrupt LOG.
# A preceding claim in the same statement makes the hook's entry count 1.
# A statement LOG before execution cannot satisfy the check.
outer_claim_test() {  # key, outer call, label, expected result
    local key="$1" call="$2" label="$3"
    OUT="$(pg_xclaim_psql -X -A -t -q 2>&1 <<SQL
CREATE FUNCTION hook_claim_$key() RETURNS bool LANGUAGE plpgsql AS \$\$
BEGIN
    PERFORM set_config('xclaim_test.hook_entry_count', xclaim.count()::text, true);
    RETURN xclaim.try($key::int8);
END
\$\$;
SET log_statement = 'none';
SET log_duration = off;
SET log_min_duration_statement = -1;
SELECT reentrant_hits AS hits0 FROM xclaim.stats() \gset
SELECT set_config('xclaim_test.hook_entry_count', '-1', false);
SELECT set_config('xclaim_test_hooks.call_on_log',
                  ('hook_claim_$key()'::regprocedure::oid)::text, false);
SELECT 'seed=' || xclaim.try((-$key)::int8)
       || ' signal=' || pg_log_backend_memory_contexts(pg_backend_pid())
       || ' outer=' || ($call)::text
       || ' count=' || xclaim.count()
       || ' rows=' || (SELECT count(*) FROM xclaim.debug() WHERE key = $key)
       || ' hits=' || ((SELECT reentrant_hits FROM xclaim.stats()) - :hits0)
       || ' hook_entry=' || current_setting('xclaim_test.hook_entry_count');
SELECT 'hook_ran=' || (current_setting('xclaim_test_hooks.call_on_log') = '0')
       || ' after=' || capacity_used || ' misses=' || cleanup_misses FROM xclaim.stats();
SQL
)" || true
    echo "$OUT" | sed 's/^/    /'
    if grep -q "^seed=true signal=true outer=$4 count=2 rows=1 hits=1 hook_entry=1\$" <<<"$OUT" && grep -q '^hook_ran=true after=0 misses=0$' <<<"$OUT"; then
        echo "  PASS: the outer $label finds the hook's key, with the seed and hook claims counted"
        PASS=$((PASS+1))
    else
        echo "  FAIL: expected seed=true signal=true outer=$4 count=2 rows=1 hits=1 hook_entry=1 and hook_ran=true after=0 misses=0" >&2
        FAIL=$((FAIL+1))
    fi
}

# ---------------------------------------------------------------------------
# Test 4: xclaim.try of the same key from an emit_log_hook in the interrupt check
# ---------------------------------------------------------------------------
echo "--- Test 4: the hook takes the key the outer xclaim.try is about to take ---"
outer_claim_test 77 "xclaim.try(77::int8)" "xclaim.try" "true"

# ---------------------------------------------------------------------------
# Test 5: the same inside xclaim.try_many
# ---------------------------------------------------------------------------
echo "--- Test 5: the hook takes the key the outer xclaim.try_many is about to take ---"
outer_claim_test 78 "xclaim.try_many(ARRAY[78::int8])" "xclaim.try_many" "{t}"

# Pick three distinct pair keys (scope = 1, k >= 1000) in partition 0 using
# the exact C dynahash key layout so an outer xclaim.try_many stages all three
# in one Phase A chunk before probing.
SAME_PART_KEYS="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 -c "
SELECT string_agg(k::text, ':' ORDER BY k)
FROM (
    SELECT g AS k
    FROM generate_series(1000, 5000) g
    WHERE xclaim_test_pair_partition(1, g) = 0
    ORDER BY g
    LIMIT 3
) s;")"
IFS=':' read -r SK1 SK2 SK3 <<<"$SAME_PART_KEYS"

# ---------------------------------------------------------------------------
# Test 6: scalar xclaim.try failing inside emit_log_hook on a key already
#         staged by outer xclaim.try_many preserves the outer staged entry
# ---------------------------------------------------------------------------
echo "--- Test 6: failed scalar xclaim.try in hook keeps outer try_many staged entry ---"
xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SET LOCAL pg_xclaim.on_capacity_exhaustion = 'warn';"
xclaim_holder_sql "SELECT 'filled6=' || count(*) FROM unnest(xclaim.try_many(2, ARRAY(SELECT g::int4 FROM generate_series(1, 500) g))) t WHERE t;"
xclaim_holder_wait '^filled6=[1-9]'

WARN_T6_BEFORE="$(pg_xclaim_psql -X -A -t -q -c "SELECT capacity_warnings FROM xclaim.stats();")"
OUT="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 2>&1 <<SQL
CREATE OR REPLACE FUNCTION hook_scalar_staged_miss() RETURNS void LANGUAGE plpgsql AS \$\$
BEGIN
    PERFORM set_config('xclaim_test.scalar_hook_res', xclaim.try(1, $SK2)::text, true);
END
\$\$;
SET pg_xclaim.on_capacity_exhaustion = 'warn';
SELECT set_config('xclaim_test.scalar_hook_res', 'unset', false);
SELECT set_config('xclaim_test_hooks.call_on_warning',
                  ('hook_scalar_staged_miss()'::regprocedure::oid)::text, false);
BEGIN;
SELECT 'outer=' || xclaim.try_many(1, ARRAY[$SK1, $SK2]::int4[])::text
       || ' hook=' || current_setting('xclaim_test.scalar_hook_res')
       || ' count=' || xclaim.count();
COMMIT;
SQL
)" || true
WARN_T6_AFTER="$(pg_xclaim_psql -X -A -t -q -c "SELECT capacity_warnings FROM xclaim.stats();")"
WARN_T6_DELTA=$((WARN_T6_AFTER - WARN_T6_BEFORE))

xclaim_holder_sql "ROLLBACK;"
xclaim_holder_close

AFTER_T6="$(pg_xclaim_psql -X -A -t -q -c "SELECT capacity_used || ':' || cleanup_misses || ':' || (SELECT count(*) FROM xclaim.debug()) FROM xclaim.stats();")"
echo "$OUT" | sed 's/^/    /'
if grep -q '^outer={f,f} hook=false count=0$' <<<"$OUT" \
   && [[ "$WARN_T6_DELTA" == "3" && "$AFTER_T6" == "0:0:0" ]]; then
    echo "  PASS: failed scalar xclaim.try kept outer staged slot intact (warn_delta=$WARN_T6_DELTA, state 0:0:0)"
    PASS=$((PASS+1))
else
    echo "  FAIL: expected outer={f,f} hook=false count=0, warn_delta=3, after=0:0:0 (got warn_delta=$WARN_T6_DELTA, after=$AFTER_T6)" >&2
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# Test 7: nested xclaim.try_many on ALREADY_STAGED keys (both normal return
#         in warn mode and catastrophic PG_CATCH rollback + demotion in error
#         mode). Note: PostgreSQL's EmitErrorReport() holds ErrorData in
#         ErrorContext, so FlushErrorState() (PL/pgSQL EXCEPTION) cannot run
#         inside emit_log_hook itself, and an error thrown in the hook unwinds
#         through nested PG_CATCH -> outer PG_CATCH -> caller's EXCEPTION.
# ---------------------------------------------------------------------------
echo "--- Test 7a: nested warn-mode try_many on ALREADY_STAGED keys returns cleanly to outer try_many ---"
pg_xclaim_psql -X -q -v ON_ERROR_STOP=1 -c "SELECT xclaim_test_inject_stale(1, $SK2);"

xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SET LOCAL pg_xclaim.on_capacity_exhaustion = 'warn';"
xclaim_holder_sql "SELECT 'filled7a=' || count(*) FROM unnest(xclaim.try_many(2, ARRAY(SELECT g::int4 FROM generate_series(1, 500) g))) t WHERE t;"
xclaim_holder_wait '^filled7a=[1-9]'
HOLDER_FILLED="$(sed -n 's/^filled7a=//p' "$XCLAIM_HOLDER_OUT" | tail -1)"
EXPECTED_USED=$(( HOLDER_FILLED + 1 ))

OUT="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 2>&1 <<SQL
CREATE OR REPLACE FUNCTION hook_nested_bulk_warn() RETURNS void LANGUAGE plpgsql AS \$\$
BEGIN
    PERFORM set_config('xclaim_test.nested_warn_res',
                       xclaim.try_many(1, ARRAY[$SK2, $SK3]::int4[])::text,
                       true);
END
\$\$;
SET pg_xclaim.on_capacity_exhaustion = 'warn';
SELECT set_config('xclaim_test.nested_warn_res', 'unset', false);
SELECT set_config('xclaim_test_hooks.call_on_warning',
                  ('hook_nested_bulk_warn()'::regprocedure::oid)::text, false);
BEGIN;
SELECT 'outer=' || xclaim.try_many(1, ARRAY[$SK1, $SK2, $SK3]::int4[])::text
       || ' inner=' || current_setting('xclaim_test.nested_warn_res')
       || ' count=' || xclaim.count()
       || ' used=' || (SELECT capacity_used FROM xclaim.stats())
       || ' key_rows=' || (SELECT count(*) FROM xclaim.debug() WHERE scope = 1 AND key = $SK2);
COMMIT;
SQL
)" || true

xclaim_holder_sql "ROLLBACK;"
xclaim_holder_close

AFTER_T7A="$(pg_xclaim_psql -X -A -t -q -c "SELECT capacity_used || ':' || cleanup_misses || ':' || (SELECT count(*) FROM xclaim.debug()) FROM xclaim.stats();")"
echo "$OUT" | sed 's/^/    /'
if grep -q "^outer={f,t,f} inner={t,f} count=1 used=${EXPECTED_USED} key_rows=1\$" <<<"$OUT" && [[ "$AFTER_T7A" == "0:0:0" ]]; then
    echo "  PASS: nested warn-mode try_many acquired SK2 and kept SK3 staged for outer try_many"
    PASS=$((PASS+1))
else
    echo "  FAIL: expected outer={f,t,f} inner={t,f} count=1 used=${EXPECTED_USED} key_rows=1 and after=0:0:0 (got after=$AFTER_T7A)" >&2
    FAIL=$((FAIL+1))
fi

echo "--- Test 7b: nested error-mode try_many rollback demotes ALREADY_STAGED + reaped key ---"
pg_xclaim_psql -X -q -v ON_ERROR_STOP=1 -c "SELECT xclaim_test_inject_stale(1, $SK2);"

xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SET LOCAL pg_xclaim.on_capacity_exhaustion = 'warn';"
xclaim_holder_sql "SELECT 'filled7b=' || count(*) FROM unnest(xclaim.try_many(2, ARRAY(SELECT g::int4 FROM generate_series(1, 500) g))) t WHERE t;"
xclaim_holder_wait '^filled7b=[1-9]'
HOLDER_FILLED_B="$(sed -n 's/^filled7b=//p' "$XCLAIM_HOLDER_OUT" | tail -1)"
EXPECTED_USED_B=$(( HOLDER_FILLED_B + 1 ))

OUT="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 2>&1 <<SQL
CREATE OR REPLACE FUNCTION hook_nested_bulk_err() RETURNS void LANGUAGE plpgsql AS \$\$
BEGIN
    SET LOCAL pg_xclaim.on_capacity_exhaustion = 'error';
    PERFORM xclaim.try_many(1, ARRAY[$SK2, $SK3]::int4[]);
END
\$\$;
BEGIN;
DO \$\$
BEGIN
    SET LOCAL pg_xclaim.on_capacity_exhaustion = 'warn';
    PERFORM set_config('xclaim_test_hooks.call_on_warning',
                       ('hook_nested_bulk_err()'::regprocedure::oid)::text, false);
    BEGIN
        PERFORM xclaim.try_many(1, ARRAY[$SK1, $SK2, $SK3]::int4[]);
        RAISE EXCEPTION 'outer try_many unexpectedly succeeded';
    EXCEPTION WHEN configuration_limit_exceeded THEN
        PERFORM set_config('xclaim_test.unwound_ok', 'yes', true);
    END;
END
\$\$;
SELECT 'caught=' || current_setting('xclaim_test.unwound_ok')
       || ' count_after_err=' || xclaim.count()
       || ' used_after_err=' || (SELECT capacity_used FROM xclaim.stats())
       || ' retry_sk2=' || xclaim.try(1, $SK2)
       || ' count_retry=' || xclaim.count()
       || ' used_retry=' || (SELECT capacity_used FROM xclaim.stats());
COMMIT;
SQL
)" || true

xclaim_holder_sql "ROLLBACK;"
xclaim_holder_close

AFTER_T7B="$(pg_xclaim_psql -X -A -t -q -c "SELECT capacity_used || ':' || cleanup_misses || ':' || (SELECT count(*) FROM xclaim.debug()) FROM xclaim.stats();")"
echo "$OUT" | sed 's/^/    /'
if grep -q "^caught=yes count_after_err=0 used_after_err=${HOLDER_FILLED_B} retry_sk2=true count_retry=1 used_retry=${EXPECTED_USED_B}\$" <<<"$OUT" && [[ "$AFTER_T7B" == "0:0:0" ]]; then
    echo "  PASS: nested + outer PG_CATCH rolled back reaped SK2, demoted + unstaged cleanly, retry succeeded"
    PASS=$((PASS+1))
else
    echo "  FAIL: expected caught=yes count_after_err=0 used_after_err=${HOLDER_FILLED_B} retry_sk2=true count_retry=1 used_retry=${EXPECTED_USED_B} and after=0:0:0 (got after=$AFTER_T7B)" >&2
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# Test 8: early setup failure in _lib.sh never deletes inherited PGDATA or
#         XCLAIM_TEST_HOOKS_DIR from caller environment
# ---------------------------------------------------------------------------
echo "--- Test 8: inherited PGDATA and XCLAIM_TEST_HOOKS_DIR survive early setup failure ---"
FAKE_PGDATA="$(mktemp -d /tmp/xclaim_foreign_pgdata.XXXXXX)"
FAKE_HOOKS="$(mktemp -d /tmp/xclaim_foreign_hooks.XXXXXX)"
echo "keep" > "$FAKE_PGDATA/PG_VERSION"
echo "keep" > "$FAKE_HOOKS/keep.txt"
SUB_RC=0
env PGDATA="$FAKE_PGDATA" XCLAIM_TEST_HOOKS_DIR="$FAKE_HOOKS" PG_CONFIG="$PG_CONFIG" \
    bash -c '
        set -euo pipefail
        source "'"$LIB_DIR"'/_lib.sh"
        trap pg_xclaim_stop_temp_cluster EXIT INT TERM
        XCLAIM_LIB_DIR="/nonexistent/dir"
        xclaim_build_test_hooks
    ' >/dev/null 2>&1 || SUB_RC=$?
FOREIGN_SURVIVED=no
if [[ -f "$FAKE_PGDATA/PG_VERSION" && -f "$FAKE_HOOKS/keep.txt" ]]; then
    FOREIGN_SURVIVED=yes
fi
rm -rf "$FAKE_PGDATA" "$FAKE_HOOKS"
if (( SUB_RC != 0 )) && [[ "$FOREIGN_SURVIVED" == "yes" ]]; then
    echo "  PASS: foreign PGDATA and hooks dir survived failed setup (rc=$SUB_RC)"
    PASS=$((PASS+1))
else
    echo "  FAIL: foreign dirs touched or setup did not fail (rc=$SUB_RC survived=$FOREIGN_SURVIVED)" >&2
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# Test 9: duplicate key in partition 0 (slot 0 warn miss, slot 1 acquired after
#         hook frees space) followed by an ERROR in partition 1 and PREPARE
#         TRANSACTION leaves zero stale staged entry for the next transaction
# ---------------------------------------------------------------------------
echo "--- Test 9: cross-partition duplicate rollback + PREPARE leaves zero stale staged entry ---"
xclaim_holder_open
xclaim_holder_sql "SELECT 'hpid9=' || pg_backend_pid();"
xclaim_holder_wait '^hpid9=[0-9]+'
HPID9="$(sed -n 's/^hpid9=//p' "$XCLAIM_HOLDER_OUT" | tail -n 1)"
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SET LOCAL pg_xclaim.on_capacity_exhaustion = 'warn';"
xclaim_holder_sql "SELECT 'filled9=' || count(*) FROM unnest(xclaim.try_many(2, ARRAY(SELECT g::int4 FROM generate_series(1, 500) g))) t WHERE t;"
xclaim_holder_wait '^filled9=[1-9]'

OUT9="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 2>&1 <<SQL
CREATE OR REPLACE FUNCTION hook_free_p0_and_arm_err() RETURNS void LANGUAGE plpgsql AS \$\$
DECLARE
    tries int := 0;
BEGIN
    PERFORM set_config('xclaim_test_hooks.call_on_warning', '0', false);
    PERFORM pg_terminate_backend($HPID9);
    WHILE (SELECT capacity_used FROM xclaim.stats()) > 0 LOOP
        tries := tries + 1;
        IF tries > 500 THEN
            RAISE EXCEPTION 'holder backend did not release claims within 5s';
        END IF;
        PERFORM pg_sleep(0.01);
    END LOOP;
    PERFORM set_config('pg_xclaim.on_capacity_exhaustion', 'error', true);
END
\$\$;
SET pg_xclaim.on_capacity_exhaustion = 'warn';
SELECT set_config('xclaim_test_hooks.call_on_warning',
                  ('hook_free_p0_and_arm_err()'::regprocedure::oid)::text, false);
BEGIN;
DO \$\$
DECLARE
    p1_keys int4[];
BEGIN
    SELECT array_agg(g::int4 ORDER BY g) INTO p1_keys
    FROM (
        SELECT g FROM generate_series(1000, 30000) g
        WHERE xclaim_test_pair_partition(1, g) = 1
        ORDER BY g LIMIT 500
    ) s;
    BEGIN
        PERFORM xclaim.try_many(1, ARRAY[$SK1, $SK1]::int4[] || p1_keys);
        RAISE EXCEPTION 'unexpected try_many success in Test 9';
    EXCEPTION WHEN configuration_limit_exceeded THEN
        NULL;
    END;
END
\$\$;
SELECT 't9_count_before_prep=' || xclaim.count();
PREPARE TRANSACTION 't9_dup_prep';
BEGIN;
SELECT 't9_next_acq=' || xclaim.try_many(1, ARRAY[$SK1, $SK2]::int4[])::text
       || ' distinct_lxids=' || (SELECT count(DISTINCT owner_lxid) FROM xclaim.debug());
ROLLBACK;
ROLLBACK PREPARED 't9_dup_prep';
SQL
)" || true
xclaim_holder_close || true

AFTER_T9="$(pg_xclaim_psql -X -A -t -q -c "SELECT capacity_used || ':' || cleanup_misses || ':' || (SELECT count(*) FROM xclaim.debug()) FROM xclaim.stats();")"
echo "$OUT9" | sed 's/^/    /'
if grep -q '^t9_count_before_prep=0$' <<<"$OUT9" \
   && grep -q '^t9_next_acq={t,t} distinct_lxids=1$' <<<"$OUT9" \
   && [[ "$AFTER_T9" == "0:0:0" ]]; then
    echo "  PASS: cross-partition duplicate rollback + PREPARE left zero stale staged entry (distinct_lxids=1, state 0:0:0)"
    PASS=$((PASS+1))
else
    echo "  FAIL: expected t9_count_before_prep=0, t9_next_acq={t,t} distinct_lxids=1, after=0:0:0 (got after=$AFTER_T9)" >&2
    FAIL=$((FAIL+1))
fi

xclaim_check_server_log "$SCRIPT" "terminating connection due to administrator command" || FAIL=$((FAIL+1))

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
