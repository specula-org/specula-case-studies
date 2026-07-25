--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for libgomp flat barrier protocol.
 * Replays NDJSON traces from instrumented libgomp against base.tla.
 *
 * Trace events → spec actions mapping:
 *   CreateTask           → ScheduleTask
 *   BarrierWaitStart(0)  → PrimaryEnterBarrier
 *   BarrierWaitStart(t)  → SecondaryEnterBarrier(t)
 *   EnsureLast           → consume (silent PrimaryCheckThread reaches all_arrived)
 *   HandleTasks_AcquireLock  → consume (implementation detail)
 *   HandleTasks_ReleaseLock  → consume (implementation detail)
 *   HandleTasks_ExecuteTask(0)  → PrimaryHandleTask / PrimaryHandleTaskLast
 *   HandleTasks_ExecuteTask(t)  → consume (secondary task exec via silent action)
 *   HandleTasks_SetWaitingForTask → PrimaryCompleteBarrier (taskCount > 0)
 *   HandleTasks_AllDone           → consume (notification only)
 *   HandleTasks_LastThread_NoTasks → PrimaryCompleteBarrier / PrimaryHandleTaskLast
 *   Cancel               → CancelBarrier
 *   NonAtomicTaskCountDecrement → custom taskCount decrement (taskwait)
 *)

EXTENDS base, TLC, IOUtils, Sequences, Json

\* =========================================================================
\* Trace Loading
\* =========================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/barrier_basic.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* =========================================================================
\* Cursor Variable
\* =========================================================================

VARIABLE tIdx    \* Cursor into TraceLog: 1..Len(TraceLog)+1

traceVars == <<tIdx>>
trace_all_vars == <<allVars, traceVars>>

\* Current log line (valid only when tIdx <= Len(TraceLog))
logline == TraceLog[tIdx]

\* =========================================================================
\* Event Predicates
\* =========================================================================

IsEvent(name) == tIdx <= Len(TraceLog) /\ logline.event = name

\* =========================================================================
\* Trace Actions — consume one trace event, advance cursor
\* =========================================================================

\* --- Task Creation ---

TraceCreateTask ==
    /\ IsEvent("CreateTask")
    /\ ScheduleTask
    /\ tIdx' = tIdx + 1

\* --- Barrier Entry ---

TracePrimaryBarrierWaitStart ==
    /\ IsEvent("BarrierWaitStart")
    /\ logline.tid = Primary
    /\ PrimaryEnterBarrier
    /\ tIdx' = tIdx + 1

TraceSecondaryBarrierWaitStart ==
    /\ IsEvent("BarrierWaitStart")
    /\ logline.tid # Primary
    /\ LET t == logline.tid
       IN \/ \* Normal path: secondary enters barrier
             /\ pc[t] = "idle"
             /\ IF barrierType = BarrierCancel
                THEN SecondaryEnterCancelBarrier(t)
                ELSE SecondaryEnterBarrier(t)
          \/ \* Already entered silently: consume as no-op
             /\ pc[t] # "idle"
             /\ UNCHANGED allVars
    /\ tIdx' = tIdx + 1

\* --- EnsureLast ---
\* Primary finished scanning all secondaries.  We do NOT require
\* pc[Primary] = "all_arrived" here — silent PrimaryCheckThread actions
\* advance the primary as needed before/after this event.

TraceEnsureLast ==
    /\ IsEvent("EnsureLast")
    /\ UNCHANGED allVars
    /\ tIdx' = tIdx + 1

\* --- HandleTasks lock events (implementation detail, no spec change) ---

TraceHandleTasksAcquireLock ==
    /\ IsEvent("HandleTasks_AcquireLock")
    /\ UNCHANGED allVars
    /\ tIdx' = tIdx + 1

TraceHandleTasksReleaseLock ==
    /\ IsEvent("HandleTasks_ReleaseLock")
    /\ UNCHANGED allVars
    /\ tIdx' = tIdx + 1

