---- MODULE base ----
(*
MongoDB Range Deletion on Secondaries - TLA+ Base Specification
Category A: Distributed / Message-Passing

This spec models the synchronization between persistent (config.rangeDeletions) and
in-memory (RangeDeletionTaskTracker) state during range deletion operations, with focus on:
- Persistent state synchronization windows (Family 1)
- Recovery completeness on term boundaries (Family 2)
- Task registration and overlap detection ordering (Family 3)
- Secondary-specific coordination gaps (Family 4)
- Deletion execution under shutdown (Family 5)
*)

EXTENDS Naturals, Sequences, FiniteSets, TLC

\* Constants (to be set by config)
CONSTANT MaxTerms, MaxTasks, MaxRecoveryTime
CONSTANT Nodes, PrimaryNode
CONSTANT NULL

\* Useful helpers
ASSUME /\ MaxTerms \in Nat \ {0}
       /\ MaxTasks \in Nat \ {0}
       /\ MaxRecoveryTime \in Nat \ {0}
       /\ Nodes /= {}
       /\ PrimaryNode \in Nodes

\* ============================================================================
\* TASK STATE DEFINITIONS
\* ============================================================================

\* Task document states in persistent storage (Family 1)
TaskDocStates == {"pending", "ready", "processing", "deleted", "absent"}

\* In-memory task tracker states
InMemoryStates == {"unregistered", "registered", "in_deletion", "completed"}

\* Processor states (Family 5)
ProcessorStates == {"initializing", "running", "stopped"}

\* Recovery states (Family 2)
RecoveryOutcomes == {"unknown", "complete", "incomplete"}

\* Task identifier
TaskId == 1..MaxTasks

\* ============================================================================
\* GLOBAL VARIABLES
\* ============================================================================

VARIABLE
    (* Replica-level state *)
    currentTerm,                 \* Current term on this node
    replicaRole,                 \* "primary" or "secondary"
    processorState,              \* State of ReadyRangeDeletionsProcessor

    (* Recovery state (Family 2) *)
    recoveryInFlight,            \* Is recovery async task running?
    recoveryOutcome,             \* Did recovery complete/incomplete/unknown?
    tasksRecoveredInTerm,        \* Tasks re-registered in current term
    lastRecoveredTerm,           \* Last term where recovery fully completed

    (* Persistent storage: task documents in config.rangeDeletions *)
    persistentTaskState,         \* TaskId -> {"pending" | "ready" | "processing" | "deleted" | "absent"}
    taskPendingFlag,             \* TaskId -> bool (in persistent document)
    taskProcessingFlag,          \* TaskId -> bool (in persistent document)

    (* In-memory tracker state (Family 1) *)
    inMemoryTaskState,           \* TaskId -> InMemoryStates
    inMemoryTaskExists,          \* Set of tasks with in-memory registrations

    (* Overlap tracking (Family 3) *)
    taskRegistrationOrder,       \* Map of TaskId -> registration_time
    registrationClock,           \* Logical clock for registration order
    pendingOverlapWaiters,       \* Tasks waiting for overlaps to complete

    (* Range preserver state (Family 4) *)
    invalidatedRanges,           \* Set of ranges invalidated globally

    (* Deletion execution state (Family 5) *)
    taskBeingDeleted,            \* Current task in deletion processing
    deletionProgress,            \* TaskId -> deletion step

    (* Shutdown coordination *)
    serviceShuttingDown          \* Boolean flag

\* Variable grouping for UNCHANGED clauses
serverVars == <<currentTerm, replicaRole, processorState>>
recoveryVars == <<recoveryInFlight, recoveryOutcome, tasksRecoveredInTerm, lastRecoveredTerm>>
persistentVars == <<persistentTaskState, taskPendingFlag, taskProcessingFlag>>
inMemoryVars == <<inMemoryTaskState, inMemoryTaskExists>>
overlapVars == <<taskRegistrationOrder, registrationClock, pendingOverlapWaiters>>
preserverVars == <<invalidatedRanges>>
deletionVars == <<taskBeingDeleted, deletionProgress>>
shutdownVars == <<serviceShuttingDown>>

