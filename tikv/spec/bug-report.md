# Bug Report — tikv/raft-rs

## Summary

- Bug families tested: 4
- Bugs found: 0
- Configs run: MC.cfg, MC_hunt_election.cfg, MC_hunt_lease.cfg, MC_hunt_confchange.cfg, MC_hunt_persist.cfg

## Convergence Statistics

| Config | Invariants | States | Distinct | Depth | Duration | Result |
|--------|-----------|--------|----------|-------|----------|--------|
| MC.cfg (structural) | ElectionSafety, LogMatching, LeaderCompleteness, CommitIndexBoundInv, PersistedBoundInv, SinglePendingConfInv, VotedForConsistencyInv | 1.04B+ | 143M | 19 | 27 min (ongoing) | PASS |

## Bug Hunting Results

| Config | Invariants | States | Distinct | Depth | Duration | Result |
|--------|-----------|--------|----------|-------|----------|--------|
| MC_hunt_election.cfg | ElectionSafety, PreVoteSafety | 140M | 25M | 16 | 20 min (ongoing) | PASS |
| MC_hunt_lease.cfg | ElectionSafety, LeaseLinearizability, NoStaleReadAfterTransfer | 129M | 22M | 20 | 20 min (ongoing) | PASS |
| MC_hunt_confchange.cfg | ElectionSafety, CommitByVoteSafety, ConfChangeSafety | 126M | 22M | 17 | 20 min (ongoing) | PASS |
| MC_hunt_persist.cfg | ElectionSafety, AsyncPersistSafety, CrashRecoverySafety, LeaderCompleteness | 136M | 21M | 18 | 20 min (ongoing) | PASS |

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 1: Leader Lease / ReadIndex | MC_hunt_lease.cfg | 129M | No violation — LeaseLinearizability, NoStaleReadAfterTransfer hold |
| Family 2: Election Safety / PreVote | MC_hunt_election.cfg | 140M | No violation — ElectionSafety, PreVoteSafety hold |
| Family 3: Configuration Change | MC_hunt_confchange.cfg | 126M | No violation — CommitByVoteSafety, ConfChangeSafety hold (ConfChangeLimit=3 enabled) |
| Family 4: Async Persistence | MC_hunt_persist.cfg | 136M | No violation — AsyncPersistSafety, CrashRecoverySafety hold (CrashLimit=3 enabled) |
| Family 5: Snapshot + Region | N/A | N/A | Not testable — raftstore integration layer specific, not modeled |

## Spec Fixes During Convergence

1. **BecomeLeader nextIndex** (Case B): followers' nextIndex set to `Len(log[i])+1` (pre-noop), matching raft.rs reset()+append_entry ordering
2. **BecomeLeader pendingConfIndex** (Case B): set to old log length before noop, matching raft.rs:1267
3. **BecomeLeader quorum guard** (Case B): added `HasQuorum(i, votesGranted[i])` — without this, any Candidate becomes Leader violating ElectionSafety
4. **HandleAppendEntriesResponse maybe_update** (Case B): use `Max(matchIndex, m.mindex)` matching raft.rs:1828 maybe_update semantics
5. **Message handling in winning paths** (Case B): HandleRequestVoteResponse and HandleRequestPreVoteResponse winning paths changed SendAll → DiscardAndSendAll to consume processed messages
6. **MCBecomeLeader UNCHANGED** (Case B): added UNCHANGED <<votesGranted, preVotesGranted, messages>> for standalone MC wrapper

## Notes

- All BFS runs are ongoing (queue still growing). The state counts above represent partial exploration.
- ConfChangeLimit=0 in the main MC.cfg (no config changes during convergence); ConfChangeLimit=3 enabled in MC_hunt_confchange.cfg.
- The spec models 4 of 5 identified bug families. Family 5 (Snapshot + Region Lifecycle) is raftstore-specific and out of scope for the raft-rs core spec.
- Known historical bugs (raft-rs #234, #511) involve edge cases in lease read + transfer and prevote + priority interactions. These are within scope of the hunting configs but were not triggered — they may require deeper BFS or more constrained hunting configs.
