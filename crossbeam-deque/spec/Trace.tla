---- MODULE Trace ----
(***************************************************************************)
(* Trace validation spec for crossbeam-deque.                             *)
(* Category B (concurrent/lock-free): per-thread timebox traces.          *)
(*                                                                        *)
(* Replays instrumented traces against the base spec to verify that the   *)
(* implementation's state transitions match the specification.             *)
(***************************************************************************)

EXTENDS base, Integers, Sequences, FiniteSets, TLC, IOUtils, Json

\* ========================================================================
\* Trace Loading
\* ========================================================================

\* Preprocessed JSON file with per-thread arrays and compressed timestamps.
\* Format: { "worker": [...events...], "s1": [...events...], ... }
\* Each event: { "event": "...", "start": N, "end": N, "state": {...} }
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.json"

RawTrace == JsonDeserialize(JsonFile)

\* Extract per-thread traces
\* traces[tid] = sequence of events for thread tid
traces == RawTrace

\* All thread IDs present in the trace (exclude metadata keys like "flavor")
TraceThreads == DOMAIN traces \ {"flavor"}

\* ========================================================================
\* Trace Variables
\* ========================================================================

\* Per-thread cursor into the thread's trace array
VARIABLE pc

traceVars == <<pc>>
allTraceVars == <<vars, pc>>

\* ========================================================================
\* Helpers
\* ========================================================================

\* Threads that still have unconsumed events
ThreadsWithEvents ==
    {tid \in TraceThreads : pc[tid] <= Len(traces[tid])}

\* Partial order constraint: thread can step iff no other thread has a
\* pending event that completed before this thread's next event started.
\* This is the core timebox ordering (OmniLink / Category B).
ViablePIDs ==
    {tid \in ThreadsWithEvents :
        ~\E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pc[tid2]].end < traces[tid][pc[tid]].start}

\* Advance a single thread's cursor
AdvancePC(tid) ==
    pc' = [pc EXCEPT ![tid] = pc[tid] + 1]

\* ========================================================================
\* Post-state Validation
\* ========================================================================

\* Strong validation: check front, back after action
ValidatePostState(logline) ==
    /\ front' = logline.state.front
    /\ back' = logline.state.back

\* Weak validation: check only front (for stealer actions where back
\* may change concurrently)
ValidatePostStateWeak(logline) ==
    /\ front' = logline.state.front

\* No validation (for actions where state is not captured)
ValidateNone == TRUE

\* ========================================================================
\* Event Matching
\* ========================================================================

\* --- Worker Events ---

TracePush(tid, logline) ==
    /\ logline.event = "Push"
    /\ tid = "worker"
    /\ Push
    /\ ValidatePostState(logline)

TraceLIFOPop(tid, logline) ==
    /\ logline.event = "LIFOPop"
    /\ tid = "worker"
    /\ LIFOPop
    /\ ValidatePostState(logline)

TraceFIFOPopAttempt(tid, logline) ==
    /\ logline.event = "FIFOPopAttempt"
    /\ tid = "worker"
    /\ FIFOPopAttempt
    /\ ValidatePostState(logline)

TraceFIFOPopRollback(tid, logline) ==
    /\ logline.event = "FIFOPopRollback"
    /\ tid = "worker"
    /\ FIFOPopRollback
    /\ ValidatePostState(logline)

TraceResizeGrow(tid, logline) ==
    /\ logline.event = "ResizeGrow"
    /\ tid = "worker"
    /\ ResizeGrow
    /\ ValidateNone    \* Buffer ID changes aren't directly observable

\* --- Stealer Events ---

\* Category B fix: stealer begin actions use logline cached values instead
\* of reading front/back from current TLA+ state. In concurrent replay, the
\* worker may have advanced front/back past what the stealer actually observed.
TraceStealBegin(tid, logline) ==
    /\ logline.event = "StealBegin"
    /\ tid \in Stealer
    /\ sPC[tid] = "Idle"
    /\ IF logline.result = "empty" THEN
         /\ UNCHANGED <<stealerVars, epochVars>>
       ELSE
         \* result = "proceed": set cached values from logline
         /\ sPC' = [sPC EXCEPT ![tid] = "ReadTask"]
         /\ sCachedFront' = [sCachedFront EXCEPT ![tid] = logline.cachedFront]
         /\ sCachedBuf' = [sCachedBuf EXCEPT ![tid] = bufferID]
         /\ sStolenCount' = [sStolenCount EXCEPT ![tid] = 1]
         /\ sStealSite' = [sStealSite EXCEPT ![tid] = "single"]
         /\ pinned' = [pinned EXCEPT ![tid] = TRUE]
         /\ UNCHANGED <<sReadVal, retired, freed>>
    /\ UNCHANGED <<coreVars, bufVars, workerVars, faultVars, historyVars>>

