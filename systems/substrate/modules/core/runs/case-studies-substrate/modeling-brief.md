# Modeling Brief: Substrate GRANDPA BFT Finality

## 1. System Overview

- **System**: Substrate GRANDPA — Rust BFT finality gadget for Substrate-based blockchains (Polkadot, Kusama, parachains)
- **Language**: Rust, ~12,200 LOC core logic across client, frame pallet, and primitives
- **Protocol**: GHOST-based Recursive ANcestor Deriving Prefix Agreement (GRANDPA)
- **Key architectural choices**:
  - Core GRANDPA algorithm in external `finality-grandpa` crate; Substrate wraps it with authority management, persistence, and networking
  - **Two types of authority set changes**: Standard (enacted on finality, tracked in ForkTree) and Forced (enacted on block depth, flat Vec, for emergencies)
  - **Multiple concurrent finalization paths**: gossip-based voting, sync-based justification import, forced changes — all race on shared authority set state
  - **Non-atomic persistence**: authority set and voter set state can be written in separate `insert_aux` calls (environment.rs, aux_schema.rs)
  - Vote targets restricted by `current_limit()` from pending authority changes, but limit only checks ForkTree roots (authorities.rs:423)
- **Concurrency model**: Fully async/Tokio. Single voter future + block import on separate async tasks. Shared state via `Arc<Mutex<AuthoritySet>>` and unbounded channels for voter commands.

## 2. Bug Families

### Family 1: Authority Set Change Safety (HIGH)

**Mechanism**: Incorrect ordering, timing, or application of standard and forced authority set changes, leading to wrong authority sets being active across nodes.

