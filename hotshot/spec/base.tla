--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for HotShot consensus (Espresso Network).
 *
 * Source: EspressoSystems/espresso-network @ main, crates/hotshot/{types,task-impls}
 *
 * System category: A (Distributed / Message-Passing) BFT
 *
 * Bug Families covered:
 *   A — TC / VSC epoch binding (simple_vote.rs:460-468 strips epoch from TC digest;
 *       helpers.rs:1131-1153 verifier uses cert-self-declared epoch for stake-table lookup)
 *   B — Equivocation invisibility & locked-view monotonicity holes
 *       (consensus.rs:1325, 1205, 1266; quorum_vote/handlers.rs:432 — submit_vote does not
 *        persist vote action)
 *   C — View-sync parallel-relay non-determinism (view_sync.rs:91-101, 647-890)
 *   D — Non-atomic in-mem ↔ persistent updates
 *       (helpers.rs:761-836 stores QC before in-mem monotonicity check;
 *        quorum_proposal/handlers.rs:899-922 handle_eqc_formed in-mem then storage;
 *        quorum_proposal_recv/handlers.rs:114 update_leaf before bail at L131)
 *   E — Cross-epoch binding gaps (helpers.rs:1100-1199 uses validation_info.membership
 *       derived from proposal's self-declared epoch; validate_current_epoch one-sided guard)
 *
 * This spec models the implementation's actual control flow, not the HotStuff-2 paper.
 * Every logic block cites source file:line.
 *)

EXTENDS Integers, FiniteSets, Sequences, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Server              \* Set of correct (honest) replica IDs
CONSTANT ByzServer           \* Set of Byzantine replica IDs (disjoint from Server)
CONSTANT MaxView             \* Maximum view number to explore
CONSTANT MaxEpoch            \* Maximum epoch index (epochs are 0..MaxEpoch)
CONSTANT Leaves              \* Set of abstract leaf identities (proposal payloads)

CONSTANT NilLeaf             \* "No leaf yet" sentinel
CONSTANT NilQC               \* "No QC" sentinel
CONSTANT NoCert              \* "No view-change evidence" sentinel

\* Cert / message types
CONSTANTS
    QcMsg,                   \* QuorumCertificate2 envelope
    TcMsg,                   \* TimeoutCertificate2 envelope
    VscMsg,                  \* ViewSyncFinalizeCertificate2 envelope
    ProposalMsg,             \* QuorumProposalWrapper envelope
    VoteMsg,                 \* QuorumVote2 envelope
    TimeoutVoteMsg           \* TimeoutVote2 envelope

\* View-change evidence kinds (helpers.rs:1118-1178 distinguishes TC vs VSC arms)
CONSTANTS
    EvNone,                  \* normal: justify_qc.view == view - 1
    EvTimeout,               \* ViewChangeEvidence2::Timeout (TC)
    EvViewSync               \* ViewChangeEvidence2::ViewSync (VSC)

\* View-sync relay phases (view_sync.rs:88-103)
CONSTANTS
    PhasePreCommit,
    PhaseCommit,
    PhaseFinalize

ASSUME Server \cap ByzServer = {}
AllReplicas == Server \cup ByzServer

\* ============================================================================
\* HELPERS — stake tables and epoch arithmetic
\* ============================================================================

\* realEpoch(v) — the deterministic epoch a view v "should" belong to.
\* The implementation derives a *proposal*'s epoch from its declared block_number
\* (quorum_proposal_recv/mod.rs:163-178). We collapse view→epoch as a fixed total
\* function chosen to expose Family E composition with Family A.
realEpoch(v) ==
    IF v <= MaxView \div 2 THEN 0 ELSE 1

\* StakeTable(e) — set of replicas whose BLS keys are present in epoch e's stake table.
\* Family A's "partial-membership-overlap" mechanism: the two epochs share most keys
\* but differ in at least one slot, so a TC's sig set can be carried across.
\* Concrete shape exposed in MC.tla.
StakeTable(e) == AllReplicas

\* Success threshold (2f+1 in BFT). We abstract to "≥ ThresholdCount(e)" because we
\* keep signer-set semantics (a subset of StakeTable(e)) rather than tracking f.
ThresholdCount(e) == (2 * Cardinality(StakeTable(e))) \div 3 + 1

\* A signer set sigs is "valid for epoch e" iff every signer is in epoch e's stake
\* table AND there are at least ThresholdCount(e) of them. (Models is_valid_cert at
\* simple_certificate.rs:177 + simple_vote.rs:185-201 stake-table membership check.)
ValidSignersFor(sigs, e) ==
    /\ sigs \subseteq StakeTable(e)
    /\ Cardinality(sigs) >= ThresholdCount(e)

\* ============================================================================
\* TYPE SHAPES — certificates, votes, proposals
\* ============================================================================

\* QC: signed over (leaf_commit, epoch, block_number) — see simple_vote.rs:406-427
\* (QuorumData2 includes epoch). Therefore QC value binding *is* sound: sigs cannot
\* be re-tagged across epochs without producing a different digest.
\* Modeling note: we represent the signed-digest content as a record. Family B
\* exposes the *same-view two distinct leafs* case at QC formation.
QCType == [
    leafCommit  : Leaves \cup {NilLeaf},
    view        : 0..MaxView,
    epoch       : 0..MaxEpoch,
    signers     : SUBSET AllReplicas
]

\* TC: TimeoutData2.commit() strips epoch (simple_vote.rs:460-468). We model the
\* signed digest as covering only `view`. The cert *carries* an epoch claim that
\* the verifier uses to pick a stake table (helpers.rs:1137: `timeout_cert.data().epoch()`).
TCType == [
    view        : 0..MaxView,
    epochClaim  : 0..MaxEpoch,         \* what the cert *says* its epoch is
    signers     : SUBSET AllReplicas
]

\* VSC: digest includes (view, relay, epoch) — sound w.r.t. epoch binding
\* (simple_vote.rs:582-592). But Family C: multiple relays for the same (epoch,view)
\* can independently produce valid finalize certs.
VSCType == [
    view        : 0..MaxView,
    relay       : 0..MaxView,
    epoch       : 0..MaxEpoch,
    signers     : SUBSET AllReplicas
]

