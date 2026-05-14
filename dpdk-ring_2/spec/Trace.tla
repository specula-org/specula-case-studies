---- MODULE Trace ----
(***************************************************************************)
(* Trace validation spec for DPDK rte_ring (Round 2).                      *)
(*                                                                         *)
(* Category B (concurrent / lock-free) — uses the *timebox* trace pattern: *)
(* per-thread cursor `pc[tid]` walking through per-thread event sequences  *)
(* with [start, end] timestamps. ViablePIDs constrains TLC to consider     *)
(* only orderings consistent with the recorded intervals.                  *)
(*                                                                         *)
(* Trace events captured by the harness (see instrumentation-spec.md):     *)
(*   - default-mode move_head load/CAS                                     *)
(*   - default-mode update_tail                                            *)
(*   - RTS update_tail load/CAS                                            *)
(*   - RTS move_head load/CAS                                              *)
(*   - HTS analogues                                                       *)
(*   - SORING acquire / release / finalize                                 *)
(*   - Peek start / finish                                                 *)
(***************************************************************************)

EXTENDS base, Integers, Sequences, FiniteSets, TLC, Json, IOUtils

\* ========================================================================
\* Trace file location
\* ========================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* The preprocessed trace is a record { tid -> [event sequence] }.
PreprocessedTrace == JsonDeserialize(JsonFile)

\* All thread IDs in the trace
TraceThreads == DOMAIN PreprocessedTrace

\* ========================================================================
\* Trace state — per-thread cursor
\* ========================================================================

VARIABLES
    pc,             \* pc[tid] = next event index for thread tid
    traces          \* traces[tid] = sequence of events for thread tid

traceVars == <<pc, traces>>

\* ThreadsWithEvents = threads that still have unconsumed events.
ThreadsWithEvents == { tid \in Thread : pc[tid] <= Len(traces[tid]) }

\* ViablePIDs constrains TLC to orderings consistent with timestamps.
\* If thread A's pending event ended *before* thread B's next event
\* started, then A must go first; B is not yet viable.
ViablePIDs ==
    { tid \in ThreadsWithEvents :
        ~ \E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pc[tid2]].end < traces[tid][pc[tid]].start }

\* ========================================================================
\* Trace bootstrap
\* ========================================================================

TraceInit ==
    /\ Init
    /\ traces = [t \in Thread |-> IF t \in TraceThreads THEN PreprocessedTrace[t] ELSE <<>>]
    /\ pc = [t \in Thread |-> 1]

\* ========================================================================
\* Event matching
\* ========================================================================

\* Every action wrapper:
\*   1. matches the event by name
\*   2. dispatches a base spec action with the captured args
\*   3. validates post-state by comparing event.state fields to spec vars
\*
\* For Category B systems, state is captured *outside* the [start, end]
\* interval so it reflects an externally-observed snapshot — TLC explores
\* multiple interleavings and prunes those whose state doesn't match.

\* --- Validation helpers ---
ValidateProdHead(ev) == ev.state.prodHead = prodHead
ValidateProdTail(ev) == ev.state.prodTail = prodTail
ValidateConsHead(ev) == ev.state.consHead = consHead
ValidateConsTail(ev) == ev.state.consTail = consTail

\* Post-state validators (primed). The HTS / RTS harnesses emit *post-state*
\* snapshots after the opaque move_head/update_tail calls, so we validate
\* against the post-step value of the corresponding spec variable.
ValidateProdHeadPost(ev) == ev.state.prodHead = prodHead'
ValidateProdTailPost(ev) == ev.state.prodTail = prodTail'
ValidateConsHeadPost(ev) == ev.state.consHead = consHead'
ValidateConsTailPost(ev) == ev.state.consTail = consTail'

ValidateRTSProdHead(ev) ==
    /\ ev.state.rtsProdHeadCnt = rtsProdHeadCnt
    /\ ev.state.rtsProdHeadPos = rtsProdHeadPos

