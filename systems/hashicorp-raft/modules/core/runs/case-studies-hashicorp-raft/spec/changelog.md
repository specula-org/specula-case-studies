# hashicorp-raft Spec Validation Changelog

## Round 1 - Trace Validation

- All 4 traces pass: basic_election (362 lines), client_request (368), config_change (873), leader_failure (557)

## Round 1 - Model Checking

- [fix-spec] HandleAppendEntriesRequest: unconditional log truncation (`SubSeq(log[i], 1, prevLogIndex) \o entries`) replaced with conflict-aware `MergeEntries` that walks entries and only truncates on actual conflict (different term at same index). Matches raft.go:1541-1565 conflict check logic. Without this, a stale AppendEntries delivered after a newer one truncates committed entries. (Case B)
- [fix-inv] LeaderCompleteness: added guard `log[other][idx].term <= currentTerm[leader]` so stale leaders from earlier terms are not required to have entries committed in later terms. Raft paper's Leader Completeness only applies to leaders for term >= the committed entry's term. (Case A)
- [fix-inv] LeaderLogCompleteness: same guard as LeaderCompleteness. (Case A)
- BFS: 777M states, 133M distinct, depth 16, 21 minutes — no violations
- Simulation: 682M states, 7.85M traces, depth 100, 15 minutes — no violations

## Round 1 - Convergence

- Trace re-validation after spec changes: all 4 traces pass
- Spec modified (MergeEntries) + invariants weakened → re-validated traces → pass
- MC simulation after all changes → 682M states, no violations
- **Converged in Round 1**

## Bug Hunting

- ~~[bug] NoPhantomContact: BFS found violation in 10 states, 6 seconds (MC_hunt_phantom_lease.cfg)~~ **RETRACTED** — spec fidelity issue (see below)
- ~~[bug] LeaseImpliesLoyalty: BFS found violation in 11 states, 11 seconds (MC_hunt_lease_loyalty.cfg)~~ **RETRACTED** — spec fidelity issue (see below)
- MC_hunt_persist_vote.cfg: BFS 933M states (depth 16, 17 min) + simulation 554M states (7.7M traces) — no violations
- MC_hunt_config_safety.cfg: BFS 840M states (depth 16, 17 min) + simulation 378M states (5M traces) — no violations

## Bug Retraction (2026-03-18)

Both Bug Family 1 violations (NoPhantomContact, LeaseImpliesLoyalty) are retracted after maintainer review at https://github.com/hashicorp/raft/issues/666.

**Root cause**: The spec's `Timeout(i)` action does not model the real system's election timeout suppression by heartbeat receipt. In hashicorp/raft, a follower receiving heartbeats resets its election timer (`setLastContact()` at raft.go:1580) and rejects vote requests from other candidates (leader contact check at raft.go:1650-1656). This means followers **cannot reach a higher term** while heartbeats are flowing, so the phantom contact precondition (follower at higher term responds to heartbeat) is unreachable in the real system.

The real bug is a **liveness** issue (disk-stalled leader's heartbeats prevent follower elections, cluster stuck), not the **safety** issue we reported (stale reads from phantom lease quorum). Maintainers confirmed and are working on a fix.

## Result
Converged in 1 round. Bug hunting: **0 bugs found** (2 reported, 2 retracted due to spec fidelity gap).