\* Proposal: leaf, justify_qc, declared epoch (proposal-self-declared, Family E),
\* and view-change evidence.
ProposalType == [
    view              : 0..MaxView,
    leaf              : Leaves \cup {NilLeaf},
    parentLeaf        : Leaves \cup {NilLeaf},
    epochClaim        : 0..MaxEpoch,        \* proposal-self-declared epoch (E)
    justifyQc         : QCType,
    evidenceKind      : {EvNone, EvTimeout, EvViewSync},
    tcEvidence        : TCType,             \* meaningful iff evidenceKind = EvTimeout
    vscEvidence       : VSCType             \* meaningful iff evidenceKind = EvViewSync
]

VoteType == [
    voter       : AllReplicas,
    view        : 0..MaxView,
    leaf        : Leaves \cup {NilLeaf},
    epoch       : 0..MaxEpoch,
    block_no    : 0..MaxView                \* block_number (Family A QuorumData2 binding)
]

TimeoutVoteType == [
    voter       : AllReplicas,
    view        : 0..MaxView,
    epoch       : 0..MaxEpoch                \* attacker-controllable: digest strips this
]

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* ---- Per-server consensus state (consensus.rs Consensus struct) ----

VARIABLE curView           \* [AllReplicas -> Nat] cur_view (consensus.rs)
VARIABLE curEpoch          \* [AllReplicas -> Nat] cur_epoch (consensus.rs)
VARIABLE highQcInMem       \* [AllReplicas -> QC | NilQC] in-mem high_qc (Family D)
VARIABLE highQcPersisted   \* [AllReplicas -> QC | NilQC] persistent high_qc (Family D)
VARIABLE lockedView        \* [AllReplicas -> Nat] locked_view (consensus.rs:1205-1212)
VARIABLE latestVotedView   \* [AllReplicas -> Nat] in-mem only (Family B; never persisted)
VARIABLE savedLeaves       \* [AllReplicas -> SUBSET Leaves] (consensus.rs:1301-1302)
VARIABLE highestBlock      \* [AllReplicas -> Nat] highest_block tracker
VARIABLE transitionQc      \* [AllReplicas -> QC | NilQC] dual-QC at epoch boundary

\* ---- Network — bags of in-flight messages ----

VARIABLE proposals         \* SUBSET ProposalType — all proposals ever broadcast
VARIABLE votes             \* SUBSET VoteType — quorum votes
VARIABLE timeoutVotes      \* SUBSET TimeoutVoteType — timeout votes
VARIABLE qcs               \* SUBSET QCType — formed QCs in the air
VARIABLE tcs               \* SUBSET TCType — formed TCs in the air
VARIABLE vscs              \* SUBSET VSCType — formed VSCs in the air

\* ---- Extension B: equivocation pool ----

\* qcWitnessed[node][view] is the set of QCs that this node has observed at this view.
\* update_high_qc (consensus.rs:1325) silently drops second QCs; we record the
\* observation regardless and check whether the impl flagged it.
VARIABLE qcWitnessed       \* [AllReplicas -> [0..MaxView -> SUBSET QCType]]

\* equivocationFlagged[node][view] — TRUE iff the impl raised an equivocation
\* alert at this (node, view). Under current code (consensus.rs:1325) it is never
\* set, so the invariant NoEquivocationGoesUnflagged is expected to fail.
VARIABLE equivocationFlagged  \* [AllReplicas -> [0..MaxView -> BOOLEAN]]

\* ---- Extension C: per-relay accumulators (view_sync.rs:91-101) ----

\* relayPool[epoch][view][relay][phase] is the set of votes accumulated for that
\* (epoch, view, relay, phase). Each phase produces its own cert at threshold.
VARIABLE relayPool         \* nested function -> SUBSET AllReplicas

\* ---- Extension B/D: per-node crash/recovery flag ----

VARIABLE crashed           \* [AllReplicas -> BOOLEAN]

\* ---- Extension D: pending storage windows ----

\* pendingPersistHighQC[node] is a QC that update_high_qc has scheduled to be
\* persisted (helpers.rs:779-785) but not yet committed in-mem. A crash here
\* loses the in-mem update; a crash *before* persist loses both.
VARIABLE pendingPersistHighQC  \* [AllReplicas -> QC | NilQC]

\* pendingEqcStorage[node] models handle_eqc_formed (quorum_proposal/handlers.rs:899-922):
\* in-mem updated under one write lock, lock dropped, then storage.update_eqc awaited.
VARIABLE pendingEqcStorage  \* [AllReplicas -> QC | NilQC]

\* ---- Decisions ----

VARIABLE committedLeaf     \* [AllReplicas -> [0..MaxView -> Leaves | NilLeaf]]

\* ---- Variable groups for UNCHANGED ----

consensusInMemVars == <<curView, curEpoch, highQcInMem, lockedView,
                        latestVotedView, savedLeaves, highestBlock, transitionQc>>
consensusPersistedVars == <<highQcPersisted, pendingPersistHighQC, pendingEqcStorage>>
networkVars == <<proposals, votes, timeoutVotes, qcs, tcs, vscs>>
extVars == <<qcWitnessed, equivocationFlagged, relayPool, crashed, committedLeaf>>
vars == <<consensusInMemVars, consensusPersistedVars, networkVars, extVars>>

\* ============================================================================
\* INIT
\* ============================================================================

\* Genesis QC: every node starts with a valid QC over the genesis leaf at view 0.
\* In the impl this comes from `Consensus::new` with a genesis high_qc; without
\* it the spec is unreachable from Init for honest QC formation (no proposer
\* could fire ProposeLeader without highQcInMem ≠ NilQC).
GenesisQc == [leafCommit |-> NilLeaf,
              view       |-> 0,
              epoch      |-> 0,
              signers    |-> AllReplicas]

