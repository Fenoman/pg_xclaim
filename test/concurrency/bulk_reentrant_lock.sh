#!/usr/bin/env bash
# test/concurrency/bulk_reentrant_lock.sh
# xclaim.try_many holds a partition LWLock only for the run of slots in that
# partition, also when the rest of the array is keys the backend already
# holds.
#
# Scenario:
#   Session A holds 1,500,000 keys, then for 8 s calls try_many over the
#   same keys plus one new key each time. The new key takes the lock of its
#   partition, and the 1,500,000 held keys after it are reentrant hits.
#   Session B starts when A's calls start and for 5 s takes and commits
#   fresh keys of every partition, one per transaction, timing each
#   xclaim.try.
#
# Checks:
#   * every call of A takes all its keys
#   * B's 5 s lie inside A's calls (start and end times of both), B made
#     at least 1000 tries, and at least 2 calls of A started and finished
#     inside B's window
#   * fewer than 2 of B's tries take over 10 ms. A lock kept over the
#     reentrant tail of A's array would make B wait for that tail, tens of
#     ms, once per call of A, so at least 2 slow tries. One slow try is
#     allowed for a scheduler stall
#
# Attempts. A stall of the host (2 vCPUs shared with other work) can delay
# several of B's tries in one 5 s window. Such an attempt is repeated, up to
# 3 attempts, and the test passes on the first attempt with fewer than 2 slow
# tries. A lock held over the reentrant tail delays B in every attempt. The
# checks of the first two points end the test at once.
#
# HARD INVARIANTS: set -euo pipefail, /tmp cluster, ru_RU.UTF-8, trap cleanup
set -euo pipefail

SCRIPT="bulk_reentrant_lock"
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/_lib.sh"

XCLAIM_MAX_CLAIMS=2097152
pg_xclaim_start_temp_cluster "bulk_reentrant"
trap pg_xclaim_stop_temp_cluster EXIT INT TERM

xclaim_banner "$SCRIPT"

PASS=0
FAIL=0
HELD=1500000

pg_xclaim_psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE PROCEDURE probe(seconds numeric) LANGUAGE plpgsql AS $$
DECLARE
    b_start timestamptz := clock_timestamp();
    stop    timestamptz := clock_timestamp() + seconds * interval '1 second';
    t0      timestamptz;
    took    interval;
    worst   interval := interval '0';
    slow    int := 0;
    k       int8 := 100000000;
BEGIN
    WHILE clock_timestamp() < stop LOOP
        t0 := clock_timestamp();
        IF NOT xclaim.try(k) THEN
            RAISE EXCEPTION 'xclaim.try(%) returned false', k;
        END IF;
        took := clock_timestamp() - t0;
        IF took > worst THEN
            worst := took;
        END IF;
        IF took > interval '10 ms' THEN
            slow := slow + 1;
        END IF;
        COMMIT;
        k := k + 1;
    END LOOP;
    RAISE NOTICE 'b_start=% b_end=% tries=% slow=% worst_us=%',
        extract(epoch FROM b_start), extract(epoch FROM clock_timestamp()),
        k - 100000000, slow, (extract(epoch FROM worst) * 1000000)::bigint;
END $$;
SQL

echo "--- A holds $HELD keys ---"
xclaim_holder_open
xclaim_holder_sql "BEGIN;"
xclaim_holder_sql "SELECT 'held=' || count(*) FROM unnest(xclaim.try_many(ARRAY(SELECT g::int8 FROM generate_series(1, $HELD) g))) t WHERE t;"
if ! xclaim_holder_wait "^held=$HELD\$"; then
    echo "  FAIL: A did not take $HELD keys, output follows:" >&2
    sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
    exit 1
fi

