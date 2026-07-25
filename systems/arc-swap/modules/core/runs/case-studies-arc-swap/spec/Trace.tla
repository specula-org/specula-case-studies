---- MODULE Trace ----
\* ===================================================================================
\* Trace Validation Spec for arc-swap Debt-Based Reader Tracking
\* ===================================================================================
\*
\* Replays implementation traces against the base spec to verify consistency.
\* Each trace event is matched to a base spec action, and the post-state is
\* validated against the recorded state in the trace.

EXTENDS base, TLCExt, Toolbox, IOUtils, Json, Sequences, Naturals

\* ===================================================================================
\* Trace Loading
\* ===================================================================================

\* Trace file location (override via IOEnv.JSON for per-run selection)
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load and parse trace
RawTrace == ndJsonDeserialize(JsonFile)

\* Filter to only arc-swap debt protocol events
TraceLog == SelectSeq(RawTrace, LAMBDA e : "event" \in DOMAIN e)

\* ===================================================================================
\* Trace Cursor
\* ===================================================================================

VARIABLES l   \* Trace cursor: current position in TraceLog

traceVars == <<l>>
allVars == <<vars, l>>

\* ===================================================================================
\* Event Matching Helpers
\* ===================================================================================

\* Current log line
logline == TraceLog[l]

\* Check if current event matches a given name
IsEvent(name) == logline.event = name

\* Check if event is for a specific thread
IsThreadEvent(name, t) ==
    /\ logline.event = name
    /\ logline.thread = t

\* Advance cursor
AdvanceCursor == l' = l + 1

\* End of trace
TraceFinished == l > Len(TraceLog)

\* ===================================================================================
\* Thread/Pointer Mapping
\* ===================================================================================

\* Identity mapping: harness emits IDs matching spec constant names.
\* Constants must be defined as strings in the cfg (not model values).
MapThread(tid) == tid

MapPtr(addr) ==
    IF addr = "null" THEN NullPtr
    ELSE addr

\* ===================================================================================
\* Post-State Validation
\* ===================================================================================

\* Strong validation: check all reader state fields (post-state)
ValidateReaderState(t) ==
    /\ rPC'[t] = logline.state.rPC
    /\ rPtr'[t] = MapPtr(logline.state.rPtr)
    /\ rHasDebt'[t] = logline.state.rHasDebt

\* Weak validation: check only program counter (post-state)
ValidateReaderPC(t) ==
    /\ rPC'[t] = logline.state.rPC

\* Writer state validation (post-state)
ValidateWriterState(t) ==
    /\ wPC'[t] = logline.state.wPC

\* Storage validation (post-state)
ValidateStorage ==
    /\ storagePtr' = MapPtr(logline.state.storagePtr)

\* ===================================================================================
\* Trace Action Wrappers
\* ===================================================================================

\* --- Reader Fast Path ---

TraceReaderAcquireFast ==
    /\ IsEvent("ReaderAcquireFast")
    /\ LET t == MapThread(logline.thread)
       IN /\ ReaderAcquireFast(t)
          /\ ValidateReaderPC(t)
    /\ AdvanceCursor

TraceReaderConfirmFast ==
    /\ IsEvent("ReaderConfirmFast")
    /\ LET t == MapThread(logline.thread)
       IN /\ ReaderConfirmFast(t)
          /\ ValidateReaderPC(t)
    /\ AdvanceCursor

TraceReaderResolveFast ==
    /\ IsEvent("ReaderResolveFast")
    /\ LET t == MapThread(logline.thread)
       IN /\ ReaderResolveFast(t)
          /\ ValidateReaderPC(t)
    /\ AdvanceCursor

\* --- Reader Fallback ---

TraceReaderFallbackLoad ==
    /\ IsEvent("ReaderFallbackLoad")
    /\ LET t == MapThread(logline.thread)
       IN /\ ReaderFallbackLoad(t)
          /\ ValidateReaderPC(t)
    /\ AdvanceCursor

\* --- Reader Drop ---

TraceReaderDropGuard ==
    /\ IsEvent("ReaderDropGuard")
    /\ LET t == MapThread(logline.thread)
       IN /\ ReaderDropGuard(t)
          /\ ValidateReaderPC(t)
    /\ AdvanceCursor

\* --- Writer ---

TraceWriterSwap ==
    /\ IsEvent("WriterSwap")
    /\ LET t == MapThread(logline.thread)
       IN /\ WriterSwap(t)
          /\ ValidateStorage
    /\ AdvanceCursor

TraceWriterPayInit ==
    /\ IsEvent("WriterPayInit")
    /\ LET t == MapThread(logline.thread)
       IN /\ WriterPayInit(t)
          /\ ValidateWriterState(t)
    /\ AdvanceCursor