\* --- HandleTasks ExecuteTask ---
\* Primary during scanning:     PrimaryHandleTask  (primary_handle_task → scanning)
\* Primary after all_arrived:   PrimaryHandleTaskLast
\* Secondary:                   consume — actual task exec via SilentSecondaryHandleTask
\*
\* Primary during scanning:   PrimaryHandleTask  (requires pc = primary_handle_task)
\* Primary after all_arrived:  PrimaryHandleTaskLast
\* Secondary:                  try SecondaryHandleTask, fall back to no-op
\*   The fallback is needed because trace event ordering may differ from
\*   the spec's required task-count ordering.

TraceHandleTasksExecuteTask ==
    /\ IsEvent("HandleTasks_ExecuteTask")
    /\ LET t == logline.tid
       IN IF t = Primary
          THEN \/ /\ pc[Primary] = "primary_handle_task"
                  /\ PrimaryHandleTask
               \/ /\ pc[Primary] = "primary_handle_task_last"
                  /\ PrimaryHandleTaskLast
          ELSE \* Secondary: fire SecondaryHandleTask (requires pc[t]="waiting")
               SecondaryHandleTask(t)
    /\ tIdx' = tIdx + 1

\* --- HandleTasks SetWaitingForTask ---
\* Primary at all_arrived with taskCount > 0: PrimaryCompleteBarrier
\* sets waitingForTask = TRUE, pc → primary_handle_task_last.

TraceHandleTasksSetWaitingForTask ==
    /\ IsEvent("HandleTasks_SetWaitingForTask")
    /\ PrimaryCompleteBarrier
    /\ tIdx' = tIdx + 1

\* --- HandleTasks AllDone ---
\* Notification that taskCount reached 0.  Consumed as no-op.
\* The actual barrier completion is handled by SilentPrimaryHandleTaskLast.

TraceHandleTasksAllDone ==
    /\ IsEvent("HandleTasks_AllDone")
    /\ UNCHANGED allVars
    /\ tIdx' = tIdx + 1

\* --- HandleTasks LastThread NoTasks ---
\* Primary (was_last) entered handle_tasks and found taskCount = 0.
\* Completes the barrier via PrimaryCompleteBarrier or PrimaryHandleTaskLast.

TraceHandleTasksLastThreadNoTasks ==
    /\ IsEvent("HandleTasks_LastThread_NoTasks")
    /\ \/ /\ pc[Primary] = "all_arrived"
          /\ PrimaryCompleteBarrier
       \/ /\ pc[Primary] = "primary_handle_task_last"
          /\ PrimaryHandleTaskLast
    /\ tIdx' = tIdx + 1

\* --- Cancel ---

TraceCancel ==
    /\ IsEvent("Cancel")
    /\ CancelBarrier
    /\ tIdx' = tIdx + 1

\* --- NonAtomicTaskCountDecrement (taskwait path, not in base spec) ---

TraceNonAtomicTaskCountDecrement ==
    /\ IsEvent("NonAtomicTaskCountDecrement")
    /\ taskCount > 0
    /\ taskCount' = taskCount - 1
    /\ taskPending' = IF taskCount - 1 > taskDetachCount THEN TRUE ELSE FALSE
    /\ UNCHANGED <<generation, waitingForTask, cancelled, secondaryArrived, holding>>
    /\ UNCHANGED <<detachVars, threadGenVars, cancelVars, controlVars,
                   holdingVars, teamVars>>
    /\ tIdx' = tIdx + 1

\* =========================================================================
\* Silent Actions — fire base spec actions without consuming a trace event
\* =========================================================================

\* --- Primary scanning ---

SilentPrimaryCheckThread ==
    /\ tIdx <= Len(TraceLog)
    /\ PrimaryCheckThread
    /\ UNCHANGED tIdx

SilentPrimaryCheckCancelThread ==
    /\ tIdx <= Len(TraceLog)
    /\ PrimaryCheckCancelThread
    /\ UNCHANGED tIdx

