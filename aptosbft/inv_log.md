# Aptos BFT Invariant Checking Log

## Model Checking Configuration

**Spec:** `MC.tla` + `MC.cfg`
**Mode:** BFS (exhaustive state space exploration)
**Parameters:**
- Server = {s1, s2, s3} (3 servers)
- MaxRound = 4
- Quorum = 2
- Values = {v1, v2}
- Fault injection limits: MaxTimeoutLimit=4, MaxCrashLimit=2, MaxCrashPersistLimit=1, MaxDropLimit=3, MaxSyncLimit=2, MaxEpochChangeLimit=1
- Message buffer constraint: MaxMsgBufferLimit=10
- Symmetry reduction: Permutations(Server)
- Deadlock checking disabled (`-deadlock`)

---

### Record #1 — VoteSafety violation (Case B: spec modeling issue)

**Date:** 2026-02-27
**Mode:** BFS
**States at violation:** 8 states (depth 8)
**Result:** **VoteSafety VIOLATED** — 8-state counterexample

#### Counterexample Summary

Two servers proposed different values for the same round (round 1), both formed quorum with different vote sets, violating the VoteSafety invariant (no two QCs for different blocks in same round).

#### Analysis Conclusion

- **Type:** Case B — spec modeling issue
- **Violated Property:** VoteSafety
- **Root Cause:** The base spec's `Propose` action had no guard preventing multiple proposers per round. The implementation uses `ProposerElection` to ensure exactly one leader per round, but this was not modeled in the spec.

#### Modifications Made

- **File:** `base.tla`
- **Change:** Added `roundProposer` ghost variable to model leader election
- **Details:** See fix_log.md Fix #1

---

### Record #2 — SignCommitVote msgs conflict (spec syntax error)