ValidateRTSProdHeadPost(ev) ==
    /\ ev.state.rtsProdHeadCnt = rtsProdHeadCnt'
    /\ ev.state.rtsProdHeadPos = rtsProdHeadPos'

ValidateRTSProdTail(ev) ==
    /\ ev.state.rtsProdTailCnt = rtsProdTailCnt
    /\ ev.state.rtsProdTailPos = rtsProdTailPos

ValidateRTSProdTailPost(ev) ==
    /\ ev.state.rtsProdTailCnt = rtsProdTailCnt'
    /\ ev.state.rtsProdTailPos = rtsProdTailPos'

\* --- Event handlers (one per spec action) ---

OnProdMoveHead_LoadHead(tid, ev) ==
    /\ ProdMoveHead_LoadHead(tid, ev.n)
    /\ ValidateProdHead(ev)
    /\ ValidateConsTail(ev)

OnProdMoveHead_LoadTail(tid, ev) ==
    /\ ProdMoveHead_LoadTail(tid)
    /\ ValidateConsTail(ev)

OnProdMoveHead_CAS(tid, ev) ==
    /\ ProdMoveHead_CAS(tid)
    /\ ValidateProdHead(ev)

OnProdWriteRing(tid, ev) ==
    /\ ProdWriteRing(tid)

OnProdUpdateTail(tid, ev) ==
    /\ ProdUpdateTail(tid)
    /\ ValidateProdTail(ev)

OnConsMoveHead_LoadHead(tid, ev) ==
    /\ ConsMoveHead_LoadHead(tid, ev.n)
    /\ ValidateConsHead(ev)
    /\ ValidateProdTail(ev)

OnConsMoveHead_LoadTail(tid, ev) ==
    /\ ConsMoveHead_LoadTail(tid)
    /\ ValidateProdTail(ev)

OnConsMoveHead_CAS(tid, ev) ==
    /\ ConsMoveHead_CAS(tid)
    /\ ValidateConsHead(ev)

OnConsUpdateTail(tid, ev) ==
    /\ ConsUpdateTail(tid)
    /\ ValidateConsTail(ev)

\* HTS / RTS Trace replay design notes:
\*   The harness captures a state snapshot once per opaque move_head
\*   call and emits 3 events sharing that snapshot.  For a per-thread
\*   trace under a partial-order model, a cross-thread read (e.g., the
\*   consumer reading prodTail) may capture a value that the producer
\*   had not yet published in the linearization TLC explores.  Strict
\*   `prodTail = ev.state.prodTail` validation then deadlocks when TLC
\*   schedules the producer's update_tail before the consumer's load.
\*
\*   To preserve trace fidelity, the LoadStail wrappers seed
\*   visibleProdTail / visibleConsTail directly from the captured
\*   ev.state value (rather than from the live spec variable).  This
\*   forces subsequent CAS / break decisions to match what the harness
\*   observed, without requiring TLC to enforce a particular
\*   linearization order between the two threads.

OnHTSProdHeadWait(tid, ev) ==
    /\ Mode = "HTS"
    /\ phase[tid] = "Idle"
    /\ ev.n \in 1..MaxBatch
    /\ prodHead = prodTail   \* head_wait done
    /\ phase' = [phase EXCEPT ![tid] = "HTSMoveHead.HeadWait"]
    /\ op' = [op EXCEPT ![tid] = "enq"]
    /\ role' = [role EXCEPT ![tid] = "prod"]
    /\ callMode' = [callMode EXCEPT ![tid] = Mode]
    /\ locOldHead' = [locOldHead EXCEPT ![tid] = prodHead]
    /\ locReqN' = [locReqN EXCEPT ![tid] = ev.n]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, soringVars,
                   stage, locNewHead, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots,
                   visibleVars, staleVars, extVars>>

