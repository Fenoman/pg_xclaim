#!/usr/bin/env bash
# test/concurrency/peak_warn.sh
# Per-backend peak watermark LOG hint.
#
# Scenario:
#   Configure a tiny pg_xclaim.expected_claims_per_backend (= 64), so
#   the 75% threshold is 48 claims. Acquire enough claims in a single
#   transaction to cross the threshold, and verify:
#     1. The LOG hint fires exactly once per session (one-shot flag).
#     2. xclaim.session_reset() rearms the flag and a second growth
#        emits another LOG hint.
#     3. Workloads that stay below the threshold never log.
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
    # grep -c returns 1 when no matches; tolerate via `|| true`. -E for ERE.
    local n
    n="$(grep -cE "$PEAK_PATTERN" "$LOG_FILE" 2>/dev/null || true)"
    # Normalise whitespace / empty (grep prints "0" but be defensive).
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
# Test 2: cross 75% -- LOG hint fires exactly once in this session
# ---------------------------------------------------------------------------
echo "--- Test 2: 50 claims (78%) -- must log once ---"

HITS_BEFORE="$(count_log_hits)"

# Single backend session: 50 claims, then 50 more after session_reset.
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
# Test 3: session_reset() rearms the flag -- another threshold cross logs again
# ---------------------------------------------------------------------------
echo "--- Test 3: session_reset rearms -- second cross logs again ---"

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
# Server log sanity
# ---------------------------------------------------------------------------
xclaim_check_server_log "$SCRIPT" || FAIL=$((FAIL+1))

echo ""
echo "RESULT: $SCRIPT  PASS=$PASS  FAIL=$FAIL"

exit $(( FAIL > 0 ? 1 : 0 ))
