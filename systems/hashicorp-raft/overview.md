# HashiCorp Raft

## Scope

Specula analyzed and tested HashiCorp Raft's core, including elections and PreVote, log replication, leader leases, configuration changes, snapshots, leadership transfer, vote persistence, and coordination among the main loop, replication, heartbeat, snapshot, and FSM goroutines.

## Bugs

Specula found 2 new bugs:

- Independent heartbeats can maintain the leader lease while replication is blocked on disk I/O, preventing follower election even though the cluster cannot commit; Issue #666 records the fixed issue.
- The `requestPreVote` metrics path retained the copied `requestVote` label; PR #665 fixed it.

The bug tracker also records 1 known bug examined by Specula:

- If suffix deletion succeeds but storing replacement logs fails, the cached last-log index and term still point to deleted entries; the developer TODO remains open for non-transactional log stores.