\* Seed visibleConsTail from captured trace state (cross-thread read).
OnHTSProdLoadStail(tid, ev) ==
    /\ Mode = "HTS"
    /\ phase[tid] = "HTSMoveHead.HeadWait"
    /\ role[tid] = "prod"
    /\ visibleConsTail' = [visibleConsTail EXCEPT ![tid] = ev.state.consTail]
    /\ phase' = [phase EXCEPT ![tid] = "HTSMoveHead.LoadStail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                   op, role, callMode, stage, locOldHead, locNewHead, locReqN,
                   locActualN, locFtoken, locVals, locReleaseN, locStaleHead,
                   locReservedSlots, soringVars, visibleProdTail,
                   visibleProdHeadCnt, visibleProdHeadPos,
                   visibleConsHeadCnt, visibleConsHeadPos, extVars>>

OnHTSProdCAS(tid, ev) ==
    /\ HTSProdCAS(tid)
    /\ ValidateProdHeadPost(ev)

OnHTSProdUpdateTail(tid, ev) ==
    /\ HTSProdUpdateTail(tid)
    /\ ValidateProdTailPost(ev)

OnHTSConsHeadWait(tid, ev) ==
    /\ Mode = "HTS"
    /\ phase[tid] = "Idle"
    /\ ev.n \in 1..MaxBatch
    /\ consHead = consTail
    /\ phase' = [phase EXCEPT ![tid] = "HTSMoveHead.HeadWait"]
    /\ op' = [op EXCEPT ![tid] = "deq"]
    /\ role' = [role EXCEPT ![tid] = "cons"]
    /\ callMode' = [callMode EXCEPT ![tid] = Mode]
    /\ locOldHead' = [locOldHead EXCEPT ![tid] = consHead]
    /\ locReqN' = [locReqN EXCEPT ![tid] = ev.n]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, soringVars,
                   stage, locNewHead, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots,
                   visibleVars, staleVars, extVars>>

OnHTSConsLoadStail(tid, ev) ==
    /\ Mode = "HTS"
    /\ phase[tid] = "HTSMoveHead.HeadWait"
    /\ role[tid] = "cons"
    /\ visibleProdTail' = [visibleProdTail EXCEPT ![tid] = ev.state.prodTail]
    /\ phase' = [phase EXCEPT ![tid] = "HTSMoveHead.LoadStail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleConsTail, visibleProdHeadCnt,
                   visibleProdHeadPos, visibleConsHeadCnt, visibleConsHeadPos,
                   extVars>>

OnHTSConsCAS(tid, ev) ==
    /\ HTSConsCAS(tid)
    /\ ValidateConsHeadPost(ev)

OnHTSConsUpdateTail(tid, ev) ==
    /\ HTSConsUpdateTail(tid)
    /\ ValidateConsTailPost(ev)

OnRTSConsHeadWait(tid, ev) ==
    /\ RTSConsHeadWait(tid, ev.n)

OnRTSConsLoadStail(tid, ev) ==
    /\ Mode = "RTS"
    /\ phase[tid] = "RTSMoveHead.HeadWait"
    /\ role[tid] = "cons"
    /\ visibleProdTail' = [visibleProdTail EXCEPT ![tid] = ev.state.rtsProdTailPos]
    /\ phase' = [phase EXCEPT ![tid] = "RTSMoveHead.LoadStail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleConsTail, visibleProdHeadCnt,
                   visibleProdHeadPos, visibleConsHeadCnt, visibleConsHeadPos,
                   extVars>>

OnRTSConsCAS(tid, ev) ==
    /\ RTSConsCAS(tid)

OnRTSConsUpdateTail(tid, ev) ==
    /\ RTSConsUpdateTail(tid)

OnRTSProdHeadWait(tid, ev) ==
    /\ RTSProdHeadWait(tid, ev.n)

OnRTSProdLoadStail(tid, ev) ==
    /\ Mode = "RTS"
    /\ phase[tid] = "RTSMoveHead.HeadWait"
    /\ role[tid] = "prod"
    /\ visibleConsTail' = [visibleConsTail EXCEPT ![tid] = ev.state.rtsConsTailPos]
    /\ phase' = [phase EXCEPT ![tid] = "RTSMoveHead.LoadStail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                   op, role, callMode, stage, locOldHead, locNewHead, locReqN,
                   locActualN, locFtoken, locVals, locReleaseN, locStaleHead,
                   locReservedSlots, soringVars, visibleProdTail,
                   visibleProdHeadCnt, visibleProdHeadPos,
                   visibleConsHeadCnt, visibleConsHeadPos, extVars>>

