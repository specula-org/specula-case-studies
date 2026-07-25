---- MODULE base ----
(* MongoDB Range Deletion Service State Machine
   Category A: Distributed/Message-Passing

   Core state machine modeling task-based range deletion with async recovery.
   Bug families:
   - Family 1: Service state and recovery completion ordering
   - Family 2: Pending task unblocking and persistent state inconsistency
   - Family 3: Overlapping task detection and registration order races
   - Family 4: Task completion and service state check race
   - Family 5: Recovery task scan and concurrent writes
*)

EXTENDS Naturals, Sequences, FiniteSets

CONSTANT Node, TaskId, MaxTerm

VARIABLE
    \* Standard protocol variables
    service_state,      \* [Node -> {"DOWN", "READY_FOR_INIT", "INITIALIZING", "UP"}]
    current_term,       \* [Node -> Nat]

    \* Persistent state in config.rangeDeletions collection
    persistent_tasks,              \* [Node -> SUBSET TaskId]
    persistent_pending_flag,       \* [Node -> [TaskId -> BOOL]]
    persistent_processing_flag,    \* [Node -> [TaskId -> BOOL]]

    \* In-memory state on the node
    in_memory_tasks,    \* [Node -> SUBSET TaskId]

    (* Family 1: Service state and recovery completion ordering
       ref: modeling-brief.md section 2.1
       Variables to track async recovery completion separate from service state.
    *)
    recovery_outcome,       \* [Node -> [Term -> {"UNKNOWN", "COMPLETE", "INCOMPLETE"}]]
    recovery_started,       \* [Node -> [Term -> BOOL]]

    (* Family 2: Pending task unblocking and persistent state inconsistency
       ref: modeling-brief.md section 2.2
       Separate in-memory promise state from persistent pending flag.
    *)
    pending_promise_state,      \* [Node -> [TaskId -> {"UNRESOLVED", "RESOLVED"}]]
    task_scheduling_started,    \* [Node -> [TaskId -> BOOL]]

    (* Family 3: Overlapping task detection and registration order races
       ref: modeling-brief.md section 2.3
       Track registration time for deterministic ordering.
    *)
    registration_time,      \* [Node -> [TaskId -> Nat]]
    overlapping_with,       \* [Node -> [TaskId -> SUBSET TaskId]]

    (* Family 4: Task completion and service state check race
       ref: modeling-brief.md section 2.4
       Track task execution state separately.
    *)
    task_executing,     \* [Node -> [TaskId -> BOOL]]
    task_completed,     \* [Node -> [TaskId -> BOOL]]

    (* Family 5: Recovery task scan and concurrent writes
       ref: modeling-brief.md section 2.5
       Track recovery scan progress.
    *)
    recovery_scan_state     \* [Node -> {"initial", "scanned_processing", "scanned_all"}]

serverVars == <<service_state, current_term>>
persistentVars == <<persistent_tasks, persistent_pending_flag, persistent_processing_flag>>
inMemoryVars == <<in_memory_tasks, pending_promise_state, task_scheduling_started>>
recoveryVars == <<recovery_outcome, recovery_started, recovery_scan_state>>
executionVars == <<task_executing, task_completed, registration_time, overlapping_with>>

vars == <<serverVars, persistentVars, inMemoryVars, recoveryVars, executionVars>>

(* ===== INVARIANTS ===== *)

(* Family 1: Service UP implies recovery complete *)
ServiceUPImpliesRecoveryComplete ==
    \A n \in Node : service_state[n] = "UP" => recovery_outcome[n][current_term[n]] = "COMPLETE"

(* Family 2: Pending tasks never schedule execution *)
PendingTasksNeverScheduleUnpending ==
    \A n \in Node :
        \A t \in in_memory_tasks[n] :
            (persistent_pending_flag[n][t] = TRUE) => (task_scheduling_started[n][t] = FALSE)

(* Family 3: Overlapping tasks serialize *)
OverlappingTasksSerialize ==
    \A n \in Node :
        \A t1 \in in_memory_tasks[n] :
            \A t2 \in in_memory_tasks[n] :
                (t2 \in overlapping_with[n][t1] /\ registration_time[n][t1] < registration_time[n][t2]) =>
                task_completed[n][t1] = TRUE

(* Family 4: Executing tasks cannot have service step down *)
TaskExecutingOnlyWhenServiceUp ==
    \A n \in Node :
        \A t \in in_memory_tasks[n] :
            task_executing[n][t] = TRUE => service_state[n] = "UP"

