# Modeling Brief: Autobahn BFT Consensus

## 1. System Overview

**System**: Autobahn (Sailfish/Narwhal+HotStuff)  
**Language**: Rust  
**Core Protocol**: Narwhal DAG mempool + HotStuff 3-phase consensus (Prepare-Confirm-Commit)  
**Size**: ~20k LOC across primary, hotstuff, worker, consensus modules

**Category**: **Category A (Distributed / Message-Passing)** — this is a replicated state machine with protocol state transitions (Prepare → Confirm → Commit) driven by network messages and timeouts.

**Sub-category**: **BFT Consensus** — safety argument relies on tolerating ≤ *f* Byzantine faults with threshold n ≥ 3f+1. Applies the authenticated Byzantine fault model with unforgeable honest signatures.

**Key Architectural Properties**:
- Two-layer architecture: Narwhal DAG layer (primary nodes, workers) + HotStuff consensus layer
- Asynchronous message-passing with channel-based actor model (tokio)
- View-change via Timeout Certificate (TC) — timeout-triggered consensus rounds
- Crash-recoverable consensus state via RocksDB store
- Split leadership: DAG leader (Narwhal) and consensus leader (HotStuff)

---

## 2. Bug Families

### Family 1: Unsafe Vote Safety State — Persistent Storage

**Mechanism**: Core voting safety state (`last_voted_round` in HotStuff, `last_voted_consensus` + view state in primary) is maintained in-memory only, with no guarantee of persisting to durable storage. A replica crash and restart can result in double-voting (voting for two incompatible blocks in the same round).

**Evidence**:
- Historical: hotstuff/src/core.rs:118 — TODO comment: *"TODO [issue #15]: Write to storage preferred_round and last_voted_round."*
- Code analysis: hotstuff/src/core.rs:99-101, 117 — `increase_last_voted_round()` updates in-memory only; store is never called
- Code analysis: hotstuff/src/core.rs:103-114 — `make_vote()` increments `last_voted_round` in memory (line 117) without persistence

**Affected code paths**:
- hotstuff/src/core.rs: `Core::make_vote()` (lines 103-120), `Core::run()` message handling (lines 400-429)
- primary/src/core.rs: `last_voted` HashMap and `last_voted_consensus` set are in-memory only
- store/src/lib.rs: Store exists but is never used to persist voting state

**Suggested modeling approach**:
- **Variables**: Add `PersistentLastVotedRound` (separate from in-memory `last_voted_round`)
- **Actions**: Split voting into two steps: (1) check safety, (2) persist to durable storage before sending vote
- **Granularity**: Model persistence as an atomic action conditional on before-state; a crash between voting and persist is the adversary window
- **Verification boundary**: Invariant "no two votes in same round" must hold even across crash/recovery

**Priority**: **HIGH**  
**Rationale**: This is a direct violation of core BFT safety (preventing double-voting). Every replica crash without persisting voting state is a potential equivocation opportunity. The TODO in the code confirms this is a known gap.

---

### Family 2: Non-Atomic State Transitions in Message Handlers

**Mechanism**: Message handlers update multiple pieces of safety state (`high_qc`, `round`, `last_voted_round`, `high_proposals`, etc.) without atomicity guarantees. If processing is interrupted (network partition, timeout, async yield), intermediate state can leak to vote aggregation or message validation.

**Evidence**:
- Code analysis: hotstuff/src/core.rs:299-303 — `process_qc()` calls `advance_round()` then `update_high_qc()` — these are two separate async operations
- Code analysis: hotstuff/src/core.rs:277-289 — `advance_round()` modifies `round`, `timer`, and `aggregator` state; no synchronization between updates
- Code analysis: hotstuff/src/core.rs:359-389 — `handle_proposal()` processes QC (line 376) and TC (line 381) in separate async calls before voting (line 339)

**Affected code paths**:
- hotstuff/src/core.rs: `handle_proposal()`, `handle_timeout()`, `process_qc()`, `advance_round()`
- primary/src/core.rs: multi-step prepare → confirm → commit transitions across async boundaries

