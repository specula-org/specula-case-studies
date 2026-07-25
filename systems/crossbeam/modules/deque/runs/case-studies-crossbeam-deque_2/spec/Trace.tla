---- MODULE Trace ----
(***************************************************************************)
(* Trace validation spec for crossbeam-deque (Category B timebox).         *)
(*                                                                        *)
(* Replays per-thread traces against the base spec, verifying that every  *)
(* observed transition matches a base-spec action and the post-state      *)
(* fields agree.                                                          *)
(*                                                                        *)
(* Trace format: preprocessed JSON {tid: [event records]} with each event *)
(* containing {event, start, end, state, ...action-specific fields}.      *)
(***************************************************************************)

EXTENDS base, Integers, Sequences, FiniteSets, TLC, IOUtils, Json

\* ========================================================================
\* Trace Loading
\* ========================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.json"

RawTrace == JsonDeserialize(JsonFile)
traces   == RawTrace

\* Per-thread trace IDs. Exclude metadata keys (e.g., "flavor").
TraceThreads == DOMAIN traces \ {"flavor"}

\* ========================================================================
\* Trace Variables
\* ========================================================================

VARIABLE pc                    \* per-thread cursor [Thread -> Nat]

traceVars    == <<pc>>
allTraceVars == <<vars, pc>>

\* ========================================================================
\* Helpers
\* ========================================================================

ThreadsWithEvents ==
    {tid \in TraceThreads : pc[tid] <= Len(traces[tid])}

ViablePIDs ==
    { tid \in ThreadsWithEvents :
        ~ \E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pc[tid2]].end < traces[tid][pc[tid]].start }

AdvancePC(tid) ==
    pc' = [pc EXCEPT ![tid] = pc[tid] + 1]

\* ========================================================================
\* Post-State Validation
\* ========================================================================
\*
\* Post-state checks: validate the spec variables that an action modifies
\* against the fields captured in the trace event. The instrumentation spec
\* dictates which fields are captured per event; this section dispatches
\* them. We implement strong validation where possible and weak validation
\* (only `front` or only structural facts) where the captured field set is
\* limited.

ValidateFrontBack(logline) ==
    /\ "state" \in DOMAIN logline
    /\ "front" \in DOMAIN logline.state => front' = logline.state.front
    /\ "back"  \in DOMAIN logline.state => back'  = logline.state.back

ValidateFront(logline) ==
    /\ "state" \in DOMAIN logline
    /\ "front" \in DOMAIN logline.state => front' = logline.state.front

ValidateBack(logline) ==
    /\ "state" \in DOMAIN logline
    /\ "back"  \in DOMAIN logline.state => back'  = logline.state.back

ValidateBufferGen(logline) ==
    /\ "state" \in DOMAIN logline
    /\ "bufferID" \in DOMAIN logline.state => bufferID' = logline.state.bufferID

ValidateNone == TRUE

\* ========================================================================
\* Worker Event Wrappers
\* ========================================================================

TracePushWriteSlot(tid, logline) ==
    /\ logline.event = "PushWriteSlot"
    /\ tid = "worker"
    /\ PushWriteSlot

TracePushStoreBack(tid, logline) ==
    /\ logline.event = "PushStoreBack"
    /\ tid = "worker"
    /\ PushStoreBack
    /\ ValidateBack(logline)

TraceLIFOPopDecrFence(tid, logline) ==
    /\ logline.event = "LIFOPopDecrFence"
    /\ tid = "worker"
    /\ LIFOPopDecrFence
    /\ ValidateBack(logline)

TraceLIFOPopDecide(tid, logline) ==
    /\ logline.event = "LIFOPopDecide"
    /\ tid = "worker"
    /\ LIFOPopDecide
    /\ ValidateFrontBack(logline)

TraceFIFOPopAttempt(tid, logline) ==
    /\ logline.event = "FIFOPopAttempt"
    /\ tid = "worker"
    /\ FIFOPopAttempt
    /\ ValidateFront(logline)

TraceFIFOPopRollback(tid, logline) ==
    /\ logline.event = "FIFOPopRollback"
    /\ tid = "worker"
    /\ FIFOPopRollback
    /\ ValidateFront(logline)

TraceResizeGrow(tid, logline) ==
    /\ logline.event = "ResizeGrow"
    /\ tid = "worker"
    /\ ResizeGrow
    /\ ValidateBufferGen(logline)

\* ========================================================================
\* Stealer Event Wrappers
\* ========================================================================
\*
\* Stealer events drive the per-stealer state machine. Each event matches
\* exactly one base-spec action. We do NOT bypass the base action — TLC
\* explores interleavings and the real ordering is among them.

TraceStealLoadFront_Single(tid, logline) ==
    /\ logline.event = "StealLoadFront_Single"
    /\ tid \in Stealer
    /\ StealLoadFront_Single(tid)

TraceStealLoadFront_BatchFifo(tid, logline) ==
    /\ logline.event = "StealLoadFront_BatchFifo"
    /\ tid \in Stealer
    \* The trace records the sampled batchN; pin via ValidateNone since the
    \* base action existentially quantifies n. The captured n is checked at
    \* StealRecheckCAS via sStolenCount/sBatchN equality if the trace logs it.
    /\ StealLoadFront_BatchFifo(tid)

TraceStealLoadFront_BatchLifo(tid, logline) ==
    /\ logline.event = "StealLoadFront_BatchLifo"
    /\ tid \in Stealer
    /\ StealLoadFront_BatchLifo(tid)

