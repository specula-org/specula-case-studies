# Apache Ratis

## Scope

Specula analyzed and tested Apache Ratis's Raft implementation, including pre-vote and priority elections, asynchronous log replication and commit, joint-consensus membership changes, leader-lease and ReadIndex reads, snapshots, and crash recovery.

## Bugs

Specula found 4 new bugs:

- Stale AppendEntries success after a higher-term vote can let an old leader acknowledge an entry absent from the next leader.
- Metadata persistence failure can leave an accepted higher term non-durable across restart.
- Type-only step-down queue deduplication can drop a later higher-term step-down event.
- Async flush failure can still advance `flushIndex` and `commitIndex` and return success.
