--------------------------- MODULE base_mutation_holding_1 ---------------------------
(*
 * MUTATION TEST: PrimaryReleasePrev WITHOUT the prevHolding guard.
 * Models a bug where gomp_release_held_threads (team.c:34-50) is called
 * unconditionally -- even when there are no secondaries held from a
 * previous barrier round. This could corrupt the generation counter
 * (spurious increment) or clear holding when it shouldn't.
 *
 * Expected: generation counter corruption should break BarrierSafety
 * or SecondaryStateConsistency, and spurious holding=FALSE should break
 * HoldingCorrectness.
 *)

EXTENDS base

\* Override PrimaryReleasePrev: remove prevHolding guard
PrimaryReleasePrevMutated ==
    \* MUTATION: removed /\ prevHolding guard
    /\ pc[Primary] = "idle"  \* Primary is setting up next region
    /\ generation' = generation + 1
    /\ holding' = FALSE
    /\ prevHolding' = FALSE
    /\ UNCHANGED <<taskPending, waitingForTask, cancelled, secondaryArrived,
                   taskCount, threadGenVars, cancelVars,
                   pc, scanIndex, barrierRound, barrierType, teamVars>>

\* Mutated Next: replace PrimaryReleasePrev with mutated version
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
    \/ PrimaryHandleTaskLast
    \/ \E t \in Secondaries : SecondaryHandleTask(t)
    \/ CancelBarrier
    \/ PrimaryReleasePrevMutated  \* <-- MUTATED
    \/ PrimaryStartNextRound

MutatedSpec == Init /\ [][MutatedNext]_allVars

===============================================================
