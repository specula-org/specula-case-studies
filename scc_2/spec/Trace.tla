---- MODULE Trace ----
(***************************************************************************)
(* Trace validation spec for `scc` (Category B — concurrent / lock-free).  *)
(*                                                                         *)
(* Uses the timebox / per-thread-cursor pattern (see                       *)
(* spec_generation/references/trace-spec-pattern.md § "Category B").       *)
(*                                                                         *)
(* The harness emits per-thread JSON arrays of events with                 *)
(* [start, end] timestamp intervals (rdtsc-derived). ViablePIDs gives the  *)
(* partial-order constraint; TLC searches all viable interleavings of      *)
(* overlapping events.                                                     *)
(*                                                                         *)
(* See instrumentation-spec.md for the exact event schema.                 *)
(***************************************************************************)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* ========================================================================
\* Trace loading
\* ========================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.json"

\* JSON layout:
\*   {
\*     "threads": ["t1","t2",...],
\*     "events": {
\*        "t1": [ {start, end, event, ...}, ... ],
\*        "t2": [ ... ],
\*        ...
\*     }
\*   }
TraceData == ndJsonDeserialize(JsonFile)

\* Single-document JSON file: pull the (sole) record
TraceDoc == TraceData[1]

\* Per-thread arrays
traces == TraceDoc.events

\* ========================================================================
\* Per-thread cursor variable
\* ========================================================================

VARIABLE pcCursor       \* [Thread -> Nat] — index into traces[tid]

traceVars == <<pcCursor>>

\* ========================================================================
\* Helpers
\* ========================================================================

ThreadsWithEvents ==
    { tid \in Thread : pcCursor[tid] <= Len(traces[tid]) }

\* ViablePIDs: thread tid can step iff no other thread tid2 has a pending
\* event whose `end` is strictly less than tid's pending event's `start`.
\* (See trace-spec-pattern.md § "ViablePIDs (Core Concept)".)
ViablePIDs ==
    { tid \in ThreadsWithEvents :
        ~ \E tid2 \in ThreadsWithEvents :
            /\ tid2 # tid
            /\ traces[tid2][pcCursor[tid2]].end <
               traces[tid][pcCursor[tid]].start }

\* Quick accessor for the next event of thread tid
Logline(tid) == traces[tid][pcCursor[tid]]

\* ========================================================================
\* Post-state validation
\* ========================================================================

\* Each event captures `state` containing the post-action snapshot of the
\* spec variables that the action modifies. ValidatePostState checks them.
\*
\* For the writer/iter/migrate state machine, the `state` record includes
\* the relevant fields per action — see Section 2 of instrumentation-spec.md.

\* Strong: full bucket-array state (TryResize, EndIncrementalRehash, etc.)
ValidateBucketArrayState(L) ==
    /\ currentArray' = L.state.currentArray

\* Strong: slot-bitmap state for migrate / writer (slot is keyed by `key`).
ValidateSlotState(L, aid, bidx, key) ==
    /\ occBit'[<<aid, bidx, key>>]  = L.state.occBit
    /\ remBit'[<<aid, bidx, key>>]  = L.state.remBit

\* Per-thread pc state
ValidatePcState(L, tid) ==
    /\ pc'[tid].kind = L.state.kind
    /\ pc'[tid].step = L.state.step

\* ========================================================================
\* Trace action wrappers
\* ========================================================================

TraceWriterStart(tid) ==
    /\ Logline(tid).event = "WriterStart"
    /\ \E k \in Key, v \in Value :
         /\ Logline(tid).key = k
         /\ Logline(tid).val = v
         /\ WriterStart(tid, k, v)
    /\ ValidatePcState(Logline(tid), tid)

TraceWriterMaybeRehashOK(tid) ==
    /\ Logline(tid).event = "WriterMaybeRehashOK"
    /\ WriterMaybeRehashOK(tid)
    /\ ValidatePcState(Logline(tid), tid)

TraceWriterMaybeRehashRetry(tid) ==
    /\ Logline(tid).event = "WriterMaybeRehashRetry"
    /\ WriterMaybeRehashRetry(tid)
    /\ ValidatePcState(Logline(tid), tid)

TraceWriterAcquireLock(tid) ==
    /\ Logline(tid).event = "WriterAcquireLock"
    /\ WriterAcquireLock(tid)
    /\ ValidatePcState(Logline(tid), tid)
    /\ pc'[tid].bucketIdx = Logline(tid).bucketIdx

TraceWriterCommitInsert(tid) ==
    /\ Logline(tid).event = "WriterCommitInsert"
    /\ WriterCommitInsert(tid)
    /\ ValidatePcState(Logline(tid), tid)
    /\ ValidateSlotState(Logline(tid),
                         pc[tid].cachedArray, pc[tid].bucketIdx, pc[tid].key)

TraceWriterCommitMarkRemoved(tid) ==
    /\ Logline(tid).event = "WriterCommitMarkRemoved"
    /\ WriterCommitMarkRemoved(tid)
    /\ ValidatePcState(Logline(tid), tid)
    /\ ValidateSlotState(Logline(tid),
                         pc[tid].cachedArray, pc[tid].bucketIdx, pc[tid].key)

TraceWriterRelease(tid) ==
    /\ Logline(tid).event = "WriterRelease"
    /\ WriterRelease(tid)
    /\ ValidatePcState(Logline(tid), tid)

TraceIterStart(tid) ==
    /\ Logline(tid).event = "IterStart"
    /\ IterStart(tid)
    /\ ValidatePcState(Logline(tid), tid)
    /\ pc'[tid].cachedArray = Logline(tid).cachedArray

