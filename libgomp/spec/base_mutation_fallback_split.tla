--------------------------- MODULE base_mutation_fallback_split ---------------------------
(*
 * MUTATION TEST: Split-atomicity of futex_waitv fallback.
 *
 * The real implementation's futex_waitv fallback (for pre-5.16 kernels) does:
 *   1) fetch_or(addr, PRIMARY_WAITING_TG) -- always sets the flag
 *   2) Check old value: if thread arrived, store clean value and return
 *   3) Otherwise, futex_wait on bar->generation
 *
 * The base spec models this as atomic: PrimaryEnterFallback either
 * sets the flag (if thread not arrived) or doesn't (if arrived).
 *
 * This mutation models the split: PrimaryEnterFallback ALWAYS sets the flag,
 * then a separate action checks and potentially clears it. This exposes the
 * window where PRIMARY_WAITING_TG is set even though the thread arrived.
 *
 * If the secondary's check (SecondaryCheckFallback) runs in this window,
 * it could set BAR_SECONDARY_ARRIVED spuriously.
 *
 * Expected: Either clean (the spec handles spurious BAR_SECONDARY_ARRIVED)
 * or FallbackCorrectness violated.
 *)

EXTENDS base

(*
 * Mutated PrimaryEnterFallback: ALWAYS sets PRIMARY_WAITING_TG, regardless
 * of whether thread arrived. Goes to "fallback_check" state.
 *)
PrimaryEnterFallbackMutated ==
    /\ pc[Primary] = "enter_fallback"
    \* Always set the flag (models the fetch_or which unconditionally sets it)
    /\ primaryWaiting' = [primaryWaiting EXCEPT ![scanIndex] = TRUE]
    /\ pc' = [pc EXCEPT ![Primary] = "fallback_check"]
    /\ UNCHANGED <<globalBarVars, threadGen, cancelVars,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

(*
 * New action: Primary checks if thread arrived AFTER setting flag.
 * Models: futex_waitv.h:103-124 check after fetch_or
 *)
PrimaryFallbackCheck ==
    /\ pc[Primary] = "fallback_check"
    /\ IF ThreadArrived(scanIndex)
       THEN \* Thread arrived — clear flag and go back to scanning
            /\ primaryWaiting' = [primaryWaiting EXCEPT ![scanIndex] = FALSE]
            /\ pc' = [pc EXCEPT ![Primary] = "scanning"]
       ELSE \* Thread not arrived — enter wait
            /\ pc' = [pc EXCEPT ![Primary] = "fallback_waiting"]
            /\ UNCHANGED primaryWaiting
    /\ UNCHANGED <<globalBarVars, threadGen, cancelVars,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

(*
 * Similarly for cancel fallback.
 *)
PrimaryEnterCancelFallbackMutated ==
    /\ pc[Primary] = "enter_cancel_fallback"
    /\ primaryWaitingC' = [primaryWaitingC EXCEPT ![scanIndex] = TRUE]
    /\ pc' = [pc EXCEPT ![Primary] = "cancel_fallback_check"]
    /\ UNCHANGED <<globalBarVars, threadGenVars, primaryWaiting,
                   cancelArrived, threadCGen,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

PrimaryCancelFallbackCheck ==
    /\ pc[Primary] = "cancel_fallback_check"
    /\ IF threadCGen[scanIndex] > threadCGen[Primary] - 1
       THEN /\ primaryWaitingC' = [primaryWaitingC EXCEPT ![scanIndex] = FALSE]
            /\ pc' = [pc EXCEPT ![Primary] = "scanning"]
       ELSE /\ pc' = [pc EXCEPT ![Primary] = "cancel_fallback_waiting"]
            /\ UNCHANGED primaryWaitingC
    /\ UNCHANGED <<globalBarVars, threadGenVars, primaryWaiting,
                   cancelArrived, threadCGen,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

\* Mutated Next
MutatedNext ==
    \/ PrimaryEnterBarrier
    \/ \E t \in Secondaries : SecondaryEnterBarrier(t)
    \/ \E t \in Secondaries : SecondaryCheckFallback(t)
    \/ \E t \in Secondaries : SecondaryEnterCancelBarrier(t)
    \/ \E t \in Secondaries : SecondaryCheckCancelFallback(t)
    \/ \E t \in Secondaries : SecondarySeeCancelled(t)
    \/ PrimaryCheckThread
    \/ PrimaryCheckCancelThread
    \/ PrimaryEnterFallbackMutated   \* <-- SPLIT: always set flag
    \/ PrimaryFallbackCheck          \* <-- SPLIT: then check
    \/ PrimaryWakeFromFallback
    \/ PrimaryEnterCancelFallbackMutated  \* <-- SPLIT
    \/ PrimaryCancelFallbackCheck         \* <-- SPLIT
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
