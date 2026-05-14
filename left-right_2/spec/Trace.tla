---- MODULE Trace ----
(***************************************************************************)
(* Trace validation spec for left-right (Category B: per-thread timebox).  *)
(*                                                                         *)
(* Per-thread NDJSON traces with [start, end] intervals.  TLC searches all *)
(* viable interleavings consistent with the recorded real-time order via  *)
(* ViablePIDs (events whose intervals overlap can be ordered in any way). *)
(*                                                                         *)
(* Trace format: preprocessed JSON                                         *)
(*   { threads: { tid: [ {event, start, end, state: {...}}, ... ] } }      *)
(* See instrumentation-spec.md for the field schema.                       *)
(*                                                                         *)
(* Granularity note: the Round-2 base spec splits publish() and            *)
(* take_inner() into ~10 sub-actions each.  The instrumentation, however, *)
(* records each public API call as a SINGLE event.  Trace.tla therefore    *)
(* bundles the corresponding base sub-actions into one atomic transition  *)
(* with the resulting post-state — the timebox approach lets TLC search   *)
(* compatible interleavings against the recorded intervals while still     *)
(* enforcing the spec's pre/post conditions at event boundaries.          *)
(*                                                                         *)
(* Bug-detection happens in MC.tla (with action splits + adversaries);     *)
(* Trace.tla establishes that the Round-2 spec can reproduce real          *)
(* executions and is therefore not over-restrictive.                       *)
(***************************************************************************)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* ========================================================================
\* Trace loading
\* ========================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTrace == JsonDeserialize(JsonFile)

traces == RawTrace.threads
TraceThreads == DOMAIN traces

\* ========================================================================
\* Per-thread cursor
\* ========================================================================

VARIABLE pc
traceVars == <<pc>>

\* ========================================================================
\* Helpers
\* ========================================================================

ThreadsWithEvents ==
    { tid \in TraceThreads : pc[tid] <= Len(traces[tid]) }

\* ViablePIDs: a thread is viable iff no other thread's pending event
\* ended strictly before this thread's next event started.  Overlapping
\* intervals are mutually viable; TLC explores both orderings.
ViablePIDs ==
    { tid \in ThreadsWithEvents :
        ~ \E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pc[tid2]].end < traces[tid][pc[tid]].start }

\* tid → reader id mapping.  Trace tids are "r1", "r2" etc.; spec ids
\* are R1, R2 (TLC model values).  We use string tids equal to model values.
MapReader(tid) == tid
IsWriter(tid) == tid = "writer"

\* ========================================================================
\* Post-state validation — match captured fields against spec post-state
\* ========================================================================

