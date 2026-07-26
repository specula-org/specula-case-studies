# braft

## Scope

Specula analyzed and tested braft's Raft core, including elections and PreVote, log and snapshot replication, quorum and commit tracking, joint membership changes, leader transfer, two-sided leases, witness nodes, and recovery paths.

## Bugs

Specula found 4 new bugs:

- During a configuration change, committing one entry can force-commit earlier uncommitted entries without their own quorum.
- If election-state persistence fails, `elect_self` resets the vote but does not roll back the incremented current term.
- A null snapshot-completion callback prevents cleanup of `SaveSnapshotDone` and its `SnapshotWriter`; PR #522 remains open.
- The replicator does not close a snapshot reader when loading snapshot metadata fails; PR #521 remains open.

The bug tracker also records 1 known bug examined by Specula:

- A leader always grants PreVote after `become_leader` resets its follower lease, allowing a rebooted node to disrupt a stable cluster; Issues #365 and #492 and PR #366 remain open.