**Suggested modeling approach**:
- **Variables**: Track intermediate states (e.g., "QC seen but round not advanced yet")
- **Actions**: Each message handler should be split into atomic sub-actions: validate, then apply all state changes in one TLA+ action
- **Granularity**: Fine-grained — one action per consistency boundary

**Priority**: **MEDIUM**  
**Rationale**: Interleaving between async operations can cause state divergence, but mitigated by the fact that tokio-select ensures one branch runs to completion before the next is selected. The risk is highest when composed with crash/recovery or network partitions.

---

### Family 3: View-Change (TC) Handling and Round Advance Gaps

**Mechanism**: TC (Timeout Certificate) messages advance rounds and trigger new leader proposals, but the validation of TC embedded in blocks (line 379-382 in core.rs) happens after QC processing, creating a window where a block with an inconsistent TC is partially processed before validation.

**Evidence**:
- Code analysis: hotstuff/src/core.rs:359-389 — `handle_proposal()` calls `process_qc()` (line 376) before checking TC validity; TC is verified after round-advance (lines 379-382)
- Code analysis: hotstuff/src/core.rs:306-357 — `process_block()` checks block.round == self.round at line 334, but this check happens after ancestor lookup — order of operations matters
- Code analysis: hotstuff/src/messages.rs:72-75 — TC validation uses `high_qc_rounds()` to compute min high_qc, but does not validate that TC round is strictly greater than min(high_qc.round)

**Affected code paths**:
- hotstuff/src/core.rs: `handle_proposal()`, `handle_tc()`, `process_qc()`
- hotstuff/src/messages.rs: TC::verify() (lines 291-316)

**Suggested modeling approach**:
- **Variables**: Track which TCs have been seen; track the state of pending round-advance operations
- **Actions**: Model TC processing as a separate action that validates and then commits the round advance atomically
- **Verification boundary**: Invariant "rounds never decrease" and "once a TC for round r is assembled, the leader for round r+1 must receive it"

**Priority**: **MEDIUM**  
**Rationale**: The ordering of QC processing before TC validation is subtle. A Byzantine leader could craft a block with a valid QC but invalid TC; the code processes the QC first (advancing the round) before detecting the invalid TC. This is a potential path divergence.

---

### Family 4: Memory Exhaustion via Unbounded Vote/Timeout Aggregation

**Mechanism**: The aggregator (QCMaker, TCMaker) grows without limit for different (round, digest) or (slot, view) combinations. A Byzantine node sending votes for many different digests/rounds can cause unbounded memory growth, leading to OOM and node crash.

**Evidence**:
- Historical: hotstuff/src/aggregator.rs:29-30 — TODO comment: *"TODO [issue #7]: A bad node may make us run out of memory by sending many votes with different round numbers or different digests."*
- Code analysis: hotstuff/src/aggregator.rs:28-39 — `add_vote()` creates a new HashMap entry per (round, digest) pair without bounds checking
- Code analysis: hotstuff/src/aggregator.rs:41-50 — `add_timeout()` creates entries per round without cleanup until `cleanup()` is called
- Code analysis: hotstuff/src/aggregator.rs:52-55 — `cleanup()` only retains aggregators for rounds >= current round; does not bound per-round aggregator count

**Affected code paths**:
- hotstuff/src/aggregator.rs: QCMaker (HashMap of votes), TCMaker (HashMap of timeouts)
- primary/src/core.rs: Similar unbounded maps for qc_makers, tc_makers (lines 103-107)

**Suggested modeling approach**:
- **Variables**: None needed in base spec; this is an implementation-level resource attack
- **Actions**: If modeling Byzantine behavior, add a "flood votes" action that fills the aggregator with distinct digests
- **Verification boundary**: This is below the protocol level — it's a resource management issue. Better suited for code review / integration testing than TLA+

**Priority**: **LOW → Code-Review-Only**  
**Rationale**: This is a known resource exhaustion risk, not a protocol safety violation. The fix is straightforward (rate-limit or per-round aggregator count cap). TLA+ cannot effectively model memory limits; this should be addressed via code review and deployment constraints.

---

### Family 5: Proposal Generation Race Between QC and TC Paths

**Mechanism**: When a QC or TC causes a round advance, `generate_proposal()` is called to ask the proposer to create a block. However, there is no synchronization between multiple paths that might trigger this. If a QC and TC both arrive for the same round, two proposal requests might be issued, or the second one might overwrite the first.