ValidateReaderState(tid, logline) ==
    LET r == MapReader(tid) IN
    /\ ("epoch" \in DOMAIN logline.state =>
        epoch'[r] = logline.state.epoch)
    /\ ("enters" \in DOMAIN logline.state =>
        enters'[r] = logline.state.enters)

ValidatePointer(logline) ==
    IF "pointer" \in DOMAIN logline.state
    THEN inner_ptr' = logline.state.pointer
    ELSE TRUE

ValidateCopyData(logline) ==
    /\ ("copyL" \in DOMAIN logline.state =>
        copyData'["L"] = logline.state.copyL)
    /\ ("copyR" \in DOMAIN logline.state =>
        copyData'["R"] = logline.state.copyR)

ValidateFirstSecond(logline) ==
    /\ ("first" \in DOMAIN logline.state =>
        first' = logline.state.first)
    /\ ("second" \in DOMAIN logline.state =>
        second' = logline.state.second)

ValidateTaken(logline) ==
    IF "taken" \in DOMAIN logline.state
    THEN taken' = logline.state.taken
    ELSE TRUE

\* Variables not modified by any trace action.  Note: snapPending and
\* clientHolding are spec-only adversary state, never observed in real
\* traces.
TraceUnchangedAll ==
    UNCHANGED <<panicked, registered, mutexHolder,
                snapPending, clientHolding>>

\* ========================================================================
\* Composite trace actions — one per public API event
\* ========================================================================

\* TraceReaderEnter — read.rs:177-205 fresh enter, non-NULL branch.
\* Bundles ReaderEnterFreshBumpEpoch + ReaderEnterFreshLoad (non-null
\* branch) into one atomic transition.
TraceReaderEnter(tid, logline) ==
    LET r == MapReader(tid) IN
    /\ registered[r]
    /\ rPC[r] = "Idle"
    /\ enters[r] = 0
    /\ inner_ptr /= "null"
    /\ epoch' = [epoch EXCEPT ![r] = epoch[r] + 1]   \* read.rs:180
    /\ readerHolding' = [readerHolding EXCEPT ![r] = inner_ptr]
                                                       \* read.rs:186 load
    /\ enters' = [enters EXCEPT ![r] = 1]            \* read.rs:194-195
    /\ rPC' = [rPC EXCEPT ![r] = "Reading"]
    /\ ValidateReaderState(tid, logline)
    /\ ValidatePointer(logline)
    /\ UNCHANGED <<inner_ptr, writerCopy, copyAlive, synced, copyData,
                   lastEpochs, releasedCopy,
                   wPC, totalOps, oplogLen, swapIndex,
                   first, second, taken>>
    /\ TraceUnchangedAll

\* TraceReaderEnterNone — read.rs:206-213 fresh enter, NULL branch.
TraceReaderEnterNone(tid, logline) ==
    LET r == MapReader(tid) IN
    /\ registered[r]
    /\ rPC[r] = "Idle"
    /\ enters[r] = 0
    /\ inner_ptr = "null"
    /\ epoch' = [epoch EXCEPT ![r] = epoch[r] + 2]   \* +1 then +1 again (180, 209)
    /\ ValidateReaderState(tid, logline)
    /\ UNCHANGED <<inner_ptr, writerCopy, copyAlive, synced, copyData,
                   lastEpochs, enters, readerHolding, releasedCopy,
                   rPC, wPC, totalOps, oplogLen, swapIndex,
                   first, second, taken>>
    /\ TraceUnchangedAll

\* TraceReaderEnterNested — read.rs:120-148 reentrant branch.
\* Note: this trace event NEVER observes inner_ptr = NULL; if it did, the
\* implementation would have hit unreachable!() (read.rs:146) and crashed
\* before emitting the event.  So we only model the non-null branch.
TraceReaderEnterNested(tid, logline) ==
    LET r == MapReader(tid) IN
    /\ rPC[r] = "Reading"
    /\ enters[r] > 0
    /\ inner_ptr /= "null"
    /\ enters' = [enters EXCEPT ![r] = enters[r] + 1]   \* read.rs:133-134
    /\ readerHolding' = [readerHolding EXCEPT ![r] = inner_ptr]
    /\ ValidateReaderState(tid, logline)
    /\ ValidatePointer(logline)
    /\ UNCHANGED <<inner_ptr, writerCopy, copyAlive, synced, copyData,
                   epoch, lastEpochs, releasedCopy,
                   rPC, wPC, totalOps, oplogLen, swapIndex,
                   first, second, taken>>
    /\ TraceUnchangedAll

\* TraceReaderExit — guard.rs:117-130 ReadGuard::Drop.
TraceReaderExit(tid, logline) ==
    LET r == MapReader(tid) IN
    /\ rPC[r] = "Reading"
    /\ enters[r] > 0
    /\ enters' = [enters EXCEPT ![r] = enters[r] - 1] \* guard.rs:120-121
    /\ IF enters[r] - 1 = 0
       THEN /\ epoch' = [epoch EXCEPT ![r] = epoch[r] + 1] \* guard.rs:124
            /\ rPC' = [rPC EXCEPT ![r] = "Idle"]
            /\ readerHolding' = [readerHolding EXCEPT ![r] = "none"]
       ELSE UNCHANGED <<epoch, rPC, readerHolding>>
    /\ ValidateReaderState(tid, logline)
    /\ UNCHANGED <<inner_ptr, writerCopy, copyAlive, synced, copyData,
                   lastEpochs, releasedCopy,
                   wPC, totalOps, oplogLen, swapIndex,
                   first, second, taken>>
    /\ TraceUnchangedAll

\* TraceWriterAppend — write.rs:497-506 + 560-578 (single-op extend).
TraceWriterAppend(tid, logline) ==
    /\ IsWriter(tid)
    /\ wPC = "Idle"
    /\ ~taken
    /\ totalOps' = totalOps + 1
    /\ IF first
       THEN /\ copyData' =
                [copyData EXCEPT ![writerCopy] = copyData[writerCopy] + 1]
            /\ UNCHANGED oplogLen
       ELSE /\ oplogLen' = oplogLen + 1
            /\ UNCHANGED copyData
    /\ ValidateCopyData(logline)
    /\ ValidateFirstSecond(logline)
    /\ UNCHANGED <<inner_ptr, writerCopy, copyAlive, synced,
                   epoch, lastEpochs, enters, readerHolding, releasedCopy,
                   rPC, wPC,
                   swapIndex, first, second, taken>>
    /\ TraceUnchangedAll

\* TraceWriterPublish — write.rs:370-391 (lock + wait + update_and_swap).
\* Bundles the full publish() sub-action sequence atomically; the timebox
\* interval [start, end] subsumes all sub-actions.
TraceWriterPublish(tid, logline) ==
    /\ IsWriter(tid)
    /\ wPC = "Idle"
    /\ ~taken
    /\ AllReadersQuiescedByLastEpochs              \* wait skip rule passed
    /\ \/ /\ first
          /\ first' = FALSE                         \* write.rs:439-441
          /\ UNCHANGED <<copyData, second, synced, oplogLen, swapIndex>>
       \/ /\ ~first
          /\ IF second
             THEN /\ second' = FALSE
                  /\ synced' = [synced EXCEPT ![writerCopy] = TRUE]
             ELSE UNCHANGED <<second, synced>>
          /\ copyData' = [copyData EXCEPT ![writerCopy] = totalOps]
          /\ swapIndex' = oplogLen
          /\ UNCHANGED <<oplogLen, first>>
    \* (write.rs:455) atomic swap inner_ptr ↔ writerCopy.
    /\ inner_ptr' = writerCopy
    /\ writerCopy' = OtherCopy(writerCopy)
    \* (write.rs:464-466) per-reader epoch snapshot.
    /\ lastEpochs' = [r \in Reader |-> epoch[r]]
    /\ ValidatePointer(logline)
    /\ ValidateCopyData(logline)
    /\ ValidateFirstSecond(logline)
    /\ UNCHANGED <<copyAlive,
                   epoch, enters, readerHolding, releasedCopy,
                   rPC, wPC, totalOps, taken>>
    /\ TraceUnchangedAll

\* WriterTryPublishOk shares the same post-state as WriterPublish.
TraceWriterTryPublishOk(tid, logline) ==
    TraceWriterPublish(tid, logline)

\* TraceWriterTryPublishFail — write.rs:337-349, no state mutation.
TraceWriterTryPublishFail(tid, logline) ==
    /\ IsWriter(tid)
    /\ wPC = "Idle"
    /\ ~taken
    /\ ValidatePointer(logline)
    /\ ValidateFirstSecond(logline)
    /\ UNCHANGED <<inner_ptr, writerCopy, copyAlive, synced, copyData,
                   epoch, lastEpochs, enters, readerHolding, releasedCopy,
                   rPC, wPC, totalOps, oplogLen, swapIndex,
                   first, second, taken>>
    /\ TraceUnchangedAll

\* TraceWriterTakeInner — write.rs:149-210 (full take_inner + drops).
\* Bundles all take_inner sub-actions atomically.  The recorded post-state
\* shows pointer="null", taken=TRUE, both copies dropped (copyAlive=FALSE).
TraceWriterTakeInner(tid, logline) ==
    /\ IsWriter(tid)
    /\ wPC = "Idle"
    /\ ~taken
    /\ AllReadersQuiescedByLastEpochs
    /\ taken' = TRUE
    /\ \/ /\ first
          /\ first' = FALSE
          /\ UNCHANGED <<copyData, second, synced, oplogLen, swapIndex>>
       \/ /\ ~first
          /\ IF second
             THEN /\ second' = FALSE
                  /\ synced' = [synced EXCEPT ![writerCopy] = TRUE]
             ELSE UNCHANGED <<second, synced>>
          /\ copyData' = [copyData EXCEPT ![writerCopy] = totalOps]
          /\ swapIndex' = oplogLen
          /\ UNCHANGED <<oplogLen, first>>
    \* After internal publish: inner_ptr would become old writerCopy and
    \* writerCopy becomes the swapped copy.  Then the NULL-swap captures
    \* the inner_ptr post-publish into releasedCopy.  Both copies dropped.
    /\ LET swapped == OtherCopy(writerCopy) IN
       /\ inner_ptr' = "null"
       /\ writerCopy' = swapped
       /\ releasedCopy' = writerCopy        \* old writerCopy = post-publish ptr
       /\ copyAlive' = [c \in {"L","R"} |-> FALSE]
    /\ lastEpochs' = [r \in Reader |-> epoch[r]]
    /\ ValidatePointer(logline)
    /\ ValidateTaken(logline)
    /\ UNCHANGED <<epoch, enters, readerHolding,
                   rPC, wPC, totalOps>>
    /\ TraceUnchangedAll

\* ========================================================================
\* Event matching
\* ========================================================================

MatchEvent(tid, logline) ==
    \/ /\ logline.event = "ReaderEnter"
       /\ TraceReaderEnter(tid, logline)
    \/ /\ logline.event = "ReaderEnterNone"
       /\ TraceReaderEnterNone(tid, logline)
    \/ /\ logline.event = "ReaderEnterNested"
       /\ TraceReaderEnterNested(tid, logline)
    \/ /\ logline.event = "ReaderExit"
       /\ TraceReaderExit(tid, logline)
    \/ /\ logline.event = "WriterAppend"
       /\ TraceWriterAppend(tid, logline)
    \/ /\ logline.event = "WriterPublish"
       /\ TraceWriterPublish(tid, logline)
    \/ /\ logline.event = "WriterTryPublishOk"
       /\ TraceWriterTryPublishOk(tid, logline)
    \/ /\ logline.event = "WriterTryPublishFail"
       /\ TraceWriterTryPublishFail(tid, logline)
    \/ /\ logline.event = "WriterTakeInner"
       /\ TraceWriterTakeInner(tid, logline)

\* ========================================================================
\* Init / Next / Spec
\* ========================================================================

TraceInit ==
    /\ Init
    /\ pc = [tid \in TraceThreads |-> 1]

TraceNext ==
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            LET logline == traces[tid][pc[tid]] IN
            /\ MatchEvent(tid, logline)
            /\ pc' = [pc EXCEPT ![tid] = pc[tid] + 1]
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED <<vars, pc>>

TraceSpec ==
    TraceInit /\ [][TraceNext]_<<vars, pc>> /\ WF_<<vars, pc>>(TraceNext)

\* The trace must be fully consumed eventually.
TraceFullyConsumed == <>(ThreadsWithEvents = {})
TraceMatched == TraceFullyConsumed

====
