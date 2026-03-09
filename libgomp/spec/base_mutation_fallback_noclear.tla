--------------------------- MODULE base_mutation_fallback_noclear ---------------------------
(*
 * MUTATION TEST: PrimaryCheckThread does NOT clear primaryWaiting when
 * BAR_SECONDARY_ARRIVED is handled.
 *
 * This models removing bar.c:380-381 in gomp_team_barrier_ensure_last:
 *   __atomic_fetch_and(&arr[i].gen, ~PRIMARY_WAITING_TG, MEMMODEL_RELAXED)
 *
 * If PRIMARY_WAITING_TG stays set on the secondary's gen after BAR_SECONDARY_ARRIVED
 * is cleared, the secondary's gen value will permanently have the flag, which
 * breaks the "thread arrived" check (threadgen == tstate + BAR_INCR test will fail
 * because it actually has PRIMARY_WAITING_TG too).
 *
 * In the TLA+ model, the primary checking loop will keep falling through to the
 * bar->generation check instead of advancing, and the secondary could never
 * trigger another BAR_SECONDARY_ARRIVED because the check at gomp_assert_and_increment_flag
 * already passed. This could lead to livelock in the ensure_last loop.
 *
 * Expected: PrimaryFallbackConsistency or FallbackCorrectness violated,
 *           or deadlock from livelock.
 *)

EXTENDS base

\* Override PrimaryCheckThread: when BAR_SECONDARY_ARRIVED, clear secondaryArrived
\* but do NOT clear primaryWaiting (simulating missing fetch_and on arr[i].gen)
PrimaryCheckThreadMutated ==
    /\ pc[Primary] = "scanning"
    /\ scanIndex \in Secondaries
    /\ barrierType # BarrierCancel
    /\ IF ThreadArrived(scanIndex) /\ ~primaryWaiting[scanIndex]
       THEN /\ UNCHANGED <<globalBarVars, threadGenVars>>
            /\ IF scanIndex = CHOOSE t \in Secondaries : \A s \in Secondaries : t >= s
               THEN /\ pc' = [pc EXCEPT ![Primary] = "all_arrived"]
                    /\ UNCHANGED scanIndex
               ELSE /\ scanIndex' = scanIndex + 1
                    /\ UNCHANGED pc
       ELSE IF taskPending
       THEN /\ pc' = [pc EXCEPT ![Primary] = "primary_handle_task"]
            /\ UNCHANGED <<scanIndex, globalBarVars, threadGenVars>>
       ELSE IF secondaryArrived
       THEN \* MUTATION: clear BAR_SECONDARY_ARRIVED but do NOT clear primaryWaiting
            /\ secondaryArrived' = FALSE
            \* Original: primaryWaiting' = [primaryWaiting EXCEPT ![scanIndex] = FALSE]
            /\ UNCHANGED primaryWaiting  \* <-- BUG: stale PRIMARY_WAITING_TG
            /\ pc' = [pc EXCEPT ![Primary] = "scanning"]
            /\ UNCHANGED <<generation, taskPending, waitingForTask,
                           cancelled, holding, taskCount,
                           threadGen, scanIndex>>
       ELSE /\ pc' = [pc EXCEPT ![Primary] = "enter_fallback"]
            /\ UNCHANGED <<globalBarVars, threadGenVars, scanIndex>>
    /\ UNCHANGED <<cancelVars, barrierRound, barrierType, holdingVars, teamVars>>

\* Mutated Next
MutatedNext ==
    \/ PrimaryEnterBarrier
    \/ \E t \in Secondaries : SecondaryEnterBarrier(t)
    \/ \E t \in Secondaries : SecondaryCheckFallback(t)
    \/ \E t \in Secondaries : SecondaryEnterCancelBarrier(t)
    \/ \E t \in Secondaries : SecondaryCheckCancelFallback(t)
    \/ \E t \in Secondaries : SecondarySeeCancelled(t)
    \/ PrimaryCheckThreadMutated  \* <-- MUTATED
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
    \/ PrimaryStartNextRound

MutatedSpec == Init /\ [][MutatedNext]_allVars

===============================================================