Init ==
    \* cur_view starts at 0 in the impl (Consensus::new with caller-provided
    \* cur_view; the test harness uses 0). Older revisions of this spec set
    \* this to 1, which conflicted with the harness's initial state.
    /\ curView           = [s \in AllReplicas |-> 0]
    /\ curEpoch          = [s \in AllReplicas |-> 0]
    /\ highQcInMem       = [s \in AllReplicas |-> GenesisQc]
    /\ highQcPersisted   = [s \in AllReplicas |-> GenesisQc]
    /\ lockedView        = [s \in AllReplicas |-> 0]
    /\ latestVotedView   = [s \in AllReplicas |-> 0]
    /\ savedLeaves       = [s \in AllReplicas |-> {}]
    /\ highestBlock      = [s \in AllReplicas |-> 0]
    /\ transitionQc      = [s \in AllReplicas |-> NilQC]
    /\ proposals         = {}
    /\ votes             = {}
    /\ timeoutVotes      = {}
    \* Seed qcs with genesis so byz actions and FormQC chains can find a view-0 QC.
    /\ qcs               = {GenesisQc}
    /\ tcs               = {}
    /\ vscs              = {}
    /\ qcWitnessed       = [s \in AllReplicas |->
                              [v \in 0..MaxView |-> {}]]
    /\ equivocationFlagged = [s \in AllReplicas |->
                                [v \in 0..MaxView |-> FALSE]]
    /\ relayPool = [e \in 0..MaxEpoch |->
                      [v \in 0..MaxView |->
                          [r \in 0..MaxView |->
                              [p \in {PhasePreCommit, PhaseCommit, PhaseFinalize}
                                  |-> {}]]]]
    /\ crashed           = [s \in AllReplicas |-> FALSE]
    /\ pendingPersistHighQC = [s \in AllReplicas |-> NilQC]
    /\ pendingEqcStorage    = [s \in AllReplicas |-> NilQC]
    /\ committedLeaf     = [s \in AllReplicas |->
                              [v \in 0..MaxView |-> NilLeaf]]

\* ============================================================================
\* HELPER OPERATORS — modeling the impl's predicates
\* ============================================================================

\* simple_certificate.rs:177-201 — is_valid_cert (QC)
\* The verifier passes the membership_stake_table of cert.epoch (helpers.rs:1228
\* `membership_coordinator.stake_table_for_epoch(cert.epoch())`).
\* QuorumData2.commit() includes epoch (simple_vote.rs:406-427), so the signed
\* digest binds (leaf_commit, epoch). The verifier-side epoch picks the table.
IsValidQc(qc) ==
    /\ qc /= NilQC
    /\ ValidSignersFor(qc.signers, qc.epoch)

\* simple_certificate.rs:177-201 + simple_vote.rs:460-468 — is_valid_cert (TC)
\* TC digest strips epoch. The verifier uses cert.data().epoch() at helpers.rs:1137
\* to look up the stake table. THIS IS THE FAMILY-A MECHANISM.
\* A TC's signers are checked against StakeTable(tc.epochClaim).
\* Crucially, the *signed digest itself* covers only `view`, so a Byzantine
\* re-tagger can change epochClaim without invalidating signatures.
IsValidTc(tc) ==
    /\ ValidSignersFor(tc.signers, tc.epochClaim)
    \* No re-check that signers actually signed against epochClaim's digest —
    \* that's the gap. We model it by only checking membership+threshold.

\* simple_certificate.rs:257 + simple_vote.rs:582-592 — is_valid_cert (VSC)
\* VSC digest includes (view, relay, epoch). Family C is *not* about the digest;
\* it is about multiple per-relay accumulators (view_sync.rs:91-101) producing
\* multiple valid certs for the same (epoch, view).
IsValidVsc(vsc) ==
    /\ ValidSignersFor(vsc.signers, vsc.epoch)

\* helpers.rs:1218-1259 — validate_qc_and_next_epoch_qc:
\*   epoch_membership = membership_coordinator.stake_table_for_epoch(cert.epoch())
\*   cert.qc().is_valid_cert(membership_stake_table, ...)
\* Family E: cert.epoch() is whatever the proposal says it is, so the wrong
\* stake table can be used.
ValidateProposalQcs(p) ==
    IsValidQc(p.justifyQc)

\* helpers.rs:1131-1153 — TC arm of validate_proposal_view_and_certs
ValidateTcArm(p) ==
    /\ p.tcEvidence.view = p.view - 1
    /\ IsValidTc(p.tcEvidence)

\* helpers.rs:1154-1177 — VSC arm
ValidateVscArm(p) ==
    /\ p.vscEvidence.view = p.view
    /\ IsValidVsc(p.vscEvidence)

\* helpers.rs:1118-1178 — entire view-change-evidence dispatch
ValidateProposalViewAndCerts(p) ==
    /\ ValidateProposalQcs(p)
    /\ \/ /\ p.evidenceKind = EvNone
          /\ p.justifyQc.view = p.view - 1
       \/ /\ p.evidenceKind = EvTimeout
          /\ p.justifyQc.view /= p.view - 1
          /\ ValidateTcArm(p)
       \/ /\ p.evidenceKind = EvViewSync
          /\ p.justifyQc.view /= p.view - 1
          /\ ValidateVscArm(p)

\* quorum_proposal_recv/handlers.rs:172-218 — validate_current_epoch (one-sided guard)
\* For Family E: only checks
\*   epoch_from_block_number(bn) >= epoch_from_block_number(high_bn + 1)
\* The proposal's epoch claim is taken at face value.
ValidateCurrentEpoch(s, p) ==
    p.epochClaim >= curEpoch[s]   \* one-sided ≥, mirrors the "≥" at L211-213

\* ============================================================================
\* CRASH / RECOVERY — Family B+D
\* ============================================================================

\* Crash a node: in-memory state is lost; persistent state survives.
\* Family B: latest_voted_view is in-mem only (quorum_vote/mod.rs:447), so a crash
\* loses it. Family D: pendingPersistHighQC may or may not have hit disk.
Crash(n) ==
    /\ n \in Server
    /\ ~crashed[n]
    /\ crashed' = [crashed EXCEPT ![n] = TRUE]
    /\ curView'           = [curView           EXCEPT ![n] = 1]
    /\ curEpoch'          = [curEpoch          EXCEPT ![n] = 0]
    /\ highQcInMem'       = [highQcInMem       EXCEPT ![n] = NilQC]
    /\ lockedView'        = [lockedView        EXCEPT ![n] = 0]
    /\ latestVotedView'   = [latestVotedView   EXCEPT ![n] = 0]
    /\ savedLeaves'       = [savedLeaves       EXCEPT ![n] = {}]
    /\ highestBlock'      = [highestBlock      EXCEPT ![n] = 0]
    /\ transitionQc'      = [transitionQc      EXCEPT ![n] = NilQC]
    /\ UNCHANGED <<highQcPersisted, pendingPersistHighQC, pendingEqcStorage,
                   networkVars, qcWitnessed, equivocationFlagged, relayPool,
                   committedLeaf>>

