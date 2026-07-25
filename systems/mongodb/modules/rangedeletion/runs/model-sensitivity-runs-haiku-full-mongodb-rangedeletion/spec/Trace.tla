---- MODULE Trace ----
(* Trace Validation Spec for MongoDB Range Deletion Service

   Validates that real execution traces conform to the base spec.

   Trace events are matched to spec actions with complete post-state validation.
   Silent actions handle state changes without observable events.
*)

EXTENDS base, TLC, Json

(* Trace loading - events in JSON format *)
VARIABLE
    l,          \* Trace cursor: index into TraceLog
    TraceLog    \* Loaded trace events

(* Helper to load trace - override via IOEnv in per-run config *)
TraceFile ==
    IF "JSON" \in DOMAIN IOEnv
    THEN IOEnv.JSON
    ELSE "../traces/test_basic.ndjson"

(* Initialize trace from file *)
TraceInit ==
    /\ l = 1
    /\ TraceLog = ndJsonDeserialize(TraceFile)
    /\ Init

(* Extract current logline *)
CurrentLogline ==
    IF l <= Len(TraceLog) THEN TraceLog[l] ELSE [event |-> "END"]

(* Event predicate helpers *)
IsEvent(name) == CurrentLogline.event = name

IsNodeEvent(name, node) ==
    /\ IsEvent(name)
    /\ CurrentLogline.node = node

IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ CurrentLogline.from = from
    /\ CurrentLogline.to = to

(* ===== ACTION WRAPPERS WITH POST-STATE VALIDATION ===== *)

(* ref: range_deleter_service.cpp:156-173 *)
ValidateOnStepUpComplete ==
    LET logline == CurrentLogline
        node == logline.node
        next_term == logline.term
    IN
    /\ service_state[node] = "READY_FOR_INIT"
    /\ current_term[node] = next_term
    /\ recovery_started[node][next_term] = TRUE

TraceOnStepUpComplete ==
    LET logline == CurrentLogline
        node == logline.node
    IN
    /\ IsNodeEvent("OnStepUpComplete", node)
    /\ OnStepUpComplete(node)
    /\ ValidateOnStepUpComplete
    /\ l' = l + 1

(* ref: range_deleter_service.cpp:315-316 *)
ValidateOnStepDown ==
    LET logline == CurrentLogline
        node == logline.node
    IN
    service_state[node] = "DOWN"

TraceOnStepDown ==
    LET logline == CurrentLogline
        node == logline.node
    IN
    /\ IsNodeEvent("OnStepDown", node)
    /\ OnStepDown(node)
    /\ ValidateOnStepDown
    /\ l' = l + 1

(* ref: range_deleter_service.cpp:195-210 *)
TraceLaunchRangeDeletionRecoveryTask ==
    LET logline == CurrentLogline
        node == logline.node
    IN
    /\ IsNodeEvent("LaunchRangeDeletionRecoveryTask", node)
    /\ LaunchRangeDeletionRecoveryTask(node)
    /\ service_state[node] = "INITIALIZING"
    /\ l' = l + 1

(* ref: range_deleter_service.cpp:220-231 *)
TraceRecoveryCompletesFirstScan ==
    LET logline == CurrentLogline
        node == logline.node
    IN
    /\ IsNodeEvent("RecoveryCompletesFirstScan", node)
    /\ RecoveryCompletesFirstScan(node)
    /\ recovery_scan_state[node] = "scanned_processing"
    /\ l' = l + 1

(* ref: range_deleter_service.cpp:241-254 *)
TraceRecoveryCompletesSecondScan ==
    LET logline == CurrentLogline
        node == logline.node
    IN
    /\ IsNodeEvent("RecoveryCompletesSecondScan", node)
    /\ RecoveryCompletesSecondScan(node)
    /\ recovery_scan_state[node] = "scanned_all"
    /\ l' = l + 1

(* ref: range_deleter_service.cpp:156-173 *)
TraceRecoveryCompletes ==
    LET logline == CurrentLogline
        node == logline.node
        outcome == logline.outcome
    IN
    /\ IsNodeEvent("RecoveryCompletes", node)
    /\ RecoveryCompletes(node)
    /\ recovery_outcome[node][current_term[node]] = outcome
    /\ l' = l + 1

