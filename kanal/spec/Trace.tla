---- MODULE Trace ----
(***************************************************************************)
(* Trace Validation Spec for kanal MPMC Channel                            *)
(*                                                                         *)
(* Category B (concurrent): Uses per-thread timebox traces with            *)
(* ViablePIDs partial ordering.                                            *)
(*                                                                         *)
(* Replays implementation traces against the base spec to verify that      *)
(* recorded state transitions are consistent with the specification.       *)
(***************************************************************************)

EXTENDS base, TLCExt, IOUtils, Json, Sequences, Naturals, FiniteSets

\* ========================================================================
\* Trace Loading
\* ========================================================================

\* Trace file location (override via IOEnv.JSON for per-run selection)
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.json"

\* Load preprocessed JSON: { "t1": [...], "t2": [...], ... }
\* Each entry: { "event": "...", "start": N, "end": N, "state": {...}, ... }
RawTraceData == JsonDeserialize(JsonFile)

\* Per-thread trace arrays
traces == [t \in Thread |->
    IF ToString(t) \in DOMAIN RawTraceData THEN RawTraceData[ToString(t)]
    ELSE <<>>]

\* ========================================================================
\* Trace Cursor (Per-Thread)
\* ========================================================================

VARIABLES pc   \* Per-thread cursor: [Thread -> Nat]

traceVars == <<pc>>
allVars == <<vars, pc>>

\* ========================================================================
\* Timebox Helpers
\* ========================================================================

\* Threads that still have unconsumed events
ThreadsWithEvents ==
    {tid \in Thread : pc[tid] <= Len(traces[tid])}

\* Viable PIDs: partial order constraint (OmniLink-style)
\* Thread A must go before B if A's pending event ENDED before B's next event STARTED
ViablePIDs ==
    {tid \in ThreadsWithEvents :
        ~\E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pc[tid2]].end < traces[tid][pc[tid]].start}

\* Current logline for a thread
Logline(tid) == traces[tid][pc[tid]]

\* Advance a single thread's cursor
AdvancePC(tid) == pc' = [pc EXCEPT ![tid] = pc[tid] + 1]

\* ========================================================================
\* Data Mapping
\* ========================================================================

\* Map data identifiers from trace to spec Data constants
\* Trace emits data as strings; map to model values at trace boundary
MapData(traceVal) ==
    IF traceVal \in Data THEN traceVal
    ELSE NilData  \* fallback

\* ========================================================================
\* Post-State Validation
\* ========================================================================

