#!/usr/bin/env bash
# scripts/bench_alternatives.sh
#
# Honest synthetic comparison: pg_xclaim vs claim-table (INSERT ON CONFLICT)
# vs row locks (FOR UPDATE NOWAIT). The benchmark exists to show where each
# approach wins -- not to "prove" pg_xclaim. Run on your own workload before
# making decisions.
#
# Workload:
#   - Pool of 1M synthetic accounts.
#   - For each scenario: each backend runs ITERS transactions, each acquiring
#     K random non-overlapping keys, then ROLLBACK to release.
#   - Six implementations per scenario:
#       A) pg_xclaim:        SELECT xclaim.try_many(1, $1::int4[])
#       B) claim-table:      INSERT INTO claims_t(account_id) SELECT unnest($1)
#          (UNLOGGED         ON CONFLICT (account_id) DO NOTHING RETURNING ...
#           unsorted)
#       C) row locks:        SELECT account_id FROM accounts_synth
#                            WHERE account_id = ANY($1::int4[]) FOR UPDATE NOWAIT
#       D) claim-table:      same as B, but a LOGGED (WAL-emitting) table.
#          (LOGGED unsorted)
#       E) claim-table:      LOGGED table, keys sorted (ORDER BY) before INSERT
#          (LOGGED sorted)   to suppress deadlocks via global lock ordering.
#       F) claim-table:      UNLOGGED table, keys sorted before INSERT --
#          (UNLOGGED sorted) isolates SORT cost from WAL cost vs E.
#   - Single-backend characterization (N=1) and concurrent (N=8) variants.
#
# Metrics per (impl, N, K):
#   - throughput: total transactions / wall-clock seconds across all backends
#   - latency: p50 / p95 over per-iteration wall-clock samples
#   - wal_bytes: pg_current_wal_lsn delta across the whole scenario
#   - capacity_observed (impl=A only): xclaim.stats().capacity_used peak
#
# Output:
#   docs/perf/bench-alternatives-YYYYMMDD-pg<major>.csv
#
# Usage:
#   scripts/bench_alternatives.sh                       # auto pg_config 17
#   scripts/bench_alternatives.sh /path/to/pg_config    # explicit
#   ITERS=10 K_VALUES="1000,10000" N_VALUES="1,8" scripts/bench_alternatives.sh
#
# Exit:
#   0   benchmark completed; CSV written
#   1   bench infrastructure failure
#
# HARD INVARIANTS:
#   - set -euo pipefail; trap cleanup
#   - /tmp temp cluster only; never touch user clusters
#   - locale ru_RU.UTF-8

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PG_CONFIG_BIN="${1:-${PG_CONFIG:-}}"
if [[ -z "$PG_CONFIG_BIN" ]]; then
    PG_CONFIG_BIN="$("$SCRIPT_DIR/find_pg_config.sh" 17 2>/dev/null || true)"
fi
[[ -x "$PG_CONFIG_BIN" ]] || { echo "no usable pg_config: $PG_CONFIG_BIN" >&2; exit 1; }

PG_MAJOR="$("$PG_CONFIG_BIN" --version 2>/dev/null | awk '{print $2}' | awk -F. '{print $1}')"
PERF_DIR="$ROOT_DIR/docs/perf"
mkdir -p "$PERF_DIR"
DATE_TAG="$(date -u +%Y%m%d)"

# Locale preflight: initdb dies with an opaque error if ru_RU.UTF-8 is
# absent. Probe up-front so the failure message names the actual cause.
if ! { locale -a 2>/dev/null || true; } | grep -qiE "ru_RU\.(UTF-8|utf8)"; then
    echo "bench_alternatives: locale ru_RU.UTF-8 not installed (required by initdb)" >&2
    echo "  install it (e.g. 'localedef -i ru_RU -f UTF-8 ru_RU.UTF-8') and retry" >&2
    exit 1
fi

ITERS="${ITERS:-200}"
IFS=',' read -r -a K_VALUES <<< "${K_VALUES:-1000,10000,100000}"
IFS=',' read -r -a N_VALUES <<< "${N_VALUES:-1,8}"
ACCOUNT_POOL="${ACCOUNT_POOL:-1000000}"
MODE="${MODE:-overlap}"   # overlap | disjoint

