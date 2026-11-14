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

xclaim_check_server_log "$SCRIPT" || FAIL=$((FAIL+1))

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