\* --- Secondary entry fallback checks ---

SilentSecondaryCheckFallback ==
    /\ tIdx <= Len(TraceLog)
    /\ \E t \in Secondaries : SecondaryCheckFallback(t)
    /\ UNCHANGED tIdx

SilentSecondaryCheckCancelFallback ==
    /\ tIdx <= Len(TraceLog)
    /\ \E t \in Secondaries : SecondaryCheckCancelFallback(t)
    /\ UNCHANGED tIdx

\* --- Secondary barrier passage ---

SilentSecondaryPassBarrier ==
    /\ tIdx <= Len(TraceLog)
    /\ \E t \in Secondaries : SecondaryPassBarrier(t)
    /\ UNCHANGED tIdx

SilentSecondaryPassCancelBarrier ==
    /\ tIdx <= Len(TraceLog)
    /\ \E t \in Secondaries : SecondaryPassCancelBarrier(t)
    /\ UNCHANGED tIdx

\* --- Silent secondary barrier entry ---
\* Fires when a secondary's BarrierWaitStart appears later in the trace
\* but the spec needs the secondary to have entered for the current round
\* (e.g., trace writes secondary entries after the primary's EnsureLast).

SilentSecondaryEnterBarrier ==
    /\ tIdx <= Len(TraceLog)
    /\ \E t \in Secondaries :
        /\ pc[t] = "idle"
        \* Don't compete with the trace event at the current cursor
        /\ ~(logline.event = "BarrierWaitStart" /\ logline.tid = t)
        \* This secondary has a BarrierWaitStart somewhere later in the trace
        /\ \E i \in tIdx..Len(TraceLog) :
              TraceLog[i].event = "BarrierWaitStart" /\ TraceLog[i].tid = t
        /\ IF barrierType = BarrierCancel
           THEN SecondaryEnterCancelBarrier(t)
           ELSE SecondaryEnterBarrier(t)
    /\ UNCHANGED tIdx

\* --- Secondary/Primary task handling ---

SilentPrimaryHandleTaskLast ==
    /\ tIdx <= Len(TraceLog)
    /\ PrimaryHandleTaskLast
    /\ UNCHANGED tIdx

\* --- Round transitions ---

\* --- Barrier completion (silent) ---
\* Fires when the primary reaches all_arrived and there is NO upcoming
\* HandleTasks_AcquireLock(primary) event before the next primary
\* BarrierWaitStart.  This covers the case where taskCount=0 at EnsureLast
\* and the implementation increments generation directly without entering
\* gomp_barrier_handle_tasks (no trace event emitted).

HasPrimaryBarrierCompletionUpcoming ==
    \E i \in tIdx..Len(TraceLog) :
        /\ TraceLog[i].event \in {"HandleTasks_AcquireLock",
                                   "HandleTasks_LastThread_NoTasks",
                                   "HandleTasks_SetWaitingForTask"}
        /\ TraceLog[i].tid = Primary
        /\ \A j \in tIdx..i-1 :
              ~(TraceLog[j].event = "BarrierWaitStart" /\ TraceLog[j].tid = Primary)

SilentPrimaryCompleteBarrier ==
    /\ tIdx <= Len(TraceLog)
    /\ pc[Primary] = "all_arrived"
    /\ ~HasPrimaryBarrierCompletionUpcoming
    /\ PrimaryCompleteBarrier
    /\ UNCHANGED tIdx

SilentPrimaryStartNextRound ==
    /\ tIdx <= Len(TraceLog)
    /\ PrimaryStartNextRound
    /\ UNCHANGED tIdx

SilentPrimaryReleasePrev ==
    /\ tIdx <= Len(TraceLog)
    /\ PrimaryReleasePrev
    /\ UNCHANGED tIdx

\* --- Cancellation ---

SilentPrimaryCancelDetected ==
    /\ tIdx <= Len(TraceLog)
    /\ PrimaryCancelDetected
    /\ UNCHANGED tIdx

SilentSecondarySeeCancelled ==
    /\ tIdx <= Len(TraceLog)
    /\ \E t \in Secondaries : SecondarySeeCancelled(t)
    /\ UNCHANGED tIdx

\* =========================================================================
\* TraceInit and TraceNext
\* =========================================================================

\* Override Init to allow non-deterministic barrierType
\* (Cancel traces need BarrierCancel from the start)
TraceInit ==
    /\ generation = 0
    /\ taskPending = FALSE
    /\ waitingForTask = FALSE
    /\ cancelled = FALSE
    /\ secondaryArrived = FALSE
    /\ holding = FALSE
    /\ taskCount = 0
    /\ taskDetachCount = 0
    /\ threadGen = [t \in Thread |-> 0]
    /\ primaryWaiting = [t \in Thread |-> FALSE]
    /\ cancelArrived = FALSE
    /\ threadCGen = [t \in Thread |-> 0]
    /\ primaryWaitingC = [t \in Thread |-> FALSE]
    /\ pc = [t \in Thread |-> "idle"]
    /\ scanIndex = CHOOSE t \in Secondaries : \A s \in Secondaries : t <= s
    /\ barrierRound = 0
    /\ barrierType \in {BarrierNormal, BarrierCancel}
    /\ prevHolding = FALSE
    /\ teamId = 0
    /\ threadTeamId = [t \in Thread |-> 0]
    /\ threadBarPtr = [t \in Thread |-> 0]
    /\ tIdx = 1

TraceNext ==
    IF tIdx <= Len(TraceLog) THEN
        \* --- Trace actions (consume event) ---
        \/ TraceCreateTask
        \/ TracePrimaryBarrierWaitStart
        \/ TraceSecondaryBarrierWaitStart
        \/ TraceEnsureLast
        \/ TraceHandleTasksAcquireLock
        \/ TraceHandleTasksReleaseLock
        \/ TraceHandleTasksExecuteTask
        \/ TraceHandleTasksSetWaitingForTask
        \/ TraceHandleTasksAllDone
        \/ TraceHandleTasksLastThreadNoTasks
        \/ TraceCancel
        \/ TraceNonAtomicTaskCountDecrement
        \* --- Silent actions (don't consume) ---
        \/ SilentPrimaryCheckThread
        \/ SilentPrimaryCheckCancelThread
        \/ SilentSecondaryCheckFallback
        \/ SilentSecondaryCheckCancelFallback
        \/ SilentSecondaryEnterBarrier
        \/ SilentSecondaryPassBarrier
        \/ SilentSecondaryPassCancelBarrier
        \/ SilentPrimaryHandleTaskLast
        \/ SilentPrimaryCompleteBarrier
        \/ SilentPrimaryStartNextRound
        \/ SilentPrimaryReleasePrev
        \/ SilentPrimaryCancelDetected
        \/ SilentSecondarySeeCancelled
    ELSE
        UNCHANGED trace_all_vars

\* =========================================================================
\* Trace Consumption Check
\* =========================================================================

\* This invariant is TRUE while events remain.  It becomes FALSE when
\* tIdx > Len(TraceLog), i.e. the trace was fully consumed.
\* Run with -deadlock flag; a "TraceConsumed violated" error means SUCCESS.
TraceConsumed == tIdx <= Len(TraceLog)

\* =========================================================================
\* Debugging Alias
\* =========================================================================

TraceAlias == [
    tIdx |-> tIdx,
    event |-> IF tIdx <= Len(TraceLog) THEN logline.event ELSE "END",
    tid |-> IF tIdx <= Len(TraceLog) THEN logline.tid ELSE -1,
    pc |-> pc,
    generation |-> generation,
    taskCount |-> taskCount,
    taskPending |-> taskPending,
    waitingForTask |-> waitingForTask,
    cancelled |-> cancelled,
    scanIndex |-> scanIndex,
    barrierRound |-> barrierRound,
    barrierType |-> barrierType
]

===============================================================
