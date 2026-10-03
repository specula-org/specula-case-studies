# etcd/raft

## Scope

Specula analyzed and tested etcd/raft's Raft module, including elections and PreVote, replication and message release around persistence, joint consensus, lease reads and ReadIndex, asynchronous storage writes, snapshots, and leadership transfer.

## Bugs

Specula found 1 new bug:

- **Open:** Probe mode can send a redundant `MsgApp` even when `MsgAppFlowPaused` should block additional append messages; see PR #381.

Specula also found 1 previously known bug:

- **Fixed:** Lease-based reads can return stale data from a partitioned former leader before `CheckQuorum` expires its lease; see Issues #166 and #99.

## Historical CI evaluation

The [September 2026 evolution collection](modules/raft/runs/etcd-raft-ci-evolution-20260923/README.md) studies historical versions, including per-version finding dispositions and model/invariant evolution. Historical rediscoveries, repeated confirmations, and model-only candidates are kept separate from the bug counts above.