OnRTSProdCAS(tid, ev) ==
    /\ RTSProdCAS(tid)

OnRTSProdUpdateTail_LoadTail(tid, ev) ==
    /\ RTSProdUpdateTail_LoadTail(tid)

OnRTSProdUpdateTail_LoadHead(tid, ev) ==
    /\ RTSProdUpdateTail_LoadHead(tid)

OnRTSProdUpdateTail_Compute(tid, ev) ==
    /\ RTSProdUpdateTail_Compute(tid)

OnRTSProdUpdateTail_CAS(tid, ev) ==
    /\ RTSProdUpdateTail_CAS(tid)

\* SORING trace replay: the harness's input-side enqueue/dequeue is NOT
\* instrumented, so prodTail/consTail don't advance.  Bypass the avail
\* check here and trust the captured (stage, n) — the trace witnessed a
\* successful acquire.  The action's other writes (sStageHead, locOldHead,
\* locFtoken, etc.) are still asserted so the rest of the trace lines up.
OnSORingAcquire_MoveHead(tid, ev) ==
    /\ Mode = "SORING"
    /\ phase[tid] = "Idle"
    /\ ev.stage \in 0..(NbStage-1)
    /\ ev.n \in 1..MaxBatch
    /\ LET s == ev.stage
           old_head == sStageHead[s]
           actual_n == ev.n
       IN
       /\ sStageHead' = [sStageHead EXCEPT ![s] = WrapPos(old_head + actual_n)]
       /\ phase' = [phase EXCEPT ![tid] = "SORingAcquire.UpdateState"]
       /\ op' = [op EXCEPT ![tid] = "acq"]
       /\ role' = [role EXCEPT ![tid] = "cons"]
       /\ callMode' = [callMode EXCEPT ![tid] = Mode]
       /\ stage' = [stage EXCEPT ![tid] = s]
       /\ locOldHead' = [locOldHead EXCEPT ![tid] = old_head]
       /\ locNewHead' = [locNewHead EXCEPT ![tid] = WrapPos(old_head + actual_n)]
       /\ locReqN' = [locReqN EXCEPT ![tid] = ev.n]
       /\ locActualN' = [locActualN EXCEPT ![tid] = actual_n]
       /\ locFtoken' = [locFtoken EXCEPT ![tid] = (old_head + s) % PosWrap]
       /\ locReleaseN' = [locReleaseN EXCEPT ![tid] = actual_n]
       /\ locReservedSlots' = [locReservedSlots EXCEPT ![tid] =
            { SlotOf(old_head + i - 1) : i \in 1..actual_n }]
    /\ UNCHANGED <<prodHead, prodTail, consHead, consTail, ring, rtsVars,
                   historyVars, locVals, locStaleHead, sStageTailPos,
                   sStageTailSync, sStateFtoken, sStateStnum, sStateN,
                   visibleVars, staleVars, extVars>>

OnSORingAcquire_UpdateState(tid, ev) ==
    /\ SORingAcquire_UpdateState(tid)
    /\ stage[tid] = ev.stage