**Evidence**:
- Historical: `755514de6` — forced changes applied before dependent standard changes (PR #7321)
- Historical: `5719b8cab` — forced changes with delay=0 never applied; `is_descendent_of` returns false for same block (PR #6828)
- Historical: `2e6663164` — authority set not reverted on non-`Queued` import result (PR #1508)
- Historical: `09f0486a1` — `enacts_change` triggered at wrong block numbers (PR #1530)
- Historical: `f884296f7` — ForkTree rebalancing bug caused wrong change ordering (PR #7616)
- Code analysis: `current_limit()` only checks ForkTree roots (authorities.rs:423-429). Non-root pending changes with lower effective numbers are missed, allowing votes past the intended limit.
- Code analysis: Forced change dependency check only examines root standard changes (authorities.rs:478-492). A non-root standard change with `effective_number <= median_last_finalized` would not block a forced change.
- Code analysis: `Stalled` state consumed by `take()` but `schedule_change` can fail — stall info permanently lost (frame/grandpa/lib.rs:583-609).

**Affected code paths**:
- `AuthoritySet::apply_standard_changes` / `apply_forced_changes` (authorities.rs:447-602)
- `AuthoritySet::current_limit` (authorities.rs:423-429)
- `GrandpaBlockImport::make_authorities_changes` (import.rs:314-422)
- `Pallet::schedule_change` / `on_finalize` / `on_new_session` (frame/grandpa/lib.rs)

**Suggested modeling approach**:
- Variables: `pendingStandardChanges` (a tree/set of `{block, delay, newAuthorities}`), `pendingForcedChanges` (a set of `{block, delay, medianFinalized, newAuthorities}`), `currentAuthorities`, `setId`
- Actions: `AddStandardChange(node, block)`, `AddForcedChange(node, block)`, `ApplyStandardChange(node)` (on finalization), `ApplyForcedChange(node)` (on best block depth), `Finalize(node, block)`
- Key: Model the ForkTree semantics — standard changes on competing forks, pruning on finalization, dependency ordering between forced and standard changes
- Granularity: Standard change application is atomic (single action); forced change application should model the dependency check as a guard

**Priority**: High
**Rationale**: 6+ critical/high historical bugs sharing this mechanism. The ForkTree + forced change interaction is the most complex state management in GRANDPA. Multiple open issues. Directly model-checkable.

---

### Family 2: Finalization Race Conditions (HIGH)

**Mechanism**: Multiple concurrent paths to finalization (gossip voting, sync justification import, forced changes) race on shared authority set state, leading to inconsistent views or crashes.

**Evidence**:
- Historical: `1ba689e68` — re-finalization check in wrong scope, allowing gossip and sync to race (PR #3437)
- Historical: `c8e112094` — TOCTOU: authority set lock acquired after already-finalized check (PR #3542)
- Historical: `5590a4e0e` — `finality_target > best_chain` race from non-atomic SelectChain calls (PR #13364)
- Code analysis: Authority set lock released before `inner.import_block()` — mutated set visible before block persisted (import.rs:420,578)
- Code analysis: `assert!(!enacts_change)` can fire if concurrent finalization already applied the change (import.rs:835-838)
- Code analysis: Non-atomic finalization acknowledged by developers — "Node is in a potentially inconsistent state" (environment.rs:1522-1527)

**Affected code paths**:
- `finalize_block` (environment.rs:1354-1544)
- `GrandpaBlockImport::import_block` (import.rs:522-695)
- `import_justification` (import.rs:769-843)

**Suggested modeling approach**:
- Variables: `finalizedBlock[node]`, `authoritySetLocked[node]`, `importInProgress[node]`
- Actions: `FinalizeViaGossip(node, block)`, `FinalizeViaSync(node, block)`, `ImportBlock(node, block)` — these can interleave
- Key: Model the authority set lock as a mutual exclusion variable. Split `finalize_block` into sub-steps: (1) acquire lock, (2) check already-finalized, (3) apply changes, (4) write to disk, (5) release lock. Allow interleaving between these steps across different finalization paths.
- The goal is to verify that regardless of interleaving, the authority set state remains consistent.

**Priority**: High
**Rationale**: 5 critical/high historical bugs. The non-atomicity is acknowledged in code comments. TLA+ is well-suited for exploring interleaving scenarios that are hard to test deterministically.

---

### Family 3: Equivocation Handling (HIGH)

**Mechanism**: Incorrect counting of equivocated votes in the GHOST algorithm, and incorrect validation of commits/justifications containing equivocation proofs.

**Evidence**:
- Historical: finality-grandpa PR #7 (CRITICAL) — finality check only required precommit supermajority, not prevotes
- Historical: finality-grandpa PR #5 (CRITICAL) — equivocated votes double-counted in vote graph
- Historical: finality-grandpa PR #36 (HIGH) — equivocators not treated as "voting for everything"
- Historical: finality-grandpa PR #152 — commit validation rejected valid commits with equivocation proofs
- Open: finality-grandpa Issue #113 — non-descendant votes in commits still rejected even when they are equivocation proofs
- Historical: `42655d235` (PR #11302) — justification creation failed with equivocating precommits below commit target
- Historical: `60d67dcf0` (PR #6823) — `HasVoted` state overwrite could cause equivocation on restart
- Historical: Issue #11175 — equivocation from rotated-out authority crashed 2/3 of 120-node network

**Affected code paths**:
- Core algorithm: `Round`, `VoteGraph`, `validate_commit` (finality-grandpa crate)
- `GrandpaJustification::from_commit` / `verify_with_voter_set` (justification.rs)
- `Environment::prevoted` / `precommitted` — `HasVoted` state management (environment.rs)

**Suggested modeling approach**:
- Variables: `votes[round][voter]` (can contain 1 or 2 votes per voter), `equivocators[round]` (set of voters who double-voted)
- Actions: `Prevote(voter, block)`, `Precommit(voter, block)`, `Equivocate(voter, block1, block2)` — Byzantine voter casts two different votes
- Key: Model equivocator weight as "voting for all blocks" (not just the specific targets). Verify that the GHOST function computes the correct estimate with equivocators present. Verify that `validate_commit` accepts valid commits containing equivocation proofs.
- Invariant: `FinalizationSafety` — if a block is finalized, every future finalized block must be a descendant

**Priority**: High
**Rationale**: 2 critical bugs in core algorithm. The equivocation counting semantics are non-obvious and have been wrong multiple times. One open issue remains. Directly model-checkable.

---

### Family 4: Round State Transitions (MEDIUM)

**Mechanism**: Incorrect ordering of voting phases (propose → prevote → precommit → complete), incorrect round completion guards, and state persistence issues that cause protocol violations on restart.

**Evidence**:
- Historical: finality-grandpa PR #96 — precommit without prevote (prevote returned `None` but state advanced)
- Historical: finality-grandpa PR #71 — round completion did not wait for R-2 estimate finalization
- Historical: finality-grandpa PR #62 — primary proposal sent when estimate WAS finalized (inverted condition)
- Historical: finality-grandpa PR #106 — missing finality notifications before local precommit
- Historical: finality-grandpa PR #122 — caught-up rounds never pruned (memory leak)
- Code analysis: `HasVoted` state overwrite risk (environment.rs, fixed by PR #6823 but pattern is fragile)
- Code analysis: Missing `set_state` on startup causes restart at round 0 (aux_schema.rs:362-380)
- Open: finality-grandpa PR #171 — missing waker save causes busy-polling and finality stalls

**Affected code paths**:
- Core algorithm: `VotingRound` state machine (finality-grandpa crate)
- `Environment::proposed` / `prevoted` / `precommitted` / `completed` / `concluded` (environment.rs)
- `update_voter_set_state` (environment.rs:459-482)

**Suggested modeling approach**:
- Variables: `roundState[node][round]` ∈ {Proposing, Prevoting, Prevoted, Precommitting, Precommitted, Completed}
- Actions: `Propose(node, round, block)`, `Prevote(node, round, block)`, `Precommit(node, round, block)`, `CompleteRound(node, round)`, `StartNextRound(node, round+1)`
- Guards: Precommit requires prior prevote. Round R completion requires R-2 estimate finalized. Primary proposal only when last estimate NOT finalized.
- Model `Crash(node)` + `Recover(node)` to verify that persisted `HasVoted` state prevents equivocation

**Priority**: Medium
**Rationale**: 6 historical bugs in the core algorithm. Round state transitions are the core of GRANDPA and directly model-checkable. However, several have already been fixed and the remaining risk is moderate.

---

### Family 5: Vote Target Selection (MEDIUM)

**Mechanism**: Incorrect determination of what block to vote for, due to authority set limit miscalculation, SelectChain inconsistencies, or voting rule bugs.

**Evidence**:
- Historical: `d303c73f9` — voting rules restricted vote below round base (PR #4155)
- Historical: `da3a34ff7` — wrong "best block" passed to voting rules (PR #12477)
- Code analysis: `current_limit()` only checks ForkTree roots (authorities.rs:423-429)
- Code analysis: `unreachable!()` in block walk-back if block is pruned (environment.rs:1278)

**Affected code paths**:
- `best_chain_containing` (environment.rs:1178-1316)
- `AuthoritySet::current_limit` (authorities.rs:423-429)
- `VotingRules::restrict_vote` (voting_rule.rs:218-258)

**Suggested modeling approach**:
- Variables: `voteTarget[node]`, `authoritySetLimit` (derived from pending changes)
- Actions: `SelectVoteTarget(node)` with guard: `voteTarget >= roundBase AND voteTarget <= authoritySetLimit`
- Key: Model the interaction between pending authority changes and vote target selection. Verify that no node votes past a pending change boundary.

**Priority**: Medium
**Rationale**: 4 historical bugs. Directly tied to authority set change safety (Family 1). Model-checkable as an extension of the authority change model.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Standard + Forced authority set changes | Family 1: 6+ critical/high bugs; ForkTree + forced change interaction is the most complex state | Two types of pending changes; standard applied on finalization, forced on block depth; dependency ordering |
| Multiple finalization paths | Family 2: 5 critical/high bugs from racing paths | Split finalization into sub-steps with interleaving; model authority set lock |
| Equivocation counting in GHOST | Family 3: 2 critical algorithm bugs; equivocators "vote for everything" | Byzantine voters cast conflicting votes; verify GHOST computation correctness |
| Round state machine | Family 4: 6 bugs in voting phase ordering | Propose→Prevote→Precommit→Complete with guards; crash/recover |
| Vote target limits from pending changes | Family 5: 4 bugs; ties to Family 1 | Vote targets bounded by earliest pending change effective number |
| Crash and recovery | Families 2, 4: persistence atomicity concerns | Crash action resets volatile state; recover from persisted state |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Gossip protocol details | Implementation-level networking. Reputation, message routing, catch-up are not protocol logic. |
| Warp sync / finality proofs | Separate subsystem for light clients. Not core GRANDPA consensus. 5 bugs but all implementation-specific. |
| Equivocation reporting / slashing economics | Runtime/economic mechanism. The pallet equivocation handling is integration logic, not protocol safety. |
| Observer mode | Currently disabled in code (lib.rs:761). Dead code path. |
| Justification creation/verification | Serialization/deserialization logic. The justification correctness follows from commit validity. |
| Voting rules (BeforeBestBlockBy, ThreeQuarters) | Liveness optimization, not safety. Voting rules can only restrict (never expand) the vote target. |
| Block pruning / storage management | Storage layer concern. Not protocol logic. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| ForkTree pending changes | `pendingStandard`, `pendingForced` | Model standard changes on forks and forced change dependency | Family 1 |
| Dual finalization paths | `importInProgress`, `finalizationLock` | Model gossip vs sync finalization interleaving | Family 2 |
| Equivocation counting | `equivocators`, `voteWeight` | Model equivocators as "voting for everything" | Family 3 |
| Round state machine | `roundPhase`, `hasVoted` | Model propose→prevote→precommit→complete ordering | Family 4 |
| Authority set limit | `voteLimit` | Derived from pending changes; constrains vote targets | Family 5 |
| Crash recovery | `persisted`, `volatile` | Split state into persisted (survives crash) and volatile | Families 2, 4 |
| Forced change dependency | `medianFinalized` | Model forced change blocked until standard deps satisfied | Family 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| FinalizationSafety | Safety | If block B is finalized, all future finalized blocks are descendants of B | Standard, Families 1-3 |
| ElectionSafety | Safety | At most one authority set active per set_id | Family 1 |
| AuthoritySetConsistency | Safety | All honest nodes agree on the authority set for a given set_id | Family 1 |
| VoteLimitRespected | Safety | No honest voter votes for a block past the earliest pending change boundary | Family 5 |
| NoPrevoteSkip | Safety | A voter must prevote before precommitting in any round | Family 4 |
| EquivocationCorrectness | Safety | Equivocators are counted as voting for all blocks; GHOST result is still correct | Family 3 |
| ForcedChangeDependency | Safety | A forced change is not applied until all dependent standard changes (ancestors with effective_number ≤ median_last_finalized) have been applied | Family 1 |
| StandardChangeOrdering | Safety | Standard changes on the same branch are applied in order (ancestor before descendant) | Family 1 |
| RoundCompletion | Liveness | If ≥ 2f+1 honest voters participate, rounds eventually complete | Family 4 |
| FinalityProgress | Liveness | If ≥ 2f+1 honest voters participate and new blocks are produced, finality advances | Families 1, 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | `current_limit()` only checks ForkTree roots — non-root change with lower effective number allows votes past limit | VoteLimitRespected | 1, 5 |
| MC-2 | Forced change dependency check only examines root standard changes | ForcedChangeDependency | 1 |
| MC-3 | Stalled state consumed but forced change not scheduled (concurrent PendingChange) | FinalityProgress | 1 |
| MC-4 | Concurrent finalization via gossip and sync with authority set change | AuthoritySetConsistency | 2 |
| MC-5 | Equivocator "voting for everything" — verify GHOST still converges correctly | EquivocationCorrectness | 3 |
| MC-6 | Non-descendant votes in commits rejected even as equivocation proofs (Issue #113) | FinalizationSafety (liveness aspect) | 3 |
| MC-7 | HasVoted overwrite on round completion — crash and restart causes equivocation | FinalizationSafety | 4 |
| MC-8 | Round completion without R-2 estimate finalization — restart replays rounds | RoundCompletion | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Version stamp written before data migration (aux_schema.rs:171,227,291) | Integration test: crash during migration, verify recovery |
| TV-2 | `assert!(!enacts_change)` panic under concurrent finalization (import.rs:835) | Concurrent test: import + finalize same authority-change block simultaneously |
| TV-3 | Missing set_state on startup → round 0 restart → equivocation risk (aux_schema.rs:362) | Unit test: delete set_state key, restart, verify voter behavior |
| TV-4 | Node stuck in Paused state indefinitely (lib.rs:1022) | Integration test: crash during authority transition, verify recovery |
| TV-5 | Non-atomic authority set + voter set state writes (aux_schema.rs) | Crash injection test between the two writes |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Observer mode silently disabled (lib.rs:757-761) | Resolve issue #5013 or remove observer config option |
| CR-2 | `WeakBoundedVec::force_from` bypasses MaxAuthorities (frame/grandpa/lib.rs:498) | Consider using `BoundedVec` with hard error instead |
| CR-3 | Silent failure of authority set change in `on_new_session` (frame/grandpa/lib.rs:592) | Add error propagation or logging |
| CR-4 | SetIdSession pruning rejects valid equivocation proofs (equivocation.rs:202) | Ensure MaxSetIdSessionEntries >= bonding duration + 1 |
| CR-5 | Catch-up threshold gap penalizes honest peers (gossip.rs:1136) | Align catch-up threshold with vote acceptance window |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/substrate/analysis-report.md`
- **Key source files**:
  - `artifact/substrate/client/consensus/grandpa/src/authorities.rs` (authority set management, 1752 lines)
  - `artifact/substrate/client/consensus/grandpa/src/environment.rs` (voter environment, 1544 lines)
  - `artifact/substrate/client/consensus/grandpa/src/import.rs` (block import, 844 lines)
  - `artifact/substrate/client/consensus/grandpa/src/lib.rs` (voter lifecycle, 1217 lines)
  - `artifact/substrate/client/consensus/grandpa/src/communication/gossip.rs` (gossip, 2650 lines)
  - `artifact/substrate/frame/grandpa/src/lib.rs` (pallet, 625 lines)
  - `artifact/substrate/frame/grandpa/src/equivocation.rs` (equivocation, 290 lines)
- **GitHub issues (most relevant)**: substrate #7321, #6828, #1508, #3437, #3542, #13254, #11175, #6823, #7668; finality-grandpa #113, #23
- **External crate**: `finality-grandpa` v0.16.2 (core GHOST voting algorithm)
- **Reference paper**: "GRANDPA: a Byzantine Finality Gadget" (Stewart, 2020)
