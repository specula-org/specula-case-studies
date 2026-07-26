# async-raft

## Scope

Specula analyzed and tested async-raft's Raft core, including elections, log replication and commitment, heartbeats, joint-consensus membership changes, and coordination between the serialized core, per-follower replication tasks, and state-machine application.

## Bugs

Specula found 8 new bugs:

- A client read can continue counting confirmations after a higher-term response has deposed the leader, allowing the read to succeed on a follower.
- The client-read path updates the current term without persisting hard state, so a crash can lose the updated vote record and permit double voting.
- The client-read quorum calculation uses `N/2` instead of `(N+1)/2`, allowing an isolated leader to confirm a read without any follower; PR #143 remains open.
- `commitIndex` is updated before log-consistency validation while follower `matchIndex` starts optimistically at the leader's last index, allowing commitment beyond a consistent replicated prefix.
- Snapshot installation updates `lastApplied` and `snapshotIndex` but not `commitIndex`, leaving the committed index behind the installed snapshot.
- Promoting a non-voter does not move its replication state into the voter map, so the promoted member is omitted from commit-quorum calculation.
- Removed members can retain replication streams indefinitely because removal waits for them to replicate the configuration entry; Issue #112 records the problem.
- The vote up-to-date check uses a conjunction instead of Raft's lexicographic comparison, rejecting candidates whose last log term is newer but whose log is shorter.
