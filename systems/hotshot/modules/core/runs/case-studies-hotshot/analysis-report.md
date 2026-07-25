# HotShot (Espresso Network) — Code Analysis Report

**Target**: `EspressoSystems/espresso-network` (default branch `main`, head `3038613`)
**Scope**: `crates/hotshot/` (the BFT consensus library used as Espresso's shared decentralized sequencer)
**Reference algorithm**: HotStuff-2 (Malkhi-Nayak 2023) + Naor-Keidar view-sync
**Date**: 2026-05-18
**System category**: **Category A (Distributed / Message-Passing)**, BFT threat model with stake-weighted permissionless membership and epoch transitions

---

## 1. Reconnaissance

### 1.1 Core consensus surface (LOC, in-scope only)

| File | LOC | Role |
|------|-----|------|
| `task-impls/src/consensus/mod.rs` | 289 | Top-level event dispatcher; view/epoch state |
| `task-impls/src/consensus/handlers.rs` | 529 | `handle_view_change`, `handle_timeout`, `send_high_qc`, vote receivers |
| `task-impls/src/quorum_proposal/mod.rs` | 773 | Leader-side proposal task scheduler |
| `task-impls/src/quorum_proposal/handlers.rs` | 923 | Leader-side proposal creation |
| `task-impls/src/quorum_proposal_recv/handlers.rs` | 426 | Replica-side proposal receipt + liveness/safety entry |
| `task-impls/src/quorum_vote/mod.rs` | 856 | Replica-side vote pipeline |
| `task-impls/src/quorum_vote/handlers.rs` | 568 | Vote-side helpers and `submit_vote` |
| `task-impls/src/view_sync.rs` | 1023 | Naor-Keidar view-sync pacemaker |
| `task-impls/src/helpers.rs` | 1352 | `validate_proposal_safety_and_liveness`, `validate_qc_and_next_epoch_qc`, `fetch_proposal`, `verify_drb_result`, `update_high_qc` |
| `types/src/simple_certificate.rs` | 1052 | QC/TC/VSC certificate types and `is_valid_cert` |
| `types/src/simple_vote.rs` | 1121 | Voteable data types and their `Committable` impls |
| `types/src/vote.rs` | 360 | `Certificate`/`Vote` traits |
| `types/src/consensus.rs` | 1684 | Persistent safety state (`locked_view`, `high_qc`, `validated_state_map`, `last_actions`) |
| **Total in-scope** | **~12,000 LOC** | |

### 1.2 Concurrency / threading model

- Each "task" is an async actor consuming `Arc<HotShotEvent<TYPES>>` from a broadcast channel.
- Per-view dependency tasks (`DependencyTask`) are spawned for proposal building and voting; they read shared state under `consensus: OuterConsensus<TYPES>` (= `Arc<RwLock<Consensus<TYPES>>>`).
- View-sync uses per-`(epoch, view, relay)` vote accumulators in `BTreeMap` keyed maps protected by an outer `RwLock`.
- Persistence calls (`storage.update_high_qc2`, `storage.append_vid`, `storage.update_eqc`) are awaited inline; in-memory state is mutated under separate `consensus.write().await` locks. **In-memory and persistent updates are not transactional**.

### 1.3 Reference deviations from HotStuff-2 paper

- Adds **next-epoch QC** at epoch transitions (PR #3922) — a second QC over the same leaf signed by the next-epoch's committee. Pair-binding via `CertificatePair::verify_next_epoch_qc` checks `qc.data == next_epoch_qc.data` plus `qc.view_number == next_epoch_qc.view_number` (simple_certificate.rs:1005–1031).
- Adds **Extended QC (eQC)** at end-of-epoch — a 3-chain whose tip extends the eQC's last block, broadcast (not unicast) so every node can form the eQC (PR #3851).
- Adds **DRB-driven leader rotation one epoch in advance** (PR #4063, #3948); the next epoch's leader function is derived from the current epoch's DRB result.
- Adds **view-sync pacemaker** (Naor-Keidar) layered on top of the HS2 timeout cert, with per-relay rotation.

### 1.4 Atomicity boundaries

- **Single in-memory atomic unit**: any contiguous code section inside one `consensus.write().await` scope.
- **Cross-boundary risks identified**:
  - `handle_eqc_formed` (quorum_proposal/handlers.rs:899–922) — promotes in-memory `high_qc` and `next_epoch_high_qc`, drops the lock, *then* awaits `storage.update_eqc`.
  - `update_high_qc` path in helpers.rs:773–836 — writes to storage *before* in-memory monotonicity check.
  - `validate_proposal_liveness` (quorum_proposal_recv/handlers.rs:114) — calls `consensus_writer.update_leaf(...)` *before* deciding whether the proposal will be accepted (L131).

---

## 2. Bug Archaeology (Phase 2)

### 2.1 Coverage statistics

- Repository main branch HEAD: `3038613` (2026-05-15)
- Local clone is shallow (50 commits). Archaeology relied on `gh pr list` / `gh issue view --comments`.
- **PRs deeply read**: 48 merged PRs from 2024-05 through 2026-05 that touched core consensus files. **8 PRs were the named priors** (#3971, #3635, #3922, #3851, #3918, #3900, #2165, #1612).
- **Open issues deeply read**: 8 (#3812, #2607, #2680, #3152, #1687, #1459, #2020, #2482) — most consensus bug fixes ship without persistent open issues.
- **Open PRs**: 14 (8 with bug-fix intent).
- **Internal audit**: `audits/internal-reviews/EspressoHotshot-2024internal.pdf` is in-tree but not consulted in this analysis (Espresso-internal; treat as private). No public external audit of HotShot has been published.

### 2.2 Named priors — verification summaries

| # | State | Verdict / notes |
|---|-------|-----------------|
| **#3971** "Double Voting Prevention" | PR, closed unmerged 2024-12-21 | **Confirmed unfixed.** TODO at `consensus.rs:1147` ("DA voting … for now the simple check if the last voted view is less than the view we are trying to vote doesn't work because the leader of view n+1 may propose to the DA before the leader of view n"). Maintainer bfish713 articulated the desired properties (don't vote twice in a view, don't vote for ≤ high_qc.view, don't vote too far in the future), most of which are not enforced anywhere on the default branch. Modeling target. |
| **#3635** | tracker, open | Meta issue tracking HotStuff-2 migration. Mid-migration code retains legacy 3-chain paths gated by `version < EPOCH_VERSION`; brief should consider both phases. |
| **#3922** "Lr/double quorum" | merged 2024-12-18 | Adds `next_epoch_justify_qc`; binding via `CertificatePair::verify_next_epoch_qc`. The two QCs must agree on `(view, data)` where `data` includes `leaf_commit` and `epoch` — so they bind to the same leaf. Out-of-scope item: DA layer is *not* doubled. |
| **#3851** "Lr/eqc voting" | merged 2024-11-13 | Introduces "epoch safety check": proposed block + justify_qc must be same epoch OR justify_qc is eQC for previous epoch. Adds broadcast of last-eQC vote. |
| **#3918** "pass `membership` to `is_valid_cert`" | issue, open | **Confirmed unfixed.** `is_valid_cert` still takes raw `stake_table` + `threshold`; binding between cert and committee is the caller's job. tbro: "should take a type implementing Membership as input … directly call the threshold/stake table". |
| **#3900** "Fix extended voting" | merged 2024-11-20 | Two arms in `quorum_vote/mod.rs` were inverted; the eQC-marker was attached to the wrong join point. Now `is_vote_leaf_extended` is computed correctly from `is_leaf_extended(proposed_leaf.commit())`. Already fixed. |
| **#2165** "Cancel Timeout Tasks properly" | issue, closed | Fixed by PR #2204 (2023-12-15). Pre-fix the timer task didn't get cancelled on view-change. Reference context only. |
| **#1612** "view change only on valid cert" | issue, closed | Refactored 2023 sprint5 — view advancement now driven by valid cert receipt (QC or TC). Aligns with HS/HS2 paper. Reference context only. |

### 2.3 Recurring bug-mechanism patterns in the merged-PR set

Across 48 deeply-read PRs (2024-2026), the recurring mechanisms are:

1. **Epoch-transition / dual-QC consistency** — PRs #2829, #2897, #2670, #3168, #2853 (5 PRs, central). Files: `simple_vote.rs`, `simple_certificate.rs`, `quorum_proposal*`, `helpers.rs`.
2. **DRB / next-epoch stake-table ordering and gating** — PRs #2888, #2818, #3534, #3622, #3586, #3441, #3241, #4100, #4298 (9 PRs). Files: `helpers.rs`, `consensus/mod.rs`, `epoch_membership.rs`.
3. **Membership locking / read-consistency** — PRs #2777, #4263, #4283 (3 PRs, ongoing). Files: `epoch_membership.rs`, all task-impls.
4. **Restart / persistence vs consensus state** — PRs #1442, #1926, #2221, #2160, #3279, #4193 (6 PRs). Files: `persistence/*`.
5. **Catchup safety against malicious responders** — PRs #3034/#3035; open #2020. File: `hotshot/src/types/handle.rs`.
6. **View-sync task lifetime and epoch awareness** — PRs #2921, #3544, #3439, plus byzantine-test PR #3596. File: `view_sync.rs`.
7. **Proposal vs validation race (Self-leader stores high_qc concurrently with validating own proposal)** — PR #2897. Notes: "Proposal task storing high_qc while concurrently validating could cause the proposal to fail validation (justify_qc < locally stored high_qc)."
8. **Timeout-cert dedup / re-broadcast loops** — PR #4207 (2026-04-21) for the *new-protocol* path; recurrence in old protocol unclear.

---

## 3. Deep Analysis Findings

The findings below are organized by mechanism. Findings tagged **VERIFIED** were re-read by the main analyst; others come from parallel subagent reads with file:line citations.

### 3.1 TC / TimeoutData2 epoch-stripping (VERIFIED, HIGH)

**Code**:
```rust
// crates/hotshot/types/src/simple_vote.rs:460-468
impl Committable for TimeoutData2 {
    fn commit(&self) -> Commitment<Self> {
        let TimeoutData2 { view, epoch: _ } = self;     // <-- epoch deliberately dropped

        committable::RawCommitmentBuilder::new("Timeout data")
            .u64(**view)
            .finalize()
    }
}
```

```rust
// crates/hotshot/types/src/simple_vote.rs:389-396
impl<TYPES: NodeType, DATA: Voteable<TYPES>> Committable for VersionedVoteData<TYPES, DATA> {
    fn commit(&self) -> Commitment<Self> {
        committable::RawCommitmentBuilder::new("Vote")
            .var_size_bytes(self.data.commit().as_ref())
            .u64(*self.view)
            .finalize()
    }
}
```

So a TimeoutVote2 signer signs `"Vote" || TimeoutData2.commit() || view = "Vote" || view || view`. **The epoch field is not in the signed digest.**

**Validator-side path** (helpers.rs:1137–1148):
```rust
let timeout_cert_epoch = timeout_cert.data().epoch();
membership = membership.get_new_epoch(timeout_cert_epoch)?;     // <-- self-declared
let membership_stake_table = StakeTableEntries::from_iter(membership.stake_table()).0;
let membership_success_threshold = membership.success_threshold();
timeout_cert.is_valid_cert(&membership_stake_table, membership_success_threshold, &validation_info.upgrade_lock)?;
```

The stake table used for verification is fetched from the cert's *self-declared* epoch (`timeout_cert.data().epoch()`). The signed digest does not include the epoch, so a signature collected during epoch E (signing "Vote" || view=V || view=V) is byte-identical to what an epoch-E' signer would have produced. Replay across epochs verifies whenever signers' BLS keys are still present in the verifier's lookup of epoch E's stake table.

**Why this matters under BLS aggregation**: HotShot uses BLS-aggregated `QcType` with a signer bitmap. The verifier `is_valid_cert` reconstructs the aggregated public key from the stake table that the *caller* supplies. The signed digest is identical across epochs. So: a TC formed in epoch E whose signers' keys appear in epoch E' (e.g., rolling-membership PoS where most validators continue between epochs) can be replayed with `.data.epoch = E'` and still verify against the E' stake table — *provided the bitmap indexes the same keys in both tables*. This is a real surface area for cross-epoch TC replay.

**Same pattern**: `ViewSyncFinalizeData2` (round + epoch). The "View Sync Finalize" digest includes the epoch (simple_vote.rs:582–592 via `view_and_relay_commit`), so this attack does *not* apply to view-sync certs. But `is_valid_cert` for VSC similarly uses the cert-declared epoch (helpers.rs:1162–1163), creating a softer "wrong stake table" attack surface.

**QuorumCertificate2 / QuorumData2**: The digest *does* include the epoch (simple_vote.rs:406–427), so the cross-epoch replay attack does *not* apply. QC value-binding is intact.

### 3.2 Equivocation invisibility (VERIFIED, HIGH)

`update_high_qc` (consensus.rs:1325–1338) silently drops a second QC at the same view:
```rust
pub fn update_high_qc(&mut self, high_qc: QuorumCertificate2<TYPES>) -> Result<()> {
    if self.high_qc == high_qc { return Ok(()); }
    ensure!(
        high_qc.view_number > self.high_qc.view_number,
        debug!("High QC with an equal or higher view exists.")
    );
    self.high_qc = high_qc;
    Ok(())
}
```

`update_locked_view` (consensus.rs:1205–1212): same pattern — monotonic only, no extra checks.

`update_validated_state_map` (consensus.rs:1266–1298): when a new leaf-view arrives for an existing view-number, the guard only fails if (a) new is non-Leaf, or (b) `new_delta.is_none() && existing_delta.is_some()`. **If both have `Some(delta)` but different `leaf_commit`s, the new view silently overwrites**. The associated `update_saved_leaves` (L1301–1303) just inserts the new leaf alongside the old one; the map now has two leaves but the canonical state-map entry points only to the new one.

Three call sites discard the result (`let _ = ...`):
- `handlers.rs:185-187` for `update_locked_view`
- `quorum_proposal/handlers.rs:902-906` for `update_high_qc` and `update_next_epoch_high_qc` inside `handle_eqc_formed`

So equivocation evidence (two distinct, threshold-signed QCs at the same view) is observable by an honest validator but never persisted as an accountability signal.

### 3.3 Vote-cast not durable; locked-view TOCTOU (HIGH)

`submit_vote` (quorum_vote/handlers.rs:432–568) constructs the vote, persists *the VID share* (L483–487), broadcasts the vote, and returns. **No call to** `consensus.update_action(HotShotAction::Vote, view_number)`. **No call to** `update_latest_voted_view`. The in-memory `latest_voted_view: ViewNumber` on `QuorumVoteTaskState` (mod.rs:447) is bumped only on `ViewChange` (mod.rs:811–815), and is never persisted.

The HotStuff-2 safety predicate `justify_qc.view >= locked_view` is checked once at proposal-receive time (`validate_proposal_safety_and_liveness` in helpers.rs:925; the call to `update_locked_view` for HS2 is at quorum_proposal_recv/handlers.rs:118–127). Between that check and the actual `submit_vote` call from the dependency task (mod.rs spawns the task at L619), `locked_view` could advance because of a *parallel* proposal handler running concurrently in the same consensus writer. The vote dependency task does not re-check `locked_view <= proposal.justify_qc.view` immediately before signing.

PR #3971's discussion confirmed maintainers' intent: "Don't vote twice in a view; Don't vote for old views … a view less or equal to the high QC view; Don't vote for views too far in the future." These properties are not enforced anywhere on default `main`.

### 3.4 Locked-view advancement via `valid_epoch_transition` bypass (MEDIUM)

In `validate_proposal_liveness` (quorum_proposal_recv/handlers.rs:88–135):
```rust
let liveness_check = proposal.data.justify_qc().view_number() > consensus_writer.locked_view();
if liveness_check && version >= EPOCH_VERSION {
    consensus_writer.update_locked_view(proposal.data.justify_qc().view_number())?;
}
drop(consensus_writer);
if !liveness_check && !valid_epoch_transition {
    bail!("Quorum Proposal failed the liveness check");
}
```

The function is reached when `parent_leaf` is missing from `saved_leaves` (handlers.rs:382–397). A proposal can be accepted on the disjunction:
1. `liveness_check` (justify_qc.view > locked_view), OR
2. `valid_epoch_transition` (the justify_qc.block is on an epoch transition and `validate_epoch_transition_qc` passes).

Path 2 does not require `justify_qc.view > locked_view`. The proposal is accepted, the leaf is inserted into the state map (L114), but `update_locked_view` is *not* called. That's correct safety-wise — the lock stays put — but it means an attacker can repeatedly inject epoch-transition-shaped proposals over an honest node's lower-than-lock justify_qc view to **pollute the saved_leaves map with arbitrary leaves at arbitrary views** (the `update_leaf` error at L115 is logged at trace level and ignored). Later, when an honest proposal arrives, those polluted leaves are candidates for `parent_leaf`.

### 3.5 View-sync parallel relays for the same view (HIGH)

`view_sync.rs:91–101` defines three independent maps:
```rust
pub pre_commit_relay_map: Arc<RwLock<RelayMap<TYPES, ViewSyncPreCommitVote2<TYPES>, ...>>>,
pub commit_relay_map:     Arc<RwLock<RelayMap<TYPES, ViewSyncCommitVote2<TYPES>,    ...>>>,
pub finalize_relay_map:   Arc<RwLock<RelayMap<TYPES, ViewSyncFinalizeVote2<TYPES>,  ...>>>,
```
Each is `BTreeMap<Option<EpochNumber>, BTreeMap<ViewNumber, BTreeMap<u64 /*relay*/, VoteCollectionTaskState<..>>>>`.

For a single `(epoch, view)`, multiple relay accumulators run **concurrently**. The first one to cross the success threshold emits a valid `ViewSyncFinalizeCertificate2` and triggers GC of the whole `view→relay` map; but in the race window, *other relays' accumulators may also cross threshold*. Both certificates over the same view with different `relay` numbers are valid and threshold-signed.

When a replica receives a `ViewSyncFinalizeCertificateRecv` (view_sync.rs:840–890), it checks signature validity and `certificate.view_number() == self.next_view`; it does NOT cross-check that `certificate.data().relay >= self.relay` or that a prior PreCommit/Commit cert from the same relay was observed. So two different relays' finalize certs over view V both pass.

Downstream, the proposal task uses `ViewSyncFinalizeCertificateRecv` to spawn a dependency task at `view_number = certificate.view_number` (quorum_proposal/mod.rs:608–644). The cert's view is bound to the proposal's view. If two relays produce two certs and two race propagations arrive at different replicas in different orders, different replicas may build their proposal pipeline against different relays' evidence — and the parent QC selection in `quorum_proposal/handlers.rs:740–807` differs across paths (`wait_for_transition_qc` vs `wait_for_highest_qc`), giving the leader different parent leaves depending on event ordering.

### 3.6 Non-atomic in-memory ↔ persistent updates (MEDIUM)

- **`handle_eqc_formed`** (quorum_proposal/handlers.rs:899–922): updates in-memory `high_qc` and `next_epoch_high_qc` under one write lock, drops it, then awaits `storage.update_eqc`. If storage fails, in-memory is ahead of persistent. After a crash, the node restarts with a stale persisted high_qc.
- **`update_high_qc` path** (helpers.rs:773–836): in the non-transition-epoch branch, `storage.update_high_qc2` and `storage.update_next_epoch_high_qc2` are awaited BEFORE the in-memory monotonicity check at L820–834. A storage write may persist that the in-memory layer would have refused.
- **`update_high_qc` skipped entirely** when `in_transition_epoch == true` (helpers.rs:761–773): only in-memory advances; persistent state lags. Intentional but creates a "high_qc is volatile during transition" window.

### 3.7 Cert-self-declared-epoch attack surface across QC/TC/VSC verifications (MEDIUM)

The pattern repeats across three call sites:
- `validate_qc_and_next_epoch_qc` (helpers.rs:1228): `membership_coordinator.stake_table_for_epoch(cert.epoch())`
- TC validation (helpers.rs:1137): `membership.get_new_epoch(timeout_cert.data().epoch())`
- VSC validation (helpers.rs:1162): `membership.get_new_epoch(view_sync_cert.data().epoch())`
- Per-cert validation in quorum_proposal/mod.rs:608–644: `stake_table_for_epoch(certificate.data.epoch)`

In every case the cert's *declared* epoch is the source of truth for the stake table to verify against. The QC and VSC signed digests include the epoch field; the TC signed digest does not (§ 3.1). The QC/VSC code is safe against cross-epoch replay because the digest binds; the TC code is not.

### 3.8 `fetch_proposal` accepts leaves on commit-equality without re-validating proposal signature (MEDIUM)

helpers.rs:54–147. After receiving a proposal in response to a fetch, the code checks `leaf.view_number() == requested_view && leaf.commit() == leaf_commit`, validates `justify_qc.is_valid_cert(...)` against the QC's self-declared epoch, then calls `consensus_writer.update_leaf(leaf, state, None)`. The proposal's *own* leader signature is not re-checked. Safety relies entirely on `Leaf2::commit()` being collision-resistant over the leaf's contents — which it is, since the commit body (data.rs:1726–1772, verified) includes view_number, parent_commitment, block_header, justify_qc, upgrade_certificate, and (with_epoch) next_epoch_justify_qc, next_drb_result, view_change_evidence. **`block_payload` is explicitly excluded** (`block_payload: _` at L1735), so the commit binds to the header (which contains the payload commitment) rather than the raw payload.

### 3.9 Independent path inconsistencies — proposal parent-QC selection (MEDIUM)

`get_parent_qc` in quorum_proposal/handlers.rs:740–807 selects the parent QC differently across three branches:
1. If a `Qc2Formed` is already a dependency input: use that QC.
2. If `version < EPOCH_VERSION`: use `self.consensus.read().await.high_qc().clone()` (local cache, no peer poll).
3. Else if a view-change cert is present: try `wait_for_transition_qc` (over the network), fall back to `wait_for_highest_qc`.
4. Else (no cert, post-epoch): `wait_for_highest_qc` only.

So a pre-epoch leader's view-change-driven proposal uses the *local* high_qc, while a post-epoch leader's uses an *actively polled* high_qc. In pre-epoch mode a leader with a stale local high_qc proposes off a stale parent; in post-epoch mode it polls peers up to `timeout/2`. This was the root of PR #2897 (the "self-store-high_qc while validating" race) — fixed for *self-proposing*, but the structural asymmetry remains.

### 3.10 DRB / participation accounting (LOW–MEDIUM)

- `verify_drb_result` (helpers.rs:168–230): if the local node has no stake in the *current* epoch, DRB enforcement is silently skipped (L208 — `if has_stake_current_epoch { ... }` then `Ok(())`). Non-stakers and fresh joiners do not validate DRB.
- `update_validator_participation` (consensus.rs:309–326): increments counters with no per-view dedup. A re-entered dependency task (after restart or replay) double-increments. Cannot decrement — Byzantine actions are not deducted.

### 3.11 Open-PR / draft signals

- **#3962** (draft, 2026-02-16) "Wait for Catchup in Proposal Path" — confirms a known unhandled race: proposal task races ahead of catchup; touches `helpers.rs`, `quorum_proposal/mod.rs`, `quorum_vote/`, `consensus.rs`.
- **#3789** (open, 2025-11-21) "Load membership from storage before triggering catchup" — confirms membership-vs-catchup ordering is incomplete.
- **#3833** (draft, 2025-12-09) "Fix libp2p transport" — out-of-scope per case-study scoping.
- **#2607** (open) "PoS Test: node offline during epoch transition can catch up consensus state" — confirmed unfixed liveness regression at epoch boundaries.

---

## 4. Bug Family Synthesis

The 11 findings above cluster into **5 mechanism-based families**:

### Family A: Timeout / view-sync cert epoch binding (HIGH)

§ 3.1, § 3.7. `TimeoutData2.commit()` strips `epoch`; verifier uses cert-self-declared epoch.

### Family B: Equivocation invisibility & locked-view monotonicity holes (HIGH)

§ 3.2, § 3.3, § 3.4. `update_high_qc`, `update_locked_view`, `update_validated_state_map` silently drop conflicts; vote-cast not persisted; TOCTOU between proposal-validate and submit_vote.

### Family C: View-sync parallel-relay non-determinism (HIGH)

§ 3.5. Multiple relays per (epoch, view) each emit valid finalize certs; replicas accept first arriving.

### Family D: Non-atomic in-memory vs persistent updates (MEDIUM)

§ 3.6, § 3.8. `handle_eqc_formed`, helpers.rs:773 storage-before-memory writes, `fetch_proposal` accepts leaves by commit-equality, `validate_proposal_liveness` inserts leaves before deciding.

### Family E: Cross-epoch-binding gaps in proposal validation (MEDIUM)

§ 3.7, § 3.9, § 3.10. Proposal parent-QC selection differs pre/post epoch; QC-epoch is self-declared; non-stakers skip DRB.

---

## 5. Comparison to autobahn case study

The Specula corpus has a working autobahn modeling brief that found DA-1 (QC value-binding), DA-2 (Timeout digest hashes nothing), DA-3 (TC verify always Ok), DA-5 (winning_view confusion), DA-27 (HashMap iteration). HotShot is in the same protocol family (HotStuff descendants), but the code base is distinct. Verification:

| autobahn finding | HotShot analog | Verdict |
|------------------|----------------|---------|
| DA-1 (QC value binding) | `QuorumData2.commit()` includes leaf_commit + epoch + block_number; `Leaf2.commit()` includes block_header (which carries payload_commitment) | **NOT present** — QC value-binding is sound. |
| DA-2 (Timeout digest hashes nothing) | `TimeoutData2.commit()` includes view but NOT epoch | **Partial analog** — view is bound, epoch is not. Cross-epoch TC replay surface. |
| DA-3 (TC verify always Ok) | `is_valid_cert` does run the BLS aggregate check (simple_certificate.rs:340–360) | **NOT present** — verifier does verify. But it verifies against cert-self-declared epoch's stake table (§ 3.1/3.7). |
| DA-5 (winning_view confusion) | view-sync parallel relays for same view | **Different mechanism, similar consequence** — see Family C. |
| DA-27 (HashMap iteration) | view-sync `BTreeMap` iteration (deterministic); other state uses HashMap | Not investigated; likely not analogous. |

Net: HotShot's QC binding is **stronger** than autobahn's (§ 3.1 verified), but the TC binding has the same epoch-strip weakness and is composed with cert-self-declared-epoch lookup creating a real exploit window.

---

## 6. Pointers

### 6.1 Files cited

- `/home/ubuntu/Specula/case-studies/hotshot/artifact/espresso-network/crates/hotshot/task-impls/src/consensus/handlers.rs`
- `/home/ubuntu/Specula/case-studies/hotshot/artifact/espresso-network/crates/hotshot/task-impls/src/quorum_proposal_recv/handlers.rs`
- `/home/ubuntu/Specula/case-studies/hotshot/artifact/espresso-network/crates/hotshot/task-impls/src/helpers.rs`
- `/home/ubuntu/Specula/case-studies/hotshot/artifact/espresso-network/crates/hotshot/task-impls/src/view_sync.rs`
- `/home/ubuntu/Specula/case-studies/hotshot/artifact/espresso-network/crates/hotshot/task-impls/src/quorum_proposal/handlers.rs`
- `/home/ubuntu/Specula/case-studies/hotshot/artifact/espresso-network/crates/hotshot/task-impls/src/quorum_proposal/mod.rs`
- `/home/ubuntu/Specula/case-studies/hotshot/artifact/espresso-network/crates/hotshot/task-impls/src/quorum_vote/handlers.rs`
- `/home/ubuntu/Specula/case-studies/hotshot/artifact/espresso-network/crates/hotshot/task-impls/src/quorum_vote/mod.rs`
- `/home/ubuntu/Specula/case-studies/hotshot/artifact/espresso-network/crates/hotshot/types/src/simple_certificate.rs`
- `/home/ubuntu/Specula/case-studies/hotshot/artifact/espresso-network/crates/hotshot/types/src/simple_vote.rs`
- `/home/ubuntu/Specula/case-studies/hotshot/artifact/espresso-network/crates/hotshot/types/src/consensus.rs`
- `/home/ubuntu/Specula/case-studies/hotshot/artifact/espresso-network/crates/hotshot/types/src/data.rs`

### 6.2 Issues / PRs cited

- Confirmed unfixed: #3971 (double voting), #3918 (membership binding), #2607 (epoch-transition catchup), #3962 (catchup race, draft).
- Confirmed bug-prone mechanism evidence (already fixed; do NOT propagate to § 6.1 targets): #3922, #3851, #3900, #2897, #2670, #2829, #3168, #3441, #2818, #3622, #3534, #2921, #3544.
- Tracker / reference: #3635, #1612, #2165.

### 6.3 Reference algorithm

- Malkhi-Nayak, *HotStuff-2: Optimal Two-Phase Responsive BFT* (2023).
- Naor-Keidar view-sync pacemaker.
- Espresso Sequencing Network paper, eprint.iacr.org/2024/1189.