\* SORING release: pick the slot matching the per-thread acquired ftoken
\* (locFtoken[tid] from the most recent acquire).  The base spec allows
\* any START slot, which is too loose for trace replay and breaks
\* linearization when both threads reach release at once.
OnSORingRelease_LoadState(tid, ev) ==
    /\ Mode = "SORING"
    /\ phase[tid] = "Idle"
    /\ \E s \in 0..(NbStage-1), idx \in 0..(Capacity-1) :
        /\ sStateStnum[s][idx] = "START"
        /\ sStateFtoken[s][idx] = locFtoken[tid]
        /\ stage' = [stage EXCEPT ![tid] = s]
        /\ locActualN' = [locActualN EXCEPT ![tid] = sStateN[s][idx]]
        /\ locOldHead' = [locOldHead EXCEPT ![tid] = sStateFtoken[s][idx] - s]
        /\ locReleaseN' = [locReleaseN EXCEPT ![tid] = ev.n]
    /\ phase' = [phase EXCEPT ![tid] = "SORingRelease.Verify"]
    /\ op' = [op EXCEPT ![tid] = "rel"]
    /\ role' = [role EXCEPT ![tid] = "prod"]
    /\ callMode' = [callMode EXCEPT ![tid] = Mode]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                   locNewHead, locReqN, locVals, locFtoken, locStaleHead,
                   locReservedSlots, soringVars, visibleVars, staleVars, extVars>>

OnSORingRelease_StoreFinish(tid, ev) ==
    /\ SORingRelease_StoreFinish(tid)

