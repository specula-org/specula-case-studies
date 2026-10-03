# TiKV

## Scope

Specula analyzed and tested TiKV's raft-rs library and raftstore integration, including pre-vote and elections, log replication and commit, leader-lease and ReadIndex reads, joint-consensus membership changes, asynchronous persistence, and snapshot and region lifecycles.

## Bugs

Specula found 3 new bugs:

- Automatic exit from joint consensus is proposed only by the current leader, so if the leader crashes before applying enter-joint and the joint configuration includes unreachable nodes, the remaining nodes can stay stuck in joint consensus.
- **Approved:** A leader removed from the voter set remains leader and continues sending heartbeats that suppress elections on the remaining voters.
- **Reported:** With equal logs and enough higher-priority voters to block election, an explicit transfer to a lower-priority node can fail because transfer votes bypass the lease check but not the priority check. The old leader steps down, leaving a leaderless term; [PR #597](https://github.com/tikv/raft-rs/pull/597) remains open as of 2026-10-03. The demonstrated consequence is availability loss, not a data-safety violation.

Specula also found 1 previously known bug:

- **Open:** At term zero, rejecting a lower-priority PreVote constructs a zero-term response that violates the send-path assertion and crashes the node.
