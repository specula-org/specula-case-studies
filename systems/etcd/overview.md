# etcd/raft

## Scope

Specula analyzed and tested etcd/raft's Raft module, including elections and PreVote, replication and message release around persistence, joint consensus, lease reads and ReadIndex, asynchronous storage writes, snapshots, and leadership transfer.

## Bugs

Specula found 1 new bug:

- Probe mode can send a redundant `MsgApp` even when `MsgAppFlowPaused` should block additional append messages; PR #381 remains open.

The bug tracker also records 1 known bug examined by Specula:

- Lease-based reads can return stale data from a partitioned former leader before `CheckQuorum` expires its lease; Issues #166 and #99 record the fixed design flaw.