case "$MODE" in
    overlap|disjoint) ;;
    *) echo "ERROR: MODE must be 'overlap' or 'disjoint' (got: $MODE)" >&2; exit 1 ;;
esac

CSV_OUT="$PERF_DIR/bench-alternatives-${DATE_TAG}-${MODE}-pg${PG_MAJOR}.csv"

echo "bench_alternatives: PG_CONFIG=$PG_CONFIG_BIN PG_MAJOR=$PG_MAJOR"
echo "bench_alternatives: MODE=$MODE ITERS=$ITERS K_VALUES=${K_VALUES[*]} N_VALUES=${N_VALUES[*]}"
echo "bench_alternatives: ACCOUNT_POOL=$ACCOUNT_POOL"
echo "bench_alternatives: CSV=$CSV_OUT"

# ---------------------------------------------------------------------------
# Bring up temp cluster
# ---------------------------------------------------------------------------
PGBIN="$("$PG_CONFIG_BIN" --bindir)"
PGCTL="$PGBIN/pg_ctl"
PSQL="$PGBIN/psql"
INITDB="$PGBIN/initdb"

PGDATA="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.bench_alt.XXXXXX")"
PGPORT="$(python3 -c '
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(("127.0.0.1", 0))
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    print(s.getsockname()[1])
')"
PGSOCKET="$PGDATA"
WORK_DIR="$(mktemp -d "/tmp/pg_xclaim_${USER:-nobody}_$$.bench_work.XXXXXX")"

cleanup() {
    "$PGCTL" stop -D "$PGDATA" -m immediate >/dev/null 2>&1 || true
    rm -rf "${PGDATA:?}" "${WORK_DIR:?}"
}
trap cleanup EXIT INT TERM

# Capture initdb output: a swallowed failure (e.g. missing locale) would
# otherwise die silently with no diagnostic.
if ! INITDB_OUT="$("$INITDB" -D "$PGDATA" --locale=ru_RU.UTF-8 -E UTF8 --auth=trust -U postgres 2>&1)"; then
    echo "bench_alternatives: initdb failed; output follows:" >&2
    printf '%s\n' "$INITDB_OUT" >&2
    exit 1
fi

{
    echo "shared_preload_libraries = 'pg_xclaim'"
    echo "port = $PGPORT"
    echo "unix_socket_directories = '$PGSOCKET'"
    echo "pg_xclaim.max_claims = 4194304"
    echo "pg_xclaim.num_partitions = 128"
    echo "pg_xclaim.expected_claims_per_backend = 131072"
    echo "max_locks_per_transaction = 16384"
    echo "max_connections = 64"
    echo "log_min_messages = warning"
    echo "logging_collector = off"
    echo "lc_messages = 'C'"
    echo "synchronous_commit = on"
    echo "fsync = on"
    echo "checkpoint_timeout = 30min"
    echo "log_lock_waits = on"
    echo "deadlock_timeout = 1s"
} >> "$PGDATA/postgresql.conf"

# LC_ALL/LANG must be exported in the calling env: on macOS the postmaster
# inherits the parent's locale at startup, and an unset LC_ALL triggers
# "postmaster became multithreaded during startup" FATAL on PG 17.10+.
# Inline-prefix keeps the locale scoped to pg_ctl (does not leak into the
# rest of the script, which expects en_US for parsing some psql output).
LC_ALL=ru_RU.UTF-8 LANG=ru_RU.UTF-8 \
"$PGCTL" start -D "$PGDATA" -w -l "$PGDATA/server.log" -o "-p $PGPORT" >/dev/null 2>&1 || {
    echo "bench: pg_ctl start failed" >&2
    tail -50 "$PGDATA/server.log" >&2 || true
    exit 1
}

PSQL_BASE=("$PSQL" -h "$PGSOCKET" -p "$PGPORT" -U postgres -d postgres -X -At -v ON_ERROR_STOP=1)

# ---------------------------------------------------------------------------
# Schema + extensions
# ---------------------------------------------------------------------------
"${PSQL_BASE[@]}" <<SQL >/dev/null
CREATE EXTENSION pg_xclaim;

