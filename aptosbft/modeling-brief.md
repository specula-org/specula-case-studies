# Modeling Brief: Aptos BFT (HotStuff/Jolteon)

## 1. System Overview

- **System**: Aptos BFT consensus — Rust implementation in `aptos-core/consensus/`
- **Language**: Rust, ~6500 LOC core logic (round_manager 2261, pending_votes 869, safety_rules 500+215, epoch_manager 2144)
- **Protocol**: 2-chain HotStuff with Jolteon extensions (order votes, optimistic proposals)
- **Key architectural choices**:
  - **Dual voting paths**: Regular votes (QC formation) and order votes (ordering certificates) with **independent safety checks** — regular votes track `last_voted_round`, order votes track `highest_timeout_round`
  - **Optimistic proposals**: Pre-send proposals before QC formation for consecutive rounds
  - **Decoupled execution pipeline**: Ordered blocks flow through BufferManager -> Execution -> Signing -> Persisting as separate async tasks
  - `debug_assert` used for safety-critical TC epoch/round checks (compiled out in release builds)
  - Commit vote path (`sign_commit_vote`) has explicit TODO markers for missing safety guards
- **Concurrency model**: Single-threaded RoundManager event loop with biased `tokio::select!`; parallel signature verification on BoundedExecutor; pipeline phases as separate tasks; proposal generation spawned on separate tokio task

## 2. Bug Families

### Family 1: Missing Safety Guards on Auxiliary Voting Paths (HIGH)

**Mechanism**: New voting/signing paths (order votes, commit votes, 2-chain timeouts) added incrementally without the same safety checks as the original vote path.

**Evidence**:
- Historical: PR #13711 — missing epoch check in `verify_order_vote_proposal` (safety violation)
- Historical: `4c2f5fb4a8` — missing timeout structure verification in 2-chain safety rules
- Historical: `f58e184471` — timeout signing without `last_voted_round` or `preferred_round` checks
- Historical: `cef84ff700` — signer checked too late, `last_voted_round` updated before signer availability confirmed
- Code analysis: safety_rules.rs:412-413 — explicit TODO: "add guarding rules in unhappy path" and "add extension check" in `sign_commit_vote`
- Code analysis: safety_rules_2chain.rs:168-178 — `safe_for_order_vote` only checks `round > highest_timeout_round`, not `last_voted_round`

**Affected code paths**:
- `guarded_sign_commit_vote()` (safety_rules.rs:372-418)
- `guarded_construct_and_sign_order_vote()` (safety_rules_2chain.rs:97-119)
- `guarded_sign_timeout_with_qc()` (safety_rules_2chain.rs:19-51)

**Suggested modeling approach**:
- Variables: `lastVotedRound`, `highestTimeoutRound`, `oneChainRound` (three independent round-tracking variables per node)
- Actions: Separate `CastVote`, `CastOrderVote`, `SignCommitVote`, and `SignTimeout` actions, each with their documented subset of guards
- Granularity: Each must be a distinct action to expose guard asymmetries

**Priority**: High
**Rationale**: 5 historical bugs sharing this pattern. Order vote and commit vote paths are the newest code and the least guarded. Missing guards on signing paths are direct safety violations catchable by model checking.

---

### Family 2: Order Vote Protocol Verification Gaps (HIGH)

**Mechanism**: The order vote protocol (Jolteon extension) uses a weaker verification pipeline than regular votes — no round sync-up, lazy QC verification, independent round tracking.

**Evidence**:
- Code analysis: round_manager.rs:1567-1645 — `process_order_vote_msg` does NOT call `ensure_round_and_sync_up` (unlike regular votes)
- Code analysis: round_manager.rs:1598-1618 — QC verification skipped for 2nd+ order votes per block (first establishes trust)
- Code analysis: safety_rules_2chain.rs:97-119 — order votes do NOT update `last_voted_round`
- Code analysis: order_vote_msg.rs:46-47 — "The quorum cert is verified in the round manager when the quorum certificate is used" (deferred verification)
- Historical: `061db311b3` — missing epoch check on order vote proposals
- Historical: `85b976dd68` — `InvalidOrderedLedgerInfo` after fast-forward sync due to order vote cert assumptions

