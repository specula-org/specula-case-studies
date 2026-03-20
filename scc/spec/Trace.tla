------------------------------ MODULE Trace ------------------------------
(*
 * Trace validation spec for scc HashMap.
 * Replays NDJSON traces against the base spec to verify consistency.
 *
 * Trace events are emitted by instrumented scc code and recorded as
 * NDJSON lines. Each line has:
 *   {"event": "<name>", "thread": "<id>", ...fields...}
 *)
EXTENDS base, Json, IOUtils, Sequences, TLC, Naturals

\* ---------------------------------------------------------------
\* Trace loading
\* ---------------------------------------------------------------

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTrace == ndJsonDeserialize(JsonFile)

\* Filter to only scc events (in case trace has other noise)
TraceLog == SelectSeq(RawTrace, LAMBDA e : "event" \in DOMAIN e)

\* ---------------------------------------------------------------
\* Cursor variable
\* ---------------------------------------------------------------
VARIABLE l   \* Current position in TraceLog (1-based)

traceVars == <<vars, l>>

\* ---------------------------------------------------------------
\* Helpers
\* ---------------------------------------------------------------

\* Current log line
logline == TraceLog[l]

\* Event matching predicates
IsEvent(name) == l <= Len(TraceLog) /\ logline.event = name

IsThreadEvent(name, t) ==
    /\ IsEvent(name)
    /\ logline.thread = t

\* Map thread string from trace to Thread constant
\* Thread mapping is established during TraceInit from the trace
ThreadMap(s) ==
    CHOOSE t \in Thread : ToString(t) = s

\* Map array ID from trace
ArrayMap(id) ==
    IF id = "null" THEN NullArray
    ELSE CHOOSE a \in ArrayId \cup {NullArray} : ToString(a) = id

\* ---------------------------------------------------------------
\* Post-state validation
\* ---------------------------------------------------------------

\* Strong: validate full post-state snapshot from trace
\* Uses primed variables since trace events capture state AFTER the action
ValidatePostState(t) ==
    /\ "guard_active" \in DOMAIN logline =>
        guardActive'[ThreadMap(logline.thread)] = logline.guard_active
    /\ "current_array" \in DOMAIN logline =>
        currentArray' = ArrayMap(logline.current_array)

\* Weak: validate only thread-local post-state
ValidatePostStateWeak(t) ==
    /\ "guard_active" \in DOMAIN logline =>
        guardActive'[ThreadMap(logline.thread)] = logline.guard_active

\* ---------------------------------------------------------------
\* Trace action wrappers
\* ---------------------------------------------------------------

\* --- EBR Guard ---

TraceCreateGuard ==
    /\ IsEvent("create_guard")
    /\ LET t == ThreadMap(logline.thread)
       IN /\ CreateGuard(t)
          /\ ValidatePostState(t)
    /\ l' = l + 1

TraceDropGuard ==
    /\ IsEvent("drop_guard")
    /\ LET t == ThreadMap(logline.thread)
       IN /\ DropGuard(t)
          /\ ValidatePostState(t)
    /\ l' = l + 1

\* --- Sync Read ---

TraceBeginSyncRead ==
    /\ IsEvent("begin_sync_read")
    /\ LET t == ThreadMap(logline.thread)
           k == logline.key
           b == logline.bucket
       IN /\ BeginSyncRead(t, k, b)
          /\ ValidatePostState(t)
    /\ l' = l + 1

TraceAccessDataSync ==
    /\ IsEvent("access_data")
    /\ LET t == ThreadMap(logline.thread)
           k == logline.key
       IN /\ AccessDataSync(t, k)
          /\ ValidatePostStateWeak(t)
    /\ l' = l + 1

TraceEndSyncRead ==
    /\ IsEvent("end_sync_read")
    /\ LET t == ThreadMap(logline.thread)
       IN /\ EndSyncRead(t)
          /\ ValidatePostState(t)
    /\ l' = l + 1

\* --- Sync Write ---

TraceInsertSync ==
    /\ IsEvent("insert")
    /\ LET t == ThreadMap(logline.thread)
           k == logline.key
           b == logline.bucket
       IN /\ InsertSync(t, k, b)
          /\ ValidatePostState(t)
    /\ l' = l + 1

TraceRemoveSync ==
    /\ IsEvent("remove")
    /\ LET t == ThreadMap(logline.thread)
           k == logline.key
       IN /\ RemoveSync(t, k)
          /\ ValidatePostState(t)
    /\ l' = l + 1

\* --- Resize ---

TraceTriggerResize ==
    /\ IsEvent("trigger_resize")
    /\ LET t == ThreadMap(logline.thread)
       IN /\ TriggerResize(t)
          /\ ValidatePostState(t)
    /\ l' = l + 1

TraceClaimRehashRange ==
    /\ IsEvent("claim_rehash_range")
    /\ LET t == ThreadMap(logline.thread)
           a == ArrayMap(logline.old_array)
       IN /\ ClaimRehashRange(t, a)
          /\ ValidatePostStateWeak(t)
    /\ l' = l + 1

TraceRelocateBucket ==
    /\ IsEvent("relocate_bucket")
    /\ LET t == ThreadMap(logline.thread)
           a == ArrayMap(logline.old_array)
           b == logline.bucket
       IN /\ RelocateBucket(t, a, b)
          /\ ValidatePostStateWeak(t)
    /\ l' = l + 1

