# raft-java

## Scope

Specula analyzed and tested raft-java's Raft core, including pre-vote and elections, log replication and commit-index advancement, persistence, snapshots, and configuration changes.

## Bugs

Specula found 2 new bugs:

- Installing a snapshot does not update `commitIndex`, `lastAppliedIndex`, or the configuration, leaving the node on stale state after installation.
- `requestVote` rejects an identical retry from the candidate that already received the vote, causing unnecessary election timeouts under message loss.

The bug tracker also records 3 known bugs examined by Specula:

- A stale heartbeat can regress and persist a follower's `commitIndex` because the update has no monotonicity guard.
- A delayed heartbeat response can roll back a leader's `matchIndex` because peer progress updates have no monotonicity guard.
- `startVote()` sends RequestVote messages without first persisting the new term and vote, so a crash can erase the election state and permit a double vote.
