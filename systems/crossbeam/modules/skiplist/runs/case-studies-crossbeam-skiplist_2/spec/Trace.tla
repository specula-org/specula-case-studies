---- MODULE Trace ----
(***************************************************************************)
(* Trace validation spec for crossbeam-skiplist (Category B / timebox).    *)
(*                                                                         *)
(* Replays per-thread instrumented traces against the base spec to verify  *)
(* the implementation's transitions match the spec's. Uses the OmniLink    *)
(* per-thread cursor + ViablePIDs partial-order constraint.                *)
(*                                                                         *)
(* Trace input: preprocessed JSON with per-thread arrays:                  *)
(*   { "t1": [ { "event":..., "start":N, "end":N,                          *)
(*               "state":{...}, ... }, ... ],                               *)
(*     "t2": [ ... ], ... }                                                 *)
(* Compressed timestamps (preprocessor maps raw rdtsc to dense integers).   *)
(* See instrumentation-spec.md for per-event field definitions.             *)
(***************************************************************************)

EXTENDS base, Integers, Sequences, FiniteSets, TLC, IOUtils, Json

\* ========================================================================
\* Trace loading
\* ========================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTrace == JsonDeserialize(JsonFile)

\* per-thread traces — RawTrace is a record indexed by thread id
traces == RawTrace

\* All thread IDs present in trace (exclude metadata keys)
TraceThreads == DOMAIN traces \ {"meta"}

\* ========================================================================
\* Cursor variable (per-thread)
\* ========================================================================

VARIABLE pcCursor

traceVars == <<pcCursor>>
allTraceVars == <<vars, pcCursor>>

\* ========================================================================
\* Helpers
\* ========================================================================

ThreadsWithEvents ==
    {tid \in TraceThreads : pcCursor[tid] <= Len(traces[tid])}

\* OmniLink-style partial order: a thread is viable iff no other pending
\* event completed strictly before this thread's next event started.
ViablePIDs ==
    { tid \in ThreadsWithEvents :
        ~ \E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pcCursor[tid2]].end < traces[tid][pcCursor[tid]].start }

AdvancePC(tid) == pcCursor' = [pcCursor EXCEPT ![tid] = pcCursor[tid] + 1]

\* ========================================================================
\* Post-state validation
\* ========================================================================
\*
\* For each spec action, validate the key state fields the action modifies.
\* See instrumentation-spec.md for the captured fields per event.
\*
\* In Category B/timebox replay, state is captured outside the [start,end]
\* interval, so the captured value reflects what THIS thread observed
\* in real execution. TLC searches for the interleaving where the
\* captured value matches; mismatches on non-real orderings prune.

\* Validate the lenCounter when the trace event captures len.
ValidateLen(logline) ==
    IF "len" \in DOMAIN logline.state
    THEN lenCounter' = logline.state.len
    ELSE TRUE

\* Validate refcount of the target node, if captured.
ValidateRefcount(logline) ==
    IF /\ "node" \in DOMAIN logline
       /\ "refcount" \in DOMAIN logline.state
       /\ logline.node \in DOMAIN nRefcount'
       /\ logline.node \in nodes'
    THEN nRefcount'[logline.node] = logline.state.refcount
    ELSE TRUE

\* Validate level-0 mark of the target node, if captured.
ValidateMark(logline) ==
    IF /\ "node" \in DOMAIN logline
       /\ "marked0" \in DOMAIN logline.state
       /\ logline.node \in nodes'
    THEN nMark'[logline.node][0] = logline.state.marked0
    ELSE TRUE

\* No-op (when nothing semantic is exposed beyond the event tag).
ValidateNone == TRUE

\* ========================================================================
\* Event matching — one wrapper per spec action
\* The wrapper (a) checks event tag, (b) calls the base action, (c) validates
\* post-state fields.
\* ========================================================================

\* --- Insert lifecycle ---

TraceInsert_Begin(tid, logline) ==
    /\ logline.event = "Insert_Begin"
    /\ Insert_Begin(tid, logline.key, logline.value)
    /\ ValidateLen(logline)

TraceInsert_AllocCASLevel0(tid, logline) ==
    /\ logline.event = "Insert_AllocCASLevel0"
    /\ Insert_AllocCASLevel0(tid)
    /\ ValidateLen(logline)
    /\ ValidateRefcount(logline)
    \* Pin the height non-determinism in Insert_AllocCASLevel0 to the trace's
    \* observed height. Without this, TLC explores h=1..MaxHeight and the
    \* mismatched branches deadlock at the next BuildLevel event.
    /\ IF "height" \in DOMAIN logline /\ logline.height <= MaxHeight
       THEN pc'[tid].h = logline.height
       ELSE TRUE

TraceInsert_MarkOld(tid, logline) ==
    /\ logline.event = "Insert_MarkOld"
    /\ Insert_MarkOld(tid)
    /\ ValidateLen(logline)
    /\ ValidateMark(logline)

TraceInsert_BuildLevel(tid, logline) ==
    /\ logline.event = "Insert_BuildLevel"
    /\ Insert_BuildLevel(tid)
    /\ ValidateRefcount(logline)