-- Pool of synthetic accounts. Used by impl C (FOR UPDATE) and as the
-- key universe for all three implementations.
CREATE TABLE accounts_synth (
    account_id int4 PRIMARY KEY,
    payload    bigint NOT NULL DEFAULT 0
);
INSERT INTO accounts_synth (account_id)
SELECT g FROM generate_series(1, $ACCOUNT_POOL) g;

-- Claim-tables for the four claim-table variants -- full 2x2 matrix
-- of {UNLOGGED, LOGGED} x {UNSORTED, SORTED}:
--   B (UNLOGGED unsorted INSERT) -- claims_t
--   D (LOGGED   unsorted INSERT) -- claims_t_logged
--   E (LOGGED   SORTED   INSERT) -- claims_t_sorted_logged
--   F (UNLOGGED SORTED   INSERT) -- claims_t_sorted
--
-- F isolates the cost of SORT itself from the cost of WAL+SORT in E:
-- comparing F vs B answers "what does sorting cost without WAL?",
-- comparing E vs F answers "what does WAL add on top of sorting?".
--
-- UNIQUE on account_id is the enforcement mechanism for ON CONFLICT
-- DO NOTHING; rows are removed at end of xact (we ROLLBACK every
-- iteration via subtxn RAISE, so each table stays empty between
-- iterations and is never bloated on the hot path).
--
-- E/F use separate physical tables only to keep B/D/E/F independent
-- under truncation between scenarios -- the SORT happens in the SQL
-- (ORDER BY k), not in the schema.
CREATE UNLOGGED TABLE claims_t (
    account_id int4 PRIMARY KEY
);
CREATE TABLE claims_t_logged (
    account_id int4 PRIMARY KEY
);
CREATE TABLE claims_t_sorted_logged (
    account_id int4 PRIMARY KEY
);
CREATE UNLOGGED TABLE claims_t_sorted (
    account_id int4 PRIMARY KEY
);

-- Random-key generator covering the full ACCOUNT_POOL.
-- Used in MODE=overlap: every backend draws from [1, ACCOUNT_POOL],
-- so concurrent backends compete on the same keyspace (~52% pairwise
-- key overlap at N=8 K=100k POOL=1M). Duplicates within one batch are
-- possible but rare at K << ACCOUNT_POOL.
CREATE OR REPLACE FUNCTION rand_keys(k int) RETURNS int4[]
LANGUAGE sql VOLATILE PARALLEL RESTRICTED AS \$\$
    SELECT array_agg(((random() * ($ACCOUNT_POOL - 1))::int4 + 1))
      FROM generate_series(1, k) g;
\$\$;

-- Worker-disjoint key generator (MODE=disjoint).
-- Each backend gets a unique slice of the keyspace via a worker_id
-- offset, so two concurrent backends never request the same key. This
-- isolates the raw cost of the implementations from the cost of
-- conflict-handling. Slice width = ACCOUNT_POOL / max_backends.
CREATE OR REPLACE FUNCTION rand_keys_disjoint(k int, worker_id int, n_workers int)
RETURNS int4[]
LANGUAGE sql VOLATILE PARALLEL RESTRICTED AS \$\$
    SELECT array_agg(
             (
                 (worker_id - 1) * ($ACCOUNT_POOL / GREATEST(n_workers,1))
                 + (random() * ($ACCOUNT_POOL / GREATEST(n_workers,1) - 1))::int4
                 + 1
             )::int4)
      FROM generate_series(1, k) g;
\$\$;
SQL

