---- MODULE Trace ----
\* Trace validation spec for crossbeam-epoch.
\* Replays implementation traces against the base spec to verify consistency.
\*
\* Trace format: NDJSON with events from instrumented crossbeam-epoch.
\* Each event has: { "event": "...", "thread": "...", ... }

EXTENDS base, Json, IOUtils, Sequences, TLC, Naturals

\* ============================================================================
\* Trace Loading
\* ============================================================================

\* Trace file path — override via IOEnv.JSON for per-run selection
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load and filter trace events
RawLog == ndJsonDeserialize(JsonFile)

\* Filter to only EBR-related events (exclude internal debug events)
TraceLog == SelectSeq(RawLog, LAMBDA e : "event" \in DOMAIN e)

\* ============================================================================
\* Trace Cursor
\* ============================================================================

VARIABLES
    l       \* Trace cursor: index into TraceLog (1..Len(TraceLog)+1)

traceVars == <<l>>
traceAllVars == <<allVars, traceVars>>

\* Current log line
logline == TraceLog[l]

\* Whether we've consumed the entire trace
TraceFinished == l > Len(TraceLog)

\* ============================================================================
\* Thread/Node Mapping
\* ============================================================================

\* Thread and Node constants are strings matching trace output ("T1", "T2", ...).
\* No mapping needed — trace IDs are used directly as spec constants.

\* Helper: get spec thread from trace event
EventThread == logline.thread

\* Helper: get spec node from trace event
EventNode ==
    IF "node" \in DOMAIN logline
    THEN logline.node
    ELSE Nil

\* ============================================================================
\* Event Predicates
\* ============================================================================

IsEvent(name) == logline.event = name

IsThreadEvent(name, t) ==
    /\ logline.event = name
    /\ EventThread = t

\* ============================================================================
\* Post-State Validation
\* ============================================================================

\* Strong validation: check all epoch state fields
ValidateEpochState(t) ==
    /\ ("globalEpoch" \in DOMAIN logline) =>
        globalEpoch' = logline.globalEpoch
    /\ ("localEpoch" \in DOMAIN logline) =>
        localEpoch'[t] = logline.localEpoch
    /\ ("pinned" \in DOMAIN logline) =>
        pinned'[t] = logline.pinned
    /\ ("guardCount" \in DOMAIN logline) =>
        guardCount'[t] = logline.guardCount

\* Weak validation: check only what the trace captures
ValidateWeakState(t) ==
    /\ ("pinned" \in DOMAIN logline) =>
        pinned'[t] = logline.pinned

\* Queue state validation
ValidateQueueState ==
    /\ ("qHead" \in DOMAIN logline) =>
        qHead' = logline.qHead
    /\ ("qTail" \in DOMAIN logline) =>
        qTail' = logline.qTail

\* ============================================================================
\* Action Wrappers
\* ============================================================================

\* --- TraceReadGlobalForPin ---
TraceReadGlobalForPin ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("ReadGlobalForPin", t)
        /\ ReadGlobalForPin(t)
        /\ ValidateEpochState(t)
        /\ l' = l + 1

\* --- TraceCompletePin ---
TraceCompletePin ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("CompletePin", t)
        /\ CompletePin(t)
        /\ ValidateEpochState(t)
        /\ l' = l + 1

\* --- TraceNestedPin ---
TraceNestedPin ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("NestedPin", t)
        /\ NestedPin(t)
        /\ ValidateEpochState(t)
        /\ l' = l + 1

\* --- TraceUnpin ---
TraceUnpin ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("Unpin", t)
        /\ Unpin(t)
        /\ ValidateEpochState(t)
        /\ l' = l + 1

\* --- TraceScanForAdvance ---
TraceScanForAdvance ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("ScanForAdvance", t)
        /\ ScanForAdvance(t)
        /\ ValidateWeakState(t)
        /\ l' = l + 1

\* --- TraceStoreAdvancedEpoch ---
TraceStoreAdvancedEpoch ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("StoreAdvancedEpoch", t)
        /\ StoreAdvancedEpoch(t)
        /\ ValidateEpochState(t)
        /\ l' = l + 1

\* --- TracePushLocalBag ---
TracePushLocalBag ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("PushLocalBag", t)
        /\ PushLocalBag(t)
        /\ ValidateWeakState(t)
        /\ l' = l + 1

\* --- TraceCollectExpiredBag ---
TraceCollectExpiredBag ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("CollectExpiredBag", t)
        /\ CollectExpiredBag(t)
        /\ ValidateWeakState(t)
        /\ l' = l + 1

\* --- TraceQueueLink ---
\* Push step 1: link new node into queue (CAS next pointer)
\* The implementation's push_internal does link + tail advance atomically,
\* but the trace event maps to the CAS that links the node.
TraceQueueLink ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("QueueLink", t)
        /\ LET n == EventNode
           IN
           /\ QueueLink(t, n)
           /\ ValidateQueueState
        /\ l' = l + 1

\* --- TraceQueueAdvanceTail ---
\* Push step 2: advance lagging tail pointer
TraceQueueAdvanceTail ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("QueueAdvanceTail", t)
        /\ QueueAdvanceTail(t)
        /\ ValidateQueueState
        /\ l' = l + 1

