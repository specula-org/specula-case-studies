---- MODULE MC ----
(*
MongoDB Range Deletion on Secondaries - Model Checking Spec
Wraps base.tla with counter-bounded fault-injection actions.
*)

EXTENDS Naturals, Sequences, FiniteSets, TLC, base

\* ============================================================================
\* FAULT INJECTION COUNTERS
\* ============================================================================

VARIABLE faultCounters

faultVars == <<faultCounters>>

\* Initialize fault counters
InitFaultCounters ==
    /\ faultCounters = [recoveryInterrupt |-> 0, taskLoss |-> 0, shutdownDuringDeletion |-> 0, registerDelay |-> 0, overlapDetectionFailure |-> 0]

MCInit ==
    /\ Init
    /\ InitFaultCounters

\* ============================================================================
\* WRAPPER ACTIONS - BOUNDED FAULT INJECTION
\* ============================================================================

\* Recovery interruption fault (Family 2)
MCInterruptRecoveryByStepDown ==
    /\ faultCounters.recoveryInterrupt < 2
    /\ InterruptRecoveryByStepDown
    /\ faultCounters' = [faultCounters EXCEPT !.recoveryInterrupt = @ + 1]

\* Task loss during persistent-to-in-memory sync window (Family 1)
MCTaskLossWindow ==
    /\ faultCounters.taskLoss < 2
    /\ \E t \in TaskId :
        /\ persistentTaskState[t] \in {"pending", "ready"}
        /\ t \in inMemoryTaskExists
        /\ inMemoryTaskExists' = inMemoryTaskExists \ {t}
        /\ inMemoryTaskState' = [inMemoryTaskState EXCEPT ![t] = "unregistered"]
    /\ UNCHANGED <<serverVars, recoveryVars, persistentVars, overlapVars,
                   preserverVars, deletionVars, shutdownVars>>
    /\ faultCounters' = [faultCounters EXCEPT !.taskLoss = @ + 1]

\* Shutdown during deletion (Family 5)
MCShutdownDuringDeletion ==
    /\ faultCounters.shutdownDuringDeletion < 2
    /\ IsPrimary
    /\ processorState = "running"
    /\ taskBeingDeleted /= NULL
    /\ taskBeingDeleted' = NULL
    /\ processorState' = "stopped"
    /\ serviceShuttingDown' = TRUE
    /\ UNCHANGED <<currentTerm, replicaRole, recoveryVars, persistentVars,
                   inMemoryVars, overlapVars, preserverVars,
                   deletionVars>>
    /\ faultCounters' = [faultCounters EXCEPT !.shutdownDuringDeletion = @ + 1]

\* Delay task registration (Family 3)
MCRegisterTaskDelay ==
    /\ faultCounters.registerDelay < 3
    /\ IsPrimary
    /\ \E t \in TaskId :
        /\ persistentTaskState[t] = "pending"
        /\ t \notin inMemoryTaskExists
        \* Force multiple registration attempts to delay by just returning
    /\ UNCHANGED allVars
    /\ faultCounters' = [faultCounters EXCEPT !.registerDelay = @ + 1]

\* Overlap detection failure (Family 3)
MCOverlapDetectionFailure ==
    /\ faultCounters.overlapDetectionFailure < 1
    /\ IsPrimary
    /\ \E t \in inMemoryTaskExists :
        /\ inMemoryTaskState[t] = "registered"
        /\ t \in pendingOverlapWaiters
        \* Allow task to proceed without waiting
        /\ pendingOverlapWaiters' = pendingOverlapWaiters \ {t}
    /\ UNCHANGED <<serverVars, recoveryVars, persistentVars, inMemoryVars,
                   taskRegistrationOrder, registrationClock, preserverVars,
                   deletionVars, shutdownVars>>
    /\ faultCounters' = [faultCounters EXCEPT !.overlapDetectionFailure = @ + 1]

\* ============================================================================
\* CONSTRAINED WRAPPERS - DETERMINISTIC ACTIONS (NO FAULT INJECTION)
\* ============================================================================

