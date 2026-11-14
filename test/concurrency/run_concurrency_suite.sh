#!/usr/bin/env bash
# test/concurrency/run_concurrency_suite.sh
# Driver: runs all pg_xclaim concurrency/stress tests, aggregates results.
#
# Usage:
#   ./run_concurrency_suite.sh [--skip-slow] [--only <script>]
#   PG_CONFIG=/path/to/pg_config ./run_concurrency_suite.sh
#
# Options:
#   --skip-slow        Skip the slow scripts: hot_standby_rejection.sh
#                      (requires pg_basebackup ~30-60s), stress_10x100k.sh
#                      (long running), and debug_scan_stress.sh.
#   --only <name>      Run only the named script (without .sh suffix). A
#                      name that is not in the registry below is an error.
#
# Exit: 0 if all tests PASS, non-zero if any FAIL.
#
# HARD INVARIANTS: set -euo pipefail, temp clusters only, ru_RU.UTF-8
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SKIP_SLOW=false
ONLY_SCRIPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-slow) SKIP_SLOW=true; shift ;;
        --only)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "--only needs a script name" >&2
                exit 1
            fi
            ONLY_SCRIPT="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Script registry -- execution order matters (fast before slow)
# ---------------------------------------------------------------------------
ALL_SCRIPTS=(
    # cross-session conflict
    "conflict"
    # commit release
    "commit_release"
    # rollback release
    "rollback_release"
    # error/abort release
    "error_release"
    # disconnect release
    "disconnect_release"
    # pg_terminate_backend release
    "terminate_backend_release"
    # backend-exit callback registered once per claiming backend
    "exit_callback_registration"
    # backend-exit callback releases leftover claims, publishes token 0
    "exit_callback_actions"
    # stale-owner reaper (debug injection path)
    "sigkill_stale"
    # owner reuse / token mismatch
    "owner_reuse"
    # per-backend peak watermark LOG hint
    "peak_warn"
    # the lowest accepted settings serve claims up to capacity
    "min_config"
    # LWLockAcquire ERROR in xclaim.try, session_reset from a hook in try_many
    "hook_error_paths"
    # out of memory while the local set grows (Linux only)
    "local_grow_oom"
    # autonomous transactions refused, parent claims kept (Postgres Pro Enterprise only)
    "autonomous_xact"
    # live_capacity equals the shared rows after a terminate inside try_many
    "bulk_fatal_capacity"
    # out-of-memory cleanup at transaction end is linear (Linux only)
    "cleanup_oom_fallback"
    # a one-claim transaction costs the same whatever the local set size
    "short_xact_cost"
    # debug scan stress
    "debug_scan_stress"
    # bulk concurrent
    "bulk_concurrent"
    # try_many holds a partition lock only for its run, reentrant tail included
    "bulk_reentrant_lock"
    # wait-event observability
    "wait_event_check"
    # grouped cleanup 50k <100ms (HARD gate)
    "grouped_cleanup_50k"
    # hot-standby rejection (slow: pg_basebackup)
    "hot_standby_rejection"
    # stress 10x100k (slow)
    "stress_10x100k"
)

SLOW_SCRIPTS=("hot_standby_rejection" "stress_10x100k" "debug_scan_stress")

# ---------------------------------------------------------------------------
# Filter scripts
# ---------------------------------------------------------------------------
SCRIPTS_TO_RUN=()
for s in "${ALL_SCRIPTS[@]}"; do
    if [[ -n "$ONLY_SCRIPT" ]]; then
        [[ "$s" == "$ONLY_SCRIPT" ]] && SCRIPTS_TO_RUN+=("$s")
        continue
    fi
    if $SKIP_SLOW; then
        IS_SLOW=false
        for slow in "${SLOW_SCRIPTS[@]}"; do
            [[ "$s" == "$slow" ]] && IS_SLOW=true
        done
        $IS_SLOW && echo "[suite] SKIP (--skip-slow): $s" && continue
    fi
    SCRIPTS_TO_RUN+=("$s")
done

