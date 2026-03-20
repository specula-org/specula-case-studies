---- MODULE MC ----
\* Model checking wrapper for libomp barrier + tasking specification
\* Adds counter-bounded fault injection for non-deterministic actions
\* and structural invariants for state space exploration.

EXTENDS base

\* Named instance for access to un-overridden operator definitions
libomp == INSTANCE base

\* --------------------------------------------------------------------------
\* Counter-bounded action limits
\* --------------------------------------------------------------------------
CONSTANTS
    MaxScheduleTaskLimit,       \* Max normal task scheduling events
    MaxScheduleDetachLimit,     \* Max detachable task scheduling events
    MaxCancelLimit,             \* Max cancel barrier events
    MaxStealFromReapedLimit,    \* Max steal-from-reaped events (Family 2 bug path)
    MaxReapLimit,               \* Max team teardown events
    MaxSerialLimit              \* Max serialized parallel entry events (Family 6)

\* --------------------------------------------------------------------------
\* Fault injection counter variables
\* --------------------------------------------------------------------------
VARIABLE faultCounters

faultVars == <<faultCounters>>

mc_vars == <<allVars, faultVars>>

\* --------------------------------------------------------------------------
\* Counter-bounded wrappers
\* --------------------------------------------------------------------------

\* Bound task scheduling (non-deterministic injection)
MCScheduleTask ==
    /\ faultCounters.schedule < MaxScheduleTaskLimit
    /\ \E t \in Thread : ScheduleTask(t)
    /\ faultCounters' = [faultCounters EXCEPT !.schedule = faultCounters.schedule + 1]

\* Bound detachable task scheduling (Family 3)
MCScheduleDetachTask ==
    /\ faultCounters.detachSchedule < MaxScheduleDetachLimit
    /\ \E t \in Thread : ScheduleDetachTask(t)
    /\ faultCounters' = [faultCounters EXCEPT !.detachSchedule = faultCounters.detachSchedule + 1]

\* Bound barrier cancellation (Family 5)
MCCancelBarrier ==
    /\ faultCounters.cancel < MaxCancelLimit
    /\ CancelBarrier
    /\ faultCounters' = [faultCounters EXCEPT !.cancel = faultCounters.cancel + 1]

\* Bound steal-from-reaped bug path (Family 2)
MCStealFromReapedThread ==
    /\ faultCounters.stealFromReaped < MaxStealFromReapedLimit
    /\ \E thief, victim \in Thread : StealFromReapedThread(thief, victim)
    /\ faultCounters' = [faultCounters EXCEPT !.stealFromReaped = faultCounters.stealFromReaped + 1]

\* Bound team teardown (Family 2)
MCReapTeam ==
    /\ faultCounters.reap < MaxReapLimit
    /\ ReapTeam
    /\ faultCounters' = [faultCounters EXCEPT !.reap = faultCounters.reap + 1]

MCReapThread ==
    /\ faultCounters.reap <= MaxReapLimit  \* Reap thread follows reap team, share counter
    /\ \E t \in Workers : ReapThread(t)
    /\ UNCHANGED faultVars

\* Bound serialized parallel entry (Family 6)
MCSerializedParallelEntry ==
    /\ faultCounters.serial < MaxSerialLimit
    /\ \E t \in Thread : SerializedParallelEntry(t)
    /\ faultCounters' = [faultCounters EXCEPT !.serial = faultCounters.serial + 1]

MCSerializedParallelExit ==
    /\ \E t \in Thread : SerializedParallelExit(t)
    /\ UNCHANGED faultVars

\* --------------------------------------------------------------------------
\* Unconstrained (reactive/deterministic) actions
\* --------------------------------------------------------------------------

MCPrimaryEnterBarrier ==
    /\ PrimaryEnterBarrier
    /\ UNCHANGED faultVars

MCWorkerEnterBarrier ==
    /\ \E t \in Workers : WorkerEnterBarrier(t)
    /\ UNCHANGED faultVars

MCWorkerStartTasks ==
    /\ \E t \in Workers : WorkerStartTasks(t)
    /\ UNCHANGED faultVars

MCPrimaryStartTaskWait ==
    /\ PrimaryStartTaskWait
    /\ UNCHANGED faultVars

MCExecuteTask ==
    /\ \E t \in Thread : ExecuteTask(t)
    /\ UNCHANGED faultVars

MCStealTask ==
    /\ \E thief, victim \in Thread : StealTask(thief, victim)
    /\ UNCHANGED faultVars

MCCompleteTask ==
    /\ \E t \in Thread, task \in Task : CompleteTask(t, task)
    /\ UNCHANGED faultVars

MCDetachTask ==
    /\ \E t \in Thread, task \in Task : DetachTask(t, task)
    /\ UNCHANGED faultVars

MCFulfillEvent ==
    /\ \E task \in Task : FulfillEvent(task)
    /\ UNCHANGED faultVars

MCEarlyFulfillEvent ==
    /\ \E task \in Task : EarlyFulfillEvent(task)
    /\ UNCHANGED faultVars