**Affected code paths**:
- `process_order_vote_msg()` (round_manager.rs:1567-1645)
- `broadcast_order_vote()` (round_manager.rs:1515-1567)
- `insert_order_vote()` (pending_order_votes.rs:61-157)

**Suggested modeling approach**:
- Variables: `pendingOrderVotes`, `highestOrderedRound`, `orderVoteLedgerInfos`
- Actions: `SendOrderVote` (after QC formation), `ReceiveOrderVote` (100-round window, no sync-up), `FormOrderingCert` (from 2f+1 order votes)
- Key: Model that order votes and regular votes have independent round tracking — casting order votes for round R does not prevent regular voting at round < R

**Priority**: High
**Rationale**: Order votes are the Jolteon-specific extension beyond standard HotStuff. The verification asymmetry with regular votes is systematic and has produced multiple bugs. Model checking can explore whether the weaker guards create safety gaps.

---

### Family 3: Pipeline/Buffer Manager Race Conditions (HIGH)

**Mechanism**: The decoupled execution pipeline has separate async tasks for ordering, execution, signing, and persisting. Epoch transitions, state sync, and commit proof forwarding create race windows between these phases.

**Evidence**:
- Historical: `8e1bf87083` — PersistingPhase ongoing commit concurrent with reset, corrupting DB
- Historical: `fd8ae4161d` — epoch change notification sent before final commit task spawned
- Historical: `6236d611e8` — incoming blocks not protected during reset; reconfiguration suffix blocks cause BlockNotFound
- Historical: `d4c5b9a792` — commit proof forwarding race with pre-commit resume
- Historical: `d6c0749229` — sync/buffer manager race in decoupled execution
- Code analysis: sync_manager.rs:76-83 — `need_sync_for_ledger_info` has side effect of pausing pre-commit

**Affected code paths**:
- BufferManager reset path (pipeline/buffer_manager.rs)
- `need_sync_for_ledger_info()` (sync_manager.rs:62-93)
- Epoch transition in pipeline (buffer_item.rs, buffer_manager.rs)

**Suggested modeling approach**:
- Variables: `pipelinePhase` (Ordered/Executed/Signed/Persisted per block), `epochChangeNotified`, `syncInProgress`
- Actions: `ExecuteBlock`, `SignBlock`, `PersistBlock`, `ResetPipeline`, `TriggerSync` — as independent concurrent actions
- Key: Model the epoch transition as an action that can interleave with in-flight pipeline operations

**Priority**: High
**Rationale**: 6+ race condition bugs in this component. The pipeline is the most bug-dense area (15 bug-fix commits on buffer_manager alone). Model checking concurrent pipeline phases against epoch transitions and sync is a classic TLA+ strength.

---

### Family 4: Non-Atomic Safety-Critical Persistence (MEDIUM)

**Mechanism**: Safety data is read, mutated in memory, and written back in a non-atomic read-modify-write pattern. Crash between signing and persisting could leave stale safety state.

**Evidence**:
- Issue #18298: Non-atomic sign + persist in `guarded_construct_and_sign_vote_two_chain` (dismissed by maintainer — vote is persisted before network send — but the code structure is worth validating)
- Historical: `33b0385bb0` — safety rules writes not synced to disk, fixed with double-file swap
- Historical: `4ffd6ff5f3` — last sent vote not persisted, lost on restart
- Historical: `fdfd9f2bc5` — recovery root used `min_by_key` instead of `max_by_key`
- Code analysis: safety_rules_2chain.rs:66-92 — read at line 66, multiple mutations, write at line 92

**Suggested modeling approach**:
- Variables: `persistedSafetyData`, `volatileSafetyData` (separate persisted vs in-memory state)
- Actions: `Crash` action resets volatile state to last persisted state. `PersistSafetyData` as explicit step between signing and network send.
- Key: Verify that no double-voting survives crash recovery

**Priority**: Medium
**Rationale**: Maintainers say #18298 is not exploitable because votes are persisted before sending. But the structural pattern is fragile, and historical bugs (fsync, lost last_vote, wrong recovery root) show persistence has been error-prone. TLA+ crash recovery modeling is valuable insurance.

---

### Family 5: Epoch Transition Boundary Bugs (MEDIUM)

**Mechanism**: Cross-epoch operations (votes, leader election, state sync, timestamp propagation) have incomplete epoch boundary guards.