(* Family 5: Recovery eventually recovers all non-pending tasks *)
PersistentStateRecoveredCompletely ==
    \A n \in Node :
        (recovery_outcome[n][current_term[n]] = "COMPLETE" /\ recovery_scan_state[n] = "scanned_all") =>
        \A t \in persistent_tasks[n] :
            (persistent_pending_flag[n][t] = FALSE /\ persistent_processing_flag[n][t] = FALSE) =>
            (t \in in_memory_tasks[n])

(* Structural invariants *)
InMemorySubsetOfPersistent ==
    \A n \in Node : in_memory_tasks[n] \subseteq persistent_tasks[n]

AllTasksHaveValidState ==
    \A n \in Node :
        \A t \in in_memory_tasks[n] :
            /\ registration_time[n][t] > 0
            /\ overlapping_with[n][t] \subseteq in_memory_tasks[n]

StateTransitionsAreMonotone ==
    \A n \in Node :
        \/ service_state[n] \in {"DOWN", "READY_FOR_INIT", "INITIALIZING", "UP"}

(* Liveness *)
AllTasksEventuallyComplete ==
    \A n \in Node :
        \A t \in in_memory_tasks[n] :
            (service_state[n] = "UP") ~> (task_completed[n][t] = TRUE)

(* ===== INITIALIZATION ===== *)

Init ==
    /\ service_state = [n \in Node |-> "DOWN"]
    /\ current_term = [n \in Node |-> 0]
    /\ persistent_tasks = [n \in Node |-> {}]
    /\ persistent_pending_flag = [n \in Node |-> [t \in TaskId |-> FALSE]]
    /\ persistent_processing_flag = [n \in Node |-> [t \in TaskId |-> FALSE]]
    /\ in_memory_tasks = [n \in Node |-> {}]
    /\ recovery_outcome = [n \in Node |-> [t \in 0..MaxTerm |-> "UNKNOWN"]]
    /\ recovery_started = [n \in Node |-> [t \in 0..MaxTerm |-> FALSE]]
    /\ pending_promise_state = [n \in Node |-> [t \in TaskId |-> "UNRESOLVED"]]
    /\ task_scheduling_started = [n \in Node |-> [t \in TaskId |-> FALSE]]
    /\ registration_time = [n \in Node |-> [t \in TaskId |-> 0]]
    /\ overlapping_with = [n \in Node |-> [t \in TaskId |-> {}]]
    /\ task_executing = [n \in Node |-> [t \in TaskId |-> FALSE]]
    /\ task_completed = [n \in Node |-> [t \in TaskId |-> FALSE]]
    /\ recovery_scan_state = [n \in Node |-> "initial"]

(* ===== ACTIONS ===== *)

(* ref: range_deleter_service.cpp:156-173, range_deleter_service.cpp:137 *)
OnStepUpComplete(node) ==
    /\ service_state[node] = "DOWN"
    /\ service_state' = [service_state EXCEPT ![node] = "READY_FOR_INIT"]
    /\ current_term' = [current_term EXCEPT ![node] = current_term[node] + 1]
    /\ recovery_started' = [recovery_started EXCEPT ![node][current_term'[node]] = TRUE]
    /\ recovery_scan_state' = [recovery_scan_state EXCEPT ![node] = "initial"]
    /\ in_memory_tasks' = [in_memory_tasks EXCEPT ![node] = {}]
    /\ pending_promise_state' = [pending_promise_state EXCEPT ![node] = [t \in TaskId |-> "UNRESOLVED"]]
    /\ task_scheduling_started' = [task_scheduling_started EXCEPT ![node] = [t \in TaskId |-> FALSE]]
    /\ task_executing' = [task_executing EXCEPT ![node] = [t \in TaskId |-> FALSE]]
    /\ task_completed' = [task_completed EXCEPT ![node] = [t \in TaskId |-> FALSE]]
    /\ registration_time' = registration_time
    /\ overlapping_with' = overlapping_with
    /\ UNCHANGED <<persistentVars, recoveryVars>>

(* ref: range_deleter_service.cpp:315-316, range_deletion_recovery_tracker.cpp:141-151 *)
OnStepDown(node) ==
    /\ service_state[node] \in {"UP", "READY_FOR_INIT", "INITIALIZING"}
    /\ service_state' = [service_state EXCEPT ![node] = "DOWN"]
    /\ IF service_state[node] \in {"READY_FOR_INIT", "INITIALIZING"}
       THEN recovery_outcome' = [recovery_outcome EXCEPT ![node][current_term[node]] = "INCOMPLETE"]
       ELSE UNCHANGED recovery_outcome
    /\ UNCHANGED <<current_term, persistentVars, inMemoryVars>>
    /\ UNCHANGED <<recovery_started, recovery_scan_state, executionVars>>

