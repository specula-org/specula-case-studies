---- MODULE Trace ----
(***************************************************************************)
(* Trace validation spec for crossbeam-skiplist.                           *)
(* Category B (concurrent/lock-free): per-thread timebox traces.           *)
(*                                                                         *)
(* Replays instrumented traces against the base spec to verify that the    *)
(* implementation's state transitions match the specification.             *)
(***************************************************************************)

EXTENDS base, Integers, Sequences, FiniteSets, TLC, IOUtils, Json

(* ====================================================================== *)
(* Trace Loading                                                           *)
(* ====================================================================== *)

\* Preprocessed JSON file with per-thread event arrays + compressed timestamps.
\* Format: { "t1": [...events...], "t2": [...events...], ... }
\* Each event: { "event": "...", "start": N, "end": N,
\*               "key": K, "node": N, "state": {...} }
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.json"

RawTrace == JsonDeserialize(JsonFile)

\* Per-thread traces (exclude metadata keys)
traces == RawTrace

\* Thread IDs from trace (must match Thread constant)
TraceThreads == DOMAIN traces \ {"metadata"}

(* ====================================================================== *)
(* Trace Variables                                                         *)
(* ====================================================================== *)

\* Per-thread cursor into the thread's trace array
VARIABLE tracePC

traceVars == <<tracePC>>
allTraceVars == <<vars, tracePC>>

(* ====================================================================== *)
(* Helpers                                                                 *)
(* ====================================================================== *)

\* Threads that still have unconsumed events
ThreadsWithEvents ==
    {tid \in TraceThreads : tracePC[tid] <= Len(traces[tid])}

\* Partial order constraint: thread can step iff no other thread has a
\* pending event that completed before this thread's next event started.
\* Core timebox ordering (OmniLink / Category B).
ViablePIDs ==
    {tid \in ThreadsWithEvents :
        ~\E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][tracePC[tid2]].end < traces[tid][tracePC[tid]].start}

\* Advance one thread's cursor
AdvancePC(tid) ==
    tracePC' = [tracePC EXCEPT ![tid] = tracePC[tid] + 1]

\* Node identity mapping: trace node IDs (strings) to spec node IDs (ints)
\* Trace emits string node IDs: "0" = HeadNode, "1".."N" = NodePool, "nil" = Nil
RECURSIVE StringToNat(_)
StringToNat(s) ==
    LET lastChar == SubSeq(s, Len(s), Len(s))
        d == IF lastChar = "0" THEN 0 ELSE IF lastChar = "1" THEN 1
             ELSE IF lastChar = "2" THEN 2 ELSE IF lastChar = "3" THEN 3
             ELSE IF lastChar = "4" THEN 4 ELSE IF lastChar = "5" THEN 5
             ELSE IF lastChar = "6" THEN 6 ELSE IF lastChar = "7" THEN 7
             ELSE IF lastChar = "8" THEN 8 ELSE IF lastChar = "9" THEN 9
             ELSE -1
    IN IF Len(s) = 1 THEN d
       ELSE StringToNat(SubSeq(s, 1, Len(s)-1)) * 10 + d

NodeMap(traceNodeId) ==
    IF traceNodeId = "nil" THEN Nil
    ELSE IF traceNodeId = "head" THEN HeadNode
    ELSE StringToNat(traceNodeId)

(* ====================================================================== *)
(* Post-state Validation                                                   *)
(* ====================================================================== *)

\* Strong validation: check key fields that the action modifies.
\* For concurrent systems, TLC prunes orderings where state doesn't match.

\* After insert CAS: check that the new node's key is installed at level 0
ValidateInsertCAS(logline) ==
    /\ "nodeKey" \in DOMAIN logline.state =>
       nodeKey'[NodeMap(logline.node)] = logline.state.nodeKey
    /\ "listSize" \in DOMAIN logline.state =>
       Cardinality(listMap') = logline.state.listSize

\* After remove mark: check that the node is now marked
ValidateRemoveMark(logline) ==
    /\ "removed" \in DOMAIN logline.state =>
       (logline.state.removed = TRUE) = succMarked'[NodeMap(logline.node)][0]

\* After tower build: check that the node is linked at the specified level
ValidateBuildLevel(tid, logline) ==
    /\ "level" \in DOMAIN logline.state =>
       LET n == NodeMap(logline.node)
           l == logline.state.level
       IN succ'[tPred'[tid][l]][l] = n