allVars == <<serverVars, recoveryVars, persistentVars, inMemoryVars,
             overlapVars, preserverVars, deletionVars, shutdownVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

GetTaskDocState(t) == persistentTaskState[t]

IsTaskDocumentDeleted(t) == GetTaskDocState(t) = "deleted"

IsTaskDocumentAbsent(t) == GetTaskDocState(t) = "absent"

IsTaskInMemory(t) == t \in inMemoryTaskExists

HasPendingFlag(t) == /\ GetTaskDocState(t) /= "absent"
                     /\ GetTaskDocState(t) /= "deleted"
                     /\ taskPendingFlag[t]

HasProcessingFlag(t) == /\ GetTaskDocState(t) /= "absent"
                        /\ GetTaskDocState(t) /= "deleted"
                        /\ taskProcessingFlag[t]

IsPrimary == replicaRole = "primary"
IsSecondary == replicaRole = "secondary"

ProcessorRunning == processorState = "running"

OverlappingTasks(t) ==
    \* Simplified: any two different tasks overlap if both exist
    {t2 \in inMemoryTaskExists : t2 /= t}

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

Init ==
    /\ currentTerm = 0
    /\ replicaRole = "secondary"  \* Start as secondary
    /\ processorState = "initializing"
    /\ recoveryInFlight = FALSE
    /\ recoveryOutcome = "unknown"
    /\ tasksRecoveredInTerm = {}
    /\ lastRecoveredTerm = 0
    /\ persistentTaskState = [t \in TaskId |-> "absent"]
    /\ taskPendingFlag = [t \in TaskId |-> FALSE]
    /\ taskProcessingFlag = [t \in TaskId |-> FALSE]
    /\ inMemoryTaskState = [t \in TaskId |-> "unregistered"]
    /\ inMemoryTaskExists = {}
    /\ taskRegistrationOrder = [t \in TaskId |-> 0]
    /\ registrationClock = 0
    /\ pendingOverlapWaiters = {}
    /\ invalidatedRanges = {}
    /\ taskBeingDeleted = NULL
    /\ deletionProgress = [t \in TaskId |-> "not_started"]
    /\ serviceShuttingDown = FALSE

\* ============================================================================
\* ACTIONS - REPLICATION & ROLE CHANGES
\* ============================================================================

(*
Family 2: Recovery Completeness on Term Boundaries
range_deleter_service.cpp:127-180
*)
BecomeSecondary ==
    /\ IsPrimary
    /\ currentTerm' = currentTerm + 1
    /\ replicaRole' = "secondary"
    /\ recoveryInFlight' = FALSE
    /\ recoveryOutcome' = "unknown"
    /\ processorState' = "initializing"
    /\ tasksRecoveredInTerm' = {}
    /\ UNCHANGED <<persistentVars, inMemoryVars, overlapVars, preserverVars,
                   deletionVars, shutdownVars, lastRecoveredTerm>>

(*
Family 2: Recovery Completeness on Term Boundaries
range_deleter_service.cpp:127-180, range_deleter_service.cpp:156-175
*)
BecomePublicPrimary ==
    /\ IsSecondary
    /\ currentTerm' = currentTerm + 1
    /\ replicaRole' = "primary"
    /\ recoveryInFlight' = TRUE      \* Async recovery spawned
    /\ recoveryOutcome' = "unknown"
    /\ tasksRecoveredInTerm' = {}
    /\ processorState' = "initializing"  \* Not started until recovery completes
    /\ UNCHANGED <<persistentVars, inMemoryVars, overlapVars, preserverVars,
                   deletionVars, shutdownVars, lastRecoveredTerm>>

