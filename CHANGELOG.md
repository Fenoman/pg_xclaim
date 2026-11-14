# Changelog

All notable changes to `pg_xclaim` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-rc4] - 2026-11-13

### Fixed

- **Build on Postgres Pro Enterprise 18.** Postgres Pro Enterprise adds
  `XACT_EVENT_START` (autonomous transactions) and
  `XACT_EVENT_COMMIT_COMMAND` (multimaster) to `XactEvent`, and the build
  stopped with `-Werror=switch` in `xclaim_xact_callback`. The Makefile
  checks the server's `access/xact.h` for these events, and the callback
  takes them as no-ops. The server delivers each of them only to callbacks
  registered for its kind, and `RegisterXactCallback` registers pg_xclaim's
  for the vanilla events only.
- **Autonomous transactions no longer release the claims of their parent
  on Postgres Pro Enterprise.** The COMMIT or ABORT of an autonomous
  transaction reaches the xact callback as an ordinary transaction end,
  and the cleanup released every claim of the backend while the parent
  transaction went on: another backend could take a key the parent still
  relied on. While pg_xclaim is in `shared_preload_libraries`, it now marks
  itself incompatible with autonomous transactions
  (`atx_mark_extension_as_incompatible`), and the server refuses
  `BEGIN AUTONOMOUS` and autonomous PL/pgSQL blocks with `pg_xclaim
  extension is incompatible with autonomous transactions`. timescaledb in
  `shared_preload_libraries` already makes the server refuse them.
  `test/concurrency/autonomous_xact.sh` covers it and is skipped on servers
  without the Enterprise autonomous-transaction API, including Tantor SE.
- **A backend stays responsive to cancel, timeouts and terminate after an
  ERROR inside pg_xclaim.** PostgreSQL zeroes the interrupt holdoff count
  before an ERROR reaches a `PG_CATCH`, and the handlers that released their
  own partition LWLocks decremented it once more, so the backend ignored
  `pg_cancel_backend`, `statement_timeout` and `pg_terminate_backend` until
  its next ERROR (an assertion failure on a cassert build). The handlers
  restore the count first, as `LWLockReleaseAll` does. `xclaim.try` and
  the debug functions no longer keep such a handler at all. Test 3 of
  `test/concurrency/local_grow_oom.sh` (Linux) makes the handler of
  `xclaim.try_many` run and checks `statement_timeout` afterwards,
  `test/sql/error_keeps_interrupts.sql` checks the debug functions.
- **`xclaim.session_reset()` no longer releases the claims of the running
  transaction.** The guard covered an explicit `BEGIN` only: a function, a DO
  block or `SELECT xclaim.try(...), xclaim.session_reset()` in autocommit
  released the claims of its own transaction, and another session could
  take the key while it still ran. It now raises
  `ERRCODE_ACTIVE_SQL_TRANSACTION` while the local set holds a claim of the
  running transaction, and inside an `xclaim.try_many` loop (an
  `emit_log_hook` on its capacity WARNING), where the loop goes on to take
  claims under the token the reset would rotate.
  `test/sql/session_reset_running_xact.sql` and
  `test/concurrency/hook_error_paths.sh` cover it.
- **Interrupts are processed before the reentrancy probe.** `xclaim.try`
  checks interrupts first, before any state is read, and `xclaim.try_many`
  checks them before the probe of every slot it handles with no partition
  lock held. A message written by the interrupts can reach an
  `emit_log_hook` that runs SQL: an `xclaim.try` of the key the call was
  about to take was counted twice (`xclaim.count()`, the peak), and a
  `session_reset()` there left the claim with owner token 0.
  `xclaim.session_reset()` writes its DEBUG1 line last, after the reset.
  `test/concurrency/hook_error_paths.sh` Tests 3 to 5 cover it.
- **Out of memory with `exit_on_error = on` while the local set grows.**
  The allocator of the set restored the geometry of the array in use in a
  `PG_CATCH`, which a FATAL skips. On PostgreSQL 16, where simplehash sets
  the doubled geometry before the allocation, the cleanup at backend exit
  then read past the end of the array. The allocator now allocates with
  `MCXT_ALLOC_NO_OOM` and restores the geometry before the ERROR is
  raised. `test/concurrency/local_grow_oom.sh` Test 5 (Linux) runs the
  growth with `exit_on_error = on` and checks that the server survives
  and the exit releases every claim. Known limit: such a FATAL inside a
  `try_many` partition run leaves the row of the slot being inserted until
  a conflicting acquisition reaps it, and `live_capacity` stays below the
  table by that row and the rows of the run not yet added to it, until
  the server restarts.
