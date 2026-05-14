---- MODULE Trace ----
(***************************************************************************)
(* Trace validation spec for crossbeam-epoch.                              *)
(*                                                                         *)
(* Category B (concurrent / lock-free) — uses the per-thread timebox       *)
(* trace pattern with ViablePIDs partial order.                            *)
(*                                                                         *)
(* Trace events come from a preprocessed JSON file: each thread's events   *)
(* form an array of records with                                           *)
(*   { event, start, end, ...fields }                                      *)
(* where start/end are compressed rdtsc timestamps used by ViablePIDs.     *)
(***************************************************************************)

EXTENDS base, Json, IOUtils, Sequences, TLC, FiniteSets

\* ========================================================================
\* Trace loading
\* ========================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* The preprocessed trace is a record:
\*   threads = <<tid -> [event, start, end, fields...]>>
\* indexed by thread name strings that match the Thread constant.
TraceData == JsonDeserialize(JsonFile)

\* Per-thread trace arrays.  Empty array if a thread has no events.
traces == TraceData.threads

\* ========================================================================
\* Per-thread cursor + viability
\* ========================================================================

VARIABLE pcThread
traceVars == <<pcThread>>

\* Threads that still have unconsumed events.
ThreadsWithEvents ==
    { tid \in Thread :
        /\ tid \in DOMAIN traces
        /\ pcThread[tid] <= Len(traces[tid]) }

\* ViablePIDs (timebox partial order).  A thread tid can step iff no
\* other thread has a pending event that ENDED before tid's next event
\* STARTED.
ViablePIDs ==
    { tid \in ThreadsWithEvents :
        ~ \E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pcThread[tid2]].end < traces[tid][pcThread[tid]].start }

\* ========================================================================
\* Helpers
\* ========================================================================

EventOf(tid)  == traces[tid][pcThread[tid]].event
FieldOf(tid, f) == traces[tid][pcThread[tid]][f]

Advance(tid) == pcThread' = [pcThread EXCEPT ![tid] = pcThread[tid] + 1]

\* ========================================================================
\* Post-state validation
\* ========================================================================
\* For each action wrapper, validate the spec variables that the action
\* modifies, against the captured fields in the trace.  Capture timing
\* is "AFTER the action completes" (per instrumentation-spec.md).

\* PinIncGuardCount: guardCount[t] should now equal recorded.guardCountAfter
ValidatePin(tid) ==
    /\ guardCount'[tid] = FieldOf(tid, "guardCountAfter")

\* PinPublish: localEpoch[t] should equal capturedGlobal
ValidatePinPublish(tid) ==
    /\ localEpoch'[tid] = FieldOf(tid, "localEpochAfter")

\* UnpinDec
ValidateUnpinDec(tid) ==
    /\ guardCount'[tid] = FieldOf(tid, "guardCountAfter")

\* UnpinPublish
ValidateUnpinPublish(tid) ==
    /\ localEpoch'[tid] = UNPINNED

\* TryAdvFinishStore
ValidateTryAdvStore(tid) ==
    /\ globalEpoch' = FieldOf(tid, "globalEpochAfter")