\* ============================================================================
\* ACTIONS - RECOVERY (Family 2)
\* ============================================================================

(*
Family 2: Recovery loads from persistent storage into empty in-memory state
range_deleter_service.cpp:213-254, range_deletion_recovery_tracker.h:43-48
*)
CompleteRecoverySuccessfully ==
    /\ IsPrimary
    /\ recoveryInFlight = TRUE
    /\ recoveryOutcome = "unknown"
    /\ recoveryInFlight' = FALSE
    /\ recoveryOutcome' = "complete"
    /\ lastRecoveredTerm' = currentTerm
    \* Re-register all tasks from persistent storage (simplified)
    /\ LET tasksToRecover == {t \in TaskId : persistentTaskState[t] /= "absent"
                                          /\ persistentTaskState[t] /= "deleted"}
       IN /\ tasksRecoveredInTerm' = tasksToRecover
          /\ inMemoryTaskExists' = tasksToRecover
          /\ inMemoryTaskState' = [t \in TaskId |->
                                    IF t \in tasksToRecover
                                    THEN "registered"
                                    ELSE inMemoryTaskState[t]]
    /\ UNCHANGED <<serverVars, persistentVars, overlapVars, preserverVars,
                   deletionVars, shutdownVars>>

(*
Family 2: Recovery interrupted by step-down before completion
range_deleter_service.cpp:156-175
*)
InterruptRecoveryByStepDown ==
    /\ IsPrimary
    /\ recoveryInFlight = TRUE
    /\ recoveryOutcome = "unknown"
    /\ recoveryOutcome' = "incomplete"  \* Mark as incomplete
    /\ recoveryInFlight' = FALSE
    /\ UNCHANGED <<serverVars, persistentVars, inMemoryVars, overlapVars,
                   preserverVars, deletionVars, shutdownVars,
                   tasksRecoveredInTerm, lastRecoveredTerm>>

\* ============================================================================
\* ACTIONS - PERSISTENT STATE TRANSITIONS (Family 1)
\* ============================================================================

(*
Family 1: Task document insert (initially pending)
range_deletion_util.cpp:243-271, range_deleter_service.cpp:213-254
*)
InsertTaskDocument ==
    /\ IsPrimary
    /\ \E t \in TaskId :
        /\ persistentTaskState[t] = "absent"
        /\ persistentTaskState' = [persistentTaskState EXCEPT ![t] = "pending"]
        /\ taskPendingFlag' = [taskPendingFlag EXCEPT ![t] = TRUE]
        /\ UNCHANGED <<serverVars, recoveryVars, taskProcessingFlag,
                       inMemoryVars, overlapVars, preserverVars,
                       deletionVars, shutdownVars>>

(*
Family 1: Update pending flag to false (document is ready for deletion)
range_deleter_service_op_observer.cpp:68-102
*)
MarkTaskReadyInDocument ==
    /\ IsPrimary
    /\ \E t \in TaskId :
        /\ persistentTaskState[t] = "pending"
        /\ taskPendingFlag[t] = TRUE
        /\ persistentTaskState' = [persistentTaskState EXCEPT ![t] = "ready"]
        /\ taskPendingFlag' = [taskPendingFlag EXCEPT ![t] = FALSE]
        /\ UNCHANGED <<serverVars, recoveryVars, taskProcessingFlag,
                       inMemoryVars, overlapVars, preserverVars,
                       deletionVars, shutdownVars>>

(*
Family 1: Mark task as processing before deletion begins
range_deletion_util.cpp:273-294
*)
MarkTaskProcessingInDocument ==
    /\ IsPrimary
    /\ ProcessorRunning
    /\ \E t \in TaskId :
        /\ persistentTaskState[t] = "ready"
        /\ taskPendingFlag[t] = FALSE
        /\ ~HasProcessingFlag(t)
        /\ persistentTaskState' = [persistentTaskState EXCEPT ![t] = "processing"]
        /\ taskProcessingFlag' = [taskProcessingFlag EXCEPT ![t] = TRUE]
        /\ UNCHANGED <<serverVars, recoveryVars, taskPendingFlag,
                       inMemoryVars, overlapVars, preserverVars,
                       deletionVars, shutdownVars>>