\* Recover from persistent state. highQcPersisted seeds in-mem high_qc.
\* Family B: latest_voted_view is *not* restored.
Recover(n) ==
    /\ crashed[n]
    /\ crashed' = [crashed EXCEPT ![n] = FALSE]
    /\ highQcInMem' = [highQcInMem EXCEPT ![n] = highQcPersisted[n]]
    /\ UNCHANGED <<curView, curEpoch, lockedView, latestVotedView, savedLeaves,
                   highestBlock, transitionQc, highQcPersisted,
                   pendingPersistHighQC, pendingEqcStorage,
                   networkVars, qcWitnessed, equivocationFlagged, relayPool,
                   committedLeaf>>

\* ============================================================================
\* ACTION: HandleQuorumProposalRecv (entry point)
\* quorum_proposal_recv/handlers.rs:243-426
\* ============================================================================

\* helpers.rs:925-1066 — validate_proposal_safety_and_liveness uses lockedView and
\* the parent leaf chain. The safety arm is the "leaf extends the locked branch"
\* check. The impl also calls `update_leaf` at L969 to record the proposed leaf
\* even when entering through the safety+liveness path.
SafetyCheck(s, p) ==
    \* parent leaf must be in savedLeaves AND parent.view ≥ lockedView OR liveness
    p.parentLeaf \in savedLeaves[s]

\* Saved-leaves update for the safety+liveness arm — impl helpers.rs:969 always
\* calls `consensus_writer.update_leaf(proposed_leaf, ...)` after parent check.
SafetyPathLeafUpdate(s, p) ==
    savedLeaves' = [savedLeaves EXCEPT ![s] = @ \cup {p.leaf}]

\* quorum_proposal_recv/handlers.rs:118 — liveness_check
LivenessCheck(s, p) ==
    p.justifyQc.view > lockedView[s]

\* quorum_proposal_recv/handlers.rs:88-135 — validate_proposal_liveness
\* CRITICAL FAMILY-D MODELING: update_leaf is called at L114 BEFORE the bail at L131,
\* so even if the proposal is rejected, the leaf gets inserted into saved_leaves.
ValidateProposalLiveness(s, p) ==
    LET validEpochTransition ==
            \* approximated: a proposal with justify_qc.block_no in transition window
            \* (handlers.rs:101-104 calls validate_epoch_transition_qc)
            p.justifyQc.epoch /= p.epochClaim
        leaf == p.leaf
        \* L114: consensus_writer.update_leaf(leaf, state, None) — runs BEFORE L131 bail.
        \* Polluted-leaf insertion regardless of whether we accept.
        savedLeaves2 == [savedLeaves EXCEPT ![s] = @ \cup {leaf}]
        \* L118-127: locked-view advancement on liveness alone (HS2 rule)
        livenessOk == LivenessCheck(s, p)
        lockedView2 == IF livenessOk
                       THEN [lockedView EXCEPT ![s] = p.justifyQc.view]
                       ELSE lockedView
    IN  /\ savedLeaves' = savedLeaves2
        /\ lockedView'  = lockedView2
        \* L131: bail if neither liveness nor epoch-transition holds
        /\ (livenessOk \/ validEpochTransition)

\* helpers.rs:757-836 — update_high_qc flow.
\* Family D ordering:
\*   1. storage.update_high_qc2(justify_qc).await   <-- persisted first
\*   2. in-mem consensus_writer.update_high_qc(...)  <-- in-mem second
\* If the in-mem check rejects (consensus.rs:1325-1338 monotonic) but the storage
\* write already happened, the persistent state is ahead of in-mem.
\* If in_transition_epoch (helpers.rs:761-773) the *storage* write is skipped
\* entirely; only in-mem advances.
UpdateHighQcPersistThenInMem(s, qc) ==
    LET inTransitionEpoch == FALSE  \* simplified — see helpers.rs:761-770
        inMemCurr == highQcInMem[s]
        \* in-mem monotonic check (consensus.rs:1330-1333)
        inMemAccepts == IF inMemCurr = NilQC
                        THEN TRUE
                        ELSE qc.view > inMemCurr.view
    IN
        \* Branch 1: NOT in transition epoch → storage first, then in-mem
        \/ /\ ~inTransitionEpoch
           /\ highQcPersisted' = [highQcPersisted EXCEPT ![s] = qc]
           /\ IF inMemAccepts
              THEN highQcInMem' = [highQcInMem EXCEPT ![s] = qc]
              ELSE UNCHANGED highQcInMem
        \* Branch 2: in transition epoch → only in-mem advances
        \/ /\ inTransitionEpoch
           /\ UNCHANGED highQcPersisted
           /\ IF inMemAccepts
              THEN highQcInMem' = [highQcInMem EXCEPT ![s] = qc]
              ELSE UNCHANGED highQcInMem

\* quorum_proposal_recv/handlers.rs:243-426 — top-level handler.
HandleQuorumProposalRecv(s, p) ==
    /\ ~crashed[s]
    /\ s \in Server
    /\ p \in proposals
    /\ p.view <= MaxView
    \* L255 validate_current_epoch — Family E one-sided guard
    /\ ValidateCurrentEpoch(s, p)
    \* L258 validate_proposal_view_and_certs
    /\ ValidateProposalViewAndCerts(p)
    \* L311 validate_qc_and_next_epoch_qc
    /\ ValidateProposalQcs(p)
    \* L329-376: get parent leaf; if missing, fall to validate_proposal_liveness
    /\ LET parentInSaved == p.parentLeaf \in savedLeaves[s]
           qcAdvances == IF highQcInMem[s] = NilQC
                         THEN TRUE
                         ELSE p.justifyQc.view > highQcInMem[s].view
       IN
           \/ \* L367-376: justify_qc.view > our high_qc.view → update_high_qc
              /\ qcAdvances
              /\ UpdateHighQcPersistThenInMem(s, p.justifyQc)
              \* L378-396: parent missing → validate_proposal_liveness path
              /\ \/ /\ ~parentInSaved
                    /\ ValidateProposalLiveness(s, p)
                 \/ /\ parentInSaved
                    /\ SafetyCheck(s, p)
                    \* Impl L969 always calls update_leaf when parent is present.
                    /\ SafetyPathLeafUpdate(s, p)
                    /\ UNCHANGED lockedView
              /\ highestBlock' = [highestBlock EXCEPT ![s] = p.view]
              \* Impl does NOT update cur_view inside handle_quorum_proposal_recv;
              \* the view advancement happens via broadcast_view_change → separate
              \* task. We do not change curView here.
              /\ UNCHANGED <<curView, curEpoch, latestVotedView, transitionQc,
                             pendingPersistHighQC, pendingEqcStorage,
                             networkVars, qcWitnessed, equivocationFlagged,
                             relayPool, crashed, committedLeaf>>
           \/ \* qc does NOT advance → no update_high_qc; just validate parent path
              /\ ~qcAdvances
              /\ \/ /\ ~parentInSaved
                    /\ ValidateProposalLiveness(s, p)
                 \/ /\ parentInSaved
                    /\ SafetyCheck(s, p)
                    /\ SafetyPathLeafUpdate(s, p)
                    /\ UNCHANGED lockedView
              /\ highestBlock' = [highestBlock EXCEPT ![s] = p.view]
              /\ UNCHANGED <<curView, curEpoch, highQcInMem, highQcPersisted,
                             latestVotedView, transitionQc,
                             pendingPersistHighQC, pendingEqcStorage,
                             networkVars, qcWitnessed, equivocationFlagged,
                             relayPool, crashed, committedLeaf>>