TraceInsert_PostBuildCheck(tid, logline) ==
    /\ logline.event = "Insert_PostBuildCheck"
    /\ Insert_PostBuildCheck(tid)
    /\ ValidateNone

TraceInsert_Done(tid, logline) ==
    /\ logline.event = "Insert_Done"
    /\ Insert_Done(tid)
    /\ ValidateNone

\* --- Get ---

TraceGet(tid, logline) ==
    /\ logline.event = "Get"
    /\ Get(tid, logline.key)
    /\ ValidateLen(logline)

\* --- Remove lifecycle ---

TraceRemove_Begin(tid, logline) ==
    /\ logline.event = "Remove_Begin"
    /\ Remove_Begin(tid, logline.key)
    /\ ValidateLen(logline)

TraceRemove_Acquire(tid, logline) ==
    /\ logline.event = "Remove_Acquire"
    /\ Remove_Acquire(tid)
    /\ ValidateRefcount(logline)

TraceRemove_MarkTower(tid, logline) ==
    /\ logline.event = "Remove_MarkTower"
    /\ Remove_MarkTower(tid)
    /\ ValidateLen(logline)
    /\ ValidateMark(logline)
    /\ ValidateRefcount(logline)

TraceRemove_UnlinkLevel(tid, logline) ==
    /\ logline.event = "Remove_UnlinkLevel"
    /\ Remove_UnlinkLevel(tid)
    /\ ValidateRefcount(logline)

TraceRemove_Done(tid, logline) ==
    /\ logline.event = "Remove_Done"
    /\ Remove_Done(tid)
    /\ ValidateNone

\* --- Iterator lifecycle ---

TraceIter_Begin(tid, logline) ==
    /\ logline.event = "Iter_Begin"
    /\ LET kind == IF "iter_kind" \in DOMAIN logline /\ logline.iter_kind = "range"
                   THEN "Range" ELSE "Iter"
       IN Iter_Begin(tid, kind)
    /\ ValidateNone

TraceIter_Next(tid, logline) ==
    /\ logline.event = "Iter_Next"
    /\ Iter_Next(tid)
    /\ ValidateNone

TraceIter_NextBack(tid, logline) ==
    /\ logline.event = "Iter_NextBack"
    /\ Iter_NextBack(tid)
    /\ ValidateNone

TraceIter_Drop(tid, logline) ==
    /\ logline.event = "Iter_Drop"
    /\ Iter_Drop(tid)
    /\ ValidateNone

\* ========================================================================
\* Event dispatch
\* ========================================================================

MatchEvent(tid, logline) ==
    \/ TraceInsert_Begin(tid, logline)
    \/ TraceInsert_AllocCASLevel0(tid, logline)
    \/ TraceInsert_MarkOld(tid, logline)
    \/ TraceInsert_BuildLevel(tid, logline)
    \/ TraceInsert_PostBuildCheck(tid, logline)
    \/ TraceInsert_Done(tid, logline)
    \/ TraceGet(tid, logline)
    \/ TraceRemove_Begin(tid, logline)
    \/ TraceRemove_Acquire(tid, logline)
    \/ TraceRemove_MarkTower(tid, logline)
    \/ TraceRemove_UnlinkLevel(tid, logline)
    \/ TraceRemove_Done(tid, logline)
    \/ TraceIter_Begin(tid, logline)
    \/ TraceIter_Next(tid, logline)
    \/ TraceIter_NextBack(tid, logline)
    \/ TraceIter_Drop(tid, logline)

\* ========================================================================
\* Silent actions
\* EpochFinalize may fire between traced events (epoch GC is asynchronous
\* and not directly observable in per-thread traces). HelpUnlink is NOT
\* exposed during trace replay — when a thread cooperatively unlinks, the
\* trace event for that level CAS does appear (it's part of search_bound /
\* next_node), and letting silent HelpUnlink fire would pre-empt that CAS.
\* ========================================================================

SilentEpochFinalize ==
    /\ ThreadsWithEvents /= {}
    /\ EpochFinalize
    /\ UNCHANGED pcCursor

SilentActions == SilentEpochFinalize

\* ========================================================================
\* TraceInit / TraceNext / TraceSpec
\* ========================================================================

TraceInit ==
    /\ Init
    /\ pcCursor = [tid \in TraceThreads |-> 1]

TraceNext ==
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            LET logline == traces[tid][pcCursor[tid]] IN
            /\ MatchEvent(tid, logline)
            /\ AdvancePC(tid)
    \/ /\ ThreadsWithEvents /= {}
       /\ SilentActions
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED allTraceVars

TraceSpec ==
    TraceInit /\ [][TraceNext]_allTraceVars /\ WF_allTraceVars(TraceNext)

\* ========================================================================
\* Completion
\* TraceMatched: every event eventually consumed (all cursors past end).
\* ========================================================================

TraceFullyConsumed == ThreadsWithEvents = {}

TraceMatched == <>(ThreadsWithEvents = {})

====
