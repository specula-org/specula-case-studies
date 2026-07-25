---- MODULE Trace ----
(*
MongoDB Range Deletion on Secondaries - Trace Validation Spec
Validates recorded execution traces against base.tla
*)

EXTENDS Naturals, Sequences, FiniteSets, TLC, Json

\* Constants (to be set by config)
CONSTANT MaxTerms, MaxTasks, MaxRecoveryTime
CONSTANT Nodes, PrimaryNode
CONSTANT NULL

\* Variables from base spec
VARIABLE
    currentTerm, replicaRole, processorState,
    recoveryInFlight, recoveryOutcome, tasksRecoveredInTerm, lastRecoveredTerm,
    persistentTaskState, taskPendingFlag, taskProcessingFlag,
    inMemoryTaskState, inMemoryTaskExists,
    taskRegistrationOrder, registrationClock, pendingOverlapWaiters,
    invalidatedRanges,
    taskBeingDeleted, deletionProgress,
    serviceShuttingDown

\* Import base spec
INSTANCE base WITH MaxTerms <- MaxTerms, MaxTasks <- MaxTasks, MaxRecoveryTime <- MaxRecoveryTime,
                    Nodes <- Nodes, PrimaryNode <- PrimaryNode, NULL <- NULL,
                    currentTerm <- currentTerm, replicaRole <- replicaRole, processorState <- processorState,
                    recoveryInFlight <- recoveryInFlight, recoveryOutcome <- recoveryOutcome,
                    tasksRecoveredInTerm <- tasksRecoveredInTerm, lastRecoveredTerm <- lastRecoveredTerm,
                    persistentTaskState <- persistentTaskState, taskPendingFlag <- taskPendingFlag, taskProcessingFlag <- taskProcessingFlag,
                    inMemoryTaskState <- inMemoryTaskState, inMemoryTaskExists <- inMemoryTaskExists,
                    taskRegistrationOrder <- taskRegistrationOrder, registrationClock <- registrationClock, pendingOverlapWaiters <- pendingOverlapWaiters,
                    invalidatedRanges <- invalidatedRanges,
                    taskBeingDeleted <- taskBeingDeleted, deletionProgress <- deletionProgress,
                    serviceShuttingDown <- serviceShuttingDown

\* ============================================================================
\* TRACE LOADING AND CURSOR
\* ============================================================================

\* Trace is loaded from JSON file (NDJSON format)
VARIABLE l  \* Cursor: current line in trace

traceVars == <<l>>

\* Combined variables for specification
vars == <<allVars, traceVars>>

\* Load trace from JSON file
JsonFile == "../traces/trace.ndjson"

\* Parse trace lines (helper to deserialize NDJSON)
TraceLog == ndJsonDeserialize(JsonFile)

GetTraceEvent(idx) ==
    IF idx \in DOMAIN TraceLog THEN TraceLog[idx] ELSE NULL

\* ============================================================================
\* TRACE BOOTSTRAP
\* ============================================================================

\* Initialize from trace file's first state
TraceInit ==
    /\ Init  \* Initialize all base variables first
    /\ l = 1  \* Initialize trace cursor
    /\ \* Override with trace values if present
       IF Len(TraceLog) > 0
       THEN
           /\ currentTerm = TraceLog[1].currentTerm
           /\ replicaRole = TraceLog[1].replicaRole
           /\ processorState = TraceLog[1].processorState
           /\ recoveryInFlight = TraceLog[1].recoveryInFlight
           /\ recoveryOutcome = TraceLog[1].recoveryOutcome
           /\ inMemoryTaskExists = TraceLog[1].inMemoryTaskExists
           /\ persistentTaskState = TraceLog[1].persistentTaskState
           /\ IF "tasksRecoveredInTerm" \in DOMAIN TraceLog[1]
              THEN tasksRecoveredInTerm = TraceLog[1].tasksRecoveredInTerm
              ELSE TRUE
       ELSE TRUE

\* ============================================================================
\* EVENT MATCHING HELPERS
\* ============================================================================

IsEvent(name) == /\ l <= Len(TraceLog)
                 /\ TraceLog[l].eventName = name

IsNodeEvent(name, node) == /\ IsEvent(name)
                           /\ TraceLog[l].node = node

IsTaskEvent(name, task) == /\ IsEvent(name)
                           /\ TraceLog[l].taskId = task

\* ============================================================================
\* VALIDATION HELPERS
\* ============================================================================

\* Validate that state matches trace at cursor position
ValidatePostState ==
    LET logline == TraceLog[l] IN
    /\ IF "currentTerm" \in DOMAIN logline
       THEN currentTerm = logline.currentTerm
       ELSE TRUE
    /\ IF "replicaRole" \in DOMAIN logline
       THEN replicaRole = logline.replicaRole
       ELSE TRUE
    /\ IF "processorState" \in DOMAIN logline
       THEN processorState = logline.processorState
       ELSE TRUE
    /\ IF "persistentTaskState" \in DOMAIN logline
       THEN persistentTaskState = logline.persistentTaskState
       ELSE TRUE
    /\ IF "inMemoryTaskExists" \in DOMAIN logline
       THEN inMemoryTaskExists = logline.inMemoryTaskExists
       ELSE TRUE

\* ============================================================================
\* ACTION WRAPPERS - TRACE EVENT MATCHING
\* ============================================================================

