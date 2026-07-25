---- MODULE Trace ----
(***************************************************************************)
(* Trace validation spec for left-right (Category B: concurrent/lock-free) *)
(*                                                                         *)
(* Uses per-thread timebox traces with [start, end] intervals.             *)
(* TLC explores viable interleavings via ViablePIDs.                       *)
(*                                                                         *)
(* Trace format: preprocessed JSON with per-thread event arrays.           *)
(* Each event: {event, start, end, state: {...}}                           *)
(*                                                                         *)
(* Composite trace actions: trace records coarse events (e.g., one         *)
(* "WriterPublish" for the full lock+wait+apply+swap+fence+snapshot).      *)
(* The trace spec defines composite actions that compute the correct       *)
(* post-state in one atomic step, matching the base spec's logic.          *)
(***************************************************************************)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* ========================================================================
\* Trace Loading
\* ========================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.json"

RawTrace == JsonDeserialize(JsonFile)

\* Per-thread trace arrays. Keys are thread ID strings.
\* RawTrace.threads is a record: [tid -> <<event1, event2, ...>>]
traces == RawTrace.threads

\* Thread set derived from trace (string IDs like "writer", "r1", "r2")
TraceThreads == DOMAIN traces

\* ========================================================================
\* Per-thread cursor
\* ========================================================================

VARIABLE pc    \* [TraceThreads -> Nat] per-thread event index (1-based)
traceVars == <<pc>>

\* ========================================================================
\* Helpers
\* ========================================================================

\* Threads that still have unconsumed events.
ThreadsWithEvents ==
    { tid \in TraceThreads : pc[tid] <= Len(traces[tid]) }

\* ViablePIDs: partial order constraint.
\* Thread can step iff no other thread has a pending event that completed
\* before this thread's next event started.
ViablePIDs ==
    { tid \in ThreadsWithEvents :
        ~ \E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pc[tid2]].end < traces[tid][pc[tid]].start }

\* Map thread ID string to Reader constant.
\* With Reader = {"r1", "r2"}, MapReader is identity.
MapReader(tid) == tid

\* Check if a thread is the writer thread.
IsWriter(tid) == tid = "writer"

\* ========================================================================
\* Post-state validation
\* ========================================================================

\* Validate reader state from trace event.
ValidateReaderState(tid, logline) ==
    LET r == MapReader(tid) IN
    /\ epoch'[r] = logline.state.epoch
    /\ enters'[r] = logline.state.enters

\* Validate copy data from trace event (when available).
ValidateCopyData(logline) ==
    /\ IF "copyL" \in DOMAIN logline.state
       THEN copyData'["L"] = logline.state.copyL
       ELSE TRUE
    /\ IF "copyR" \in DOMAIN logline.state
       THEN copyData'["R"] = logline.state.copyR
       ELSE TRUE

\* Validate pointer from trace event (when available).
ValidatePointer(logline) ==
    IF "pointer" \in DOMAIN logline.state
    THEN pointer' = logline.state.pointer
    ELSE TRUE

\* ========================================================================
\* Composite Trace Actions
\* ========================================================================
\* Trace records coarse-grained events. These composite actions combine
\* multiple base spec steps into single atomic transitions that compute
\* the correct post-state directly.

\* --- Combined ReaderEnter: BumpEpoch + Fence + LoadPointer ---
\* Trace records enter() as a single event. Combines read.rs:169-183.
\* No fault injection in trace mode (traces are real executions).
TraceReaderEnter(r) ==
    /\ registered[r]
    /\ rPC[r] = "Idle"
    /\ enters[r] = 0                                   \* (read.rs:122)
    /\ pointer /= "null"                                \* (read.rs:180)
    \* Combined: epoch bump + fence + pointer load
    /\ epoch' = [epoch EXCEPT ![r] = epoch[r] + 1]     \* odd (read.rs:169)
    /\ rCopyRef' = [rCopyRef EXCEPT ![r] = pointer]     \* sees current (read.rs:175)
    /\ enters' = [enters EXCEPT ![r] = 1]               \* (read.rs:182-183)
    /\ rPC' = [rPC EXCEPT ![r] = "Reading"]
    /\ UNCHANGED <<pointer, writerCopy, lastEpochs, wPC,
                   copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- Combined WriterPublish: lock + wait + apply + swap + fence + snapshot ---
\* Trace records publish() as a single event. Combines write.rs:343-440.
TraceWriterPublish ==
    /\ wPC = "Idle"
    /\ ~taken
    /\ mutexHolder = "none"
    /\ AllReadersQuiesced
    \* Apply + Swap (write.rs:363-425)
    /\ \/ /\ first
          /\ first' = FALSE
          /\ UNCHANGED <<copyData, second>>
       \/ /\ ~first
          /\ IF second THEN second' = FALSE ELSE UNCHANGED second
          /\ copyData' = [copyData EXCEPT ![writerCopy] = totalOps]
          /\ UNCHANGED first
    /\ pointer' = writerCopy
    /\ writerCopy' = OtherCopy(writerCopy)
    \* Fence + Snapshot (write.rs:428-432)
    /\ lastEpochs' = [r \in Reader |-> epoch[r]]
    \* Writer returns to Idle (mutex released)
    /\ UNCHANGED <<wPC, epoch, enters,
                   rPC, rCopyRef, totalOps,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- Combined WriterTryPublishSucceed ---
