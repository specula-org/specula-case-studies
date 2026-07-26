# RedisRaft

## Scope

Specula analyzed and tested RedisRaft's consensus and sharding core, including pre-vote and elections, log replication and commit, reads after leader changes, membership changes and leader transfer, snapshots, persistence, and crash recovery.

## Bugs

Specula found 2 new bugs:

- A shard-group deserialization failure returns before replying to the waiting client, leaving the connection blocked indefinitely.
- `archiveSnapshot()` allocates too little space for its backup filename, truncating the path and silently renaming the snapshot to the wrong target.