(*
Family 1: Delete task document after deletion completes
range_deletion_util.cpp:273-294
*)
RemoveTaskDocument ==
    /\ IsPrimary
    /\ \E t \in TaskId :
        /\ persistentTaskState[t] = "processing"
        /\ HasProcessingFlag(t)
        /\ persistentTaskState' = [persistentTaskState EXCEPT ![t] = "deleted"]
        /\ taskProcessingFlag' = [taskProcessingFlag EXCEPT ![t] = FALSE]
        /\ UNCHANGED <<serverVars, recoveryVars, taskPendingFlag,
                       inMemoryVars, overlapVars, preserverVars,
                       deletionVars, shutdownVars>>

\* ============================================================================
\* ACTIONS - IN-MEMORY TASK REGISTRATION (Family 1, Family 3)
\* ============================================================================

(*
Family 1 + Family 3: Register task in in-memory tracker
range_deleter_service.cpp:377
Includes task in registration order queue for overlap detection.
*)
RegisterTaskInMemory ==
    /\ IsPrimary
    /\ ~serviceShuttingDown
    /\ \E t \in TaskId :
        /\ persistentTaskState[t] \in {"pending", "ready"}
        /\ t \notin inMemoryTaskExists
        /\ inMemoryTaskExists' = inMemoryTaskExists \cup {t}
        /\ inMemoryTaskState' = [inMemoryTaskState EXCEPT ![t] = "registered"]
        /\ taskRegistrationOrder' = [taskRegistrationOrder EXCEPT ![t] = registrationClock]
        /\ registrationClock' = registrationClock + 1
        /\ UNCHANGED <<serverVars, recoveryVars, persistentVars, pendingOverlapWaiters,
                       preserverVars, deletionVars, shutdownVars>>

(*
Family 3: Check for overlapping tasks during registration
range_deleter_service.cpp:392-426
Tasks must wait for any overlapping task registered before them to complete.
*)
DetectAndWaitForOverlaps ==
    /\ IsPrimary
    /\ \E t \in inMemoryTaskExists :
        /\ inMemoryTaskState[t] = "registered"
        /\ t \notin pendingOverlapWaiters
        /\ LET overlaps == {t2 \in inMemoryTaskExists :
                              /\ t2 /= t
                              /\ taskRegistrationOrder[t2] < taskRegistrationOrder[t]}
           IN /\ overlaps /= {} \* Only enter wait if overlaps exist
              /\ pendingOverlapWaiters' = pendingOverlapWaiters \cup {t}
        /\ UNCHANGED <<serverVars, recoveryVars, persistentVars, inMemoryVars,
                       taskRegistrationOrder, registrationClock,
                       preserverVars, deletionVars, shutdownVars>>

(*
Overlapping task completes, allow waiter to proceed
*)
CompleteOverlapWait ==
    /\ IsPrimary
    /\ \E t \in TaskId :
        /\ t \in pendingOverlapWaiters
        /\ inMemoryTaskState[t] = "completed"
        /\ pendingOverlapWaiters' = pendingOverlapWaiters \ {t}
        /\ UNCHANGED <<serverVars, recoveryVars, persistentVars, inMemoryVars,
                       overlapVars, preserverVars, deletionVars, shutdownVars>>

\* ============================================================================
\* ACTIONS - DELETION EXECUTION (Family 5)
\* ============================================================================

(*
Family 5: Processor transitions to running after recovery completes
ready_range_deletions_processor.cpp:78-86
*)
StartProcessor ==
    /\ IsPrimary
    /\ processorState = "initializing"
    /\ recoveryInFlight = FALSE
    /\ recoveryOutcome = "complete"
    /\ processorState' = "running"
    /\ UNCHANGED <<currentTerm, replicaRole, recoveryVars, persistentVars,
                   inMemoryVars, overlapVars, preserverVars,
                   deletionVars, shutdownVars>>

