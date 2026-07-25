---- MODULE MC ----
(* Model Checking Spec for MongoDB Range Deletion Service

   Wraps base spec with counter-bounded fault-injection actions to enable
   exhaustive state space exploration while keeping search tractable.

   Fault injection mechanisms targeted at each bug family:
   - Family 1: Vary recovery completion timing
   - Family 2: Vary pending flag clearing timing
   - Family 3: Vary task registration order
   - Family 4: Vary service state during task completion
   - Family 5: Vary migration insert timing
*)

EXTENDS base, Naturals

(* Counter variables for bounding fault-injection actions *)
VARIABLE faultCounters

faultVars == <<faultCounters>>
mcVars == <<vars, faultVars>>

(* Counter limits - tuned for finding bugs while keeping state space tractable *)
(* These bounds are set in the .cfg file, not here *)
(* MaxStepUpLimit, MaxStepDownLimit, MaxRecoveryDelay, MaxPendingClearDelay,
   MaxTaskRegisterLimit, MaxTaskExecuteLimit, MaxMigrationInsertLimit, MaxCrashLimit *)

(* Initialize counters *)
MCInit ==
    /\ Init
    /\ faultCounters = [stepUp |-> 0, stepDown |-> 0, recoveryFirstScan |-> 0,
                        recoverySecondScan |-> 0, pendingClear |-> 0, taskRegister |-> 0,
                        taskExecute |-> 0, migrationInsert |-> 0, crash |-> 0]

(* Bounded wrappers for non-deterministic actions *)

\* Family 1: Bound step-up events
MCOnStepUpComplete(node) ==
    /\ faultCounters.stepUp < MaxStepUpLimit
    /\ OnStepUpComplete(node)
    /\ faultCounters' = [faultCounters EXCEPT !.stepUp = @ + 1]

\* Family 1,4: Bound step-down events
MCOnStepDown(node) ==
    /\ faultCounters.stepDown < MaxStepDownLimit
    /\ OnStepDown(node)
    /\ faultCounters' = [faultCounters EXCEPT !.stepDown = @ + 1]

\* Family 1: Bound recovery first scan
MCRecoveryCompletesFirstScan(node) ==
    /\ faultCounters.recoveryFirstScan < MaxRecoveryDelay
    /\ RecoveryCompletesFirstScan(node)
    /\ faultCounters' = [faultCounters EXCEPT !.recoveryFirstScan = @ + 1]

\* Family 1: Bound recovery second scan
MCRecoveryCompletesSecondScan(node) ==
    /\ faultCounters.recoverySecondScan < MaxRecoveryDelay
    /\ RecoveryCompletesSecondScan(node)
    /\ faultCounters' = [faultCounters EXCEPT !.recoverySecondScan = @ + 1]

\* Family 2: Bound pending flag clearing (causes delay in unblocking)
MCClearPendingFlag(node, task) ==
    /\ faultCounters.pendingClear < MaxPendingClearDelay
    /\ ClearPendingFlag(node, task)
    /\ faultCounters' = [faultCounters EXCEPT !.pendingClear = @ + 1]

\* Family 3: Bound task registration (causes interleaving variety)
MCRegisterTask(node, task) ==
    /\ faultCounters.taskRegister < MaxTaskRegisterLimit
    /\ RegisterTask(node, task)
    /\ faultCounters' = [faultCounters EXCEPT !.taskRegister = @ + 1]

\* Family 4: Bound task execution
MCExecuteTask(node, task) ==
    /\ faultCounters.taskExecute < MaxTaskExecuteLimit
    /\ ExecuteTask(node, task)
    /\ faultCounters' = [faultCounters EXCEPT !.taskExecute = @ + 1]

\* Family 5: Bound migration inserts (causes recovery scan races)
MCMigrationInsertTask(node, task) ==
    /\ faultCounters.migrationInsert < MaxMigrationInsertLimit
    /\ MigrationInsertTask(node, task)
    /\ faultCounters' = [faultCounters EXCEPT !.migrationInsert = @ + 1]

\* All families: Bound crashes
MCCrash(node) ==
    /\ faultCounters.crash < MaxCrashLimit
    /\ Crash(node)
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

(* Reactive actions (not bounded - deterministic responses to state) *)

\* Family 1: Recovery launch - reactive, always allowed
MCLaunchRangeDeletionRecoveryTask(node) ==
    /\ LaunchRangeDeletionRecoveryTask(node)
    /\ UNCHANGED faultCounters

\* Family 1: Recovery completion - reactive, always allowed
MCRecoveryCompletes(node) ==
    /\ RecoveryCompletes(node)
    /\ UNCHANGED faultCounters

\* Family 4: Task completion - reactive, always allowed
MCCompleteTask(node, task) ==
    /\ CompleteTask(node, task)
    /\ UNCHANGED faultCounters

(* Next state for model checking *)
MCNext ==
    \/ \E node \in Node : MCOnStepUpComplete(node)
    \/ \E node \in Node : MCOnStepDown(node)
    \/ \E node \in Node : MCLaunchRangeDeletionRecoveryTask(node)
    \/ \E node \in Node : MCRecoveryCompletesFirstScan(node)
    \/ \E node \in Node : MCRecoveryCompletesSecondScan(node)
    \/ \E node \in Node : MCRecoveryCompletes(node)
    \/ \E node \in Node, task \in TaskId : MCRegisterTask(node, task)
    \/ \E node \in Node, task \in TaskId : MCClearPendingFlag(node, task)
    \/ \E node \in Node, task \in TaskId : MCExecuteTask(node, task)
    \/ \E node \in Node, task \in TaskId : MCCompleteTask(node, task)
    \/ \E node \in Node, task \in TaskId : MCMigrationInsertTask(node, task)
    \/ \E node \in Node : MCCrash(node)

MCSpec == MCInit /\ [][MCNext]_mcVars

(* Symmetry reduction *)
Permute(S) == Permutations(S)
ModelSymmetry == Permute(Node)

(* View that excludes fault counters for symmetry *)
SymmetryView == <<service_state, current_term, persistent_tasks, in_memory_tasks,
                   recovery_outcome, pending_promise_state, task_executing, task_completed>>

====
