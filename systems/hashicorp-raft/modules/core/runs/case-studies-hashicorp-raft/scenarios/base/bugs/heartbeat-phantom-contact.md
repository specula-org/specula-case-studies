# ~~Missing resp.Term check in heartbeat causes phantom contact~~ — RETRACTED

**Issue**: https://github.com/hashicorp/raft/issues/666
**Status**: RETRACTED (2026-03-18) — spec fidelity issue, not a real safety bug

## Original Claim

`heartbeat()` (`replication.go:423`) calls `setLastContact()` unconditionally when the transport succeeds, without checking `resp.Term`. Both `replicateTo()` (line 239) and `pipelineDecode()` (line 548) check `resp.Term > req.Term` before calling `setLastContact()`.

When `replicate()` is blocked on disk IO, only `heartbeat()` sends RPCs. A follower that has moved to a higher term rejects the heartbeat, but `heartbeat()` still records it as a successful contact. `checkLeaderLease()` counts these phantom contacts toward quorum, keeping the stale leader alive indefinitely.

## Why Retracted

The scenario requires a follower to reach a higher term while still receiving heartbeats from the leader. Maintainer @tgross showed this is impossible:

1. **Heartbeats suppress election timeout**: Followers receiving heartbeats call `setLastContact()` (raft.go:1580), resetting their election timer. They never time out and never start elections.
2. **Leader contact blocks voting**: Even if a partitioned node requests votes, followers with recent leader contact reject (raft.go:1650-1656).

Therefore, term divergence cannot occur while heartbeats are flowing, and the missing `resp.Term` check is irrelevant.

## What IS Real

The maintainers confirmed a **liveness** issue: when a leader's disk stalls, heartbeats continue (by design), preventing followers from electing a new leader. The cluster gets stuck — no commits, no recovery. This is a liveness bug, not a safety bug (no stale reads).