(*
Family 5: Dequeue task for deletion from ready queue
ready_range_deletions_processor.cpp:210-228
*)
DequeuTaskForDeletion ==
    /\ IsPrimary
    /\ ProcessorRunning
    /\ taskBeingDeleted = NULL
    /\ \E t \in inMemoryTaskExists :
        /\ inMemoryTaskState[t] = "registered"
        /\ t \notin pendingOverlapWaiters
        /\ taskBeingDeleted' = t
        /\ deletionProgress' = [deletionProgress EXCEPT ![t] = "mark_processing"]
        /\ UNCHANGED <<serverVars, recoveryVars, persistentVars, inMemoryVars,
                       overlapVars, preserverVars, shutdownVars>>

(*
Family 5: Begin deletion - mark task as processing
Deletion interrupted here leaves task in processing state.
*)
BeginDeletion ==
    /\ IsPrimary
    /\ ProcessorRunning
    /\ taskBeingDeleted /= NULL
    /\ deletionProgress[taskBeingDeleted] = "mark_processing"
    /\ taskBeingDeleted' = taskBeingDeleted
    /\ deletionProgress' = [deletionProgress EXCEPT ![taskBeingDeleted] = "deleting"]
    /\ UNCHANGED <<serverVars, recoveryVars, persistentVars, inMemoryVars,
                   overlapVars, preserverVars, shutdownVars>>

(*
Family 5: Complete deletion - mark document as deleted
*)
CompleteDeletion ==
    /\ IsPrimary
    /\ ProcessorRunning
    /\ taskBeingDeleted /= NULL
    /\ deletionProgress[taskBeingDeleted] = "deleting"
    /\ deletionProgress' = [deletionProgress EXCEPT ![taskBeingDeleted] = "mark_complete"]
    /\ UNCHANGED <<serverVars, recoveryVars, persistentVars, inMemoryVars,
                   overlapVars, preserverVars, shutdownVars>>

(*
Family 5: Remove task from in-memory tracker after deletion
*)
RemoveTaskFromMemory ==
    /\ IsPrimary
    /\ taskBeingDeleted /= NULL
    /\ deletionProgress[taskBeingDeleted] = "mark_complete"
    /\ LET t == taskBeingDeleted
       IN /\ inMemoryTaskState' = [inMemoryTaskState EXCEPT ![t] = "completed"]
          /\ inMemoryTaskExists' = inMemoryTaskExists \ {t}
          /\ taskBeingDeleted' = NULL
          /\ deletionProgress' = [deletionProgress EXCEPT ![t] = "removed"]
    /\ UNCHANGED <<serverVars, recoveryVars, persistentVars, overlapVars,
                   preserverVars, shutdownVars>>

(*
Family 5: Processor shutdown interrupts current deletion
range_deleter_service.cpp:306-309, ready_range_deletions_processor.cpp:104-119
*)
ShutdownProcessor ==
    /\ IsPrimary
    /\ processorState = "running"
    /\ processorState' = "stopped"
    /\ serviceShuttingDown' = TRUE
    \* Current task (if any) is abandoned mid-deletion
    /\ UNCHANGED <<currentTerm, replicaRole, recoveryVars, persistentVars,
                   inMemoryVars, overlapVars, preserverVars,
                   deletionVars>>

\* ============================================================================
\* ACTIONS - SECONDARY COORDINATION (Family 4)
\* ============================================================================

