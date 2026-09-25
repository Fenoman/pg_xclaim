# pg_xclaim DBA Runbook

> **Русская версия:** [`runbook.md`](runbook.md).

Audience. DBAs and SREs operating PostgreSQL clusters (upstream PG or
any ABI-compatible fork) where `pg_xclaim` is deployed.

Use this runbook to deploy pg_xclaim, monitor it, respond to incidents,
and roll back. It is built as a sequence of steps - every command can
be copy-pasted into a script and run.

Cross-references in this document:

- `incident-decision-tree_en.md` (oncall triage)

---

## Table of Contents

1. [Pre-deploy checklist](#1-pre-deploy-checklist)
2. [Deploy stages](#2-deploy-stages)
3. [Monitoring metrics + alert thresholds](#3-monitoring-metrics--alert-thresholds)
4. [Live kill-switch (incident response)](#4-live-kill-switch-incident-response)
5. [Three rollback levels](#5-three-rollback-levels)
6. [Pooler integration](#6-pooler-integration)
7. [GUC tuning guide](#7-guc-tuning-guide)
8. [Post-migration validation queries](#8-post-migration-validation-queries)
9. [Capacity planning](#9-capacity-planning)
10. [Common errors and remediations](#10-common-errors-and-remediations)

---

## 1. Pre-deploy checklist

Do not edit production `postgresql.conf` until every gate in the
table below has passed. This protects against partial rollout.

| # | Gate | Command | Pass criterion |
|---|------|---------|----------------|
| 1 | Smoke gate | `bash scripts/smoke_gate.sh /path/to/pg_config` | exit 0, "SMOKE GATE PASS" |
| 2 | Smoke gate (no preload) | `bash scripts/smoke_gate_no_preload.sh /path/to/pg_config` | exit 0, SQLSTATE 55000 matched |
| 3 | Regress matrix | `bash scripts/run_regress_matrix.sh` | all targets green |
| 4 | Bench budgets | `bash scripts/bench_try_many.sh` | both budgets PASS |
| 5 | Baseline `LockManager` p99 | `pg_wait_sampling` 3-day capture | committed to `docs/perf/baseline-pre-migration-YYYY-MM-DD.csv` |

> All shell snippets in this runbook assume `set -euo pipefail`. When you
> copy-paste into a script, prepend that line.

> Locale: the scripts of gates 1-4 create temporary clusters with the
> `ru_RU.UTF-8` locale, so that locale must be installed on the host
> that runs them.

---

## 2. Deploy stages

All extension-installation and call-site rewrite steps happen during
the planned maintenance window.

| Stage | Action | Owner | Gate to next stage                                                                                                                                                                                                                         |
|-------|--------|-------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 0 | Build `pg_xclaim.so` against the target PG major (16/17/18) on the build host: `make PG_CONFIG=... && sudo make PG_CONFIG=... install`. | Build | `smoke_gate.sh` exit 0 in CI (`.github/workflows/ci-pg-matrix.yml`). The `pg_xclaim.so`, `pg_xclaim.control`, `pg_xclaim--1.0.0-rc1.sql` and `pg_xclaim--1.0.0-rc1--1.0.0-rc2.sql` files are installed under `$(pg_config --pkglibdir)` and `$(pg_config --sharedir)/extension/`. |
| 1 | Add `pg_xclaim` as the **last** entry in `shared_preload_libraries` (PostgreSQL invokes xact callbacks in LIFO order - the last one registered runs first) and the `pg_xclaim.*` GUCs in `postgresql.conf`. Restart the cluster. | DBA | server starts, log line `pg_xclaim: shared memory initialized (...)` is present, no `FATAL` during `_PG_init`.                                                                                                                             |
| 2 | Run `CREATE EXTENSION pg_xclaim;` in every database that needs the new SQL surface. | DBA | `SELECT * FROM xclaim.stats();` returns a valid row in each database, `\dx pg_xclaim` shows the installed version.                                                                                                                         |
| 3 | On the **dev cluster**: apply the per-site rewrite DDL (replace `pg_try_advisory_xact_lock(...)` with `xclaim.try(...)` in target functions). | DBA | The post-check finds zero remaining `pg_try_advisory_xact_lock` references on migrated paths, functional smoke tests pass.                                                                                                                 |
| 4 | Soak on dev: leave the extension running on the dev cluster for 1-3 days under normal load (developer testing, integration tests) so slow-burning issues show up - memory leaks, accumulating stale entries, performance drift. | Dev | no regressions reported.                                                                                                                                                                                                                   |
| 5 | Repeat stages 0-2 on the **prod cluster** during the planned maintenance window: install the binaries, edit `postgresql.conf`, restart, run `CREATE EXTENSION pg_xclaim;`. | DBA | server starts, `xclaim.stats()` clean in every database.                                                                                                                                                                                   |
| 6 | Apply per-site rewrite DDL to prod cluster. | DBA | post-check clean, `xclaim.stats()` shows `capacity_errors = 0` and `cleanup_misses = 0`.                                                                                                                                                   |
| 7 | Monitor prod 24-48h. | Oncall | no incidents, `capacity_errors=0`, `cleanup_misses=0`.                                                                                                                                                                                     |

> **Why last specifically?** PostgreSQL stores registered xact
> callbacks in a stack: each new one is inserted at the head of the
> list, and on commit PG walks the list from the head
> (`REL_18_STABLE:xact.c:3812-3813,3843`). So the last callback
> registered is the first one called.
>
> Registration happens inside each extension's `_PG_init`, and the
> order in which `_PG_init` fires matches the order in
> `shared_preload_libraries` (`process_shared_preload_libraries()` ->
> `load_libraries()` in `miscinit.c` iterates the library list in GUC
> order). Putting pg_xclaim last means its callback releases the
> claims first, before the callbacks of other extensions.
>
> In a running backend the order changes nothing. When another
> extension's callback raises ERROR at commit or rollback, PostgreSQL
> runs the transaction abort again and calls every callback with the
> ABORT event, pg_xclaim's included (`REL_18_STABLE:xact.c:2876,2965`).
> When the transaction already has an xid, the same error at commit
> ends in PANIC and a server restart (`REL_18_STABLE:xact.c:1793`).
>
> The order matters only when a backend exits with an open
> transaction. `ShutdownPostgres` aborts it, and an ERROR in another
> extension's callback at that point becomes FATAL
> (`REL_18_STABLE:elog.c:379`) and ends the chain. With pg_xclaim
> last, its callback has already run by then. Otherwise the pg_xclaim
> backend-exit callback releases the claims.

### 2.0 Build & install the extension files

```bash
set -euo pipefail
PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config   # adjust for the target major

make PG_CONFIG="$PG_CONFIG" -j"$(nproc)"
sudo make PG_CONFIG="$PG_CONFIG" install

# Sanity: verify installed paths
test -f "$($PG_CONFIG --pkglibdir)/pg_xclaim.so"
test -f "$($PG_CONFIG --sharedir)/extension/pg_xclaim.control"
test -f "$($PG_CONFIG --sharedir)/extension/pg_xclaim--1.0.0-rc1.sql"
test -f "$($PG_CONFIG --sharedir)/extension/pg_xclaim--1.0.0-rc1--1.0.0-rc2.sql"
```

For a multi-major matrix (16/17/18), repeat the `make` + `make install`
sequence with each target's `pg_config` path.

To update an installed extension: install the new build with the same
`make install`, restart the server (the library is loaded through
`shared_preload_libraries`), and run `ALTER EXTENSION pg_xclaim UPDATE;`
in every database that has the extension. Per-version changes are listed
in `CHANGELOG.md`.

### 2.1 Apply per-site rewrite DDL

Replacing `pg_try_advisory_xact_lock(...)` with `xclaim.try(...)` is
your own script tailored to your code layout. The principles it
should follow:

> **WARNING: per-keyspace migration must be atomic.** Advisory locks
> and xclaim claims live in **separate, disjoint namespaces**: holding
> key K via `pg_xclaim` and holding the same K via
> `pg_try_advisory_xact_lock` **do not see each other**. If some call
> sites operating on the same keyspace are migrated to xclaim while
> others are not (for example because of a failure in a
> continue-on-error run), mutual exclusion for that keyspace **silently
> breaks**: two backends can "hold" the same key at once, each through
> a different mechanism.
>
> Therefore: **all call sites touching one keyspace must be migrated
> atomically -- all or nothing.** Continue-on-error
> (`EXCEPTION WHEN OTHERS`) is safe **only** when the failed functions
> share no keys with already-migrated ones. The post-check must verify
> completeness **at the keyspace level**, not just "how many functions
> passed" -- a partially migrated keyspace is worse than an
> unmigrated one.

- **One `CREATE OR REPLACE FUNCTION` per call site** - do not bundle
  multiple function rewrites in a single transaction, an error in
  one would roll back the rest.
- **Each block wrapped in `BEGIN ... EXCEPTION WHEN OTHERS ... END`** -
  log the failure and continue, so one bad identifier does not kill
  the whole migration.
- **Post-check**: after the run, scan `pg_proc.prosrc` for any
  remaining `pg_try_advisory_xact_lock\s*\(` on paths that should
  already be migrated.
- **Logs to file** + `set -e` in bash - so you can quickly show the
  DBA "these 3 functions failed, the rest are OK".

Run it across every database in the cluster that uses the extension
(`SELECT datname FROM pg_database WHERE datistemplate = false`),
excluding `postgres` and system DBs.

---

## 3. Monitoring metrics + alert thresholds

All metrics are sourced from `xclaim.stats()` (granted to `pg_monitor`).
Recommended scrape interval: **15s** for Prometheus / Zabbix / pgwatch.

| Metric | Type | Warn | Page | Action |
|--------|------|------|------|--------|
| `capacity_pct` | gauge | 80% | 90% | Raise `pg_xclaim.max_claims`. Restart required. |
| `capacity_errors` rate | counter | -- | any non-zero/min | P1: capacity exhaustion in error mode -- switch to `warn` mode, then size up (§10.1). |
| `capacity_warnings` rate | counter | any | -- | Capacity exhaustion in warn mode -- callers seeing spurious `false` returns. |
| `cleanup_misses` rate | counter | any | -- | P2: cleanup found its entry gone. Investigate. |
| `reaped_stale` rate | counter | -- | > 1/min | P3: entries outlived their owner. Check the log for errors at transaction end and backend exit, and `cleanup_misses`. |
| `conflicts` rate | counter | -- | -- | Informational, workload-dependent. |
| `disabled_calls` rate | counter | -- | -- | Should be 0 in steady state. Non-zero only when `enabled=off`. |
| `total_acquires` rate | counter | -- | -- | Throughput: baseline + alert on 50% drop. |

Beyond `xclaim.stats()` there is also a server-log signal. The
extension emits a single `LOG` line per session when a backend's
live claim count first crosses 75% of
`pg_xclaim.expected_claims_per_backend`. This is an early-warning
signal -- it fires well before any grow: the actual rehash happens
when the simplehash bucket-array fill reaches 0.9 (fillfactor). The
75% mark leaves headroom to raise the GUC before a rehash lands on
the hot path. Example log line:

```
LOG:  pg_xclaim: per-backend live claims (12345) crossed 75% of
      pg_xclaim.expected_claims_per_backend (16384) -- simplehash
      will rehash on further growth
HINT:  Raise pg_xclaim.expected_claims_per_backend to your observed
       peak and restart the cluster.
```

Ready-made grep alert for a log aggregator:

```bash
grep -E 'pg_xclaim:.*crossed 75%.*expected_claims_per_backend' /var/log/postgresql/*.log
```

Action on hit: look up `xclaim.stats().peak_per_backend` in the same
window, raise the GUC to the observed peak with a 1.2x-1.5x safety
margin, and restart the cluster.

Additional pg-side wait-event observability:

```sql
-- Per-event sample distribution. Track p99 over time.
SELECT wait_event, count(*)
FROM pg_stat_activity
WHERE state IS NOT NULL
GROUP BY 1
ORDER BY 2 DESC;
```

After migration, `LWLock: xclaim_partition` will show up in wait
events but stay short - this is normal. Once the main hot-path call
sites are migrated, `LWLock: LockManager` p99 should drop by at
least 50%.

### 3.1 Watermark log line

The extension emits a message when `capacity_pct` first crosses one of
three bands: 80%, 90%, 95% (the lowest band is controlled by the
`pg_xclaim.capacity_warn_pct` GUC, default 80). Further warnings are
suppressed for 60s. The 80% and 90% bands are logged at `LOG` level,
and the 95% band escalates to `WARNING`.

Hardcoded bands below the configured `capacity_warn_pct` are skipped:
the ladder respects `capacity_warn_pct`, and bands strictly below the
configured value never fire.

Sample (server log):
```
LOG:  pg_xclaim: capacity watermark crossed -- 81% (3404288 / 4194304 claims)
```

The percentage in the line is an integer (the code computes the
integer ratio, no fractional part). This is informational. If
sustained > 5 minutes, plan a `max_claims` bump in the next
maintenance window. If it crosses 95% repeatedly, page oncall.

---

## 4. Live kill-switch (incident response)

To disable pg_xclaim without restarting the cluster:

```sql
ALTER SYSTEM SET pg_xclaim.enabled = off;
SELECT pg_reload_conf();
```

Effects:

- New `xclaim.try` calls always return `true` - no acquisition
  happens.
- Existing held entries continue to release through the xact callback
  as transactions end and through the backend-exit callback
  (`on_shmem_exit`).
- `xclaim.stats().disabled_calls` increments per call - monitoring
  will show the kill switch is engaged.

> **CRITICAL.** While disabled, **locks do not work**: 
> `xclaim.try(k)` will always return `true`, even if the key is already 
> held. Applications that rely on claims for uniqueness (queues, 
> deduplication, leader election) will start **processing duplicates**. 
> This is a direct violation of application logic.
>
> Use `enabled = off` ONLY when:
> - User traffic is completely stopped (maintenance window).
> - Application correctness is not the priority during diagnosis
>   (emergency incident diagnosis).
>
> Always document this action in your incident ticket. Monitor the 
> `xclaim.stats().disabled_calls` counter (if it grows, the switch 
> is active) and re-enable the extension as soon as the issue is resolved.

To re-enable:

```sql
ALTER SYSTEM SET pg_xclaim.enabled = on;
SELECT pg_reload_conf();
```

---

## 5. Three rollback levels

### 5.1 Level 1 -- Soft rollback (no restart, immediate)

This is the kill-switch `pg_xclaim.enabled = off` from §4. The
extension becomes a no-op for new acquisitions, and held claims keep
releasing as their transactions finish. Reversible at any time. The
kill switch removes mutual exclusion for every key, so use it only in
the cases §4 lists: user traffic stopped, or emergency diagnosis where
correctness is not the priority.

### 5.2 Level 2 -- Code rollback (no restart)

```bash
set -euo pipefail
PGHOST=...; PGPORT=...; PGUSER=postgres
DBS=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -At -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');")

# Step 1: stop user traffic (in the application or the pooler), and
# only then engage soft rollback: with live traffic the kill switch
# removes mutual exclusion for every key (§4)
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres \
     -c "ALTER SYSTEM SET pg_xclaim.enabled = off; SELECT pg_reload_conf();"

# Step 2: apply per-site rollback DDL (inverse of the forward rewrite --
# restores pg_try_advisory_xact_lock(...) calls in target functions)
for db in $DBS; do
    echo "=== Applying per-site rollback to $db ==="
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$db" \
         -v ON_ERROR_STOP=1 -f /path/to/your/rollback_rewrite.sql \
         2>&1 | tee "/tmp/pg_xclaim_rollback_${db}_$(date +%Y%m%d_%H%M%S).log"
done
```

After completion: callers use advisory locks again. Resume user traffic
once the script has finished without errors: the rollback DDL has gone
through in every database. `pg_xclaim.enabled=off` ensures no parallel
claim acquisition until the next deploy.

### 5.3 Level 3 -- Full rollback (restart required)

1. Apply the per-site rollback DDL first (Level 2 above).
2. During the next maintenance window:
   1. In every database that has the extension installed, run
      `DROP EXTENSION pg_xclaim CASCADE;`.
   2. Edit `postgresql.conf` and remove `pg_xclaim` from
      `shared_preload_libraries`.
   3. Optionally remove the `pg_xclaim.*` GUC lines.
   4. Restart the cluster.
3. Verify `shared_preload_libraries` no longer mentions `pg_xclaim` and
   the cluster restarts cleanly. `\dx` shows no `pg_xclaim` row.
4. Optionally `sudo make PG_CONFIG=... uninstall` (or remove the files
   manually from `$(pg_config --pkglibdir)` and
   `$(pg_config --sharedir)/extension/`).

---

## 6. Pooler integration

Short version: pg_xclaim works with any pooler, no config changes
needed.

Claims are released automatically on every COMMIT/ABORT through the
xact callback. It fires regardless of how the transaction ends:
commit, rollback, client disconnect, idle-in-tx timeout, FATAL backend
exit.

Tx-mode poolers (`pg_doorman`, `odyssey`, `PgBouncer`) all issue
`ROLLBACK` before reusing a backend across clients on unhealthy
disconnect. This triggers pg_xclaim cleanup just like any other abort
path.

### Do not do this

```ini
# !!! DO NOT add session_reset() to server_reset_query !!!
# server_reset_query = "SELECT xclaim.session_reset()"
```

The `xclaim.session_reset()` function is an emergency recovery tool, 
not a routine hook for returning connections to the pool. Adding it to 
`server_reset_query` (or a similar pooler setting) causes three problems:

1. **Unnecessary network queries on every handoff**. On a busy cluster, 
   this generates thousands of wasted queries per second.
2. **No added protection**. Claims are released at every transaction
   end and at backend exit. By the time `server_reset_query` runs, the
   transaction has ended, so `session_reset()` has nothing to release
   and only resets the backend's owner_token (the next claim gets a new
   one).
3. **Polluted `session_resets` metric**. The counter in `xclaim.stats()` 
   will become useless, since it is meant to track rare failures, not 
   routine pool events.

`session_reset()` is only for a session that holds claims outside a
transaction (see below). Normal operation never produces that state.

### Claims held outside a transaction and `session_reset()`

Claims live until the end of the transaction that took them. The xact
callback releases them at commit or rollback, and the backend-exit
callback when the backend exits. A backend that holds claims outside a
transaction means this did not work. Normal operation never produces
that state, and other extensions' callbacks do not lead to it either:
when another extension's callback raises ERROR, PostgreSQL still calls
the pg_xclaim callback (see section 2). `cleanup_misses` does not count
such claims, so you have to look for the claims themselves.

Find backends that hold claims outside a transaction, and claims of
backends that have exited (needs the `pg_monitor` role):

```sql
SELECT d.owner_pid, d.owner_lxid, coalesce(a.state, '(gone)') AS state,
       count(*) AS claims
FROM xclaim.debug_snapshot() d
LEFT JOIN pg_stat_activity a ON a.pid = d.owner_pid
WHERE a.pid IS NULL OR a.state = 'idle'
GROUP BY 1, 2, 3 ORDER BY claims DESC;
```

- Run the query in autocommit (the psql default), not inside `BEGIN`:
  `pg_stat_activity` is read once per transaction, so inside an open
  transaction a repeat shows the backend's earlier state.
- Run the query twice, a few seconds apart. The claim snapshot and
  `pg_stat_activity` are not read at the same instant, so a backend
  that has just ended its transaction can show up once. Rows that
  repeat with the same `owner_pid` and `owner_lxid` are the signal.
- `debug_snapshot()` holds shared locks on all partitions for the scan
  and refuses to run when `pg_xclaim.num_partitions > 192`. Do not put
  this query into routine monitoring, `xclaim.stats()` is for that.
- The query does not show backends inside a transaction (`active`,
  `idle in transaction`): their claims are legitimate, and the end of
  that transaction releases any extra ones.

What to do with the result:

1. An `idle` backend: terminate it with the state checked again in the
   same statement:
   `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid = <owner_pid> AND state = 'idle';`.
   The backend-exit callback releases its claims. The check and the
   signal are not atomic: a transaction the client starts at that very
   moment ends with the session. If that is not acceptable, first stop
   giving that session work (in the application or the pooler). Left
   alone, the end of the backend's next transaction releases the claims.
2. `(gone)`: the owner has exited and its claims stayed. The
   backend-exit callback releases claims at exit, so such rows mean the
   cleanup at exit did not finish (step 4). No action is needed: the
   stale-owner reaper takes such an entry over on the first conflicting
   claim of the key (`reaped_stale` grows). On PG 16, when the exit
   callback did not get to publish owner_token 0, that happens only
   after the backend's PGPROC slot is reused.
3. `xclaim.session_reset()` only acts in the session that calls it and
   cannot clear another backend. In your own session, the end of any
   transaction does the same.
4. Save the query output, `xclaim.stats()` and the server log for that
   time, and file an issue: this is a pg_xclaim defect, like
   `cleanup_misses` (section 10.5).

### Required pooler configuration

None. Just confirm the pooler issues `ROLLBACK` (not raw RESET) when
returning a backend to the pool after an unhealthy disconnect - this
is the default in `pg_doorman`, `odyssey`, and `PgBouncer`.

---

## 7. GUC tuning guide

| GUC | Default | Where to set | When to change |
|-----|---------|--------------|----------------|
| `shared_preload_libraries` | -- | `postgresql.conf` (postmaster) | `pg_xclaim` must be last in the list. Restart required. |
| `pg_xclaim.max_claims` | 4194304 (4M) | `postgresql.conf` (postmaster) | Bump if `capacity_pct > 80%` observed under load. Doubling `max_claims` roughly doubles pg_xclaim's shmem (4M ~360 MB, 24M ~2.2 GB, 32M ~2.8 GB, see Capacity planning). Restart required. |
| `pg_xclaim.num_partitions` | 128 | `postgresql.conf` (postmaster) | Rarely changed. Increase only if `LWLock: xclaim_partition` p99 dominates wait events. Restart required. |
| `pg_xclaim.expected_claims_per_backend` | 16384 | `postgresql.conf` (postmaster) | Pre-grows the per-backend local `simplehash` to this size so the 750k single-backend burst does not rehash on the hot path. The extension emits a server log line `crossed 75% of pg_xclaim.expected_claims_per_backend` the first time a backend's live-claim count crosses 75% of the GUC - that's the signal to raise the GUC to your observed peak. **Must be <= `pg_xclaim.max_claims`**, otherwise the cluster fails to start (see §10.6). Restart required. |
| `pg_xclaim.enabled` | on | `ALTER SYSTEM` (PGC_SUSET) | Set `off` to disable acquisition without restart -- the kill switch. |
| `pg_xclaim.capacity_warn_pct` | 80 | `ALTER SYSTEM` | Lower to receive earlier warning logs, or raise to silence noise. |
| `pg_xclaim.on_capacity_exhaustion` | error | `ALTER SYSTEM` (PGC_SUSET) | Switch to `warn` to treat exhaustion as logical conflict (callers' retry path triggers). `error` is otherwise correct -- forces sizing discipline. |

### 7.1 `on_capacity_exhaustion` mode selection

| Scenario | Recommended mode |
|----------|------------------|
| Normal operation | `error` (default) -- forces sizing discipline. |
| Spike behavior unknown, retries cheap | `warn` -- callers see `false`, retry path trips. |

WARN mode + bulk API (`xclaim.try_many`) emits **one detail WARNING
for the first refused slot and, when more than one slot of the call is
refused, one tail summary WARNING** at the end of the call:
`N additional slot(s) hit max_claims ... per-slot WARNINGs suppressed`.
A 1000-key bulk past capacity produces 2 log lines, not 1000. The
`xclaim.stats().capacity_warnings` counter remains **exact** -- it
ticks once per refused slot regardless of the ereport-level
suppression: read it (not WARNING line counts) for sizing observation.
Scalar `xclaim.try` writes one WARNING line per refused call, even when
one statement makes many calls.

There is no fallback-to-advisory mode. Delegating to
`LockAcquire(LOCKTAG_ADVISORY)` on capacity exhaustion is unsafe:
xclaim cleanup does not see such a claim, allowing the same key to be
subsequently re-acquired through xclaim shmem and breaking mutual
exclusion (a split-brain namespace between xclaim shmem and the PG
LockManager).

If you anticipate a spike, the kill-switch chain is the safe path, run
with user traffic stopped. The kill switch removes mutual exclusion for
every key, and with live traffic the application starts processing
duplicates (section 4).

1. Stop user traffic, then run
   `ALTER SYSTEM SET pg_xclaim.enabled = off; SELECT pg_reload_conf();`
   -- callers see `true` unconditionally, no acquisition runs.
2. Apply the per-site rollback DDL (re-introduces
   `pg_try_advisory_xact_lock` at known-safe call sites). This is the
   pre-pg_xclaim code path that you migrated FROM, so it is by
   definition something the cluster handled before. Resume traffic
   once the rollback has gone through at every call site.
3. Bump `max_claims` in the next maintenance window.

---

## 8. Post-migration validation queries

After the per-site rewrite forward script has been applied (stage 3
in §2), run the validation bundle on each cluster:

```sql
-- Pre-migration baseline (run BEFORE the migration and archive the result):
SELECT locktype, mode, granted, count(*), count(DISTINCT pid)
FROM pg_locks
GROUP BY 1, 2, 3
ORDER BY count(*) DESC;
```

```sql
-- Post-migration: advisory count should drop on migrated paths.
SELECT count(*) FROM pg_locks WHERE locktype = 'advisory';
-- expected: 0 for migrated paths

-- Post-migration: per-backend claim count visible.
SELECT count(*) FROM xclaim.debug_snapshot();
-- expected: > 0 during peak workload
-- WARNING:
--   * debug_snapshot() acquires SHARED locks on ALL partitions
--     simultaneously (128 by default) while scanning memory. Any 
--     concurrent attempts to acquire new locks will wait until the 
--     scan finishes. On a busy cluster, this causes a **noticeable stall**, 
--     which lasts longer as memory usage grows. 
--     Do not run this function during peak traffic unless absolutely 
--     necessary. Use `xclaim.stats()` for routine monitoring and reserve 
--     `debug_snapshot()` for incident diagnosis or maintenance windows.
--   * This function is only available if `pg_xclaim.num_partitions <= 192` 
--     (due to the PostgreSQL core limit on simultaneous locks).

-- Post-migration: capacity + counters clean.
SELECT * FROM xclaim.stats();
-- expected: capacity_errors = 0
--           cleanup_misses  = 0
--           capacity_pct    < 80
```

```sql
-- Semantic parity (your_lock_success_flag FALSE rate before vs after):
-- Replace the table/column names below with the ones used in your
-- application's call-site validation table.
SELECT * FROM your_validation_table WHERE your_lock_success_flag = FALSE;
-- expected NOT zero -- verify equivalent distribution vs pre-migration
-- baseline (link to docs/perf/baseline-pre-migration-YYYY-MM-DD.csv).
```

```sql
-- Wait-event distribution shift (run during peak load, before vs after):
SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE state IS NOT NULL
GROUP BY 1, 2
ORDER BY 3 DESC;
-- expected: 'LWLock: LockManager' p99 down >= 50%
--           'LWLock: xclaim_partition' visible but short
```

The pre-migration baseline reference lives in
`docs/perf/baseline-pre-migration-YYYY-MM-DD.csv` (DBA captures via
`pg_wait_sampling` for 3 days before deploy).

---

## 9. Capacity planning

The shared-memory footprint of `pg_xclaim` scales almost linearly with
`max_claims`: the dynahash bucket array is rounded up to a power of
two, so 24M takes 2241 MB against 2160 MB for strictly linear growth.

| `max_claims` | Approx shmem |
|--------------|--------------|
| 1M           | ~90 MB       |
| 4M (default) | ~360 MB      |
| 8M           | ~720 MB      |
| 16M          | ~1.4 GB      |
| 24M          | ~2.2 GB      |
| 32M          | ~2.8 GB      |

Plus per-partition LWLock overhead (`num_partitions=128` default, ~few KB).

The default 4M comfortably covers a 750k single-backend hot-path workload
with 5.6x headroom plus 10-20 concurrent backends, each holding up to 100k
claims. Bump to 8M-16M only if `capacity_errors > 0` or
`capacity_pct > 80` is observed in production.

> **Add a safety margin for workload peaks.** The shared table is one
> dynahash of `max_claims` entries, and a claim hits the capacity limit
> only when all `max_claims` entries are in use: when the free list the
> key maps to is empty, dynahash takes an entry from another free list.
>
> Sizing recommendation: **set `max_claims` so that the expected peak
> stays below `pg_xclaim.capacity_warn_pct` (80% by default), that is
> at least 1.25x the peak**. The margin absorbs peaks above the expected
> ones, and the watermark log line (section 3.1) appears before
> capacity runs out.

Local backend memory. Held claims live in a backend-local
`simplehash` (memory context `xclaim local set`, child of
TopMemoryContext). Empirically measured on PG 16 and PG 18 (identical -
it's backend-local code):

| Claims held in one tx | `xclaim local set` |
|-----------------------|--------------------|
| 0-10 000 | ~1.58 MB (pre-grown floor under default `expected_claims_per_backend=16384`) |
| 100 000 | **~6.3 MB** |
| 750 000 | **~50.3 MB** |

Effective cost per held claim is ~63 bytes (including simplehash
overhead at ~75% load factor). The local-set entry
(`XClaimLocalEntry`) is 48 bytes after alignment (see
`src/pg_xclaim_local.h`).

Per-backend limit: at most 134217727 held claims (2^27 - 1). The
cleanup at transaction end collects pointers to all of the backend's
claims in one array, 8 bytes per claim, and PostgreSQL refuses single
allocations above 1 GB (`MaxAllocSize`). At 134217728 claims and more
the cleanup fails with ERROR: at transaction end that is a PANIC and a
cluster restart, at backend exit the backend's keys stay taken (on
PG 16 until its PGPROC slot is reused). Getting there needs
`max_claims >= 134217728` (about 12 GB of shared memory) and about
13 GB of local memory in one backend. With the default 4M the limit
cannot be reached.

### 9.1 Comparison vs pre-migration (high-cardinality use case)

Realistic scenario: **100k claims in one transaction, 200 concurrent
backends** - the workload pg_xclaim was built for. Together that is 20M
keys held at once.

Shared memory is measured on PG 16 with `postgres -C shared_memory_size`
at `max_connections = 200` (MaxBackends = 222). A server without
pg_xclaim and with `max_locks_per_transaction = 64` needs 148 MB, and
the shared-memory rows in the table below are the increase over that
base.

The PostgreSQL lock tables hold `max_locks_per_transaction` x
(MaxBackends + `max_prepared_transactions`) locks for the whole server.
With `max_locks_per_transaction = 4096` the server needs 482 MB: the
lock tables add ~334 MB and hold 4096 x 222 = ~909k locks, not 20M.
20M advisory locks need `max_locks_per_transaction` of about 91000,
7942 MB in total. pg_xclaim needs `max_claims` of at least 20M for 20M
claims, for example 24M, 2389 MB in total.

| Component | Before (advisory, `max_locks_per_transaction` ~91000) | After (pg_xclaim, `max_locks_per_transaction = 64`, `max_claims` = 24M) | Δ |
|-----------|-------------------------------------------------------|---------------------------------------------------------------------------|---|
| Shared LockManager (lock tables) | ~7.6 GB | 0 (part of the base) | -7.6 GB |
| Shared `pg_xclaim` dynahash | 0 | ~2.2 GB | +2.2 GB |
| Local LockManager x 200 backends (holding 100k locks: LOCALLOCK hash 16.8 MB + `lockOwners` arrays in TopMemoryContext 16.8 MB) | 33.6 MB x 200 = **6.72 GB** | minimal (no advisory locks taken) | **-6.71 GB** |
| Local `pg_xclaim` x 200 backends | 0 | 6.3 MB x 200 = **1.26 GB** | +1.26 GB |
| **Total** | **~14.3 GB** | **~3.5 GB** | **~-10.8 GB** |

Local memory is measured with `pg_backend_memory_contexts` in one
backend, with the same numbers on PG 16, 17 and 18: 100k
`pg_try_advisory_xact_lock` calls in one transaction add 16.8 MB to the
`LOCALLOCK hash` context and 16.8 MB to TopMemoryContext (the
`lockOwners` arrays), while 100k pg_xclaim claims take 6.3 MB in
`xclaim local set`. Shared-memory rows are in PostgreSQL units as
`shared_memory_size` prints them (1 MB = 2^20 bytes), local-memory rows
are decimal (1 MB = 10^6 bytes). The totals add the table's numbers as
shown and are accurate to within ~5%.

PG 17 and PG 18 size the lock tables with the same formula: on PG 17
the same measurement with `max_locks_per_transaction = 4096` gives
484 MB. PG 18 also allocates a fast-path array that grows with
`max_locks_per_transaction`, but to no more than 72 KB per process.
The effect on the total is small.

**Bottom line.** The saving comes from both shared memory and
backend-local memory. The lock tables for 20M advisory locks take
~7.6 GB, while the pg_xclaim dynahash for 24M claims takes ~2.2 GB.
The backend's local lock state (**LOCALLOCK hash** and `lockOwners`
arrays) grows to ~34 MB/backend under a high-cardinality advisory
workload and eats several GB cluster-wide, while pg_xclaim moves that
state into its own compact simplehash (~6 MB at 100k claims).

Under a light workload (10-100 locks per transaction), switching to
pg_xclaim **only adds** ~360 MB of shmem with no visible saving - that
kind of workload does not need pg_xclaim in the first place.

---

## 10. Common errors and remediations

### 10.1 SQLSTATE `53400` (`ERRCODE_CONFIGURATION_LIMIT_EXCEEDED`)

```
ERROR:  pg_xclaim: max_claims (4194304) exhausted
HINT:   Increase pg_xclaim.max_claims and restart, or set
        pg_xclaim.on_capacity_exhaustion to warn.
SQLSTATE: 53400
```

Cause: `on_capacity_exhaustion=error` (default) and shared dynahash hit
`max_claims`. Caller transaction aborts.

Remediation, in priority order:
1. Immediate: switch to emergency `warn` mode:
   `ALTER SYSTEM SET pg_xclaim.on_capacity_exhaustion = warn; SELECT pg_reload_conf();`
   A refused claim returns false, the caller's retry path triggers, and
   mutual exclusion holds. Scalar `xclaim.try` writes one WARNING line
   per refused call. `xclaim.try_many` writes a WARNING for the first
   refused slot and, when more than one slot of the call is refused,
   one summary WARNING per call (see 7.1):
   `N additional slot(s) hit max_claims ... per-slot WARNINGs suppressed`.
2. Schedule maintenance window to bump `max_claims` (requires restart).
3. Use the kill switch `pg_xclaim.enabled = off` (section 4) only when
   user traffic is completely stopped, or during emergency diagnosis
   where application correctness is not the priority: callers get
   `true` unconditionally, and mutual exclusion is gone for every key.

See `docs/incident-decision-tree_en.md` (P1).

### 10.2 SQLSTATE `55000` (`ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE`)

```
ERROR:  pg_xclaim must be loaded via shared_preload_libraries
SQLSTATE: 55000
```

Cause: `shared_preload_libraries` does not include `pg_xclaim`, but
the application called `xclaim.try` / another extension function.
`CREATE EXTENSION pg_xclaim` itself **does not fail** without
preload - it only installs the SQL wrappers. The error appears on
the first SQL call into the extension (the `XCLAIM_REQUIRE_INIT`
gate fires there).

Remediation:
1. Check `shared_preload_libraries`: run
   `SHOW shared_preload_libraries;` and confirm `pg_xclaim` is in the
   list.
2. If it is missing, add it **as the last entry** (e.g.
   `citus,timescaledb,pg_xclaim`) and restart the cluster. pg_xclaim
   goes last so its xact cleanup runs first in the LIFO callback
   chain. See §2 "Deploy stages".
3. Before the restart, fall back to `pg_try_advisory_xact_lock`
   directly. If the cluster has already gone through the per-site
   rewrite step (stage 3 in §2), apply your rollback rewrite script
   first.

### 10.3 Hot standby: calls fail until promotion

```
ERROR:  pg_xclaim does not support hot-standby/recovery mode
HINT:  Calls succeed once the server is promoted, so keep pg_xclaim in shared_preload_libraries on standbys.
```

The extension loads through `shared_preload_libraries` on a standby (and
on a primary still in WAL replay) without errors. SQL calls to
`xclaim.*` return `ERRCODE_FEATURE_NOT_SUPPORTED` while the node is in
recovery: the check fires at call time, not at load. After promotion
(`pg_is_in_recovery() = false`) the calls succeed without a restart or a
config change.

Keep `pg_xclaim` in `shared_preload_libraries` on replicas. A replica
without it answers calls after promotion with the §10.2 error until the
extension is added to `shared_preload_libraries` and the server is
restarted. A replica reserves as much shared memory for pg_xclaim as a
primary with the same settings.

### 10.4 2PC: `PRE_PREPARE` rejection

```
ERROR:  pg_xclaim: PREPARE TRANSACTION is not allowed while pg_xclaim claims are held
HINT:   Release pg_xclaim claims (or COMMIT/ROLLBACK the transaction) before preparing.
SQLSTATE: 0A000  -- feature_not_supported
```

Cause: application attempted `PREPARE TRANSACTION` after acquiring
xclaim claims. xclaim explicitly rejects 2PC on
`XACT_EVENT_PRE_PREPARE`.

This is a hard limitation, and it is not a parallel to PostgreSQL's
own behaviour: PG core advisory xact locks **are** handled across
`PREPARE TRANSACTION` via `AtPrepare_Locks()` (see PG18
`lock.c:3446`, PG17 `lock.c:3304`, PG16 `lock.c:3299`), which records
them in the prepared GID so a later
`COMMIT/ROLLBACK PREPARED` releases them.

pg_xclaim rejects the event because PostgreSQL has no public API
for an extension to register itself as a 2PC participant. The
internal API `RegisterTwoPhaseRecord` uses a fixed `TwoPhaseRmgrId`
enum (see `include/access/twophase_rmgr.h`), and extensions cannot
add themselves to it.

2PC support requires an upstream patch to PostgreSQL itself. In the
current model, any `PREPARE TRANSACTION` after an xclaim acquire is
an error.

Remediation: refactor the application to NOT use `PREPARE TRANSACTION`
for transactions that hold xclaim claims. There is no DBA-side fix.

**Edge case.** The `PRE_PREPARE` rejection checks every claim the
backend holds, not only the claims of the transaction being prepared.
If the backend holds claims outside a transaction (normal operation
never does this, see section 6), `PREPARE TRANSACTION` in its next
transaction is rejected too, even when that transaction took no
claims. The rejection aborts the transaction, the abort releases those
claims, and a retry succeeds.


### 10.5 `cleanup_misses` non-zero

Cause: a backend's cleanup found its shared entry gone or owned by
someone else. Normal operation never does this: the reaper only takes
over entries whose owner exited or rotated its owner_token, and
`session_reset()` releases the held claims before it rotates the
token. So the entry left its live owner: the reaper was wrong or
shared memory is corrupted. Mutual exclusion on those keys may have
been violated.

Remediation (details: `docs/incident-decision-tree_en.md`, section 5):
1. Save `xclaim.stats()`, `xclaim.debug_snapshot()`, `pg_stat_activity`
   and the server log for the time of the increase, and file an issue.
2. Check the application data for keys processed in that window.
3. Do not set `pg_xclaim.enabled = off`: `xclaim.try` would return true
   without claiming, which removes exclusion for every key.
4. If the counter keeps growing, restart the server in a planned
   window.

### 10.6 FATAL: `expected_claims_per_backend` > `max_claims`

```
FATAL:  pg_xclaim.expected_claims_per_backend (N) must be <= pg_xclaim.max_claims (M)
```

Cause: `postgresql.conf` sets
`pg_xclaim.expected_claims_per_backend` higher than
`pg_xclaim.max_claims`. The per-backend local `simplehash` cannot be
larger than the cluster-wide shmem capacity, so the extension
refuses to start.

Typical case: a DBA lowers `max_claims` for a test or after
rebalancing the cluster, forgetting to lower
`expected_claims_per_backend` (default 16384) at the same time.

Recovery:

1. Lower `pg_xclaim.expected_claims_per_backend` to a value <=
   `pg_xclaim.max_claims` in `postgresql.conf`.
2. Start the cluster again.

### 10.7 `reaped_stale` rate climbing

Cause: shared memory holds entries that outlived their owner or its
owner_token, and the reaper takes them over on a conflicting claim.
Normal operation leaves no such entries: claims are released at
transaction end and at backend exit, `session_reset()` releases them
before it rotates the token, and PostgreSQL handles hard backend death
(`SIGKILL`, segfault, OOM kill) as a child crash: the postmaster
terminates other processes and recreates shared memory
(`REL_18_STABLE:postmaster.c:2768-2792,3180-3202`). So some cleanup
path did not finish.

Remediation:
1. Check the server log for ERROR, FATAL and PANIC at transaction end
   and backend exit, including those from other extensions' callbacks,
   and whether `cleanup_misses` grows at the same time (10.5).
2. Check that nothing calls `xclaim.debug_inject_stale()`: it is a test
   function that creates such entries on purpose.
3. Save `xclaim.stats()`, `xclaim.debug_snapshot()` and the log, and
   file an issue.
4. If the rate is < 1/min, nothing is urgent: the reaper frees a key on
   the first conflict, and the application does not notice. The growth
   is still worth investigating.

---

End of runbook. For incident escalation paths, see
`docs/incident-decision-tree_en.md`.