\* Family 2: BecomePublicPrimary event
TraceBecomePrimary ==
    /\ IsEvent("BecomePublicPrimary")
    /\ BecomePublicPrimary
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 2: CompleteRecoverySuccessfully event
TraceCompleteRecovery ==
    /\ IsEvent("CompleteRecoverySuccessfully")
    /\ CompleteRecoverySuccessfully
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 2: InterruptRecoveryByStepDown event
TraceInterruptRecovery ==
    /\ IsEvent("InterruptRecoveryByStepDown")
    /\ InterruptRecoveryByStepDown
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 1: InsertTaskDocument event
TraceInsertTaskDocument ==
    /\ IsEvent("InsertTaskDocument")
    /\ InsertTaskDocument
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 1: MarkTaskReady event
TraceMarkTaskReady ==
    /\ IsEvent("MarkTaskReady")
    /\ MarkTaskReadyInDocument
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 1: MarkTaskProcessing event
TraceMarkTaskProcessing ==
    /\ IsEvent("MarkTaskProcessing")
    /\ MarkTaskProcessingInDocument
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 1: RemoveTaskDocument event
TraceRemoveTaskDocument ==
    /\ IsEvent("RemoveTaskDocument")
    /\ RemoveTaskDocument
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 3: RegisterTaskInMemory event
TraceRegisterTaskInMemory ==
    /\ IsEvent("RegisterTaskInMemory")
    /\ RegisterTaskInMemory
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 3: DetectAndWaitForOverlaps event
TraceDetectOverlaps ==
    /\ IsEvent("DetectAndWaitForOverlaps")
    /\ DetectAndWaitForOverlaps
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 5: StartProcessor event
TraceStartProcessor ==
    /\ IsEvent("StartProcessor")
    /\ StartProcessor
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 5: DequeuTaskForDeletion event
TraceDequeuTask ==
    /\ IsEvent("DequeuTaskForDeletion")
    /\ DequeuTaskForDeletion
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 5: BeginDeletion event
TraceBeginDeletion ==
    /\ IsEvent("BeginDeletion")
    /\ BeginDeletion
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 5: CompleteDeletion event
TraceCompleteDeletion ==
    /\ IsEvent("CompleteDeletion")
    /\ CompleteDeletion
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 5: RemoveTaskFromMemory event
TraceRemoveTaskFromMemory ==
    /\ IsEvent("RemoveTaskFromMemory")
    /\ RemoveTaskFromMemory
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 5: ShutdownProcessor event
TraceShutdownProcessor ==
    /\ IsEvent("ShutdownProcessor")
    /\ ShutdownProcessor
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 4: SecondaryObserveTaskInsert event
TraceSecondaryObserveTaskInsert ==
    /\ IsEvent("SecondaryObserveTaskInsert")
    /\ SecondaryObserveTaskInsert
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 4: InvalidateRangeOnSecondary event
TraceInvalidateRangeSecondary ==
    /\ IsEvent("InvalidateRangeOnSecondary")
    /\ InvalidateRangeOnSecondary
    /\ ValidatePostState
    /\ l' = l + 1

\* Family 4: InvalidateRangeOnPrimary event
TraceInvalidateRangePrimary ==
    /\ IsEvent("InvalidateRangeOnPrimary")
    /\ InvalidateRangeOnPrimary
    /\ ValidatePostState
    /\ l' = l + 1

\* ============================================================================
\* SILENT ACTIONS - IMPLEMENTATION STATE CHANGES WITHOUT TRACE EVENTS
\* ============================================================================

\* Secondary role change (may not be directly traced)
SilentBecomeSecondary ==
    /\ l <= Len(TraceLog)
    /\ BecomeSecondary
    /\ UNCHANGED <<allVars, l>>

\* Overlap wait completion (internal event, may not trace)
SilentCompleteOverlapWait ==
    /\ l <= Len(TraceLog)
    /\ pendingOverlapWaiters /= {}
    /\ CompleteOverlapWait
    /\ UNCHANGED <<allVars, l>>

\* ============================================================================
\* TRACE NEXT - ALL POSSIBLE EVENTS
\* ============================================================================

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ \/ TraceBecomePrimary
          \/ TraceCompleteRecovery
          \/ TraceInterruptRecovery
          \/ TraceInsertTaskDocument
          \/ TraceMarkTaskReady
          \/ TraceMarkTaskProcessing
          \/ TraceRemoveTaskDocument
          \/ TraceRegisterTaskInMemory
          \/ TraceDetectOverlaps
          \/ TraceStartProcessor
          \/ TraceDequeuTask
          \/ TraceBeginDeletion
          \/ TraceCompleteDeletion
          \/ TraceRemoveTaskFromMemory
          \/ TraceShutdownProcessor
          \/ TraceSecondaryObserveTaskInsert
          \/ TraceInvalidateRangeSecondary
          \/ TraceInvalidateRangePrimary
    \/ /\ l <= Len(TraceLog)
       /\ \/ SilentBecomeSecondary
          \/ SilentCompleteOverlapWait
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED <<allVars, traceVars>>

\* ============================================================================
\* COMPLETION PROPERTY
\* ============================================================================

\* Temporal property: trace must be fully consumed (all events matched)
TraceMatched == <>(l > Len(TraceLog))

TraceFullyConsumed == l > Len(TraceLog)

====
