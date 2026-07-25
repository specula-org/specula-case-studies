--------------------------- MODULE MC ---------------------------
(*
 * Model-checking wrapper for HotShot (Espresso Network) base spec.
 *
 * Wraps fault-injection actions with per-action counters and adds bounds suitable
 * for exhaustive state-space exploration. The base spec describes WHAT the
 * adversary can do; this MC spec bounds HOW OFTEN.
 *
 * Hunt configs (MC_hunt_<family>.cfg) tighten irrelevant bounds to 0-1 and check
 * only the targeted bug-family invariant + ElectionSafety_HS2.
 *)

EXTENDS base, Integers, FiniteSets, Sequences, TLC

\* ============================================================================
\* COUNTERS — one per fault-injection action
\* ============================================================================

VARIABLE faultCtrs
\* faultCtrs is a record:
\*   crash               : count of Crash actions
\*   tcReplay            : count of ByzReplayTcAcrossEpoch
\*   doubleVote          : count of ByzDoubleVote
\*   misdeclaredEpoch    : count of ByzProposeMisdeclaredEpoch
\*   forceLockedAdvance  : count of ByzForceLockedViewAdvance
\*   timeout             : count of TimeoutVote (introducing non-determinism)
\*   recover             : count of Recover

\* ============================================================================
\* CONSTANTS — fault bounds
\* ============================================================================

CONSTANT MaxCrash
CONSTANT MaxTcReplay
CONSTANT MaxDoubleVote
CONSTANT MaxMisdeclaredEpoch
CONSTANT MaxForceLockedAdvance
CONSTANT MaxTimeoutVote
CONSTANT MaxRecover
CONSTANT MaxQcs         \* cap on |qcs| to bound state space
CONSTANT MaxTcs         \* cap on |tcs|
CONSTANT MaxVscs        \* cap on |vscs|
CONSTANT MaxProposals   \* cap on |proposals|

\* ============================================================================
\* MCInit / Init
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCtrs = [crash              |-> 0,
                    tcReplay           |-> 0,
                    doubleVote         |-> 0,
                    misdeclaredEpoch   |-> 0,
                    forceLockedAdvance |-> 0,
                    timeout            |-> 0,
                    recover            |-> 0]

\* ============================================================================
\* BOUNDED FAULT-INJECTION WRAPPERS
\* ============================================================================

MCCrash(n) ==
    /\ faultCtrs.crash < MaxCrash
    /\ Crash(n)
    /\ faultCtrs' = [faultCtrs EXCEPT !.crash = @ + 1]

MCRecover(n) ==
    /\ faultCtrs.recover < MaxRecover
    /\ Recover(n)
    /\ faultCtrs' = [faultCtrs EXCEPT !.recover = @ + 1]

MCTimeoutVote(s) ==
    /\ faultCtrs.timeout < MaxTimeoutVote
    /\ TimeoutVote(s)
    /\ faultCtrs' = [faultCtrs EXCEPT !.timeout = @ + 1]

MCByzReplayTcAcrossEpoch(view, fromE, toE) ==
    /\ faultCtrs.tcReplay < MaxTcReplay
    /\ ByzReplayTcAcrossEpoch(view, fromE, toE)
    /\ faultCtrs' = [faultCtrs EXCEPT !.tcReplay = @ + 1]

MCByzDoubleVote(s, view, leaf1, leaf2, epoch) ==
    /\ faultCtrs.doubleVote < MaxDoubleVote
    /\ ByzDoubleVote(s, view, leaf1, leaf2, epoch)
    /\ faultCtrs' = [faultCtrs EXCEPT !.doubleVote = @ + 1]

MCByzProposeMisdeclaredEpoch(s, leaf, view, claimedEpoch) ==
    /\ faultCtrs.misdeclaredEpoch < MaxMisdeclaredEpoch
    /\ ByzProposeMisdeclaredEpoch(s, leaf, view, claimedEpoch)
    /\ faultCtrs' = [faultCtrs EXCEPT !.misdeclaredEpoch = @ + 1]

MCByzForceLockedViewAdvance(s, leaf, view) ==
    /\ faultCtrs.forceLockedAdvance < MaxForceLockedAdvance
    /\ ByzForceLockedViewAdvance(s, leaf, view)
    /\ faultCtrs' = [faultCtrs EXCEPT !.forceLockedAdvance = @ + 1]

\* ============================================================================
\* UNBOUNDED REACTIVE ACTIONS — pass through with faultCtrs unchanged
\* ============================================================================

MCHandleQuorumProposalRecv(s, p) ==
    /\ HandleQuorumProposalRecv(s, p)
    /\ UNCHANGED faultCtrs

MCViewChange(s, v) ==
    /\ ViewChange(s, v)
    /\ UNCHANGED faultCtrs

MCSubmitVote(s, p) ==
    /\ SubmitVote(s, p)
    /\ UNCHANGED faultCtrs

MCFormQC(view, leaf, epoch, signers) ==
    /\ Cardinality(qcs) < MaxQcs
    /\ FormQC(view, leaf, epoch, signers)
    /\ UNCHANGED faultCtrs

MCFormTC(view, epochClaim, signers) ==
    /\ Cardinality(tcs) < MaxTcs
    /\ FormTC(view, epochClaim, signers)
    /\ UNCHANGED faultCtrs

MCObserveQC(s, qc) ==
    /\ ObserveQC(s, qc)
    /\ UNCHANGED faultCtrs

