# CometBFT Bug Discovery Summary

## Overview

| Metric | Value |
|--------|-------|
| Code Analyzed | ~12,800 LOC (12 core files) |
| GitHub Issues/PRs Surveyed | ~380 (CometBFT ~120 + Tendermint ~115 + PRs 146) |
| Issues Read In Depth | 39 |
| Confirmed Historical Bugs | 25 |
| New Code Analysis Findings | ~50 model-checkable findings |
| TLA+ Model Checking State Space | >1.2B states |
| Trace Validation | 4 traces all passed (31,395 states) |
| **Bugs Reproduced via Model Checking** | **2 (both known, unfixed)** |
| Safety Verification | ElectionSafety, LockSafety and other core invariants all passed within test bounds |

---

## Reproduced Bugs

### Bug #1: Vote Extension Deadlock (Critical)

| Property | Value |
|----------|-------|
| Issue | cometbft#5204 |
| Status | **OPEN, unfixed** |
| Impact | Production chain (Seda) already affected |
| Bug Family | Family 1: Vote Extension Lifecycle |
| Discovery Method | MC-BFS, VELivenessInv invariant, 22-state counterexample |
| Analysis IDs | B1, S7, E8 |

**Mechanism**: The proposer skips Vote Extension verification for its own precommit when signing (`state.go:2196-2244`). When the proposer's VE is invalid:

1. **Proposer's view**: Its own precommit is counted unconditionally (no VE check), plus 2 valid precommits received → reaches 3/3 quorum → commits
2. **Other nodes' view**: Receive the proposer's precommit, run `VerifyVoteExtension` → VE invalid → discard the vote → only 1/3 precommits → can never reach quorum
3. **Permanent deadlock**: Proposer advances to the next height, other nodes are stuck at the current height forever

**Suggested fix**: Remove the proposer self-verification skip. All precommit votes (including the proposer's own) should go through `VerifyVoteExtension`.

---

### Bug #2: Nil Precommit Cannot Immediately Advance Round (High)

| Property | Value |
|----------|-------|
| Issue | cometbft#1431 |
| Status | **OPEN, unfixed** |
| Impact | All chains using CometBFT; each nil round adds unnecessary delay |
| Bug Family | Family 2: Liveness / Round Advancement |
| Discovery Method | MC-BFS, NilPrecommitAdvance temporal property, 15-state counterexample |
| Analysis IDs | B6, S4 |

**Mechanism**: After all nodes have sent nil precommits (+2/3 nil precommits), the Tendermint paper specifies an immediate advance to the next round. However, the implementation must wait for `timeout_precommit` to expire before advancing:

1. `enterPrecommitWait` (`state.go:1584-1610`): Schedules the `timeout_precommit` timer
2. `handleTimeout` (`state.go:1018-1022`): Waits for the timeout to expire
3. `enterNewRound` (`state.go:1066`): Only then advances to the next round

**Suggested fix**: Add a fast path — when +2/3 nil precommits are detected, immediately call `enterNewRound(height, round+1)` without waiting for the timeout.

---

## Safety Verification Results

The following core safety properties all passed across a search space of **>1.2B states**:

| Invariant | Meaning | Max Verified Scale |
|-----------|---------|-------------------|
| ElectionSafety | At most one value committed per height | 793M (3 server BFS) + 152M (4 server sim) |
| Validity | Only proposed values can be committed | 793M |
| LockSafety | Locked nodes only precommit the locked value (unless a higher-round polka is seen) | 793M |
| POLRoundValidity | Proposal's POLRound < Round | 793M |
| CommittedBlockDurability | Committed blocks are never lost | 793M |
| VEConsistency | All non-self precommit VEs in the quorum are verified | 366M |
| CrashRecoveryConsistency | No invalid votes produced after crash recovery | 366M |
| PrivvalConsistency | Signing state is consistent with the current height | 366M |
| EvidenceUniqueness | The same evidence is never submitted twice | 793M |

**Conclusion**: CometBFT's core consensus safety (Agreement / Validity) is correct within the tested bounds. All 5 `enterPrecommit` paths, lock/unlock logic, and round-skipping mechanisms correctly maintain the safety invariants.

---

## Hypotheses Not Reproduced

| Hypothesis | Reason | Analysis Finding |
|------------|--------|-----------------|
| Cross-height VE not verified (LastCommit) | Spec does not model `timeout_commit` and cross-height vote propagation | B15, S7 |
| Race between privval signing and WAL | `signAddVote` is atomic in the spec | S8, W6 |
| Crash after Commit but before evpool.Update | Evidence lifecycle modeling is too simplified | E2, E4 |
| Crash after block save but before EndHeightMessage | `FinalizeCommit` is atomic in the spec | W3 |

These hypotheses require splitting atomic operations in the spec into multiple sub-steps to verify, and are left as future work.

---

## Notable Code Analysis Findings Not Yet Modeled

### High Priority (Potential Undiscovered Bugs)

| ID | Finding | Code Location | Risk |
|----|---------|---------------|------|
| B3 | PBTS time check during WAL replay causes chain halt | state.go (replay) | Critical, reported in tendermint#8739 but unfixed |
| B4 | Same DuplicateVoteEvidence submitted in consecutive blocks | pool.go:194-232 | Critical, cometbft#4114 closed as NOT_PLANNED |
| B7 | Fast-sync failure under short block times | reactor.go | High, affects Injective/Sei/Initia |
| S5 | Goroutine causes self-message reordering when queue is full | state.go:575 | May violate message processing order assumptions |
| W1 | Async WAL writes lost on crash | state.go:838,869 | State inconsistency after recovery |

### Medium Priority (Confirmed but Fixed or Lower Risk)

| ID | Finding | Status |
|----|---------|--------|
| B8 | VE flag incorrectly set on nil precommit → remote signer panic | Fixed in PR#3565 |
| B9 | Large VE exceeds WAL size limit → panic | OPEN #1253 |
| V8 | POLRound >= Round passes ValidateBasic | POLRoundValidity passed in model checking |
| R2 | Vote tracker reset to nil on round change | Affects gossip efficiency, not safety |

---

## Summary

1. **CometBFT's core safety is correct** — ElectionSafety and LockSafety hold across a >1.2B state search space. All 5 `enterPrecommit` paths and lock/unlock logic correctly implement the Tendermint BFT protocol.

2. **Vote Extension is the most dangerous area** — Bug #1 (#5204) is an unfixed Critical-severity deadlock that has already affected a production chain. As a new ABCI++ feature, VE edge cases are insufficiently handled.

3. **Known liveness deficiencies exist** — Bug #2 (#1431) adds unnecessary timeout delay on each nil round, deviating from the behavior defined in the Tendermint paper.

4. **Crash recovery and evidence handling are verification blind spots** — 3 hypotheses could not be tested due to spec atomicity constraints. WAL persistence races (W6), evidence double-submission (B4/E2) and related issues require more fine-grained spec modeling.

5. **Trace validation confirms the spec faithfully reflects the implementation** — 4 traces across different scenarios (basic consensus, lock-and-relock, timeout-propose, two-heights) all passed validation, demonstrating that the spec covers the real behavioral paths of the implementation.