**Evidence**:
- Code analysis: hotstuff/src/core.rs:228-231 — `handle_vote()` calls `generate_proposal()` if leader for next round
- Code analysis: hotstuff/src/core.rs:269-271 — `handle_timeout()` calls `generate_proposal()` after assembling TC
- Code analysis: hotstuff/src/core.rs:394-396 — `handle_tc()` also calls `generate_proposal()`
- Code analysis: hotstuff/src/proposer.rs:28, 160-161 — `leader` field is stored as `Option<(Round, QC, Option<TC>)>` — if two messages arrive, the second overwrites the first

**Affected code paths**:
- hotstuff/src/core.rs: `handle_vote()`, `handle_timeout()`, `handle_tc()`, `generate_proposal()`
- hotstuff/src/proposer.rs: `run()` loop at lines 123-171

**Suggested modeling approach**:
- **Variables**: Track whether a proposal request is already pending for the current round
- **Actions**: Model proposal generation as atomic with idempotency check — only one proposal per (round, {QC|TC}) pair should be issued
- **Verification boundary**: Invariant "at most one block proposed per round by a leader" should hold even with concurrent QC/TC assembly

**Priority**: **MEDIUM**  
**Rationale**: The proposer might receive duplicate or conflicting (QC, TC) pairs, but the async channel should serialize these. The risk is highest if the proposer's receiver is dropped or the message gets lost. The idempotency of proposal generation is not explicit in the code.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| Item | Why | How |
|------|-----|-----|
| **Crash/Recovery** | Family 1 requires modeling persistent vs in-memory state divergence. A crash without persisting last_voted_round enables double-voting. | Add `PersistentVotedRound` as separate from in-memory `VotedRound`. Model crash action that forgets in-memory state; recovery loads from persistent storage. |
| **Non-Atomic Persistence** | Family 1 — voting must be atomic with persistence before the vote leaves the node. | Split vote action into (1) check safety against persistent state, (2) persist vote round, (3) send vote. A crash between (1) and (2) is safe; a crash between (2) and (3) is safe (vote lost, not duplicated). |
| **TC/View-Change** | Family 3 — TC messages should trigger round advance, but the interaction with QC processing is subtle. Need to verify TC validation does not have ordering bugs. | Model TC assembly as separate from round advance. Verify: (1) TC requires f+1 timeouts, (2) round advances to TC.round + 1, (3) new leader must be elected deterministically. |
| **QC/Round Interaction** | Family 2, 3 — Verify that QC.round always ≤ VotedRound and that advancing round does not repeat a vote. | Model QC assembly (requires quorum of votes) separately from QC processing (round advance). Verify invariant: once a QC for round r is finalized, no node votes for any block in round < r. |

### 3.2 Do Not Model (with rationale)