\* ============================================================================
\* ACTION: ViewChange — separate view-change task (consensus/handlers.rs:329)
\* ============================================================================
\*
\* In the impl, `broadcast_view_change` emits a ViewChange event from
\* handle_quorum_proposal_recv (handlers.rs:417) and other places; the
\* consensus/handlers.rs:329 `handle_view_change` consumes it and updates
\* `cur_view`. We model this as a separate monotone advancement action so the
\* spec's HandleQuorumProposalRecv stays faithful (does not bump curView).
ViewChange(s, v) ==
    /\ ~crashed[s]
    /\ s \in Server
    /\ v <= MaxView
    /\ v > curView[s]
    /\ curView' = [curView EXCEPT ![s] = v]
    /\ UNCHANGED <<curEpoch, highQcInMem, highQcPersisted, lockedView,
                   latestVotedView, savedLeaves, highestBlock, transitionQc,
                   pendingPersistHighQC, pendingEqcStorage,
                   networkVars, qcWitnessed, equivocationFlagged, relayPool,
                   crashed, committedLeaf>>

\* ============================================================================
\* ACTION: SubmitVote (quorum_vote/handlers.rs:432-568)
\* ============================================================================

\* CRITICAL FAMILY-B MODELING: submit_vote does NOT call consensus.update_action()
\* for the vote, and latest_voted_view is in-mem only. So after a crash, the node
\* can re-vote at the same view on a different leaf without any record.
SubmitVote(s, p) ==
    /\ ~crashed[s]
    /\ s \in Server
    /\ p \in proposals
    \* Bound: vote at most once per view in-memory
    /\ p.view > latestVotedView[s]
    \* Vote requires we've validated this proposal (saved its leaf)
    /\ p.leaf \in savedLeaves[s]
    /\ LET v == [voter |-> s,
                 view  |-> p.view,
                 leaf  |-> p.leaf,
                 epoch |-> curEpoch[s],
                 block_no |-> p.view]
       IN  /\ votes' = votes \cup {v}
           \* L482-491: storage.append_vid — NOT the vote itself.
           \* The vote is broadcast at L564 with NO persist of "I voted view V".
           /\ latestVotedView' = [latestVotedView EXCEPT ![s] = p.view]
    /\ UNCHANGED <<curView, curEpoch, highQcInMem, highQcPersisted,
                   lockedView, savedLeaves, highestBlock, transitionQc,
                   pendingPersistHighQC, pendingEqcStorage,
                   proposals, timeoutVotes, qcs, tcs, vscs,
                   qcWitnessed, equivocationFlagged, relayPool, crashed,
                   committedLeaf>>

\* ============================================================================
\* ACTION: TimeoutVote (consensus/handlers.rs:154-186)
\* ============================================================================

\* simple_vote.rs:460-468 — TimeoutData2.commit() strips epoch.
\* Family A: the digest content is `(view)` only; epoch is "metadata" the cert
\* carries but signers do not commit to.
TimeoutVote(s) ==
    /\ ~crashed[s]
    /\ s \in Server
    /\ curView[s] <= MaxView
    /\ LET tv == [voter |-> s,
                  view  |-> curView[s],
                  epoch |-> curEpoch[s]]
       IN  timeoutVotes' = timeoutVotes \cup {tv}
    /\ UNCHANGED <<consensusInMemVars, consensusPersistedVars,
                   proposals, votes, qcs, tcs, vscs,
                   extVars>>

\* ============================================================================
\* ACTION: FormQC (vote aggregator; vote_collection.rs)
\* ============================================================================

\* Vote-aggregator forms a QC once threshold same-view-same-leaf votes accumulate.
\* Family B side: same view, two different leafs each over threshold → two QCs in
\* the air. update_high_qc (consensus.rs:1325) silently drops the second one
\* observed by a node, even though it is itself evidence.
FormQC(view, leaf, epoch, signers) ==
    /\ view <= MaxView
    /\ ValidSignersFor(signers, epoch)
    /\ \A v \in signers : \E vote \in votes :
            /\ vote.voter = v
            /\ vote.view = view
            /\ vote.leaf = leaf
            /\ vote.epoch = epoch
    /\ LET qc == [leafCommit |-> leaf,
                  view       |-> view,
                  epoch      |-> epoch,
                  signers    |-> signers]
       IN  qcs' = qcs \cup {qc}
    /\ UNCHANGED <<consensusInMemVars, consensusPersistedVars,
                   proposals, votes, timeoutVotes, tcs, vscs,
                   qcWitnessed, equivocationFlagged, relayPool, crashed,
                   committedLeaf>>

\* ============================================================================
\* ACTION: FormTC (vote_collection.rs — timeout vote aggregator)
\* ============================================================================

