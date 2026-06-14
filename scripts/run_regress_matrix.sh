#!/usr/bin/env bash
# scripts/run_regress_matrix.sh
#
# Driver for full regression + capacity + non-preload test suite across
# the available PG matrix (16 / 17 / 18).
#
# For each version:
#   1. clean build (`make clean && make && sudo? make install`)
#   2. `make installcheck`
#   3. `make installcheck-capacity`
#   4. `make installcheck-nonpreload`
#   5. `make installcheck-lwlocks`
#   6. `bash scripts/smoke_gate.sh`
#   7. (optional) `bash test/concurrency/run_concurrency_suite.sh --skip-slow`
#
# Aggregates pass/fail across versions; exits non-zero if ANY slot fails.
#
# Usage:
#   scripts/run_regress_matrix.sh                 # auto-discover all majors
#   scripts/run_regress_matrix.sh 17              # single version
#   scripts/run_regress_matrix.sh 16 17 18        # explicit list
#   scripts/run_regress_matrix.sh --skip-install  # skip `make install` step
#                                                  # (e.g. for non-sudo CI runs)
#   scripts/run_regress_matrix.sh --with-concurrency
#                                                  # also run concurrency suite
#
# Environment overrides:
#   PG16_CONFIG, PG17_CONFIG, PG18_CONFIG -- pin specific paths
#   SUDO=sudo -- prefix `make install` (default: empty for Homebrew, "sudo" on Linux)
#   MAKE_JOBS=N -- parallel build jobs (default: nproc/sysctl)
#
# HARD INVARIANTS:
#   - set -euo pipefail
#   - delegates temp-cluster lifetime to `make installcheck` (pg_regress
#     --temp-instance under /tmp -- already configured in Makefile)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SKIP_INSTALL=0
WITH_CONCURRENCY=0
EXPLICIT_VERSIONS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-install)     SKIP_INSTALL=1; shift ;;
        --with-concurrency) WITH_CONCURRENCY=1; shift ;;
        16|17|18)           EXPLICIT_VERSIONS+=("$1"); shift ;;
        -h|--help)
            sed -n '1,40p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Determine which majors to run
# ---------------------------------------------------------------------------
if [[ ${#EXPLICIT_VERSIONS[@]} -eq 0 ]]; then
    if listing="$("$SCRIPT_DIR/find_pg_config.sh" --majors 2>/dev/null)"; then
        # shellcheck disable=SC2206
        EXPLICIT_VERSIONS=($listing)
    else
        echo "no PG installations discovered; set PG{16,17,18}_CONFIG or pass major" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Build job count
# ---------------------------------------------------------------------------
if [[ -z "${MAKE_JOBS:-}" ]]; then
    if command -v nproc >/dev/null 2>&1; then
        MAKE_JOBS="$(nproc)"
    elif command -v sysctl >/dev/null 2>&1; then
        MAKE_JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
    else
        MAKE_JOBS=2
    fi
fi

# Default SUDO: empty on macOS (Homebrew prefix is user-writable), "sudo" on
# linux for /usr/lib/postgresql install dirs.
if [[ -z "${SUDO+x}" ]]; then
    case "$(uname -s)" in
        Linux)  SUDO="sudo" ;;
        Darwin) SUDO=""     ;;
        *)      SUDO=""     ;;
    esac
fi

# ---------------------------------------------------------------------------
# Per-version runner
# ---------------------------------------------------------------------------
RESULTS=()       # "<v>:<step>:<rc>"

run_step() {
    local v="$1" label="$2" rc=0
    shift 2
    echo "================================================================"
    echo " [$v] $label"
    echo "    cmd: $*"
    echo "================================================================"
    if "$@"; then
        rc=0
    else
        rc=$?
    fi
    RESULTS+=("$v:$label:$rc")
    return $rc
}

run_for_major() {
    local v="$1"
    local pgc
    if ! pgc="$("$SCRIPT_DIR/find_pg_config.sh" "$v")"; then
        echo "[$v] pg_config not found -- skipping" >&2
        RESULTS+=("$v:discover:1")
        return 1
    fi
    echo "[$v] using pg_config: $pgc"

    pushd "$ROOT_DIR" >/dev/null

    # Clean build with strict flags (-Wall -Wextra -Werror in PG_CFLAGS).
    run_step "$v" "build" \
        bash -c "make PG_CONFIG=$pgc clean && make PG_CONFIG=$pgc -j$MAKE_JOBS" \
        || { popd >/dev/null; return 1; }

    # Install (sudo on Linux, plain on macOS).
    if [[ "$SKIP_INSTALL" -eq 0 ]]; then
        if [[ -n "$SUDO" ]]; then
            run_step "$v" "install" $SUDO make PG_CONFIG="$pgc" install \
                || { popd >/dev/null; return 1; }
        else
            run_step "$v" "install" make PG_CONFIG="$pgc" install \
                || { popd >/dev/null; return 1; }
        fi
    fi

    # Smoke gate
    run_step "$v" "smoke_gate"  bash "$SCRIPT_DIR/smoke_gate.sh" "$pgc" || true
    run_step "$v" "smoke_gate_no_preload" \
        bash "$SCRIPT_DIR/smoke_gate_no_preload.sh" "$pgc" || true
    run_step "$v" "smoke_gate_multi_preload" \
        bash "$SCRIPT_DIR/smoke_gate_multi_preload.sh" "$pgc" || true

    # Regression / capacity / non-preload / lwlocks.
    run_step "$v" "installcheck"             make PG_CONFIG="$pgc" installcheck             || true
    run_step "$v" "installcheck-capacity"    make PG_CONFIG="$pgc" installcheck-capacity    || true
    run_step "$v" "installcheck-nonpreload"  make PG_CONFIG="$pgc" installcheck-nonpreload  || true
    run_step "$v" "installcheck-lwlocks"     make PG_CONFIG="$pgc" installcheck-lwlocks     || true

    # Optional concurrency suite. Heavy -- opt-in.
    if [[ "$WITH_CONCURRENCY" -eq 1 ]]; then
        run_step "$v" "concurrency" \
            env PG_CONFIG="$pgc" \
            bash "$ROOT_DIR/test/concurrency/run_concurrency_suite.sh" --skip-slow \
            || true
    fi

    popd >/dev/null
}

for v in "${EXPLICIT_VERSIONS[@]}"; do
    run_for_major "$v" || true
done

# ---------------------------------------------------------------------------
# Aggregate results
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " REGRESS MATRIX SUMMARY"
echo "================================================================"

FAILED_COUNT=0
for r in "${RESULTS[@]}"; do
    rc="${r##*:}"
    if [[ "$rc" -eq 0 ]]; then
        echo "  PASS  $r"
    else
        echo "  FAIL  $r" >&2
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done
echo ""
echo "Total steps: ${#RESULTS[@]}    Failures: $FAILED_COUNT"

[[ "$FAILED_COUNT" -eq 0 ]] || exit 1
exit 0
