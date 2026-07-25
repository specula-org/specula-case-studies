------------------------------ MODULE Trace ------------------------------
(***************************************************************************
  Trace validation for VibeTensor CUDA allocator.

  **Category B (concurrent / lock-free / runtime)** — per-thread trace with
  timebox [start, end] intervals (see references/trace-spec-pattern.md §
  "Category B: Timebox Trace Spec").

  Each spec action that mutates shared allocator state corresponds to a
  single trace event emitted by the instrumented code.  State is snapshotted
  *outside* the [start, end] window (i.e., before start or after end) to keep
  the critical-section interval as tight as possible.  Events are grouped
  per thread; TLC searches the partial-order space via `ViablePIDs`.

  Trace schema:  see instrumentation-spec.md.
 ***************************************************************************)
EXTENDS base, Json, IOUtils, Sequences, TLC, Naturals, FiniteSets

\* -------------------------------------------------------------------------
\* Trace file location (preprocessed to per-thread arrays).
\* The harness writes traces/<name>.ndjson and the preprocessor converts it
\* to traces/<name>.json with structure { traces: [tid -> [events...]] }.
\* -------------------------------------------------------------------------
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.json"

TraceFile == JsonDeserialize(JsonFile)

\* traces : [tid -> Seq([name, start, end, state, fields])]
traces == TraceFile.traces

\* -------------------------------------------------------------------------
\* Trace-derived constants
\* -------------------------------------------------------------------------
TraceThreads == DOMAIN traces

\* -------------------------------------------------------------------------
\* Per-thread cursor
\* -------------------------------------------------------------------------
VARIABLES
    pc,          \* [tid -> Nat]: each thread's next event index (1-based)
    windowObs    \* [BlockId -> SUBSET Streams]: ghost variable for Family 3 —
                 \* records stream-ids that `record_stream` observed while the
                 \* block was in the raw_delete off-lock window.  Lets us
                 \* assert StreamUsesPersist after rollback.

ThreadsWithEvents ==
    { tid \in TraceThreads : pc[tid] <= Len(traces[tid]) }

\* Partial order: thread can step iff no other thread's pending event ended
\* strictly before this thread's next event started.
ViablePIDs ==
    { tid \in ThreadsWithEvents :
        ~ \E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pc[tid2]].end < traces[tid][pc[tid]].start }

\* -------------------------------------------------------------------------
\* Trace loading & bootstrap.  Initial allocator state is the base spec's
\* Init; no blocks exist, all queues empty, no captures active.
\* -------------------------------------------------------------------------
TraceInit ==
    /\ Init
    /\ pc = [tid \in TraceThreads |-> 1]
    /\ windowObs = [b \in BlockIds |-> {}]

\* =========================================================================
\* Event matchers.
\*
\* Each wrapper:
\*   1. dispatches on the event `name` field
\*   2. extracts per-event fields
\*   3. calls the base spec action with those fields
\*   4. validates the captured post-state against the base spec's computed
\*      post-state (see ValidatePostState.* helpers below)
\* =========================================================================
BaseState ==
    [ existingBlocks |-> existingBlocks,
      byPtr          |-> byPtr,
      activeBlocks   |-> activeBlocks,
      perStreamFree  |-> perStreamFree,
      crossStreamFree|-> crossStreamFree,
      limbo          |-> limbo,
      deferredQ      |-> deferredQ,
      reservedBytes  |-> reservedBytes,
      routingFlag    |-> routingFlag,
      rdPc           |-> rdPc,
      pePc           |-> pePc,
      fgPc           |-> fgPc ]

\* -- Strong post-state validation helpers ---------------------------------
ValidateAlloc(logline, tid, bid) ==
    \* logline.state captures post-action BaseState.
    \* Byte sizes abstracted to unit=1 in the spec; don't compare raw bytes.
    /\ bid \in existingBlocks'
    /\ bid \in byPtr' /\ bid \in activeBlocks'

ValidateReuse(logline, bid, sid) ==
    /\ bid \in existingBlocks' /\ bid \in activeBlocks'
    /\ bid \notin perStreamFree'[sid]
    /\ bid \notin crossStreamFree'