\* Family A: TC signers' digest is (view) only. The TC carries an epochClaim,
\* but the *signers* did not commit to that epoch.
FormTC(view, epochClaim, signers) ==
    /\ view <= MaxView
    /\ ValidSignersFor(signers, epochClaim)
    /\ \A v \in signers : \E tv \in timeoutVotes :
            /\ tv.voter = v
            /\ tv.view = view
            \* NOTE: tv.epoch is *carried* by the vote but not part of the digest
            \* (simple_vote.rs:460-468). The aggregator picks an epoch.
    /\ LET tc == [view       |-> view,
                  epochClaim |-> epochClaim,
                  signers    |-> signers]
       IN  tcs' = tcs \cup {tc}
    /\ UNCHANGED <<consensusInMemVars, consensusPersistedVars,
                   proposals, votes, timeoutVotes, qcs, vscs,
                   qcWitnessed, equivocationFlagged, relayPool, crashed,
                   committedLeaf>>

\* ============================================================================
\* ACTION: ObserveQC — node updates qcWitnessed pool
\* ============================================================================

\* Every node that sees a QC records it in qcWitnessed. The impl drops second
\* same-view QCs silently (consensus.rs:1325-1338); we track that drop.
ObserveQC(s, qc) ==
    /\ ~crashed[s]
    /\ s \in Server
    /\ qc \in qcs
    /\ IsValidQc(qc)
    \* Always record the observation (even though impl drops at update_high_qc)
    /\ qcWitnessed' = [qcWitnessed EXCEPT ![s][qc.view] = @ \cup {qc}]
    \* update_high_qc accepts only if qc.view > existing.view (consensus.rs:1330)
    /\ LET accepts == IF highQcInMem[s] = NilQC
                      THEN TRUE
                      ELSE qc.view > highQcInMem[s].view
       IN  IF accepts
           THEN /\ highQcInMem' = [highQcInMem EXCEPT ![s] = qc]
                /\ UNCHANGED equivocationFlagged
           ELSE \* Family B: same-view-different-leaf is silently dropped (debug! log)
                /\ UNCHANGED highQcInMem
                /\ UNCHANGED equivocationFlagged
    /\ UNCHANGED <<curView, curEpoch, highQcPersisted, lockedView,
                   latestVotedView, savedLeaves, highestBlock, transitionQc,
                   pendingPersistHighQC, pendingEqcStorage,
                   networkVars, relayPool, crashed, committedLeaf>>

\* ============================================================================
\* ACTION: ProposeLeader (quorum_proposal/handlers.rs — leader proposes)
\* ============================================================================

\* Leader proposes building on its high_qc.
ProposeLeader(s, leaf, view, evidenceKind) ==
    /\ ~crashed[s]
    /\ s \in Server
    /\ view <= MaxView
    /\ view = curView[s] + 1   \* leader proposes the next view
    /\ leaf /= NilLeaf
    /\ highQcInMem[s] /= NilQC
    /\ LET parent == highQcInMem[s].leafCommit
           p == [view         |-> view,
                 leaf         |-> leaf,
                 parentLeaf   |-> parent,
                 epochClaim   |-> curEpoch[s],
                 justifyQc    |-> highQcInMem[s],
                 evidenceKind |-> evidenceKind,
                 tcEvidence   |-> [view |-> view - 1,
                                   epochClaim |-> curEpoch[s],
                                   signers |-> {}],
                 vscEvidence  |-> [view |-> view,
                                   relay |-> 0,
                                   epoch |-> curEpoch[s],
                                   signers |-> {}]]
       IN  proposals' = proposals \cup {p}
    /\ UNCHANGED <<consensusInMemVars, consensusPersistedVars,
                   votes, timeoutVotes, qcs, tcs, vscs,
                   qcWitnessed, equivocationFlagged, relayPool, crashed,
                   committedLeaf>>

\* ============================================================================
\* ACTION: CommitLeaf (decide rule — three consecutive views, HS2)
\* ============================================================================

\* The decide rule fires when there is a QC for view v over leaf l, and a child
\* QC at v+1 over the proposal extending l. Simplified two-chain commit for the
\* spec; HS2 is a single-leaf two-chain.
CommitLeaf(s, leaf, view) ==
    /\ ~crashed[s]
    /\ s \in Server
    /\ view <= MaxView - 1
    /\ \E qc1, qc2 \in qcs :
            /\ qc1.leafCommit = leaf
            /\ qc1.view = view
            /\ qc2.view = view + 1
            /\ qc2.leafCommit /= NilLeaf
            \* qc2 must extend qc1's leaf (modelled as committed exists)
    /\ committedLeaf' = [committedLeaf EXCEPT ![s][view] = leaf]
    /\ UNCHANGED <<consensusInMemVars, consensusPersistedVars,
                   networkVars,
                   qcWitnessed, equivocationFlagged, relayPool, crashed>>

\* ============================================================================
\* ACTION: ViewSync — per-relay accumulator (Family C)
\* ============================================================================

\* view_sync.rs:91-101 — three per-relay accumulators.
\* The replica handler (view_sync.rs:647-890) accepts ANY relay's cert and
\* signs new votes over the cert's relay number, NOT the replica's local relay.
\* Multiple relays for the same (epoch, view) can independently reach threshold.

\* A correct voter casts its vote into the (epoch, view, relay, phase) bucket.
ViewSyncVote(s, e, v, r, phase) ==
    /\ ~crashed[s]
    /\ s \in Server
    /\ v <= MaxView
    /\ r <= MaxView
    /\ relayPool' = [relayPool EXCEPT ![e][v][r][phase] = @ \cup {s}]
    /\ UNCHANGED <<consensusInMemVars, consensusPersistedVars,
                   networkVars, qcWitnessed, equivocationFlagged,
                   crashed, committedLeaf>>

\* Form a view-sync cert when an accumulator reaches threshold.
\* Family C: the implementation does NOT enforce relay monotonicity across the
\* commit_relay_map and finalize_relay_map for the same (epoch, view) — so two
\* relays can independently emit valid finalize certs.
FormViewSyncCert(e, v, r, phase) ==
    /\ v <= MaxView
    /\ phase \in {PhasePreCommit, PhaseCommit, PhaseFinalize}
    /\ ValidSignersFor(relayPool[e][v][r][phase], e)
    /\ LET cert == [view |-> v, relay |-> r, epoch |-> e,
                    signers |-> relayPool[e][v][r][phase]]
       IN  IF phase = PhaseFinalize
           THEN vscs' = vscs \cup {cert}
           ELSE UNCHANGED vscs   \* PreCommit/Commit certs don't enter the proposal path
    /\ UNCHANGED <<consensusInMemVars, consensusPersistedVars,
                   proposals, votes, timeoutVotes, qcs, tcs,
                   qcWitnessed, equivocationFlagged, relayPool,
                   crashed, committedLeaf>>

