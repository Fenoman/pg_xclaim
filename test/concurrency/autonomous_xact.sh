#!/usr/bin/env bash
# test/concurrency/autonomous_xact.sh
# Autonomous transactions of Postgres Pro Enterprise are refused while
# pg_xclaim is preloaded, and a refused one leaves the claims of its parent
# transaction held.
#
# Why. An autonomous transaction runs inside its parent in the same backend,
# and its COMMIT or ABORT reaches pg_xclaim's xact callback as an ordinary
# transaction end. The cleanup would release every claim of the backend,
# the parent's too, and another backend could take a key the parent still
# relies on. pg_xclaim marks itself incompatible with autonomous
# transactions, so the server refuses to start one.
#
#   Test 1: a PL/pgSQL autonomous block inside a transaction that holds a
#           claim is refused. The parent catches the ERROR, keeps its claim,
#           and another session cannot take the key until the parent ends.
#   Test 2: BEGIN AUTONOMOUS in SQL is refused with the same message.
#
# Servers without the Enterprise pg_current_atx_nest_level API exit with 77.
# This includes Tantor SE, whose autonomous SQL uses a separate backend.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="autonomous_xact"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

xclaim_banner "$SCRIPT"

trap pg_xclaim_stop_temp_cluster EXIT INT TERM
pg_xclaim_start_temp_cluster "autonomous_xact"

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

if [[ "$(q "SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'pg_current_atx_nest_level');")" != "t" ]]; then
    echo "  SKIP: the server has no Enterprise autonomous-transaction API"
    exit 77
fi

REFUSAL="pg_xclaim extension is incompatible with autonomous transactions"

# ---------------------------------------------------------------------------
# Test 1: a refused autonomous block keeps the parent's claim
# ---------------------------------------------------------------------------
echo "--- Test 1: an autonomous block is refused and the parent keeps its claim ---"

xclaim_holder_open
xclaim_holder_sql "SET lc_messages = 'C';"
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'claim=' || xclaim.try(1, 1000);"
xclaim_holder_sql "DO \$\$
BEGIN
    BEGIN
        BEGIN AUTONOMOUS
            PERFORM 1;
        END;
        RAISE NOTICE 'autonomous=ran';
    EXCEPTION WHEN others THEN
        RAISE NOTICE 'autonomous=refused: %', SQLERRM;
    END;
END \$\$;"
xclaim_holder_sql "SELECT 'held=' || xclaim.count();"
xclaim_holder_wait '^held=' || true

OTHER_WHILE_HELD="$(q "SELECT xclaim.try(1, 1000);" 2>&1 || true)"

xclaim_holder_sql "COMMIT;"
xclaim_holder_sql "SELECT 'after=' || xclaim.count();"
xclaim_holder_wait '^after=' || true
xclaim_holder_close

OTHER_AFTER="$(q "SELECT xclaim.try(1, 1000);" 2>&1 || true)"

CLAIM="$(sed -n 's/^claim=//p' "$XCLAIM_HOLDER_OUT")"
AUTONOMOUS="$(sed -n 's/^NOTICE: *autonomous=//p' "$XCLAIM_HOLDER_OUT")"
HELD="$(sed -n 's/^held=//p' "$XCLAIM_HOLDER_OUT")"
AFTER="$(sed -n 's/^after=//p' "$XCLAIM_HOLDER_OUT")"
echo "  claim: $CLAIM, autonomous block: ${AUTONOMOUS:-none}, held: $HELD"
echo "  other session while held: $OTHER_WHILE_HELD, after COMMIT: $AFTER, other session then: $OTHER_AFTER"

if [[ "$AUTONOMOUS" != "refused: $REFUSAL" ]]; then
    fail "autonomous_block" "autonomous" "${AUTONOMOUS:-none}" "the autonomous block must be refused with \"$REFUSAL\""
elif [[ "$CLAIM" == "true" && "$HELD" == "1" && "$OTHER_WHILE_HELD" == "f" && "$AFTER" == "0" && "$OTHER_AFTER" == "t" ]]; then
    pass "autonomous_block" "held" "$HELD" "the refused autonomous block left the parent's claim held until COMMIT"
else
    fail "autonomous_block" "state" "claim=$CLAIM held=$HELD other=$OTHER_WHILE_HELD after=$AFTER other_after=$OTHER_AFTER" "the parent must keep its claim until COMMIT"
fi

# ---------------------------------------------------------------------------
# Test 2: BEGIN AUTONOMOUS in SQL is refused
# ---------------------------------------------------------------------------
echo "--- Test 2: BEGIN AUTONOMOUS is refused ---"

SQL_OUT="$(pg_xclaim_psql -X -A -t -q 2>&1 <<'SQL' || true
SET lc_messages = 'C';
BEGIN;
SELECT xclaim.try(1, 1001);
BEGIN AUTONOMOUS;
ROLLBACK;
SQL
)"
SQL_ERROR="$(printf '%s\n' "$SQL_OUT" | sed -n 's/^.*ERROR: *//p' | head -1)"
echo "  BEGIN AUTONOMOUS: ${SQL_ERROR:-no error}"
if [[ "$SQL_ERROR" == "$REFUSAL" ]]; then
    pass "begin_autonomous" "error" "refused" "BEGIN AUTONOMOUS is refused while pg_xclaim is preloaded"
else
    fail "begin_autonomous" "error" "${SQL_ERROR:-none}" "BEGIN AUTONOMOUS must be refused with \"$REFUSAL\""
fi

ROWS="$(q "SELECT count(*) FROM xclaim.debug_snapshot();")"
if [[ "$ROWS" == "0" ]]; then
    pass "no_leftover" "rows" "$ROWS" "no claim is left in shared memory"
else
    fail "no_leftover" "rows" "$ROWS" "no claim may be left in shared memory"
fi

xclaim_check_server_log "$SCRIPT" || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
