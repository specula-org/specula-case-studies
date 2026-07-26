# HashiCorp Raft

## Scope

Specula analyzed and tested HashiCorp Raft's core, including elections and PreVote, log replication, leader leases, configuration changes, snapshots, leadership transfer, vote persistence, and coordination among the main loop, replication, heartbeat, snapshot, and FSM goroutines.

## Bugs

Specula found 2 new bugs:

- **Fixed:** Independent heartbeats can maintain the leader lease while replication is blocked on disk I/O, preventing follower election even though the cluster cannot commit; see Issue #666.
- **Fixed:** The `requestPreVote` metrics path retained the copied `requestVote` label; see PR #665.

Specula also found 1 previously known bug:

- **Open:** If suffix deletion succeeds but storing replacement logs fails, the cached last-log index and term still point to deleted entries; a developer TODO documents the problem for non-transactional log stores.