TraceIterReadOccupied(tid) ==
    /\ Logline(tid).event = "IterReadOccupied"
    /\ IterReadOccupied(tid)
    /\ ValidatePcState(Logline(tid), tid)

TraceIterReadEmpty(tid) ==
    /\ Logline(tid).event = "IterReadEmpty"
    /\ IterReadEmpty(tid)

TraceIterAdvanceWithinBucket(tid) ==
    /\ Logline(tid).event = "IterAdvanceWithinBucket"
    /\ IterAdvanceWithinBucket(tid)
    /\ pc'[tid].bucketIdx = Logline(tid).bucketIdx

TraceIterCrossArray(tid) ==
    /\ Logline(tid).event = "IterCrossArray"
    /\ IterCrossArray(tid)
    /\ ValidatePcState(Logline(tid), tid)

TraceIterFinish(tid) ==
    /\ Logline(tid).event = "IterFinish"
    /\ IterFinish(tid)
    /\ ValidatePcState(Logline(tid), tid)

TraceTryResize(tid) ==
    /\ Logline(tid).event = "TryResize"
    /\ TryResize(tid)
    /\ currentArray' = Logline(tid).state.currentArray

TraceMigrateLockOldBucket(tid) ==
    /\ Logline(tid).event = "MigrateLockOldBucket"
    /\ MigrateLockOldBucket(tid)
    /\ ValidatePcState(Logline(tid), tid)

TraceMigratePublishNew(tid) ==
    /\ Logline(tid).event = "MigratePublishNew"
    /\ MigratePublishNew(tid)
    /\ ValidatePcState(Logline(tid), tid)

TraceMigrateClearOld(tid) ==
    /\ Logline(tid).event = "MigrateClearOld"
    /\ MigrateClearOld(tid)
    /\ ValidatePcState(Logline(tid), tid)

TraceMigrateEmpty(tid) ==
    /\ Logline(tid).event = "MigrateEmpty"
    /\ MigrateEmpty(tid)
    /\ ValidatePcState(Logline(tid), tid)

TraceMigrateKillOldBucket(tid) ==
    /\ Logline(tid).event = "MigrateKillOldBucket"
    /\ MigrateKillOldBucket(tid)

TraceEndIncrementalRehash(tid) ==
    /\ Logline(tid).event = "EndIncrementalRehash"
    /\ EndIncrementalRehash(tid)
    /\ currentArray' = Logline(tid).state.currentArray

TraceDeallocGarbage(tid) ==
    /\ Logline(tid).event = "DeallocGarbage"
    /\ DeallocGarbage(tid)

\* ========================================================================
\* Match dispatch
\* ========================================================================

MatchEvent(tid) ==
    \/ TraceWriterStart(tid)
    \/ TraceWriterMaybeRehashOK(tid)
    \/ TraceWriterMaybeRehashRetry(tid)
    \/ TraceWriterAcquireLock(tid)
    \/ TraceWriterCommitInsert(tid)
    \/ TraceWriterCommitMarkRemoved(tid)
    \/ TraceWriterRelease(tid)
    \/ TraceIterStart(tid)
    \/ TraceIterReadOccupied(tid)
    \/ TraceIterReadEmpty(tid)
    \/ TraceIterAdvanceWithinBucket(tid)
    \/ TraceIterCrossArray(tid)
    \/ TraceIterFinish(tid)
    \/ TraceTryResize(tid)
    \/ TraceMigrateLockOldBucket(tid)
    \/ TraceMigratePublishNew(tid)
    \/ TraceMigrateClearOld(tid)
    \/ TraceMigrateEmpty(tid)
    \/ TraceMigrateKillOldBucket(tid)
    \/ TraceEndIncrementalRehash(tid)
    \/ TraceDeallocGarbage(tid)

\* ========================================================================
\* Silent actions — fire base actions without consuming a trace event
\* ========================================================================

\* AdvanceGlobalEpoch is not directly observed by the harness (it is
\* internal to sdd::Guard). It may need to fire silently to enable a
\* DeallocGarbage event whose post-state matches.
SilentAdvanceGlobalEpoch ==
    /\ ThreadsWithEvents # {}
    \* Only fire if some pending event is "DeallocGarbage" — gated to keep
    \* the silent action constrained.
    /\ \E tid \in ThreadsWithEvents :
         Logline(tid).event = "DeallocGarbage"
    /\ AdvanceGlobalEpoch
    /\ UNCHANGED traceVars

\* ========================================================================
\* TraceInit / TraceNext
\* ========================================================================

TraceInit ==
    /\ Init
    /\ pcCursor = [tid \in Thread |-> 1]

TraceNext ==
    \/ /\ ThreadsWithEvents # {}
       /\ \E tid \in ViablePIDs :
            /\ MatchEvent(tid)
            /\ pcCursor' = [pcCursor EXCEPT ![tid] = pcCursor[tid] + 1]
    \/ /\ ThreadsWithEvents # {}
       /\ SilentAdvanceGlobalEpoch
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED <<allVars, pcCursor>>

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_<<allVars, pcCursor>>
    /\ WF_<<allVars, pcCursor>>(TraceNext)

\* ========================================================================
\* Completion
\* ========================================================================

\* Trace fully consumed when no thread has any unconsumed events.
TraceFinished == ThreadsWithEvents = {}

\* Liveness: the trace must eventually be fully consumed.
\* (Required by Trace.cfg; see trace-spec-pattern.md § "Trace.cfg Must
\* Include TraceMatched".)
TraceMatched == <>(ThreadsWithEvents = {})

====