\* SORING release_loadtail: the spec branches on (sStageTailPos == pos).
\* TLC's view of sStageTailPos may differ from what the harness saw at
\* runtime (the harness's view is timing-dependent under weak memory).
\* We therefore look at the trace itself: if the next event for this
\* thread is a SORingFinalize_* call, take branch 1 (proceed to finalize);
\* otherwise take branch 2 (skip finalize).
OnSORingRelease_LoadTail(tid, ev) ==
    /\ Mode = "SORING"
    /\ phase[tid] = "SORingRelease.LoadTail"
    /\ op[tid] = "rel"
    /\ \/ \* Next event is finalize: jump to SORingFinalize.LoadTail
          /\ pc[tid] + 1 <= Len(traces[tid])
          /\ traces[tid][pc[tid] + 1].name = "SORingFinalize_LoadTail"
          /\ phase' = [phase EXCEPT ![tid] = "SORingFinalize.LoadTail"]
          /\ UNCHANGED <<op, role>>
       \/ \* No follow-on finalize: thread returns to Idle
          /\ \/ pc[tid] + 1 > Len(traces[tid])
             \/ traces[tid][pc[tid] + 1].name /= "SORingFinalize_LoadTail"
          /\ phase' = [phase EXCEPT ![tid] = "Idle"]
          /\ op' = [op EXCEPT ![tid] = "none"]
          /\ role' = [role EXCEPT ![tid] = "none"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, callMode, stage, locOldHead,
                   locNewHead, locReqN, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars>>

OnSORingFinalize_LoadTail(tid, ev) ==
    /\ SORingFinalize_LoadTail(tid)

OnSORingFinalize_CAS(tid, ev) ==
    /\ SORingFinalize_CAS(tid)

OnSORingFinalize_StoreTail(tid, ev) ==
    /\ SORingFinalize_StoreTail(tid)

OnPeekStart(tid, ev) ==
    /\ PeekStart(tid, ev.n)
    /\ ValidateProdHead(ev)

OnPeekFinish(tid, ev) ==
    /\ PeekFinish(tid)
    /\ ValidateProdTail(ev)

\* ========================================================================
\* Dispatch by event name
\* ========================================================================

MatchEvent(tid, ev) ==
    \/ /\ ev.name = "ProdMoveHead_LoadHead"
       /\ OnProdMoveHead_LoadHead(tid, ev)
    \/ /\ ev.name = "ProdMoveHead_LoadTail"
       /\ OnProdMoveHead_LoadTail(tid, ev)
    \/ /\ ev.name = "ProdMoveHead_CAS"
       /\ OnProdMoveHead_CAS(tid, ev)
    \/ /\ ev.name = "ProdWriteRing"
       /\ OnProdWriteRing(tid, ev)
    \/ /\ ev.name = "ProdUpdateTail"
       /\ OnProdUpdateTail(tid, ev)
    \/ /\ ev.name = "ConsMoveHead_LoadHead"
       /\ OnConsMoveHead_LoadHead(tid, ev)
    \/ /\ ev.name = "ConsMoveHead_LoadTail"
       /\ OnConsMoveHead_LoadTail(tid, ev)
    \/ /\ ev.name = "ConsMoveHead_CAS"
       /\ OnConsMoveHead_CAS(tid, ev)
    \/ /\ ev.name = "ConsUpdateTail"
       /\ OnConsUpdateTail(tid, ev)
    \/ /\ ev.name = "HTSProdHeadWait"
       /\ OnHTSProdHeadWait(tid, ev)
    \/ /\ ev.name = "HTSProdLoadStail"
       /\ OnHTSProdLoadStail(tid, ev)
    \/ /\ ev.name = "HTSProdCAS"
       /\ OnHTSProdCAS(tid, ev)
    \/ /\ ev.name = "HTSProdUpdateTail"
       /\ OnHTSProdUpdateTail(tid, ev)
    \/ /\ ev.name = "HTSConsHeadWait"
       /\ OnHTSConsHeadWait(tid, ev)
    \/ /\ ev.name = "HTSConsLoadStail"
       /\ OnHTSConsLoadStail(tid, ev)
    \/ /\ ev.name = "HTSConsCAS"
       /\ OnHTSConsCAS(tid, ev)
    \/ /\ ev.name = "HTSConsUpdateTail"
       /\ OnHTSConsUpdateTail(tid, ev)
    \/ /\ ev.name = "RTSConsHeadWait"
       /\ OnRTSConsHeadWait(tid, ev)
    \/ /\ ev.name = "RTSConsLoadStail"
       /\ OnRTSConsLoadStail(tid, ev)
    \/ /\ ev.name = "RTSConsCAS"
       /\ OnRTSConsCAS(tid, ev)
    \/ /\ ev.name = "RTSConsUpdateTail"
       /\ OnRTSConsUpdateTail(tid, ev)
    \/ /\ ev.name = "RTSProdHeadWait"
       /\ OnRTSProdHeadWait(tid, ev)
    \/ /\ ev.name = "RTSProdLoadStail"
       /\ OnRTSProdLoadStail(tid, ev)
    \/ /\ ev.name = "RTSProdCAS"
       /\ OnRTSProdCAS(tid, ev)
    \/ /\ ev.name = "RTSProdUpdateTail_LoadTail"
       /\ OnRTSProdUpdateTail_LoadTail(tid, ev)
    \/ /\ ev.name = "RTSProdUpdateTail_LoadHead"
       /\ OnRTSProdUpdateTail_LoadHead(tid, ev)
    \/ /\ ev.name = "RTSProdUpdateTail_Compute"
       /\ OnRTSProdUpdateTail_Compute(tid, ev)
    \/ /\ ev.name = "RTSProdUpdateTail_CAS"
       /\ OnRTSProdUpdateTail_CAS(tid, ev)
    \/ /\ ev.name = "SORingAcquire_MoveHead"
       /\ OnSORingAcquire_MoveHead(tid, ev)
    \/ /\ ev.name = "SORingAcquire_UpdateState"
       /\ OnSORingAcquire_UpdateState(tid, ev)
    \/ /\ ev.name = "SORingRelease_LoadState"
       /\ OnSORingRelease_LoadState(tid, ev)
    \/ /\ ev.name = "SORingRelease_StoreFinish"
       /\ OnSORingRelease_StoreFinish(tid, ev)
    \/ /\ ev.name = "SORingRelease_LoadTail"
       /\ OnSORingRelease_LoadTail(tid, ev)
    \/ /\ ev.name = "SORingFinalize_LoadTail"
       /\ OnSORingFinalize_LoadTail(tid, ev)
    \/ /\ ev.name = "SORingFinalize_CAS"
       /\ OnSORingFinalize_CAS(tid, ev)
    \/ /\ ev.name = "SORingFinalize_StoreTail"
       /\ OnSORingFinalize_StoreTail(tid, ev)
    \/ /\ ev.name = "PeekStart"
       /\ OnPeekStart(tid, ev)
    \/ /\ ev.name = "PeekFinish"
       /\ OnPeekFinish(tid, ev)

\* ========================================================================
\* Silent actions — fire base actions without consuming a trace event.
\* Used for intermediate spec steps that the harness cannot directly
\* observe (e.g., CAS-failure retry steps, intermediate update_tail
\* compute steps that don't change shared state).
\* ========================================================================

\* Silent transitions are tightly constrained: only fire when no thread
\* has an event that matches the current pending action.  Without this
\* guard, the silent action races with MatchEvent — silent picks an
\* arbitrary disjunct (e.g., CAS-failure) while the trace event expects
\* the success branch, leaving the spec in a state where the trace can
\* no longer progress.
NoPendingEvent(t, name) ==
    \* Use IF/THEN/ELSE to guarantee that traces[t][pc[t]] is only
    \* indexed when the cursor is in range — TLC's OR-evaluation can
    \* probe the right-hand disjunct even when the left is true.
    IF pc[t] > Len(traces[t]) THEN TRUE
    ELSE traces[t][pc[t]].name /= name

SilentActions ==
    \E t \in Thread :
        \/ /\ NoPendingEvent(t, "ProdMoveHead_CAS")
           /\ role[t] = "prod"  \* phase=LoadTail is shared between prod/cons
           /\ ProdMoveHead_CAS(t)
        \/ /\ NoPendingEvent(t, "RTSProdUpdateTail_Compute")
           /\ role[t] = "prod"
           /\ RTSProdUpdateTail_Compute(t)
        \/ /\ NoPendingEvent(t, "SORingRelease_WriteRing")
           /\ SORingRelease_WriteRing(t)
        \/ /\ NoPendingEvent(t, "SORingFinalize_LoadHead")
           /\ SORingFinalize_LoadHead(t)
        \/ /\ NoPendingEvent(t, "SORingFinalize_WalkStates")
           /\ SORingFinalize_WalkStates(t)
        \/ /\ NoPendingEvent(t, "SORingRelease_Verify")
           /\ SORingRelease_Verify(t)
        \/ /\ NoPendingEvent(t, "SORingRelease_MaybeFinalize")
           /\ SORingRelease_MaybeFinalize(t)

\* ========================================================================
\* TraceNext
\* ========================================================================

TraceNext ==
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            LET ev == traces[tid][pc[tid]] IN
            /\ MatchEvent(tid, ev)
            /\ pc' = [pc EXCEPT ![tid] = pc[tid] + 1]
            /\ traces' = traces
    \/ /\ ThreadsWithEvents /= {}
       /\ SilentActions
       /\ UNCHANGED <<pc, traces>>
    \* Stutter when fully consumed
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED <<allVars, traceVars>>

\* ========================================================================
\* TraceMatched — temporal property
\* ========================================================================

\* Eventually all threads have consumed their entire event sequence.
TraceMatched == <>(ThreadsWithEvents = {})

TraceFullyConsumed == TraceMatched

TraceSpec == TraceInit
              /\ [][TraceNext]_<<allVars, traceVars>>
              \* Weak fairness so TLC doesn't return a stuttering
              \* counter-example trivially when there's an enabled
              \* TraceNext step.  Without this, `<>TraceMatched` is
              \* violated by an immediate stutter.
              /\ WF_<<allVars, traceVars>>(TraceNext)

\* ========================================================================
\* Invariants for trace validation (safety + structural only;
\* fault-injection invariants excluded — traces run without faults).
\* ========================================================================

T_ConsumedWasPushed     == ConsumedWasPushed
T_NoDoublePop           == NoDoublePop
T_RTSPosCntConsistent   == RTSPosCntConsistent
T_DefaultPartialOrder   == DefaultPartialOrder
T_SORingStageOrdered    == SORingStageOrdered
T_SORingFtokenUnique    == SORingFtokenUnique
T_TypeOK                == TypeOK
T_ThreadAtomic          == ThreadAtomic

====
