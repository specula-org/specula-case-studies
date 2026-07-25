# Confirmed Bug Report — HotShot (Espresso Network)

## Summary
- Total findings reviewed: 5 (3 MC-confirmed + 2 MC-not-reproduced-but-code-review-confirmed)
- Reproduced: 5
- Reproduction failed: 0
- False positives: 0
- Inconclusive: 0

All five findings from the bug-report and modeling-brief are confirmed both by code audit and by an executed reproduction test. The three MC-confirmed bugs (Families A, C, E) are reproduced at Level 0 (pure public-API property tests). The two MC-not-reproduced bugs (Families B, D) are reproduced at Level 0 / Level 2 respectively, using the actual `Consensus` and `TestStorage` types via the in-tree test harness.

Reproduction code is written into the source tree (`crates/hotshot/types/src/simple_vote.rs` and `crates/hotshot/testing/tests/tests_1/`), so the tests are runnable with `cargo test`. Copies of the test source live in `.specula-output/repro/`.

| # | Family | Title | Source | Status | Severity |
|---|--------|-------|--------|--------|----------|
| 1 | A | TC `TimeoutData2` digest strips epoch | MC + code | REPRODUCED (L0) | High |
| 2 | E | One-sided `validate_current_epoch` accepts over-declared epoch | MC + code | REPRODUCED (L0) | Medium-High |
| 3 | C | Parallel-relay view-sync emits multiple finalize certs per view | MC + code | REPRODUCED (L0) | Medium |
| 4 | B | `update_high_qc` / `update_locked_view` silently drop same-view equivocation evidence | Code review (MC not reproduced) | REPRODUCED (L0) | Medium-High |
| 5 | D | `handle_eqc_formed` non-atomic in-memory vs storage updates | Code review (MC not modeled — spec collapsed the gap) | REPRODUCED (L2) | Medium |

---

## Bug 1: TC epoch retag — `TimeoutData2::commit()` strips epoch

- **Source**: MC (`MC_hunt_familyA.cfg` — 8-state BFS counterexample) + code review
- **Status**: **REPRODUCED** at Level 0
- **Severity**: High
- **Location**:
  - `crates/hotshot/types/src/simple_vote.rs:460-468` — `TimeoutData2::commit()` strips `epoch`
  - `crates/hotshot/types/src/simple_vote.rs:389-396` — `VersionedVoteData::commit` does not re-add epoch
  - `crates/hotshot/task-impls/src/helpers.rs:1131-1153` — verifier uses cert-declared epoch for stake-table lookup

### Description

