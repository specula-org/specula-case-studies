--------------------------- MODULE MC ---------------------------
(*
 * Model checking specification for libgomp flat barrier protocol.
 *
 * Wraps the base spec with counter-bounded non-deterministic actions.
 * Deterministic/reactive actions pass through unbounded.
 *
 * Counter-bounded actions (non-deterministic injection):
 *   - ScheduleTask (external task scheduling)
 *   - ScheduleDetachTask (detachable task scheduling)
 *   - CancelBarrier (cancellation event)
 *
 * Restricted actions:
 *   - PrimaryStartNextRound (barrier type restricted to BarrierTypeSet)
 *
 * Unbounded actions (deterministic/reactive):
 *   - All barrier entry/exit, primary scanning, fallback protocol,
 *     task handling, holding lifecycle
 *)

EXTENDS base

\* Access original (un-overridden) operator definitions
libgomp == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

CONSTANT MaxScheduleTaskLimit  \* Max task scheduling events
CONSTANT MaxDetachScheduleLimit \* Max detach task scheduling events
CONSTANT MaxCancelLimit        \* Max cancellation events
CONSTANT BarrierTypeSet        \* Subset of {BarrierNormal, BarrierFinal, BarrierCancel}

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

VARIABLE faultCounters

faultVars == <<faultCounters>>

\* ============================================================================
\* COUNTER-BOUNDED ACTIONS
\* ============================================================================

\* --- ScheduleTask: bound external task injection ---
MCScheduleTask ==
    /\ faultCounters.schedule < MaxScheduleTaskLimit
    /\ libgomp!ScheduleTask
    /\ faultCounters' = [faultCounters EXCEPT !.schedule = @ + 1]

\* --- ScheduleDetachTask: bound detachable task injection ---
MCScheduleDetachTask ==
    /\ faultCounters.detachSchedule < MaxDetachScheduleLimit
    /\ libgomp!ScheduleDetachTask
    /\ faultCounters' = [faultCounters EXCEPT !.detachSchedule = @ + 1]

\* --- CancelBarrier: bound cancellation events ---
MCCancelBarrier ==
    /\ faultCounters.cancel < MaxCancelLimit
    /\ libgomp!CancelBarrier
    /\ faultCounters' = [faultCounters EXCEPT !.cancel = @ + 1]

\* --- PrimaryStartNextRound: restrict barrier type choices ---
MCPrimaryStartNextRound ==
    /\ pc[Primary] = "done"
    /\ \A t \in Secondaries :
         \/ pc[t] = "done"
         \/ (holding /\ pc[t] = "waiting")
    /\ IF holding
       THEN /\ prevHolding' = TRUE
            /\ holding' = FALSE
       ELSE /\ prevHolding' = prevHolding
            /\ UNCHANGED holding
    /\ barrierRound' = barrierRound + 1
    /\ cancelled' = FALSE
    /\ secondaryArrived' = FALSE
    /\ cancelArrived' = FALSE
    /\ waitingForTask' = FALSE
    /\ taskPending' = FALSE
    /\ taskCount' = 0
    /\ taskDetachCount' = 0
    /\ teamId' = teamId + 1
    /\ threadTeamId' = [t \in Thread |-> teamId + 1]
    /\ threadBarPtr' = [t \in Thread |-> teamId + 1]
    \* KEY: restrict barrier type to BarrierTypeSet (for hunting configs)
    /\ barrierType' \in BarrierTypeSet
    /\ pc' = [t \in Thread |-> "idle"]
    /\ scanIndex' = CHOOSE t \in Secondaries : \A s \in Secondaries : t <= s
    /\ primaryWaiting' = [t \in Thread |-> FALSE]
    /\ primaryWaitingC' = [t \in Thread |-> FALSE]
    /\ UNCHANGED <<generation, threadGen, threadCGen>>
    /\ UNCHANGED faultVars

\* ============================================================================
\* NEXT STATE RELATION
\* ============================================================================