\* Defer
\* Note: bagLenAfter is captured from the impl's bag, which may include
\* the MS-queue's internal node retires (suppressed in the trace). The
\* spec tracks only user-driven defers, so the spec's Len(bag'[t]) is a
\* lower bound on the impl's. Validate weakly: the impl's reported
\* bagLenAfter must be at least the spec's view.
ValidateDefer(tid) ==
    /\ Len(bag'[tid]) <= FieldOf(tid, "bagLenAfter")

\* PushBag
ValidatePushBag(tid) ==
    /\ Len(sealedBags') = FieldOf(tid, "sealedBagsLenAfter")
    /\ Len(bag'[tid]) = 0

\* Repin
ValidateRepin(tid) ==
    /\ localEpoch'[tid] = FieldOf(tid, "localEpochAfter")

\* CollectScan / BagDrop don't change observable user-side state directly.
\* Skip strong validation; structural is enough.

\* ========================================================================
\* Event-to-action dispatch
\* ========================================================================

MatchPinIncGuardCount(tid) ==
    /\ EventOf(tid) = "PinIncGuardCount"
    /\ PinIncGuardCount(tid)
    /\ ValidatePin(tid)

MatchPinLoadGlobal(tid) ==
    /\ EventOf(tid) = "PinLoadGlobal"
    /\ PinLoadGlobal(tid)

MatchPinPublish(tid) ==
    /\ EventOf(tid) = "PinPublish"
    /\ PinPublish(tid)
    /\ ValidatePinPublish(tid)

MatchPinMaybeCollect(tid) ==
    /\ EventOf(tid) = "PinMaybeCollect"
    /\ PinMaybeCollect(tid)
    \* Constrain the spec's non-deterministic branch using the impl's choice.
    /\ IF FieldOf(tid, "triggeredCollect") = TRUE
       THEN pc'[tid] = "PinCollect"
       ELSE pc'[tid] = "Idle"

MatchUnpinDec(tid) ==
    /\ EventOf(tid) = "UnpinDec"
    /\ UnpinDec(tid)
    /\ ValidateUnpinDec(tid)

MatchUnpinPublish(tid) ==
    /\ EventOf(tid) = "UnpinPublish"
    /\ UnpinPublish(tid)
    /\ ValidateUnpinPublish(tid)

MatchRepin(tid) ==
    /\ EventOf(tid) = "Repin"
    /\ Repin(tid)
    /\ ValidateRepin(tid)

MatchTryAdvLoadGlobal(tid) ==
    /\ EventOf(tid) = "TryAdvLoadGlobal"
    /\ TryAdvLoadGlobal(tid)

MatchTryAdvIter(tid) ==
    /\ EventOf(tid) = "TryAdvIter"
    /\ TryAdvIter(tid)
    \* Constrain the spec's non-deterministic branch using the impl's choice.
    /\ CASE FieldOf(tid, "aborted") = "stalled"
              -> pc'[tid] = "TryAdvAbortStalled"
         []   FieldOf(tid, "aborted") = "different_epoch"
              -> pc'[tid] = "TryAdvAbortDifferentEpoch"
         []   OTHER
              -> pc'[tid] \in {"TryAdvIter", "TryAdvFinishStore"}

MatchTryAdvFinishStore(tid) ==
    /\ EventOf(tid) = "TryAdvFinishStore"
    /\ TryAdvFinishStore(tid)
    /\ ValidateTryAdvStore(tid)

MatchDefer(tid) ==
    /\ EventOf(tid) = "Defer"
    /\ LET o == FieldOf(tid, "obj")
       IN /\ Defer(tid, o, "Noop")
          /\ ValidateDefer(tid)

MatchPushBag(tid) ==
    /\ EventOf(tid) = "PushBag"
    /\ PushBag(tid)
    /\ ValidatePushBag(tid)

MatchFlush(tid) ==
    /\ EventOf(tid) = "Flush"
    /\ Flush(tid)

MatchCollectScan(tid) ==
    /\ EventOf(tid) = "CollectScan"
    /\ CollectScan(tid)

MatchBagDrop(tid) ==
    /\ EventOf(tid) = "BagDrop"
    /\ BagDrop(tid)

MatchPublishObject(tid) ==
    /\ EventOf(tid) = "PublishObject"
    /\ PublishObject(tid, FieldOf(tid, "obj"))

MatchUnlinkObject(tid) ==
    /\ EventOf(tid) = "UnlinkObject"
    /\ UnlinkObject(tid, FieldOf(tid, "obj"))

MatchReadAndDeref(tid) ==
    /\ EventOf(tid) = "ReadAndDeref"
    /\ ReadAndDeref(tid, FieldOf(tid, "obj"))

MatchEvent(tid) ==
    \/ MatchPinIncGuardCount(tid)
    \/ MatchPinLoadGlobal(tid)
    \/ MatchPinPublish(tid)
    \/ MatchPinMaybeCollect(tid)
    \/ MatchUnpinDec(tid)
    \/ MatchUnpinPublish(tid)
    \/ MatchRepin(tid)
    \/ MatchTryAdvLoadGlobal(tid)
    \/ MatchTryAdvIter(tid)
    \/ MatchTryAdvFinishStore(tid)
    \/ MatchDefer(tid)
    \/ MatchPushBag(tid)
    \/ MatchFlush(tid)
    \/ MatchCollectScan(tid)
    \/ MatchBagDrop(tid)
    \/ MatchPublishObject(tid)
    \/ MatchUnlinkObject(tid)
    \/ MatchReadAndDeref(tid)

\* ========================================================================
\* Silent actions — fired without consuming a trace event
\* ========================================================================
\* Several base-spec actions are not explicitly traced because they have
\* no observable boundary in the impl (e.g., the mid-step "PinFence"
\* synchronization, or the cleanup CollectScan→Idle transition when the
\* queue is empty).  We allow them as silent transitions.

SilentTryAdvFence ==
    /\ \E t \in Thread : pc[t] = "TryAdvFence" /\ TryAdvFence(t)
    /\ UNCHANGED traceVars

SilentPinCollectFinish ==
    /\ \E t \in Thread : pc[t] = "PinCollect" /\ PinCollectFinish(t)
    /\ UNCHANGED traceVars

SilentTryAdvAbortStalled ==
    /\ \E t \in Thread : pc[t] = "TryAdvAbortStalled" /\ TryAdvAbortStalled(t)
    /\ UNCHANGED traceVars

SilentTryAdvAbortDifferentEpoch ==
    /\ \E t \in Thread :
        pc[t] = "TryAdvAbortDifferentEpoch" /\ TryAdvAbortDifferentEpoch(t)
    /\ UNCHANGED traceVars

SilentInDeferCallbackPin ==
    /\ \E t \in Thread :
        pc[t] = "InDeferCallbackPin" /\ InDeferCallbackPin(t)
    /\ UNCHANGED traceVars

SilentInDeferCallbackUnpin ==
    /\ \E t \in Thread :
        pc[t] = "InDeferCallbackUnpin" /\ InDeferCallbackUnpin(t)
    /\ UNCHANGED traceVars

SilentFinalize ==
    /\ \E t \in Thread :
        pc[t] = "Finalize" /\ Finalize(t)
    /\ UNCHANGED traceVars

SilentFinalizePushBag ==
    /\ \E t \in Thread :
        pc[t] = "FinalizePinned" /\ FinalizePushBag(t)
    /\ UNCHANGED traceVars

SilentFinalizeMarkDeleted ==
    /\ \E t \in Thread :
        pc[t] = "FinalizeMarkDeleted" /\ FinalizeMarkDeleted(t)
    /\ UNCHANGED traceVars

\* The impl's `for local in self.locals.iter(guard)` loop exit is implicit:
\* once the iterator yields no more elements, the code falls through to the
\* post-iteration fence + epoch.store. The spec's TryAdvIter has a third
\* branch (iterIndex >= Cardinality(AliveLocals) → pc=TryAdvFinishStore)
\* that captures this transition. Since the impl emits no event for the
\* loop exit, expose this branch as a silent action.
SilentTryAdvIterFinish ==
    /\ \E t \in Thread :
        /\ pc[t] = "TryAdvIter"
        /\ pcAux[t].iterIndex >= Cardinality(AliveLocals)
        /\ pc' = [pc EXCEPT ![t] = "TryAdvFinishStore"]
        /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                        localEpoch, guardCount, handleCount, pinCount, bag,
                        localState, pcAux, reachable, skipFenceAt,
                        buggyRetire, deferBodies, objectGen>>
    /\ UNCHANGED traceVars

\* Silent actions are only enabled when no MatchEvent is enabled for any
\* viable thread. This prevents TLC from taking a silent transition that
\* corrupts the spec state when a trace event is available to consume.
\* (Without this guard, e.g. SilentPinCollectFinish at pc=PinCollect would
\* race with MatchTryAdvLoadGlobal — both legal — and TLC's exploration of
\* the silent branch would hit a dead-end deadlock.)
NoMatchEnabled ==
    ~ \E tid \in ViablePIDs : ENABLED MatchEvent(tid)

SilentActions ==
    /\ NoMatchEnabled
    /\ \/ SilentTryAdvFence
       \/ SilentTryAdvAbortStalled
       \/ SilentTryAdvAbortDifferentEpoch
       \/ SilentInDeferCallbackPin
       \/ SilentInDeferCallbackUnpin
       \/ SilentFinalize
       \/ SilentFinalizePushBag
       \/ SilentFinalizeMarkDeleted
       \/ SilentTryAdvIterFinish
       \* Note: SilentPinCollectFinish removed. The impl always exits the
       \* PinCollect path via the full flow (TryAdv* → CollectScan → Idle),
       \* so no silent shortcut is needed; allowing it caused TLC to
       \* prematurely take a thread from PinCollect to Idle when the trace
       \* still had pending TryAdv events.

\* ========================================================================
\* Trace Init / Next
\* ========================================================================

\* TraceInit overrides base spec's Init for trace-mode initial state.
\* Differences from base.tla's Init:
\*   - reachable = {} (no objects start published; the test scenarios drive
\*     PublishObject events that grow reachable, then UnlinkObject + Defer
\*     to retire). The base spec assumes all objects are pre-existing in
\*     some atomic structure, which doesn't match an instrumented test run.
TraceInit ==
    /\ globalEpoch = 0
    /\ sealedBags = <<>>
    /\ retired = {}
    /\ localEpoch = [t \in Thread |-> UNPINNED]
    /\ guardCount = [t \in Thread |-> 0]
    /\ handleCount = [t \in Thread |-> 1]
    /\ pinCount = [t \in Thread |-> 0]
    /\ bag = [t \in Thread |-> <<>>]
    /\ localState = [t \in Thread |-> "Live"]
    /\ pc = [t \in Thread |-> "Idle"]
    /\ pcAux = [t \in Thread |-> InitGuardSlot]
    /\ reachable = {}
    /\ skipFenceAt = "none"
    /\ buggyRetire = FALSE
    /\ deferBodies = [o \in Object |-> "Noop"]
    /\ objectGen = [t \in Thread |-> 0]
    /\ pcThread = [tid \in Thread |-> 1]

TraceNext ==
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            /\ MatchEvent(tid)
            /\ Advance(tid)
    \/ /\ ThreadsWithEvents /= {}
       /\ SilentActions
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED <<allVars, traceVars>>

\* Strong fairness on TraceNext: if a trace event can be consumed (or a silent
\* action can fire), the spec MUST eventually fire it. Without fairness, TLC
\* finds trivial counter-examples where the system stutters before consuming
\* all events.
TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_<<allVars, traceVars>>
    /\ WF_<<allVars, traceVars>>(TraceNext)

\* ========================================================================
\* Completion property
\* ========================================================================

TraceFullyConsumed == ThreadsWithEvents = {}

TraceMatched == <>(ThreadsWithEvents = {})

====