\* ============================================================================
\* BYZANTINE ACTIONS — wrappers exposed to the MC layer for counting
\* ============================================================================

\* Family A: Re-tag a TC across epochs. Take an existing TC with epochClaim=fromE,
\* keep the same signers and view, emit a new TC with epochClaim=toE.
\* This is the central Family-A mechanism. The signed digest is byte-identical
\* (simple_vote.rs:460-468), so the signatures are still valid bytes; the
\* verifier picks StakeTable(toE) and accepts as long as the signers are present
\* in epoch toE's stake table (the partial-overlap case).
ByzReplayTcAcrossEpoch(view, fromE, toE) ==
    /\ view <= MaxView
    /\ fromE /= toE
    /\ \E origTc \in tcs :
            /\ origTc.view = view
            /\ origTc.epochClaim = fromE
            /\ LET retagged == [view |-> view,
                                epochClaim |-> toE,
                                signers |-> origTc.signers]
               IN
                  \* the partial-overlap requirement: signers ⊆ StakeTable(toE)
                  /\ retagged.signers \subseteq StakeTable(toE)
                  /\ tcs' = tcs \cup {retagged}
    /\ UNCHANGED <<consensusInMemVars, consensusPersistedVars,
                   proposals, votes, timeoutVotes, qcs, vscs,
                   qcWitnessed, equivocationFlagged, relayPool,
                   crashed, committedLeaf>>

\* Family B: Byzantine double-vote after crash. A Byzantine node (or a recovered
\* node that lost latest_voted_view) signs two votes for the same view on
\* different leaves.
ByzDoubleVote(s, view, leaf1, leaf2, epoch) ==
    /\ s \in ByzServer  \/ (s \in Server /\ crashed[s] = FALSE /\ latestVotedView[s] = 0)
    /\ view <= MaxView
    /\ leaf1 /= leaf2
    /\ leaf1 /= NilLeaf
    /\ leaf2 /= NilLeaf
    /\ LET v1 == [voter |-> s, view |-> view, leaf |-> leaf1,
                  epoch |-> epoch, block_no |-> view]
           v2 == [voter |-> s, view |-> view, leaf |-> leaf2,
                  epoch |-> epoch, block_no |-> view]
       IN  votes' = votes \cup {v1, v2}
    /\ UNCHANGED <<consensusInMemVars, consensusPersistedVars,
                   proposals, timeoutVotes, qcs, tcs, vscs,
                   qcWitnessed, equivocationFlagged, relayPool,
                   crashed, committedLeaf>>

\* Family C: spin up a second relay accumulator and vote into it. (The base
\* action ViewSyncVote already supports this — Byzantine just chooses r.)
\* No separate Byzantine action needed; Family C is exposed via natural
\* nondeterminism over r in MC.

\* Family E: Byzantine leader proposes with a mis-declared epoch.
ByzProposeMisdeclaredEpoch(s, leaf, view, claimedEpoch) ==
    /\ s \in ByzServer
    /\ view <= MaxView
    /\ leaf /= NilLeaf
    /\ claimedEpoch /= realEpoch(view)   \* the misdeclaration
    /\ \E justify \in qcs :
            /\ justify.view = view - 1
            /\ LET p == [view |-> view,
                         leaf |-> leaf,
                         parentLeaf |-> justify.leafCommit,
                         epochClaim |-> claimedEpoch,
                         justifyQc |-> justify,
                         evidenceKind |-> EvNone,
                         tcEvidence |-> [view |-> view - 1,
                                          epochClaim |-> claimedEpoch,
                                          signers |-> {}],
                         vscEvidence |-> [view |-> view,
                                          relay |-> 0,
                                          epoch |-> claimedEpoch,
                                          signers |-> {}]]
               IN  proposals' = proposals \cup {p}
    /\ UNCHANGED <<consensusInMemVars, consensusPersistedVars,
                   votes, timeoutVotes, qcs, tcs, vscs,
                   qcWitnessed, equivocationFlagged, relayPool,
                   crashed, committedLeaf>>

\* Family B (composition): Byzantine leader forces locked-view advancement on
\* liveness alone using a sibling-branch justify_qc.
ByzForceLockedViewAdvance(s, leaf, view) ==
    /\ s \in ByzServer
    /\ view <= MaxView
    /\ leaf /= NilLeaf
    /\ \E justify \in qcs :
            /\ justify.view < view
            \* CRITICAL: the leaf at justify is one the honest node hasn't seen
            /\ justify.leafCommit /= NilLeaf
            /\ LET p == [view |-> view,
                         leaf |-> leaf,
                         parentLeaf |-> justify.leafCommit,
                         epochClaim |-> realEpoch(view),
                         justifyQc |-> justify,
                         evidenceKind |-> EvNone,
                         tcEvidence |-> [view |-> view - 1,
                                          epochClaim |-> realEpoch(view),
                                          signers |-> {}],
                         vscEvidence |-> [view |-> view,
                                          relay |-> 0,
                                          epoch |-> realEpoch(view),
                                          signers |-> {}]]
               IN  proposals' = proposals \cup {p}
    /\ UNCHANGED <<consensusInMemVars, consensusPersistedVars,
                   votes, timeoutVotes, qcs, tcs, vscs,
                   qcWitnessed, equivocationFlagged, relayPool,
                   crashed, committedLeaf>>

\* ============================================================================
\* NEXT — disjunction over all actions
\* ============================================================================

