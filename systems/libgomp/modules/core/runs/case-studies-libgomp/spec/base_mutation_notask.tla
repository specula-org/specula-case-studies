--------------------------- MODULE base_mutation_notask ---------------------------
(*
 * MUTATION TEST: PrimaryCompleteBarrier for BarrierCancel WITHOUT cancel check.
 * This models the implementation's actual behavior at bar.c:746-751 where
 * the primary stores the incremented cancel generation WITHOUT checking
 * BAR_CANCELLED first.
 *
 * Expected: BarrierSafety should be violated if cancel fires between
 * ensure_cancel_last and the store.
 *)

EXTENDS base

\* Override PrimaryCompleteBarrier: remove cancel check for BarrierCancel no-task path
PrimaryCompleteBarrierMutated ==
    /\ pc[Primary] = "all_arrived"
    /\ IF taskCount > 0
       THEN /\ pc' = [pc EXCEPT ![Primary] = "primary_handle_task_last"]
            /\ waitingForTask' = TRUE
            /\ UNCHANGED <<generation, taskPending, cancelled,
                           secondaryArrived, holding, taskCount>>
       ELSE IF barrierType = BarrierFinal
       THEN /\ holding' = TRUE
            /\ pc' = [pc EXCEPT ![Primary] = "done"]
            /\ UNCHANGED <<generation, taskPending, waitingForTask,
                           cancelled, secondaryArrived, taskCount>>
       ELSE IF barrierType = BarrierCancel
       THEN \* MUTATION: removed "IF cancelled" check — always complete
            /\ generation' = generation + 1
            /\ pc' = [pc EXCEPT ![Primary] = "done"]
            /\ UNCHANGED <<taskPending, waitingForTask, cancelled,
                           secondaryArrived, holding, taskCount>>
       ELSE /\ generation' = generation + 1
            /\ pc' = [pc EXCEPT ![Primary] = "done"]
            /\ UNCHANGED <<taskPending, waitingForTask, cancelled,
                           secondaryArrived, holding, taskCount>>
    /\ UNCHANGED <<threadGenVars, cancelVars, scanIndex, barrierRound,
                   barrierType, holdingVars, teamVars>>

\* Mutated Next: replace PrimaryCompleteBarrier with mutated version
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
    \/ PrimaryCompleteBarrierMutated  \* <-- MUTATED
    \/ PrimaryCancelDetected
    \/ \E t \in Secondaries : SecondaryPassBarrier(t)
    \/ \E t \in Secondaries : SecondaryPassCancelBarrier(t)
    \/ ScheduleTask
    \/ PrimaryHandleTask
    \/ PrimaryHandleTaskLast
    \/ \E t \in Secondaries : SecondaryHandleTask(t)
    \/ CancelBarrier
    \/ PrimaryReleasePrev
    \/ PrimaryStartNextRound

MutatedSpec == Init /\ [][MutatedNext]_allVars

===============================================================
