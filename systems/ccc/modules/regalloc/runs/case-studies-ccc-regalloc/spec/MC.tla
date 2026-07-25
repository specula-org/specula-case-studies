---- MODULE MC ----
(***************************************************************************)
(* Model checking wrapper for the CCC regalloc + liveness base spec.       *)
(*                                                                          *)
(* The base spec is mostly sequential — phase advances monotonically and    *)
(* most non-determinism is structural (which value/register/slot is chosen *)
(* next). The only fault-injection-style action is DataflowCapHit, which   *)
(* triggers Bug Family 1 (F3). All other bug families are exercised by    *)
(* configuring the input function (CONSTANTS) appropriately:               *)
(*   - F1 / Family 1, 3:  set AsmHasOperands[p] = FALSE on an asm point   *)
(*                        whose AsmClobbers[p] includes a caller-saved reg *)
(*                        and where some value is TRUE-alive at p.        *)
(*   - F2 / Family 1:     set IsRecognizedReturnsTwice[p] = FALSE on a    *)
(*                        ReturnsTwice point with values live at p.       *)
(*   - F3 / Family 1:     set MaxIters small enough that the dataflow can *)
(*                        fail to converge (forces DataflowCapHit).       *)
(*   - F4 / Family 2:     manifest as NoSlotCollision violation triggered *)
(*                        by F1 or F3 under-approximation.                *)
(*   - F5 / Family 2:     intentionally make CalleeSavedRegs and           *)
(*                        CallerSavedRegs overlap.                        *)
(***************************************************************************)

EXTENDS base

\* ========================================================================
\* Counter limits for fault-injection-style actions
\* ========================================================================

CONSTANTS
    DataflowCapLimit    \* How many DataflowCapHit firings to allow (0 or 1).

\* ========================================================================
\* Counter variables
\* ========================================================================

VARIABLE capHitCount     \* Number of times DataflowCapHit has fired.

mcVars == <<capHitCount>>

\* ========================================================================
\* Counter-bounded fault-injection wrappers
\* ========================================================================

\* MCDataflowCapHit — the only true "fault" action in the pipeline.
\* Bound by DataflowCapLimit (typically 0 in MC.cfg, 1 in MC_hunt_F3.cfg).
MCDataflowCapHit ==
    /\ capHitCount < DataflowCapLimit
    /\ DataflowCapHit
    /\ capHitCount' = capHitCount + 1

\* ========================================================================
\* Reactive (unbounded) action wrappers
\* ========================================================================

MCAssignProgramPoints == AssignProgramPoints /\ UNCHANGED mcVars
MCDataflowIterStep    == DataflowIterStep    /\ UNCHANGED mcVars
MCExtendIntervals     == ExtendIntervalsFromLiveness /\ UNCHANGED mcVars
MCBuildIntervals      == BuildIntervals      /\ UNCHANGED mcVars
MCPhase1Allocate(v, r) == Phase1Allocate(v, r) /\ UNCHANGED mcVars
MCPhase1Done          == Phase1Done           /\ UNCHANGED mcVars
MCPhase2Allocate(v, r) == Phase2Allocate(v, r) /\ UNCHANGED mcVars
MCPhase2Done          == Phase2Done           /\ UNCHANGED mcVars
MCPhase3Allocate(v, r) == Phase3Allocate(v, r) /\ UNCHANGED mcVars
MCPhase3Done          == Phase3Done           /\ UNCHANGED mcVars
MCAssignSlot(v, s)    == AssignSlot(v, s)    /\ UNCHANGED mcVars
MCPackSlotsDone       == PackSlotsDone       /\ UNCHANGED mcVars

\* ========================================================================
\* Init and Next
\* ========================================================================

MCInit ==
    /\ Init
    /\ capHitCount = 0

MCNext ==
    \/ MCAssignProgramPoints
    \/ MCDataflowIterStep
    \/ MCDataflowCapHit
    \/ MCExtendIntervals
    \/ MCBuildIntervals
    \/ \E v \in Vals, r \in CalleeSavedRegs : MCPhase1Allocate(v, r)
    \/ MCPhase1Done
    \/ \E v \in Vals, r \in CallerSavedRegs : MCPhase2Allocate(v, r)
    \/ MCPhase2Done
    \/ \E v \in Vals, r \in CalleeSavedRegs : MCPhase3Allocate(v, r)
    \/ MCPhase3Done
    \/ \E v \in Vals, s \in Slots : MCAssignSlot(v, s)
    \/ MCPackSlotsDone

MCSpec == MCInit /\ [][MCNext]_<<allVars, mcVars>>

\* ========================================================================
\* Symmetry — values, registers, and slots are interchangeable when their
\* roles are symmetric. We DO NOT use symmetry on Vals here because each
\* value has distinct TrueDef/TrueUses (constants), so symmetry reduction
\* is unsafe. CalleeSavedRegs and CallerSavedRegs are interchangeable
\* within their pools (use_regs preference is a heuristic we abstract).
\* ========================================================================

Symmetry == Permutations(Slots)

\* ========================================================================
\* State constraint — bound runaway exploration
\* ========================================================================

StateConstraint ==
    /\ iter <= MaxIters
    /\ capHitCount <= DataflowCapLimit

\* ========================================================================
\* Invariants — re-export from base
\* ========================================================================

\* --- Standard / structural ---
MCPoolDisjointness         == PoolDisjointness
MCValidPhases              == ValidPhases
MCAssignmentDomain         == AssignmentDomain
MCSlotDomain               == SlotDomain
MCRecordedCallPointsSubset == RecordedCallPointsSubset
MCUsedRegsConsistency      == UsedRegsConsistency
MCIterCap                  == IterCap

\* --- Bug-family extension invariants ---
MCNoRegisterCollision              == NoRegisterCollision
MCNoSlotCollision                  == NoSlotCollision
MCCallerSavedDeadAcrossCall        == CallerSavedDeadAcrossCall
MCCallerSavedDeadAcrossAsmClobber  == CallerSavedDeadAcrossAsmClobber
MCReturnsTwiceLiveExtension        == ReturnsTwiceLiveExtension
MCFixpointReachedBeforeUse         == FixpointReachedBeforeUse
MCIntervalSoundness                == IntervalSoundness

\* ========================================================================
\* Temporal property — pipeline always terminates
\* ========================================================================

EventuallyDone == <>(phase = "Done")

\* ========================================================================
\* Operator forms for CONSTANTS (TLC config parser rejects function-literal
\* values, so every non-set constant is provided via an operator override).
\* The default shape models a 2-block function with one real call at point 2:
\*   v1 defined at 0, v2 defined at 1, both used at 2 (so both span the call).
\* Hunt configs override these with scenario-specific operators.
\* ========================================================================

BlockOfPointOp == (0 :> 0 @@ 1 :> 0 @@ 2 :> 1)
BlockSuccsOp   == (0 :> {1} @@ 1 :> {})
TrueDefOp      == (1 :> 0 @@ 2 :> 1)
TrueUsesOp     == (1 :> {2} @@ 2 :> {2})
AsmHasOperandsOp == << >>
AsmClobbersOp    == << >>
IsRecognizedReturnsTwiceOp == << >>
PriorityOp     == (1 :> 1 @@ 2 :> 1)

====
