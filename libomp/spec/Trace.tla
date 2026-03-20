---- MODULE Trace ----
\* Trace validation specification for libomp barrier + tasking
\* Replays NDJSON traces from instrumented libomp against base spec actions.

EXTENDS base, TLC, IOUtils, Sequences, Json

\* --------------------------------------------------------------------------
\* Trace Loading
\* --------------------------------------------------------------------------

\* Trace file path: overridable via IOEnv.JSON environment variable
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load and deserialize the trace
TraceLog == ndJsonDeserialize(JsonFile)

\* --------------------------------------------------------------------------
\* Cursor Variable
\* --------------------------------------------------------------------------

VARIABLE l  \* Trace cursor: 1..Len(TraceLog)+1

traceVars == <<l>>
trace_all_vars == <<allVars, traceVars>>

\* Current log line
logline == TraceLog[l]

\* --------------------------------------------------------------------------
\* Event Predicates
\* --------------------------------------------------------------------------

IsEvent(name) == logline.event = name

IsThreadEvent(name, t) ==
    /\ logline.event = name
    /\ logline.tid = t

\* --------------------------------------------------------------------------
\* Post-State Validation
\* --------------------------------------------------------------------------

\* Weak validation: check only pc (for async/concurrent events)
ValidatePostStateWeak(t) ==
    /\ pc'[t] = logline.state.pc

\* --------------------------------------------------------------------------
\* Action Wrappers
\* --------------------------------------------------------------------------

\* --- Barrier Entry ---

\* Primary enters barrier. In the implementation, __kmp_task_team_setup
\* checks if the task team is already active (from fork barrier) and skips
\* re-initialization. We model this with an IF guard.
TracePrimaryEnterBarrier ==
    /\ IsThreadEvent("PrimaryEnterBarrier", Primary)
    /\ pc[Primary] = "idle"
    /\ barrierRound < MaxBarriers
    /\ LET slot == CurrentSlot(Primary)
       IN IF ~taskTeamActive[slot]
          THEN /\ taskTeamActive' = [taskTeamActive EXCEPT ![slot] = TRUE]
               /\ unfinished' = [unfinished EXCEPT ![slot] = NumThreads]
          ELSE UNCHANGED <<taskTeamActive, unfinished>>
    /\ pc' = [pc EXCEPT ![Primary] = "barrier_gather"]
    /\ ValidatePostStateWeak(Primary)
    /\ UNCHANGED <<barrierRound, cancelled, taskTeamSlot,
                   lifecycleVars, taskVars, taskCountVars>>
    /\ l' = l + 1

TraceWorkerEnterBarrier ==
    /\ \E t \in Workers :
        /\ IsThreadEvent("WorkerEnterBarrier", t)
        /\ WorkerEnterBarrier(t)
        /\ ValidatePostStateWeak(t)
    /\ l' = l + 1

\* --- Gather Completion ---

\* Workers start executing tasks during the release wait spin loop.
\* In libomp's linear barrier, workers return from gather immediately and
\* enter the release wait, where they execute tasks via __kmp_execute_tasks.
\* This happens BEFORE AllGathered (primary may still be idle), so we bypass
\* the AllGathered check from the base spec.
TraceWorkerStartTasks ==
    /\ \E t \in Workers :
        /\ IsThreadEvent("WorkerStartTasks", t)
        /\ pc[t] \in {"barrier_gather", "barrier_tasks"}
        /\ pc' = [pc EXCEPT ![t] = "barrier_tasks"]
        /\ threadState' = [threadState EXCEPT ![t] = "active"]
        /\ threadFinished' = [threadFinished EXCEPT ![t] = FALSE]
        /\ ValidatePostStateWeak(t)
    /\ UNCHANGED <<barrierRound, cancelled, parityVars, teamValid,
                   taskVars, taskCountVars>>
    /\ l' = l + 1

