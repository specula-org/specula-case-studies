# Modeling Brief: Autobahn BFT Consensus

**System**: Autobahn / Sailfish (research prototype based on Narwhal + HotStuff)  
**Language**: Rust  
**Core LOC**: ~8,000 (primary: 3,800 · sailfish: 2,700 · hotstuff: 1,500)  
**Analysis date**: 2026-06-04

---

## 1. System Overview

Autobahn is a BFT consensus prototype layering a 3-phase (Prepare–Confirm–Commit) single-leader protocol on top of a Narwhal-style DAG dissemination layer. The codebase ships three concrete implementations in separate crates:

- **`primary/`** — the Narwhal DAG layer plus the Autobahn 3-phase consensus embedded inside DAG headers via a "rideshare" mechanism. This is the most complete and active codebase.
- **`hotstuff/`** — a standalone HotStuff consensus implementation (2-chain Jolteon variant), usable without the DAG layer.
- **`sailfish/`** — a Sailfish overlay on top of the DAG; largely a work-in-progress with many critical paths commented out or stubbed.

**Category: A (Distributed / Message-Passing) — BFT**  
Safety / liveness arguments depend on tolerating ≤ f Byzantine nodes under partial synchrony; `n ≥ 3f+1`; authenticated with unforgeable honest signatures.

**Adversary model**: static Byzantine corruption, authenticated (unforgeable signatures), partial-synchronous network (post-GST), threshold `n ≥ 3f+1`.

**Concurrency model**: Tokio single-threaded event loop per node; all handlers are `async`. No shared mutable state across tasks; all inter-component communication via `tokio::sync::mpsc` channels.

**Key deviations from the reference algorithm**:
- Proposals are piggybacked ("rideshared") inside Narwhal DAG headers rather than sent as standalone messages.
- A k-pipeline allows up to k concurrent consensus slots.
- View-change uses a Timeout Certificate (TC) collecting f+1 or 2f+1 Timeout messages, each carrying a `high_qc` and `high_prop` for safety recovery.
- The codebase is in a prototype/WIP state: several critical paths in `sailfish/` are commented out.

---

## 2. Bug Families

### Family 1: Proposal-Binding Failure in Consensus Signatures

**Mechanism**: The cryptographic digest that replicas sign for Prepare, Confirm, and Commit messages does not commit to the `proposals` field. Voting signatures therefore do not bind to the payload, allowing equivocation at the proposal level.

**Evidence**:
- Code analysis: `primary/src/messages.rs:237–279` — `Hash for ConsensusMessage` explicitly excludes `proposals: _` from the digest for all three message types. FIXME comments at lines 128, 194, and 246 acknowledge this: `//hasher.update(proposal_digest(self)); FIXME: ADD THIS AND DEBUG`.
- Code analysis: `primary/src/messages.rs:121–207` — `verify_commit()` and `verify_confirm()` reconstruct the prepare_id/confirm_id without proposals; the TODO at line 174 states `FIXME: add proposal_digest to ConsensusMessage .digest`.
- Code analysis: `primary/src/core.rs:1448` — `process_prepare_message` signs the `consensus_message.digest()` and inserts into `last_voted_consensus` — a set keyed on `(slot, view)`, not on `(slot, view, proposals)`. A Byzantine leader sending two Prepare messages for the same `(slot, view)` with different proposals produces the same digest; honest replicas sign both without detecting the equivocation.

**Affected code paths**:  
`Hash for ConsensusMessage` · `verify_commit` · `verify_confirm` · `process_prepare_message` · `process_confirm_message`

**Suggested modeling approach**:
- Variables: `prepare_proposals[slot]` — the proposals content a replica has signed for each slot/view.
- Actions: split `CastPrepareVote` into a variant where the Byzantine leader equivocates (sends two `Prepare` messages for the same `(slot, view)` with different proposals). The spec should show that two distinct quorums of honest votes can be assembled for different proposal sets.
- Invariant to check: `AgreementOnProposals`: for any committed slot, all committed proposals are identical across honest replicas.

**Priority**: **High** — this breaks the foundational vote-binding requirement of BFT consensus and is explicitly acknowledged in FIXMEs.

---

### Family 2: View-Change Safety Rule Violations

