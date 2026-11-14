#!/usr/bin/env bash
# test/concurrency/peak_warn.sh
# Per-backend peak watermark LOG hint.
#
# Scenario:
#   Configure a tiny pg_xclaim.expected_claims_per_backend (= 64), so
#   the 75% threshold is 48 claims. Acquire enough claims in a single
#   transaction to cross the threshold, and verify:
#     1. Workloads that stay below the threshold never log.
#     2. A conflicting xclaim.try counts nothing: a session at the
#        threshold that conflicts once logs no hint, and its peak stays.
#     3. The LOG hint fires exactly once per session (one-shot flag).
#     4. xclaim.session_reset() rearms the flag and a second growth
#        emits another LOG hint.
#     5. The hint names the live count at the crossing (49), not at the
#        end of the call (50).
#     6. A hint marked by a call that then fails on capacity is written
#        by the next call of the session, and xclaim.session_reset()
#        drops it.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="peak_warn"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

# Tiny pre-grow target so we can cross 75% without bulk overhead.
XCLAIM_EXTRA_CONF="pg_xclaim.expected_claims_per_backend = 64
log_min_messages = log
"

# max_claims must be >= expected (cross-GUC validation in pg_xclaim.c).
# We bump it to fit the test without bumping num_partitions (32 freelist floor).
# Test 6 fills the shared table to the last 50 rows of these 4096.
XCLAIM_MAX_CLAIMS=4096
XCLAIM_NUM_PARTITIONS=32

pg_xclaim_start_temp_cluster "peak_warn"
trap pg_xclaim_stop_temp_cluster EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
LOG_FILE="$PGDATA/server.log"
PEAK_PATTERN='crossed 75%.*expected_claims_per_backend'

count_log_hits() {
    # grep -c returns 1 when nothing matches, hence `|| true`. -E for ERE.
    local n
    n="$(grep -cE "$PEAK_PATTERN" "$LOG_FILE" 2>/dev/null || true)"
    # Normalise empty output to 0 (grep prints "0" but be defensive).
    echo "${n:-0}"
}

# ---------------------------------------------------------------------------
# Test 1: stay below threshold -- no LOG hint
# ---------------------------------------------------------------------------
echo "--- Test 1: 32 claims (50%) -- must NOT log ---"

HITS_BEFORE="$(count_log_hits)"

pg_xclaim_psql -X -q <<'SQL' >/dev/null
BEGIN;
SELECT xclaim.try_many(ARRAY(SELECT generate_series(1, 32)::int4));
COMMIT;
SQL

HITS_AFTER="$(count_log_hits)"
if xclaim_assert_eq "no LOG hint at 50% fill" "$HITS_AFTER" "$HITS_BEFORE"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# Test 2: a conflict at the threshold counts nothing
# ---------------------------------------------------------------------------
echo "--- Test 2: 48 claims and one conflict -- no LOG, peak stays 48 ---"

# A holds the key the session conflicts on. The peak of the cluster is 32
# from Test 1, so the session's own peak decides peak_per_backend.
xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'claim=' || xclaim.try(999999::int8);"
if ! xclaim_holder_wait '^claim=true$'; then
    echo "  FAIL: holder did not take its key, output follows:" >&2
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
    FAIL=$((FAIL+1))
fi

HITS_BEFORE="$(count_log_hits)"

OUT="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 2>&1 <<'SQL'
BEGIN;
SELECT count(*) FROM unnest(xclaim.try_many(ARRAY(SELECT generate_series(501, 548)::int4)));
SELECT 'conflict=' || xclaim.try(999999::int8);
SELECT 'count=' || xclaim.count();
COMMIT;
BEGIN;
SELECT 'next=' || xclaim.try(600::int8);
SELECT 'peak=' || peak_per_backend FROM xclaim.stats();
COMMIT;
SQL
)" || true

xclaim_holder_sql "ROLLBACK;"
xclaim_holder_close

HITS_AFTER="$(count_log_hits)"
CONFLICT="$(sed -n 's/^conflict=//p' <<<"$OUT")"
COUNT="$(sed -n 's/^count=//p' <<<"$OUT")"
PEAK="$(sed -n 's/^peak=//p' <<<"$OUT")"
echo "  conflict: ${CONFLICT:-none}, count after it: ${COUNT:-none}, peak_per_backend: ${PEAK:-none}"
if xclaim_assert_eq "the conflicting try returns false" "$CONFLICT" "false"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi
if xclaim_assert_eq "48 claims held after the conflict" "$COUNT" "48"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi
if xclaim_assert_eq "peak_per_backend stays 48" "$PEAK" "48"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi
if xclaim_assert_eq "no LOG hint from a conflict" "$HITS_AFTER" "$HITS_BEFORE"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# Test 3: cross 75% -- LOG hint fires exactly once in this session
# ---------------------------------------------------------------------------
echo "--- Test 3: 50 claims (78%) -- must log once ---"

HITS_BEFORE="$(count_log_hits)"

# Single backend session: 50 claims, then 50 more without session_reset.
# We use a here-doc with two transactions in the same psql session.
pg_xclaim_psql -X -q <<'SQL' >/dev/null
BEGIN;
SELECT xclaim.try_many(ARRAY(SELECT generate_series(101, 150)::int4));
COMMIT;
BEGIN;
SELECT xclaim.try_many(ARRAY(SELECT generate_series(201, 250)::int4));
COMMIT;
SQL

