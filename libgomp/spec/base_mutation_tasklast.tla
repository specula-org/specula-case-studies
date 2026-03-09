--------------------------- MODULE base_mutation_tasklast ---------------------------
(*
 * MUTATION TEST: PrimaryHandleTaskLast for BarrierCancel WITHOUT cancel check.
 * This models the ACTUAL implementation bug at task.c:1659-1673 where
 * gomp_team_barrier_done is called without checking BAR_CANCELLED.
 * This is bug #28.
 *)

EXTENDS base

\* Override PrimaryHandleTaskLast: remove cancel check
PrimaryHandleTaskLastMutated ==
    /\ pc[Primary] = "primary_handle_task_last"
    /\ IF taskCount > 0 /\ taskPending
       THEN /\ taskCount' = taskCount - 1
            /\ taskPending' = IF taskCount - 1 > 0 THEN TRUE ELSE FALSE
            /\ UNCHANGED <<generation, waitingForTask, cancelled,
                           secondaryArrived, holding, pc>>
       ELSE IF barrierType = BarrierFinal
       THEN /\ holding' = TRUE
            /\ waitingForTask' = FALSE
            /\ pc' = [pc EXCEPT ![Primary] = "done"]
            /\ UNCHANGED <<generation, taskPending, cancelled,
                           secondaryArrived, taskCount>>
       ELSE IF barrierType = BarrierCancel
       THEN \* MUTATION: removed cancel check — always complete
            /\ generation' = generation + 1
            /\ waitingForTask' = FALSE
            /\ pc' = [pc EXCEPT ![Primary] = "done"]
            /\ UNCHANGED <<taskPending, cancelled,
                           secondaryArrived, holding, taskCount>>
       ELSE /\ generation' = generation + 1
            /\ waitingForTask' = FALSE
            /\ pc' = [pc EXCEPT ![Primary] = "done"]
            /\ UNCHANGED <<taskPending, cancelled, secondaryArrived,
                           holding, taskCount>>
    /\ UNCHANGED <<threadGenVars, cancelVars, scanIndex,
                   barrierRound, barrierType, holdingVars, teamVars>>

MutatedNext ==
    \/ PrimaryEnterBarrier
    \/ \E t \in Secondaries : SecondaryEnterBarrier(t)
    \/ \E t \in Secondaries : SecondaryCheckFallback(t)
    \/ \E t \in Secondaries : SecondaryEnterCancelBarrier(t)
    \/ \E t \in Secondaries : SecondaryCheckCancelFallback(t)
    \/ \E t \in Secondaries : SecondarySeeCancelled(t)
    \/ PrimaryCheckThread
    \/ PrimaryCheckCancelThread
    \/ PrimaryEnterFallback
    \/ PrimaryWakeFromFallback
    \/ PrimaryEnterCancelFallback
    \/ PrimaryWakeFromCancelFallback
    \/ PrimaryCompleteBarrier
    \/ PrimaryCancelDetected
    \/ \E t \in Secondaries : SecondaryPassBarrier(t)
    \/ \E t \in Secondaries : SecondaryPassCancelBarrier(t)
    \/ ScheduleTask
    \/ PrimaryHandleTask
    \/ PrimaryHandleTaskLastMutated  \* <-- MUTATED
    \/ \E t \in Secondaries : SecondaryHandleTask(t)
    \/ CancelBarrier
    \/ PrimaryReleasePrev
    \/ PrimaryStartNextRound

MutatedSpec == Init /\ [][MutatedNext]_allVars

===============================================================