MCProposeLeader(s, leaf, view, ev) ==
    /\ Cardinality(proposals) < MaxProposals
    /\ ProposeLeader(s, leaf, view, ev)
    /\ UNCHANGED faultCtrs

MCCommitLeaf(s, leaf, view) ==
    /\ CommitLeaf(s, leaf, view)
    /\ UNCHANGED faultCtrs

MCViewSyncVote(s, e, v, r, phase) ==
    /\ ViewSyncVote(s, e, v, r, phase)
    /\ UNCHANGED faultCtrs

MCFormViewSyncCert(e, v, r, phase) ==
    /\ Cardinality(vscs) < MaxVscs
    /\ FormViewSyncCert(e, v, r, phase)
    /\ UNCHANGED faultCtrs

\* ============================================================================
\* MCNext
\* ============================================================================

MCNext ==
    \/ \E s \in Server, p \in proposals : MCHandleQuorumProposalRecv(s, p)
    \/ \E s \in Server, v \in 0..MaxView : MCViewChange(s, v)
    \/ \E s \in Server, p \in proposals : MCSubmitVote(s, p)
    \/ \E s \in Server : MCTimeoutVote(s)
    \/ \E view \in 0..MaxView, leaf \in Leaves, epoch \in 0..MaxEpoch,
         signers \in SUBSET AllReplicas : MCFormQC(view, leaf, epoch, signers)
    \/ \E view \in 0..MaxView, epochClaim \in 0..MaxEpoch,
         signers \in SUBSET AllReplicas : MCFormTC(view, epochClaim, signers)
    \/ \E s \in Server, qc \in qcs : MCObserveQC(s, qc)
    \/ \E s \in Server, leaf \in Leaves, view \in 0..MaxView,
         ev \in {EvNone, EvTimeout, EvViewSync} : MCProposeLeader(s, leaf, view, ev)
    \/ \E s \in Server, leaf \in Leaves, view \in 0..MaxView :
            MCCommitLeaf(s, leaf, view)
    \/ \E s \in Server, e \in 0..MaxEpoch, v \in 0..MaxView, r \in 0..MaxView,
         phase \in {PhasePreCommit, PhaseCommit, PhaseFinalize} :
            MCViewSyncVote(s, e, v, r, phase)
    \/ \E e \in 0..MaxEpoch, v \in 0..MaxView, r \in 0..MaxView,
         phase \in {PhasePreCommit, PhaseCommit, PhaseFinalize} :
            MCFormViewSyncCert(e, v, r, phase)
    \/ \E s \in Server : MCCrash(s)
    \/ \E s \in Server : MCRecover(s)
    \/ \E view \in 0..MaxView, fromE, toE \in 0..MaxEpoch :
            MCByzReplayTcAcrossEpoch(view, fromE, toE)
    \/ \E s \in AllReplicas, view \in 0..MaxView, leaf1, leaf2 \in Leaves,
         epoch \in 0..MaxEpoch : MCByzDoubleVote(s, view, leaf1, leaf2, epoch)
    \/ \E s \in ByzServer, leaf \in Leaves, view \in 0..MaxView,
         claimedEpoch \in 0..MaxEpoch :
            MCByzProposeMisdeclaredEpoch(s, leaf, view, claimedEpoch)
    \/ \E s \in ByzServer, leaf \in Leaves, view \in 0..MaxView :
            MCByzForceLockedViewAdvance(s, leaf, view)

MCSpec == MCInit /\ [][MCNext]_<<vars, faultCtrs>>

\* ============================================================================
\* SYMMETRY — permutation over honest servers only (Byzantine names are distinct
\* roles, not symmetric).
\* ============================================================================

ServerSymmetry == Permutations(Server)

\* ============================================================================
\* STATE-SPACE PRUNING (view filter)
\* ============================================================================

MCView ==
    << curView, curEpoch, highQcInMem, highQcPersisted, lockedView,
       latestVotedView, savedLeaves, transitionQc,
       proposals, votes, timeoutVotes, qcs, tcs, vscs,
       qcWitnessed, equivocationFlagged, relayPool, crashed, committedLeaf >>

\* ============================================================================
\* STRUCTURAL INVARIANTS for MC
\* ============================================================================

\* Bound counters
MCFaultCtrsBounded ==
    /\ faultCtrs.crash              <= MaxCrash
    /\ faultCtrs.tcReplay           <= MaxTcReplay
    /\ faultCtrs.doubleVote         <= MaxDoubleVote
    /\ faultCtrs.misdeclaredEpoch   <= MaxMisdeclaredEpoch
    /\ faultCtrs.forceLockedAdvance <= MaxForceLockedAdvance
    /\ faultCtrs.timeout            <= MaxTimeoutVote
    /\ faultCtrs.recover            <= MaxRecover

\* No QC has more signers than the stake table of its epoch.
QcSignersWithinStakeTable ==
    \A qc \in qcs : qc.signers \subseteq StakeTable(qc.epoch)

MCTypeOK ==
    /\ TypeOK
    /\ faultCtrs.crash              \in 0..MaxCrash
    /\ faultCtrs.tcReplay           \in 0..MaxTcReplay
    /\ faultCtrs.doubleVote         \in 0..MaxDoubleVote
    /\ faultCtrs.misdeclaredEpoch   \in 0..MaxMisdeclaredEpoch
    /\ faultCtrs.forceLockedAdvance \in 0..MaxForceLockedAdvance
    /\ faultCtrs.timeout            \in 0..MaxTimeoutVote
    /\ faultCtrs.recover            \in 0..MaxRecover

================================================================================
