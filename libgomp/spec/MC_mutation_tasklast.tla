--------------------------- MODULE MC_mutation_tasklast ---------------------------
EXTENDS base_mutation_tasklast

libgomp_mut == INSTANCE base_mutation_tasklast

CONSTANT MaxScheduleTaskLimit
CONSTANT MaxCancelLimit
CONSTANT BarrierTypeSet

VARIABLE faultCounters
faultVars == <<faultCounters>>

MCScheduleTask ==
    /\ faultCounters.schedule < MaxScheduleTaskLimit
    /\ libgomp_mut!ScheduleTask
    /\ faultCounters' = [faultCounters EXCEPT !.schedule = @ + 1]

MCCancelBarrier ==
    /\ faultCounters.cancel < MaxCancelLimit
    /\ libgomp_mut!CancelBarrier
    /\ faultCounters' = [faultCounters EXCEPT !.cancel = @ + 1]

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
    /\ teamId' = teamId + 1
    /\ threadTeamId' = [t \in Thread |-> teamId + 1]
    /\ threadBarPtr' = [t \in Thread |-> teamId + 1]
    /\ barrierType' \in BarrierTypeSet
    /\ pc' = [t \in Thread |-> "idle"]
    /\ scanIndex' = CHOOSE t \in Secondaries : \A s \in Secondaries : t <= s
    /\ primaryWaiting' = [t \in Thread |-> FALSE]
    /\ primaryWaitingC' = [t \in Thread |-> FALSE]
    /\ UNCHANGED <<generation, threadGen, threadCGen>>
    /\ UNCHANGED faultVars

MCNext ==
    \/ (PrimaryEnterBarrier /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryEnterBarrier(t) /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryCheckFallback(t) /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryEnterCancelBarrier(t) /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryCheckCancelFallback(t) /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondarySeeCancelled(t) /\ UNCHANGED faultVars)
    \/ (PrimaryCheckThread /\ UNCHANGED faultVars)
    \/ (PrimaryCheckCancelThread /\ UNCHANGED faultVars)
    \/ (PrimaryEnterFallback /\ UNCHANGED faultVars)
    \/ (PrimaryWakeFromFallback /\ UNCHANGED faultVars)
    \/ (PrimaryEnterCancelFallback /\ UNCHANGED faultVars)
    \/ (PrimaryWakeFromCancelFallback /\ UNCHANGED faultVars)
    \/ (PrimaryCompleteBarrier /\ UNCHANGED faultVars)
    \/ (PrimaryCancelDetected /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryPassBarrier(t) /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryPassCancelBarrier(t) /\ UNCHANGED faultVars)
    \/ MCScheduleTask
    \/ (PrimaryHandleTask /\ UNCHANGED faultVars)
    \/ (PrimaryHandleTaskLastMutated /\ UNCHANGED faultVars)
    \/ (\E t \in Secondaries : SecondaryHandleTask(t) /\ UNCHANGED faultVars)
    \/ MCCancelBarrier
    \/ (PrimaryReleasePrev /\ UNCHANGED faultVars)
    \/ MCPrimaryStartNextRound

MCInit ==
    /\ Init
    /\ faultCounters = [schedule |-> 0, cancel |-> 0]

mc_vars == <<allVars, faultVars>>
MCSpec == MCInit /\ [][MCNext]_mc_vars
ModelView == <<allVars>>

===============================================================