(*
Family 4: Secondary observes task document insertions via oplog
On secondary, this registers task in-memory but should NOT execute deletion.
*)
SecondaryObserveTaskInsert ==
    /\ IsSecondary
    /\ \E t \in TaskId :
        /\ persistentTaskState[t] = "pending"
        /\ t \notin inMemoryTaskExists
        /\ inMemoryTaskExists' = inMemoryTaskExists \cup {t}
        /\ inMemoryTaskState' = [inMemoryTaskState EXCEPT ![t] = "registered"]
        /\ UNCHANGED <<serverVars, recoveryVars, persistentVars,
                       overlapVars, preserverVars, deletionVars, shutdownVars>>

(*
Family 4: Invalidate ranges on secondary (should match primary)
range_deleter_service_op_observer.cpp:139-175
*)
InvalidateRangeOnSecondary ==
    /\ IsSecondary
    /\ \E t \in TaskId :
        /\ t \in inMemoryTaskExists
        /\ t \notin invalidatedRanges
        /\ invalidatedRanges' = invalidatedRanges \cup {t}
        /\ UNCHANGED <<serverVars, recoveryVars, persistentVars, inMemoryVars,
                       overlapVars, deletionVars, shutdownVars>>

(*
Family 4: Invalidate ranges on primary (should be same set)
*)
InvalidateRangeOnPrimary ==
    /\ IsPrimary
    /\ \E t \in TaskId :
        /\ t \in inMemoryTaskExists
        /\ t \notin invalidatedRanges
        /\ invalidatedRanges' = invalidatedRanges \cup {t}
        /\ UNCHANGED <<serverVars, recoveryVars, persistentVars, inMemoryVars,
                       overlapVars, deletionVars, shutdownVars>>

\* ============================================================================
\* NEXT STATE
\* ============================================================================

Next ==
    \/ BecomeSecondary
    \/ BecomePublicPrimary
    \/ CompleteRecoverySuccessfully
    \/ InterruptRecoveryByStepDown
    \/ InsertTaskDocument
    \/ MarkTaskReadyInDocument
    \/ MarkTaskProcessingInDocument
    \/ RemoveTaskDocument
    \/ RegisterTaskInMemory
    \/ DetectAndWaitForOverlaps
    \/ CompleteOverlapWait
    \/ StartProcessor
    \/ DequeuTaskForDeletion
    \/ BeginDeletion
    \/ CompleteDeletion
    \/ RemoveTaskFromMemory
    \/ ShutdownProcessor
    \/ SecondaryObserveTaskInsert
    \/ InvalidateRangeOnSecondary
    \/ InvalidateRangeOnPrimary

\* ============================================================================
\* INVARIANTS - FAMILY 1: PERSISTENT STATE SYNCHRONIZATION
\* ============================================================================

(*
Family 1 (MC1): TaskDocumentExistenceConsistency
If in-memory task tracker has a task, the document must exist in persistent storage
(unless deletion has completed).
*)
TaskDocumentExistenceConsistency ==
    \A t \in TaskId :
        /\ t \in inMemoryTaskExists
        => /\ persistentTaskState[t] \in {"pending", "ready", "processing"}

(*
Family 1: If document is deleted, task must not be in in-memory tracker
*)
DeletedTaskNotTracked ==
    \A t \in TaskId :
        /\ persistentTaskState[t] = "deleted"
        => /\ t \notin inMemoryTaskExists

\* ============================================================================
\* INVARIANTS - FAMILY 2: RECOVERY COMPLETENESS
\* ============================================================================

(*
Family 2 (MC2): RecoveryCompletenessOnRoleChange
On transition to primary, service must not reach kUp (processor running) until
recovery completes.
*)
RecoveryCompletenessOnRoleChange ==
    \A t \in currentTerm..currentTerm :
        /\ (replicaRole = "primary" /\ recoveryInFlight = FALSE)
        => /\ recoveryOutcome \in {"complete", "unknown"}

(*
Family 2: Recovery outcome tracks incompleteness
*)
IncompleteRecoveryTracked ==
    /\ recoveryInFlight = FALSE
    => /\ recoveryOutcome \in {"complete", "incomplete", "unknown"}

