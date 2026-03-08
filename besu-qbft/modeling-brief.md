# Modeling Brief: hyperledger/besu QBFT

## 1. System Overview

- **System**: Hyperledger Besu QBFT — Java implementation of the Istanbul BFT (QBFT) consensus protocol for Ethereum-compatible blockchains
- **Language**: Java, ~6400 LOC core logic (qbft-core), ~3250 LOC adaptor layer (qbft), ~5700 LOC shared BFT infrastructure (consensus/common/bft)
- **Protocol**: QBFT (Istanbul BFT) — 4-phase BFT consensus: Proposal → Prepare → Commit → Round Change
- **Key architectural choices**:
  - Single-threaded event loop (`BftProcessor`) dequeues events from `BftEventQueue` and dispatches via `EventMultiplexer`
  - Timer events (block timer, round timer) fire on a separate `ScheduledExecutorService` thread but enqueue events back to the main queue
  - Per-height state machine (`QbftBlockHeightManager`) manages rounds; per-round state (`QbftRound` + `RoundState`) tracks proposals/prepares/commits
  - Block hash includes round number and proposer address in extra data — hash changes when block is re-proposed in a new round
  - Quorum = `ceil(2n/3)` for prepare, commit, and round change; f+1 = `(n-1)/3 + 1` for early round change
  - In-memory-only consensus state; crash = full state loss, recovery via round changes
- **Concurrency model**: Single-threaded event loop for all consensus processing; timer threads only enqueue events; `synchronized` only on `doRoundChange()` as defensive measure

## 2. Bug Families

### Family 1: Proposal Re-Proposal Hash Mismatch During Round Change (CRITICAL)

**Mechanism**: When a prepared block is re-proposed in a higher round, the block's identity (hash) changes because it embeds the round number and proposer in extra data. If the proposer or validator fails to correctly reconstruct the block hash accounting for the round/proposer substitution, proposals are permanently rejected and the chain stalls.

