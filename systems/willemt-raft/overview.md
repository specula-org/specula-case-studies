# willemt/raft

## Scope

Specula analyzed and tested willemt/raft's consensus core, including elections and vote handling, AppendEntries replication and commit advancement, snapshots and compaction, membership changes, and persistence and recovery.

## Bugs

Specula found 5 new bugs:

- An out-of-bounds `current_idx` in an AppendEntries response reaches a null entry dereference when assertions are disabled, crashing release builds.
- `log_clear_entries` iterates one slot past the valid range and invokes the cleanup callback on an uninitialized ghost entry.
- `log_free` releases the entry array without invoking entry cleanup callbacks, leaking user-allocated data at shutdown.
- `send_appendentries_all` returns when the first peer needs a snapshot, preventing later peers from receiving heartbeats.
- An off-by-one follower index and a stale flag after leader step-down can leave `voting_cfg_change_log_idx` set permanently and block later membership changes.