\* After unlink: check ref count
ValidateUnlink(logline) ==
    /\ "refCount" \in DOMAIN logline.state =>
       refCount'[NodeMap(logline.node)] = logline.state.refCount

\* After release entry: check ref count
ValidateRelease(logline) ==
    /\ "refCount" \in DOMAIN logline.state =>
       refCount'[NodeMap(logline.node)] = logline.state.refCount

(* ====================================================================== *)
(* Event Matching                                                          *)
(* ====================================================================== *)

\* --- Insert Events ---

TraceInsertBegin(tid, logline) ==
    /\ logline.event = "InsertBegin"
    /\ InsertBegin(tid, logline.key, logline.height)
    /\ ValidateInsertCAS(logline)

TraceInsertCAS(tid, logline) ==
    /\ logline.event = "InsertCAS"
    /\ InsertCAS(tid)
    /\ ValidateInsertCAS(logline)

TraceInsertBuildLevel(tid, logline) ==
    /\ logline.event = "InsertBuildLevel"
    /\ InsertBuildLevel(tid)
    /\ ValidateBuildLevel(tid, logline)

\* --- Remove Events ---

TraceRemoveBegin(tid, logline) ==
    /\ logline.event = "RemoveBegin"
    /\ RemoveBegin(tid, logline.key)

TraceRemoveMarkTower(tid, logline) ==
    /\ logline.event = "RemoveMarkTower"
    /\ RemoveMarkTower(tid)
    /\ ValidateRemoveMark(logline)

TraceRemoveUnlink(tid, logline) ==
    /\ logline.event = "RemoveUnlink"
    /\ RemoveUnlink(tid)
    /\ ValidateUnlink(logline)

\* --- Other Events ---

TraceGet(tid, logline) ==
    /\ logline.event = "Get"
    /\ Get(tid, logline.key)

TraceReleaseEntry(tid, logline) ==
    /\ logline.event = "ReleaseEntry"
    /\ ReleaseEntry(tid)
    /\ ValidateRelease(logline)

(* ====================================================================== *)
(* Event Dispatch                                                          *)
(* ====================================================================== *)

MatchEvent(tid, logline) ==
    \/ TraceInsertBegin(tid, logline)
    \/ TraceInsertCAS(tid, logline)
    \/ TraceInsertBuildLevel(tid, logline)
    \/ TraceRemoveBegin(tid, logline)
    \/ TraceRemoveMarkTower(tid, logline)
    \/ TraceRemoveUnlink(tid, logline)
    \/ TraceGet(tid, logline)
    \/ TraceReleaseEntry(tid, logline)

(* ====================================================================== *)
(* Silent Actions                                                          *)
(* ====================================================================== *)

\* HelpUnlink can fire between traced events (triggered by search side effects).
\* Tightly constrained: only fire if a marked node has a predecessor.
SilentHelpUnlink ==
    /\ ThreadsWithEvents /= {}
    /\ \E n \in NodePool, l \in Level : HelpUnlink(n, l)
    /\ UNCHANGED tracePC

(* ====================================================================== *)
(* Trace Init and Next                                                     *)
(* ====================================================================== *)

TraceInit ==
    /\ Init
    /\ tracePC = [tid \in TraceThreads |-> 1]

TraceNext ==
    \* Normal event consumption with timebox ordering
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            LET logline == traces[tid][tracePC[tid]] IN
            /\ MatchEvent(tid, logline)
            /\ AdvancePC(tid)
    \* Silent actions (don't advance any cursor)
    \/ SilentHelpUnlink
    \* Stuttering: always allowed (dead-end interleavings are expected in Category B)
    \/ UNCHANGED allTraceVars

TraceSpec == TraceInit /\ [][TraceNext]_allTraceVars

(* ====================================================================== *)
(* Trace Completion                                                        *)
(* ====================================================================== *)

\* All events consumed = success
TraceFullyConsumed == ThreadsWithEvents = {}

\* Inverted invariant for Category B: EXPECTED to be violated.
\* Violation = trace was fully consumed (success).
\* No violation = no valid interleaving found (failure).
TraceIncomplete == ThreadsWithEvents /= {}

\* Temporal property (requires fairness, not used for Category B)
TraceMatched == <>(ThreadsWithEvents = {})

====