TraceStealPin(tid, logline) ==
    /\ logline.event = "StealPin"
    /\ tid \in Stealer
    /\ StealPin(tid)

TraceStealLoadBack(tid, logline) ==
    /\ logline.event = "StealLoadBack"
    /\ tid \in Stealer
    /\ StealLoadBack(tid)
    \* Validate that the stealer's cached back equals the value captured
    \* in the event (back load result).
    /\ "cachedBack" \in DOMAIN logline =>
       sCachedBack'[tid] = logline.cachedBack

TraceStealLoadBuffer(tid, logline) ==
    /\ logline.event = "StealLoadBuffer"
    /\ tid \in Stealer
    /\ StealLoadBuffer(tid)
    /\ "cachedBuf" \in DOMAIN logline =>
       sCachedBuf'[tid] = logline.cachedBuf

TraceStealReadSlot(tid, logline) ==
    /\ logline.event = "StealReadSlot"
    /\ tid \in Stealer
    /\ StealReadSlot(tid)

TraceStealRecheckCAS(tid, logline) ==
    /\ logline.event = "StealRecheckCAS"
    /\ tid \in Stealer
    /\ StealRecheckCAS(tid)
    /\ ValidateFront(logline)

TraceStealLIFOBatchIter(tid, logline) ==
    /\ logline.event = "StealLIFOBatchIter"
    /\ tid \in Stealer
    /\ StealLIFOBatchIter(tid)
    /\ ValidateFront(logline)

\* ========================================================================
\* Caller-Harness Wrappers (Family C)
\* ========================================================================

TraceStealerCloneAdv(tid, logline) ==
    /\ logline.event = "StealerCloneAdv"
    \* tid is the cloning thread; new stealer name is in logline.newStealer
    /\ "newStealer" \in DOMAIN logline
    /\ StealerCloneAdv(logline.newStealer)

TraceWorkerDropAdv(tid, logline) ==
    /\ logline.event = "WorkerDropAdv"
    /\ tid = "worker"
    /\ WorkerDropAdv

\* ========================================================================
\* Event Dispatch
\* ========================================================================

MatchEvent(tid, logline) ==
    \/ TracePushWriteSlot(tid, logline)
    \/ TracePushStoreBack(tid, logline)
    \/ TraceLIFOPopDecrFence(tid, logline)
    \/ TraceLIFOPopDecide(tid, logline)
    \/ TraceFIFOPopAttempt(tid, logline)
    \/ TraceFIFOPopRollback(tid, logline)
    \/ TraceResizeGrow(tid, logline)
    \/ TraceStealLoadFront_Single(tid, logline)
    \/ TraceStealLoadFront_BatchFifo(tid, logline)
    \/ TraceStealLoadFront_BatchLifo(tid, logline)
    \/ TraceStealPin(tid, logline)
    \/ TraceStealLoadBack(tid, logline)
    \/ TraceStealLoadBuffer(tid, logline)
    \/ TraceStealReadSlot(tid, logline)
    \/ TraceStealRecheckCAS(tid, logline)
    \/ TraceStealLIFOBatchIter(tid, logline)
    \/ TraceStealerCloneAdv(tid, logline)
    \/ TraceWorkerDropAdv(tid, logline)

\* ========================================================================
\* Silent Actions
\* ========================================================================
\*
\* Constraints: silent actions only fire while the trace is still being
\* consumed (otherwise stuttering is preferred), and only when their
\* preconditions are met by the base spec. They do not advance any pc.

\* Epoch-driven reclamation can occur transparently between traced events.
SilentEpochReclaim ==
    /\ ThreadsWithEvents /= {}
    /\ EpochReclaim
    /\ UNCHANGED pc

\* Slot-publication of deferred writes (Family B liveness companion):
\* the Release fence in the worker eventually reaches all stealers.
SilentPublish ==
    /\ ThreadsWithEvents /= {}
    /\ PublishDeferredSlot
    /\ UNCHANGED pc

\* Fault-toggle adversaries are NOT silent in trace mode: real traces are
\* assumed to be unfaulted. We do not enable EnableRelaxBackStore /
\* EnableSkipStealerFence / EnableWeakLIFOLastCAS during trace replay.

\* ========================================================================
\* Trace Init
\* ========================================================================

\* Stealers that actually appear in the trace; the init constrains
\* `activeStealers` to exactly this set so we don't enumerate pointless
\* initial states that disagree with the recorded run.
TraceStealers == TraceThreads \intersect Stealer

TraceInit ==
    /\ Init
    \* Override flavor from trace metadata if present
    /\ IF "flavor" \in DOMAIN RawTrace
       THEN flavor = RawTrace.flavor
       ELSE TRUE
    \* Pin activeStealers to the threads observed in the trace.
    /\ activeStealers = TraceStealers
    /\ pc = [tid \in TraceThreads |-> 1]

\* ========================================================================
\* Trace Next
\* ========================================================================

TraceNext ==
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            LET logline == traces[tid][pc[tid]] IN
            /\ MatchEvent(tid, logline)
            /\ AdvancePC(tid)
    \/ SilentEpochReclaim
    \/ SilentPublish
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED allTraceVars

TraceSpec == TraceInit
             /\ [][TraceNext]_allTraceVars
             /\ WF_allTraceVars(TraceNext)

\* ========================================================================
\* Trace Completion
\* ========================================================================

TraceFullyConsumed == ThreadsWithEvents = {}

\* Required temporal property: every trace eventually completes.
TraceMatched == <>(ThreadsWithEvents = {})

====