| Item | Why | How |
|------|-----|-----|
| **Memory Exhaustion (Family 4)** | TLA+ cannot model resource limits. The fix is operational (rate-limit aggregators). | Addressed via code review + configuration (max aggregators per round). Not a protocol safety issue. |
| **Serialization Errors** | The code uses `bincode::serialize()` and `expect()` calls; serialization failure causes panic. This is a deployment concern, not a protocol issue. | Assume network messages are well-formed. Any serialization error in the real system is a fatal node failure, not a recoverable state. |
| **Network Latency / Partition Durations** | The protocol assumes partial-synchronous network (post-GST). Modeling arbitrary partition durations adds state space without new insights. | Use a timeout-based model where timeouts can fire after GST. Do not model arbitrary partition healing schedules. |
| **Worker / DAG Layer Details** | Autobahn includes a Narwhal DAG layer (primary/worker), but the core safety properties are in HotStuff consensus. | Focus on HotStuff core.rs consensus and message validation. DAG layer can be abstracted as a "mempool" that delivers valid certificates. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| **Persistent Voted Round** | `persistent_last_voted_round` (per node), `vote_log` (durable writes) | Track safety-critical vote state across crashes. Enable detection of double-voting attempts. | Family 1 |
| **Vote Atomicity** | `vote_status` ∈ {Checked, Persisted, Sent} | Model the three phases of voting to ensure all-or-nothing semantics. | Family 1, 2 |
| **Round Advance Atomicity** | `pending_round_advance` (state variable) | Ensure round advance happens atomically with QC/TC processing, not spread across multiple async boundaries. | Family 2, 3 |
| **TC Round Validation** | `tc_round_validation` (in TC::verify) | Enforce that TC.round > max(TC.high_qc_rounds()) to prevent stale TC reuse. | Family 3 |
| **Proposal Idempotency** | `proposed_rounds` (set of rounds already proposed by this leader) | Prevent duplicate proposals for the same round even if QC and TC both trigger proposal generation. | Family 5 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| **Safety: No Double Vote** | Safety | For all nodes n and rounds r: n votes for at most one block with round r. Holds even after crash/recovery. | Family 1 |
| **Safety: QC Justifies Quorum** | Safety | Every finalized QC has signatures from ≥ quorum_threshold stake. QC.round > block.round is impossible. | Family 3 |
| **Safety: TC Rounds Advance** | Safety | TC.round ≥ max(TC.high_qc_rounds()). New leader is elected for round TC.round + 1. | Family 3, 5 |
| **Safety: Vote Safety Rules Enforced** | Safety | A node votes for block b only if (b.round > last_voted_round) AND (b.qc.round + 1 == b.round OR TC extends b.qc). | Family 1, 2, 3 |
| **Liveness: Proposals Eventually Proposed** | Liveness | If a leader is elected for round r and receives the QC from round r-1, it eventually proposes a block for round r. | Family 5 |
| **Liveness: View Change Completes** | Liveness | If a node times out in round r, eventually a TC for round r is assembled and a new leader is elected. | Family 3 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable Findings

| ID | Description | Expected Invariant Violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | **Persistent Voting State Loss** — If a leader node crashes after checking voting safety but before persisting last_voted_round, and then recovers and processes a new block for the same round, can it vote twice? | Invariant "No Double Vote" violated. | Family 1 |
| MC2 | **TC Round Validation** — Can a Byzantine node assemble a TC for round r with high_qc_rounds = [r, r, r], satisfying the max() check but creating an invalid state machine transition? | Invariant "TC Rounds Advance" violated or inconsistent leader election. | Family 3 |
| MC3 | **Interleaved QC/TC Processing** — If a node receives a QC and a TC for the same round concurrently, can process_qc() and handle_tc() race, causing an inconsistent high_qc state? | Invariant "Vote Safety Rules Enforced" violated due to stale high_qc. | Family 2, 3 |
| MC4 | **Proposal Generation Idempotency** — If both handle_vote() and handle_timeout() call generate_proposal() for the same round, does the proposer correctly deduplicate or do two blocks get proposed? | Invariant "At most one block per round" violated (node equivocates). | Family 5 |

### 6.2 Test-Verifiable Findings

| ID | Description | Suggested Test Approach |
|----|-------------|----------------------|
| TV1 | **Vote Persistence Under Crash** | Write unit test: (1) call make_vote(), (2) simulate crash before store.write(), (3) recover, (4) verify last_voted_round is reset to 0, (5) verify a new vote for same round is allowed. Assert that safety is violated without persistence. |
| TV2 | **Aggregator Cleanup on Round Advance** | Write unit test: add votes for rounds 1-100 to different aggregators, advance round to 50, verify that aggregators for rounds 1-49 are cleaned. Verify no memory leak. |
| TV3 | **Message Ordering in Handlers** | Write integration test: send QC, then immediately send TC for same round; verify that Core processes both in a consistent order and does not get stuck. |

### 6.3 Code-Review-Only Findings

