# Bug Report — HotShot (Espresso Network)

## Summary

- Bug families tested: 5 (A, B, C, D, E)
- Bugs found: 3 confirmed (A, C, E), 1 abstraction gap (C-secondary), 2 not reproduced (B, D)
- Configs run: MC_hunt_familyA.cfg, MC_hunt_familyB.cfg, MC_hunt_familyC.cfg, MC_hunt_familyD.cfg, MC_hunt_familyE.cfg

## Bug 1: TC epoch retag — TimeoutData2 digest strips epoch (Family A)

- **Bug Family**: A (TC / VSC epoch binding)
- **Severity**: High
- **Invariant violated**: `NoEpochReplayedTC`
- **Config**: `MC_hunt_familyA.cfg` (BFS)
- **Counterexample**: 8 states (action sequence: Initial → ViewChange×3 → TimeoutVote×3 → FormTC), output file in `spec/output/familyA_bfs_bug.out`

### Trace Summary

1. Initial state: 3 honest replicas `{s1, s2, s3}` all at `curView=0`, `curEpoch=0`.
2. `MCViewChange(s1, 1)`, `MCViewChange(s2, 1)`, `MCViewChange(s3, 1)` — each replica advances to view 1.
3. `MCTimeoutVote(s1)`, `MCTimeoutVote(s2)`, `MCTimeoutVote(s3)` — each replica casts a TimeoutVote2 at `view=1, epoch=0`.
4. `MCFormTC(1, 1, {s1, s2, s3})` — an aggregator forms a `TimeoutCertificate2` with `view=1`, **`epochClaim=1`**, signers={s1,s2,s3}. The cert verifies because `signers ⊆ StakeTable(epoch=1) = AllReplicas` and `|signers|=3 ≥ ThresholdCount(epoch=1)=3`, but the underlying signed digest does not bind any epoch — all three signers actually timed-out for `epoch=0`.

Crucially, `faultCtrs.tcReplay=0` — no Byzantine `ByzReplayTcAcrossEpoch` action was required. The Byzantine choice is folded into the **honest** `FormTC` aggregator's free choice of `epochClaim`.

### Root Cause

`TimeoutData2.commit()` at `crates/hotshot/types/src/simple_vote.rs:460-468` strips the `epoch` field from the signed digest:

```rust
let TimeoutData2 { view, epoch: _ } = self;
// digest = hash(view) only
```

The downstream verifier at `crates/hotshot/task-impls/src/helpers.rs:1131-1153` then uses `timeout_cert.data().epoch()` to pick the stake table for signature checking. The verifier never confirms that the signers had previously committed to the cert-claimed epoch via their digest. As a result, an aggregator (or a Byzantine node that has collected TimeoutVote2 messages) can attach any `epoch` claim to the certificate and have it verify as long as the signers are present in the target epoch's stake table.

Contrast with `QuorumData2.commit()` at `simple_vote.rs:406-427`, which **does** include `epoch` in the digest. QC value-binding is therefore sound; only TC epoch-binding is broken.

### Affected Code

- `crates/hotshot/types/src/simple_vote.rs:460-468` — `TimeoutData2.commit()` strips epoch.
- `crates/hotshot/types/src/simple_vote.rs:389-396` — `VersionedVoteData::commit` does not re-add epoch.
- `crates/hotshot/task-impls/src/helpers.rs:1137-1148` — verifier uses cert-declared epoch for stake-table lookup, without re-checking signers signed for that epoch.

### Impact / Exploitability

In the model, both epochs share the same stake table, so any retag works. In production, the attacker needs **partial stake-table overlap** between epochs: the signers must be in both `StakeTable(orig)` and `StakeTable(target)`. With permissionless stake-weighted membership, this overlap is the *common case* at epoch boundaries. The attack:

1. Honest replicas in epoch E time-out on view V and sign `TimeoutVote2{view: V, epoch: E}`.
2. A Byzantine aggregator forms `TimeoutCertificate2{view: V, epoch: E', signers}` where E' ≠ E but `signers ⊆ StakeTable(E')`.
3. The cert verifies against `StakeTable(E')`, even though no signer ever consented to epoch E'.

Effects: the cert can be carried into the *wrong* epoch's view-change pipeline, potentially driving honest nodes in epoch E' to advance views or make leader-of-view decisions using a TC that originated in a different epoch's quorum.

### Recommendation

Include `epoch` in `TimeoutData2.commit()`:

```rust
impl<TYPES: NodeType> Committable for TimeoutData2<TYPES> {
    fn commit(&self) -> Commitment<Self> {
        committable::RawCommitmentBuilder::new("Timeout data")
            .u64_field("view number", *self.view)
            .u64_field("epoch", self.epoch.map(|e| *e).unwrap_or(0)) // NEW
            .finalize()
    }
}
```

This makes the TC signature bind to (view, epoch), preventing cross-epoch retag. The change is symmetric with `QuorumData2`'s existing epoch-binding.

---

## Bug 2: Proposal-declared epoch mismatch — one-sided validate_current_epoch (Family E)

- **Bug Family**: E (Cross-epoch binding gaps in proposal validation)
- **Severity**: Medium-High
- **Invariant violated**: `ProposalEpochMatchesView`
- **Config**: `MC_hunt_familyE.cfg` (BFS, after adding genesis-QC bootstrap to base spec)
- **Counterexample**: 7 states, output file in `spec/output/familyE_bug.out`

### Trace Summary

1. Initial state (with genesis QC seed): `qcs = {GenesisQc}`, `highQcInMem[s] = GenesisQc` for all replicas; `curEpoch = 0`; `realEpoch(view=1) = 0`.
2. `MCViewChange(s1, 1)`, `MCViewChange(s2, 1)`, `MCViewChange(s3, 1)` — honest replicas advance to view 1.
3. `MCTimeoutVote(s1)` — s1 times out (incidental; not central to bug).
4. `MCByzProposeMisdeclaredEpoch(b1, L1, 1, 1)` — Byzantine `b1` proposes a view-1 leaf with `epochClaim = 1` even though `realEpoch(1) = 0`. The justify_qc is the genesis QC (view 0).
5. (Implicit `MCHandleQuorumProposalRecv(s1, byzProposal)`) — s1 accepts the proposal:
   - `ValidateCurrentEpoch(s1, p)` = `p.epochClaim ≥ curEpoch[s1]` = `1 ≥ 0` ✓ (one-sided check, doesn't catch over-claim).
   - `ValidateProposalViewAndCerts(p)` = `p.justifyQc.view = p.view - 1` = `0 = 1 - 1` ✓.
   - `ValidateProposalQcs(p)` = `IsValidQc(GenesisQc)` ✓.
   - Spec runs the safety/liveness path → `savedLeaves[s1] += L1`.
6. Final state: `L1 ∈ savedLeaves[s1]`, `s1` not crashed. `ProposalEpochMatchesView` requires `p.epochClaim = realEpoch(p.view)` = `1 = 0` — FAILS.

### Root Cause

`validate_current_epoch` at `crates/hotshot/task-impls/src/quorum_proposal_recv/handlers.rs:172-218` is a **one-sided** guard:

```rust
ensure!(
    epoch_from_block_number(block_number, validation_info.epoch_height)
        >= epoch_from_block_number(high_block_number + 1, validation_info.epoch_height),
    "Quorum proposal has an inconsistent epoch"
);
```

This only catches proposals whose epoch is *lower* than expected — it accepts arbitrarily *higher* epoch claims. Combined with the cert-self-declared-epoch lookup in `validate_qc_and_next_epoch_qc` (`helpers.rs:1228`), the proposal's `epoch` claim drives the downstream stake-table choice. A Byzantine leader can declare an arbitrary higher epoch and have all subsequent validation defer to its choice.

### Affected Code

- `crates/hotshot/task-impls/src/quorum_proposal_recv/handlers.rs:172-218` — one-sided `validate_current_epoch`.
- `crates/hotshot/task-impls/src/quorum_proposal_recv/mod.rs:163-178` — `validation_info.membership` derived from proposal-self-declared epoch.
- `crates/hotshot/task-impls/src/helpers.rs:1218-1259` — `validate_qc_and_next_epoch_qc` uses `cert.epoch()` for stake-table lookup.

### Impact / Exploitability

A Byzantine leader can craft a proposal with `block_number` chosen such that `epoch_from_block_number(block_number, epoch_height)` lands in a future epoch the network has not yet entered. Downstream proposal verification (`validate_qc_and_next_epoch_qc`) then validates the embedded `justify_qc` against the **attacker-chosen** epoch's stake table.

Composed with Bug 1 (TC retag), this becomes a multi-step attack vector: a TC formed in epoch E with stripped digest can be retagged to epoch E', and a proposal can declare epoch E' to make verification go through `StakeTable(E')` consistently. The result is a proposal that an honest receiver accepts based on cryptographically real signatures, but with epoch-attribution under attacker control.

### Recommendation

Tighten `validate_current_epoch` to a two-sided equality (or close range), and have `validate_qc_and_next_epoch_qc` look up the membership table from the **node's own** `cur_epoch`, not the proposal's declared one. The membership-binding refactor in open issue #3918 is the broader fix.

---

## Bug 3: Parallel-relay view-sync produces multiple finalize certs per view (Family C)

- **Bug Family**: C (View-sync parallel-relay non-determinism)
- **Severity**: Medium
- **Invariant violated**: `UniqueFinalizeCertPerView`
- **Config**: `MC_hunt_familyC.cfg` (Simulation, after removing `FinalizeCertImpliesCommitCert` which fails for an abstraction gap, not a real bug)
- **Counterexample**: 58 states, output file in `spec/output/familyC_bug.out`

### Trace Summary

Two distinct finalize certificates for the same `view=2` and `epoch=0`, with **different relays**:
- `{view: 2, relay: 1, epoch: 0, signers: {s1, s2, s3}}`
- `{view: 2, relay: 2, epoch: 0, signers: {s2, s3, s4}}`

Both are valid certs: each has 3 signers ≥ `ThresholdCount(0) = 3`, and signers ⊆ `StakeTable(0)`. They differ on which 3-of-4 replicas signed and on the relay index.

The trace shows replicas distributing their finalize-phase votes across multiple relay buckets `relayPool[0][2][1][PhaseFinalize]` and `relayPool[0][2][2][PhaseFinalize]`, with no mutual-exclusion check between relays.

### Root Cause

`crates/hotshot/task-impls/src/view_sync.rs:91-101` keeps three per-relay accumulator maps:

```rust
pre_commit_relay_map: BTreeMap<(epoch, view, relay), ...>,
commit_relay_map: BTreeMap<(epoch, view, relay), ...>,
finalize_relay_map: BTreeMap<(epoch, view, relay), ...>,
```

Each accumulator can independently reach the success threshold and emit a `ViewSyncFinalizeCertificate2`. There is no cross-relay constraint: two relay-`r1` and relay-`r2` accumulators for the same `(epoch, view)` can both pass threshold and produce distinct certs.

Replicas accept whichever cert arrives first (`view_sync.rs:840-890`), without cross-checking `certificate.data().relay >= self.relay` (`view_sync.rs:660` opportunistically lifts `self.relay` but does not reject lower-relay certs). The proposal task at `quorum_proposal/mod.rs:608-644` spawns a dependency task at `view_number = certificate.view_number()` for whichever finalize cert it sees first.

### Affected Code

- `crates/hotshot/task-impls/src/view_sync.rs:91-101` — independent per-relay maps.
- `crates/hotshot/task-impls/src/view_sync.rs:441-493` — no relay-monotonicity guard on accumulator creation.
- `crates/hotshot/task-impls/src/view_sync.rs:647-736` — replica handler accepts any-relay PreCommit cert.

### Impact / Exploitability

Two replicas observing different finalize certs for the same view can derive different leader-of-view decisions or different parent QCs for the next proposal, creating a divergence window during view-sync recovery. Combined with the proposal-parent-selection asymmetry between `wait_for_transition_qc` and `wait_for_highest_qc`, this becomes an honest-but-unlucky divergence under network reorder.

### Recommendation

Enforce relay monotonicity globally per `(epoch, view)`: after `relay = r` reaches finalize-threshold for a view, refuse to accept votes for `relay < r` and stop accumulating in `relay > r`. Either at the aggregator (refuse to form a competing cert) or at the replica (reject acceptance of late-arriving certs at lower relay numbers).

PR #2921 (epochs for view-sync) and #3596 (view-sync byzantine tests) already exist; this finding suggests a follow-up to add relay-uniqueness invariants beyond epoch.

---

## Not Reproduced

| Bug Family | Config | Method | Result |
|------------|--------|--------|--------|
| **B** (equivocation invisibility) | `MC_hunt_familyB.cfg` | BFS 30 min @ diameter 10 (277M distinct states); Simulation 30 min | No `NoEquivocationGoesUnflagged` or `LockedViewBelowOrEqualHighQC` violation observed. Path to two same-view conflicting QCs requires deep interleaving that BFS and 80-depth simulation did not surface within bounds. |
| **D** (in-mem vs persistent split) | `MC_hunt_familyD.cfg` | BFS 30 min @ diameter 12 (630M distinct states); Simulation 30 min | Not testable in current spec: `UpdateHighQcPersistThenInMem` (base.tla L412-431) collapses the persist-then-in-mem flow into one atomic step. The Family D bug requires the **gap** between `storage.update_high_qc2().await` (helpers.rs:781) and `consensus_writer.update_high_qc()` (helpers.rs:834) to be modeled with an explicit crash window. Refining the spec into separate `UpdateHighQcPersist` and `UpdateHighQcInMem` actions would expose MC4 — this is documented in `harness/INSTRUMENTATION.md` § 3.2 as a known refinement axis. |

## Findings of Interest

### Family C secondary: phase-order abstraction gap

The original `MC_hunt_familyC.cfg` also checked `FinalizeCertImpliesCommitCert`, which the spec violates in 2 seconds of simulation. However, this is a **spec abstraction gap**, not a real protocol bug. The impl enforces phase ordering — a replica only casts a Finalize vote after observing a Commit cert at the same relay. The spec's `FormViewSyncCert` (base.tla L683-695) allows any phase to fire independently whenever its bucket reaches threshold, decoupled from prior-phase certs. We disabled this invariant in the cfg and continued hunting; the *real* Family C bug is in Bug 3 above.

### Family A independent of `ByzReplayTcAcrossEpoch`

The brief expected `ByzReplayTcAcrossEpoch` would be the trigger for Bug 1. Instead, the violation surfaces from the **honest** `FormTC` action, which is itself unconstrained in its `epochClaim` parameter (matching the impl's aggregator which derives the cert's epoch from `cur_epoch`, not from the signers' votes). The Byzantine action would only be a convenience for the same effect; the gap is in the protocol's signature-digest construction, not in any individual node's misbehavior.

---

## Spec Adjustments During Hunting

- **Genesis QC bootstrap**: added a `GenesisQc` constant to base.tla's Init (`highQcInMem = highQcPersisted = GenesisQc`, `qcs = {GenesisQc}`). Without this, the spec was vacuously stuck — honest `ProposeLeader` requires `highQcInMem ≠ NilQC`, and there was no bootstrap path to seed the first QC. Re-running Family E with this change surfaced Bug 2 in 21 seconds (vs. no violation under the previous unreachable-state cfg).
- **Disabled `FinalizeCertImpliesCommitCert` in `MC_hunt_familyC.cfg`**: see "Family C secondary" above.