\* Primary starts task wait. AllGathered should hold by this point
\* (workers entered barrier before primary).
TracePrimaryStartTaskWait ==
    /\ IsThreadEvent("PrimaryStartTaskWait", Primary)
    /\ pc[Primary] \in {"barrier_gather", "barrier_tasks"}
    /\ ~cancelled
    /\ pc' = [pc EXCEPT ![Primary] = "barrier_tasks"]
    /\ threadState' = [threadState EXCEPT ![Primary] = "active"]
    /\ threadFinished' = [threadFinished EXCEPT ![Primary] = FALSE]
    /\ UNCHANGED <<barrierRound, cancelled, parityVars, teamValid,
                   taskVars, taskCountVars>>
    /\ l' = l + 1

\* --- Task Scheduling ---

TraceScheduleTask ==
    /\ IsEvent("ScheduleTask")
    /\ LET t == logline.tid
           task == logline.task
           slot == CurrentSlot(t)
           theParent == IF \E pt \in Task : taskOwner[pt] = t /\ taskPhase[pt] = "executing"
                        THEN CHOOSE pt \in Task : taskOwner[pt] = t /\ taskPhase[pt] = "executing"
                        ELSE Nil
       IN /\ pc[t] \in {"idle", "barrier_tasks"}
          /\ threadState[t] = "active"
          /\ taskPhase[task] = "free"
          /\ taskPhase' = [taskPhase EXCEPT ![task] = "queued"]
          /\ taskOwner' = [taskOwner EXCEPT ![task] = Nil]
          /\ taskParent' = [taskParent EXCEPT ![task] = theParent]
          /\ childCount' = IF theParent /= Nil
                           THEN [childCount EXCEPT ![theParent] = childCount[theParent] + 1]
                           ELSE childCount
          /\ taskDetachable' = [taskDetachable EXCEPT ![task] = FALSE]
          /\ eventFulfilled' = [eventFulfilled EXCEPT ![task] = FALSE]
          /\ taskSlot' = [taskSlot EXCEPT ![task] = slot]
          /\ taskCount' = [taskCount EXCEPT ![slot] = taskCount[slot] + 1]
    /\ UNCHANGED <<pc, barrierRound, cancelled, parityVars, lifecycleVars>>
    /\ l' = l + 1

TraceScheduleDetachTask ==
    /\ IsEvent("ScheduleDetachTask")
    /\ LET t == logline.tid
           task == logline.task
           slot == CurrentSlot(t)
           theParent == IF \E pt \in Task : taskOwner[pt] = t /\ taskPhase[pt] = "executing"
                        THEN CHOOSE pt \in Task : taskOwner[pt] = t /\ taskPhase[pt] = "executing"
                        ELSE Nil
       IN /\ pc[t] \in {"idle", "barrier_tasks"}
          /\ threadState[t] = "active"
          /\ taskPhase[task] = "free"
          /\ taskPhase' = [taskPhase EXCEPT ![task] = "queued"]
          /\ taskOwner' = [taskOwner EXCEPT ![task] = Nil]
          /\ taskParent' = [taskParent EXCEPT ![task] = theParent]
          /\ childCount' = IF theParent /= Nil
                           THEN [childCount EXCEPT ![theParent] = childCount[theParent] + 1]
                           ELSE childCount
          /\ taskDetachable' = [taskDetachable EXCEPT ![task] = TRUE]
          /\ eventFulfilled' = [eventFulfilled EXCEPT ![task] = FALSE]
          /\ taskSlot' = [taskSlot EXCEPT ![task] = slot]
          /\ taskCount' = [taskCount EXCEPT ![slot] = taskCount[slot] + 1]
    /\ UNCHANGED <<pc, barrierRound, cancelled, parityVars, lifecycleVars>>
    /\ l' = l + 1

\* --- Task Execution ---

