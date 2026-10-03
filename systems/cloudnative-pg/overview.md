# CloudNativePG

## Scope

Specula analyzed and tested CloudNativePG's primary leases, automated failover, synchronous replication configuration, and quorum metadata used by the operator.

## Bugs

Specula found 1 new bug:

- **Reported:** Stale `FailoverQuorum` cache data can authorize promotion of a replica missing an acknowledged transaction after the synchronous quorum is reduced; see [issue #11500](https://github.com/cloudnative-pg/cloudnative-pg/issues/11500) and [PR #11561](https://github.com/cloudnative-pg/cloudnative-pg/pull/11561), still open as of 2026-10-03.