(* ref: range_deleter_service.cpp:361-416 *)
TraceRegisterTask ==
    LET logline == CurrentLogline
        node == logline.node
        task == logline.task
    IN
    /\ IsNodeEvent("RegisterTask", node)
    /\ task \in in_memory_tasks'[node]
    /\ registration_time'[node][task] > 0
    /\ RegisterTask(node, task)
    /\ l' = l + 1

(* ref: range_deleter_service_op_observer.cpp:149-173 *)
TraceClearPendingFlag ==
    LET logline == CurrentLogline
        node == logline.node
        task == logline.task
    IN
    /\ IsNodeEvent("ClearPendingFlag", node)
    /\ ClearPendingFlag(node, task)
    /\ persistent_pending_flag'[node][task] = FALSE
    /\ pending_promise_state'[node][task] = "RESOLVED"
    /\ l' = l + 1

(* ref: range_deleter_service.cpp:381-384 *)
TraceExecuteTask ==
    LET logline == CurrentLogline
        node == logline.node
        task == logline.task
    IN
    /\ IsNodeEvent("ExecuteTask", node)
    /\ ExecuteTask(node, task)
    /\ task_executing'[node][task] = TRUE
    /\ l' = l + 1

(* ref: range_deleter_service.cpp:491-498 *)
TraceCompleteTask ==
    LET logline == CurrentLogline
        node == logline.node
        task == logline.task
    IN
    /\ IsNodeEvent("CompleteTask", node)
    /\ CompleteTask(node, task)
    /\ IF service_state[node] = "UP"
       THEN task_completed'[node][task] = TRUE
       ELSE task_completed'[node][task] = task_completed[node][task]
    /\ l' = l + 1

(* ref: modeling-brief.md section 2.5 *)
TraceMigrationInsertTask ==
    LET logline == CurrentLogline
        node == logline.node
        task == logline.task
    IN
    /\ IsNodeEvent("MigrationInsertTask", node)
    /\ MigrationInsertTask(node, task)
    /\ task \in persistent_tasks'[node]
    /\ l' = l + 1

(* ref: modeling-brief.md section 3.1 *)
TraceCrash ==
    LET logline == CurrentLogline
        node == logline.node
    IN
    /\ IsNodeEvent("Crash", node)
    /\ Crash(node)
    /\ service_state'[node] = "DOWN"
    /\ l' = l + 1

(* ===== SILENT ACTIONS ===== *)
(* Silent actions model state changes that don't produce trace events,
   or represent internal computation steps. They must be tightly constrained
   to avoid state space explosion. *)

(* Silent action: Server becomes ready to initialize (internal state, happens in OnStepUpComplete) *)
SilentServiceReadyForInit ==
    /\ l <= Len(TraceLog)
    /\ \E node \in Node :
        /\ service_state[node] = "READY_FOR_INIT"
        /\ recovery_started[node][current_term[node]] = TRUE
        /\ UNCHANGED <<vars, l>>

(* ===== TRACE NEXT ===== *)

TraceNext ==
    \/ TraceOnStepUpComplete
    \/ TraceOnStepDown
    \/ TraceLaunchRangeDeletionRecoveryTask
    \/ TraceRecoveryCompletesFirstScan
    \/ TraceRecoveryCompletesSecondScan
    \/ TraceRecoveryCompletes
    \/ TraceRegisterTask
    \/ TraceClearPendingFlag
    \/ TraceExecuteTask
    \/ TraceCompleteTask
    \/ TraceMigrationInsertTask
    \/ TraceCrash
    \/ SilentServiceReadyForInit

(* ===== TEMPORAL PROPERTIES ===== *)

(* Entire trace must be consumed *)
TraceFullyConsumed == <>(l > Len(TraceLog))

TraceMatched ==
    /\ TraceFullyConsumed
    /\ Spec

(* ===== SPECIFICATION ===== *)

TraceSpec ==
    TraceInit /\ [][TraceNext]_<<vars, l>>

====