**Evidence**:
- Historical: `aef68f494b` — cross-epoch leader election broken (round-only comparison, missing epoch)
- Historical: `e8eaaeee4e` — reconfiguration broken in decoupled execution (buffer manager not reset, timestamp not propagated)
- Historical: `7a66f25d79` — reconfiguration timestamp not propagated to suffix batches
- Historical: `0f9bccda2e` — multiple EventProcessors started from epoch change race
- Historical: `8a50d8f021` — RPC epoch not checked in epoch_manager
- Code analysis: timeout_2chain.rs:248-257 — `debug_assert_eq` for epoch/round checks compiled out in release

**Suggested modeling approach**:
- Variables: `currentEpoch`, `epochConfig` (validator set per epoch)
- Actions: `EpochChange` action that updates config, resets round state, clears pending votes. All voting/timeout actions must include epoch preconditions.
- Key: Verify that no message from epoch E-1 can affect epoch E decisions

**Priority**: Medium
**Rationale**: 8+ epoch transition bugs in git history. The `debug_assert` pattern means release builds skip safety-critical epoch checks in TC aggregation. Model checking should verify epoch isolation as a fundamental invariant.

---

### Family 6: Optimistic Proposal Verification Gaps (LOW)

**Mechanism**: Optimistic proposals follow a weaker verification path than regular proposals — no proposer check on current-round path, deferred SyncInfo verification, no parent QC.

**Evidence**:
- Code analysis: round_manager.rs:832-836 — current-round opt proposals skip `is_valid_proposer` check
- Code analysis: opt_proposal_msg.rs:125 — "we postpone the verification of SyncInfo until it's being used"
- Code analysis: round_manager.rs:859-891 — parent QC constructed from local state, not carried in message

