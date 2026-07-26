# Tarantool

## Scope

Specula analyzed and tested Tarantool's Raft leader-election engine, including terms and votes, WAL-backed persistence, election and leader-witness handling, promote and demote transitions, fencing, and leader-health handling.

## Bugs

Specula found 1 new bug:

- A delayed positive leader-witness report can restore a remote witness bit after the leader resigns, blocking elections while the cluster is leaderless.
