--------------------------- MODULE base_mutation_fallback_stale ---------------------------
(*
 * MUTATION TEST: PrimaryStartNextRound does NOT reset primaryWaitingC.
 *
 * This models a scenario where gomp_barrier_reinit_1 (or minimal_reinit)
 * fails to clear PRIMARY_WAITING_TG on cgen when re-initializing the barrier
 * for the next team/parallel region.
 *
 * If a stale PRIMARY_WAITING_TG from a cancelled barrier round persists
 * into the next cancel barrier round, the secondary could spuriously
 * interpret it and set BAR_SECONDARY_CANCELLABLE_ARRIVED, causing the
 * primary to clear cgen flags prematurely.
 *
 * Expected: FallbackCorrectness or CgenConsistency violated.
 *)

EXTENDS base

\* Override PrimaryStartNextRound: do NOT clear primaryWaitingC
PrimaryStartNextRoundMutated ==
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
    /\ barrierType' \in {BarrierNormal, BarrierFinal, BarrierCancel}
    /\ pc' = [t \in Thread |-> "idle"]
    /\ scanIndex' = CHOOSE t \in Secondaries : \A s \in Secondaries : t <= s
    \* Clear primaryWaiting (gen path) as normal
    /\ primaryWaiting' = [t \in Thread |-> FALSE]
    \* MUTATION: do NOT clear primaryWaitingC (cgen path)
    /\ UNCHANGED primaryWaitingC  \* <-- BUG: stale PRIMARY_WAITING_TG on cgen
    /\ UNCHANGED <<generation, threadGen, threadCGen>>

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