HITS_AFTER="$(count_log_hits)"
DELTA=$(( HITS_AFTER - HITS_BEFORE ))
if xclaim_assert_eq "exactly one LOG per session" "$DELTA" "1"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# Test 4: session_reset() rearms the flag -- another threshold cross logs again
# ---------------------------------------------------------------------------
echo "--- Test 4: session_reset rearms -- second cross logs again ---"

HITS_BEFORE="$(count_log_hits)"

# Same psql process: cross threshold, reset, cross again. Expect 2 new logs.
pg_xclaim_psql -X -q <<'SQL' >/dev/null
BEGIN;
SELECT xclaim.try_many(ARRAY(SELECT generate_series(301, 350)::int4));
COMMIT;
SELECT xclaim.session_reset();
BEGIN;
SELECT xclaim.try_many(ARRAY(SELECT generate_series(401, 450)::int4));
COMMIT;
SQL

HITS_AFTER="$(count_log_hits)"
DELTA=$(( HITS_AFTER - HITS_BEFORE ))
if xclaim_assert_eq "session_reset rearms (2 new LOGs)" "$DELTA" "2"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# Test 5: the hint names the count at the crossing
# ---------------------------------------------------------------------------
echo "--- Test 5: one try_many of 50 claims -- LOG names 49 ---"

count_log_49() {
    local n
    n="$(grep -cE 'per-backend live claims \(49\) crossed 75%' "$LOG_FILE" 2>/dev/null || true)"
    echo "${n:-0}"
}

HITS_BEFORE="$(count_log_hits)"
HITS49_BEFORE="$(count_log_49)"

pg_xclaim_psql -X -q <<'SQL' >/dev/null
BEGIN;
SELECT xclaim.try_many(ARRAY(SELECT generate_series(701, 750)::int4));
COMMIT;
SQL

DELTA=$(( $(count_log_hits) - HITS_BEFORE ))
DELTA49=$(( $(count_log_49) - HITS49_BEFORE ))
if xclaim_assert_eq "one LOG, naming 49 live claims" "$DELTA/$DELTA49" "1/1"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# Test 6: a hint pending from a failed call
# ---------------------------------------------------------------------------
echo "--- Test 6: hint marked before a capacity ERROR -- next call writes it, session_reset drops it ---"

# The holder leaves 50 free rows. A try_many of 60 keys crosses 75% at its
# 49th insert and fails on capacity at its 51st, before it writes the hint.
xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'held=' || count(*) FROM unnest(xclaim.try_many(ARRAY(SELECT g::int8 FROM generate_series(1000001, 1004046) g))) t WHERE t;"
if ! xclaim_holder_wait '^held=4046$'; then
    echo "  FAIL: holder did not take 4046 rows, output follows:" >&2
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
    FAIL=$((FAIL+1))
fi

FAILING_CALL="SELECT xclaim.try_many(ARRAY(SELECT generate_series(801, 860)::int4));"

HITS_BEFORE="$(count_log_hits)"
HITS49_BEFORE="$(count_log_49)"
OUT_A="$(pg_xclaim_psql -X -A -t -q 2>&1 <<SQL
$FAILING_CALL
SELECT 'next=' || xclaim.try(900::int8);
SQL
)" || true
DELTA=$(( $(count_log_hits) - HITS_BEFORE ))
DELTA49=$(( $(count_log_49) - HITS49_BEFORE ))
if grep -q 'max_claims (4096) exhausted' <<<"$OUT_A" && grep -q '^next=true$' <<<"$OUT_A"; then
    echo "  the call failed on capacity, the next call took its key"
else
    echo "  FAIL: expected a capacity ERROR and then next=true, output follows:" >&2
    printf '%s\n' "$OUT_A" | sed 's/^/    /' >&2
    FAIL=$((FAIL+1))
fi
if xclaim_assert_eq "the next call writes the pending hint (49)" "$DELTA/$DELTA49" "1/1"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi

HITS_BEFORE="$(count_log_hits)"
OUT_B="$(pg_xclaim_psql -X -A -t -q 2>&1 <<SQL
$FAILING_CALL
SELECT xclaim.session_reset();
SELECT 'next=' || xclaim.try(901::int8);
SQL
)" || true
DELTA=$(( $(count_log_hits) - HITS_BEFORE ))
if ! grep -q '^next=true$' <<<"$OUT_B"; then
    echo "  FAIL: expected next=true after session_reset, output follows:" >&2
    printf '%s\n' "$OUT_B" | sed 's/^/    /' >&2
    FAIL=$((FAIL+1))
fi
if xclaim_assert_eq "session_reset drops the pending hint" "$DELTA" "0"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi

xclaim_holder_sql "ROLLBACK;"
xclaim_holder_close

# ---------------------------------------------------------------------------
# Server log sanity
# ---------------------------------------------------------------------------
xclaim_check_server_log "$SCRIPT" || FAIL=$((FAIL+1))

echo ""
echo "RESULT: $SCRIPT  PASS=$PASS  FAIL=$FAIL"

exit $(( FAIL > 0 ? 1 : 0 ))
