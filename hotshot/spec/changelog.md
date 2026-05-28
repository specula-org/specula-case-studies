# HotShot Spec Validation Changelog

## Round 1 - Trace Validation

- [fix-spec] Init.curView: changed from 1 to 0 to match impl (test harness starts cur_view at 0 in Consensus::new; old value caused state.curView mismatch in handle_quorum_proposal_recv trace). (Trace: handle_quorum_proposal_recv.ndjson)
- [fix-spec] HandleQuorumProposalRecv: removed `curView' = p.view` update because the impl does not bump cur_view inside the handler — broadcast_view_change emits a ViewChange event that a separate task consumes (consensus/handlers.rs:329). (Trace: handle_quorum_proposal_recv.ndjson)
- [fix-spec] HandleQuorumProposalRecv: SafetyCheck path now also adds the proposed leaf to savedLeaves (matches helpers.rs:969 update_leaf call in validate_proposal_safety_and_liveness). (Trace: handle_quorum_proposal_recv.ndjson)
- [add-action] ViewChange(s, v): new monotone curView advancement action so MC bug-hunting can still reach higher views even though HandleQuorumProposalRecv no longer advances curView. Plumbed through MC.tla too.
- [fix-spec] qcAdvances and inMemAccepts and ObserveQC.accepts: rewrote `highQcInMem[s] = NilQC \/ highQcInMem[s].view > X` from disjunction to IF-THEN-ELSE — TLC was evaluating both branches in LET-bindings and tripping `.view` on a NilQC sentinel. (Trace: handle_quorum_proposal_recv.ndjson)
- [add-trace-action] BootstrapProposalIfNeeded: silent action in Trace.tla that synthesizes a proposal from msg fields (with a synthetic AllReplicas-signed justify_qc) and pre-populates savedLeaves[recv] with the parent leaf when the harness fed a proposal directly into a recv task (matches harness L105-111). Does not advance cursor.
- [fix-cfg] Trace.cfg: EvNone/EvTimeout/EvViewSync/Phase* changed from TLC model values to strings, matching the JSON-serialized evidenceKind/phase fields in the trace.
- [fix-cfg] Trace.cfg: removed TypeOK from INVARIANTS — trace uses hex leaf commits ("COMMIT~...") that aren't in the abstract Leaves={L1,L2,L3} set. TypeOK is enforced in MC.cfg.

## Round 1 - Model Checking (MC.cfg)

- No violations found. TLC ran 30 min BFS, diameter 13 reached, 764M distinct states explored. Standard safety (ElectionSafety_HS2, HighQCMonotonic_InMem) + structural invariants (MCTypeOK, MCFaultCtrsBounded, QcSignersWithinStakeTable) all hold across the reachable state space.
- Disk note: TLC's default `-metadir /tmp/...` was redirected to `/home/ubuntu/tlc-tmp` because root fs only has 24G free vs the OffHeapDiskFPSet's 200G mmap need.

## Convergence

Converged in 1 round (Trace + MC both pass without further spec changes after Round 1 fixes). Proceeding to Bug Hunting.

## Bug Hunting

- [bug] Family A `NoEpochReplayedTC` violated in 12s BFS (depth 11, 8-state CE). `FormTC` aggregator's free choice of `epochClaim` exposes the digest-stripped TC retag. See `output/familyA_bfs_bug.out` and bug-report.md Bug 1.
- [fix-spec] Added `GenesisQc` constant to Init (`highQcInMem = highQcPersisted = GenesisQc`, `qcs = {GenesisQc}`). Without genesis seeding, `ProposeLeader` is disabled (requires `highQcInMem ≠ NilQC`) and the whole honest-QC chain is unreachable from Init. Re-validated traces — still pass.
- [bug] Family E `ProposalEpochMatchesView` violated in 21s BFS (depth 11, 7-state CE) after genesis bootstrap. `MCByzProposeMisdeclaredEpoch(b1, L1, 1, 1)` proposes view-1 with `epochClaim=1` despite `realEpoch(1)=0`; the one-sided `ValidateCurrentEpoch` accepts. See `output/familyE_bug.out` and bug-report.md Bug 2.
- [fix-cfg] Removed `FinalizeCertImpliesCommitCert` from `MC_hunt_familyC.cfg` — the spec's `FormViewSyncCert` does not model the impl's phase-ordering (PreCommit-then-Commit-then-Finalize), so this invariant fails on a spec abstraction gap rather than a real bug.
- [bug] Family C `UniqueFinalizeCertPerView` violated in 2s simulation (depth 80, 58-state CE). Two relay accumulators independently reach finalize-threshold for the same `(epoch=0, view=2)`, producing two distinct finalize certs. See `output/familyC_bug.out` and bug-report.md Bug 3.
- [no-bug] Family B (`MC_hunt_familyB.cfg`): BFS 30 min (diameter 10, 277M distinct) + Simulation 30 min (1.2B states, 15M traces). Neither `NoEquivocationGoesUnflagged` nor `LockedViewBelowOrEqualHighQC` violated. Reachability analysis: two same-view conflicting QCs requires ≥3 leaf-L2 voters, which under MaxDoubleVote=1, MaxCrash=1 forces a long interleaving (~16 ordered actions). Not surfaced under the cfg bounds.
- [no-bug] Family D (`MC_hunt_familyD.cfg`): BFS 30 min (diameter 12, 630M distinct) + Simulation 30 min (1.4B states, 17.7M traces). `HighQC_PersistedConsistent` not violated. The Family D bug requires the persist-vs-in-mem update to be modeled as two separate actions, but the spec's `UpdateHighQcPersistThenInMem` is atomic. Documented in bug-report.md as a known refinement axis.

## Result

Converged in 1 round. Bug hunting: 3 bugs found (A, C, E); 2 not reproduced (B due to bounds, D due to spec abstraction). See `bug-report.md` for full details.


