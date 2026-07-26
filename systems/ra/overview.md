# Ra

## Scope

Specula analyzed and tested RabbitMQ Ra's Raft state machine, including pre-vote and elections, log replication and commit, consistent queries, snapshot installation, membership changes, and cluster recovery.

## Bugs

Specula found 7 new bugs:

- During leadership transfer, `handle_await_condition` silently drops client commands without replying, leaving clients waiting until timeout; this was fixed in PR #610.
- Candidate state lacks an install-snapshot handler, so a lagging candidate can reject snapshots and remain in an election loop; this was fixed in PR #607.
- Overwriting an uncommitted cluster-change entry can access a missing `previous_cluster` value and crash the follower; this was fixed in PR #600.
- Overwriting a cluster-change entry updates the cluster but not membership, leaving membership stale until apply time; this was fixed in PR #609.
- Processing a PreVote updates the receiver's term, allowing a partitioned node to inflate cluster terms; this was fixed in PR #608.
- Granting a PreVote records `voted_for`, which can block a later real vote for another candidate in the same term; this was fixed in PR #608.
- While receiving a snapshot, client commands and consistent queries receive a permanent unsupported-call error instead of a redirect to the leader; this was fixed in PR #612.