TraceExecuteTask ==
    /\ IsEvent("ExecuteTask")
    /\ LET t == logline.tid
           task == logline.task
       IN \/ \* Normal path: pick up queued task
             /\ pc[t] = "barrier_tasks"
             /\ threadState[t] = "active"
             /\ LET slot == CurrentSlot(t)
                IN /\ taskSlot[task] = slot
                   /\ taskPhase[task] = "queued"
                   /\ taskPhase' = [taskPhase EXCEPT ![task] = "executing"]
                   /\ taskOwner' = [taskOwner EXCEPT ![task] = t]
                   /\ taskCount' = [taskCount EXCEPT ![slot] = taskCount[slot] - 1]
             /\ UNCHANGED <<pc, barrierRound, cancelled, parityVars, lifecycleVars,
                            taskParent, childCount, taskDetachable, eventFulfilled, taskSlot>>
          \* After StealTask, the task is already "executing" for this thread.
          \* The trace emits both StealTask and ExecuteTask for stolen tasks.
          \* Just advance the cursor if the thread already owns the executing task.
          \/ /\ taskPhase[task] = "executing"
             /\ taskOwner[task] = t
             /\ UNCHANGED allVars
    /\ l' = l + 1

\* --- Task Stealing ---

\* In the implementation, a thread that has already called ThreadFinishTasks
\* (threadState="finished") can still steal. The spin loop in the release
\* wait continues checking for tasks. StealTask re-increments unfinished
\* when the thief has threadFinished=TRUE.
\* We allow threadState "finished" in addition to "active"/"stealing".
TraceStealTask ==
    /\ IsEvent("StealTask")
    /\ LET thief == logline.tid
           victim == logline.victim
           task == logline.task
       IN /\ thief /= victim
          /\ pc[thief] = "barrier_tasks"
          /\ teamValid
          /\ LET slot == CurrentSlot(thief)
             IN /\ taskSlot[task] = slot
                /\ taskPhase[task] = "queued"
                /\ IF threadFinished[thief]
                   THEN /\ unfinished' = [unfinished EXCEPT ![slot] = unfinished[slot] + 1]
                        /\ threadFinished' = [threadFinished EXCEPT ![thief] = FALSE]
                   ELSE /\ UNCHANGED <<unfinished, threadFinished>>
                /\ taskPhase' = [taskPhase EXCEPT ![task] = "executing"]
                /\ taskOwner' = [taskOwner EXCEPT ![task] = thief]
                /\ taskCount' = [taskCount EXCEPT ![slot] = taskCount[slot] - 1]
                /\ threadState' = [threadState EXCEPT ![thief] = "active"]
    /\ UNCHANGED <<pc, barrierRound, cancelled, taskTeamSlot, taskTeamActive,
                   teamValid, taskParent, childCount, taskDetachable, eventFulfilled, taskSlot>>
    /\ l' = l + 1

\* --- Task Completion ---

TraceCompleteTask ==
    /\ IsEvent("CompleteTask")
    /\ LET task == logline.task
       IN /\ taskOwner[task] = logline.tid
          /\ taskPhase[task] = "executing"
          /\ CompleteTask(logline.tid, task)
    /\ l' = l + 1

\* --- Detachable Task Protocol ---

TraceDetachTask ==
    /\ IsEvent("DetachTask")
    /\ LET task == logline.task
       IN /\ taskOwner[task] = logline.tid
          /\ taskPhase[task] = "executing"
          /\ taskDetachable[task]
          /\ DetachTask(logline.tid, task)
    /\ l' = l + 1

TraceFulfillEvent ==
    /\ IsEvent("FulfillEvent")
    /\ LET task == logline.task
       IN /\ taskPhase[task] = "detached"
          /\ FulfillEvent(task)
    /\ l' = l + 1

TraceEarlyFulfillEvent ==
    /\ IsEvent("EarlyFulfillEvent")
    /\ LET task == logline.task
       IN /\ taskPhase[task] = "executing"
          /\ EarlyFulfillEvent(task)
    /\ l' = l + 1

TraceProxyTaskComplete ==
    /\ IsEvent("ProxyTaskComplete")
    /\ LET task == logline.task
       IN /\ taskPhase[task] \in {"fulfilled", "completed"}
          /\ IF taskPhase[task] = "fulfilled"
             THEN ProxyTaskComplete(task)
             ELSE UNCHANGED allVars
    /\ l' = l + 1