- **`capacity_used` stays equal to the shared rows when `xclaim.try_many`
  is interrupted.** `try_many` added its rows to the counter once after the
  loop. A FATAL inside the loop (`pg_terminate_backend`,
  `transaction_timeout`, a lost client) ran the exit cleanup, which
  subtracted rows never added, and a cancel after the addition left it too
  high. Both lasted until restart: `xclaim.stats()` showed a wrong
  `capacity_used` and `capacity_pct`, and the watermark stayed silent or
  logged false crossings. The rows of a partition run are added before its
  lock is released. `test/concurrency/bulk_fatal_capacity.sh` covers it.
- **The out-of-memory path of transaction-end cleanup is linear.** When the
  cleanup could not allocate its arrays, it restarted its walk over the
  local set for every claim: a COMMIT of 200,000 claims took minutes, with
  interrupts held and the keys taken. It is one walk.
  `test/concurrency/cleanup_oom_fallback.sh` covers it (Linux).
- **`xclaim.debug()` and `xclaim.debug_snapshot()` no longer stop every
  acquisition while they build their result.** They held every partition
  lock while they filled the result, with temporary files and catalog
  lookups under the locks: a snapshot of 2M claims stopped every
  `xclaim.try` for 0.7 s. They copy the entries under the locks and build
  the result after the release: about 0.13 s under the locks per million
  rows on a 2-vCPU stand, and 48 bytes of backend memory per row for the
  call, plus 1/8 and 64 rows of headroom (about 54 MB for a million rows). The copy is sized from `capacity_used` and checked under the locks,
  and `debug_scans` counts completed copies.
- **`xclaim.try_many` no longer keeps a partition lock over keys the
  backend already holds.** The check for a key the backend holds ran
  before the switch to the next partition: after a new key, every
  following held key of later partitions kept the new key's partition
  locked, with interrupts held, until the end of the array. Another
  backend's `xclaim.try` in that partition waited up to 40 ms behind a
  repeated call over 1.5M held keys and one new key. The lock of a
  partition run is released at the run boundary, before that check, and
  interrupts are processed there. `test/concurrency/bulk_reentrant_lock.sh`
  covers it.
- **No messages under a partition LWLock.** The 75%-of-
  `expected_claims_per_backend` LOG and a capacity watermark check per
  `try_many` element ran under the partition lock, where writing a message
  can block on the client socket. The LOG goes out after the release with
  the count at the crossing, and `try_many` checks the watermark once after
  its loop, after it has restored its WARN-suppression state, so a cancel
  while a message is written leaves no suppression behind.
  `xclaim.session_reset()` also drops a LOG still pending.
- A negative `classid` no longer shifts a signed value past its range when
  the pair key is packed. `test/sql/pair_key_negative.sql` covers it.
- The build stops when the server headers declare `XACT_EVENT_START` but
  the Makefile probe does not find `atx_mark_extension_as_incompatible`,
  instead of building without the refusal of autonomous transactions.
- The incident decision tree no longer advises turning pg_xclaim off at
  95% capacity: `pg_xclaim.enabled = off` lifts mutual exclusion for every
  key. It advises finding the transactions that hold claims, switching to
  `on_capacity_exhaustion = warn` and planning a `max_claims` raise with a
  restart.

### Changed

- **`pg_xclaim.enabled = off` stops new acquisitions only.**
  `xclaim.count()`, `xclaim.debug()` and `xclaim.debug_snapshot()` keep
  reporting the claims taken before the switch until their transactions
  end, and `disabled_calls` counts `xclaim.try` calls and `xclaim.try_many`
  elements only, not the observability calls.
- **The end of a short transaction no longer depends on the size of the
  local set.** The cleanup walked and zeroed the whole bucket array, which
  never shrank: a transaction with one claim cost 39 us with the default
  set and 1.29 ms after one 750k-claim transaction in the same backend, and
  the same with `expected_claims_per_backend = 750000`. It now looks up the
  keys taken since the last cleanup: about 1.3 us in all three cases.
  `test/concurrency/short_xact_cost.sh` covers it.
- **The local set grows without the partition LWLock.** Other backends
  waited for its rehash under the lock, up to 30 ms per growth at 750k
  claims. `xclaim.try` adds its local entry before it takes the lock and
  records it as held (live count, peak, held-key list, 75% hint) only
  after the shared insert. On a conflict or a capacity miss it drops the
  entry after the release, so a failed call leaves the count, peak, list
  and hint unchanged. Its only `PG_TRY` is around `LWLockAcquire`, which
  drops the entry when the backend holds too many LWLocks.
  `xclaim.try_many` reserves room before it takes a partition lock, sized
  by the rest of the run: a call whose keys are taken by others or
  repeated no longer enlarges the set by the whole array. simplehash
  reuses the stored hash of an entry instead of recomputing it.
  Known limit: the reservation prevents only growth by the fill
  threshold. The keys of one `try_many` run start their probes from
  1/`num_partitions` of the buckets, so the set grows by long probes from
  a fill of about 0.1 inside the run, under its partition lock. One
  750,000-key call with default settings on PostgreSQL 17 grows the set
  five times, at 3,825 to 105,144 entries, and rehashes about 165,000
  entries under partition locks in total. After a shrink the next large
  `try_many` gives the set, before its first lock, twice the room the
  claims of the transaction need, up to the largest size the set shrank
  from, so under the locks the set grows only when the backend has not
  had a set of the needed size before (with keys the hash spreads evenly
  over the partitions).