TraceWriterScanSlot ==
    /\ IsEvent("WriterScanSlot")
    /\ LET t == MapThread(logline.thread)
           slot == logline.slot
       IN /\ wPC[t] = "w_scanning"
          /\ \E target \in Thread :
              /\ <<target, slot>> \notin wScanned[t]
              /\ \/ IF debtSlot[target][slot] = wOldPtr[t]
                    THEN /\ debtSlot' = [debtSlot EXCEPT ![target][slot] = NullPtr]
                         /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ + 1]
                    ELSE UNCHANGED <<debtSlot, refCount>>
                 \/ UNCHANGED <<debtSlot, refCount>>
              /\ wScanned' = [wScanned EXCEPT ![t] = @ \cup {<<target, slot>>}]
          /\ UNCHANGED <<coreVars, ptrAlive, readerVars, wPC, wOldPtr, ptrVars, genVars>>
          /\ ValidateWriterState(t)
    /\ AdvanceCursor

\* Override: writer only scans registered nodes, not all Thread × Slot.
\* Implementation iterates the global linked list; unregistered threads are skipped.
TraceWriterPayDone ==
    /\ IsEvent("WriterPayDone")
    /\ LET t == MapThread(logline.thread)
       IN /\ wPC[t] = "w_scanning"
          /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ - 1]
          /\ wPC' = [wPC EXCEPT ![t] = "w_returning"]
          /\ UNCHANGED <<coreVars, debtVars, ptrAlive, readerVars, wOldPtr, wScanned,
                         ptrVars, genVars>>
          /\ ValidateWriterState(t)
    /\ AdvanceCursor

TraceWriterReturn ==
    /\ IsEvent("WriterReturn")
    /\ LET t == MapThread(logline.thread)
       IN /\ WriterReturn(t)
          /\ ValidateWriterState(t)
    /\ AdvanceCursor

\* ===================================================================================
\* Silent Actions
\* ===================================================================================

\* Silent actions handle state transitions not captured in the trace.
\* Each is tightly constrained to prevent state space explosion.

\* Silent: CheckCooldown (may fire between any events)
SilentCheckCooldown ==
    /\ l <= Len(TraceLog)
    /\ \E target \in Thread :
        /\ nodeState[target] = NODE_COOLDOWN
        /\ activeWriters[target] = 0
        /\ CheckCooldown(target)
    /\ UNCHANGED <<l>>

\* Silent: ClaimNode (may fire when thread needs a node)
SilentClaimNode ==
    /\ l <= Len(TraceLog)
    /\ \E t \in Thread :
        /\ nodeState[t] = NODE_UNUSED
        /\ ClaimNode(t)
    /\ UNCHANGED <<l>>

\* Silent: WriterReserveNode (implicit during scan)
SilentWriterReserveNode ==
    /\ l <= Len(TraceLog)
    /\ \E t \in Thread, target \in Thread :
        /\ wPC[t] = "w_scanning"
        /\ WriterReserveNode(t, target)
    /\ UNCHANGED <<l>>

\* Silent: WriterReleaseNode (implicit after scan)
SilentWriterReleaseNode ==
    /\ l <= Len(TraceLog)
    /\ \E t \in Thread, target \in Thread :
        /\ activeWriters[target] > 0
        /\ WriterReleaseNode(t, target)
    /\ UNCHANGED <<l>>

\* ===================================================================================
\* Trace Init and Next
\* ===================================================================================

\* Derive initial constants from trace
TraceThread == {MapThread(TraceLog[i].thread) : i \in 1..Len(TraceLog)}

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    /\ l <= Len(TraceLog)
    /\ \/ TraceReaderAcquireFast
       \/ TraceReaderConfirmFast
       \/ TraceReaderResolveFast
       \/ TraceReaderFallbackLoad
       \/ TraceReaderDropGuard
       \/ TraceWriterSwap
       \/ TraceWriterPayInit
       \/ TraceWriterScanSlot
       \/ TraceWriterPayDone
       \/ TraceWriterReturn
       \* Silent actions
       \/ SilentCheckCooldown
       \/ SilentClaimNode
       \/ SilentWriterReserveNode
       \/ SilentWriterReleaseNode

TraceSpec == TraceInit /\ [][TraceNext]_allVars

\* ===================================================================================
\* Trace Validation Properties
\* ===================================================================================

\* Temporal: entire trace was consumed (checked via deadlock at end)
\* If TLC reports deadlock and l = Len(TraceLog) + 1, the trace was fully matched.
TraceMatched ==
    <>(l = Len(TraceLog) + 1)

\* The trace cursor only advances (never goes backward)
TraceCursorMonotonic ==
    [][l' >= l]_l

====