MCBecomeSecondary == /\ BecomeSecondary /\ UNCHANGED faultCounters
MCBecomePublicPrimary == /\ BecomePublicPrimary /\ UNCHANGED faultCounters
MCCompleteRecoverySuccessfully == /\ CompleteRecoverySuccessfully /\ UNCHANGED faultCounters
MCInsertTaskDocument == /\ InsertTaskDocument /\ UNCHANGED faultCounters
MCMarkTaskReadyInDocument == /\ MarkTaskReadyInDocument /\ UNCHANGED faultCounters
MCMarkTaskProcessingInDocument == /\ MarkTaskProcessingInDocument /\ UNCHANGED faultCounters
MCRemoveTaskDocument == /\ RemoveTaskDocument /\ UNCHANGED faultCounters
MCRegisterTaskInMemory == /\ RegisterTaskInMemory /\ UNCHANGED faultCounters
MCDetectAndWaitForOverlaps == /\ DetectAndWaitForOverlaps /\ UNCHANGED faultCounters
MCCompleteOverlapWait == /\ CompleteOverlapWait /\ UNCHANGED faultCounters
MCStartProcessor == /\ StartProcessor /\ UNCHANGED faultCounters
MCDequeuTaskForDeletion == /\ DequeuTaskForDeletion /\ UNCHANGED faultCounters
MCBeginDeletion == /\ BeginDeletion /\ UNCHANGED faultCounters
MCCompleteDeletion == /\ CompleteDeletion /\ UNCHANGED faultCounters
MCRemoveTaskFromMemory == /\ RemoveTaskFromMemory /\ UNCHANGED faultCounters
MCShutdownProcessor == /\ ShutdownProcessor /\ UNCHANGED faultCounters
MCSecondaryObserveTaskInsert == /\ SecondaryObserveTaskInsert /\ UNCHANGED faultCounters
MCInvalidateRangeOnSecondary == /\ InvalidateRangeOnSecondary /\ UNCHANGED faultCounters
MCInvalidateRangeOnPrimary == /\ InvalidateRangeOnPrimary /\ UNCHANGED faultCounters

\* ============================================================================
\* NEXT STATE - UNIFIED
\* ============================================================================

MCNext ==
    \/ MCBecomeSecondary
    \/ MCBecomePublicPrimary
    \/ MCCompleteRecoverySuccessfully
    \/ MCInterruptRecoveryByStepDown
    \/ MCInsertTaskDocument
    \/ MCMarkTaskReadyInDocument
    \/ MCMarkTaskProcessingInDocument
    \/ MCRemoveTaskDocument
    \/ MCRegisterTaskInMemory
    \/ MCDetectAndWaitForOverlaps
    \/ MCCompleteOverlapWait
    \/ MCStartProcessor
    \/ MCDequeuTaskForDeletion
    \/ MCBeginDeletion
    \/ MCCompleteDeletion
    \/ MCRemoveTaskFromMemory
    \/ MCShutdownProcessor
    \/ MCSecondaryObserveTaskInsert
    \/ MCInvalidateRangeOnSecondary
    \/ MCInvalidateRangeOnPrimary
    \/ MCTaskLossWindow
    \/ MCShutdownDuringDeletion
    \/ MCRegisterTaskDelay
    \/ MCOverlapDetectionFailure

\* ============================================================================
\* SYMMETRY
\* ============================================================================

\* Tasks are symmetric; ignore fault counter in symmetry
Symmetry == Permutations(TaskId)

\* ============================================================================
\* INVARIANTS FOR MC
\* ============================================================================

\* Standard safety invariants from base spec
SafetyInvariants ==
    /\ TaskDocumentExistenceConsistency
    /\ DeletedTaskNotTracked
    /\ OrphansDeletion
    /\ ConsistentTaskStates
    /\ TypeInvariant

\* Family-specific invariants (commented out for standard MC.cfg, enabled in hunt configs)

(*
Family 2: RecoveryCompletenessOnRoleChange
*)
Family2_RecoveryCompletes ==
    \A t \in currentTerm..currentTerm :
        /\ (replicaRole = "primary" /\ recoveryInFlight = FALSE)
        => /\ recoveryOutcome \in {"complete", "unknown"}

(*
Family 3: OverlapSerializationOrder
*)
Family3_OverlapSerialization ==
    \A t1, t2 \in inMemoryTaskExists :
        /\ t1 /= t2
        /\ taskRegistrationOrder[t1] < taskRegistrationOrder[t2]
        => /\ /\ inMemoryTaskState[t2] = "registered"
              /\ t2 \in pendingOverlapWaiters
           \/ /\ inMemoryTaskState[t1] = "completed"

(*
Family 5: Deletion progress tracking
*)
Family5_DeletionProgress ==
    \A t \in TaskId :
        /\ t \in inMemoryTaskExists
        /\ inMemoryTaskState[t] = "in_deletion"
        => /\ deletionProgress[t] \in {"mark_processing", "deleting"}

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* Recovery eventually completes or is interrupted
RecoveryEventually ==
    <>(recoveryInFlight = FALSE)

\* Task eventually completes or processor shuts down
TaskEventuallyCompletes ==
    <>(taskBeingDeleted = NULL)

====