# ---------------------------------------------------------------------------
# Worker driver. Runs ITERS transactions; each tx does:
#   1. BEGIN;
#   2. compute random K-element key array;
#   3. invoke the implementation's acquire SQL;
#   4. ROLLBACK;
# Wall-clock sample per iteration goes to $1 (latency file).
# Counts how many keys were actually claimed (some may collide on B/C).
#
# Args:
#   $1  worker id (used for output filename)
#   $2  impl tag: A | B | C
#   $3  K (keys per tx)
# ---------------------------------------------------------------------------
worker() {
    local wid="$1" impl="$2" k="$3" n_workers="$4"
    local lat_file="$WORK_DIR/lat_${impl}_${wid}.txt"
    : > "$lat_file"

    case "$impl" in
        A) acquire_sql="PERFORM ok FROM unnest(xclaim.try_many(1, _keys)) AS x(ok) WHERE ok;" ;;
        B) acquire_sql="WITH ins AS (INSERT INTO claims_t(account_id) SELECT unnest(_keys) ON CONFLICT (account_id) DO NOTHING RETURNING 1) SELECT count(*) INTO _acq FROM ins;" ;;
        C) acquire_sql="PERFORM 1 FROM accounts_synth WHERE account_id = ANY(_keys) FOR UPDATE NOWAIT;" ;;
        D) acquire_sql="WITH ins AS (INSERT INTO claims_t_logged(account_id) SELECT unnest(_keys) ON CONFLICT (account_id) DO NOTHING RETURNING 1) SELECT count(*) INTO _acq FROM ins;" ;;
        E) acquire_sql="WITH sorted AS (SELECT k FROM unnest(_keys) AS k ORDER BY k), ins AS (INSERT INTO claims_t_sorted_logged(account_id) SELECT k FROM sorted ON CONFLICT (account_id) DO NOTHING RETURNING 1) SELECT count(*) INTO _acq FROM ins;" ;;
        F) acquire_sql="WITH sorted AS (SELECT k FROM unnest(_keys) AS k ORDER BY k), ins AS (INSERT INTO claims_t_sorted(account_id) SELECT k FROM sorted ON CONFLICT (account_id) DO NOTHING RETURNING 1) SELECT count(*) INTO _acq FROM ins;" ;;
        *) echo "unknown impl: $impl" >&2; return 1 ;;
    esac

    # MODE switch: overlap -> rand_keys; disjoint -> rand_keys_disjoint(wid, n_workers).
    # Substitute K already at bash level so the Python f-string sees a
    # plain SQL expression (no nested {k} placeholder to confuse it).
    local key_call
    if [[ "$MODE" == "disjoint" ]]; then
        key_call="rand_keys_disjoint(${k}, ${wid}, ${n_workers})"
    else
        key_call="rand_keys(${k})"
    fi

    python3 - "$lat_file" "$ITERS" "$k" "$acquire_sql" "$key_call" <<EOF
import os, subprocess, sys, time

lat_file = sys.argv[1]
iters    = int(sys.argv[2])
k        = int(sys.argv[3])
acquire  = sys.argv[4]
key_call = sys.argv[5]

# Iteration loop scripted in plpgsql. Each iteration runs the acquire
# inside a BEGIN/EXCEPTION/END subtransaction and forces a RAISE to
# roll back the subtxn between iterations -- otherwise state would
# accumulate across iterations and exceed max_claims by orders of
# magnitude (K=100k * ITERS=200 = 20M state entries).
#
# Known methodology limitation: the subtxn rollback path is
# implementation-dependent (xclaim's subxact_callback vs claim-table
# heap+index UNDO vs row-lock release). This adds an
# implementation-specific component to each iteration's measured
# wall time -- the comparison numbers are NOT a pure measure of
# acquire cost. The flamegraph contention scenario shows
# MemoryContextReset (subtxn teardown) at ~21% of CPU; expect a
# similar fraction here. Treat the absolute numbers as
# order-of-magnitude; trust the *direction* of effects between
# implementations more than the precise ratios. A pgbench-style
# outer-rollback harness would isolate acquisition cost more cleanly,
# at the cost of one psql roundtrip per iteration.
pl = f"""
DO \$\$
DECLARE
    _i int;
    _keys int4[];
    _acq int;
    _t0 timestamptz;
    _t1 timestamptz;
    _ms numeric;
BEGIN
    FOR _i IN 1..{iters} LOOP
        _keys := {key_call};
        _t0 := clock_timestamp();
        BEGIN
            {acquire}
            RAISE EXCEPTION USING ERRCODE = 'XBENC';
        EXCEPTION
            WHEN sqlstate 'XBENC' THEN
                -- expected: subtxn rolls back, releasing acquired state
                NULL;
            WHEN lock_not_available THEN
                -- impl C contention: subtxn already rolled back, latency still valid
                NULL;
        END;
        _t1 := clock_timestamp();
        _ms := EXTRACT(EPOCH FROM (_t1 - _t0)) * 1000.0;
        RAISE NOTICE 'LATENCY % ms', _ms;
    END LOOP;
END\$\$;
"""