TraceRelocateBucketFail ==
    /\ IsEvent("relocate_bucket_fail")
    /\ LET t == ThreadMap(logline.thread)
           a == ArrayMap(logline.old_array)
           b == logline.bucket
       IN /\ RelocateBucketFail(t, a, b)
          /\ ValidatePostStateWeak(t)
    /\ l' = l + 1

TraceEndRehash ==
    /\ IsEvent("end_rehash")
    /\ LET t == ThreadMap(logline.thread)
           a == ArrayMap(logline.old_array)
       IN /\ EndRehash(t, a)
          /\ ValidatePostState(t)
    /\ l' = l + 1

TraceFinalizeResize ==
    /\ IsEvent("finalize_resize")
    /\ LET t == ThreadMap(logline.thread)
           a == ArrayMap(logline.old_array)
       IN /\ FinalizeResize(t, a)
          /\ ValidatePostState(t)
    /\ l' = l + 1

TraceDedupBucket ==
    /\ IsEvent("dedup_bucket")
    /\ LET t == ThreadMap(logline.thread)
           b == logline.bucket
       IN /\ DedupBucket(t, b)
          /\ ValidatePostStateWeak(t)
    /\ l' = l + 1

\* --- Async Read ---

TraceBeginAsyncRead ==
    /\ IsEvent("begin_async_read")
    /\ LET t == ThreadMap(logline.thread)
       IN /\ BeginAsyncRead(t)
          /\ ValidatePostState(t)
    /\ l' = l + 1

TraceAsyncAwait ==
    /\ IsEvent("async_await")
    /\ LET t == ThreadMap(logline.thread)
       IN /\ AsyncAwait(t)
          /\ ValidatePostStateWeak(t)
    /\ l' = l + 1

TraceAsyncReacquireGuard ==
    /\ IsEvent("async_reacquire_guard")
    /\ LET t == ThreadMap(logline.thread)
       IN /\ AsyncReacquireGuard(t)
          /\ ValidatePostState(t)
    /\ l' = l + 1

TraceAsyncCheckRef ==
    /\ IsEvent("async_check_ref")
    /\ LET t == ThreadMap(logline.thread)
       IN /\ AsyncCheckRef(t)
          /\ ValidatePostState(t)
    /\ l' = l + 1

TraceAsyncOperate ==
    /\ IsEvent("async_operate")
    /\ LET t == ThreadMap(logline.thread)
           k == logline.key
       IN /\ AsyncOperate(t, k)
          /\ ValidatePostStateWeak(t)
    /\ l' = l + 1

TraceEndAsyncRead ==
    /\ IsEvent("end_async_read")
    /\ LET t == ThreadMap(logline.thread)
       IN /\ EndAsyncRead(t)
          /\ ValidatePostState(t)
    /\ l' = l + 1

\* --- EBR ---

TraceAdvanceEpoch ==
    /\ IsEvent("advance_epoch")
    /\ AdvanceEpoch
    /\ l' = l + 1

TraceReclaimArray ==
    /\ IsEvent("reclaim_array")
    /\ LET a == ArrayMap(logline.array)
       IN /\ ReclaimArray(a)
    /\ l' = l + 1

\* ---------------------------------------------------------------
\* Silent actions (no trace event consumed)
\* ---------------------------------------------------------------

\* Silent epoch advancement: may happen without explicit trace event
\* Constrained: only fire if next event requires it
SilentAdvanceEpoch ==
    /\ l <= Len(TraceLog)
    \* Only advance if next event is reclaim_array (needs epoch to have advanced)
    /\ logline.event = "reclaim_array"
    /\ AdvanceEpoch
    /\ l' = l

\* Silent dedup: occurs implicitly during read/write without separate event
SilentDedupBucket ==
    /\ l <= Len(TraceLog)
    \* Only fire if next event is a read/write that requires dedup
    /\ logline.event \in {"begin_sync_read", "insert", "remove"}
    /\ linkedArray[currentArray] /= NullArray
    /\ \E t \in Thread, b \in Bucket : DedupBucket(t, b)
    /\ l' = l

\* ---------------------------------------------------------------
\* Init and Next
\* ---------------------------------------------------------------

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \* Trace action wrappers
    \/ TraceCreateGuard
    \/ TraceDropGuard
    \/ TraceBeginSyncRead
    \/ TraceAccessDataSync
    \/ TraceEndSyncRead
    \/ TraceInsertSync
    \/ TraceRemoveSync
    \/ TraceTriggerResize
    \/ TraceClaimRehashRange
    \/ TraceRelocateBucket
    \/ TraceRelocateBucketFail
    \/ TraceEndRehash
    \/ TraceFinalizeResize
    \/ TraceDedupBucket
    \/ TraceBeginAsyncRead
    \/ TraceAsyncAwait
    \/ TraceAsyncReacquireGuard
    \/ TraceAsyncCheckRef
    \/ TraceAsyncOperate
    \/ TraceEndAsyncRead
    \/ TraceAdvanceEpoch
    \/ TraceReclaimArray
    \* Silent actions
    \/ SilentAdvanceEpoch
    \/ SilentDedupBucket

\* Done: self-loop when trace fully consumed (prevents deadlock report)
TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED traceVars

TraceNextOrDone ==
    \/ TraceNext
    \/ TraceDone

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

\* ---------------------------------------------------------------
\* Trace-specific invariants
\* ---------------------------------------------------------------

\* All base spec safety invariants also apply during trace replay
TraceEntryReachability == EntryReachability
TraceNoUseAfterFree == NoUseAfterFree
TraceEpochSafety == EpochSafety

=============================================================================
