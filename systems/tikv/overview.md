# TiKV

## Scope

Specula analyzed and tested TiKV's raft-rs library and raftstore integration, including pre-vote and elections, log replication and commit, leader-lease and ReadIndex reads, joint-consensus membership changes, asynchronous persistence, and snapshot and region lifecycles.

## Bugs

Specula found 3 new bugs:

- Automatic exit from joint consensus is proposed only by the current leader, so if the leader crashes before applying enter-joint and the joint configuration includes unreachable nodes, the remaining nodes can stay stuck in joint consensus.
- A leader removed from the voter set remains leader and continues sending heartbeats that suppress elections on the remaining voters.
- Leader transfer to a lower-priority node can fail because transfer elections bypass the lease check but not the priority check, leaving the cluster without a leader.

The bug tracker also records 1 known bug examined by Specula:

- At term zero, rejecting a lower-priority PreVote constructs a zero-term response that violates the send-path assertion and crashes the node.