**Mechanism**: Multiple defects in the view-change recovery path — the Timeout digest is empty (signatures cover nothing), the winning-proposal selection uses the wrong variable, and TC verification does not validate embedded QCs — collectively break the invariant that the new leader must re-propose the highest locked value.

**Evidence**:
- Code analysis: `primary/src/messages.rs:1349–1358` — `Hash for Timeout` hashes nothing (all `hasher.update` calls are commented out). Every timeout from any replica for any `(slot, view, high_qc, high_prop)` produces the same digest `SHA512("")`. Signatures are therefore interchangeable across all fields.
- Code analysis: `primary/src/messages.rs:1454–1455` — in `TC::get_winning_proposals`, the condition `if other_view > &winning_view` correctly compares the embedded ConfirmQC view, but then assigns `winning_view = timeout.view` (the timeout's view, which is a constant across all timeouts in the TC) rather than `winning_view = *other_view`. After the first ConfirmQC is found, `winning_view` equals the TC's view, so all subsequent comparisons fail and the winning proposal is whichever ConfirmQC happened to be first in iteration order — not the highest-view one.
- Code analysis: `primary/src/messages.rs:1518–1546` — `TC::verify()` calls only `timeout.verify()` for each timeout (which is meaningless per above) and never verifies the `high_qc` embedded inside each timeout. A TODO at line 1341 acknowledges: `"If it would be winning QC then you need to verify"`.
- Code analysis: `hotstuff/src/core.rs:391–397` — HotStuff's `handle_tc` does not call `tc.verify()` at all before calling `self.advance_round(tc.round)`. Every other handler verifies its message; this one does not.

**Affected code paths**:  
`Hash for Timeout` · `TC::get_winning_proposals` · `TC::verify` · `hotstuff::handle_tc`

**Suggested modeling approach**:
- Variables: `high_qc_reported[n]` — the QC each replica claims to hold in its timeout; `committed[slot]` — the proposals committed at each slot.
- Actions: a `SendTimeout` action where a Byzantine replica can choose any `high_qc`/`high_prop` value (since the Timeout digest binds to nothing); a `FormTC` action that picks the winning proposal per the `get_winning_proposals` algorithm.
- Invariant to check: `ViewChangeSafety`: the value proposed by the new leader after a TC is consistent with the highest value locked before the view change.

**Priority**: **High** — broken Timeout digest + wrong `winning_view` variable together make the view-change locking rule non-binding. This is the most likely source of a safety violation in an adversarial run.

---

### Family 3: Validator State Machine Inconsistency

**Mechanism**: The `is_valid` predicate for Prepare messages advances the node's view as a side-effect before confirming all validity conditions, and there is no equivocation guard on Confirm votes, creating inconsistent safety rule enforcement across the Prepare/Confirm/Commit path.

**Evidence**:
- Code analysis: `primary/src/core.rs:1158–1165` — `is_valid` for Prepare writes `self.views.insert(*slot, *view)` at line 1160 unconditionally when `curr_view < view`, before checking `ticket_valid`. If `ticket_valid` later fails (invalid QC ticket), the node has already advanced its view for this slot. A Byzantine Prepare with `view = V+1` and an invalid ticket causes the node to reject future valid `Prepare(slot, V)` messages (which now appear to be for a stale view), stalling the slot.
- Code analysis: `primary/src/core.rs:1167–1183` — `is_valid` for Confirm checks `curr_view <= view` and immediately calls `self.views.insert(*slot, *view)` and `return true` inside the if-block. Unlike Prepare (line 1165), there is no `!self.last_voted_consensus.contains(&(*slot, *view))` guard. A node can cast a Confirm vote for the same `(slot, view)` multiple times upon receiving re-sent or replayed Confirm messages.
- Code analysis: `primary/src/core.rs:1302–1315` — `process_consensus_request` inserts a Prepare/Confirm message into `self.consensus_instances` before calling `is_valid`. An invalid or Byzantine message leaves a corrupt entry that subsequent votes will match against.

**Affected code paths**:  
`is_valid` (Prepare branch) · `is_valid` (Confirm branch) · `process_consensus_request`

**Suggested modeling approach**:
- Variables: `voted_confirm[slot][view]` — tracks whether a replica has already cast a Confirm vote for `(slot, view)`.
- Actions: split `CastConfirmVote` to show paths with and without the equivocation guard.
- Invariant to check: `NoConfirmEquivocation`: an honest replica votes Confirm at most once per `(slot, view)`.

**Priority**: **Medium-High** — the Confirm equivocation gap directly weakens the 3-phase protocol; the `is_valid` side-effect can stall individual consensus slots.

---

### Family 4: Incomplete 2-Chain Commit Rule (HotStuff)

**Mechanism**: HotStuff's `process_block` checks only one of the two consecutive-round conditions required for the 2-chain commit rule, allowing premature commitment.

**Evidence**:
- Code analysis: `hotstuff/src/core.rs:327` — the commit check reads `if b0.round + 1 == b1.round { self.commit(b0).await?; }`. The Jolteon/2-chain rule requires both `b0.round + 1 == b1.round` **and** `b1.round + 1 == block.round`. Only the `b0→b1` link is tested. If `block` has a QC for `b1` but `b1.round + 1 ≠ block.round` (possible after a view change opens a round gap), `b0` is committed prematurely.
- Code analysis: `hotstuff/src/core.rs:118` — `TODO [issue #15]: Write to storage preferred_round and last_voted_round`. Neither `last_voted_round` nor `high_qc` is persisted. A restarted node resets both to 0/genesis and may vote in rounds it already voted in, violating the one-vote-per-round safety invariant.

**Affected code paths**:  
`hotstuff::process_block` · `hotstuff::make_vote` (persistence gap)

**Suggested modeling approach**:
- Variables: `last_voted_round[n]` (both in-memory and durable), `high_qc[n]`.
- Actions: separate `CrashRecover` action that resets in-memory state but preserves only the durable store. Check that nodes never vote below `last_voted_round` even after crash.
- Invariants: `TwoChainCommitRule`: a block is committed only when both consecutive-round links hold; `VoteSafety`: no node casts a vote for a round ≤ its last-voted round.

**Priority**: **Medium** — the incomplete 2-chain check is a genuine protocol deviation; the persistence gap is acknowledged and known but also a clear safety regression under crashes.

---

### Family 5: GC Lifecycle Bugs (Pipeline and Memory)

**Mechanism**: The garbage-collection predicate for the k-pipeline is logically inverted, dropping active future-slot consensus instances rather than old ones, disrupting pipelined progress.

**Evidence**:
- Code analysis: `primary/src/core.rs:1612–1617` — `clean_slot_periods` uses `retain(|(s, _), _| s % k != slot_period && s <= &slot)`. The intended GC condition is "drop entries in the same lane at or before the committed slot" — i.e., drop where `s % k == slot_period && s <= slot`. The correct retain predicate is the negation: `s % k != slot_period || s > &slot`. The actual predicate is `s % k != slot_period && s <= &slot` — the De Morgan complement — which instead drops all entries at future slots (`s > slot`) in any lane, purging active consensus instances for slots that haven't committed yet.
- Code analysis: `primary/src/core.rs:98, 1448, 2189` — `last_voted_consensus: HashSet<(Slot, View)>` is never GC'd. In long-running sessions this grows without bound. A comment at line 1614 says `//self.committed_slots GC those that are older.` but no code implements it.

**Affected code paths**:  
`clean_slot_periods` · `process_commit_message` (GC call site)

**Suggested modeling approach**:
- This is primarily test-verifiable: write an integration test that commits slot S and checks that consensus instances for slot S+k still exist.
- For TLA+: model the k-pipeline with `active_slots` as a set; verify `GCPreservesActive`: after committing slot S, all instances for slots S+k are still present.

**Priority**: **Medium** — the inverted GC will silence-fail in pipelined operation. The impact is bounded by the pipeline depth k but will manifest in every commit.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Proposal content as part of vote digest | Family 1: votes do not bind to proposals; MC can confirm equivocation attack | Add `proposals` to `PrepareVote.digest` variable; Byzantine equivocate action |
| View-change winning-proposal selection | Family 2: `winning_view` bug allows wrong proposal to win TC | Model `TC.get_winning_proposals` as a function in TLA+; MC checks `ViewChangeSafety` |
| Timeout authentication (Timeout.digest) | Family 2: empty digest makes Timeout signatures meaningless | Model Timeout as carrying an authenticated `(slot, view, high_qc)` tuple; Byzantine action = arbitrary `high_qc` |
| Confirm vote equivocation guard | Family 3: no `last_voted_consensus` check for Confirm | Track `confirmVoted[node][slot][view]` as a boolean; invariant `NoConfirmEquivocation` |
| Two-chain commit rule (HotStuff) | Family 4: missing second link check | Model both `b0→b1→block` links; `TwoChainCommitRule` invariant |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| `sailfish/` commented-out code paths | The aggregator, committer, and synchronizer in `sailfish/` are stubs; modeling them would target code that is not live. Flag for code review once re-enabled. |
| `last_voted_consensus` memory leak | Implementation defect, not a protocol safety issue. Test-verifiable. |
| Certificate parent signature bypass (`primary/src/core.rs:317–335`) | The check uses `validity_threshold` (f+1) for a header-embedded cert rather than calling `certificate.verify()`. Important but best caught by code review + targeted test since the fix is a one-line call, not a protocol deviation. |
| `is_valid` side-effect view advance (Family 3, `is_valid` Prepare) | The behavior is subtle and depends on the specific Byzantine Prepare sequence. Better confirmed by integration test that sends an invalid Prepare before a valid one in the same slot. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| `ProposalDigestBinding` | `voteDigest[node][slot][view]`, `proposalContent[slot][view]` | Model that vote digests bind to proposal content; Byzantine equivocation action sends two Prepare with same digest | Family 1 |
| `TimeoutAuthentication` | `timeoutHighQC[node][slot][view]`, `isByzTimeout[msg]` | Model Byzantine timeout with arbitrary `high_qc` field; check view-change picks highest honest QC | Family 2 |
| `TCWinningSelection` | `winningView[slot]`, `winningProposals[slot]` | Encode `get_winning_proposals` logic exactly; MC checks agreement on winning proposals | Family 2 |
| `ConfirmEquivocationGuard` | `confirmVoted[node][slot][view]` | Track per-node Confirm vote history; safety invariant = voted at most once | Family 3 |
| `TwoChainRule` | `chainAncestors[block]`, `roundGaps[block]` | Model both consecutive-round conditions for 2-chain commit; inject round-gap blocks | Family 4 |
| `CrashRecovery` | `durable[node]` (voted_round, high_qc), `crashed[node]` | Separate durable vs. in-memory state; crash action clears in-memory, restores durable | Family 4 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `AgreementOnProposals` | Safety | No two honest nodes commit different proposals for the same slot | Family 1 |
| `ViewChangeSafety` | Safety | The winning proposal after any TC is consistent with the highest value locked before the view change | Family 2 |
| `TimeoutAuthenticityBound` | Safety | A Byzantine node cannot cause honest nodes to adopt a `winning_proposal` that no honest node had locked | Family 2 |
| `NoConfirmEquivocation` | Safety | An honest node casts at most one Confirm vote per `(slot, view)` | Family 3 |
| `TwoChainCommitRule` | Safety | A block is committed only when the full 2-chain (both consecutive-round links) is present | Family 4 |
| `VoteSafety` | Safety | No honest node votes in round ≤ its `last_voted_round` (including after crash-recovery) | Family 4 |
| `GCPreservesActive` | Liveness | After committing slot S, all consensus instances for slots S+k remain in the active map | Family 5 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | Can a Byzantine leader equivocate at the Prepare phase (same `slot/view`, different proposals) and assemble two valid PrepareQCs? | `AgreementOnProposals` violated | Family 1 |
| MC2 | Does the `winning_view = timeout.view` assignment in `get_winning_proposals` allow the new-view leader to propose a stale (lower-view) value instead of the highest locked value? | `ViewChangeSafety` violated | Family 2 |
| MC3 | Can a Byzantine node send a Timeout with arbitrary `high_qc` (empty digest makes signature reusable) and steer the new-view leader's proposal? | `TimeoutAuthenticityBound` violated | Family 2 |
| MC4 | Can an honest node cast two Confirm votes for the same `(slot, view)` (missing `last_voted_consensus` guard), enabling a Byzantine aggregator to form two conflicting ConfirmQCs? | `NoConfirmEquivocation` violated | Family 3 |
| MC5 | Does the missing second link check (`b1.round + 1 == block.round`) in HotStuff's `process_block` allow a block to be committed when the 2-chain is not fully consecutive? | `TwoChainCommitRule` violated | Family 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV1 | `clean_slot_periods` GC drops active future slots | Integration test: commit slot S in a k=2 pipeline; assert consensus instances for slot S+2 still exist |
| TV2 | Certificate parent not verified via `certificate.verify()` | Unit test: send a header with forged `parent_cert` signatures; assert it is rejected |
| TV3 | `is_valid` for Prepare advances view before checking `ticket_valid` | Unit test: send invalid Prepare with `view=2` for slot S; then send valid `Prepare(slot=S, view=1)`; assert the valid one is not rejected |
| TV4 | `last_voted_consensus` never GC'd — confirm memory growth | Stress test: commit 1000 slots; measure `last_voted_consensus.len()` |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `process_consensus_request` inserts into `consensus_instances` before verification; an invalid remote message leaves a corrupt entry | Move `verify()` and `is_valid()` before the `insert()` call |
| CR2 | `primary/src/core.rs:317–335`: parent certificate quorum checked with `validity_threshold()` (f+1) but `certificate.verify()` is never called on the embedded `parent_cert` | Call `header.parent_cert.verify(&self.committee)?` before the stake count check |
| CR3 | `enough_coverage` at `primary/src/core.rs:1511` and `sailfish/src/core.rs:520` panics on `.unwrap()` if a committee member is absent from `prepare_proposals`; Byzantine Prepare can crash the node | Replace `.unwrap()` with `.unwrap_or_default()` or an explicit error path |
| CR4 | `verify_commit` at `messages.rs:159` contains `panic!("ids don't match")` before an unreachable `return false` — panics are denial-of-service for any moderately malformed message | Replace `panic!` with `return false` |
| CR5 | `get_prev_special_header` in `sailfish/src/synchronizer.rs:384–388` panics instead of initiating sync; restart scenario crashes the node | Implement the sync waiter instead of `panic!` |
| CR6 | `TC::PartialEq` always returns `true` (`messages.rs:1408`) — any two TCs compare equal; affects deduplication logic | Implement proper equality check |
| CR7 | `hotstuff/src/core.rs:118` TODO: `last_voted_round` and `high_qc` not written to storage (acknowledged as issue #15) | Implement durable write before returning `Some(Vote)` in `make_vote` |

---

## 7. Reference Pointers

**Source files (primary targets)**:
- `primary/src/messages.rs` (1589 lines) — ConsensusMessage, QC, TC, Timeout digest/verify
- `primary/src/core.rs` (2202 lines) — `is_valid`, `process_consensus_request`, `clean_slot_periods`
- `hotstuff/src/core.rs` (430 lines) — `handle_tc`, `process_block`, `make_vote`
- `sailfish/src/aggregator.rs` (194 lines) — TC formation (commented out)
- `sailfish/src/synchronizer.rs` (604 lines) — `get_prev_special_header`

**Key line anchors**:
- Family 1 (proposal binding): `messages.rs:237–280`, `messages.rs:121–207`
- Family 2 (view-change): `messages.rs:1349–1358`, `messages.rs:1454–1455`, `messages.rs:1518–1546`, `hotstuff/core.rs:391–397`
- Family 3 (state machine): `primary/core.rs:1158–1165`, `primary/core.rs:1167–1183`, `primary/core.rs:1302–1315`
- Family 4 (2-chain / crash): `hotstuff/core.rs:327`, `hotstuff/core.rs:118`
- Family 5 (GC): `primary/core.rs:1612–1617`

**GitHub**: Repository not publicly accessible under `asonnino/autobahn` — no issue/PR history was available for bug archaeology. Analysis is based entirely on code reading.

**Reference algorithm**: Autobahn BFT (Spiegelman et al.) / Jolteon (2-chain HotStuff variant) / Narwhal DAG mempool (Danezis et al.).