MCProxyTaskComplete ==
    /\ \E task \in Task : ProxyTaskComplete(task)
    /\ UNCHANGED faultVars

MCThreadFinishTasks ==
    /\ \E t \in Thread : ThreadFinishTasks(t)
    /\ UNCHANGED faultVars

\* Weak variant: thread marks finished even if tasks exist elsewhere (faithful to real code)
MCThreadFinishTasksWeak ==
    /\ \E t \in Thread : ThreadFinishTasksWeak(t)
    /\ UNCHANGED faultVars

MCPrimaryTaskTeamWait ==
    /\ PrimaryTaskTeamWait
    /\ UNCHANGED faultVars

MCPrimaryRelease ==
    /\ PrimaryRelease
    /\ UNCHANGED faultVars

MCWorkerReceiveRelease ==
    /\ \E t \in Workers : WorkerReceiveRelease(t)
    /\ UNCHANGED faultVars

MCTaskTeamSync ==
    /\ \E t \in Thread : TaskTeamSync(t)
    /\ UNCHANGED faultVars

MCBarrierDone ==
    /\ \E t \in Thread : BarrierDone(t)
    /\ UNCHANGED faultVars

MCStartNextRound ==
    /\ StartNextRound
    /\ UNCHANGED faultVars

MCPrimaryCancelledBarrier ==
    /\ PrimaryCancelledBarrier
    /\ UNCHANGED faultVars

MCWorkerCancelledBarrier ==
    /\ \E t \in Workers : WorkerCancelledBarrier(t)
    /\ UNCHANGED faultVars

\* --------------------------------------------------------------------------
\* MCInit and MCNext
\* --------------------------------------------------------------------------

MCInit ==
    /\ Init
    /\ faultCounters = [
            schedule |-> 0,
            detachSchedule |-> 0,
            cancel |-> 0,
            stealFromReaped |-> 0,
            reap |-> 0,
            serial |-> 0
       ]

MCNext ==
    \* Barrier lifecycle (unconstrained)
    \/ MCPrimaryEnterBarrier
    \/ MCWorkerEnterBarrier
    \/ MCWorkerStartTasks
    \/ MCPrimaryStartTaskWait
    \* Task execution (unconstrained)
    \/ MCExecuteTask
    \/ MCStealTask
    \/ MCCompleteTask
    \* Detachable task protocol (unconstrained)
    \/ MCDetachTask
    \/ MCFulfillEvent
    \/ MCEarlyFulfillEvent
    \/ MCProxyTaskComplete
    \* Thread finish & barrier sync (unconstrained)
    \/ MCThreadFinishTasks
    \/ MCThreadFinishTasksWeak
    \/ MCPrimaryTaskTeamWait
    \/ MCPrimaryRelease
    \/ MCWorkerReceiveRelease
    \/ MCTaskTeamSync
    \/ MCBarrierDone
    \* Round transition (unconstrained)
    \/ MCStartNextRound
    \* Cancellation handling (unconstrained)
    \/ MCPrimaryCancelledBarrier
    \/ MCWorkerCancelledBarrier
    \* --- Counter-bounded fault injection ---
    \/ MCScheduleTask
    \/ MCScheduleDetachTask
    \/ MCCancelBarrier
    \/ MCStealFromReapedThread
    \/ MCReapTeam
    \/ MCReapThread
    \* --- Serialized parallel (Family 6) ---
    \/ MCSerializedParallelEntry
    \/ MCSerializedParallelExit

MCSpec == MCInit /\ [][MCNext]_mc_vars

\* --------------------------------------------------------------------------
\* VIEW: exclude fault counters from state fingerprint
\* --------------------------------------------------------------------------
ModelView == <<allVars>>

\* Symmetry set for Task permutations
ModelSymmetry == Permutations(Task)

\* --------------------------------------------------------------------------
\* Structural Invariants (always checked)
\* --------------------------------------------------------------------------

\* Program counters are in valid states
PcInRange == \A t \in Thread : pc[t] \in PcStates

\* Barrier round never exceeds max
MCRoundBound == barrierRound <= MaxBarriers

\* Unfinished counters bounded by thread count
UnfinishedBound ==
    /\ unfinished[0] <= NumThreads
    /\ unfinished[1] <= NumThreads

\* Task count bounded by task set size
TaskCountBound ==
    /\ taskCount[0] <= Cardinality(Task)
    /\ taskCount[1] <= Cardinality(Task)

\* Thread finished implies appropriate thread state
FinishedImpliesState ==
    \A t \in Thread :
        threadFinished[t] => threadState[t] \in {"finished", "reaped"}

\* --------------------------------------------------------------------------
\* Temporal Properties
\* --------------------------------------------------------------------------

\* Liveness: if all threads enter the barrier, they eventually all complete
\* (requires fairness - use with WF)
BarrierProgress ==
    (\A t \in Thread : pc[t] = "barrier_gather") ~>
    (\A t \in Thread : pc[t] = "done")

====