\* --- Thread Finish Tasks ---

\* In the implementation, ThreadFinishTasks fires when a thread's local
\* view shows no tasks to execute. But tasks may be queued globally
\* (just pushed by another thread). We bypass the QueuedTasks = {} check
\* and the "no executing tasks" check from the base spec.
TraceThreadFinishTasks ==
    /\ IsEvent("ThreadFinishTasks")
    /\ LET t == logline.tid
           slot == CurrentSlot(t)
       IN /\ pc[t] = "barrier_tasks"
          /\ threadState[t] \in {"active", "finished"}
          /\ ~threadFinished[t]
          /\ unfinished' = [unfinished EXCEPT ![slot] = unfinished[slot] - 1]
          /\ threadFinished' = [threadFinished EXCEPT ![t] = TRUE]
          /\ threadState' = [threadState EXCEPT ![t] = "finished"]
    /\ UNCHANGED <<pc, barrierRound, cancelled, taskTeamSlot, taskTeamActive,
                   teamValid, taskVars, taskCountVars>>
    /\ l' = l + 1

\* --- Primary Task Team Wait ---

TracePrimaryTaskTeamWait ==
    /\ IsThreadEvent("PrimaryTaskTeamWait", Primary)
    /\ PrimaryTaskTeamWait
    /\ l' = l + 1

\* --- Barrier Release ---

TracePrimaryRelease ==
    /\ IsThreadEvent("PrimaryRelease", Primary)
    /\ PrimaryRelease
    /\ ValidatePostStateWeak(Primary)
    /\ l' = l + 1

TraceWorkerReceiveRelease ==
    /\ \E t \in Workers :
        /\ IsThreadEvent("WorkerReceiveRelease", t)
        /\ WorkerReceiveRelease(t)
        /\ ValidatePostStateWeak(t)
    /\ l' = l + 1

\* --- Task Team Sync ---

TraceTaskTeamSync ==
    /\ IsEvent("TaskTeamSync")
    /\ TaskTeamSync(logline.tid)
    /\ l' = l + 1

\* --- Barrier Done ---

TraceBarrierDone ==
    /\ IsEvent("BarrierDone")
    /\ BarrierDone(logline.tid)
    /\ l' = l + 1

\* --- Cancellation ---

TraceCancelBarrier ==
    /\ IsEvent("CancelBarrier")
    /\ CancelBarrier
    /\ l' = l + 1

TracePrimaryCancelledBarrier ==
    /\ IsThreadEvent("PrimaryCancelledBarrier", Primary)
    /\ PrimaryCancelledBarrier
    /\ l' = l + 1

TraceWorkerCancelledBarrier ==
    /\ \E t \in Workers :
        /\ IsThreadEvent("WorkerCancelledBarrier", t)
        /\ WorkerCancelledBarrier(t)
    /\ l' = l + 1

\* --------------------------------------------------------------------------
\* Silent Actions
\* --------------------------------------------------------------------------
\* Silent actions fire base spec actions without consuming a trace event.
\* Each must be tightly constrained to avoid state space explosion.

\* Silent worker start tasks: worker transitions from barrier_gather to
\* barrier_tasks between observed events (e.g., when a task event fires
\* for a thread still in barrier_gather in the spec).
SilentWorkerStartTasks ==
    /\ l <= Len(TraceLog)
    /\ \E t \in Workers :
        /\ pc[t] = "barrier_gather"
        /\ pc' = [pc EXCEPT ![t] = "barrier_tasks"]
        /\ threadState' = [threadState EXCEPT ![t] = "active"]
        /\ threadFinished' = [threadFinished EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<barrierRound, cancelled, parityVars, teamValid,
                   taskVars, taskCountVars>>
    /\ UNCHANGED l