t_start = time.monotonic()
r = subprocess.run(
    ["$PSQL", "-h", "$PGSOCKET", "-p", "$PGPORT", "-U", "postgres", "-d", "postgres",
     "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", pl],
    capture_output=True, text=True)
t_end = time.monotonic()

if r.returncode != 0:
    sys.stderr.write(r.stderr)
    sys.exit(1)

# Parse NOTICE lines for latency samples.
samples = []
for line in r.stderr.splitlines():
    line = line.strip()
    if line.startswith("NOTICE:") and "LATENCY" in line:
        try:
            samples.append(float(line.split("LATENCY")[1].split("ms")[0].strip()))
        except (IndexError, ValueError):
            pass

with open(lat_file, "w") as fh:
    for s in samples:
        fh.write(f"{s}\n")
    fh.write(f"# wall_total_s={t_end - t_start:.6f}\n")
EOF
}

# ---------------------------------------------------------------------------
# Aggregator: read all lat_<impl>_*.txt for a scenario; emit summary line.
# ---------------------------------------------------------------------------
aggregate() {
    local impl="$1" n="$2" k="$3" wal_bytes="$4" cap_used="$5" deadlocks="$6"
    python3 - "$WORK_DIR" "$impl" "$n" "$k" "$ITERS" "$wal_bytes" "$cap_used" "$deadlocks" <<'EOF'
import glob, os, statistics, sys

work_dir = sys.argv[1]
impl     = sys.argv[2]
n        = int(sys.argv[3])
k        = int(sys.argv[4])
iters    = int(sys.argv[5])
wal_bytes = sys.argv[6]
cap_used  = sys.argv[7]
deadlocks = sys.argv[8]

samples = []
wall_max = 0.0
for fp in sorted(glob.glob(os.path.join(work_dir, f"lat_{impl}_*.txt"))):
    with open(fp) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            if line.startswith("# wall_total_s="):
                w = float(line.split("=")[1])
                wall_max = max(wall_max, w)
            else:
                try:
                    samples.append(float(line))
                except ValueError:
                    pass

if not samples:
    print(f"NO_SAMPLES,{impl},{n},{k}", file=sys.stderr)
    sys.exit(1)

samples.sort()
def pct(p):
    if not samples:
        return float("nan")
    idx = max(0, min(len(samples) - 1, int(round(p / 100.0 * (len(samples) - 1)))))
    return samples[idx]

p50 = pct(50)
p95 = pct(95)
p99 = pct(99)
total_tx = n * iters
throughput = total_tx / wall_max if wall_max > 0 else 0.0

print(f"{impl},{n},{k},{throughput:.1f},{p50:.3f},{p95:.3f},{p99:.3f},{wal_bytes},{cap_used},{deadlocks}")
EOF
}

# ---------------------------------------------------------------------------
# WAL helpers
# ---------------------------------------------------------------------------
wal_lsn() {
    "${PSQL_BASE[@]}" -c "SELECT pg_current_wal_lsn();"
}

wal_diff_bytes() {
    local lsn0="$1" lsn1="$2"
    "${PSQL_BASE[@]}" -c "SELECT pg_wal_lsn_diff('$lsn1','$lsn0')::int8;"
}

cap_peak() {
    "${PSQL_BASE[@]}" -c "SELECT capacity_used FROM xclaim.stats();"
}

