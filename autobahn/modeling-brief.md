# Modeling Brief: Autobahn BFT

## 1. System Overview

- **System**: neilgiri/autobahn-artifact — Rust prototype of the Autobahn BFT consensus protocol (SOSP 2024)
- **Language**: Rust (Tokio async), ~4500 LOC core logic (`primary/src/`), ~20K LOC total
- **Protocol**: Autobahn — 3-phase (Prepare/Confirm/Commit) slot-based BFT consensus with DAG data dissemination
- **Key architectural choices**:
  - Two-layer design: asynchronous DAG data dissemination + partially synchronous consensus
  - Parallel slots (up to k concurrent consensus instances, default k=4)
  - Fast path: unanimous (3f+1) PrepareQC skips Confirm phase
  - Consensus messages embedded in DAG headers ("ride-sharing")
  - Core is single-threaded `tokio::select!` event loop; Proposer, Committer, HeaderWaiter as separate Tokio tasks
  - No Mutex/RwLock — all sync via mpsc channels and atomics
  - No persistence of consensus state (`last_voted`, views, etc.) — upstream issue #15 open
- **Reference**: Autobahn paper (Giridharan, Suri-Payer, Abraham, Alvisi, Crooks, SOSP 2024)

## 2. Bug Families

### Family 1: Proposal Binding & Equivocation (CRITICAL)

**Mechanism**: Consensus message digests exclude proposal content. Votes don't bind to the actual proposals being voted on. A Byzantine leader can send different proposals to different honest nodes, and all their votes will be over the same digest, forming a valid QC for ambiguous content.

**Evidence**:
- Code analysis: messages.rs:246 — `//hasher.update(proposal_digest(consensus_message)); FIXME: ADD THIS AND DEBUG` (also lines 128, 194)
- Code analysis: messages.rs:587-590 — Header digest also excludes `consensus_messages` (`//TODO: Sign Consensus Messages too.`)
- Code analysis: messages.rs:772-783 — Vote digest excludes `consensus_votes`
- Code analysis: messages.rs:1349-1358 — Timeout digest hashes NOTHING (empty hasher finalized)
- Code analysis: aggregators.rs:143 — QCMaker uses last vote's digest, no check all votes reference same content

**Affected code paths**:
- `ConsensusMessage::digest()` (messages.rs:233-280) — all three phases
- `Header::digest()` (messages.rs:570-594) — DAG headers
- `Vote::digest()` (messages.rs:772-783) — DAG votes
- `Timeout::digest()` (messages.rs:1349-1358) — view change timeouts
- `QCMaker::append()`/`check_fast_qc()` (aggregators.rs:107-150) — QC formation

**Suggested modeling approach**:
- Variables: none needed beyond standard — the broken binding is modeled by allowing Byzantine nodes to present QCs with arbitrary proposals
- Actions: `ByzantineLeaderEquivocate` — leader sends Prepare with proposals=A to some nodes and proposals=B to others. Both groups vote. A single QC forms that the leader can claim supports either proposal set.
- Key invariant: `AgreementSafety` — no two honest nodes commit different proposals for the same slot

**Priority**: High
**Rationale**: 3 FIXME annotations acknowledge the bug. This is a fundamental safety violation — equivocation on proposal content breaks the core consensus guarantee. The `proposal_digest()` function exists (messages.rs:210-231) but is never called.

---

### Family 2: View Change Safety (HIGH)

**Mechanism**: The TC (Timeout Certificate) formation and winning proposal selection have multiple interacting bugs — view assignment error, broken proposal binding (Family 1 interaction), missing TC verification, and disabled TC broadcast.

**Evidence**:
- Code analysis: messages.rs:1455 — `winning_view = timeout.view` should be `winning_view = *other_view` (assigns timeout's view instead of ConfirmQC's view)
- Code analysis: messages.rs:1405-1411 — `TC::PartialEq` always returns `true`, making `TC::verify()` always succeed via genesis bypass (line 1520)
- Code analysis: core.rs:1916-1922 — `handle_tc()` skips verification, view update, and timer start (near-no-op)
- Code analysis: core.rs:1830-1847 — TC broadcast entirely commented out
- Code analysis: messages.rs:1486 — FIXME: "We should be using the f+1st smallest" for matching Prepares
- Code analysis: core.rs:1450 — `high_proposals` only tracked when `use_fast_path` is true; without it, TC carries no Prepare evidence
- Historical: commit `33ab623` — TC forced adoption bug (safety-critical fix)
- Historical: commit `3baa668` — 3 bugs in one commit including TC view validation
- Historical: commit `65a9fff` — 2-chain safety rule fix
- Historical: upstream issue #77 — TC not verified at all (1-line fix)

