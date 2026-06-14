---
name: Bug report
about: Report incorrect behaviour, crash, or correctness regression in pg_xclaim
title: ''
labels: bug
assignees: ''
---

<!--
For SUSPECTED SECURITY ISSUES (memory corruption, privilege escalation,
DoS via SQL surface), do NOT open a public issue. Follow the process in
.github/SECURITY.md: report privately via GitHub Security Advisories at
https://github.com/Fenoman/pg_xclaim/security/advisories/new
-->

## Environment

- PostgreSQL version: <!-- output of `SELECT version();` -->
- OS + architecture: <!-- output of `uname -a` -->
- pg_xclaim version: <!-- `SELECT extversion FROM pg_extension WHERE extname = 'pg_xclaim';` -->

## xclaim.stats() snapshot

```
<!-- paste output of `SELECT * FROM xclaim.stats();` here -->
```

## Steps to reproduce

<!-- Minimal SQL or shell snippet that triggers the issue. -->

```sql

```

## Expected behaviour

<!-- What you thought should happen. -->

## Actual behaviour

<!-- What actually happens, including any error message + SQLSTATE. -->

## Server log excerpt

<!--
Relevant lines from postgresql.log around the time of the incident.
Strip any sensitive data first.
-->

```
```

## Additional context

<!-- GUC settings, pooler config, anything else that might be relevant. -->