# Read deadlocks counter from pg_stat_database.
deadlock_count() {
    "${PSQL_BASE[@]}" -c "SELECT COALESCE(deadlocks, 0) FROM pg_stat_database WHERE datname = 'postgres';"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
HEADER="timestamp,pg_major,mode,impl,backends,K,throughput_tx_per_sec,p50_ms,p95_ms,p99_ms,wal_bytes,xclaim_capacity_observed,deadlocks"
if [[ ! -f "$CSV_OUT" ]]; then
    echo "$HEADER" > "$CSV_OUT"
fi

for n in "${N_VALUES[@]}"; do
    for k in "${K_VALUES[@]}"; do
        for impl in A B C D E F; do
            # Reset state between scenarios.
            "${PSQL_BASE[@]}" -c "TRUNCATE claims_t, claims_t_logged, claims_t_sorted_logged, claims_t_sorted;" >/dev/null
            # Reset xclaim per-backend state -- the previous scenario's
            # backends already disconnected, so xclaim state is empty,
            # but be paranoid.
            "${PSQL_BASE[@]}" -c "SELECT xclaim.session_reset();" >/dev/null 2>&1 || true

            lsn0="$(wal_lsn)"
            cap_before="$(cap_peak 2>/dev/null || echo 0)"
            dl_before="$(deadlock_count 2>/dev/null || echo 0)"

            # Clear any old worker output files for this impl.
            rm -f "$WORK_DIR"/lat_${impl}_*.txt

            echo "[bench] impl=$impl mode=$MODE backends=$n K=$k iters=$ITERS ..."
            for ((w = 1; w <= n; w++)); do
                worker "$w" "$impl" "$k" "$n" &
            done
            wait

            lsn1="$(wal_lsn)"
            wal_bytes="$(wal_diff_bytes "$lsn0" "$lsn1")"
            cap_after="$(cap_peak 2>/dev/null || echo 0)"
            dl_after="$(deadlock_count 2>/dev/null || echo 0)"
            dl_delta=$((dl_after - dl_before))

            cap_used_obs="-"
            if [[ "$impl" == "A" ]]; then
                cap_used_obs="$cap_after"
            fi

            row="$(aggregate "$impl" "$n" "$k" "$wal_bytes" "$cap_used_obs" "$dl_delta")" || {
                echo "[bench] aggregate failed for impl=$impl n=$n k=$k" >&2
                continue
            }
            ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "${ts},${PG_MAJOR},${MODE},${row}" >> "$CSV_OUT"
            echo "  -> $row"
        done
    done
done

echo ""
echo "================================================================"
echo " CSV written: $CSV_OUT"
echo "================================================================"
echo "Reading the CSV:"
echo "  - throughput_tx_per_sec is total across all backends; higher = better"
echo "  - p95_ms is per-transaction tail latency; lower = better"
echo "  - wal_bytes shows write amplification; lower = less vacuum/replication pressure"
echo "  - xclaim_capacity_observed is xclaim.stats().capacity_used after impl=A scenarios"
echo
echo "Two key-space modes are supported (MODE=overlap|disjoint):"
echo
echo "MODE=overlap  -- backends share a key pool; ~52% pairwise overlap"
echo "                at N=8 K=100k. Models real production scenarios"
echo "                where operations naturally compete for the same"
echo "                accounts."
echo "MODE=disjoint -- worker-disjoint key slices; no two backends ever"
echo "                request the same key. Isolates raw implementation"
echo "                cost from conflict-resolution cost."
echo
echo "What the workload tends to show (verify in your own CSV):"
echo "  - claim-table (B/D) hits deadlocks on the UNIQUE index under N=8"
echo "    overlap -- p95 spikes, throughput collapses to ~10-30 tx/sec."
echo "  - sorted INSERT (E) eliminates deadlocks but introduces wait-on-"
echo "    lock serialization on overlap; deadlocks become serialization,"
echo "    they do not disappear."
echo "  - row locks (C) at high overlap can show inflated throughput"
echo "    because FOR UPDATE NOWAIT bails out on the first conflict in"
echo "    microseconds, acquiring 0 keys per tx -- a fail-fast artefact,"
echo "    NOT a fair comparison. On disjoint, where NOWAIT cannot 'cheat',"
echo "    C drops sharply (~4x slower vs overlap)."
echo "  - claim-table B/D even on disjoint suffer from PostgreSQL's"
echo "    relation extension lock (~13-14 tx/sec at N=8 K=100k)."
echo "  - pg_xclaim (A) keeps p95 stable and writes 0 WAL; on disjoint"
echo "    it pulls clearly ahead at K>=10k+N>=8."
echo
echo "Decision rule: at low K + low concurrency, prefer B or C (no extension"
echo "needed). pg_xclaim earns its place only when concurrency is high AND"
echo "alternatives are measurably / architecturally unsuitable. Run on YOUR"
echo "workload before drawing conclusions."
