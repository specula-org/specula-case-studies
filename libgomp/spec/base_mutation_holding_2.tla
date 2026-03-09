--------------------------- MODULE base_mutation_holding_2 ---------------------------
(*
 * MUTATION TEST: PrimaryStartNextRound WITHOUT transferring holding -> prevHolding.
 * Models a bug where team.c:1222 (pool->prev_barrier = &team->barrier) is
 * omitted -- the primary clears holding but doesn't save the reference for
 * later release. This means secondaries from a BarrierFinal round are
 * never released (holding is cleared but generation never incremented).
 *
 * Expected: Secondaries stuck in "waiting" forever, or use-after-free because
 * generation is never incremented to release them. Should violate HoldingCorrectness
 * or cause deadlock.
 *)

EXTENDS base

\* Override PrimaryStartNextRound: don't transfer holding -> prevHolding
PrimaryStartNextRoundMutated ==
    /\ pc[Primary] = "done"
    /\ \A t \in Secondaries :
         \/ pc[t] = "done"
         \/ (holding /\ pc[t] = "waiting")  \* Secondaries held from final barrier
    /\ IF holding
       THEN \* MUTATION: clear holding but DON'T set prevHolding
            \* This means PrimaryReleasePrev will never fire for these secondaries
            /\ prevHolding' = FALSE  \* <-- BUG: should be TRUE
            /\ holding' = FALSE
       ELSE /\ prevHolding' = prevHolding
            /\ UNCHANGED holding
    /\ barrierRound' = barrierRound + 1
    \* Reset for next round
    /\ cancelled' = FALSE
    /\ secondaryArrived' = FALSE
    /\ cancelArrived' = FALSE
    /\ waitingForTask' = FALSE
    /\ taskPending' = FALSE
    /\ taskCount' = 0
    \* Family 4: new team
    /\ teamId' = teamId + 1
    /\ threadTeamId' = [t \in Thread |-> teamId + 1]
    /\ threadBarPtr' = [t \in Thread |-> teamId + 1]
    \* Choose next barrier type non-deterministically
    /\ barrierType' \in {BarrierNormal, BarrierFinal, BarrierCancel}
    /\ pc' = [t \in Thread |-> "idle"]
    /\ scanIndex' = CHOOSE t \in Secondaries : \A s \in Secondaries : t <= s
    \* Team recreation
    /\ primaryWaiting' = [t \in Thread |-> FALSE]
    /\ primaryWaitingC' = [t \in Thread |-> FALSE]
    /\ UNCHANGED <<generation, threadGen, threadCGen>>

\* Mutated Next: replace PrimaryStartNextRound with mutated version
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
    \/ PrimaryReleasePrev
    \/ PrimaryStartNextRoundMutated  \* <-- MUTATED

MutatedSpec == Init /\ [][MutatedNext]_allVars

===============================================================