(* ref: range_deleter_service.cpp:195-210 *)
LaunchRangeDeletionRecoveryTask(node) ==
    /\ service_state[node] = "READY_FOR_INIT"
    /\ recovery_started[node][current_term[node]] = TRUE
    /\ service_state' = [service_state EXCEPT ![node] = "INITIALIZING"]
    /\ UNCHANGED <<current_term, persistentVars, inMemoryVars, recoveryVars, executionVars>>

(* ref: range_deleter_service.cpp:220-231 *)
RecoveryCompletesFirstScan(node) ==
    /\ service_state[node] = "INITIALIZING"
    /\ recovery_started[node][current_term[node]] = TRUE
    /\ recovery_scan_state[node] = "initial"
    /\ recovery_scan_state' = [recovery_scan_state EXCEPT ![node] = "scanned_processing"]
    /\ UNCHANGED <<serverVars, persistentVars, inMemoryVars>>
    /\ UNCHANGED <<recovery_outcome, recovery_started, executionVars>>

(* ref: range_deleter_service.cpp:241-254 *)
RecoveryCompletesSecondScan(node) ==
    /\ service_state[node] = "INITIALIZING"
    /\ recovery_started[node][current_term[node]] = TRUE
    /\ recovery_scan_state[node] = "scanned_processing"
    /\ LET recovered_tasks == {t \in persistent_tasks[node] :
                               persistent_pending_flag[node][t] = FALSE /\
                               persistent_processing_flag[node][t] = FALSE}
       IN in_memory_tasks' = [in_memory_tasks EXCEPT ![node] =
                              in_memory_tasks[node] \cup recovered_tasks]
    /\ recovery_scan_state' = [recovery_scan_state EXCEPT ![node] = "scanned_all"]
    /\ UNCHANGED <<serverVars, persistentVars>>
    /\ UNCHANGED <<pending_promise_state, task_scheduling_started>>
    /\ UNCHANGED <<recovery_outcome, recovery_started, executionVars>>

(* ref: range_deleter_service.cpp:156-173 *)
RecoveryCompletes(node) ==
    /\ service_state[node] = "INITIALIZING"
    /\ recovery_scan_state[node] = "scanned_all"
    /\ IF service_state[node] # "DOWN"
       THEN /\ service_state' = [service_state EXCEPT ![node] = "UP"]
            /\ recovery_outcome' = [recovery_outcome EXCEPT ![node][current_term[node]] = "COMPLETE"]
       ELSE /\ service_state' = service_state
            /\ recovery_outcome' = [recovery_outcome EXCEPT ![node][current_term[node]] = "INCOMPLETE"]
    /\ UNCHANGED <<current_term, persistentVars, inMemoryVars, recovery_started, recovery_scan_state, executionVars>>

(* ref: range_deleter_service.cpp:361-416, range_deleter_service.cpp:377-393 *)
RegisterTask(node, task) ==
    /\ service_state[node] \in {"READY_FOR_INIT", "INITIALIZING", "UP"}
    /\ task \notin in_memory_tasks[node]
    /\ in_memory_tasks' = [in_memory_tasks EXCEPT ![node] = in_memory_tasks[node] \cup {task}]
    /\ persistent_tasks' = [persistent_tasks EXCEPT ![node] = persistent_tasks[node] \cup {task}]
    /\ registration_time' = [registration_time EXCEPT ![node][task] = current_term[node]]
    /\ persistent_pending_flag' = [persistent_pending_flag EXCEPT ![node][task] = TRUE]
    /\ persistent_processing_flag' = [persistent_processing_flag EXCEPT ![node][task] = FALSE]
    /\ pending_promise_state' = [pending_promise_state EXCEPT ![node][task] = "UNRESOLVED"]
    /\ task_scheduling_started' = [task_scheduling_started EXCEPT ![node][task] = TRUE]
    /\ LET other_tasks == in_memory_tasks[node] \ {task}
       IN overlapping_with' = [overlapping_with EXCEPT ![node][task] = other_tasks]
    /\ UNCHANGED <<serverVars, persistent_processing_flag, task_executing, task_completed, recoveryVars>>

