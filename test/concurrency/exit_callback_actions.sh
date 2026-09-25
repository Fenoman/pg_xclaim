#!/usr/bin/env bash
# test/concurrency/exit_callback_actions.sh
# What the backend-exit callback (xclaim_shmem_exit_cb) does at exit.
#
# Test 1: claims the xact callback could not release are released at exit.
#   Backend A holds (1, 900) in an open transaction and disconnects with
#   xclaim_test_hooks.fail_abort_at_exit on. The hooks module, preloaded
#   after pg_xclaim, fails the abort at exit, the ERROR becomes FATAL and
#   pg_xclaim's xact callback does not run, so the claim reaches the exit
#   callback. Right after A is gone, and before any backend asks for the
#   key, the row must be gone and reaped_stale unchanged: the lazy reaper
#   would otherwise hide a missing release on the next conflicting claim.
#
# Test 2: the exit callback publishes owner_token 0 for the exiting backend.
#   Backend B holds (1, 901), so its token is published in its slot. After
#   B exits, the slot must read 0. On PG 16 an exited backend's pid stays
#   in its PGPROC slot, and this token is what lets the stale-owner reaper
#   take over rows such a backend left behind.
#
# The hooks module (test/modules/xclaim_test_hooks) is built for the
# PG_CONFIG under test by xclaim_build_test_hooks in _lib.sh. The cluster
# runs with restart_after_crash = off: a crash in the exit callback would
# otherwise reinitialize shared memory, which empties both the rows and the
# token slots these checks read, and the checks would pass.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="exit_callback_actions"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

trap pg_xclaim_stop_temp_cluster EXIT INT TERM
XCLAIM_EXTRA_CONF="restart_after_crash = off"
xclaim_build_test_hooks
pg_xclaim_start_temp_cluster "exit_actions"
xclaim_create_test_hooks_functions

xclaim_banner "$SCRIPT"

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
    tail -n 20 "$PGDATA/server.log" 2>/dev/null | sed 's/^/    /' >&2 || true
}

# ---------------------------------------------------------------------------
# Test 1: exit releases a claim the xact callback left behind
# ---------------------------------------------------------------------------
echo "--- Test 1: exit releases a claim the xact callback left behind ---"

REAPED_BEFORE="$(q "SELECT reaped_stale FROM xclaim.stats();")"

A_OUT="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 2>&1 <<'SQL'
SET xclaim_test_hooks.fail_abort_at_exit = on;
BEGIN;
SELECT 'try=' || xclaim.try(1, 900);
SELECT 'pid=' || pg_backend_pid();
SQL
)"
A_TRY="$(sed -n 's/^try=//p' <<<"$A_OUT")"
A_PID="$(sed -n 's/^pid=//p' <<<"$A_OUT")"
echo "  A: try(1, 900) = $A_TRY, pid = $A_PID, disconnected with the transaction open"

if [[ "$A_TRY" != "true" ]] || [[ -z "$A_PID" ]]; then
    fail "exit_releases_left_behind" "setup" "try=$A_TRY pid=$A_PID" "backend A must hold (1, 900)"
elif ! xclaim_wait_backend_gone "$A_PID"; then
    fail "exit_releases_left_behind" "setup" "pid $A_PID alive" "backend A must exit within 10s"
elif ! server_alive; then
    server_down "exit_releases_left_behind"
else
    # The abort at exit must really have failed, otherwise pg_xclaim's xact
    # callback released the claim and the exit callback had nothing to do.
    SKIPPED="$(grep -c "xclaim_test_hooks: failing the abort at backend exit" "$PGDATA/server.log" || true)"
    if [[ "$SKIPPED" -ge 1 ]]; then
        pass "abort_at_exit_failed" "log_lines" "$SKIPPED" "the hooks module failed the abort at A's exit"
    else
        fail "abort_at_exit_failed" "log_lines" "$SKIPPED" "the hooks module must fail the abort at A's exit"
    fi

    ROWS="$(q "SELECT count(*) FROM xclaim.debug() WHERE key = 900;")"
    REAPED_AFTER="$(q "SELECT reaped_stale FROM xclaim.stats();")"
    echo "  after A exited: rows for key 900 = $ROWS, reaped_stale $REAPED_BEFORE -> $REAPED_AFTER"
    if [[ "$ROWS" == "0" ]]; then
        pass "exit_releases_left_behind" "rows" "$ROWS" "A's claim was released at exit"
    else
        fail "exit_releases_left_behind" "rows" "$ROWS" "A's claim must be released at exit"
    fi
    if [[ "$REAPED_AFTER" == "$REAPED_BEFORE" ]]; then
        pass "no_reap_needed" "reaped_stale" "$REAPED_AFTER" "no stale-owner reap was involved"
    else
        fail "no_reap_needed" "reaped_stale" "$REAPED_AFTER" "reaped_stale must stay at $REAPED_BEFORE"
    fi
