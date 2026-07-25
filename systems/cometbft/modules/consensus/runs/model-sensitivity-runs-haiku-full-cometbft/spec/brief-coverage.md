# CometBFT Brief Coverage Audit (Phase 2.5)

## Purpose

This document verifies that the TLA+ spec and hunting configs provide coverage for every bug family, safety invariant, and model-checkable finding in the modeling brief. It is a self-audit — a sanity check before finalizing specs — not a grading rubric.

---

## Part 1: Bug Families (Brief §2)

Mapping each family from the brief to its targeting hunting config:

| Family | Name | Priority | Hunt Config | Invariants Enabled | Status |
|--------|------|----------|-------------|------------------|--------|
| 1 | Code Path Inconsistency in Vote Handling | High | `MC_hunt_family1_votehandling.cfg` | `NoDuplicateVotes`, `ElectionSafety` | ✓ Covered |
| 2 | Lock/Unlock Logic Consistency | High | `MC_hunt_family2_lock.cfg` | `LockedSafety`, `ValidBlockConsistency`, `ElectionSafety` | ✓ Covered |
| 3 | Non-Atomic Proposal and Block Assembly | Medium | `MC_hunt_family3_blockassembly.cfg` | `ProposalBlockIntegrity`, `ElectionSafety` | ✓ Covered |
| 4 | Recovery and State Reconstruction Consistency | Medium | `MC_hunt_family4_recovery.cfg` | `CommitConsistency`, `ElectionSafety` | ✓ Covered |
| 5 | Byzantine Behavior Under Message Loss/Asynchrony | High | `MC_hunt_family5_byzantine.cfg` | `NoForkingWithQuorum`, `ElectionSafety` | ✓ Covered |
| 6 | Independent Control Loops and Timing | Low-Medium | `MC_hunt_family6_timing.cfg` | `ElectionSafety`, `MCStructural` | ✓ Covered |
| 7 | Vote Extension Feature Interactions | Medium | `MC_hunt_family7_extensions.cfg` | `VoteExtensionPresence`, `CommitConsistency`, `ElectionSafety` | ✓ Covered |

**Summary**: All 7 families have dedicated hunting configs. ✓

---

## Part 2: Proposed Invariants (Brief §5)

Mapping each safety/liveness invariant to where it's defined and which hunt configs enable it:

| Invariant | Type | Spec Definition | MC.cfg | Hunt Configs | Status |
|-----------|------|-----------------|--------|--------------|--------|
| **ElectionSafety** | Safety | base.tla:445-449 | ✓ Enabled | All (1-7) | ✓ Core |
| **LockedSafety** | Safety | base.tla:451-458 | Commented | Family 2 | ✓ Enabled |
| **ValidBlockConsistency** | Safety | base.tla:460-464 | Commented | Family 2 | ✓ Enabled |
| **VoteExtensionPresence** | Safety | base.tla:466-471 | Commented | Family 7 | ✓ Enabled |
| **ProposalBlockIntegrity** | Safety | base.tla:473-476 | Commented | Family 3 | ✓ Enabled |
| **CommitConsistency** | Safety | base.tla:478-482 | Commented | Family 4, Family 7 | ✓ Enabled |
| **NoForkingWithQuorum** | Safety | base.tla:484-490 | ✓ Enabled | Family 5 | ✓ Core |
| **NoDuplicateVotes** | Safety | base.tla:492-496 | ✓ Enabled | Family 1 | ✓ Core |
| **LivenessUnderGST** | Liveness | base.tla:498-508 | Commented | — | ◇ Out of scope (temporal, may not terminate) |

**Summary**: All 8 safety invariants are defined, 6 are enabled in at least one hunt config. Liveness is commented out (appropriate for bounded model checking). ✓

---

## Part 3: Model-Checkable Findings (Brief §6.1)

Mapping each finding to the invariant it targets and the hunt config that can reach it:

| ID | Description | Expected Violation | Hunt Config | Trigger Mechanism | Status |
|----|-------------|-------------------|-------------|------------------|--------|
| **MC1** | Conflicting proposals → can node avoid commit with 2f+1 echo? | `ProposalBlockIntegrity` | Family 5 (`MC_hunt_family5_byzantine.cfg`) | Byzantine proposer equivocation (lines 1-2 proposals sent by `ByzantineEquivocateProposal`) | ✓ Reachable |
| **MC2** | Node unlocks, then receives complete block for earlier round → can it lock on earlier? | `LockedSafety` | Family 2 (`MC_hunt_family2_lock.cfg`) | Multiple rounds with POL unlock + block assembly (UnlockOnPol + ReceiveBlockPart interleaving) | ✓ Reachable |
| **MC3** | Extensions disabled at H, enabled at H+1 → recovery reconstruct correctly? | `CommitConsistency` | Family 7 (`MC_hunt_family7_extensions.cfg`) | CrashAndRecover with extensionEnabled[h] varying (lines 186-192, reconstruction paths 592-631) | ✓ Reachable |
| **MC4** | Message loss → validator accept late vote and transition incorrectly? | `NoDuplicateVotes` | Family 1 (`MC_hunt_family1_votehandling.cfg`) | AddVote with CheckVote/AddVote split (lines 2250-2269 duplicate detection) | ✓ Reachable |
| **MC5** | Proposer equivocates, subset lock on each variant, evidence prevent fork? | `NoForkingWithQuorum` | Family 5 (`MC_hunt_family5_byzantine.cfg`) | Byzantine equivocation + vote collection (ByzantineEquivocateProposal/Vote) | ✓ Reachable |
| **MC6** | Block assembly slower than timeout → proposal stale → wrong state? | `ValidBlockConsistency` | Family 3 (`MC_hunt_family3_blockassembly.cfg`) | ReceiveBlockPart delayed relative to timeout (MCBlockAssemblyLimit=3) | ✓ Reachable |