\* Strong validation: check post-state fields (all primed)
\* Trace captures state AFTER the operation under the lock.
ValidatePostState(tid) ==
    LET ll == Logline(tid) IN
    /\ "state" \in DOMAIN ll =>
        /\ "queueLen" \in DOMAIN ll.state =>
               Len(queue') = ll.state.queueLen
        /\ "sendCount" \in DOMAIN ll.state =>
               sendCount' = ll.state.sendCount
        /\ "recvCount" \in DOMAIN ll.state =>
               recvCount' = ll.state.recvCount
        /\ "channelOpen" \in DOMAIN ll.state =>
               channelOpen' = ll.state.channelOpen

\* Signal-specific validation: check signal state after handoff
ValidateSignalState(tid) ==
    LET ll == Logline(tid) IN
    /\ "signalState" \in DOMAIN ll =>
        signalState'[tid] = ll.signalState

\* Weak validation: for actions with limited observability
ValidatePostStateWeak(tid) == TRUE

\* ========================================================================
\* Event Matching
\* ========================================================================

MatchEvent(tid, logline) ==
    LET event == logline.event IN

    \* --- Send: direct handoff to waiting receiver (lib.rs:614-618) ---
    \/ /\ event = "send_direct_handoff"
       /\ SendDirectHandoff(tid)
       /\ ValidatePostState(tid)

    \* --- Send: buffer in queue (lib.rs:620-623) ---
    \/ /\ event = "send_to_queue"
       /\ SendToQueue(tid)
       /\ ValidatePostState(tid)

    \* --- Send: block on waitlist (lib.rs:625-636) ---
    \/ /\ event = "send_block"
       /\ SendBlock(tid)
       /\ ValidatePostState(tid)

    \* --- Send: channel closed (lib.rs:610-612) ---
    \/ /\ event = "send_closed"
       /\ SendClosed(tid)
       /\ ValidatePostState(tid)

    \* --- Recv: pop from queue + refill (lib.rs:1067-1075) ---
    \/ /\ event = "recv_from_queue"
       /\ RecvFromQueue(tid)
       /\ ValidatePostState(tid)

    \* --- Recv: direct handoff from sender (lib.rs:1077-1081) ---
    \/ /\ event = "recv_direct_handoff"
       /\ RecvDirectHandoff(tid)
       /\ ValidatePostState(tid)

    \* --- Recv: block on waitlist (lib.rs:1085-1095) ---
    \/ /\ event = "recv_block"
       /\ RecvBlock(tid)
       /\ ValidatePostState(tid)

    \* --- Recv: channel closed (lib.rs:1082-1083) ---
    \/ /\ event = "recv_closed"
       /\ RecvClosed(tid)
       /\ ValidatePostState(tid)

    \* --- Signal: write_data completed (signal.rs:161-168) ---
    \* Two cases: (a) counterpart thread confirmed handoff (no-op, already modeled
    \* atomically in send/recv), (b) blocking thread woke up and observed UNLOCKED.
    \/ /\ event = "signal_write_data"
       /\ \/ /\ threadDone[tid]  \* (a) counterpart: signal write already modeled
             /\ UNCHANGED vars
          \/ /\ SignalWaitSuccess(tid)  \* (b) blocking thread wakeup
             /\ ValidatePostStateWeak(tid)

    \* --- Signal: terminated (signal.rs:185-189) ---
    \/ /\ event = "signal_terminated"
       /\ SignalWaitFailure(tid)
       /\ ValidatePostStateWeak(tid)

    \* --- Timeout: CAS to LOCKED_STARVATION (signal.rs:241-246) ---
    \/ /\ event = "wait_timeout"
       /\ WaitTimeout(tid)
       /\ ValidatePostStateWeak(tid)

    \* --- Timeout: recheck after timeout (signal.rs:248-255) ---
    \/ /\ event = "wait_timeout_recheck"
       /\ WaitTimeoutRecheck(tid)
       /\ ValidatePostStateWeak(tid)

    \* --- Timeout: cancel signal (lib.rs:801-806) ---
    \/ /\ event = "wait_timeout_cancel"
       /\ WaitTimeoutCancel(tid)
       /\ ValidatePostState(tid)

    \* --- Future drop: rendezvous data lost (future.rs:240-244) ---
    \/ /\ event = "drop_recv_future_rendezvous"
       /\ DropRecvFutureRendezvous(tid)
       /\ ValidatePostStateWeak(tid)

    \* --- Future drop: buffered push_front (future.rs:246-249) ---
    \/ /\ event = "drop_recv_future_buffered"
       /\ DropRecvFutureBuffered(tid)
       /\ ValidatePostState(tid)

    \* --- Future drop: cancel recv signal (future.rs:223-227) ---
    \/ /\ event = "drop_recv_future_cancel"
       /\ DropRecvFutureCancel(tid)
       /\ ValidatePostState(tid)

    \* --- Future drop: cancel send signal (future.rs:77-79) ---
    \/ /\ event = "drop_send_future_cancel"
       /\ DropSendFutureCancel(tid)
       /\ ValidatePostState(tid)

    \* --- Future drop: send wait (future.rs:82-85) ---
    \/ /\ event = "drop_send_future_wait"
       /\ DropSendFutureWait(tid)
       /\ ValidatePostStateWeak(tid)

    \* --- Thread reset ---
    \/ /\ event = "thread_reset"
       /\ ThreadReset(tid)
       /\ ValidatePostStateWeak(tid)

    \* --- Clone sender (internal.rs:270-274) ---
    \/ /\ event = "clone_sender"
       /\ CloneSender
       /\ ValidatePostState(tid)

    \* --- Clone receiver (internal.rs:278-283) ---
    \/ /\ event = "clone_receiver"
       /\ CloneReceiver
       /\ ValidatePostState(tid)

    \* --- Drop sender (internal.rs:288-295) ---
    \/ /\ event = "drop_sender"
       /\ DropSender
       /\ ValidatePostState(tid)

    \* --- Drop receiver (internal.rs:296-303) ---
    \/ /\ event = "drop_receiver"
       /\ DropReceiver
       /\ ValidatePostState(tid)

    \* --- Close (lib.rs:237-247) ---
    \/ /\ event = "close"
       /\ Close
       /\ ValidatePostState(tid)

\* ========================================================================
\* Silent Actions
\* ========================================================================

\* Silent signal wait success: counterpart resolved signal without trace event
SilentSignalWaitSuccess ==
    /\ ThreadsWithEvents /= {}
    /\ \E t \in Thread :
        /\ role[t] \in {ROLE_SENDER, ROLE_RECEIVER}
        /\ ~threadDone[t]
        /\ signalOwner[t] /= OWN_WAITLIST
        /\ signalState[t] = UNLOCKED
        /\ SignalWaitSuccess(t)
    /\ UNCHANGED pc

\* Silent signal wait failure: signal terminated without trace event
SilentSignalWaitFailure ==
    /\ ThreadsWithEvents /= {}
    /\ \E t \in Thread :
        /\ role[t] \in {ROLE_SENDER, ROLE_RECEIVER}
        /\ ~threadDone[t]
        /\ signalOwner[t] /= OWN_WAITLIST
        /\ signalState[t] = TERMINATED
        /\ SignalWaitFailure(t)
    /\ UNCHANGED pc

\* Silent thread reset: thread completes and resets without trace event.
\* Only fire when the thread has NO remaining events (cleanup after all
\* events consumed). If the thread has pending events, the explicit
\* "thread_reset" event handles the reset instead.
SilentThreadReset ==
    /\ ThreadsWithEvents /= {}
    /\ \E t \in Thread :
        /\ threadDone[t]
        /\ t \notin ThreadsWithEvents  \* only when no more events
        /\ ThreadReset(t)
    /\ UNCHANGED pc

\* Silent timeout recheck: timed-out thread rechecks resolved signal (no trace event).
\* Only fires after signal is resolved (UNLOCKED/TERMINATED), so cannot preempt
\* the counterpart's event that does the resolution.
SilentWaitTimeoutRecheck ==
    /\ ThreadsWithEvents /= {}
    /\ \E t \in Thread :
        /\ WaitTimeoutRecheck(t)
    /\ UNCHANGED pc

SilentActions ==
    \/ SilentSignalWaitSuccess
    \/ SilentSignalWaitFailure
    \/ SilentWaitTimeoutRecheck
    \/ SilentThreadReset

\* ========================================================================
\* Trace Init
\* ========================================================================

TraceInit ==
    /\ Init
    /\ pc = [t \in Thread |-> 1]

\* ========================================================================
\* Trace Next
\* ========================================================================

TraceNext ==
    \* Normal event consumption
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            LET logline == Logline(tid) IN
            /\ MatchEvent(tid, logline)
            /\ AdvancePC(tid)
    \* Silent actions (no cursor advance)
    \/ /\ ThreadsWithEvents /= {}
       /\ SilentActions
    \* Stuttering when all events consumed
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED allVars

TraceSpec == TraceInit /\ [][TraceNext]_allVars

\* ========================================================================
\* Trace Completion
\* ========================================================================

\* Temporal property: all events must be consumed
TraceFullyConsumed == <>(ThreadsWithEvents = {})

\* ========================================================================
\* Invariants for trace validation
\* ========================================================================

\* Core safety — should hold on every real execution
TraceNoDataRace == NoDataRace
TraceSignalSingleUse == SignalSingleUse
TraceNoDoubleFree == NoDoubleFree
TraceNoHangingSignals == NoHangingSignals

\* Structural — catches spec modeling errors
TraceQueueDataValid == QueueDataValid
TraceRefCountConsistency == RefCountConsistency

====