\* --- TraceQueuePop ---
TraceQueuePop ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("QueuePop", t)
        /\ QueuePop(t)
        /\ ValidateQueueState
        /\ l' = l + 1

\* --- TraceAccessNode ---
TraceAccessNode ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("AccessNode", t)
        /\ LET n == EventNode
           IN AccessNode(t, n)
        /\ l' = l + 1

\* --- TraceReleaseHandle ---
TraceReleaseHandle ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("ReleaseHandle", t)
        /\ ReleaseHandle(t)
        /\ ValidateWeakState(t)
        /\ l' = l + 1

\* --- TraceFinalize ---
TraceFinalize ==
    /\ ~TraceFinished
    /\ \E t \in Thread :
        /\ IsThreadEvent("Finalize", t)
        /\ Finalize(t)
        /\ l' = l + 1

\* ============================================================================
\* Silent Actions
\* ============================================================================

\* Silent actions fire base actions without consuming a trace event.
\* They handle implementation state changes that aren't traced.
\* CONSTRAINT: must be tightly bounded to prevent state explosion.

\* --- SilentCompletePin ---
\* The instrumentation may emit a single "Pin" event for both phases.
\* This silent action completes the pin when the next event expects pinned state.
SilentCompletePin ==
    /\ l <= Len(TraceLog)
    /\ \E t \in Thread :
        /\ pinPhase[t] = "readEpoch"       \* Mid-pin, need to complete
        /\ CompletePin(t)
    /\ UNCHANGED l

\* --- SilentScanForAdvance ---
\* TryAdvance may be called internally during collect; not always traced.
SilentScanForAdvance ==
    /\ l <= Len(TraceLog)
    /\ \E t \in Thread :
        /\ pinned[t]
        /\ advancePhase[t] = "idle"
        /\ ScanForAdvance(t)
    /\ UNCHANGED l

\* --- SilentStoreAdvancedEpoch ---
\* Store phase of try_advance may not be separately traced.
SilentStoreAdvancedEpoch ==
    /\ l <= Len(TraceLog)
    /\ \E t \in Thread :
        /\ advancePhase[t] = "scanned"
        /\ StoreAdvancedEpoch(t)
    /\ UNCHANGED l

\* --- SilentPushLocalBag ---
\* Bag push happens transparently when bag fills up during defer.
SilentPushLocalBag ==
    /\ l <= Len(TraceLog)
    /\ \E t \in Thread :
        /\ pinned[t]
        /\ localBag[t] /= {}
        /\ PushLocalBag(t)
    /\ UNCHANGED l

\* --- SilentCollectExpiredBag ---
\* Collection happens during pin() every PINNINGS_BETWEEN_COLLECT pins.
SilentCollectExpiredBag ==
    /\ l <= Len(TraceLog)
    /\ \E t \in Thread :
        /\ pinned[t]
        /\ \E entry \in sealedBags : IsExpired(entry)
        /\ CollectExpiredBag(t)
    /\ UNCHANGED l

\* --- SilentQueueAdvanceTail ---
\* Tail advancement happens as part of push or as helping; may not be traced.
SilentQueueAdvanceTail ==
    /\ l <= Len(TraceLog)
    /\ \E t \in Thread :
        /\ pinned[t]
        /\ qNext[qTail] /= Nil
        /\ QueueAdvanceTail(t)
    /\ UNCHANGED l

\* --- SilentAccessNode ---
\* Node accesses are ghost events, may not be in the trace.
SilentAccessNode ==
    /\ l <= Len(TraceLog)
    /\ \E t \in Thread :
        /\ pinned[t]
        /\ \E n \in Node :
            /\ n \notin collected
            /\ AccessNode(t, n)
    /\ UNCHANGED l

\* ============================================================================
\* Trace Init and Next
\* ============================================================================

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \* Event-driven wrappers
    \/ TraceReadGlobalForPin
    \/ TraceCompletePin
    \/ TraceNestedPin
    \/ TraceUnpin
    \/ TraceScanForAdvance
    \/ TraceStoreAdvancedEpoch
    \/ TracePushLocalBag
    \/ TraceCollectExpiredBag
    \/ TraceQueueLink
    \/ TraceQueueAdvanceTail
    \/ TraceQueuePop
    \/ TraceAccessNode
    \/ TraceReleaseHandle
    \/ TraceFinalize
    \* Silent actions
    \/ SilentCompletePin
    \/ SilentScanForAdvance
    \/ SilentStoreAdvancedEpoch
    \/ SilentPushLocalBag
    \/ SilentCollectExpiredBag
    \/ SilentQueueAdvanceTail
    \/ SilentAccessNode

TraceSpec == TraceInit /\ [][TraceNext]_traceAllVars

\* ============================================================================
\* Trace Validation Properties
\* ============================================================================

\* The trace is fully consumed (checked as a temporal property)
\* If validation succeeds, l reaches Len(TraceLog) + 1.
\* Deadlock at l < Len(TraceLog) + 1 means the spec cannot match event l.
TraceMatched == <>(l = Len(TraceLog) + 1)

\* All base invariants should hold during trace replay
TraceInvariant ==
    /\ TypeOK
    /\ SafeReclamation
    /\ PinnedConsistency

====
