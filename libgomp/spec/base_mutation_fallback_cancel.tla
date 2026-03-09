--------------------------- MODULE base_mutation_fallback_cancel ---------------------------
(*
 * MUTATION TEST: PrimaryCheckCancelThread does NOT clear primaryWaitingC
 * when cancel is detected during scan.
 *
 * This models removing bar.c:676-678 in gomp_team_barrier_ensure_cancel_last:
 *   if (threadgen & PRIMARY_WAITING_TG)
 *     __atomic_fetch_and(&arr[i].cgen, ~PRIMARY_WAITING_TG, ...)
 *
 * If PRIMARY_WAITING_TG is left stale on a thread's cgen when cancel exits,
 * the secondary might spuriously set BAR_SECONDARY_CANCELLABLE_ARRIVED in
 * the next cancel barrier round.
 *
 * Expected: FallbackCorrectness or CgenConsistency violated.
 *)

EXTENDS base

\* Override PrimaryCheckCancelThread: remove primaryWaitingC clear on cancel exit
PrimaryCheckCancelThreadMutated ==
    /\ pc[Primary] = "scanning"
    /\ scanIndex \in Secondaries
    /\ barrierType = BarrierCancel
    /\ IF threadCGen[scanIndex] > threadCGen[Primary] - 1
       THEN \* Thread arrived — but DO NOT clear primaryWaitingC (mutation)
            \* Normal code clears it; we skip that to model the bug
            /\ primaryWaitingC' = [primaryWaitingC EXCEPT ![scanIndex] = FALSE]
            /\ UNCHANGED <<cancelArrived, threadCGen>>
            /\ IF scanIndex = CHOOSE t \in Secondaries : \A s \in Secondaries : t >= s
               THEN /\ pc' = [pc EXCEPT ![Primary] = "all_arrived"]
                    /\ UNCHANGED scanIndex
               ELSE /\ scanIndex' = scanIndex + 1
                    /\ UNCHANGED pc
       ELSE IF cancelled
       THEN \* MUTATION: cancel detected but do NOT clear primaryWaitingC
            \* Original: primaryWaitingC' = [primaryWaitingC EXCEPT ![scanIndex] = FALSE]
            /\ UNCHANGED primaryWaitingC  \* <-- BUG: stale PRIMARY_WAITING_TG
            /\ pc' = [pc EXCEPT ![Primary] = "cancel_detected"]
            /\ UNCHANGED <<scanIndex, cancelArrived, threadCGen>>
       ELSE IF cancelArrived
       THEN /\ cancelArrived' = FALSE
            /\ primaryWaitingC' = [primaryWaitingC EXCEPT ![scanIndex] = FALSE]
            /\ pc' = [pc EXCEPT ![Primary] = "scanning"]
            /\ UNCHANGED <<scanIndex, threadCGen>>
       ELSE IF taskPending
       THEN /\ pc' = [pc EXCEPT ![Primary] = "primary_handle_task"]
            /\ UNCHANGED <<scanIndex, cancelVars>>
       ELSE /\ pc' = [pc EXCEPT ![Primary] = "enter_cancel_fallback"]
            /\ UNCHANGED <<scanIndex, cancelVars>>
    /\ UNCHANGED <<globalBarVars, threadGenVars, barrierRound, barrierType,
                   holdingVars, teamVars>>

\* Mutated Next: replace PrimaryCheckCancelThread with mutated version
MutatedNext ==
    \/ PrimaryEnterBarrier
    \/ \E t \in Secondaries : SecondaryEnterBarrier(t)
    \/ \E t \in Secondaries : SecondaryCheckFallback(t)
    \/ \E t \in Secondaries : SecondaryEnterCancelBarrier(t)
    \/ \E t \in Secondaries : SecondaryCheckCancelFallback(t)
    \/ \E t \in Secondaries : SecondarySeeCancelled(t)
    \/ PrimaryCheckThread
    \/ PrimaryCheckCancelThreadMutated  \* <-- MUTATED
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
