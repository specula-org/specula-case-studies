--------------------------- MODULE base_mutation_holding_3 ---------------------------
(*
 * MUTATION TEST: PrimaryCompleteBarrier for BarrierFinal WITHOUT setting holding=TRUE.
 * Models a bug where bar.c:500-511 omits the BAR_HOLDING_SECONDARIES flag --
 * the primary just increments generation like a normal barrier, releasing
 * secondaries immediately instead of holding them.
 *
 * This is a use-after-free scenario: secondaries proceed to next region code
 * while the primary may be destroying/reconfiguring the team structure.
 *
 * Expected: Should violate HoldingCorrectness or HoldingImpliesFinalType,
 * or allow secondaries to reach "done" prematurely.
 *)

EXTENDS base

\* Override PrimaryCompleteBarrier: treat BarrierFinal like BarrierNormal
PrimaryCompleteBarrierMutated ==
    /\ pc[Primary] = "all_arrived"
    /\ IF taskCount > 0
       THEN \* bar.c:429-434: tasks pending, handle them first
            /\ pc' = [pc EXCEPT ![Primary] = "primary_handle_task_last"]
            /\ waitingForTask' = TRUE
            /\ UNCHANGED <<generation, taskPending, cancelled,
                           secondaryArrived, holding, taskCount>>
       ELSE IF barrierType = BarrierFinal
       THEN \* MUTATION: don't set holding=TRUE, just increment generation
            \* like a normal barrier — secondaries released immediately
            /\ generation' = generation + 1  \* <-- BUG: should set holding=TRUE instead
            /\ pc' = [pc EXCEPT ![Primary] = "done"]
            /\ UNCHANGED <<taskPending, waitingForTask,
                           cancelled, secondaryArrived, holding, taskCount>>
       ELSE IF barrierType = BarrierCancel
       THEN IF cancelled
            THEN /\ pc' = [pc EXCEPT ![Primary] = "cancel_detected"]
                 /\ UNCHANGED <<generation, taskPending, waitingForTask, cancelled,
                                secondaryArrived, holding, taskCount>>
            ELSE /\ generation' = generation + 1
                 /\ pc' = [pc EXCEPT ![Primary] = "done"]
                 /\ UNCHANGED <<taskPending, waitingForTask, cancelled,
                                secondaryArrived, holding, taskCount>>
       ELSE \* bar.c:437-439: normal barrier — increment generation
            /\ generation' = generation + 1
            /\ pc' = [pc EXCEPT ![Primary] = "done"]
            /\ UNCHANGED <<taskPending, waitingForTask, cancelled,
                           secondaryArrived, holding, taskCount>>
    /\ UNCHANGED <<threadGenVars, cancelVars, scanIndex, barrierRound,
                   barrierType, holdingVars, teamVars>>

\* Also need to mutate PrimaryHandleTaskLast for BarrierFinal path
PrimaryHandleTaskLastMutated ==
    /\ pc[Primary] = "primary_handle_task_last"
    /\ IF taskCount > 0 /\ taskPending
       THEN /\ taskCount' = taskCount - 1
            /\ taskPending' = IF taskCount - 1 > 0 THEN TRUE ELSE FALSE
            /\ UNCHANGED <<generation, waitingForTask, cancelled,
                           secondaryArrived, holding, pc>>
       ELSE IF barrierType = BarrierFinal
       THEN \* MUTATION: don't set holding=TRUE, just increment generation
            /\ generation' = generation + 1  \* <-- BUG: should set holding=TRUE instead
            /\ waitingForTask' = FALSE
            /\ pc' = [pc EXCEPT ![Primary] = "done"]
            /\ UNCHANGED <<taskPending, cancelled,
                           secondaryArrived, holding, taskCount>>
       ELSE IF barrierType = BarrierCancel
       THEN IF cancelled
            THEN /\ waitingForTask' = FALSE
                 /\ pc' = [pc EXCEPT ![Primary] = "cancel_detected"]
                 /\ UNCHANGED <<generation, taskPending, cancelled,
                                secondaryArrived, holding, taskCount>>
            ELSE /\ generation' = generation + 1
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

\* Mutated Next: replace both PrimaryCompleteBarrier and PrimaryHandleTaskLast
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
    \/ PrimaryCompleteBarrierMutated   \* <-- MUTATED
    \/ PrimaryCancelDetected
    \/ \E t \in Secondaries : SecondaryPassBarrier(t)
    \/ \E t \in Secondaries : SecondaryPassCancelBarrier(t)
    \/ ScheduleTask
    \/ PrimaryHandleTask
    \/ PrimaryHandleTaskLastMutated    \* <-- MUTATED
    \/ \E t \in Secondaries : SecondaryHandleTask(t)
    \/ CancelBarrier
    \/ PrimaryReleasePrev
    \/ PrimaryStartNextRound

MutatedSpec == Init /\ [][MutatedNext]_allVars

===============================================================