OUTCOME=slow
for ATTEMPT in 1 2 3; do
    echo "--- attempt $ATTEMPT: A calls try_many over its keys plus one new key for 8 s, B takes keys for 5 s ---"
    # Each attempt's new keys are new to A's transaction, so each call
    # takes the lock of the new key's partition.
    NEW_BASE=$(( 5000000 + ATTEMPT * 1000000 ))
    xclaim_holder_sql "SELECT 'a_start_$ATTEMPT=' || extract(epoch FROM clock_timestamp());"
    xclaim_holder_sql "DO \$\$ DECLARE t0 timestamptz := clock_timestamp(); n int := 0; taken bigint; starts text := ''; BEGIN WHILE clock_timestamp() < t0 + interval '8 s' LOOP n := n + 1; starts := starts || ' ' || extract(epoch FROM clock_timestamp()); SELECT count(*) INTO taken FROM unnest(xclaim.try_many(ARRAY(SELECT g::int8 FROM generate_series(1, $HELD) g) || ($NEW_BASE + n)::int8)) t WHERE t; IF taken <> $HELD + 1 THEN RAISE EXCEPTION 'call % took % keys', n, taken; END IF; starts := starts || '-' || extract(epoch FROM clock_timestamp()); END LOOP; RAISE NOTICE 'a_calls_$ATTEMPT=% a_starts_$ATTEMPT=%', n, starts; END \$\$;"
    xclaim_holder_sql "SELECT 'a_end_$ATTEMPT=' || extract(epoch FROM clock_timestamp());"
    if ! xclaim_holder_wait "^a_start_$ATTEMPT="; then
        echo "  FAIL: A did not start its calls, output follows:" >&2
        sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
        OUTCOME=invalid
        break
    fi

    # B runs while A's calls run. It stops on its own after 5 s.
    B_OUT="$(pg_xclaim_psql -X -A -t -q -v ON_ERROR_STOP=1 -c "CALL probe(5);" 2>&1)" || true

    if ! xclaim_holder_wait "^a_end_$ATTEMPT="; then
        echo "  FAIL: A's calls did not finish, output follows:" >&2
        sed 's/^/    /' "$XCLAIM_HOLDER_OUT" >&2
        OUTCOME=invalid
        break
    fi

    A_START="$(sed -n "s/^a_start_$ATTEMPT=//p" "$XCLAIM_HOLDER_OUT")"
    A_END="$(sed -n "s/^a_end_$ATTEMPT=//p" "$XCLAIM_HOLDER_OUT")"
    A_CALLS="$(sed -n "s/.*a_calls_$ATTEMPT=\([0-9]*\).*/\1/p" "$XCLAIM_HOLDER_OUT")"
    A_STARTS="$(sed -n "s/.*a_starts_$ATTEMPT= *\([0-9. -]*\).*/\1/p" "$XCLAIM_HOLDER_OUT")"
    B_START="$(sed -n 's/.*b_start=\([0-9.]*\).*/\1/p' <<<"$B_OUT")"
    B_END="$(sed -n 's/.*b_end=\([0-9.]*\).*/\1/p' <<<"$B_OUT")"
    TRIES="$(sed -n 's/.*tries=\([0-9]*\).*/\1/p' <<<"$B_OUT")"
    SLOW="$(sed -n 's/.*slow=\([0-9]*\).*/\1/p' <<<"$B_OUT")"
    WORST_US="$(sed -n 's/.*worst_us=\([0-9]*\).*/\1/p' <<<"$B_OUT")"
    # Each call of A is "start-end": count the calls that ran entirely
    # inside B's window.
    IN_WINDOW="$(awk -v bs="${B_START:-0}" -v be="${B_END:-0}" '{ n = 0; for (i = 1; i <= NF; i++) { split($i, c, "-"); if (c[1] >= bs && c[2] != "" && c[2] <= be) n++ } print n }' <<<"${A_STARTS:-}")"
    echo "  A: ${A_CALLS:-none} calls, ${IN_WINDOW:-none} of them inside B's window, B: ${TRIES:-none} tries, ${SLOW:-none} over 10 ms, slowest ${WORST_US:-none} us"

    if grep -qE '^(ERROR|ОШИБКА):' "$XCLAIM_HOLDER_OUT" || [[ -z "$A_CALLS" || -z "$TRIES" || -z "$SLOW" || -z "$A_START" || -z "$A_END" || -z "$B_START" || -z "$B_END" ]]; then
        echo "  FAIL: A or B did not report or A hit an ERROR, outputs follow:" >&2
        sed 's/^/    A: /' "$XCLAIM_HOLDER_OUT" >&2
        printf '%s\n' "$B_OUT" | sed 's/^/    B: /' >&2
        OUTCOME=invalid
        break
    fi
    if ! awk -v as="$A_START" -v ae="$A_END" -v bs="$B_START" -v be="$B_END" \
             'BEGIN { exit !(bs >= as && be <= ae) }' || (( TRIES < 1000 || IN_WINDOW < 2 )); then
        echo "  FAIL: B's $TRIES tries ($B_START - $B_END) must lie inside A's calls ($A_START - $A_END), at least 1000, with at least 2 calls of A inside B's window (got $IN_WINDOW)" >&2
        OUTCOME=invalid
        break
    fi
    if (( SLOW < 2 )); then
        OUTCOME=pass
        break
    fi
    echo "  attempt $ATTEMPT: $SLOW of B's tries take over 10 ms (slowest $WORST_US us)"
done

xclaim_holder_sql "ROLLBACK;"
xclaim_holder_close

case "$OUTCOME" in
    pass)
        echo "  PASS: B's tries lie inside A's calls, $IN_WINDOW calls of A inside B's window"
        echo "  PASS: fewer than 2 of B's tries take over 10 ms in attempt $ATTEMPT"
        PASS=$((PASS+2))
        ;;
    slow)
        echo "  FAIL: in each of 3 attempts 2 or more of B's tries take over 10 ms: a partition lock held over A's reentrant keys" >&2
        FAIL=$((FAIL+1))
        ;;
    *)
        FAIL=$((FAIL+1))
        ;;
esac

xclaim_check_server_log "$SCRIPT" || FAIL=$((FAIL+1))

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
(( FAIL > 0 )) && exit 1 || exit 0