- **The local set shrinks after a burst.** The bucket array grown by a
  large transaction stayed for the life of the backend. After 64
  transactions in a row that took at least one claim and no more than the
  first array holds, the next claim gives a set 4 or more times its first
  size an array of that size, and `xclaim.session_reset()` does it at
  once. A `try_many` that needs half of the first array or more starts
  the count over only while the set is less than 4 times the size the
  call needs. Otherwise, once the count is complete, the call shrinks the
  set itself and grows it to that size before its first lock. The held-key
  list grows with the set (1/64 of its buckets), so transactions with
  thousands of claims in a large set also skip the full walk.
- The transaction-end cleanup allocates its arrays with
  `MCXT_ALLOC_HUGE`: a backend can hold more than 2^27 claims without a
  PANIC at COMMIT (the arrays passed 1 GB).
- `xclaim.try_many` frees its element arrays and the detoasted input as
  soon as it no longer needs them, and with `enabled = off` returns without
  building and hashing the keys.
- **Shared memory: 1% headroom instead of 25%.** The table is allocated in
  full at startup and `hash_estimate_size()` covers it exactly, so the
  headroom was never used: the default `max_claims = 4M` takes ~291 MB
  instead of ~360 MB, 16M ~1.14 GB instead of ~1.4 GB. The headroom is at
  least 8 kB for the rounding of a small `max_claims`.
- A local entry takes 48 bytes also with a 64-bit `LocalTransactionId`
  (Tantor SE, Postgres Pro Enterprise), 56 before.

- **Extension version 1.0.0-rc4.** `pg_xclaim--1.0.0-rc3--1.0.0-rc4.sql`
  changes no SQL object other than five comments, which describe the
  1.0.0-rc4 library: both `xclaim.try_many` forms name the extra LWLock
  cycle per capacity miss in warn mode, `xclaim.debug()` and
  `xclaim.debug_snapshot()` build their result after releasing the
  partition locks, and `xclaim.session_reset()` names its refusals and the
  shrink of the local set. A fresh install runs the script too and gets the same
  text. `test/sql/extension_version.sql` checks both paths. To update an
  installation, install the new build, restart the server, then run
  `ALTER EXTENSION pg_xclaim UPDATE;` in each database that has the
  extension (the postgrespro-docker entrypoint does it at start).

## [1.0.0-rc3] - 2026-10-22

### Fixed

- **Build on Tantor SE 18.** Tantor SE adds `XACT_EVENT_PRE_ABORT` and
  `XACT_EVENT_PARALLEL_PRE_ABORT` to `XactEvent`, and the build stopped
  with `-Werror=switch` in `xclaim_xact_callback`. The Makefile checks
  the server's `access/xact.h` for these events, and the callback takes
  them as no-ops: Tantor SE fires them at the start of the abort, and
  the same abort later delivers `XACT_EVENT_ABORT`, which releases the
  claims, as on PostgreSQL. Builds against PostgreSQL are unchanged.

### Changed

- **Extension version 1.0.0-rc3.** No SQL object changes:
  `pg_xclaim--1.0.0-rc2--1.0.0-rc3.sql` only moves the version. To
  update an installation, install the new build, restart the server,
  then run `ALTER EXTENSION pg_xclaim UPDATE;` in each database that has
  the extension. On PostgreSQL the library behaves as 1.0.0-rc2: the
  new cases compile only against server headers that declare the
  events.

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

[Unreleased]: https://github.com/Fenoman/pg_xclaim/compare/v1.0.0-rc4...HEAD
[1.0.0-rc4]: https://github.com/Fenoman/pg_xclaim/compare/v1.0.0-rc3...v1.0.0-rc4
[1.0.0-rc3]: https://github.com/Fenoman/pg_xclaim/compare/v1.0.0-rc2...v1.0.0-rc3
[1.0.0-rc2]: https://github.com/Fenoman/pg_xclaim/compare/v1.0.0-rc1...v1.0.0-rc2
[1.0.0-rc1]: https://github.com/Fenoman/pg_xclaim/releases/tag/v1.0.0-rc1