**Date:** 2026-02-27
**Mode:** BFS (during restart after Fix #1)
**Result:** TLC reported variable assignment conflict

#### Analysis Conclusion

- **Type:** Spec syntax error
- **Root Cause:** `SignCommitVote` action calls `Broadcast(...)` which sets `msgs'`, but `msgs` was also in the `UNCHANGED` clause

#### Modifications Made

- **File:** `base.tla`
- **Change:** Removed `msgs` from UNCHANGED clause in SignCommitVote
- **Details:** See fix_log.md Fix #2

---

### Run #1 — Post-fix model checking (initial, pre-broadcast fix)

**Date:** 2026-02-27
**Duration:** ~20 minutes (interrupted for broadcast fix)
**States checked:** 332M+ states generated, depth 17
**Result:** No violations found (incomplete — interrupted)

**Invariants checked (all held at time of interruption):**

Safety:
- `VoteSafety` — no two QCs for different blocks in same round
- `OrderVoteSafety` — no two ordering certs for different blocks in same round
- `CommitSafety` — 2-chain commit rule consistency
- `NoDoubleVoteAfterCrash` — no conflicting votes after crash/recovery
- `CommitVoteConsistency` — commit vote implies ordering cert exists

Structural:
- `PipelineMonotonicity` — pipeline phases advance monotonically
- `RoundPositive` — current round >= 1
- `QCRoundBound` — QC round < current round
- `TCRoundBound` — TC round < current round
- `LVRBound` — lastVotedRound <= current round

**Note:** Interrupted to apply broadcast fix (Broadcast sending 1 copy instead of N copies — see fix_log.md Fix #3). The fix changes message delivery semantics, requiring a restart.

---

### Run #2 — Post-broadcast-fix model checking (ongoing)

**Date:** 2026-02-27
**Duration:** 23+ minutes (still running)
**States checked:** 823M+ states generated, 122M+ distinct, depth 16
**Queue:** 82M+ states remaining
**Rate:** ~35M states/minute
**Result:** No violations found (ongoing)

**All 10 invariants checked so far (none violated):**
- VoteSafety
- OrderVoteSafety
- CommitSafety
- NoDoubleVoteAfterCrash
- CommitVoteConsistency
- PipelineMonotonicity
- RoundPositive
- QCRoundBound
- TCRoundBound
- LVRBound

**Estimated completion:** State space is still growing (queue increasing). With MaxRound=4 and 3 servers, complete exploration may take several hours. The queue growth rate is decreasing, suggesting the peak breadth may be near.

---

## Trace Validation Results

**Date:** 2026-02-27
**Trace:** `trace.ndjson` (64 events, 4 rounds, 3 servers)
**Result:** **PASS** — all events consumed, all invariants hold

```
Model checking completed. No error has been found.
69 states generated, 65 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 65.
```

**Properties checked during trace validation:**
- TraceMatched temporal property: SATISFIED
- VoteSafety: HELD
- OrderVoteSafety: HELD
- CommitSafety: HELD
- NoDoubleVoteAfterCrash: HELD
- CommitVoteConsistency: HELD

---

## Summary of Bug Families

The spec models 5 bug families from the Aptos BFT implementation:

| Family | Description | Invariant | Status |
|--------|------------|-----------|--------|
| 1 | Missing safety guards on auxiliary voting paths | VoteSafety, CommitVoteConsistency | No violation found (823M+ states) |
| 2 | Order vote protocol gaps (100-round window) | OrderVoteSafety | No violation found |
| 3 | Pipeline/buffer manager race conditions | PipelineMonotonicity | No violation found |
| 4 | Non-atomic safety-critical persistence | NoDoubleVoteAfterCrash | No violation found |
| 5 | Epoch transition boundary bugs | (EpochIsolation — not in MC.cfg) | Not fully tested |

---

## Bug Hunting Campaign (MC-1 through MC-6)

**Date:** 2026-02-27
**Objective:** Test 6 model-checkable hypotheses from the analysis report.

---

### Record #3 — EpochIsolation violation (Case A: invariant too strong)

**Date:** 2026-02-27
**Config:** MC_hunt1.cfg (MC.tla, all invariants enabled)
**States at violation:** 881 (depth 8)
**Result:** **EpochIsolation VIOLATED** — 4-state counterexample

#### Counterexample Summary

s1 proposes and votes at round 1 (epoch 1), then does EpochChange (epoch 2). The proposal and vote messages from epoch 1 are still in the network, but s1's currentEpoch is now 2. The invariant `m.msrc = s => m.mepoch = currentEpoch[s]` fails because in-flight messages retain the old epoch.

#### Analysis Conclusion

- **Type:** Case A — Invariant Too Strong
- **Violated Property:** EpochIsolation
- **Root Cause:** The invariant checks that ALL messages from a server match its CURRENT epoch. But when a server changes epochs, previously sent messages naturally remain in the network with the old epoch. Receivers filter these by checking `m.mepoch = currentEpoch[s]` on receipt (already enforced by all receive actions).

#### Resolution

EpochIsolation invariant removed from hunt configurations. The real test for epoch boundary bugs (MC-3/MC-5) requires weak-epoch receive actions (modeled in MC_epoch.tla), not a stronger invariant.

---

### Record #4 — OrderVoteGap violation (MC-1 structural gap confirmed)

**Date:** 2026-02-27
**Config:** MC_gap.cfg (MC.tla, OrderVoteGap invariant only)
**States at violation:** 12,093 (depth 9)
**Result:** **OrderVoteGap VIOLATED** — 9-state counterexample

#### Counterexample Summary

s1 proposes v1 at round 1. s1 and s2 cast regular votes (lastVotedRound=1). s3 receives both votes, forming a QC. s3 then casts an order vote for round 1 via CastOrderVote. After the order vote, `oneChainRound[s3]=1` but `lastVotedRound[s3]=0` (never updated by order vote path).

#### Analysis Conclusion

- **Type:** Structural gap confirmed (not a safety violation)
- **Violated Property:** OrderVoteGap (`oneChainRound <= lastVotedRound`)
- **Root Cause:** `guarded_construct_and_sign_order_vote` (safety_rules_2chain.rs:97-119) does NOT call `verify_and_update_last_vote_round`. It only calls `safe_for_order_vote` which checks `round > highest_timeout_round`.
- **Safety impact:** No safety invariant (VoteSafety, OrderVoteSafety, CommitSafety) is violated because `RoundManager.current_round` monotonicity prevents the gap from being exploited. After order-voting at round R, currentRound is already R+1, blocking any proposals/votes for round ≤ R.

#### Recommendation

Defense-in-depth improvement: add `verify_and_update_last_vote_round` to `guarded_construct_and_sign_order_vote` so that the safety rules layer is self-contained.

---

### Run #3 — BFS with IndependentRoundTracking + RoundMonotonicity (MC-1)

**Date:** 2026-02-27
**Config:** MC_hunt2.cfg (3 servers, MaxRound=4, all safety + structural invariants + IndependentRoundTracking + RoundMonotonicity)
**Duration:** 30 minutes (timeout)
**States checked:** 154,278,411 generated, 24,480,609 distinct, depth 17
**Result:** **No violations found**

All 12 invariants held: VoteSafety, OrderVoteSafety, CommitSafety, NoDoubleVoteAfterCrash, CommitVoteConsistency, PipelineMonotonicity, RoundPositive, QCRoundBound, TCRoundBound, LVRBound, IndependentRoundTracking, RoundMonotonicity.

---

### Run #4 — BFS with weak-epoch receive actions (MC-3/MC-5)

**Date:** 2026-02-27
**Config:** MC_epoch.cfg (MC_epoch.tla, 3 servers, MaxRound=3, MaxWeakEpochLimit=3, MaxEpochChangeLimit=2)
**Duration:** 30 minutes (timeout)
**States checked:** 31,750,121 generated, 4,492,829 distinct, depth 12
**Result:** **No violations found**

Safety invariants checked: VoteSafety, OrderVoteSafety, CommitSafety, CommitVoteConsistency, RoundPositive.

---

### Run #5 — Simulation with higher fault limits (MC-2/MC-4/MC-6)

**Date:** 2026-02-27
**Config:** MC_sim.cfg (3 servers, MaxRound=5, MaxCrashPersistLimit=2, MaxEpochChangeLimit=2)
**Mode:** Simulation (random traces, depth 200)
**Duration:** 25 minutes (timeout)
**States checked:** 108,999,069 checked, 389,634 traces (mean length=174, sd=26)
**Result:** **No violations found**

All 9 invariants held: VoteSafety, OrderVoteSafety, CommitSafety, NoDoubleVoteAfterCrash, CommitVoteConsistency, PipelineMonotonicity, RoundPositive, IndependentRoundTracking, RoundMonotonicity.

---

### Run #6 — Simulation with weak-epoch actions (MC-3/MC-5)

**Date:** 2026-02-27
**Config:** MC_epoch.cfg (MC_epoch.tla, simulation mode, depth 300)
**Duration:** 25 minutes (timeout)
**States checked:** 156,282,527 checked, 71,057 traces (mean length=267, sd=33)
**Result:** **No violations found**

---

## Updated Bug Family Summary

| Family | Description | Invariants | BFS States | Sim Traces | Status |
|--------|------------|-----------|------------|------------|--------|
| 1 | Missing safety guards (aux voting) | VoteSafety, CommitVoteConsistency, OrderVoteGap | 154M+ | 389K | **OrderVoteGap violated** (structural); safety holds |
| 2 | Order vote protocol gaps | OrderVoteSafety | 154M+ | 389K | No violation |
| 3 | Pipeline/buffer manager races | PipelineMonotonicity | 154M+ | 389K | No violation |
| 4 | Non-atomic persistence | NoDoubleVoteAfterCrash | 154M+ | 389K | No violation (requires Byzantine leader) |
| 5 | Epoch transition boundary | VoteSafety, OrderVoteSafety (weak-epoch) | 31M | 71K | No violation |

---