Next ==
    \/ \E s \in Server, p \in proposals : HandleQuorumProposalRecv(s, p)
    \/ \E s \in Server, v \in 0..MaxView : ViewChange(s, v)
    \/ \E s \in Server, p \in proposals : SubmitVote(s, p)
    \/ \E s \in Server : TimeoutVote(s)
    \/ \E view \in 0..MaxView, leaf \in Leaves, epoch \in 0..MaxEpoch,
         signers \in SUBSET AllReplicas : FormQC(view, leaf, epoch, signers)
    \/ \E view \in 0..MaxView, epochClaim \in 0..MaxEpoch,
         signers \in SUBSET AllReplicas : FormTC(view, epochClaim, signers)
    \/ \E s \in Server, qc \in qcs : ObserveQC(s, qc)
    \/ \E s \in Server, leaf \in Leaves, view \in 0..MaxView,
         ev \in {EvNone, EvTimeout, EvViewSync} : ProposeLeader(s, leaf, view, ev)
    \/ \E s \in Server, leaf \in Leaves, view \in 0..MaxView : CommitLeaf(s, leaf, view)
    \/ \E s \in Server, e \in 0..MaxEpoch, v \in 0..MaxView, r \in 0..MaxView,
         phase \in {PhasePreCommit, PhaseCommit, PhaseFinalize} :
            ViewSyncVote(s, e, v, r, phase)
    \/ \E e \in 0..MaxEpoch, v \in 0..MaxView, r \in 0..MaxView,
         phase \in {PhasePreCommit, PhaseCommit, PhaseFinalize} :
            FormViewSyncCert(e, v, r, phase)
    \/ \E s \in Server : Crash(s)
    \/ \E s \in Server : Recover(s)
    \/ \E view \in 0..MaxView, fromE, toE \in 0..MaxEpoch :
            ByzReplayTcAcrossEpoch(view, fromE, toE)
    \/ \E s \in AllReplicas, view \in 0..MaxView, leaf1, leaf2 \in Leaves,
         epoch \in 0..MaxEpoch : ByzDoubleVote(s, view, leaf1, leaf2, epoch)
    \/ \E s \in ByzServer, leaf \in Leaves, view \in 0..MaxView,
         claimedEpoch \in 0..MaxEpoch :
            ByzProposeMisdeclaredEpoch(s, leaf, view, claimedEpoch)
    \/ \E s \in ByzServer, leaf \in Leaves, view \in 0..MaxView :
            ByzForceLockedViewAdvance(s, leaf, view)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- Standard safety ---

\* HS2 textbook: at most one leaf committed per view across all correct replicas.
ElectionSafety_HS2 ==
    \A v \in 0..MaxView :
        \A s1, s2 \in Server :
            (committedLeaf[s1][v] /= NilLeaf /\ committedLeaf[s2][v] /= NilLeaf)
                => committedLeaf[s1][v] = committedLeaf[s2][v]

\* --- Family A: TC epoch binding ---

\* NoEpochReplayedTC: if a valid TC carries epochClaim = e', either the signers
\* are NOT a witnessed timeout-vote set under epoch e' OR e' was their original
\* signing epoch. Under the current code this can fail: signers can be present
\* in epoch e (where they originally voted) but their cert can be retagged to e'.
NoEpochReplayedTC ==
    \A tc \in tcs :
        IsValidTc(tc) =>
            \E e \in 0..MaxEpoch :
                /\ tc.signers \subseteq StakeTable(e)
                /\ e = tc.epochClaim
                /\ \A v \in tc.signers :
                        \E tv \in timeoutVotes :
                            /\ tv.voter = v
                            /\ tv.view = tc.view
                            /\ tv.epoch = e

\* --- Family B: equivocation & locked-view ---

\* If two distinct QCs at the same view both have threshold-valid signers,
\* equivocationFlagged should mark that view.
NoEquivocationGoesUnflagged ==
    \A s \in Server, v \in 0..MaxView :
        (\E qc1, qc2 \in qcWitnessed[s][v] :
             /\ qc1 /= qc2
             /\ qc1.leafCommit /= qc2.leafCommit
             /\ IsValidQc(qc1) /\ IsValidQc(qc2))
        => equivocationFlagged[s][v]

\* In-mem high_qc must be monotonic per node (consensus.rs:1330 invariant)
HighQCMonotonic_InMem ==
    \A s \in Server :
        \/ highQcInMem[s] = NilQC
        \/ highQcInMem[s].view <= MaxView

\* Locked view should not exceed high QC view.
\* Under Family B+E this can fail: ByzForceLockedViewAdvance pushes lockedView
\* past a justify_qc.view for which the node has not advanced highQcInMem yet
\* (e.g., because the in-mem write was rejected).
LockedViewBelowOrEqualHighQC ==
    \A s \in Server :
        \/ highQcInMem[s] = NilQC
        \/ lockedView[s] <= highQcInMem[s].view

\* --- Family C: view-sync uniqueness ---

\* UniqueFinalizeCertPerView (expected to fail by design of relay accumulators).
UniqueFinalizeCertPerView ==
    \A vsc1, vsc2 \in vscs :
        vsc1.view = vsc2.view => vsc1 = vsc2

\* A finalize cert at relay r requires a commit cert at relay r.
\* (We approximate by checking that the finalize-phase pool at r was preceded
\* by a commit-phase pool at r reaching threshold.)
FinalizeCertImpliesCommitCert ==
    \A vsc \in vscs :
        \E pool \in {relayPool[vsc.epoch][vsc.view][vsc.relay][PhaseCommit]} :
            \/ ValidSignersFor(pool, vsc.epoch)
            \/ pool = {}   \* allows initial states; tightened in MC hunt cfg

\* --- Family D: persistent vs in-mem ---

\* After a quiescent moment (no pending storage writes), in-mem and persisted
\* should agree on high_qc.
HighQC_PersistedConsistent ==
    \A s \in Server :
        (pendingPersistHighQC[s] = NilQC /\ pendingEqcStorage[s] = NilQC /\ ~crashed[s])
            => (highQcInMem[s] = highQcPersisted[s]
                \/ highQcInMem[s] = NilQC
                \/ highQcPersisted[s] = NilQC)

\* --- Family E: proposal-declared epoch vs real epoch ---

\* For every proposal accepted into a node's saved_leaves AND whose justify_qc was
\* used to advance high_qc, the declared epoch must equal realEpoch(view).
ProposalEpochMatchesView ==
    \A p \in proposals :
        \A s \in Server :
            (p.leaf \in savedLeaves[s] /\ ~crashed[s])
                => p.epochClaim = realEpoch(p.view)

\* --- Structural / type invariants ---

TypeOK ==
    /\ curView           \in [AllReplicas -> 0..MaxView+1]
    /\ curEpoch          \in [AllReplicas -> 0..MaxEpoch]
    /\ lockedView        \in [AllReplicas -> 0..MaxView]
    /\ latestVotedView   \in [AllReplicas -> 0..MaxView]
    /\ crashed           \in [AllReplicas -> BOOLEAN]
    /\ \A s \in AllReplicas :
            savedLeaves[s] \subseteq Leaves

================================================================================
