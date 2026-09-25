# Changelog

All notable changes to `pg_xclaim` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-rc2] - 2026-09-25

### Fixed

- **Backend-exit callback now runs in backends.** The exit callback was
  registered with `before_shmem_exit` from `_PG_init`, which runs in the
  postmaster, and PostgreSQL clears inherited exit callbacks in every
  forked child, so it only ran at postmaster shutdown. Each backend now
  registers it on its first claim, as an `on_shmem_exit` callback, which
  also keeps it out of the way of `PG_ENSURE_ERROR_CLEANUP` scopes. At
  exit it releases the claims the backend still holds. The claims of a
  transaction open at exit are normally released by the abort of that
  transaction, but when another extension's xact callback, called
  before pg_xclaim's, raises ERROR in that abort, the ERROR becomes
  FATAL during exit and pg_xclaim's xact callback does not run. With
  1.0.0-rc1 those claims then outlived the backend: on PostgreSQL 16
  their keys stayed taken until the backend's PGPROC slot was reused,
  on 17 and later the stale-owner reaper took them over on the next
  conflicting claim. Loading pg_xclaim last in
  `shared_preload_libraries`, as the installation guide recommends,
  avoided it. The callback also invalidates the backend's owner token,
  so on PostgreSQL 16, where an exited backend's pid stays in its
  PGPROC slot until the slot is reused, the reaper can take over any
  entry left behind.
- **Out of memory while the backend-local claim set grows.** A growth
  of the set allocates a bucket array twice the size of the current
  one. When that allocation failed, PostgreSQL 16's simplehash had
  already set the doubled size, so the next access to the set read and
  wrote past the end of the array and the backend crashed, taking the
  server through crash recovery. On PostgreSQL 17 and later a growth
  started by a long probe left the grow threshold at zero, so the next
  claim in that backend grew the set again, and while memory stayed
  short every claim failed with out of memory, even into an empty set.
  pg_xclaim now allocates the bucket arrays itself and, when an
  allocation fails, restores the size, mask and grow threshold of the
  array the set still uses before the ERROR propagates, also when one
  insert grows the set twice and the second growth fails. The
  out-of-memory ERROR still aborts the statement, and the set stays
  usable. When the first bucket array of a session did not fit, every
  failed attempt also left a memory context behind until the backend
  exited, and now the failed attempt drops it. 1.0.0-rc1 has the same
  defects. `test/concurrency/local_grow_oom.sh` (Linux, skipped
  elsewhere) caps the address space of one backend and covers an
  aborted transaction, an ERROR caught by plpgsql, a failed second
  growth within one insert and failed creations of the set.

### Changed

- **Extension version 1.0.0-rc2.** The only SQL change is the catalog
  comment of `xclaim.session_reset()`, set by
  `pg_xclaim--1.0.0-rc1--1.0.0-rc2.sql`, which `CREATE EXTENSION` also
  runs to reach 1.0.0-rc2. To update an installation, install the new
  build, restart the server (the library is loaded through
  `shared_preload_libraries`), then run `ALTER EXTENSION pg_xclaim
  UPDATE;` in each database that has the extension.
- **Operator documentation on `cleanup_misses`, `reaped_stale` and
  `session_reset()`.** `cleanup_misses` counts a backend's cleanup
  finding its shared entry gone or owned by someone else, which normal
  operation never does: the incident decision tree (P2) and the runbook
  now treat it as a pg_xclaim defect and advise against
  `pg_xclaim.enabled = off`, which removes mutual exclusion for every
  key. A failing xact callback of another extension does not leave
  claims behind in a running backend, because PostgreSQL then calls the
  callbacks again with the ABORT event (or ends in PANIC), so
  `session_reset()` is no longer described as a remedy for
  `cleanup_misses`. The runbook shows
  how to find claims held outside a transaction with
  `xclaim.debug_snapshot()` and lists what makes `reaped_stale` grow.
- **Documented per-backend claim limit.** A backend can hold at most
  134217727 claims: the cleanup at transaction end allocates one array
  of 8-byte pointers, and PostgreSQL refuses allocations above 1 GB, so
  at 134217728 claims the cleanup fails and the cluster goes into PANIC.
  Reaching it needs `pg_xclaim.max_claims >= 134217728`. See README
  "Limitations" and runbook section 9.
- **Hot-standby guidance.** The hint of the hot-standby error, the
  README, the runbook and the control file now say to keep pg_xclaim in
  `shared_preload_libraries` on replicas: calls fail only while the node
  is in recovery and work after promotion without a restart. The advice
  to remove it from replicas left a promoted standby without pg_xclaim
  until a restart.
- **Corrected sizing and comparison figures.** 200 backends with 100k
  claims each hold 20M claims and need `pg_xclaim.max_claims` of at
  least 20M, not the default 4M. Raising `max_locks_per_transaction`
  to 4096 with 200 connections adds about 334 MB of lock tables, not
  100 KB, and advisory locks cost a backend about 34 MB of local memory
  per 100k held locks, not 17 MB. The README and the runbook tables and
  conclusions are recomputed from these measurements.