**Priority**: Low
**Rationale**: Downstream `process_proposal` catches invalid proposers. The opt proposal path is a latency optimization that eventually feeds into the fully-verified proposal path. Model if time permits but not critical.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Dual voting paths (vote vs order vote) | Family 1, 2: independent safety checks with asymmetric guards | Two separate vote actions with different preconditions; independent round tracking variables |
| Commit vote signing | Family 1: explicit TODO for missing guards | `SignCommitVote` action with current (incomplete) guards to find violations |
| Order vote protocol | Family 2: systematic verification asymmetry | `SendOrderVote`, `ReceiveOrderVote`, `FormOrderingCert` with 100-round window and no sync-up |
| Pipeline phases | Family 3: 6+ race conditions | Model Ordered/Executed/Signed/Persisted as separate state transitions per block |
| Epoch transitions | Family 5: 8+ bugs, debug_assert in release | `EpochChange` action; epoch precondition on all message-processing actions |
| Crash recovery | Family 4: persistence bugs | `Crash` action + persisted vs volatile safety state |
| 2-chain timeout and TC | Family 1: missing timeout verification bugs | `SignTimeout`, `FormTC` actions; TC carries highest HQC round |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Optimistic proposals | Family 6: downstream verification catches issues; latency optimization not safety-critical |
| Quorum store / batch management | Implementation detail; proof queue bugs (double negation, backpressure) are logic errors better caught by testing |
| Randomness generation (DKG/VRF) | Separate subsystem; race conditions (#17922) are concurrency bugs below protocol-level abstraction |
| DAG consensus mode | Alternative consensus path, not HotStuff/Jolteon |
| Consensus observer | Observer role for fullnodes; #18383 is an execution determinism issue, not protocol logic |
| Network message ordering | LIFO bug (`8988eab9f0`) is a configuration error, not protocol logic |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Order vote path | `highestTimeoutRound`, `pendingOrderVotes`, `highestOrderedRound` | Capture Jolteon order vote mechanism with independent safety checks | Family 1, 2 |
| Commit vote path | (split in actions) | Expose missing guards in commit vote signing | Family 1 |
| Pipeline phases | `pipelinePhase`, `syncInProgress`, `epochChangeNotified` | Model concurrent pipeline operations and epoch transition races | Family 3 |
| Crash recovery | `persistedSafetyData`, `volatileSafetyData` | Verify safety under crash recovery | Family 4 |
| Epoch boundary | `currentEpoch`, `epochConfig` | Verify cross-epoch isolation | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| VoteSafety | Safety | No two QCs for different blocks in the same (epoch, round) | Standard, Family 1 |
| OrderVoteSafety | Safety | No two ordering certificates for different blocks in the same (epoch, round) | Family 2 |
| CommitSafety | Safety | 2-chain commit rule: if B0 committed, there exists certified B1 with round(B0)+1 = round(B1) | Standard |
| EpochIsolation | Safety | No vote/order-vote/timeout from epoch E affects decisions in epoch E' != E | Family 5 |
| NoDoubleVoteAfterCrash | Safety | After crash recovery, a node does not vote for a conflicting block in a previously-voted round | Family 4 |
| CommitVoteConsistency | Safety | Commit vote signed for block B implies B was previously ordered with 2f+1 order votes | Family 1 |
| PipelineMonotonicity | Safety | Pipeline phases advance monotonically: Ordered -> Executed -> Signed -> Persisted | Family 3 |
| Liveness | Liveness | If fewer than f nodes are faulty, a new block is eventually committed | Standard |
| TimeoutLiveness | Liveness | If a round times out, a TC is eventually formed and the next round starts | Family 1 |
| OrderVoteLiveness | Liveness | If a QC is formed and fewer than f nodes are faulty, an ordering certificate is eventually formed | Family 2 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | Order vote cast at round R does not prevent regular vote at round < R (independent tracking) | OrderVoteSafety or VoteSafety | 1, 2 |
| MC-2 | Commit vote signed without round-monotonicity check (TODO at safety_rules.rs:412) | CommitVoteConsistency | 1 |
| MC-3 | TC aggregation accepts cross-epoch timeouts (debug_assert compiled out in release) | EpochIsolation | 5 |
| MC-4 | Crash between sign and persist allows double-voting on recovery | NoDoubleVoteAfterCrash | 4 |
| MC-5 | Order vote without epoch check allows cross-epoch ordering cert formation | EpochIsolation, OrderVoteSafety | 2, 5 |
| MC-6 | Epoch change interleaved with in-flight pipeline operations corrupts commit | PipelineMonotonicity | 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | pending_opt_proposals unbounded growth for skipped rounds (round_manager.rs:344) | Integration test: inject proposals for many future rounds, check memory |
| TV-2 | MUST_FIX paths in pending_votes.rs (lines 248, 409, 457) | Unit test: trigger VerifyError variants, verify no panic |
| TV-3 | Randomness share race between network receipt and metadata update (#17922) | Concurrent test: send shares before block metadata |
| TV-4 | need_sync_for_ledger_info side-effect pauses pre-commit (sync_manager.rs:76-83) | Integration test: call multiple times, verify pre-commit state |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | safety_rules.rs:412-413 TODO: missing guarding rules in sign_commit_vote unhappy path | Add round-monotonicity and extension checks |
| CR-2 | timeout_2chain.rs:248-257: debug_assert for epoch/round should be assert or error | Change to runtime check in release builds |
| CR-3 | opt_proposal_msg.rs:125: SyncInfo verification deferred | Evaluate if deferred verification creates exploitable window |
| CR-4 | Typo "dostinct" at safety_rules.rs:405 | Minor fix |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/aptosbft/analysis-report.md`
- **Key source files**:
  - `consensus/src/round_manager.rs` (central event loop, 2261 lines)
  - `consensus/safety-rules/src/safety_rules.rs` (core safety rules, 500 lines)
  - `consensus/safety-rules/src/safety_rules_2chain.rs` (2-chain rules, 215 lines)
  - `consensus/src/pending_votes.rs` (vote aggregation, 869 lines)
  - `consensus/src/pending_order_votes.rs` (order vote aggregation, 378 lines)
  - `consensus/src/liveness/round_state.rs` (pacemaker, 387 lines)
  - `consensus/src/epoch_manager.rs` (epoch lifecycle, 2144 lines)
- **GitHub issues/PRs**: #18298 (persistence atomicity), #18383 (observer panic), PR #13711 (epoch check), #17922 (randomness race), #3977 (epoch stuck)
- **Reference algorithm**: Jolteon (Gelashvili et al., 2021) — 2-chain HotStuff with order votes and optimistic proposals
- **Repository**: `aptos-labs/aptos-core`, consensus module
