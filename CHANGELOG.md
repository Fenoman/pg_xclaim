# Changelog

All notable changes to `pg_xclaim` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-rc1] - 2026-06-13

First public release candidate of an experimental high-cardinality
claim primitive for PostgreSQL. The public SQL API is frozen; the
extension passes the full test matrix on PostgreSQL 16, 17, and 18.

### Added

- **Claim API.** `xclaim.try(int8)` and `xclaim.try(int4, int4)` —
  non-blocking transaction-scoped claims with signatures matching
  `pg_try_advisory_xact_lock`. Distinct keyspaces per overload.
- **Bulk API.** `xclaim.try_many(int8[])` and
  `xclaim.try_many(int4, int4[])` — partition-presorted batch
  acquisition (≤ `num_partitions` LWLock cycles per array). Result
  element `i` maps to input element `i`; best-effort, not
  all-or-nothing.
- **Introspection.** `xclaim.count()`, `xclaim.stats()` (atomic
  counters plus capacity gauges, `pg_monitor`), `xclaim.debug_snapshot()`
  (`pg_monitor`, requires `num_partitions <= 192`), and `xclaim.debug()`
  (superuser-only consistent snapshot).
- **Triage.** `xclaim.session_reset()` — reactive local-state clear plus
  owner-token rotation. `xclaim.debug_inject_stale(int4, int4)` —
  test-only stale-entry injector, superuser-only and revoked from
  `PUBLIC`.
- **Partitioned shared-memory storage** sized by `pg_xclaim.max_claims`,
  bypassing the LockManager. Group-by-partition cleanup amortizes
  release to ≤ `num_partitions` LWLock cycles per transaction.
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
  alternative is the right choice — see the README.
- Deliberate divergences from `pg_try_advisory_xact_lock`: claims are
  released only by the top-level COMMIT/ABORT (they survive
  `ROLLBACK TO SAVEPOINT`); NULL keys raise instead of returning NULL;
  `PREPARE TRANSACTION` is rejected with `0A000`.
- Not supported on hot-standby replicas or Windows.

[1.0.0-rc1]: https://github.com/Fenoman/pg_xclaim/releases/tag/v1.0.0-rc1