| ID | Description | Suggested Action |
|----|-------------|-----------------|
| CR1 | **Aggregator Memory Exhaustion (TODO #7)** | Review and implement per-round aggregator count limit. Reject votes/timeouts if count exceeds threshold (e.g., max_digests_per_round = 10). This is operational hardening, not protocol logic. |
| CR2 | **Proposal Generation Race (Family 5)** | Code review: verify that proposer.rs correctly handles duplicate (QC, TC) pairs. If leader receives generate_proposal() twice for same round, ensure only one block is created. |
| CR3 | **Sync/Recovery Invariants** | Code review the synchronizer.rs::waiter() logic: verify that a node does not commit blocks before ancestors are persisted. Ensure commit() in core.rs does not depend on non-durable state. |
| CR4 | **Timer Accuracy and Fairness** | Review timer.rs implementation: ensure timeout delay is measured from block reception, not from internal clock. This affects liveness but not safety. |

---

## 7. Reference Pointers

### Code Files (with line ranges)

- **hotstuff/src/core.rs** (lines 1-430) — Core consensus loop, voting safety rules, view change handling
  - Lines 103-120: `make_vote()` — voting safety checks (Family 1)
  - Lines 236-275: `handle_timeout()` — TC handling (Family 3)
  - Lines 277-289: `advance_round()` — non-atomic state update (Family 2)

- **hotstuff/src/messages.rs** (lines 280-327) — TC message definition and verification
  - Lines 291-316: `TC::verify()` — TC validation logic

- **hotstuff/src/aggregator.rs** (lines 1-140) — QC and TC assembly
  - Lines 29-30: TODO comment (Family 4)
  - Lines 28-39: `add_vote()` — unbounded growth (Family 4)

- **store/src/lib.rs** (lines 1-95) — Persistent storage layer
  - Lines 65-69: `write()` — async write operation

### GitHub Issues & TODOs

- Issue #15: Persist last_voted_round and preferred_round (directly cited in code)
- Issue #7: Memory exhaustion via vote flooding (directly cited in code)
- Issue #195 (primary/): Resource accounting (mentioned in comments)
- Issue #9 (primary/): Batch digest reuse in GC (mentioned in comments)

### Reference Algorithm & Papers

- **HotStuff consensus** (Yin et al., 2019) — 3-phase Prepare-Commit-Confirm with view change via TC
- **Narwhal DAG** (Danezis et al., 2021) — mempool DAG layer feeding certificates to consensus
- **Core BFT safety** (Lamport-Shostak-Pease 1982) — double-voting prevention and quorum intersection

### Related Implementations

- **Aptos / DiemBFT**: Also implements HotStuff; comparison on TC validation and vote persistence
- **Tendermint/CometBFT**: Raft-style voting; persistently stores pre-vote/vote state (for comparison)

---

## Appendix: Coverage Statistics

### Phase 2 (Bug Archaeology)

- **Git history**: Limited (source extract, no full git history available)
- **Code-embedded TODOs**: 50+ found via grep; focused analysis on 5 high-confidence items
- **Direct issue references**: 4 identified (issues #7, #9, #15, #195)
- **False positives excluded**: ~30 (most TODOs were refactoring/optimization hints, not safety bugs)

### Phase 3 (Deep Analysis)

- **Files analyzed**:
  - hotstuff/src/core.rs (full, 430 lines)
  - hotstuff/src/messages.rs (full, 327 lines)
  - hotstuff/src/aggregator.rs (full, 140 lines)
  - hotstuff/src/synchronizer.rs (full, 151 lines)
  - hotstuff/src/proposer.rs (full, 172 lines)
  - primary/src/core.rs (partial, 2189 lines, focused on voting logic)
  - store/src/lib.rs (full, 95 lines)

- **Total lines reviewed**: ~3,400+ (core protocol)
- **Analysis patterns applied**: Code path inconsistency, non-atomic operations, message handler ordering, missing invariant checks

---

## Summary

Autobahn's architecture separates Narwhal DAG (for batching) from HotStuff consensus (for ordering), but the core safety risks cluster around **vote persistence** (Family 1), **state atomicity** (Family 2), and **view-change correctness** (Family 3). The most critical finding is the TODO #15 gap: voting safety state is never persisted to durable storage, creating a direct equivocation window after crash/recovery.

Model checking should focus on:
1. **Persistent vote state vs in-memory state** — ensuring crash does not enable double-voting
2. **Atomic transitions** in message handlers — ensuring QC/TC processing does not leak partial state
3. **TC assembly and round validation** — ensuring malicious TC messages cannot cause inconsistent state

Code review should address the resource exhaustion risk (Family 4) and proposal generation idempotency (Family 5), which are implementation concerns better suited to testing than formal verification.