fi

# ---------------------------------------------------------------------------
# Test 2: exit publishes owner_token 0
# ---------------------------------------------------------------------------
echo "--- Test 2: exit publishes owner_token 0 ---"

if ! server_alive; then
    server_down "exit_publishes_token_0"
else
    xclaim_holder_open
    xclaim_holder_sql "BEGIN;"
    xclaim_holder_sql "SELECT 'try=' || xclaim.try(1, 901);"
    xclaim_holder_sql "SELECT 'pid=' || pg_backend_pid();"

    if ! xclaim_holder_wait '^pid='; then
        xclaim_holder_close
        fail "exit_publishes_token_0" "setup" "$(tr '\n' ' ' < "$XCLAIM_HOLDER_OUT")" "backend B must hold (1, 901)"
    else
        B_TRY="$(sed -n 's/^try=//p' "$XCLAIM_HOLDER_OUT")"
        B_PID="$(sed -n 's/^pid=//p' "$XCLAIM_HOLDER_OUT")"
        B_ROW="$(q "SELECT owner_procno || ' ' || owner_token FROM xclaim.debug() WHERE key = 901;")"
        read -r B_PROCNO B_TOKEN <<<"${B_ROW:-x x}"
        PUB_ALIVE=""
        [[ -n "$B_ROW" ]] && PUB_ALIVE="$(q "SELECT xclaim_test_published_token($B_PROCNO);")"
        xclaim_holder_sql "COMMIT;"
        xclaim_holder_close
        echo "  B: try(1, 901) = $B_TRY, pid = $B_PID, procno = $B_PROCNO, row token = $B_TOKEN, published while alive = $PUB_ALIVE"
        if [[ "$B_TRY" == "true" ]] && [[ -n "$B_ROW" ]] && [[ "$PUB_ALIVE" == "$B_TOKEN" ]]; then
            pass "published_token_read" "token" "$PUB_ALIVE" "the hooks module reads B's published token"
        else
            fail "published_token_read" "token" "${PUB_ALIVE:-none}" "published token must equal B's row token ${B_TOKEN}"
        fi
        if [[ -z "$B_ROW" ]] || [[ -z "$B_PID" ]] || ! xclaim_wait_backend_gone "$B_PID"; then
            fail "exit_publishes_token_0" "setup" "pid=$B_PID" "backend B must hold the claim and exit within 10s"
        elif ! server_alive; then
            server_down "exit_publishes_token_0"
        else
            PUB_AFTER="$(q "SELECT xclaim_test_published_token($B_PROCNO);")"
            echo "  after B exited: published token = $PUB_AFTER"
            if [[ "$PUB_AFTER" == "0" ]]; then
                pass "exit_publishes_token_0" "token" "$PUB_AFTER" "B's slot publishes token 0 after exit"
            else
                fail "exit_publishes_token_0" "token" "$PUB_AFTER" "B's slot must publish token 0 after exit"
            fi
        fi
    fi
fi

xclaim_check_server_log "$SCRIPT" "xclaim_test_hooks: failing the abort at backend exit" \
    || FAIL=$(( FAIL + 1 ))

echo ""
echo "=== CSV SUMMARY ==="
echo "TIMESTAMP,SCRIPT,TEST,RESULT,METRIC_NAME,METRIC_VALUE,NOTES"
for row in "${CSV_ROWS[@]}"; do echo "$row"; done
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