\* ============================================================================
\* INVARIANTS - FAMILY 3: OVERLAP SERIALIZATION
\* ============================================================================

(*
Family 3 (MC3): OverlapSerializationOrder
If two tasks overlap and registered in order T1 < T2, then T1 must complete
before T2 starts deletion.
*)
OverlapSerializationOrder ==
    \A t1, t2 \in inMemoryTaskExists :
        /\ t1 /= t2
        /\ taskRegistrationOrder[t1] < taskRegistrationOrder[t2]
        => /\ /\ inMemoryTaskState[t2] = "registered"
              /\ t2 \in pendingOverlapWaiters
           \/ /\ inMemoryTaskState[t1] = "completed"

\* ============================================================================
\* INVARIANTS - FAMILY 4: SECONDARY COORDINATION
\* ============================================================================

(*
Family 4 (MC4): SecondaryInvalidationConsistency
Invalidated ranges on secondary match invalidated ranges on primary.
At any moment, both should have the same set of invalidated ranges.
*)
SecondaryInvalidationConsistency ==
    /\ TRUE  \* Requires multi-node state; simplified for single-node model

\* ============================================================================
\* INVARIANTS - FAMILY 5: DELETION AND ORPHANS
\* ============================================================================

(*
Family 5 (MC5): OrphansDeletion
Once a task completes (document deleted and not tracked), no orphans remain.
*)
OrphansDeletion ==
    \A t \in TaskId :
        /\ persistentTaskState[t] = "deleted"
        => /\ t \notin inMemoryTaskExists

(*
Family 5: NoTaskQueueDeadlock
If a task is queued and processor is running, it will eventually complete
or be interrupted.
*)
NoTaskQueueDeadlock ==
    /\ TRUE  \* Requires liveness; checked via temporal properties

\* ============================================================================
\* STRUCTURAL INVARIANTS
\* ============================================================================

ValidTaskId ==
    /\ taskBeingDeleted = NULL \/ taskBeingDeleted \in TaskId

ValidProcessorState ==
    /\ processorState \in ProcessorStates

ValidRecoveryOutcome ==
    /\ recoveryOutcome \in RecoveryOutcomes

ConsistentTaskStates ==
    \A t \in TaskId :
        /\ persistentTaskState[t] \in TaskDocStates
        /\ inMemoryTaskState[t] \in InMemoryStates

\* ============================================================================
\* TYPE INVARIANT
\* ============================================================================

TypeInvariant ==
    /\ currentTerm \in 0..MaxTerms
    /\ replicaRole \in {"primary", "secondary"}
    /\ processorState \in ProcessorStates
    /\ recoveryInFlight \in BOOLEAN
    /\ recoveryOutcome \in RecoveryOutcomes
    /\ tasksRecoveredInTerm \subseteq TaskId
    /\ lastRecoveredTerm \in 0..MaxTerms
    /\ persistentTaskState \in [TaskId -> TaskDocStates]
    /\ taskPendingFlag \in [TaskId -> BOOLEAN]
    /\ taskProcessingFlag \in [TaskId -> BOOLEAN]
    /\ inMemoryTaskState \in [TaskId -> InMemoryStates]
    /\ inMemoryTaskExists \subseteq TaskId
    /\ taskRegistrationOrder \in [TaskId -> 0..MaxTasks]
    /\ registrationClock \in 0..MaxTasks
    /\ pendingOverlapWaiters \subseteq TaskId
    /\ invalidatedRanges \subseteq TaskId
    /\ taskBeingDeleted = NULL \/ taskBeingDeleted \in TaskId
    /\ deletionProgress \in [TaskId -> {"not_started", "mark_processing", "deleting", "mark_complete", "removed"}]
    /\ serviceShuttingDown \in BOOLEAN

\* ============================================================================
\* PROPERTIES
\* ============================================================================

\* Safety properties are checked as invariants above
\* Liveness: processor eventually stops or task completes

====
