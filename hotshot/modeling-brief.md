# Modeling Brief: HotShot (Espresso Network)

## 1. System Overview

- **System**: `EspressoSystems/espresso-network`, the HotShot BFT consensus library used as Espresso's shared decentralized sequencer (Caldera and other rollups). Default branch `main`, HEAD `3038613` (2026-05-15).
- **Language**: Rust. **Core in-scope LOC**: ~12,000 (`crates/hotshot/{task-impls,types}`).
- **System category**: **Category A (Distributed / Message-Passing)**, BFT threat model with stake-weighted permissionless membership and epoch transitions. *Justification*: safety/liveness arguments rest on tolerating ≤ f Byzantine stake share via threshold-signed QCs / TCs / view-sync certs across asynchronous message passing; persistence + crash-recovery are present but not the dominant failure mode.
- **Reference algorithm**: HotStuff-2 (Malkhi-Nayak 2023) with two extensions: (a) Naor-Keidar view-sync pacemaker, (b) DRB-driven leader rotation one epoch in advance.
- **Key deviations from the paper**:
  - **Dual QC at epoch boundaries** (PR #3922): last block of an epoch requires a `QuorumCertificate2` (current epoch's stake) + `NextEpochQuorumCertificate2` (next epoch's stake) over the *same leaf*.
  - **Extended QC (eQC)** broadcast (PR #3851): eQC vote is broadcast, not unicast; "epoch safety check" gates cross-epoch chaining on same-epoch-OR-eQC predicate.
  - **View-sync pacemaker** with per-relay rotation, layered on top of HS2 timeout cert.
- **Concurrency model**: Each "task" is an async actor consuming `HotShotEvent` from a broadcast channel. Shared safety state in `Arc<RwLock<Consensus<TYPES>>>`. Per-view dependency tasks run on independent spawns. In-memory and persistent updates are **not** transactional.

## 2. Bug Families

### Family A: Timeout / view-sync cert epoch binding (HIGH)

**Mechanism**: `TimeoutData2.commit()` deliberately strips the epoch field from the digest (`simple_vote.rs:460-468`: `let TimeoutData2 { view, epoch: _ } = self;`). The verifier (`helpers.rs:1137`) looks up the stake table from the certificate's self-declared epoch (`timeout_cert.data().epoch()`). The signed digest is therefore byte-identical across epochs, so a TC formed in epoch *E* can be re-tagged `.data.epoch = E'` and replayed against the verifier's lookup of *E*'s table whenever the signers' BLS keys remain present.

**Evidence**:
- Historical: PR #2829 (2025-03-24) — "Fix QC Inconsistencies between epochs"; PR #3922 (2024-12-18) — double-quorum design; #3918 (open) — `is_valid_cert` membership binding.
- Code analysis: `simple_vote.rs:460-468` (epoch stripped); `helpers.rs:1137-1148` (verifier uses cert-declared epoch); `simple_vote.rs:389-396` (`VersionedVoteData::commit` does not re-add epoch).
- Contrast: `QuorumData2.commit()` (`simple_vote.rs:406-427`) DOES include the epoch; QC value-binding is sound.

**Affected code paths**: `validate_proposal_view_and_certs` TC arm (`helpers.rs:1131-1153`); also VSC arm (`helpers.rs:1154-1177`) for `validate_qc_and_next_epoch_qc` (`helpers.rs:1218-1259`). VSC digest includes epoch (`simple_vote.rs:582-592` via `view_and_relay_commit`), so VSC is sound; the lookup-from-self-declared-epoch is still a softer "wrong table" surface.

**Suggested modeling approach**:
- Variables: `timeoutCerts ⊆ [view ↦ TC]`, but TC payload only `(view, signerSet)` — no epoch in the signed-data abstraction.
- Actions: split `ValidateTimeoutCert` into `(a) check signature against stake table of cert.data.epoch` and `(b) check that cert's view matches`. Add a Byzantine action `ReplayTcAcrossEpoch(view, fromEpoch, toEpoch)` that produces `TC{view, epoch=toEpoch, sigs=originalSigs}`.
- Granularity: keep view + cert-claimed-epoch as a 2-tuple; let TLC explore whether re-tagging passes verification.

**Priority**: High
**Rationale**: Forward-looking question, not a closed-PR reproduction. The signed-digest strip is *current code on `main`*; the verifier-side stake-table lookup is also current code. No PR has been opened to fix this. Crosses two of the named bug-family hypotheses (TC integrity + locked-view bypass).

---

### Family B: Equivocation invisibility & locked-view monotonicity holes (HIGH)

**Mechanism**: Three persistent-state mutators silently drop conflicting input as `debug!` log lines:
- `update_high_qc` (`consensus.rs:1325-1338`): same view + different leaf → silently rejected, no equivocation flag.
- `update_locked_view` (`consensus.rs:1205-1212`): monotonic only; caller often discards `Result` with `let _ = ...` (handlers.rs:185-187).
- `update_validated_state_map` (`consensus.rs:1266-1298`): same view + Some(delta) on both new and old → overwrites; `update_saved_leaves` just inserts the new leaf alongside.
Additionally, `submit_vote` (`quorum_vote/handlers.rs:432-568`) never calls `consensus.update_action(HotShotAction::Vote, view)` or persists "I voted for view V". The in-memory `latest_voted_view` (`quorum_vote/mod.rs:447`) is bumped only on `ViewChange`, not on vote-cast, and is never written to storage. After a crash between sign-and-broadcast, the node can re-vote for the same view on a different proposal.

**Evidence**:
- Historical: PR #3971 (closed unmerged, 2024-12-21) — proposed fix rejected; the TODO at `consensus.rs:1147` ("the simple check ... doesn't work because leader of view n+1 may propose to DA before leader of view n") is still present. Maintainer bfish713 articulated the desired (unenforced) properties.
- Code analysis: `consensus.rs:1325`, `consensus.rs:1205`, `consensus.rs:1266`, `quorum_vote/handlers.rs:432-568`, `quorum_vote/mod.rs:811-815`.

**Affected code paths**: any caller of `update_*` on `Consensus`. Especially `validate_proposal_safety_and_liveness` (helpers.rs:925), `validate_proposal_liveness` (quorum_proposal_recv/handlers.rs:88), `handle_quorum_proposal_validated` (quorum_vote/handlers.rs), `submit_vote`.

**Suggested modeling approach**:
- Variables: split `lockedView[node]` (in-memory) from `persistedVotedView[node]` (persistent). Add `equivocationEvidence ⊆ [view ↦ Set<(QC1, QC2)>]` to record observable double-QCs that the implementation drops.
- Actions: `Crash(node)` resets `lockedView` and `latestVotedView` *but not* `high_qc` or `votedView` if persisted. Currently no path persists `votedView`, so crash recovery loses it.
- Add `HandleEquivocatingHighQC(node, qc1, qc2)` whose only effect is to drop the second (matching current code); invariant `NoUnseenEquivocation` should be checked, expected to fail under any 2f+1 Byzantine.
- Add `Byzantine_DoubleVote(node, view, leaf1, leaf2)` that signs two votes for the same view after a simulated crash.

**Priority**: High
**Rationale**: Unfixed (PR #3971 closed unmerged). Locked-view advancement on liveness alone is HotStuff-2-paper-correct, but composed with non-durable vote-cast and silent-drop equivocation it creates a class of behaviors where slashing evidence is invisible. Forward-looking modeling question: under crash-recovery + Byzantine vote-set, can a node sign two votes for the same view that aggregate into two distinct same-view QCs?

---

### Family C: View-sync parallel-relay non-determinism (HIGH)

**Mechanism**: View-sync uses three per-relay accumulators (`pre_commit_relay_map`, `commit_relay_map`, `finalize_relay_map`) keyed by `(epoch, view, relay)` (`view_sync.rs:91-101`). Multiple relay accumulators for the *same* `(epoch, view)` run concurrently; each can independently reach the success threshold and emit a valid `ViewSyncFinalizeCertificate2`. Replicas accept whichever cert arrives first (`view_sync.rs:840-890`), without cross-checking that `certificate.data().relay >= self.relay` or that a prior PreCommit/Commit cert from the same relay was observed. The proposal task uses `ViewSyncFinalizeCertificateRecv` to spawn a dependency task at `view_number = certificate.view_number` (`quorum_proposal/mod.rs:608-644`). The replica's local relay number is *opportunistically* lifted (`view_sync.rs:660`: `if certificate.data().relay > self.relay { self.relay = ...; }`), but its outgoing Commit vote is signed over `certificate.data().relay`, not `self.relay`, which means a late-arriving lower-relay PreCommit can still make the replica vote in a *different relay race* for the same view.

**Evidence**:
- Historical: PR #2921 (2025-04-04) — "Epochs for all view sync tasks"; PR #3544 (2025-08-26) — "GC view-sync tasks on decide"; PR #3596 (2025-10-29) — "View-sync byzantine tests" (testing split-view-sync across epochs). These confirm the mechanism is bug-prone and tested.
- Code analysis: `view_sync.rs:91-101` (independent maps); `view_sync.rs:441-493` (no relay-monotonicity guard on accumulator creation); `view_sync.rs:647-736` (replica accepts any-relay PreCommit cert and votes over cert's relay number).

**Affected code paths**: `ViewSyncTaskState::handle` dispatch (`view_sync.rs:135-630`); `ViewSyncReplicaTaskState::handle` (`view_sync.rs:647-890`); proposal-side consumption (`quorum_proposal/mod.rs:608-644`).

**Suggested modeling approach**:
- Variables: `relayAccumulators[(epoch, view, relay)] ⊆ Set<viewSyncVote>`; `viewSyncCerts ⊆ Set<{view, relay, epoch, sigs}>`.
- Actions: allow multiple relays to threshold-pass for the same view → emit multiple finalize certs. Add `Byzantine_RotateRelay(view, fromRelay, toRelay)` if a Byzantine replica's "timeout" can cause unnecessary rotation.
- Invariants: `UniqueFinalizeCertPerView` (expected to fail); `LeaderProposalConsistencyAcrossViewSync` — if two distinct finalize certs for view V drive two replicas into view V, both must derive the same parent QC.
- Granularity: keep relay number as a free variable; do NOT collapse to "single view-sync per view".

**Priority**: High
**Rationale**: Independent concrete code structure with multiple PRs in the area (#2921, #3544, #3596). The proposal-parent-selection asymmetry between `wait_for_transition_qc` and `wait_for_highest_qc` (§ 3.9 in analysis report) combines with this family to produce divergent leader choices under network reorder.

---

### Family D: Non-atomic in-memory ↔ persistent updates (MEDIUM)

**Mechanism**: Multiple code paths mutate in-memory `Consensus` state and await a separate `storage.*` call without transactional bracketing. The three concrete sites:
- `handle_eqc_formed` (`quorum_proposal/handlers.rs:899-922`): in-memory `update_high_qc` + `update_next_epoch_high_qc` run under one write lock, lock is dropped, then `storage.update_eqc` is awaited. `ExtendedQc2Formed` is broadcast unconditionally.
- `update_high_qc` flow in helpers.rs:773-836: storage writes (`update_high_qc2`, `update_next_epoch_high_qc2`) run BEFORE the in-memory monotonicity check at L820-834. A storage write may persist that the in-memory check would have refused.
- `validate_proposal_liveness` (`quorum_proposal_recv/handlers.rs:88-135`): calls `consensus_writer.update_leaf(...)` at L114 BEFORE deciding whether the proposal will be accepted (L131). Polluted leaves persist in `saved_leaves` even if the proposal is rejected.
- `update_high_qc` is **skipped entirely** in storage when `in_transition_epoch == true` (helpers.rs:761-773): only in-memory advances.

**Evidence**:
- Historical: PR #2897 (2025-04-02) — "Proposal Task Doesn't store High QC it just Formed" (race between self-storing and self-validating). PR #1442, #1926, #2221, #2160, #3279 — all restart/persistence-vs-in-memory bug fixes.
- Code analysis: cited file:line above.

**Affected code paths**: `handle_eqc_formed`, `update_high_qc` (the helper, not the struct method), `validate_proposal_liveness`, `fetch_proposal` (helpers.rs:54-147; accepts leaves by commit-equality without re-checking proposal leader signature).

**Suggested modeling approach**:
- Variables: split `consensusInMem[node] = (highQc, lockedView, savedLeaves)` from `consensusPersisted[node] = (highQc, lockedView)` (note: vote-cast is **not** in the persisted set under current code — see Family B).
- Actions: split `UpdateHighQC` into `UpdateHighQCInMem` then `UpdateHighQCPersist`. Add `Crash(node)` that discards in-memory state. Demand that recovery from persistent state still satisfies safety invariants.
- For `fetch_proposal`: keep the leaf-commitment-binding modeling, but track that `commit()` excludes `block_payload` (data.rs:1735 `block_payload: _`) — modeling can rely on header commitments rather than payload.

**Priority**: Medium
**Rationale**: Classic distributed-systems TLA+ strength. Multiple historical PRs confirm bug-proneness, but the specific code paths above are not all directly reproductions of fixed bugs — they are unaudited compositions.

---

### Family E: Cross-epoch-binding gaps in proposal validation (MEDIUM)

**Mechanism**: `validate_proposal_view_and_certs` uses `validation_info.membership` derived from the *proposal's own self-declared* block-number/epoch (`quorum_proposal_recv/mod.rs:163-178`). The leader-of-view check thus runs against the proposal-declared epoch, not the "true current" epoch. `validate_current_epoch` (`quorum_proposal_recv/handlers.rs:172-218`) only checks `epoch_from_block_number(block_number) >= epoch_from_block_number(high_block_number + 1)` — a one-sided guard. Combined with the cert-self-declared-epoch lookup (Family A and `validate_qc_and_next_epoch_qc` at helpers.rs:1228), the proposal's epoch claim drives every downstream verification call.

`validate_proposal_liveness` is reached when `parent_leaf` is missing from `saved_leaves`. It accepts the proposal under the disjunction `liveness_check OR valid_epoch_transition` (handlers.rs:131). The `valid_epoch_transition` branch is gated on `is_epoch_transition(justify_qc.block_number, epoch_height)` — attacker-controlled if the attacker can produce a transition-block-shaped justify QC.

**Evidence**:
- Code analysis: `quorum_proposal_recv/handlers.rs:88-135`, `helpers.rs:1100-1199`, `helpers.rs:1218-1259`, `quorum_proposal/mod.rs:608-644`.
- Open: #3918 (`is_valid_cert` membership binding still not refactored to take `Membership` directly).
- Open draft: #3962 ("Wait for Catchup in Proposal Path") — confirms proposal pipeline ↔ membership-catchup race is unhandled.

**Affected code paths**: `validate_proposal_view_and_certs`, `validate_qc_and_next_epoch_qc`, `validate_proposal_liveness`, `validate_current_epoch`, `validate_epoch_transition_qc`.

**Suggested modeling approach**:
- Variables: `proposalDeclaredEpoch[proposal]`, distinct from `consensusEpoch[node]`. Maintain `realEpoch[view]` as the deterministic function of view-history.
- Actions: a Byzantine leader proposes with mis-declared epoch; downstream check the predicate runs against the *declared* epoch's stake table.
- Invariant: `EpochClaimMatchesView` — proposal's `epoch_from_block_number(block_number)` must equal `realEpoch[view]`.

**Priority**: Medium
**Rationale**: Forward-looking question that crosses Family A. The composition "TC with stripped epoch" + "proposal validator that trusts the cert's self-declared epoch" is the genuine open mechanism question.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| TC digest semantics: signature over (view) only, with cert-declared epoch trusted for stake-table lookup | Family A — current code on `main`, no PR fix | `TimeoutCert ≜ [view, epoch_claim, signers]`; `ValidateTC(tc, atEpoch)` looks up stake table by `tc.epoch_claim`; checks `signers ⊆ stakeTable(tc.epoch_claim)`. Byzantine action `ReplayTcAcrossEpoch`. |
| Equivocation visibility for QCs | Family B — `update_high_qc` silently drops same-view conflicts | Track `qcWitnessed[node, view] ⊆ Set<QC>`. Invariant `Observable_Equivocation_Implies_Evidence` (expected to fail per current code). |
| Non-durable vote-cast & crash-replay | Family B + PR #3971 unfixed | `latestVotedView[node]` is in-memory only; `Crash(node)` resets it. Byzantine action `DoubleVoteAfterCrash`. |
| Parallel view-sync relays | Family C | `viewSyncFinalizeCerts[view] ⊆ Set<{view, relay, epoch, signers}>`; allow multiple relays to threshold-pass concurrently. Invariant `UniqueFinalizeCertPerView` (expected to fail). |
| Non-atomic in-memory vs persistent for high_qc | Family D | Split `highQcInMem[node]` from `highQcPersisted[node]`; `Crash(node)` loses in-mem; recovery starts from persisted. |
| Proposal-declared epoch vs real epoch | Family E | `realEpoch[v]` deterministic function; `Byzantine_ProposeWithMisdeclaredEpoch`. |
| Locked-view advancement on liveness rule (HS2 paper) | Family B context, Family E composition | Update `lockedView[node]` to `justify_qc.view` whenever `justify_qc.view > lockedView[node]` and the proposal is accepted on liveness alone — match the code. |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Light-client SNARK / L1 contract verification | Out-of-scope per case-study scoping. |
| Tiramisu DA layer, VID share distribution | Out-of-scope per case-study scoping. |
| Libp2p / gossip transport (`crates/cliquenet`) | Out-of-scope per case-study scoping. |
| Builder-exchange / MEV | Out-of-scope per case-study scoping. |
| DRB cryptographic computation | Model only as an opaque function; correctness of the DRB *construction* is its own subsystem. |
| Reproducing PR #3900 (extended voting wrong-branch) | Already fixed; reproduction adds no info beyond the PR. Demoted to § 7 Reference Pointers. |
| Reproducing PR #3922 (dual-quorum design) | Already merged + designed-in. Model the *current* code's binding, not the pre-fix state. |
| Reproducing PR #2829 (block_number in QC) | Already fixed. |
| Reproducing PR #2204 (timeout task cancellation) | Already fixed in 2023. |
| Reproducing PR #2897 (proposal-task-stores-its-own-high_qc race) | Already fixed for self-proposing; the structural asymmetry (Family D) is what we model instead. |
| Verifying HotStuff-2 LeaderCompleteness as-stated-in-paper | If the spec is a faithful HS2 encoding, this is paper-textbook and adds no information. Only meaningful if composed with Family A or B Byzantine wrappers. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| TC epoch-strip semantics | `TC = [view, epochClaim, signers]`, signed only over `view` | Capture that TC sigs reuse across epochs | A |
| Cert-self-declared epoch lookup | `ValidateCert(cert, stakeTableSource)` where source = `stakeTable(cert.epochClaim)` | Capture the verifier's choice of table | A, E |
| QC equivocation pool | `qcWitnessed[node, view] ⊆ Set<QC>` | Capture observable double-QCs that the code drops | B |
| In-mem vs persistent split | `highQcInMem[node]`, `highQcPersisted[node]`, `lockedViewInMem[node]`, `lockedViewPersisted[node]`, `latestVotedView[node]` (in-mem only) | Model crash recovery | B, D |
| Parallel relay accumulators | `relayPool[(epoch, view, relay)] ⊆ Set<vote>`; `finalizeCerts[view] ⊆ Set<{relay, signers}>` | Model multiple finalize certs per view | C |
| Proposal-declared vs real epoch | `proposalEpochClaim[proposal]`, `realEpoch[view]` | Model misdeclared-epoch proposals | E |
| Saved-leaf pollution via liveness-rejected proposals | `savedLeaves[node] ⊆ Set<Leaf>` even for proposals that fail `liveness_check && !valid_epoch_transition` … actually, code does insert before deciding | Capture polluted-leaf state | D |
| Locked-view advancement on liveness rule | `lockedView[node]` updated to `justify_qc.view` whenever liveness check passes | Match current HS2 code | B context |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety_HS2 | Safety | At most one leaf is committed per view (HS2 textbook). | Standard. |
| LockedViewMonotonic | Safety | `lockedView[node]` is non-decreasing under correct operation; crash recovery may reset it. | B (expected: violated under crash + double-vote action). |
| HighQCMonotonic_InMem | Safety | `highQcInMem.view` is non-decreasing. | B. |
| HighQC_PersistedConsistent | Safety | After crash-recovery, `highQcInMem == highQcPersisted` initially. | D. |
| NoEpochReplayedTC | Safety | If TC with `epochClaim = E'` verifies against stake table E', then either signers actually signed for E' or epochs E and E' share signers' keys identically — TLC should explore the negation. | A. |
| UniqueFinalizeCertPerView | Safety (expected to fail) | For each view, at most one `viewSyncFinalizeCert` exists. | C. |
| FinalizeCertImpliesCommitCert | Safety | A `ViewSyncFinalizeCert` at relay r exists ⇒ a `ViewSyncCommitCert` at relay r exists. | C (relay binding). |
| ProposalEpochMatchesView | Safety | `proposal.epochClaim == realEpoch[proposal.view]`. | E. |
| NoEquivocationGoesUnflagged | Liveness (Accountability) | If two distinct threshold-signed QCs for the same view exist, the implementation surfaces equivocation evidence. Expected to fail under current code. | B. |
| LockedViewBelowOrEqualHighQC | Safety | `lockedView ≤ highQc.view`. | B (composition). |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

Each entry is a forward-looking question, not a "reproduce closed PR" target.

| ID | Description | Expected invariant violation | Family |
|----|-------------|------------------------------|--------|
| MC1 | Can a Byzantine validator collect TimeoutVote2 signatures in epoch E, retag the cert `.data.epoch = E'`, and have it verify against the verifier's lookup of E's stake table — using the cert-declared epoch path? Combine with a partial-membership-overlap stake-table model. | `NoEpochReplayedTC` | A |
| MC2 | Under crash recovery (which loses in-memory `latest_voted_view` but retains persisted `high_qc`), can a Byzantine validator sign two distinct votes for the same view that aggregate into two distinct same-view QCs over different leaves? | `ElectionSafety_HS2` or `NoEquivocationGoesUnflagged` | B |
| MC3 | Can two parallel view-sync relays for the same `(epoch, view)` each emit valid finalize certs, and can replicas accepting different certs reach different leader-of-view decisions / different parent QCs? | `UniqueFinalizeCertPerView`, then check whether subsequent proposal-creation produces inconsistent leaves | C |
| MC4 | Can a crash between `handle_eqc_formed`'s in-memory updates and the `storage.update_eqc` await leave a node with `highQcInMem` ahead of `highQcPersisted` such that a restart re-uses the older persisted high_qc, leading to a proposal off the wrong parent? | `HighQC_PersistedConsistent`, `ElectionSafety_HS2` | D |
| MC5 | Can a Byzantine proposer with a *mis-declared* epoch satisfy `validate_current_epoch`'s one-sided check (`epoch_from_block_number(bn) ≥ epoch_from_block_number(high_bn + 1)`) and then have `validate_qc_and_next_epoch_qc` verify the QC against the *attacker-chosen* stake table? | `ProposalEpochMatchesView` | A, E |
| MC6 | Locked-view advancement on liveness rule: can a Byzantine leader produce a `justify_qc` for a *higher* view than the locked view but on a *sibling* branch (no leaf-chain extension), forcing an honest node's `lockedView` to advance past a leaf the node has never seen, and subsequently to vote on a conflicting proposal? | `LockedViewBelowOrEqualHighQC`, `ElectionSafety_HS2` | B, E |

Each of MC1–MC6 is a mechanism question whose answer is **not** in any closed PR.

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|-------------------------|
| T1 | Confirm `TimeoutData2.commit()` epoch-strip is detectable in serialized form across two epochs with identical signers | Property test: sign a `TimeoutVote2` with `epoch=E`, rebuild as `epoch=E'`, verify signature still checks. |
| T2 | Confirm `submit_vote` does not persist vote action | Inject a crash via test harness between `broadcast_event(QuorumVoteSend)` and the next `update_action`; verify the recovered node will sign a vote at the same view on a different proposal. |
| T3 | Confirm parallel relays can emit two valid finalize certs for the same view | Integration test driving the view-sync task with votes routed to two different relays' accumulators. |
| T4 | Confirm `validate_proposal_liveness` pollutes `saved_leaves` with rejected proposals | Send a proposal with low `justify_qc.view` and no epoch-transition; assert that the leaf appears in `consensus.saved_leaves()` despite the bail. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|------------------|
| R1 | `update_high_qc` (consensus.rs:1325) should escalate same-view-different-leaf cases beyond `debug!`; possibly produce slashing-evidence event. | Discuss with maintainers; relates to #3918 ongoing refactor. |
| R2 | `update_locked_view` callers (handlers.rs:185-187) currently discard `Result` with `let _ = ...`; should at minimum log at warn-level or propagate. | Submit PR. |
| R3 | `validate_proposal_liveness` calls `consensus_writer.update_leaf(...)` at L114 BEFORE deciding whether the proposal will be accepted (L131); errors silently traced. | Move the `update_leaf` after the L131 bail. |
| R4 | `fetch_proposal` (helpers.rs:54-147) does not re-check proposal leader signature; relies on `Leaf2::commit()` binding. | Document the security argument; add a defensive re-check if cheap. |
| R5 | `is_valid_cert` (simple_certificate.rs:177, 257, 340) — refactor per #3918 to take `Membership` directly. | Tracked in #3918; brief surfaces it as still-open. |
| R6 | `update_validator_participation` (consensus.rs:309-326) — no per-view dedup; consider gating on `last_actions`. | Discuss whether double-increment affects rewards. |
| R7 | `verify_drb_result` silently skips enforcement for non-stakers (helpers.rs:208). Document the security boundary. | Comment-only fix; verify new-joiner replay covers the gap. |
| R8 | View-sync replica accepts a cert with `cert.data().relay < self.relay` (view_sync.rs:660-680). Consider rejecting. | Submit PR; verify the protocol allows or forbids it per Naor-Keidar. |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/hotshot/.specula-output/analysis-report.md`
- **Key source files** (all under `crates/hotshot/`):
  - `task-impls/src/consensus/handlers.rs:154-510` — view-change / timeout handling
  - `task-impls/src/quorum_proposal_recv/handlers.rs:88-426` — proposal receipt + liveness/safety entry
  - `task-impls/src/quorum_proposal/handlers.rs:740-922` — proposal creation + `handle_eqc_formed`
  - `task-impls/src/quorum_vote/handlers.rs:432-568` — `submit_vote`
  - `task-impls/src/view_sync.rs:91-101, 205-279, 647-890` — relay maps and replica
  - `task-impls/src/helpers.rs:1100-1259` — `validate_proposal_view_and_certs`, `validate_qc_and_next_epoch_qc`
  - `task-impls/src/helpers.rs:761-836` — `update_high_qc` flow
  - `task-impls/src/helpers.rs:925-1066` — `validate_proposal_safety_and_liveness`
  - `task-impls/src/helpers.rs:168-230` — `verify_drb_result`
  - `task-impls/src/helpers.rs:54-147` — `fetch_proposal`
  - `types/src/simple_vote.rs:460-468` — TimeoutData2 commit (epoch-strip)
  - `types/src/simple_vote.rs:389-396` — VersionedVoteData commit
  - `types/src/simple_vote.rs:406-449` — QuorumData2 / NextEpochQuorumData2 commit
  - `types/src/simple_certificate.rs:340-360` — is_valid_cert (generic)
  - `types/src/simple_certificate.rs:1005-1031` — CertificatePair::verify_next_epoch_qc
  - `types/src/consensus.rs:1205-1212, 1266-1338, 1364-1400` — `update_locked_view`, `update_validated_state_map`, `update_high_qc`, `reset_high_qc`
  - `types/src/data.rs:1478-1515, 1726-1772, 2178-2208` — Leaf2 definition, Committable, `from_quorum_proposal`
- **GitHub issues / PRs**:
  - **Unfixed, target for modeling questions**: #3971 (double voting), #3918 (membership binding), #2607 (epoch-transition catchup), #3962 (catchup race draft).
  - **Reference context — closed/fixed (do NOT propagate to § 6.1)**: #3922 (dual-QC design), #3851 (eQC voting), #3900 (extended voting fix), #2897 (proposal task self-race), #2670 (broadcast eQC), #2829 (QC inconsistencies across epochs), #3168 (proposal pipeline cleanup), #3441 (DRB fixes), #2818 (DRB catchup), #3622 (add_drb_result ordering), #3534 (get_epoch_drb), #2921 (epoch-keyed view-sync), #3544 (view-sync GC), #3596 (view-sync byzantine tests), #2204 (timeout cancel), #1442 (view-2 timeouts).
  - **Tracker / structural reference**: #3635 (HS2 macro), #1612 (cert-driven view change).
- **Reference algorithm**: Malkhi-Nayak, *HotStuff-2* (2023); Naor-Keidar view-sync; Espresso paper (eprint.iacr.org/2024/1189).
- **In-tree audit**: `audits/internal-reviews/EspressoHotshot-2024internal.pdf` (Espresso-internal; not consulted; treat as private).