\* try_publish returns true: equivalent to full publish.
TraceWriterTryPublishSucceed ==
    TraceWriterPublish

\* --- Combined WriterTryPublishFail ---
\* try_publish returns false: no state change (mutex acquired and released).
TraceWriterTryPublishFail ==
    /\ wPC = "Idle"
    /\ ~taken
    /\ mutexHolder = "none"
    /\ ~AllReadersQuiesced
    /\ UNCHANGED vars

\* --- Combined WriterTakeInner: publish + null-swap + wait + fence ---
\* Trace records take_inner() as a single event. Combines write.rs:149-198.
\* Precondition: both copies up to date (take_inner calls publish internally).
TraceWriterTakeInner ==
    /\ wPC = "Idle"
    /\ ~taken
    /\ ~first
    /\ mutexHolder = "none"
    /\ AllReadersQuiesced
    \* Set taken, swap pointer to null
    /\ taken' = TRUE                                    \* (write.rs:157)
    /\ pointer' = "null"                                \* (write.rs:170)
    \* Wait + fence already satisfied (AllReadersQuiesced checked)
    /\ wPC' = "Done"
    \* Snapshot (for completeness)
    /\ lastEpochs' = [r \in Reader |-> epoch[r]]
    /\ UNCHANGED <<writerCopy, epoch, enters,
                   rPC, rCopyRef, copyData, totalOps, first, second,
                   registered, mutexHolder,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* ========================================================================
\* Event Matching
\* ========================================================================

MatchEvent(tid, logline) ==
    \* --- Reader events ---
    \/ /\ ~IsWriter(tid)
       /\ logline.event = "ReaderEnter"
       /\ LET r == MapReader(tid) IN
          /\ TraceReaderEnter(r)
          /\ ValidateReaderState(tid, logline)

    \/ /\ ~IsWriter(tid)
       /\ logline.event = "ReaderNestedEnter"
       /\ LET r == MapReader(tid) IN
          /\ ReaderNestedEnter(r)
          /\ ValidateReaderState(tid, logline)

    \/ /\ ~IsWriter(tid)
       /\ logline.event = "ReaderExit"
       /\ LET r == MapReader(tid) IN
          /\ ReaderExit(r)
          /\ ValidateReaderState(tid, logline)

    \/ /\ ~IsWriter(tid)
       /\ logline.event = "ReaderRegister"
       /\ LET r == MapReader(tid) IN
          /\ ReaderRegister(r)

    \/ /\ ~IsWriter(tid)
       /\ logline.event = "ReaderDeregister"
       /\ LET r == MapReader(tid) IN
          /\ ReaderDeregister(r)

    \* --- Writer events ---
    \/ /\ IsWriter(tid)
       /\ logline.event = "WriterAppend"
       /\ WriterAppend
       /\ ValidateCopyData(logline)

    \/ /\ IsWriter(tid)
       /\ logline.event = "WriterPublish"
       /\ TraceWriterPublish
       /\ ValidateCopyData(logline)
       /\ ValidatePointer(logline)

    \/ /\ IsWriter(tid)
       /\ logline.event = "WriterTryPublish"
       /\ \/ /\ TraceWriterTryPublishSucceed
             /\ ValidateCopyData(logline)
             /\ ValidatePointer(logline)
          \/ TraceWriterTryPublishFail

    \/ /\ IsWriter(tid)
       /\ logline.event = "WriterTakeInner"
       /\ TraceWriterTakeInner

\* ========================================================================
\* Silent Actions
\* ========================================================================

\* No silent actions needed for left-right: all observable state changes
\* are instrumented and recorded in the trace.
SilentActions == FALSE

\* ========================================================================
\* Trace Init
\* ========================================================================

TraceInit ==
    /\ Init
    /\ pc = [tid \in TraceThreads |-> 1]

\* ========================================================================
\* Trace Next
\* ========================================================================

TraceNext ==
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            LET logline == traces[tid][pc[tid]] IN
            /\ MatchEvent(tid, logline)
            /\ pc' = [pc EXCEPT ![tid] = pc[tid] + 1]
    \/ /\ ThreadsWithEvents /= {}
       /\ SilentActions
       /\ UNCHANGED pc
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED <<vars, pc>>

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, pc>>

\* ========================================================================
\* Completion check
\* ========================================================================

TraceFullyConsumed == <>(ThreadsWithEvents = {})

\* ========================================================================
\* Invariants for trace validation
\* ========================================================================

\* Safety invariants that should hold on every real execution.
TraceNoWriteWhileRead == NoWriteWhileRead
TraceApplyCorrectness == ApplyCorrectness

\* Structural invariants to catch modeling errors.
TraceTypeOK          == TypeOK
TraceEpochParity     == EpochParity
TracePointerDisjoint == PointerCopyDisjoint

====
