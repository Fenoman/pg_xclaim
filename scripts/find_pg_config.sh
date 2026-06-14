#!/usr/bin/env bash
# scripts/find_pg_config.sh
#
# Discover a usable `pg_config` binary for a given PostgreSQL major version.
#
# Usage:
#   scripts/find_pg_config.sh <16|17|18>             # echo single path, exit 1 if missing
#   scripts/find_pg_config.sh --list                 # echo MAJOR:PATH lines for all found
#   scripts/find_pg_config.sh --majors               # echo only majors found, space-separated
#
# Discovery order:
#   1. Explicit env var override:
#        PG16_CONFIG / PG17_CONFIG / PG18_CONFIG
#      (only the per-major variables are read; a generic PG_CONFIG env is NOT
#       consulted here -- callers that want it pass it as the first argument.)
#   2. macOS Homebrew opt symlink:
#        /opt/homebrew/opt/postgresql@<v>/bin/pg_config        (Apple Silicon)
#        /usr/local/opt/postgresql@<v>/bin/pg_config           (Intel)
#   3. macOS Homebrew Cellar (versioned):
#        /opt/homebrew/Cellar/postgresql@<v>/*/bin/pg_config
#        /usr/local/Cellar/postgresql@<v>/*/bin/pg_config
#   4. Linux Debian/Ubuntu apt layout:
#        /usr/lib/postgresql/<v>/bin/pg_config
#   5. Generic PATH lookup of `pg_config` (only used if its --version matches <v>).
#
# Exit codes:
#   0  -- found and printed
#   1  -- not found (also for empty --list)
#   2  -- bad usage
#
# HARD INVARIANTS:
#   - set -euo pipefail
#   - Never invokes any user cluster; pure filesystem + binary probe.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  find_pg_config.sh <16|17|18>
  find_pg_config.sh --list
  find_pg_config.sh --majors
EOF
    exit 2
}

# Test whether $1 is an executable pg_config whose --version reports major $2.
_xclaim_probe_pg_config_major() {
    local path="$1" want_major="$2"
    [[ -n "$path" ]] || return 1
    [[ -x "$path" ]] || return 1
    local out major
    out="$("$path" --version 2>/dev/null || true)"
    # `pg_config --version` output: "PostgreSQL 17.10 (Homebrew)" / "PostgreSQL 17.10".
    # Strip suffixes (.X.Y, devel, betaN, rcN) -> integer major.
    major="$(printf '%s\n' "$out" \
        | awk '{print $2}' \
        | awk -F. '{print $1}' \
        | tr -dc '0-9' || true)"
    [[ -n "$major" ]] || return 1
    [[ "$major" == "$want_major" ]]
}

# Probe a single major version against env override + candidate paths.
# Echo first match and return 0; return 1 if none.
_xclaim_find_for_major() {
    local v="$1"
    local env_var="PG${v}_CONFIG"
    local cand candidates=()

    # 1. Env var override
    if [[ -n "${!env_var:-}" ]]; then
        if _xclaim_probe_pg_config_major "${!env_var}" "$v"; then
            printf '%s\n' "${!env_var}"
            return 0
        fi
        # Env override that's wrong for the requested major is a hard-fail
        # signal -- but we still try other candidates so users can override
        # one slot without breaking siblings.
    fi

    # 2-3. macOS candidates (Apple Silicon + Intel; opt symlink + Cellar).
    candidates=(
        "/opt/homebrew/opt/postgresql@${v}/bin/pg_config"
        "/usr/local/opt/postgresql@${v}/bin/pg_config"
    )
    # Cellar versioned dirs -- expand only if base exists (avoid spurious globs).
    local cellar_base
    for cellar_base in \
        "/opt/homebrew/Cellar/postgresql@${v}" \
        "/usr/local/Cellar/postgresql@${v}"
    do
        if [[ -d "$cellar_base" ]]; then
            local sub
            for sub in "$cellar_base"/*/bin/pg_config; do
                [[ -e "$sub" ]] && candidates+=("$sub")
            done
        fi
    done

    # 4. Linux apt layout.
    candidates+=("/usr/lib/postgresql/${v}/bin/pg_config")

    for cand in "${candidates[@]}"; do
        if _xclaim_probe_pg_config_major "$cand" "$v"; then
            printf '%s\n' "$cand"
            return 0
        fi
    done

    # 5. Generic PATH fallback -- only accept if its --version matches.
    local on_path
    if on_path="$(command -v pg_config 2>/dev/null)"; then
        if _xclaim_probe_pg_config_major "$on_path" "$v"; then
            printf '%s\n' "$on_path"
            return 0
        fi
    fi

    return 1
}

[[ $# -ge 1 ]] || usage

case "$1" in
    --list)
        # Emit "MAJOR:PATH" lines for every discovered major (16/17/18).
        any=0
        for v in 16 17 18; do
            if path="$(_xclaim_find_for_major "$v")"; then
                printf '%s:%s\n' "$v" "$path"
                any=1
            fi
        done
        [[ $any -eq 1 ]] || exit 1
        exit 0
        ;;
    --majors)
        majors=()
        for v in 16 17 18; do
            if _xclaim_find_for_major "$v" >/dev/null; then
                majors+=("$v")
            fi
        done
        [[ ${#majors[@]} -gt 0 ]] || exit 1
        printf '%s\n' "${majors[*]}"
        exit 0
        ;;
    16|17|18)
        if path="$(_xclaim_find_for_major "$1")"; then
            printf '%s\n' "$path"
            exit 0
        fi
        echo "pg_config for PG $1 not found (set PG${1}_CONFIG to override)" >&2
        exit 1
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage
        ;;
esac