- **Benchmark caveats.** In `scripts/bench_alternatives.sh` pg_xclaim
  keeps its claims across the subtransaction rollback of each
  iteration, while the claim-table and row-lock variants release their
  state, and in the overlap runs at 8 backends one worker of eight
  finishes the unsorted claim-table variants (the others stop on
  deadlocks). The README and `docs/perf/` state both limits, and the
  conclusions that rested on those numbers, such as sorted INSERT
  being slower than unsorted, are removed. The hot-path analysis
  describes the profiled scenarios as the scripts run them.
- **Operator procedures.** The runbook and the incident decision tree
  turn on `pg_xclaim.enabled = off` only with client traffic stopped,
  and offer `on_capacity_exhaustion = warn` first on capacity
  exhaustion. The stage 0 and stage 6 gates, the WARNING behaviour of
  `xclaim.try_many` and the capacity headroom figures match the code.
- **Tests check what they describe.** `topmem_leak` runs real
  top-level rollback cycles and compares the size of the local set's
  memory context, `session_reset_public_grant` checks that the refused
  call keeps the claims (under a savepoint), `hot_standby_rejection`
  promotes the standby and takes a claim without a restart, and
  `run_concurrency_suite.sh` reports scripts that exit with 77 as
  skipped.

### Removed

- **Load-time PostgreSQL version check in `_PG_init`.** It compared a
  compile-time value with itself and never fired, so the FATAL that the
  runbook described for it never appeared. PostgreSQL itself rejects a
  library built for another major version before `_PG_init` runs
  (`incompatible library "...": version mismatch`).

## [1.0.0-rc1] - 2026-06-13

First public release candidate of an experimental high-cardinality
claim primitive for PostgreSQL. The public SQL API is frozen, and the
extension passes the full test matrix on PostgreSQL 16, 17, and 18.

### Added

- **Claim API.** `xclaim.try(int8)` and `xclaim.try(int4, int4)` -
  non-blocking transaction-scoped claims with signatures matching
  `pg_try_advisory_xact_lock`. Distinct keyspaces per overload.
- **Bulk API.** `xclaim.try_many(int8[])` and
  `xclaim.try_many(int4, int4[])` - partition-presorted batch
  acquisition (<= `num_partitions` LWLock cycles per array). Result
  element `i` maps to input element `i`. The batch is best-effort, not
  all-or-nothing.
- **Introspection.** `xclaim.count()`, `xclaim.stats()` (atomic
  counters plus capacity gauges, `pg_monitor`), `xclaim.debug_snapshot()`
  (`pg_monitor`, requires `num_partitions <= 192`), and `xclaim.debug()`
  (superuser-only consistent snapshot).
- **Triage.** `xclaim.session_reset()` - reactive local-state clear plus
  owner-token rotation. `xclaim.debug_inject_stale(int4, int4)` -
  test-only stale-entry injector, superuser-only and revoked from
  `PUBLIC`.
- **Partitioned shared-memory storage** sized by `pg_xclaim.max_claims`,
  bypassing the LockManager. Group-by-partition cleanup amortizes
  release to <= `num_partitions` LWLock cycles per transaction.
- **GUCs.** `pg_xclaim.max_claims`, `num_partitions`,
  `expected_claims_per_backend`, `enabled`, `capacity_warn_pct`, and
  `on_capacity_exhaustion` (`error` / `warn`).
- **Per-backend watermark log** when a backend crosses 75% of
  `expected_claims_per_backend`, signaling when to raise the GUC.
- **Build matrix** for PostgreSQL 16 / 17 / 18 with a three-tier test
  suite (pg_regress, capacity, concurrency) plus performance budgets.
- **Operational docs:** DBA runbook, incident decision tree, hot-path
  analysis, and an alternatives benchmark with full methodology.

### Notes

- Experimental: targets a narrow niche (self-hosted PostgreSQL where
  `LWLock:LockManager` is a measured top wait event under
  100k+ claims per transaction). For most workloads a standard
  alternative is the right choice - see the README.
- Deliberate divergences from `pg_try_advisory_xact_lock`: claims are
  released only by the top-level COMMIT/ABORT (they survive
  `ROLLBACK TO SAVEPOINT`), NULL keys raise instead of returning NULL,
  and `PREPARE TRANSACTION` is rejected with `0A000`.
- Not supported on hot-standby replicas or Windows.

[Unreleased]: https://github.com/Fenoman/pg_xclaim/compare/v1.0.0-rc2...HEAD
[1.0.0-rc2]: https://github.com/Fenoman/pg_xclaim/compare/v1.0.0-rc1...v1.0.0-rc2
[1.0.0-rc1]: https://github.com/Fenoman/pg_xclaim/releases/tag/v1.0.0-rc1
