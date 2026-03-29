---- MODULE Trace ----
\* ===========================================================================
\* Trace Validation Spec for tokio broadcast channel (Category B — Timebox)
\* ===========================================================================
\*
\* Replays per-thread implementation traces against the base spec.
\* Uses timebox approach: each event has [start, end] interval timestamps.
\* TLC explores all viable interleavings via ViablePIDs.
\*
\* Trace format: preprocessed JSON with per-thread event arrays.
\* Each event: { "event": "...", "thread": "...", "start": N, "end": N, "state": {...} }

EXTENDS base, TLCExt, Toolbox, IOUtils, Json, Sequences, Naturals

\* ===========================================================================
\* Trace Loading
\* ===========================================================================

\* Trace file location (override via -DJSON=... for per-run selection)
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.json"

\* Load preprocessed trace (per-thread arrays)
\* Format: { "threads": { "t1": [...events...], "t2": [...events...] }, "meta": {...} }
RawTrace == JsonDeserialize(JsonFile)

\* Per-thread trace arrays
traces == RawTrace.threads

\* Set of thread IDs present in the trace
TraceThreads == DOMAIN traces

\* ===========================================================================
\* Per-thread cursor
\* ===========================================================================

VARIABLE pc   \* [TraceThreads -> Nat]: per-thread cursor into traces[tid]

traceVars == <<pc>>
allVars == <<vars, pc>>

\* ===========================================================================
\* Timebox Helpers
\* ===========================================================================

\* Threads with unconsumed events
ThreadsWithEvents ==
    {tid \in TraceThreads : pc[tid] <= Len(traces[tid])}

\* ViablePIDs: partial order constraint on event ordering.
\* Thread A must step before thread B if A's pending event ended
\* before B's pending event started.
ViablePIDs ==
    {tid \in ThreadsWithEvents :
        ~\E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pc[tid2]].end < traces[tid][pc[tid]].start}

\* Advance cursor for a specific thread
AdvancePC(tid) == pc' = [pc EXCEPT ![tid] = pc[tid] + 1]

\* ===========================================================================
\* Thread/Receiver Mapping
\* ===========================================================================

\* Map thread ID from trace to receiver constant.
\* Harness emits IDs matching spec constant names.
MapReceiver(tid) == tid

\* Map value from trace to spec value
MapValue(v) ==
    IF v = "null" THEN Nil ELSE v

\* ===========================================================================
\* Post-State Validation
\* ===========================================================================

\* Validate core state after Send
ValidateSendState(logline) ==
    /\ tailPos' = logline.state.tailPos
    /\ rxCnt = logline.state.rxCnt      \* rxCnt unchanged by Send

\* Validate receiver state after Recv
ValidateRecvState(logline, r) ==
    /\ rxNext'[r] = logline.state.rxNext

\* Validate slot state after recv (rem decrement)
ValidateSlotState(logline, idx) ==
    /\ slotRem'[idx] = logline.state.slotRem

\* Validate close state
ValidateCloseState(logline) ==
    /\ closed' = logline.state.closed

\* Validate after Subscribe
ValidateSubscribeState(logline, r) ==
    /\ rxNext'[r] = logline.state.rxNext
    /\ rxCnt' = logline.state.rxCnt

\* Validate after ReceiverDrop
ValidateDropState(logline) ==
    /\ rxCnt' = logline.state.rxCnt

\* Validate after SenderDrop
ValidateSenderDropState(logline) ==
    /\ numTx' = logline.state.numTx

\* ===========================================================================
\* Event Matching
\* ===========================================================================

\* Dispatch a trace event to the corresponding base spec action.
\* Each case: match event name → call base action → validate post-state.

MatchEvent(tid, logline) ==
    \* --- Send ---
    \/ /\ logline.event = "Send"
       /\ LET v == MapValue(logline.value) IN
          /\ Send(v)
          /\ ValidateSendState(logline)

    \* --- Subscribe ---
    \/ /\ logline.event = "Subscribe"
       /\ LET r == MapReceiver(logline.receiver) IN
          /\ Subscribe(r)
          /\ ValidateSubscribeState(logline, r)

    \* --- RecvSuccess ---
    \/ /\ logline.event = "RecvSuccess"
       /\ LET r == MapReceiver(logline.receiver) IN
          /\ RecvSuccess(r)
          /\ ValidateRecvState(logline, r)

    \* --- RecvEmpty ---
    \/ /\ logline.event = "RecvEmpty"
       /\ LET r == MapReceiver(logline.receiver) IN
          /\ RecvEmpty(r)

    \* --- RecvClosed ---
    \/ /\ logline.event = "RecvClosed"
       /\ LET r == MapReceiver(logline.receiver) IN
          /\ RecvClosed(r)

    \* --- RecvLagged ---
    \/ /\ logline.event = "RecvLagged"
       /\ LET r == MapReceiver(logline.receiver) IN
          /\ RecvLagged(r)
          /\ ValidateRecvState(logline, r)

    \* --- SenderDrop ---
    \/ /\ logline.event = "SenderDrop"
       /\ SenderDrop
       /\ ValidateSenderDropState(logline)

    \* --- SenderClone ---
    \/ /\ logline.event = "SenderClone"
       /\ SenderClone

    \* --- CloseChannel ---
    \/ /\ logline.event = "CloseChannel"
       /\ CloseChannel
       /\ ValidateCloseState(logline)

    \* --- ReceiverDrop ---
    \/ /\ logline.event = "ReceiverDrop"
       /\ LET r == MapReceiver(logline.receiver) IN
          /\ ReceiverDrop(r)
          /\ ValidateDropState(logline)

    \* --- DeregisterWaiter ---
    \/ /\ logline.event = "DeregisterWaiter"
       /\ LET r == MapReceiver(logline.receiver) IN
          /\ DeregisterWaiter(r)

\* ===========================================================================
\* Silent Actions
\* ===========================================================================
\*
\* Silent actions fire without consuming trace events.
\* Each is tightly constrained to prevent state space explosion.

\* Silent: CloseChannel fires when closePending is TRUE
\* (The close_channel() call happens internally after SenderDrop,
\* may not have its own trace event if instrumented as part of drop)
SilentCloseChannel ==
    /\ ThreadsWithEvents /= {}
    /\ closePending
    \* Don't fire if ANY thread's next event IS CloseChannel
    \* (let the traced event handle it instead — must check all threads,
    \* not just ViablePIDs, to avoid consuming closePending prematurely)
    /\ \A tid \in ThreadsWithEvents : traces[tid][pc[tid]].event /= "CloseChannel"
    /\ CloseChannel
    /\ UNCHANGED pc

\* ===========================================================================
\* Trace Init and Next
\* ===========================================================================

TraceInit ==
    /\ Init
    /\ pc = [tid \in TraceThreads |-> 1]

TraceNext ==
    \* Match trace events using ViablePIDs ordering
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            LET logline == traces[tid][pc[tid]] IN
            /\ MatchEvent(tid, logline)
            /\ AdvancePC(tid)
    \* Silent actions (no cursor advance)
    \/ /\ ThreadsWithEvents /= {}
       /\ SilentCloseChannel
    \* Stuttering when all events consumed
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED allVars

TraceSpec == TraceInit /\ [][TraceNext]_allVars /\ WF_allVars(TraceNext)

\* ===========================================================================
\* Trace Validation Properties
\* ===========================================================================

\* Temporal: entire trace was consumed
TraceMatched ==
    <>(ThreadsWithEvents = {})

\* Cursor monotonicity (structural)
TraceCursorMonotonic ==
    [][\A tid \in TraceThreads : pc'[tid] >= pc[tid]]_pc

====