**Evidence**:
- Historical: #3785, #6053, #6613, #6732 — chain stalls with "Latest Prepared Metadata blockhash does not align with proposed block" (all fixed by PR #7875)
- Historical: Commit `f64c147c4a` — round number was not updated in re-proposed blocks
- Historical: Commit `01f8f0325d` (#9204) — proposer address was not updated in re-proposed blocks
- Code analysis: `ProposalValidator.java:167-189` — hash reconstruction requires correct round + proposer substitution
- Code analysis: `QbftRound.java:169-172` — `replaceRoundAndProposerForProposalBlock()` is the fix

**Affected code paths**:
- `QbftRound.startRoundWith()` (QbftRound.java:153-183) — proposer-side block re-wrapping
- `ProposalValidator.validate()` (ProposalValidator.java:151-206) — validator-side hash reconstruction
- `RoundChangeArtifacts.create()` (RoundChangeArtifacts.java:70-104) — selecting best prepared certificate

**Suggested modeling approach**:
- Variables: Block identity must include round number and proposer. Model `blockHash` as a function of `(blockContent, round, proposer)`.
- Actions: Split Proposal into `ProposeNewBlock` (round 0, no certificate) and `ReProposeFromCertificate` (round > 0, prepared certificate). The re-proposal action must update block identity to the new round/proposer.
- Key invariant: The validator's hash reconstruction must match the proposer's block — model both sides and check equality.

**Priority**: High
**Rationale**: 4+ production chain stalls sharing the same root cause. The hash-includes-round-and-proposer design is a QBFT-specific complexity absent from simpler BFT protocols. Two separate fixes were needed (round number in 2024, proposer address in 2025), suggesting this area may have further issues. TLA+ can systematically verify all round-change re-proposal scenarios.

---

### Family 2: Event Queue Race Between Timer and Block Import (CRITICAL)

**Mechanism**: Timer events (round expiry, block timer) are enqueued asynchronously and can be processed after a block has been successfully imported but before the `NEW_CHAIN_HEAD` event is processed. This creates a window where stale timer events trigger incorrect round changes or redundant proposals.

**Evidence**:
- Historical: #1734 — Two honest IBFT2 validators commit different blocks at same height (safety violation, discovered via formal verification)
- Historical: #2095 — Round change sent before block period expired, stalling network (fixed by PR #2112)
- Code analysis: `QbftController.java:276-289` — dual-guard pattern (blockchain head + height manager) mitigates #1734 for QBFT
- Code analysis: `QbftController.java:261-271` — block timer expiry lacks the blockchain-head guard that round expiry has (asymmetry)
- Code analysis: `QbftRound.java:350-383` — block import failure + committed latch = no retry

**Affected code paths**:
- `QbftController.handleRoundExpiry()` (QbftController.java:276-289)
- `QbftController.handleBlockTimerExpiry()` (QbftController.java:261-271)
- `QbftRound.importBlockToChain()` (QbftRound.java:350-383)
- `BftProcessor.run()` (BftProcessor.java:67-83) — event loop

**Suggested modeling approach**:
- Variables: `eventQueue` as a sequence of events; `blockchainHeight[s]` for the on-chain state; `heightManagerHeight[s]` for the in-memory state
- Actions: Model timer events as non-deterministic insertions into `eventQueue`. Model `ImportBlock` as updating `blockchainHeight` but NOT `heightManagerHeight` (which updates only when `NewChainHead` is dequeued). Model `ProcessRoundExpiry` with the dual-guard check. Model `ProcessBlockTimerExpiry` with only the height-manager check (no blockchain check).
- Granularity: The event queue ordering is the key — model event dispatch as a single action per event type.

**Priority**: High
**Rationale**: #1734 was a confirmed safety violation (two different blocks at the same height). The QBFT fix (dual-guard) is correct for round expiry but the block timer path has an asymmetric guard. TLA+ can verify whether the dual-guard is sufficient and whether the block timer asymmetry can cause issues.

---

### Family 3: Round Change Quorum and Certificate Management (HIGH)

**Mechanism**: The round change protocol requires collecting `2f+1` round change messages, selecting the highest prepared certificate among them, and using it to justify the next proposal. Bugs in quorum counting, duplicate handling, certificate selection, or the "actioned" one-shot flag can cause incorrect round transitions or lost certificates.

**Evidence**:
- Historical: #1736 — Duplicate prepares not discarded in prepared certificate counting (safety vulnerability, fixed by PR #1671)
- Historical: #1822 — f+1 early round change was missing for 3.5 years (liveness gap, fixed by PR #7838)
- Historical: Commit `5ab214e894` — `BftMessage` lacked `equals()`/`hashCode()`, allowing duplicate prepares
- Code analysis: `RoundChangeManager.java:52,69,90` — `actioned` flag prevents re-creation of round change certificate; no recovery if first use fails
- Code analysis: `RoundChangeArtifacts.java:72-85` — comparator violates antisymmetric contract when both operands have empty metadata
- Code analysis: `RoundChangeManager.java:156` — `roundSummary` uses `put` (overwrites) while `roundChangeCache` uses `putIfAbsent` (preserves first), creating inconsistent views for f+1 early round change
- Code analysis: `RoundChangeManager.java:249-251` — `roundSummary` is never cleaned by `discardRoundsPriorTo()`

**Affected code paths**:
- `RoundChangeManager.appendRoundChangeMessage()` (RoundChangeManager.java:213-227)
- `RoundChangeManager.futureRCQuorumReceived()` (RoundChangeManager.java:180-204)
- `RoundChangeArtifacts.create()` (RoundChangeArtifacts.java:70-104)
- `QbftBlockHeightManager.handleRoundChangePayload()` (QbftBlockHeightManager.java:378-450)

**Suggested modeling approach**:
- Variables: `roundChangeMessages[s][r]` — set of round change messages per server per target round; `actioned[s][r]` — boolean flag; `roundSummary[s]` — latest round per validator
- Actions: `SendRoundChange`, `ReceiveRoundChange` (with quorum check), `EarlyRoundChange` (f+1 check on roundSummary). Model the `actioned` flag's one-shot behavior.
- Key: Model both the 2f+1 quorum path and the f+1 early path. The f+1 path uses `roundSummary` which has different update semantics than `roundChangeCache`.

**Priority**: High
**Rationale**: 2 historical bugs (#1736 safety, #1822 liveness). The dual data structures (`roundSummary` vs `roundChangeCache`) with different update semantics is a source of potential inconsistencies. TLA+ can verify that the f+1 early round change correctly interacts with the 2f+1 standard path.

---

### Family 4: Validator Set Transition Correctness (HIGH)

**Mechanism**: When the validator set changes (via block-header voting or smart contract), code paths that determine the validator set for the current height must consistently use the correct set. Off-by-one errors in fork schedule lookups, stale validator caches, or TOCTOU races between block import and event processing can cause nodes to use different validator sets, breaking quorum calculations.

**Evidence**:
- Historical: #2868, #2935, #2874 — wrong validators used at fork transition boundaries (3 separate bugs)
- Historical: Commits `0ffe977f86`, `91ef16d378`, `71e6b0ccf1` — off-by-one in fork schedule, wrong protocol schedule config
- Code analysis: `QbftController.java:303` + `295-297` — TOCTOU: validator set can change between message buffering and replay
- Code analysis: `QbftController.java:305-307` — future messages buffered WITHOUT any validator check

**Affected code paths**:
- `ForkingValidatorProvider.getValidatorsAfterBlock()` — determines validators for next block
- `QbftBlockHeightManagerFactory.create()` — uses validator set at creation time
- `QbftController.processMessage()` — checks validator set at processing time

**Suggested modeling approach**:
- Variables: `validators[height]` — validator set per block height (changes at specific heights); `currentValidators[s]` — each server's view of the active validator set
- Actions: `ValidatorSetChange` at specific heights. All message validation actions must check against `validators[currentHeight]`.
- Key: Model validator set changes as occurring at specific block heights. Verify that all quorum calculations use the same validator set. Check for scenarios where a node uses an old validator set for quorum while another uses the new set.

**Priority**: High
**Rationale**: 3 historical bugs in this area, all related to the same off-by-one pattern. Validator set transitions are a classic source of consensus bugs. TLA+ can verify consistency of validator set usage across all code paths.

---

### Family 5: Block Import Failure and Committed State Latch (MEDIUM)

**Mechanism**: Once a node collects `2f+1` commit messages, the `RoundState` transitions to `committed = true` (a one-way latch). If the subsequent block import fails (e.g., storage error), the latch prevents retry. The node cannot re-import the block and is stuck for this round. Similarly, if the commit seal creation fails but the proposal was accepted, the node loses its own commit vote toward quorum.

**Evidence**:
- Historical: #6053 — RocksDB Busy error during block persistence triggered cascading stall
- Code analysis: `QbftRound.java:350-383` — `importBlockToChain()` logs error but has no retry; committed latch at `RoundState.java:141` prevents re-entry
- Code analysis: `QbftRound.java:292-295` — `SecurityModuleException` during commit seal creation returns `true` but skips adding local commit to `roundState`

**Affected code paths**:
- `QbftRound.importBlockToChain()` (QbftRound.java:350-383)
- `QbftRound.updateStateWithProposedBlock()` (QbftRound.java:283-324)
- `RoundState.updateState()` (RoundState.java:139-141)

**Suggested modeling approach**:
- Variables: `committed[s]` — boolean latch; `blockImported[s]` — whether block was actually persisted
- Actions: `CollectCommitQuorum` sets `committed = TRUE`. `ImportBlock` can non-deterministically fail. Model as: committed but not imported = stuck until round change timeout.
- Key: The latch behavior means a transient import failure becomes a permanent per-round failure. Model whether this degrades liveness beyond the expected round timeout recovery.

**Priority**: Medium
**Rationale**: One production instance (#6053). The protocol recovers via round changes (other nodes import successfully), but the affected node wastes a round. TLA+ can verify that liveness is maintained despite import failures.

---

### Family 6: Empty Block Timer Interaction with Round Changes (MEDIUM)

**Mechanism**: When `emptyBlockPeriodSeconds` is configured, the block creation logic can reset the current round to `Optional.empty()` and cancel the round timer, entering a "waiting for empty block timer" state. During this window, incoming messages are treated as future-round messages, and round change handling behaves differently (may trigger round 0 recreation).

**Evidence**:
- Historical: #8354 — emptyBlockPeriodSeconds doesn't work as expected (transactions delayed by minutes)
- Historical: #7873 — emptyBlockPeriodSeconds ignores validator votes
- Historical: #8191 — emptyBlockPeriodSeconds not working when transactions arrive
- Code analysis: `QbftBlockHeightManager.java:226-236` — empty block handling cancels round timer and sets `currentRound = Optional.empty()`
- Code analysis: `QbftBlockHeightManager.java:422-424` — early RC path recreates round 0 when `currentRound.isEmpty()`, potentially conflicting with pending empty block timer

**Affected code paths**:
- `QbftBlockHeightManager.buildBlockAndMaybePropose()` (QbftBlockHeightManager.java:207-237)
- `QbftBlockHeightManager.handleRoundChangePayload()` (QbftBlockHeightManager.java:420-424)
- `BlockTimer.resetTimerForEmptyBlock()` (BlockTimer.java:142-151)

**Suggested modeling approach**:
- Variables: `emptyBlockTimerPending[s]` — whether waiting for empty block period; `hasPendingTxs[s]` — whether the proposer has transactions
- Actions: `BlockTimerExpiry` with empty-block logic: if block is empty and period not expired, reset timer. `EmptyBlockTimerExpiry` fires the rescheduled timer.
- Key: Model the interaction between the empty block timer reset and incoming round change messages.

**Priority**: Medium
**Rationale**: 3 reported issues with this feature, none definitively fixed. The empty block period feature is optional but widely used in private networks. TLA+ can verify that the timer interaction does not cause liveness violations.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Round-change re-proposal with hash reconstruction | Family 1: root cause of 4 production stalls; 2 separate fixes | Model block identity as `(content, round, proposer)`. Split Proposal into round-0 and re-proposal variants. |
| Event queue with timer interleaving | Family 2: root cause of IBFT2 safety violation #1734 | Model `eventQueue` with non-deterministic timer insertion. Separate `blockchainHeight` from `heightManagerHeight`. |
| Round change quorum: standard (2f+1) and early (f+1) | Family 3: 2 historical bugs; dual data structures with different semantics | Model both `roundChangeCache` (per-round, putIfAbsent) and `roundSummary` (latest, put-overwrites). |
| Validator set changes at height boundaries | Family 4: 3 historical off-by-one bugs | Model `validators[height]` changing at specified heights. All quorum checks use height-specific validator sets. |
| Block import failure with committed latch | Family 5: production trigger for chain stall | Model `committed` as one-way latch. `ImportBlock` can fail non-deterministically. |
| Crash and recovery | General: in-memory state is lost on crash | `Crash` action resets all volatile state. Node recovers by receiving messages from peers. |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| RLP encoding / serialization details | Families 2109/2134/2145 are interop encoding bugs, not protocol logic |
| Ethereum block structure (withdrawals, EVM state) | #5842, #9644 are EVM/fork-specific, not consensus protocol logic |
| Empty block period timer | Family 6 is medium priority and significantly expands state space; can be added as extension |
| Gossip propagation | Gossip-before-validation is a bandwidth concern, not a safety issue |
| Transaction pool / block creation timing | #7589, #6732 trigger involves block creation latency which is below protocol abstraction |
| RocksDB / storage layer errors | #6053, #9040 involve storage failures which are below protocol abstraction |
| Signature / cryptographic operations | Assume correct signatures; focus on protocol logic |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Block identity with round+proposer | `blockHash = <<content, round, proposer>>` | Capture hash-change on re-proposal | Family 1 |
| Event queue model | `eventQueue`, `blockchainHeight`, `heightManagerHeight` | Capture timer/import race | Family 2 |
| Dual round-change tracking | `roundChangeCache`, `roundSummary`, `actioned` | Capture f+1 vs 2f+1 interaction | Family 3 |
| Dynamic validator set | `validators[height]`, `currentValidators[server]` | Capture off-by-one at boundaries | Family 4 |
| Committed latch | `committed`, `blockImported` | Capture import failure stuck state | Family 5 |
| Crash/recovery | `alive[server]`, volatile state reset | Standard BFT crash model | General |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| Agreement | Safety | No two honest nodes commit different blocks at the same height | Standard, Family 2 |
| Validity | Safety | A committed block was proposed by the legitimate proposer for that round | Standard, Family 1 |
| PreparedBlockIntegrity | Safety | If a proposal carries a prepared certificate, the proposed block matches the certificate's block (after round/proposer substitution) | Family 1 |
| RoundChangeSafety | Safety | A round change quorum of 2f+1 messages from distinct validators is required for non-zero round proposals | Family 3 |
| QuorumConsistency | Safety | All quorum calculations at a given height use the same validator set | Family 4 |
| CommitLatchProgress | Liveness | If a node's committed latch fires but import fails, the node eventually participates in the next round | Family 5 |
| LivenessUnderCrash | Liveness | If at most f nodes crash, the protocol eventually commits a new block | General |
| LivenessUnderTimerRace | Liveness | If a round expiry event races with block import, the protocol does not stall | Family 2 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | Block timer expiry lacks the blockchain-head guard that round expiry has — can a stale block timer cause a duplicate proposal? | Agreement or Validity | 2 |
| MC-2 | The `actioned` flag prevents round-change certificate re-creation — if the proposer's proposal from the first certificate fails, can the system recover? | Liveness | 3 |
| MC-3 | `roundSummary` (put-overwrites) and `roundChangeCache` (putIfAbsent) can disagree — can f+1 early round change use stale roundSummary data to jump to wrong round? | RoundChangeSafety | 3 |
| MC-4 | Validator set changes at height H — can one node use validators(H-1) while another uses validators(H) for the same round's quorum check? | QuorumConsistency | 4 |
| MC-5 | Block import failure with committed latch — does the protocol maintain liveness when one node's import fails but commit was broadcast? | CommitLatchProgress | 5 |
| MC-6 | Re-proposal hash: if the comparator in `RoundChangeArtifacts` returns a different "best prepared" than the validator's `getRoundChangeWithLatestPreparedRound`, can the proposal be rejected? | PreparedBlockIntegrity | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | `SecurityModuleException` during commit seal creation: node loses its own commit vote (QbftRound.java:292-295) | Unit test: mock seal creation to fail, verify commit quorum still reached with other nodes |
| TV-2 | Comparator contract violation in `RoundChangeArtifacts.java:72-85` when both operands have empty metadata | Unit test: create collection where all round changes have empty metadata, verify `max()` returns any element |
| TV-3 | FutureMessageBuffer eviction removes ALL messages for highest height (FutureMessageBuffer.java:128-135) | Unit test: fill buffer with mixed-height messages, verify near-future messages survive eviction |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `roundSummary` in `RoundChangeManager` is never cleaned by `discardRoundsPriorTo()` — memory grows per height | Add cleanup of `roundSummary` in `discardRoundsPriorTo()` |
| CR-2 | Future messages buffered without validator check (QbftController.java:305-307) — non-validator can fill buffer | Add lightweight validator check for future messages |
| CR-3 | Gossip happens before height-manager content validation (QbftController.java:221-223) — invalid messages propagated | Move gossip after handleMessage.accept() |
| CR-4 | Three independent lifecycle flags (Processor, Queue, Controller) not coordinated | Unify lifecycle management |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/besu-qbft/analysis-report.md`
- **Key source files**:
  - `consensus/qbft-core/.../statemachine/QbftRound.java` (398 lines — round consensus logic)
  - `consensus/qbft-core/.../statemachine/QbftBlockHeightManager.java` (508 lines — round change orchestration)
  - `consensus/qbft-core/.../statemachine/QbftController.java` (317 lines — event routing)
  - `consensus/qbft-core/.../statemachine/RoundChangeManager.java` (271 lines — round change tracking)
  - `consensus/qbft-core/.../statemachine/RoundState.java` (217 lines — quorum tracking)
  - `consensus/qbft-core/.../validation/ProposalValidator.java` (351 lines — proposal validation)
  - `consensus/common/.../bft/BftHelpers.java` (100 lines — quorum calculation)
- **GitHub issues**: #1734, #1736 (safety); #3785, #6053, #6613, #6732 (Family 1 stalls); #2095, #1822 (Family 2/3 timer/round change); #2868, #2935, #2874 (Family 4 validators)
- **Reference algorithm**: Istanbul BFT (QBFT) paper
- **Reference TLA+ spec**: The QBFT paper includes a formal specification that can serve as the base spec