\* Silent primary start task wait: primary transitions from barrier_gather
\* to barrier_tasks without a trace event.
SilentPrimaryStartTaskWait ==
    /\ l <= Len(TraceLog)
    /\ pc[Primary] = "barrier_gather"
    /\ ~cancelled
    /\ pc' = [pc EXCEPT ![Primary] = "barrier_tasks"]
    /\ threadState' = [threadState EXCEPT ![Primary] = "active"]
    /\ threadFinished' = [threadFinished EXCEPT ![Primary] = FALSE]
    /\ UNCHANGED <<barrierRound, cancelled, parityVars, teamValid,
                   taskVars, taskCountVars>>
    /\ UNCHANGED l

\* Silent proxy task complete: bottom-half runs between observed events
SilentProxyTaskComplete ==
    /\ l <= Len(TraceLog)
    /\ \E task \in Task :
        /\ taskPhase[task] = "fulfilled"
        /\ ProxyTaskComplete(task)
    /\ UNCHANGED l

\* --------------------------------------------------------------------------
\* TraceInit and TraceNext
\* --------------------------------------------------------------------------

\* Trace starts AFTER the fork barrier has run. The fork barrier:
\* - Toggled th_task_state from 0 to 1 via __kmp_task_team_sync
\* - Set up the task team for slot 1 via __kmp_task_team_setup
\* So the initial state has taskTeamSlot=1, taskTeamActive[1]=TRUE,
\* and unfinished[1]=NumThreads.
TraceInit ==
    /\ pc = [t \in Thread |-> "idle"]
    /\ barrierRound = 0
    /\ cancelled = FALSE
    /\ taskTeamSlot = [t \in Thread |-> 1]
    /\ taskTeamActive = [slot \in {0, 1} |-> IF slot = 1 THEN TRUE ELSE FALSE]
    /\ unfinished = [slot \in {0, 1} |-> IF slot = 1 THEN NumThreads ELSE 0]
    /\ threadState = [t \in Thread |-> "active"]
    /\ teamValid = TRUE
    /\ threadFinished = [t \in Thread |-> FALSE]
    /\ taskPhase = [task \in Task |-> "free"]
    /\ taskOwner = [task \in Task |-> Nil]
    /\ taskParent = [task \in Task |-> Nil]
    /\ childCount = [task \in Task |-> 0]
    /\ taskDetachable = [task \in Task |-> FALSE]
    /\ eventFulfilled = [task \in Task |-> FALSE]
    /\ taskSlot = [task \in Task |-> Nil]
    /\ taskCount = [slot \in {0, 1} |-> 0]
    /\ l = 1

TraceNext ==
    IF l <= Len(TraceLog) THEN
        \* Action wrappers (consume a trace event)
        \/ TracePrimaryEnterBarrier
        \/ TraceWorkerEnterBarrier
        \/ TraceWorkerStartTasks
        \/ TracePrimaryStartTaskWait
        \/ TraceScheduleTask
        \/ TraceScheduleDetachTask
        \/ TraceExecuteTask
        \/ TraceStealTask
        \/ TraceCompleteTask
        \/ TraceDetachTask
        \/ TraceFulfillEvent
        \/ TraceEarlyFulfillEvent
        \/ TraceProxyTaskComplete
        \/ TraceThreadFinishTasks
        \/ TracePrimaryTaskTeamWait
        \/ TracePrimaryRelease
        \/ TraceWorkerReceiveRelease
        \/ TraceTaskTeamSync
        \/ TraceBarrierDone
        \/ TraceCancelBarrier
        \/ TracePrimaryCancelledBarrier
        \/ TraceWorkerCancelledBarrier
        \* Silent actions (do not consume trace events)
        \/ SilentWorkerStartTasks
        \/ SilentPrimaryStartTaskWait
        \/ SilentProxyTaskComplete
    ELSE
        UNCHANGED trace_all_vars

TraceSpec == TraceInit /\ [][TraceNext]_trace_all_vars

\* --------------------------------------------------------------------------
\* Trace Matched Property
\* --------------------------------------------------------------------------

\* The entire trace was consumed (checked as temporal property via deadlock)
TraceMatched == <>(l = Len(TraceLog) + 1)

\* Alternative: check via invariant at deadlock
TraceFullyConsumed == l >= Len(TraceLog) + 1

====
