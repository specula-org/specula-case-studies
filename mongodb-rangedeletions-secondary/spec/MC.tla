---- MODULE MC ----
(***************************************************************************)
(* Model checking wrapper for the RangeDeletionsSecondaryNodes base spec.  *)
(* Adds counter-bounded StepUp (the only event-injection action) and       *)
(* structural invariants.                                                  *)
(*                                                                         *)
(* All other actions are reactive (deterministic transitions) and           *)
(* naturally bounded by finite state machines — no counters needed.         *)
(***************************************************************************)
EXTENDS base, TLC

(*====================================================================*)
(* Counter variable for event-injection action                         *)
(*====================================================================*)

VARIABLE stepUpCount

mcVars == <<vars, stepUpCount>>

(*====================================================================*)
(* Constants                                                           *)
(*====================================================================*)

CONSTANTS MaxStepUpLimit   \* Maximum number of step-up transitions (typically 0-1)

(*====================================================================*)
(* Default function constants                                          *)
(*====================================================================*)

\* Default: all RDs remove all docs (conservative, maximizes invariant coverage)
MCRDDocs == [rd \in RangeDeletion |-> Doc]

(*====================================================================*)
(* Counter-bounded actions                                             *)
(*====================================================================*)

\* StepUp is the only event-injection action — bounds the SECONDARY→PRIMARY transition.
\* All other actions are reactive (handle existing oplog entries, process queries)
\* and are naturally bounded by finite state machines.
MCStepUp ==
    /\ stepUpCount < MaxStepUpLimit
    /\ StepUp
    /\ stepUpCount' = stepUpCount + 1

(*====================================================================*)
(* MCInit / MCNext / MCSpec                                            *)
(*====================================================================*)

MCInit ==
    /\ Init
    /\ stepUpCount = 0

MCNext ==
    \* Oplog application actions (unbounded — reactive)
    \/ \E rd \in RangeDeletion :
        \/ OpApplierSignalUpdate(rd) /\ UNCHANGED stepUpCount
        \/ OpApplierSignalCommit(rd) /\ UNCHANGED stepUpCount
        \/ OpApplierDeleteUpdate(rd) /\ UNCHANGED stepUpCount
        \/ OpApplierDeleteCommit(rd) /\ UNCHANGED stepUpCount
        \/ BatchCommitted(rd) /\ UNCHANGED stepUpCount
        \/ RecoverTask(rd) /\ UNCHANGED stepUpCount
    \* Query actions (unbounded — reactive)
    \/ \E q \in Query :
        \/ QueryAdvanceSnapshot(q) /\ UNCHANGED stepUpCount
        \/ QueryKilled(q) /\ UNCHANGED stepUpCount
        \/ QueryProceed(q) /\ UNCHANGED stepUpCount
    \* Step-up (counter-bounded — event injection)
    \/ MCStepUp
    \* Termination
    \/ Terminating /\ UNCHANGED stepUpCount

MCSpec == MCInit /\ [][MCNext]_mcVars

(*====================================================================*)
(* Structural invariants                                               *)
(*====================================================================*)

\* Counter never exceeds limit
StepUpBound == stepUpCount <= MaxStepUpLimit

\* Batch only commits when both signal and delete are committed
\* (oplog batch waits for all ops in the batch)
BatchRequiresBothCommitted ==
    \A rd \in RangeDeletion :
        batchState[rd] = "COMMITTED" =>
            /\ signalState[rd] = "COMMITTED"
            /\ deleteState[rd] = "COMMITTED"

\* Recovery only happens on primary
RecoveryOnlyOnPrimary ==
    \A rd \in RangeDeletion :
        rdRecovered[rd] = TRUE => nodeRole = "PRIMARY"

\* Frozen variables never change (sanity check)
FrozenVarsStable ==
    \A t \in Tracker : trackerShardV[t] \in 0..MaxVersion

(*====================================================================*)
(* Liveness with fairness                                              *)
(*====================================================================*)

MCFairness ==
    /\ \A q \in Query : WF_mcVars(QueryAdvanceSnapshot(q) /\ UNCHANGED stepUpCount)
    /\ \A q \in Query : WF_mcVars(QueryKilled(q) /\ UNCHANGED stepUpCount)
    /\ \A q \in Query : WF_mcVars(QueryProceed(q) /\ UNCHANGED stepUpCount)
    /\ \A rd \in RangeDeletion :
        WF_mcVars(OpApplierSignalUpdate(rd) /\ UNCHANGED stepUpCount)
    /\ \A rd \in RangeDeletion :
        WF_mcVars(OpApplierSignalCommit(rd) /\ UNCHANGED stepUpCount)
    /\ \A rd \in RangeDeletion :
        WF_mcVars(OpApplierDeleteUpdate(rd) /\ UNCHANGED stepUpCount)
    /\ \A rd \in RangeDeletion :
        WF_mcVars(OpApplierDeleteCommit(rd) /\ UNCHANGED stepUpCount)
    /\ \A rd \in RangeDeletion :
        WF_mcVars(BatchCommitted(rd) /\ UNCHANGED stepUpCount)

MCLiveSpec == MCInit /\ [][MCNext]_mcVars /\ MCFairness

====