**Affected code paths**:
- `get_winning_proposals()` (messages.rs:1436-1499) — selects proposals from TC
- `TC::verify()` (messages.rs:1518-1546) — always returns Ok due to PartialEq bug
- `handle_tc()` (core.rs:1916-1922) — receives TC without verification
- `handle_timeout()` (core.rs:1778-1854) — forms TC, advances view
- `generate_prepare_from_tc()` (core.rs:1856-1914) — creates new Prepare from TC

**Suggested modeling approach**:
- Variables: `views [Server -> Slot -> View]`, `highQC [Server -> Slot -> QC]`, `highProp [Server -> Slot -> Prepare]`
- Actions: `SendTimeout`, `FormTC`, `GeneratePrepareFromTC` — model the exact view change protocol with the code's bugs
- Split: Model the view assignment bug (`timeout.view` vs `other_view`) faithfully to check if it breaks safety
- Key invariant: `ViewChangeSafety` — after view change, the new Prepare must include all proposals that could have been committed in any previous view

**Priority**: High
**Rationale**: 10+ historical bug-fix commits in this area. The view assignment bug (line 1455) is a subtle but potentially safety-critical error. Combined with Family 1 (broken proposal binding in TC's embedded QCs), this creates a compound attack surface.

---

### Family 3: Message Acceptance Guards (HIGH)

**Mechanism**: Missing validation guards allow processing of stale, duplicate, or unauthorized messages — no leader validation for incoming Prepares, no duplicate voting guard for Confirm, voting on already-committed slots, and no commit idempotency.

**Evidence**:
- Code analysis: core.rs:1108-1166 — `is_valid()` for Prepare never checks sender == designated leader. Any node's Prepare is accepted and voted on.
- Code analysis: core.rs:1468-1496 — `process_confirm_message()` has no duplicate voting guard (unlike Prepare which uses `last_voted_consensus` at line 1448)
- Code analysis: core.rs:1108-1166 — `is_valid()` for Prepare does not check if slot is already committed (contrast with `handle_timeout()` line 1793)
- Code analysis: core.rs:1517-1588 — `process_commit_message()` no check for already-committed slot at entry, can overwrite and re-deliver
- Code analysis: core.rs:1167-1183 — Confirm uses `curr_view <= view` (≤) but Prepare uses `== view` (strict equality), asymmetric view checking
- Code analysis: core.rs:1303-1307 — Consensus instances inserted into map before validation

**Affected code paths**:
- `is_valid()` (core.rs:1108-1230) — all message validation
- `process_prepare_message()` (core.rs:1406-1466)
- `process_confirm_message()` (core.rs:1468-1496)
- `process_commit_message()` (core.rs:1517-1588)

**Suggested modeling approach**:
- Variables: `lastVoted [Server -> Slot -> {Prepare, Confirm}]` to track voting state
- Actions: Model each handler with the EXACT guards from the code (not the paper)
  - `ReceivePrepare` — no leader check, no committed-slot check
  - `ReceiveConfirm` — no duplicate guard
  - `ReceiveCommit` — no idempotency check
  - `ByzantineNodePrepare` — non-leader sends valid Prepare
- Key invariants: `ElectionSafety` (at most one committed value per slot), `NoDoubleVoting` (detect if missing guards cause honest nodes to effectively double-vote)

**Priority**: High
**Rationale**: The missing leader validation (FINDING 1) is especially severe — it means any Byzantine node can propose for any slot/view and get honest votes. Combined with Family 1 (equivocation), a Byzantine non-leader could form conflicting QCs.

---

### Family 4: Fast/Slow Path Interaction (MEDIUM)

**Mechanism**: The QCMaker state machine managing fast path (3f+1 unanimous) and slow path (2f+1) has complex flag interactions that can produce multiple QCs or lose track of completion state.

**Evidence**:
- Code analysis: aggregators.rs:128,138 — `self.weight = 0` resets allow threshold re-crossing
- Code analysis: aggregators.rs:153-162 — `get_qc()` can be called multiple times, creating multiple QCs
- Code analysis: aggregators.rs:143 — `qc_dig` uses last vote's digest, no check all votes agree
- Historical: commit `1953ece` — QCMaker `completed` flag mixed up fast/slow path
- Code analysis: core.rs:259 — WARNING about QC maker GC timing when votes are external

**Affected code paths**:
- `QCMaker` (aggregators.rs:84-163) — fast/slow path state machine
- `process_vote()` (core.rs:558-600) — feeds QCMaker
- `process_loopback()` (core.rs:1650-1680) — timer-triggered slow path fallback

**Suggested modeling approach**:
- Variables: `qcFormed [Server -> Slot -> {None, Fast, Slow}]`
- Actions: `FormFastQC` (all N votes), `FormSlowQC` (2f+1 votes + timer), `FastTimeout` (timer fires, fallback to slow)
- Check: Can both fast and slow QCs form for same slot with different content? Can a QC form after the slot is committed?

**Priority**: Medium
**Rationale**: 1 historical bug fix. The state machine is complex but mostly guarded by the single-threaded Core loop. The main risk is interaction between fast path timer and slow path fallback.

---

### Family 5: Slot Bounding & GC (MEDIUM)

**Mechanism**: The mechanism bounding concurrent consensus instances (k parameter) has had multiple bugs, and the GC logic for cleaning up committed slots has a retain-condition error.

**Evidence**:
- Historical: commit `46b612d` — Instance bounding inverted (contains → !contains)
- Code analysis: core.rs:1612-1617 — `clean_slot_periods()` retain condition uses `&&` that may prematurely delete future slot entries
- Code analysis: core.rs:118-120 — Comment: only checking slot s-k committed, not all predecessors, allows Byzantine nodes to open f extra instances
- Historical: commit `3baa668` — GC type mismatch `HashMap<Height>` vs `HashMap<Slot>`
- Code analysis: core.rs:100 — TODO: GC for open consensus instances not implemented

**Affected code paths**:
- `is_prepare_ticket_ready()` (core.rs:1036-1043) — slot bounding
- `clean_slot()` / `clean_slot_periods()` (core.rs:1590-1630) — GC
- `process_commit_message()` (core.rs:1543-1545) — committed_slots update

**Suggested modeling approach**:
- Variables: `committedSlots [Server -> SUBSET Slot]`, `openInstances [Server -> SUBSET Slot]`
- Actions: Model slot opening with k-bounding, commit with GC
- Key invariant: `BoundedInstances` — at most k+f open consensus instances at any time

**Priority**: Medium
**Rationale**: 2+ historical bugs. The GC retain condition bug could cause premature cleanup of active instances. However, the slot bounding mechanism itself is structurally sound once the inversion is fixed.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| 3-phase consensus (Prepare/Confirm/Commit) | Core protocol — all families depend on it | Actions per phase with exact code guards |
| Byzantine leader equivocation | Family 1: proposals not bound to votes | Allow Byzantine leader to present QCs with arbitrary proposals |
| View change (TC formation + winning proposal) | Family 2: 10+ historical bugs, view assignment error | Faithful model of `get_winning_proposals()` logic |
| Missing leader validation | Family 3: any node can propose | `ReceivePrepare` without leader check |
| Missing Confirm duplicate guard | Family 3: can double-vote for Confirm | Track voting state, allow re-voting |
| Fast path + slow path | Family 4: path interaction bugs | Both QC formation paths with timer fallback |
| Parallel slots (k=2) | Family 5: bounding bugs | 2-3 concurrent slots, prepare ticket chaining |
| Byzantine fault model (f=1, n=4) | BFT protocol requires adversary modeling | 1 Byzantine node that can equivocate, withhold, and replay |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| DAG data dissemination layer | Not related to any high-priority bug family. Abstract as "proposals reference lane tips" without modeling lane construction. |
| Ride-sharing (consensus in headers) | Implementation optimization, not protocol logic. Both paths reach the same handlers. |
| Network/TCP layer | Below protocol abstraction level. Model as async message delivery. |
| RocksDB persistence | No persistence bugs in top families (upstream #15 is separate). |
| Worker/batch processing | Transaction batching is below consensus abstraction. |
| Timer implementation | Abstract as non-deterministic timeout events. |
| Digest/hash computation | Code-level issue. Model the EFFECT (equivocation possible) not the mechanism (broken hash). |
| Channel backpressure | Runtime concern, not protocol logic. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Byzantine equivocation | (action, no new vars) | Model leader sending different proposals to different nodes | Family 1 |
| View change state | `highQC`, `highProp`, `views` | Track view change evidence per slot per server | Family 2 |
| Voting guards | `lastVotedPrepare`, `lastVotedConfirm` | Track what each server has voted for | Family 3 |
| Leader validation | (guard absence in action) | Model that Prepare receiver does NOT check sender == leader | Family 3 |
| Fast/slow QC tracking | `qcType` per slot | Distinguish fast QC (skip Confirm) from slow QC | Family 4 |
| Slot bounding | `openSlots`, `committedSlots` | Track concurrent instance count | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| AgreementSafety | Safety | No two honest nodes commit different proposal sets for the same slot | Family 1, 2, 3 |
| ViewChangeSafety | Safety | After TC, new Prepare preserves any possibly-committed proposals from previous views | Family 2 |
| NoDoubleVotePrepare | Safety | No honest node votes for two different Prepare messages in the same (slot, view) | Family 1, 3 |
| NoDoubleVoteConfirm | Safety | No honest node votes for two different Confirm messages in the same (slot, view) | Family 3 |
| FastPathCorrectness | Safety | If fast QC (3f+1) forms for proposals P, no conflicting Confirm QC can form | Family 4 |
| SlotBounding | Safety | Number of open consensus instances ≤ k + f at any time | Family 5 |
| CommitValidity | Safety | Any committed proposal set was actually proposed by a (possibly Byzantine) leader | Family 3 |
| LivenessUnderHonestLeader | Liveness | If leader is honest and network is synchronous, slot eventually commits | All |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| F1-A | Byzantine leader sends different proposals to different nodes; QC forms for ambiguous content | AgreementSafety | 1 |
| F2-A | View assignment bug (timeout.view vs other_view) causes wrong winning proposal in TC | ViewChangeSafety | 2 |
| F2-B | TC::verify() always succeeds (PartialEq=true); Byzantine node forges TC to force view change | ViewChangeSafety | 2 |
| F3-A | Non-leader sends Prepare, gets voted on, forms QC conflicting with real leader's QC | AgreementSafety | 1, 3 |
| F3-B | Confirm duplicate voting allows QCs for different proposals in same (slot, view) | NoDoubleVoteConfirm | 3 |
| F3-C | Voting on already-committed slot creates conflicting QC for new view | AgreementSafety | 3 |
| F4-A | Fast path QC and slow path QC form concurrently with different vote sets | FastPathCorrectness | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T1 | Non-deterministic intra-slot commit ordering (HashMap iteration) | Run 2 replicas, compare output order for same committed slot |
| T2 | `is_special` flag never reset in proposer (proposer.rs:141) | Unit test: send one consensus instance, verify subsequent headers aren't all `special=true` |
| T3 | `panic!()` in verify_commit (messages.rs:159) crashes node on mismatch | Fuzz test with malformed commit messages |
| T4 | Committer panics on missing ancestor (committer.rs:143) | Test with slow sync, verify graceful handling |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| C1 | QC::PartialEq always returns false (messages.rs:1288) | Fix: compare `id` and `view` fields |
| C2 | TC::PartialEq always returns true (messages.rs:1405) | Fix: compare `slot`, `view`, and timeout content |
| C3 | QC::digest() and Timeout::digest() hash nothing | Fix: include slot, view, and relevant fields |
| C4 | proposal_digest() uses HashMap iteration (non-deterministic) | Fix: sort by key before hashing |
| C5 | Leader election `keys.sort()` commented out (leader.rs:41) | Fix: uncomment (already safe due to BTreeMap, but fragile) |
| C6 | TC broadcast commented out (core.rs:1830-1847) | Review: was this intentionally disabled or unfinished? |

## 7. Reference Pointers

- **Paper**: `case-studies/autobahn/autobahn-sosp24.pdf` (Autobahn: Seamless high speed BFT, SOSP 2024)
- **Key source files**:
  - `artifact/autobahn-artifact/primary/src/core.rs` (2202 lines — protocol engine)
  - `artifact/autobahn-artifact/primary/src/messages.rs` (1589 lines — message types, verification)
  - `artifact/autobahn-artifact/primary/src/aggregators.rs` (211 lines — QC/TC formation)
  - `artifact/autobahn-artifact/primary/src/committer.rs` (307 lines — commit ordering)
  - `artifact/autobahn-artifact/primary/src/proposer.rs` (267 lines — header creation)
  - `artifact/autobahn-artifact/primary/src/leader.rs` (48 lines — leader election)
- **Upstream repo**: github.com/asonnino/hotstuff (base Narwhal framework)
- **Open upstream issues**: #7 (DoS), #15 (crash recovery), #44 (loopback spoofing)
- **Bug archaeology**: 68 fix commits on core.rs, 30+ on autobahn branch touching primary/src/