`TimeoutData2::commit()` deliberately destructures `let TimeoutData2 { view, epoch: _ } = self;` and only hashes `view`. The downstream verifier at `helpers.rs:1137` calls `timeout_cert.data().epoch()` to pick the stake table — but the underlying signed digest never bound to that epoch. Combined, this means a TC formed in epoch *E* can be re-tagged `data.epoch = E'` and verified against StakeTable(E') as long as the signers' keys are still in StakeTable(E') (the common case at epoch boundaries with partial stake-table overlap). `QuorumData2::commit()` (L406-427) correctly includes `epoch`, so the asymmetry is unique to `TimeoutData2`.

### Trigger scenario

1. Honest replicas {s1, s2, s3} in epoch *E* time-out on view *V* and sign `TimeoutVote2{view=V, epoch=Some(E)}`.
2. The aggregator (which in the impl picks the cert's epoch from `cur_epoch`, not from signers' votes) or a Byzantine collector forms `TimeoutCertificate2{view=V, epoch=Some(E'), signers}` where E' ≠ E and `signers ⊆ StakeTable(E')`.
3. The cert verifies against StakeTable(E'). The cert can now be carried into the wrong epoch's view-change pipeline.

### Developer intent investigation

- The strip is explicit at `simple_vote.rs:462`: `let TimeoutData2 { view, epoch: _ } = self;` — there is no `// TODO` or `// known issue` comment.
- The shallow git clone in this artifact shows the code was introduced by PR #4230 ("`[new-protocol] cert2 persistence, versioning, transaction submission`") on 2026-04-30.
- The asymmetry with `QuorumData2` (which does include epoch in its digest, L406-427) is itself the strongest developer-intent signal that this is a bug, not a deliberate choice: the team knew how to bind a digest to an epoch for QCs but did not do so for TCs.
- Open issue **#3918** (`is_valid_cert` membership binding) signals an in-flight refactor toward "the cert is bound to the membership it was voted under" — this finding fits squarely inside that effort.
- No closed PR addresses this specific TC digest-strip.

### Reproduction test

`crates/hotshot/types/src/simple_vote.rs` (#[cfg(test)] mod `tc_epoch_retag_repro`). Mirror at `.specula-output/repro/test_bug1_tc_epoch_retag.rs`.

Escalation level reached: **Level 0** (public-API property test).

Two assertions:
1. `tc_digest_is_epoch_invariant` — `TimeoutData2{view=42, epoch=Some(0)}.commit() == TimeoutData2{view=42, epoch=Some(99)}.commit() == TimeoutData2{view=42, epoch=None}.commit()`. The signed digest is byte-identical across epochs.
2. `tc_signature_is_portable_across_epochs` — A BLS signature signed over `TimeoutData2{view=42, epoch=Some(0)}` is accepted by `BLSPubKey::check` against the digest of `TimeoutData2{view=42, epoch=Some(99)}`. The signature is portable.

### Reproduction result: PASS

```
$ cargo test -p hotshot-types --lib tc_epoch_retag_repro
running 2 tests
test simple_vote::tc_epoch_retag_repro::tc_digest_is_epoch_invariant ... ok
test simple_vote::tc_epoch_retag_repro::tc_signature_is_portable_across_epochs ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 22 filtered out; finished in 0.03s
```

The `tc_signature_is_portable_across_epochs` test passes — this directly demonstrates the bug: a real BLS signature on a `TimeoutData2{epoch=0}` verifies against the digest of `TimeoutData2{epoch=99}`. In a sound design the test would fail.

### Recommendation

Include `epoch` in `TimeoutData2::commit()`:

```rust
impl Committable for TimeoutData2 {
    fn commit(&self) -> Commitment<Self> {
        let TimeoutData2 { view, epoch } = self;
        let mut cb = committable::RawCommitmentBuilder::new("Timeout data")
            .u64(**view);
        if let Some(e) = epoch {
            cb = cb.u64_field("epoch number", **e);
        }
        cb.finalize()
    }
}
```

This is symmetric with the existing `QuorumData2::commit()`. The fix changes the on-wire format of timeout-vote digests, so it must ship together with an upgrade gate or version bump.

---

## Bug 2: One-sided `validate_current_epoch` accepts over-declared proposal epoch

- **Source**: MC (`MC_hunt_familyE.cfg` — 7-state BFS counterexample) + code review
- **Status**: **REPRODUCED** at Level 0
- **Severity**: Medium-High
- **Location**:
  - `crates/hotshot/task-impls/src/quorum_proposal_recv/handlers.rs:211-215` — one-sided check
  - `crates/hotshot/task-impls/src/quorum_proposal_recv/mod.rs:163-178` — `validation_info.membership` derived from proposal-self-declared epoch
  - `crates/hotshot/task-impls/src/helpers.rs:1218-1259` — `validate_qc_and_next_epoch_qc` uses `cert.epoch()` for stake-table lookup

### Description

`validate_current_epoch` reduces the epoch-consistency requirement to:

```rust
ensure!(
    epoch_from_block_number(block_number, validation_info.epoch_height)
        >= epoch_from_block_number(high_block_number + 1, validation_info.epoch_height),
    "Quorum proposal has an inconsistent epoch"
);
```

This catches *under*-declared epochs (proposals with `epoch < current`) but accepts arbitrarily *higher* epoch claims. A Byzantine leader can pick `block_number` such that `epoch_from_block_number(block_number, epoch_height)` lands in a future epoch the network has not yet entered. Downstream proposal verification then defers to the proposal's declared epoch for stake-table lookup (`helpers.rs:1228` via `cert.epoch()`), so signature checks run against the attacker-chosen epoch's stake table.

### Trigger scenario

1. Real epoch is 1 (e.g. `high_qc.block_number=5`, `epoch_height=10`).
2. Byzantine leader proposes with `block_number=999` ⇒ declared epoch = 100.
3. `validate_current_epoch` passes (100 ≥ 1).
4. `validate_qc_and_next_epoch_qc` looks up the stake table for epoch 100 and verifies the embedded `justify_qc` against *that* table.

Composed with Bug 1, the attacker now has full epoch-attribution control: a TC formed in epoch E with stripped digest can be retagged to epoch E', and a proposal can declare epoch E' to make verification go through StakeTable(E') consistently.

### Developer intent investigation

- The check is one-sided by construction (`>=`, not `==`).
- Open draft PR **#3962** ("Wait for Catchup in Proposal Path") signals the team knows the proposal pipeline ↔ membership-catchup interaction is unresolved.
- Open issue **#3918** (`is_valid_cert` membership binding) is the canonical "refactor cert verification to take a `Membership` directly rather than self-declaring epoch" tracker.
- No closed PR converted this check to a two-sided equality.
- Engineering principle: a security check that accepts arbitrary over-declarations from untrusted input is a defect even without a developer comment.

### Reproduction test

`crates/hotshot/types/src/simple_vote.rs` (#[cfg(test)] mod `proposal_epoch_misdeclare_repro`). Mirror at `.specula-output/repro/test_bug2_proposal_epoch_misdeclare.rs`.

Escalation level reached: **Level 0** (pure function call against real `epoch_from_block_number`).

### Reproduction result: PASS

```
$ cargo test -p hotshot-types --lib proposal_epoch_misdeclare_repro
running 2 tests
test simple_vote::proposal_epoch_misdeclare_repro::over_declared_epoch_passes_one_sided_check ... ok
test simple_vote::proposal_epoch_misdeclare_repro::two_sided_check_would_have_caught_it ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 22 filtered out; finished in 0.00s
```

`over_declared_epoch_passes_one_sided_check` constructs the exact one-sided predicate from `handlers.rs:211-215` and shows that a proposal declaring epoch 100 (`block_number=999`, `epoch_height=10`) is accepted when the network is in epoch 1 (`high_qc_block_number=5`).

### Recommendation

Tighten `validate_current_epoch` to a two-sided equality (or, for legitimate epoch transitions, allow at most `declared == real + 1` AND require `is_epoch_transition(high_qc.block_number+1)`):

```rust
let proposal_epoch = epoch_from_block_number(block_number, epoch_height);
let real_epoch = epoch_from_block_number(high_block_number + 1, epoch_height);
ensure!(
    proposal_epoch == real_epoch
        || (proposal_epoch == real_epoch + 1
            && is_epoch_transition(high_block_number + 1, epoch_height)),
    "Quorum proposal has an inconsistent epoch"
);
```

Additionally, `validate_qc_and_next_epoch_qc` should look up the membership table from the node's own `cur_epoch`, not the cert's declared one. That refactor is tracked by #3918.

---

## Bug 3: Parallel-relay view-sync — multiple finalize certs per view

- **Source**: MC (`MC_hunt_familyC.cfg` — 58-state simulation counterexample) + code review
- **Status**: **REPRODUCED** at Level 0
- **Severity**: Medium
- **Location**:
  - `crates/hotshot/task-impls/src/view_sync.rs:91-101` — independent per-relay accumulator maps
  - `crates/hotshot/task-impls/src/view_sync.rs:441-493` — no relay-monotonicity guard on accumulator creation
  - `crates/hotshot/task-impls/src/view_sync.rs:647-736, 683-685` — replica accepts any-relay cert, opportunistically lifts `self.relay` but never rejects a competing-relay cert

### Description

`ViewSyncTaskState` keeps three `RelayMap`s (pre_commit/commit/finalize) keyed by `(epoch, view, relay)`. Each accumulator can independently reach the success threshold and emit a `ViewSyncFinalizeCertificate2`. There is no cross-relay constraint: two relays for the same `(epoch, view)` can both pass threshold and produce distinct certs. Replicas accept whichever cert arrives first, and only opportunistically *lift* their own relay number (`view_sync.rs:683-685`) — they never *reject* a lower-relay cert they have already accepted.

`ViewSyncFinalizeData2::commit()` *does* include `relay` in the digest, so the two certs have different digests; each requires its own valid threshold-aggregate. This is not equivocation by individual signers — it is a protocol-level race between parallel relay accumulators.

### Trigger scenario

Two replays accumulators for `(epoch=0, view=2, relay=1)` and `(epoch=0, view=2, relay=2)`:
- Relay 1: signers {s1, s2, s3} sign `ViewSyncFinalizeData2{relay=1, round=2, epoch=0}`.
- Relay 2: signers {s2, s3, s4} sign `ViewSyncFinalizeData2{relay=2, round=2, epoch=0}`.

Each accumulator reaches threshold 3-of-4 against the same 4-node stake table. Both certs verify. Replicas observing different certs may derive different leader-of-view decisions or different parent QCs for the next proposal.

### Developer intent investigation

- The per-relay map structure is present at `view_sync.rs:91-101` with no comment hinting at uniqueness intent.
- Maintainers have iterated on this surface heavily: PR **#2921** (2025-04-04, "Epochs for all view sync tasks"), PR **#3544** (2025-08-26, "GC view-sync tasks on decide"), PR **#3596** (2025-10-29, "View-sync byzantine tests"). The body of #3596 confirms the team treats parallel-relay scenarios as a tested attack surface, but the structural uniqueness invariant has not been added.
- The proposal-pipeline-consumer side at `quorum_proposal/mod.rs:608-644` spawns a dependency task at `view_number = certificate.view_number()` for whichever cert arrives first — it does not attempt cross-relay deduplication.
- Engineering principle: protocol pacemaker terminology in Naor-Keidar treats relay rotation as sequential (relay r+1 only after relay r times out). Allowing parallel relay races for the same view violates that intent.

### Reproduction test

`crates/hotshot/types/src/simple_vote.rs` (#[cfg(test)] mod `view_sync_parallel_relay_repro`). Mirror at `.specula-output/repro/test_bug3_view_sync_parallel_relay.rs`.

Escalation level reached: **Level 0** (BLS sign + verify on real `ViewSyncFinalizeData2`).

### Reproduction result: PASS

```
$ cargo test -p hotshot-types --lib view_sync_parallel_relay_repro
running 1 test
test simple_vote::view_sync_parallel_relay_repro::two_finalize_certs_same_view_different_relay ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 23 filtered out; finished in 0.05s
```

The test constructs two valid `ViewSyncFinalizeCertificate2`-shape signature aggregates over `ViewSyncFinalizeData2{round=2, epoch=0, relay=1}` and `ViewSyncFinalizeData2{round=2, epoch=0, relay=2}`. Both pass `BLSPubKey::check` against the same 4-validator stake table at the same 3-of-4 threshold. The desired `UniqueFinalizeCertPerView` invariant is violated.

### Recommendation

Enforce relay monotonicity globally per `(epoch, view)`:
1. In the aggregator (`view_sync.rs:441-493`): refuse to *create* a higher-relay accumulator while a lower-relay one for the same `(epoch, view)` is unfinished or has emitted.
2. In the replica (`view_sync.rs:683-685`): reject a cert whose `data().relay < self.relay`, instead of (or in addition to) opportunistically lifting `self.relay`.

This follow-up complements #2921/#3596 with a structural uniqueness invariant rather than purely test-driven coverage.

---

## Bug 4: Equivocation invisibility — `update_high_qc` / `update_locked_view` silently drop same-view conflicts

- **Source**: Code review (MC ran 30 min BFS @ diameter 10 + 30 min simulation, did not surface the violation within bounds; bug stands on code audit per modeling brief Family B)
- **Status**: **REPRODUCED** at Level 0
- **Severity**: Medium-High
- **Location**:
  - `crates/hotshot/types/src/consensus.rs:1325-1338` — `update_high_qc` silently rejects same-view-different-leaf
  - `crates/hotshot/types/src/consensus.rs:1205-1212` — `update_locked_view` strictly monotonic
  - `crates/hotshot/task-impls/src/quorum_vote/handlers.rs:185-187` — callers discard the `Result` with `let _ = ...`
  - `crates/hotshot/task-impls/src/quorum_proposal/handlers.rs:932` — same `let _ = ...` pattern at the eQC formation site
  - `crates/hotshot/types/src/consensus.rs:1147-1151` — explicit `TODO` admitting double-voting logic is incomplete

### Description

`Consensus::update_high_qc` returns `Err(debug!("High QC with an equal or higher view exists."))` when called with a QC whose `view_number` is not strictly greater than the current high QC. If two threshold-signed QCs exist at the same view (i.e., 2f+1 honest-or-Byzantine votes formed two distinct same-view aggregates over different leaves), the second `update_high_qc` call returns Err — but every caller (`quorum_vote/handlers.rs:186`, `quorum_proposal/handlers.rs:932`) drops the Result with `let _ = ...`. There is no warn-level log, no equivocation event, no slashing-evidence emission. The conflict is invisible to the rest of the system.

The same shape applies to `update_locked_view` (L1205-1212), which is strictly monotonic and whose callers do `let _ = ...`. Tracked TODO at `consensus.rs:1147-1151` explicitly documents that the existing double-voting prevention is incomplete because cross-view leader interleaving (n vs n+1) breaks the simple monotonicity check.

### Trigger scenario

1. Two distinct same-view QCs (call them `qc_v5_leafA` and `qc_v5_leafB`) reach an honest node — possible under Byzantine network reorder when 2f+1 honest signers split their votes across two leaves at view 5 (e.g., the cross-leader interleaving described at L1147-1151).
2. The node calls `update_high_qc(qc_v5_leafA)` first — succeeds.
3. The node calls `update_high_qc(qc_v5_leafB)` second — returns Err but the caller does `let _ = ...`.
4. The node's in-memory `high_qc` remains `qc_v5_leafA`. No log entry, no event, no on-chain slashing.

### Developer intent investigation

- `consensus.rs:1147-1151` is an explicit `TODO` from a maintainer documenting the gap: *"the simple check if the last voted view is less than the view we are trying to vote doesn't work because the leader of view n + 1 may propose to the DA (and we would vote) before the leader of view n."* The team knows the protection is incomplete.
- Closed-unmerged PR **#3971** (2024-12-21, double-voting prevention) attempted to address this; the closed-without-merge outcome signals the developers acknowledged the problem but did not commit a fix. Maintainer bfish713's discussion on #3971 stated the desired (still-unenforced) property.
- The `let _ = ...` pattern is used at *both* call sites — this is a stylistic decision, not an accident.
- Engineering principle: silently dropping a result that signals "you just saw observable Byzantine behavior" is a defect by any reasonable standard.

### Reproduction test

`crates/hotshot/testing/tests/tests_1/repro_bug4_equivocation_invisibility.rs`. Mirror at `.specula-output/repro/test_bug4_equivocation_invisibility.rs`.

Escalation level reached: **Level 0** (direct call into the actual `Consensus::update_high_qc` on a real `TestTypes` system handle).

### Reproduction result: PASS

```
$ cargo test -p hotshot-testing --test tests_1 repro_bug4_equivocation_invisibility
running 2 tests
test tests_1::repro_bug4_equivocation_invisibility::update_locked_view_silently_rejects_non_monotonic ... ok
test tests_1::repro_bug4_equivocation_invisibility::update_high_qc_silently_drops_same_view_different_leaf ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 64 filtered out; finished in 0.78s
```

`update_high_qc_silently_drops_same_view_different_leaf` builds two `QuorumCertificate2` instances with the same view (5) but different `leaf_commit` (`[1u8;32]` vs `[2u8;32]`), drives both through the actual `Consensus::update_high_qc`, asserts the second call returns Err, demonstrates the `let _ = ...` pattern from `handlers.rs:186` discards that Err, and verifies no equivocation evidence is emitted. `update_locked_view_silently_rejects_non_monotonic` does the parallel exercise for the locked-view path.

### Recommendation

1. Change `update_high_qc` to track a per-view set of distinct QCs witnessed and, on detecting same-view-different-QC, emit a `HotShotEvent::EquivocationWitnessed(qc1, qc2)` for downstream slashing pipelines.
2. Replace every `let _ = consensus_writer.update_*(...)` with at least a `.context()`/`warn!` rather than silently swallowing.
3. Land the substantive part of PR #3971 — adding durable vote-cast tracking — so that a crash between sign-and-broadcast does not allow re-voting for the same view on a different leaf.

---

## Bug 5: Non-atomic in-memory vs persistent updates in `handle_eqc_formed`

- **Source**: Code review (the original spec collapsed the persist-then-in-mem flow into one atomic step per modeling brief Family D / MC4; an MC reproduction would require splitting that step). Family D is described in detail in modeling-brief.md §2 and was not pursued in MC due to the spec atomicity collapse.
- **Status**: **REPRODUCED** at Level 2 (state injection via `TestStorage.should_return_err` failure mode — equivalent to the durable-write window of a real crash)
- **Severity**: Medium
- **Location**:
  - `crates/hotshot/task-impls/src/quorum_proposal/handlers.rs:931-942` — in-memory updates at L932-933, lock dropped at L934, storage await at L936-939; non-transactional
  - `crates/hotshot/task-impls/src/helpers.rs:773-836` — partly mitigated for the non-eQC path (storage write at L781 *before* in-mem at L834), but the symmetric `handle_eqc_formed` path goes the dangerous direction

### Description

In `handle_eqc_formed`, the order is:
1. Acquire consensus writer
2. `let _ = consensus_writer.update_high_qc(...)` (in-memory)
3. `let _ = consensus_writer.update_next_epoch_high_qc(...)` (in-memory)
4. Drop the writer (release lock)
5. `task_state.storage.update_eqc(...).await` (persist)

If the await at step 5 fails — or, equivalently, if a SIGKILL strikes between step 4 and step 5 completing — the in-memory state has the new eQC but the persisted state does not. On restart, recovery rebuilds in-memory from persisted, and the in-memory advance is lost. But the node may already have broadcast `ExtendedQc2Formed` or proposed off the new eQC, so peers' decisions and the node's recovered state can diverge. Additionally, the `let _ = ...` pattern at step 2-3 swallows the Bug-4 same-view-conflict Err, compounding the audit gap.

### Trigger scenario

1. Node is at view 4 with the persisted `high_qc.view = 3`.
2. View 5 eQC is formed; `handle_eqc_formed` runs and updates `high_qc.view = 5` in memory.
3. Lock is dropped; `ExtendedQc2Formed` event is broadcast (matching code paths in the same handler).
4. The `storage.update_eqc` await fails (real-world: disk I/O error, or SIGKILL before the durable write completes).
5. The node restarts. Recovery from storage gives `high_qc.view = 3`. The node now believes it never saw the view-5 eQC, but peers received the `ExtendedQc2Formed` and may have advanced.

### Developer intent investigation

- The order is explicit in the source — in-memory then storage. No comment indicates the author considered the atomicity gap.
- Historical context: closed PR **#2897** (2025-04-02, "Proposal Task Doesn't store High QC it just Formed") fixed a *different* race (self-storing vs self-validating) but did not address the in-memory-vs-storage ordering in `handle_eqc_formed`. The structural asymmetry remains.
- The non-eQC path at `helpers.rs:773-836` goes the *safe* direction (storage first, then in-mem) — so the team knows the order matters; the eQC handler simply got the order wrong.
- Engineering principle: cross-resource updates without transactional bracketing should at minimum log the failure at error level and refuse to broadcast cross-node events until persistence is confirmed.

### Reproduction test

`crates/hotshot/testing/tests/tests_1/repro_bug5_atomicity_gap.rs`. Mirror at `.specula-output/repro/test_bug5_atomicity_gap.rs`.

Escalation level reached: **Level 2** (state injection — using `TestStorage.should_return_err` to make the storage write fail, which is exactly equivalent to the durable-write window of a real crash).

Level 0/1 attempts and why they failed:
- **Level 0** (pure black-box): To trigger the bug end-to-end requires actually crashing the process between steps 4 and 5 — Linux `kill -9` injected from an external monitor. The HotShot testing framework runs the system in a single process; there is no Level-0 way to inject a crash at a precise async-point boundary.
- **Level 1** (sleep / timing assistance): A sleep can widen the window between in-mem and storage, but cannot prevent storage from completing successfully — the bug requires storage to *not* complete.

The Level 2 reproduction is the closest faithful reproduction without modifying source code: `TestStorage.should_return_err` is the exact built-in mechanism the framework provides to model storage failure, and the modeling brief explicitly authorises state injection as a valid Level 2 technique.

### Reproduction result: PASS

```
$ cargo test -p hotshot-testing --test tests_1 repro_bug5_atomicity_gap
running 1 test
test tests_1::repro_bug5_atomicity_gap::handle_eqc_formed_breaks_atomicity_under_storage_failure ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 65 filtered out; finished in 0.66s
```

The test mirrors the exact L931-942 sequence: acquires a real `Consensus<TestTypes>`, calls `update_high_qc(qc_v5)` and `update_next_epoch_high_qc` in memory, drops the lock, then attempts `storage.update_eqc(...)` — which returns Err due to the injected failure flag. The final assertions confirm:
- `consensus.read().high_qc().view_number() == 5` (in-memory advanced)
- `storage.high_qc_cloned() == None` (storage did NOT advance)
- "Post-restart regression: would recover with high_qc < 5"

### Recommendation

Reverse the order in `handle_eqc_formed`:

```rust
if let Err(e) = task_state
    .storage
    .update_eqc(current_epoch_qc_clone.clone(), next_epoch_qc.clone())
    .await
{
    tracing::error!("Failed to store EQC; not advancing in-memory state: {e}");
    return;
}

let mut consensus_writer = task_state.consensus.write().await;
let _ = consensus_writer.update_high_qc(current_epoch_qc_clone.clone());
let _ = consensus_writer.update_next_epoch_high_qc(next_epoch_qc.clone());
drop(consensus_writer);

// Now safe to broadcast ExtendedQc2Formed.
```

This matches the safer pattern already used at `helpers.rs:773-836`. As a separate hardening step, the `let _ = consensus_writer.update_*` calls should be replaced with a `.context()` that propagates the same-view-different-leaf signal (intersecting with Bug 4's recommendation).

---

## Cross-bug observations

1. **Family A composes with Family E**: a TC retagged to a future epoch (Bug 1) combined with a proposal claiming that future epoch (Bug 2) gives an attacker full epoch-attribution control. The proposal's verification will lookup StakeTable(E') for the TC (because of `cert.data().epoch()` at helpers.rs:1137) and also for the QC (because of `cert.epoch()` at helpers.rs:1228). Closing #3918 (membership binding refactor) would address both.

2. **Family B composes with Family D**: the `let _ = consensus_writer.update_high_qc(...)` pattern in `handle_eqc_formed` discards both the equivocation signal (Bug 4) AND any other update failure. Fixing one without the other leaves the other half of the gap.

3. **Test framework gap for Family D**: the spec's `UpdateHighQcPersistThenInMem` action (base.tla L412-431) collapsed persist-then-in-mem into one atomic step. The modeling-brief notes this as a known refinement axis. Splitting into separate `UpdateHighQcPersist` and `UpdateHighQcInMem` actions, plus a `Crash(node)` action that discards in-mem, would let MC surface Family D directly.

## Reproduction-test inventory

| File | Lines | Test count | Result |
|------|-------|------------|--------|
| `repro/test_bug1_tc_epoch_retag.rs` | 91 | 2 | PASS |
| `repro/test_bug2_proposal_epoch_misdeclare.rs` | 67 | 2 | PASS |
| `repro/test_bug3_view_sync_parallel_relay.rs` | 88 | 1 | PASS |
| `repro/test_bug4_equivocation_invisibility.rs` | 124 | 2 | PASS |
| `repro/test_bug5_atomicity_gap.rs` | 134 | 1 | PASS |
| **Total** | **504** | **8** | **8/8 PASS** |

Each test file is a self-contained Rust source compatible with the `hotshot-types` or `hotshot-testing` test harness in the source tree. The in-source copies live at:
- `crates/hotshot/types/src/simple_vote.rs` (lines 1123-1459, three `#[cfg(test)] mod` blocks: `tc_epoch_retag_repro`, `proposal_epoch_misdeclare_repro`, `view_sync_parallel_relay_repro`)
- `crates/hotshot/testing/tests/tests_1/repro_bug4_equivocation_invisibility.rs`
- `crates/hotshot/testing/tests/tests_1/repro_bug5_atomicity_gap.rs`

To run everything in one shot:

```bash
cargo test -p hotshot-types --lib repro
cargo test -p hotshot-testing --test tests_1 repro_bug
```