TraceBatchStealBeginFIFO(tid, logline) ==
    /\ logline.event = "BatchStealBeginFIFO"
    /\ tid \in Stealer
    /\ sPC[tid] = "Idle"
    /\ flavor = "FIFO"
    /\ IF logline.result = "empty" THEN
         /\ UNCHANGED <<stealerVars, epochVars>>
       ELSE
         /\ sPC' = [sPC EXCEPT ![tid] = "ReadTask"]
         /\ sCachedFront' = [sCachedFront EXCEPT ![tid] = logline.cachedFront]
         /\ sCachedBuf' = [sCachedBuf EXCEPT ![tid] = bufferID]
         /\ sStolenCount' = [sStolenCount EXCEPT ![tid] = logline.batchSize]
         /\ sStealSite' = [sStealSite EXCEPT ![tid] = "batchFIFO"]
         /\ pinned' = [pinned EXCEPT ![tid] = TRUE]
         /\ UNCHANGED <<sReadVal, retired, freed>>
    /\ UNCHANGED <<coreVars, bufVars, workerVars, faultVars, historyVars>>

TraceBatchStealBeginLIFO(tid, logline) ==
    /\ logline.event = "BatchStealBeginLIFO"
    /\ tid \in Stealer
    /\ sPC[tid] = "Idle"
    /\ flavor = "LIFO"
    /\ IF logline.result = "empty" THEN
         /\ UNCHANGED <<stealerVars, epochVars>>
       ELSE
         /\ sPC' = [sPC EXCEPT ![tid] = "ReadTask"]
         /\ sCachedFront' = [sCachedFront EXCEPT ![tid] = logline.cachedFront]
         /\ sCachedBuf' = [sCachedBuf EXCEPT ![tid] = bufferID]
         /\ sStolenCount' = [sStolenCount EXCEPT ![tid] = 1]
         /\ sStealSite' = [sStealSite EXCEPT ![tid] = "batchLIFOFirst"]
         /\ pinned' = [pinned EXCEPT ![tid] = TRUE]
         /\ UNCHANGED <<sReadVal, retired, freed>>
    /\ UNCHANGED <<coreVars, bufVars, workerVars, faultVars, historyVars>>

TraceStealReadTask(tid, logline) ==
    /\ logline.event = "StealReadTask"
    /\ tid \in Stealer
    /\ StealReadTask(tid)
    /\ ValidateNone

TraceStealCommit(tid, logline) ==
    /\ logline.event = "StealCommit"
    /\ tid \in Stealer
    /\ StealCommit(tid)
    /\ IF "front" \in DOMAIN logline.state
       THEN ValidatePostStateWeak(logline)
       ELSE ValidateNone

\* ========================================================================
\* Event Dispatch
\* ========================================================================

MatchEvent(tid, logline) ==
    \* Worker events
    \/ TracePush(tid, logline)
    \/ TraceLIFOPop(tid, logline)
    \/ TraceFIFOPopAttempt(tid, logline)
    \/ TraceFIFOPopRollback(tid, logline)
    \/ TraceResizeGrow(tid, logline)
    \* Stealer events
    \/ TraceStealBegin(tid, logline)
    \/ TraceBatchStealBeginFIFO(tid, logline)
    \/ TraceBatchStealBeginLIFO(tid, logline)
    \/ TraceStealReadTask(tid, logline)
    \/ TraceStealCommit(tid, logline)

\* ========================================================================
\* Silent Actions
\* ========================================================================

\* EpochReclaim can happen between traced events. Constrained to only fire
\* when there are retired buffers that can be reclaimed.
SilentEpochReclaim ==
    /\ ThreadsWithEvents /= {}
    /\ EpochReclaim
    /\ UNCHANGED pc

\* ========================================================================
\* Trace Init and Next
\* ========================================================================

TraceInit ==
    /\ Init
    \* Override flavor from trace metadata if present
    /\ IF "flavor" \in DOMAIN RawTrace
       THEN flavor = RawTrace.flavor
       ELSE TRUE
    /\ pc = [tid \in TraceThreads |-> 1]

TraceNext ==
    \* Normal event consumption with timebox ordering
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            LET logline == traces[tid][pc[tid]] IN
            /\ MatchEvent(tid, logline)
            /\ AdvancePC(tid)
    \* Silent actions (don't advance any cursor)
    \/ SilentEpochReclaim
    \* Stuttering when all events consumed
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED allTraceVars

TraceSpec == TraceInit /\ [][TraceNext]_allTraceVars

\* ========================================================================
\* Trace Completion
\* ========================================================================

\* Deadlock-based: TLC stops when no action is enabled.
\* If all events consumed, it's success (not real deadlock).
TraceFullyConsumed == ThreadsWithEvents = {}

\* As temporal property (if using fairness):
TraceMatched == <>(ThreadsWithEvents = {})

====