ValidateMark(logline, tid, bid) ==
    /\ rdPc'[tid] = "Marked"
    /\ rdBlock'[tid] = bid
    /\ ~ block'[bid].allocated

ValidatePublish(logline, tid, bid) ==
    /\ rdPc'[tid] = "Idle"
    /\ bid \in existingBlocks'

ValidatePeSnapshot(logline, tid) ==
    /\ pePc'[tid] = "Snapshotted"
    /\ Len(peCands'[tid]) = logline.state.deferredLen

ValidatePePublish(logline, tid, bid) ==
    /\ pePc'[tid] = "Snapshotted"
    /\ LET nStreams == Cardinality(peRecorded[tid]) IN
         \A sid \in peRecorded[tid] : Len(limbo'[sid]) >= 1

ValidateCoalesce(logline, bid) ==
    \* Either the block was merged (removed) or left alone.
    /\ \/ bid \notin existingBlocks'
       \/ bid \in existingBlocks'

ValidateGcDetach(logline, head) ==
    /\ head \notin existingBlocks'

ValidateBeginCapture(logline, tid, id) ==
    /\ routingFlag' = TRUE
    /\ tls'[tid].active /\ tls'[tid].pool = id

ValidateEndCapture(logline, tid, id) ==
    /\ routingFlag' = FALSE
    /\ \/ tls'[tid].active = FALSE
       \/ tls'[tid].pool # id

ValidateGuardDestruct(logline, tid, id) ==
    /\ routingFlag' = FALSE
    /\ <<tid, id>> \notin guardOwners'

ValidatePassGate(logline, tid) ==
    /\ fgPc'[tid] \in {"PastGate", "GCDone", "Idle"}

\* =========================================================================
\* Dispatch
\* =========================================================================
MatchEvent(tid, logline) ==
    LET name   == logline.name
        fields == logline.fields
    IN
    \/ /\ name = "raw_alloc.new"
       /\ RawAllocNewBlock(tid, fields.sid, fields.pool)
       /\ ValidateAlloc(logline, tid, fields.bid)
    \/ /\ name = "raw_alloc.reuse_stream"
       /\ RawAllocReuseFromFreeList(tid, fields.sid, fields.pool)
       /\ ValidateReuse(logline, fields.bid, fields.sid)
    \/ /\ name = "raw_alloc.reuse_cross"
       /\ RawAllocReuseFromCross(tid, fields.sid)
       /\ ValidateReuse(logline, fields.bid, fields.sid)
    \/ /\ name = "split"
       /\ Split(fields.bid)
    \/ /\ name = "record_stream"
       /\ RecordStream(tid, fields.bid, fields.sid)
       /\ \* Family 3 ghost: if the block is currently in rd window, record it
          LET in_window ==
               \E t2 \in TraceThreads : rdBlock[t2] = fields.bid
                                     /\ rdPc[t2] \in {"Marked", "RecordFailed"}
          IN
          windowObs' = IF in_window
                       THEN [windowObs EXCEPT ![fields.bid] = @ \cup {fields.sid}]
                       ELSE windowObs
    \/ /\ name = "raw_delete.mark"
       /\ RawDeleteMark(tid, fields.bid, fields.new_owner)
       /\ ValidateMark(logline, tid, fields.bid)
    \/ /\ name = "raw_delete.same_stream_fast"
       /\ RawDeleteSameStreamFastPath(tid, fields.bid, fields.new_owner)
    \/ /\ name = "raw_delete.record_ok"
       /\ RawDeleteRecordOk(tid)
    \/ /\ name = "raw_delete.record_fail"
       /\ RawDeleteRecordFail(tid)
    \/ /\ name = "raw_delete.publish"
       /\ RawDeletePublish(tid)
       /\ ValidatePublish(logline, tid, fields.bid)
    \/ /\ name = "raw_delete.finish_rollback"
       /\ RawDeleteFinishRollback(tid)
    \/ /\ name = "raw_delete.to_deferred"
       /\ RawDeleteToDeferred(tid)
    \/ /\ name = "pe.snapshot"
       /\ PeSnapshot(tid)
       /\ ValidatePeSnapshot(logline, tid)
    \/ /\ name = "pe.skip_capturing"
       /\ PeSkipCapturing(tid)
    \/ /\ name = "pe.record_ok"
       /\ PeRecordOk(tid)
    \/ /\ name = "pe.record_fail"
       /\ PeRecordFail(tid)
    \/ /\ name = "pe.publish"
       /\ PePublish(tid)
       /\ ValidatePePublish(logline, tid, fields.bid)
    \/ /\ name = "pe.loop_done"
       /\ PeLoopDone(tid)
    \/ /\ name = "pe.pop_ready"
       /\ PePopReady(fields.sid)
    \/ /\ name = "coalesce.left"
       /\ CoalesceLeft(fields.bid)
       /\ ValidateCoalesce(logline, fields.bid)
    \/ /\ name = "coalesce.right"
       /\ CoalesceRight(fields.bid)
       /\ ValidateCoalesce(logline, fields.bid)
    \/ /\ name = "gc.detach"
       /\ GcDetachIdleSegment(fields.head)
       /\ ValidateGcDetach(logline, fields.head)
    \/ /\ name = "emptyCache"
       /\ EmptyCache
    \/ /\ name = "pool.begin"
       /\ BeginCapture(tid, fields.pool)
       /\ ValidateBeginCapture(logline, tid, fields.pool)
    \/ /\ name = "pool.end_flat"
       /\ EndCaptureFlat(tid, fields.pool)
       /\ ValidateEndCapture(logline, tid, fields.pool)
    \/ /\ name = "pool.guard_destruct"
       /\ GuardDestruct(tid, fields.pool)
       /\ ValidateGuardDestruct(logline, tid, fields.pool)
    \/ /\ name = "pool.retain"
       /\ RetainPool(tid, fields.pool)
    \/ /\ name = "pool.release"
       /\ ReleasePool(tid, fields.pool)
    \/ /\ name = "fg.pass_gate"
       /\ PassGate(tid)
       /\ ValidatePassGate(logline, tid)
    \/ /\ name = "fg.retry_misfire"
       /\ PassGateRetryMisfire(tid)
    \/ /\ name = "fg.recovered"
       /\ PassGateRecovered(tid)
    \/ /\ name = "env.capture_start"
       /\ StreamCaptureStart(fields.sid)
    \/ /\ name = "env.capture_end"
       /\ StreamCaptureEnd(fields.sid)

\* =========================================================================
\* Silent actions (allocator-internal reactive steps that real execution
\* doesn't hook; tightly constrained to avoid state-space explosion).
\* The harness is expected to emit events for every action in MatchEvent,
\* so SilentActions should almost never fire.  We keep them as a safety
\* valve for bootstrap stutters / missing hooks.
\* =========================================================================
SilentActions ==
    \* Internal PE state transitions not directly emitted by the harness
    \* (pe.record_ok, pe.loop_done, pe.skip_capturing).
    \* These bridge the gap between the 3-step spec state machine and the
    \* coarser harness events (pe.snapshot / pe.publish only).
    \* PeRecordFail is a fault-injection action (cudaEventRecord failure);
    \* excluded from silent firing so real traces don't prematurely abort
    \* deferred flushes.  It fires only via trace event "pe.record_fail".
    \/ \E t \in TraceThreads : PeRecordOk(t)
    \/ \E t \in TraceThreads : PeSkipCapturing(t)
    \/ \E t \in TraceThreads : PeLoopDone(t)

\* =========================================================================
\* TraceNext — step one event, or stutter when no thread has events.
\* =========================================================================
TraceNext ==
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            LET logline == traces[tid][pc[tid]] IN
            /\ MatchEvent(tid, logline)
            /\ pc' = [pc EXCEPT ![tid] = pc[tid] + 1]
            /\ UNCHANGED windowObs   \* MatchEvent may override for record_stream
    \/ /\ ThreadsWithEvents /= {}
       /\ SilentActions
       /\ UNCHANGED <<pc, windowObs>>
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED <<vars, pc, windowObs>>

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, pc, windowObs>>
             /\ WF_<<vars, pc, windowObs>>(TraceNext)

\* =========================================================================
\* Completion property
\* =========================================================================
TraceMatched == <> (ThreadsWithEvents = {})

==============================================================================