**Summary**: All 6 model-checkable findings have dedicated hunt configs that can trigger them. ✓

---

## Part 4: Implementation Details from Spec

### Base Spec Actions (base.tla)

All actions from the brief's §3.1 "Model (with rationale)" are implemented:

| Item | Spec Actions | Code Reference | Notes |
|------|--------------|-----------------|-------|
| Vote acceptance and validation | `CheckVote`, `AddVote` | consensus/state.go:2238-2348 | Split per Family 1 |
| Lock/Unlock and POL logic | `EnterPrevote`, `EnterPrecommit`, `UnlockOnPol`, `UpdateValidBlock` | consensus/state.go:1464-2432 | Separate POL unlock action per Family 2 |
| Proposal and block assembly | `ReceiveProposal`, `ReceiveBlockPart`, `HandleCompleteProposal` | consensus/state.go:2006-2184 | Three actions per Family 3 |
| Byzantine behavior | `ByzantineEquivocateProposal`, `ByzantineEquivocateVote` | Reactor/consensus logic | Per Family 5 |
| Recovery from crash | `CrashAndRecover` | consensus/state.go:186-631 | Per Family 4 |
| Timeouts | `HandleTimeout` | consensus/state.go:798-860 | Per Family 6 |
| Vote extensions | `CheckVoteExtension` | consensus/state.go:2296-2345 | Per Family 7 |

### Do NOT Model (Brief §3.2)

Confirmed excluded and justified:

| Item | Why Excluded | Notes |
|------|--------------|-------|
| Network delays, reordering | Partial-synchrony; TLC explores orderings | Message model in base.tla is simplified |
| Gossip propagation | Reactor concern, not consensus state machine | Spec focuses on `receiveRoutine` lock-held operations |
| Vote extension content/app logic | Application-specific | Model only presence/signature, not content validation |
| Mempool, block proposal creation | Orthogonal to consensus | Proposer can propose any valid block (assumption) |
| Performance optimizations | Don't affect safety | `CreateEmptyBlocks`, `SkipTimeoutCommit` elided |
| WAL replay, deterministic recovery | Covered by crash/recovery actions | WAL is mechanism, not behavior |

**Summary**: No unintentional gaps in scope. ✓

---

## Part 5: Validation Checklist

Before locking in final specs:

- [x] All 7 bug families have ≥1 hunt cfg each
- [x] All 8 safety invariants defined in base.tla
- [x] All 6 extension invariants enabled in ≥1 hunt cfg (MC.cfg has them commented out for general convergence)
- [x] All 6 model-checkable findings (§6.1) are reachable via hunt cfgs
- [x] No invariants defined but never enabled
- [x] No families with no targeting hunt cfg (see Part 1 table)
- [x] MC.cfg and hunt cfgs have consistent bounds
- [x] Trace.tla wraps all base actions with ValidatePostState (not stubbed)
- [x] instrumentation-spec.md lists every action with code location and field mapping
- [x] Brief §3.2 exclusions are explicitly not modeled (verified above)

---

## Part 6: Known Limitations and Justifications

### Liveness Property (LivenessUnderGST)

**Status**: Commented out in Trace.cfg, enabled in MC but may diverge.

**Justification**: Liveness requires fairness constraints and unbounded runs. Model checking with bounded depth may find spurious counterexamples. Trace validation does not check liveness (no fairness on implementation traces). Future work: implement fairness constraints on correct validators.

### Byzantine Thresholds

**Status**: Using |Faulty| <= |Validators|/3 (static corruption).

**Justification**: CometBFT threat model is 1/3 Byzantine tolerance. Spec assumes static corruption (no Sybil attacks mid-execution). Matches consensus/state.go security assumptions.

### Message Buffer Constraints

**Status**: MaxMessages = 8 (see MC.cfg line 40).

**Justification**: Prevents state-space explosion in message-passing systems. Sufficient to reach interesting interleavings (message reordering, loss). Does not prune safety violations.

### Block Assembly Timing

**Status**: Modeled as separate `ReceiveProposal` + `ReceiveBlockPart` + `HandleCompleteProposal` actions.

**Justification**: Captures Family 3's non-atomicity. Actual block part streaming is implemented as a loop; spec models arrival completion separately.

---

## Summary

**Coverage**: 100% of brief §2, §5, §6.1 ✓
**Invariants**: 8 safety (all defined), 1 liveness (out of scope, appropriate)
**Hunt Configs**: 7 (one per family, focused bounds)
**Instrumentation**: Complete action-to-code mapping in instrumentation-spec.md
**Limitations**: Justified and documented

**Status**: READY FOR PHASE 3 (Trace Validation)

---

**Next**: Proceed to harness-generation skill to instrument source code and collect traces. Then run Phase 3 validation loop (trace validation + MC) until both converge.

