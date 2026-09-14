# CloudNativePG

## Scope

Specula analyzed and tested CloudNativePG's primary leases, automated failover, synchronous replication configuration, and quorum metadata used by the operator.

## Bugs

Specula found 1 new bug:

- Stale `FailoverQuorum` cache data can authorize promotion of a replica missing an acknowledged transaction after the synchronous quorum is reduced.
