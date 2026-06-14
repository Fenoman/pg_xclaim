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
#   --only <name>      Run only the named script (without .sh suffix).
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
        --only) ONLY_SCRIPT="$2"; shift 2 ;;
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
    # stale-owner reaper (debug injection path)
    "sigkill_stale"
    # owner reuse / token mismatch
    "owner_reuse"
    # per-backend peak watermark LOG hint
    "peak_warn"
    # debug scan stress
    "debug_scan_stress"
    # bulk concurrent
    "bulk_concurrent"
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
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        echo "[suite] SKIP (not found): $script"
        SKIP_SCRIPTS+=("$script")
        continue
    fi

    echo "================================================================"
    echo " Running: $script"
    echo "================================================================"

    T_START="$(python3 -c "import time; print(int(time.time() * 1000))")"
    if bash "$SCRIPT_PATH"; then
        T_END="$(python3 -c "import time; print(int(time.time() * 1000))")"
        ELAPSED=$(( T_END - T_START ))
        echo ""
        echo "[suite] PASS: $script  (${ELAPSED}ms)"
        PASS_SCRIPTS+=("$script:${ELAPSED}ms")
    else
        T_END="$(python3 -c "import time; print(int(time.time() * 1000))")"
        ELAPSED=$(( T_END - T_START ))
        echo ""
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