(* ref: range_deleter_service_op_observer.cpp:149-173, range_deletion.cpp:55-57 *)
ClearPendingFlag(node, task) ==
    /\ task \in in_memory_tasks[node]
    /\ persistent_pending_flag[node][task] = TRUE
    /\ persistent_pending_flag' = [persistent_pending_flag EXCEPT ![node][task] = FALSE]
    /\ pending_promise_state' = [pending_promise_state EXCEPT ![node][task] = "RESOLVED"]
    /\ UNCHANGED <<serverVars, persistent_tasks, persistent_processing_flag, inMemoryVars>>
    /\ UNCHANGED <<task_scheduling_started, registration_time, overlapping_with, executionVars>>

(* ref: range_deleter_service.cpp:381-384 *)
ExecuteTask(node, task) ==
    /\ task \in in_memory_tasks[node]
    /\ service_state[node] = "UP"
    /\ pending_promise_state[node][task] = "RESOLVED"
    /\ overlapping_with[node][task] \subseteq {t \in in_memory_tasks[node] : task_completed[node][t] = TRUE}
    /\ task_executing[node][task] = FALSE
    /\ task_executing' = [task_executing EXCEPT ![node][task] = TRUE]
    /\ UNCHANGED <<serverVars, persistentVars, inMemoryVars, recoveryVars>>
    /\ UNCHANGED <<registration_time, overlapping_with, task_completed>>

(* ref: range_deleter_service.cpp:491-498 *)
CompleteTask(node, task) ==
    /\ task_executing[node][task] = TRUE
    /\ IF service_state[node] = "UP"
       THEN /\ task_completed' = [task_completed EXCEPT ![node][task] = TRUE]
            /\ task_executing' = [task_executing EXCEPT ![node][task] = FALSE]
       ELSE /\ task_executing' = [task_executing EXCEPT ![node][task] = FALSE]
            /\ UNCHANGED task_completed
    /\ UNCHANGED <<serverVars, persistentVars, inMemoryVars, recoveryVars>>
    /\ UNCHANGED <<registration_time, overlapping_with>>

(* ref: modeling-brief.md section 2.5 *)
MigrationInsertTask(node, task) ==
    /\ task \notin persistent_tasks[node]
    /\ persistent_tasks' = [persistent_tasks EXCEPT ![node] = persistent_tasks[node] \cup {task}]
    /\ persistent_pending_flag' = [persistent_pending_flag EXCEPT ![node][task] = TRUE]
    /\ persistent_processing_flag' = [persistent_processing_flag EXCEPT ![node][task] = FALSE]
    /\ UNCHANGED <<serverVars, in_memory_tasks, inMemoryVars, recoveryVars, executionVars>>

(* ref: modeling-brief.md section 3.1 *)
Crash(node) ==
    /\ service_state' = [service_state EXCEPT ![node] = "DOWN"]
    /\ in_memory_tasks' = [in_memory_tasks EXCEPT ![node] = {}]
    /\ task_scheduling_started' = [task_scheduling_started EXCEPT ![node] = [t \in TaskId |-> FALSE]]
    /\ pending_promise_state' = [pending_promise_state EXCEPT ![node] = [t \in TaskId |-> "UNRESOLVED"]]
    /\ task_executing' = [task_executing EXCEPT ![node] = [t \in TaskId |-> FALSE]]
    /\ task_completed' = [task_completed EXCEPT ![node] = [t \in TaskId |-> FALSE]]
    /\ recovery_outcome' = [recovery_outcome EXCEPT ![node][current_term[node]] = "INCOMPLETE"]
    /\ UNCHANGED <<current_term, persistentVars, recovery_started, recovery_scan_state, registration_time, overlapping_with>>

(* ===== NEXT STATE ===== *)

Next ==
    \/ \E node \in Node : OnStepUpComplete(node)
    \/ \E node \in Node : OnStepDown(node)
    \/ \E node \in Node : LaunchRangeDeletionRecoveryTask(node)
    \/ \E node \in Node : RecoveryCompletesFirstScan(node)
    \/ \E node \in Node : RecoveryCompletesSecondScan(node)
    \/ \E node \in Node : RecoveryCompletes(node)
    \/ \E node \in Node, task \in TaskId : RegisterTask(node, task)
    \/ \E node \in Node, task \in TaskId : ClearPendingFlag(node, task)
    \/ \E node \in Node, task \in TaskId : ExecuteTask(node, task)
    \/ \E node \in Node, task \in TaskId : CompleteTask(node, task)
    \/ \E node \in Node, task \in TaskId : MigrationInsertTask(node, task)
    \/ \E node \in Node : Crash(node)

Spec == Init /\ [][Next]_vars

====
