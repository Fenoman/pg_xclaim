# Security policy

## Supported versions

`pg_xclaim` is in **release-candidate** state. Security fixes land on
the current tag (`v1.0.0-rc1`) and on `main`.

| Version | Security fixes |
|---------|----------------|
| `v1.0.0-rc1` (current) / `main` | Yes |

PostgreSQL major-version matrix: PG 16, 17, 18 (upstream and
ABI-compatible forks). Security fixes apply to all three majors
simultaneously.

## Reporting a vulnerability

Suspected security issues include:

- Memory corruption (use-after-free, out-of-bounds read/write, double
  free in shared memory or backend-local state).
- Privilege escalation (any path that lets a non-superuser observe or
  modify state they shouldn't, including bypass of the `pg_monitor` /
  superuser gates on `xclaim.debug` and `xclaim.debug_inject_stale`).
- Denial-of-service via the SQL surface (a single non-superuser call
  that crashes the cluster, exhausts shared memory irrecoverably, or
  permanently deadlocks the LockManager).
- Anything that breaks the cleanup-correctness invariant
  (`cleanup_misses` increasing without a clear root cause; orphaned
  shared rows that the reaper cannot collect).

**Do not file a public GitHub issue for security reports.** Instead,
use [GitHub Security Advisories](https://github.com/Fenoman/pg_xclaim/security/advisories/new)
to send a private report. The maintainer will acknowledge within five
business days and coordinate disclosure.

When reporting, please include:

- PostgreSQL version (`SELECT version();`).
- `pg_xclaim` version (`SELECT extversion FROM pg_extension WHERE extname = 'pg_xclaim';`).
- Minimal reproduction (SQL or shell snippet).
- Observed behaviour and the impact you believe it has.
- Whether the issue is already public (e.g. discussed on a mailing
  list); if so, where.

## What is not a security issue

- Performance regressions or sizing surprises under legitimate load
  (`capacity_errors > 0`, `cleanup_misses > 0` because the cluster
  outgrew its `pg_xclaim.max_claims` budget). Open a regular GitHub
  issue with `xclaim.stats()` output and the server log excerpt -- see
  `.github/ISSUE_TEMPLATE/bug_report.md`.
- Documented limitations: 2PC rejection at `PRE_PREPARE`, hot-standby
  refusal, managed-cloud incompatibility, `num_partitions <= 192` cap
  for `xclaim.debug_snapshot()`.
- Build failures on a PostgreSQL major outside the supported matrix
  (PG 16 / 17 / 18 upstream + ABI-compatible forks).

## Acknowledged exposure: deliberate capacity exhaustion

The claim table is a fixed-size shared structure sized by
`pg_xclaim.max_claims`. An untrusted role with `EXECUTE` on
`xclaim.try` / `xclaim.try_many` can deliberately exhaust it, forcing
`on_capacity_exhaustion=error` to raise for other sessions. This is the
same class as PostgreSQL's own shared lock-table exhaustion (the
"out of shared memory" failure of `pg_try_advisory_xact_lock` once
`max_locks_per_transaction` is consumed): a global, fixed-size pool
that any grantee can fill.

On multi-tenant clusters, treat the SQL surface as a privileged
resource and `REVOKE EXECUTE` from untrusted roles:

```sql
REVOKE EXECUTE ON FUNCTION xclaim.try(int8)            FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION xclaim.try(int4, int4)      FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION xclaim.try_many(int8[])     FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION xclaim.try_many(int4, int4[]) FROM PUBLIC;
```

Setting `pg_xclaim.on_capacity_exhaustion=warn` degrades to a failed
acquisition (the call returns `false` instead of raising), which keeps
unrelated sessions running but lets the exhausting role deny claims to
others. Privilege restriction is the primary mitigation; the `warn`
fallback only softens the blast radius.

## Disclosure policy

Coordinated disclosure. After a fix is ready, a GitHub Security
Advisory is published, the patch lands on `main` and a new release
tag, and the advisory becomes public. Reporters are credited unless
they request otherwise.