# --only must select exactly one registered script: a misspelled name would
# otherwise run nothing and exit 0.
if [[ -n "$ONLY_SCRIPT" ]] && (( ${#SCRIPTS_TO_RUN[@]} != 1 )); then
    echo "[suite] FAIL: --only '$ONLY_SCRIPT' selects ${#SCRIPTS_TO_RUN[@]} registered scripts, expected 1" >&2
    echo "[suite] registered: ${ALL_SCRIPTS[*]}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Run each script
# ---------------------------------------------------------------------------
PASS_SCRIPTS=()
FAIL_SCRIPTS=()
SKIP_SCRIPTS=()
SUITE_START_MS="$(python3 -c "import time; print(int(time.time() * 1000))")"

echo "================================================================"
echo " pg_xclaim concurrency suite"
echo " Scripts: ${#SCRIPTS_TO_RUN[@]} of ${#ALL_SCRIPTS[@]}"
echo " Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "================================================================"
echo ""

for script in "${SCRIPTS_TO_RUN[@]}"; do
    SCRIPT_PATH="$SUITE_DIR/${script}.sh"
    # A registered script missing from disk is a FAIL: skipping it would let
    # the suite pass without running the test.
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        echo "[suite] FAIL (not found): $script" >&2
        FAIL_SCRIPTS+=("$script:not found")
        continue
    fi

    echo "================================================================"
    echo " Running: $script"
    echo "================================================================"

    T_START="$(python3 -c "import time; print(int(time.time() * 1000))")"
    # Exit code 77 means the script does not run on this platform.
    if bash "$SCRIPT_PATH"; then rc=0; else rc=$?; fi
    T_END="$(python3 -c "import time; print(int(time.time() * 1000))")"
    ELAPSED=$(( T_END - T_START ))
    echo ""
    if (( rc == 0 )); then
        echo "[suite] PASS: $script  (${ELAPSED}ms)"
        PASS_SCRIPTS+=("$script:${ELAPSED}ms")
    elif (( rc == 77 )); then
        echo "[suite] SKIP (not supported here): $script"
        SKIP_SCRIPTS+=("$script")
    else
        echo "[suite] FAIL: $script  (${ELAPSED}ms)" >&2
        FAIL_SCRIPTS+=("$script:${ELAPSED}ms")
    fi
    echo ""
done

SUITE_END_MS="$(python3 -c "import time; print(int(time.time() * 1000))")"
SUITE_TOTAL_MS=$(( SUITE_END_MS - SUITE_START_MS ))

# ---------------------------------------------------------------------------
# Aggregate summary
# ---------------------------------------------------------------------------
echo "================================================================"
echo " SUITE AGGREGATE RESULTS"
echo " Total wall time: ${SUITE_TOTAL_MS}ms"
echo "================================================================"
echo ""
echo "PASSED (${#PASS_SCRIPTS[@]}):"
for s in "${PASS_SCRIPTS[@]}"; do echo "  PASS: $s"; done

if [[ ${#SKIP_SCRIPTS[@]} -gt 0 ]]; then
    echo ""
    echo "SKIPPED (${#SKIP_SCRIPTS[@]}):"
    for s in "${SKIP_SCRIPTS[@]}"; do echo "  SKIP: $s"; done
fi

if [[ ${#FAIL_SCRIPTS[@]} -gt 0 ]]; then
    echo ""
    echo "FAILED (${#FAIL_SCRIPTS[@]}):"
    for s in "${FAIL_SCRIPTS[@]}"; do echo "  FAIL: $s"; done
fi

echo ""
echo "================================================================"
echo " RESULT: PASS=${#PASS_SCRIPTS[@]} FAIL=${#FAIL_SCRIPTS[@]} SKIP=${#SKIP_SCRIPTS[@]}"
echo "================================================================"

# ---------------------------------------------------------------------------
# CSV summary row for CI consumption
# ---------------------------------------------------------------------------
echo ""
echo "CSV_SUITE_SUMMARY:"
echo "TIMESTAMP,SUITE,TOTAL_SCRIPTS,PASS,FAIL,SKIP,WALL_MS"
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),concurrency,${#SCRIPTS_TO_RUN[@]},${#PASS_SCRIPTS[@]},${#FAIL_SCRIPTS[@]},${#SKIP_SCRIPTS[@]},$SUITE_TOTAL_MS"

# Exit non-zero if any failures
if [[ ${#FAIL_SCRIPTS[@]} -gt 0 ]]; then
    exit 1
fi
exit 0