MCNext ==
    \* --- Barrier entry (unbounded, reactive) ---
    \/ (PrimaryEnterBarrier /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryEnterBarrier(t) /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryCheckFallback(t) /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryEnterCancelBarrier(t) /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryCheckCancelFallback(t) /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondarySeeCancelled(t) /\ UNCHANGED faultVars)
    \* --- Primary scanning (unbounded, reactive) ---
    \/ (PrimaryCheckThread /\ UNCHANGED faultVars)
    \/ (PrimaryCheckCancelThread /\ UNCHANGED faultVars)
    \* --- Fallback protocol (unbounded, reactive) ---
    \/ (PrimaryEnterFallback /\ UNCHANGED faultVars)
    \/ (PrimaryWakeFromFallback /\ UNCHANGED faultVars)
    \/ (PrimaryEnterCancelFallback /\ UNCHANGED faultVars)
    \/ (PrimaryWakeFromCancelFallback /\ UNCHANGED faultVars)
    \* --- Barrier completion (unbounded, reactive) ---
    \/ (PrimaryCompleteBarrier /\ UNCHANGED faultVars)
    \/ (PrimaryCancelDetected /\ UNCHANGED faultVars)
    \* --- Secondary waiting (unbounded, reactive) ---
    \/ (\E t \in Secondaries : SecondaryPassBarrier(t) /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryPassCancelBarrier(t) /\ UNCHANGED faultVars)
    \* --- Task handling (unbounded for handlers, bounded for scheduling) ---
    \/ MCScheduleTask
    \/ MCScheduleDetachTask
    \/ (PrimaryHandleTask /\ UNCHANGED faultVars)
    \/ (PrimaryHandleTaskLast /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryHandleTask(t) /\ UNCHANGED faultVars)
    \* --- Detach task lifecycle (unbounded, reactive) ---
    \/ (DetachTaskBodyComplete /\ UNCHANGED faultVars)
    \/ (FulfillEvent /\ UNCHANGED faultVars)
    \/ (WaitingPrimaryCompleteBarrier /\ UNCHANGED faultVars)
    \/ (PrimaryPassBarrierFromWaiting /\ UNCHANGED faultVars)
    \* --- Cancellation (bounded) ---
    \/ MCCancelBarrier
    \* --- Holding lifecycle (unbounded, reactive) ---
    \/ (PrimaryReleasePrev /\ UNCHANGED faultVars)
    \* --- Round transition (restricted barrier type) ---
    \/ MCPrimaryStartNextRound

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [schedule |-> 0, detachSchedule |-> 0, cancel |-> 0]

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

mc_vars == <<allVars, faultVars>>

MCSpec == MCInit /\ [][MCNext]_mc_vars

\* ============================================================================
\* VIEW (exclude fault counters from state fingerprint)
\* ============================================================================

ModelView == <<allVars>>

\* ============================================================================
\* STATE SPACE PRUNING
\* ============================================================================

\* Barrier type constraint for hunting configs
BarrierTypeConstraint ==
    barrierType \in BarrierTypeSet

\* ============================================================================
\* STRUCTURAL INVARIANTS
\* ============================================================================

\* All pc values are in the expected set
PcInRange ==
    \A t \in Thread :
        pc[t] \in {"idle", "scanning", "sec_arrived", "waiting",
                   "enter_fallback", "fallback_waiting", "all_arrived",
                   "done", "primary_handle_task", "primary_handle_task_last",
                   "sec_cancel_arrived", "cancel_waiting",
                   "enter_cancel_fallback", "cancel_fallback_waiting",
                   "cancel_detected"}

\* scanIndex is always a valid secondary (when scanning)
ScanIndexValid ==
    pc[Primary] \in {"scanning", "enter_fallback", "fallback_waiting",
                     "enter_cancel_fallback", "cancel_fallback_waiting",
                     "primary_handle_task"}
        => scanIndex \in Secondaries

\* barrierRound never exceeds MaxBarriers
RoundBound ==
    barrierRound <= MaxBarriers

\* taskCount is bounded
TaskCountBound ==
    taskCount <= MaxTasks

\* Per-thread gen never goes backward
ThreadGenMonotonic ==
    \A t \in Thread : threadGen[t] >= 0

===============================================================
