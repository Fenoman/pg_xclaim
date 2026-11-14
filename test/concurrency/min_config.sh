#!/usr/bin/env bash
# test/concurrency/min_config.sh
# The lowest accepted settings start a cluster that serves claims up to its
# capacity.
#
# Settings: pg_xclaim.max_claims = 32 (its lowest value) with
# num_partitions = 32 and expected_claims_per_backend = 32. dynahash puts
# one element on each of its 32 freelists.
#
# Checks:
#   * the server starts and xclaim.try_many takes all 32 keys
#   * the 33rd key fails with the capacity ERROR (SQLSTATE 53400)
#   * after ROLLBACK capacity_used is 0 and the server log has no FATAL or
#     PANIC
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="min_config"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

XCLAIM_MAX_CLAIMS=32
XCLAIM_NUM_PARTITIONS=32
XCLAIM_EXTRA_CONF="pg_xclaim.expected_claims_per_backend = 32
lc_messages = 'C'"
pg_xclaim_start_temp_cluster "min_config"
trap pg_xclaim_stop_temp_cluster EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0

OUT="$(pg_xclaim_psql -X -A -t -q 2>&1 <<'SQL'
\set VERBOSITY sqlstate
BEGIN;
SELECT 'taken=' || count(*) FROM unnest(xclaim.try_many(ARRAY(SELECT g::int8 FROM generate_series(1, 32) g))) t WHERE t;
SELECT 'next=' || xclaim.try(33::int8);
ROLLBACK;
SELECT 'used=' || capacity_used FROM xclaim.stats();
SQL
)" || true

TAKEN="$(sed -n 's/^taken=//p' <<<"$OUT")"
USED="$(sed -n 's/^used=//p' <<<"$OUT")"
echo "  try_many took ${TAKEN:-none} of 32, capacity_used after ROLLBACK: ${USED:-none}"
if xclaim_assert_eq "try_many takes all 32 keys" "$TAKEN" "32"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi
if grep -q '^ERROR:  53400$' <<<"$OUT" && ! grep -q '^next=' <<<"$OUT"; then
    echo "  PASS: the 33rd key fails with SQLSTATE 53400"
    PASS=$((PASS+1))
else
    echo "  FAIL: the 33rd key must fail with SQLSTATE 53400, output follows:" >&2
    printf '%s\n' "$OUT" | sed 's/^/    /' >&2
    FAIL=$((FAIL+1))
fi
if xclaim_assert_eq "capacity_used is 0 after ROLLBACK" "$USED" "0"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$((FAIL+1))

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
