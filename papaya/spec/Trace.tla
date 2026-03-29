------------------------------- MODULE Trace --------------------------------
(* Trace validation spec for papaya lock-free HashMap.
 *
 * Category B (concurrent/lock-free): Uses per-thread timebox traces
 * with [start, end] intervals. TLC explores viable orderings via
 * ViablePIDs partial order constraint.
 *
 * Trace format: preprocessed JSON with per-thread arrays:
 *   { "threads": { "tid": [ {event, start, end, state...}, ... ] } }
 *)
EXTENDS base, TLC, IOUtils, Json, Sequences

(* ================================================================
 * TRACE LOADING
 * ================================================================ *)

\* Trace file path: override via IOEnv.JSON or use default
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load the preprocessed trace (JSON format)
RawTrace == JsonDeserialize(JsonFile)

\* Per-thread trace arrays: traces[tid] = sequence of events
traces == RawTrace.threads

\* Set of thread IDs present in the trace
TraceThreads == DOMAIN traces

(* ================================================================
 * PER-THREAD CURSOR
 * ================================================================ *)

VARIABLE pc  \* pc[tid] \in 1..Len(traces[tid]) + 1

traceVars == <<vars, pc>>

(* ================================================================
 * TIMEBOX HELPERS
 * ================================================================ *)

\* Threads that still have unconsumed events
ThreadsWithEvents ==
    { tid \in TraceThreads : pc[tid] <= Len(traces[tid]) }

\* Partial order: thread can step iff no other thread has a pending
\* event that completed before this thread's next event started.
\* If intervals overlap, both are viable — TLC explores both orderings.
ViablePIDs ==
    { tid \in ThreadsWithEvents :
        ~ \E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pc[tid2]].end < traces[tid][pc[tid]].start }

(* ================================================================
 * STATE MAPPING
 * ================================================================ *)

\* Map thread ID string from trace to Thread constant
ThreadMap(tidStr) == tidStr  \* Identity for now; override in cfg if needed

\* Map key string from trace to Key constant
KeyMap(kStr) == kStr

\* Map value string from trace to Value constant
ValueMap(vStr) == vStr

(* ================================================================
 * EVENT MATCHING
 * ================================================================ *)

\* Post-state validation: check spec state matches trace snapshot
ValidatePostState(tid, logline) ==
    \* Validate fields present in the logline against spec state
    TRUE  \* Placeholder — filled in during convergence with actual field checks

\* Dispatch by event name.
\* Uses trace-provided table/slot to constrain search (eliminates existential explosion).
MatchEvent(tid, logline) ==
    LET event == logline.event IN

    \* --- Insert CAS (Phase 1) ---
    IF event = "insert_cas" THEN
        /\ InsertCASEntry(ThreadMap(tid), KeyMap(logline.key),
                          ValueMap(logline.value), logline.table, logline.slot)
        /\ ValidatePostState(tid, logline)

    \* --- Insert Meta Store (Phase 2) ---
    ELSE IF event = "insert_meta" THEN
        /\ InsertStoreMeta(ThreadMap(tid), logline.table, logline.slot)
        /\ ValidatePostState(tid, logline)

    \* --- Insert Update (replace existing) ---
    ELSE IF event = "insert_update" THEN
        /\ InsertUpdate(ThreadMap(tid), KeyMap(logline.key),
                        ValueMap(logline.value), logline.table, logline.slot)
        /\ ValidatePostState(tid, logline)

    \* --- Remove ---
    ELSE IF event = "remove" THEN
        /\ Remove(ThreadMap(tid), KeyMap(logline.key), logline.table, logline.slot)
        /\ ValidatePostState(tid, logline)

    \* --- Copy Mark Copying ---
    ELSE IF event = "copy_mark_copying" THEN
        /\ CopyMarkCopying(ThreadMap(tid), logline.table, logline.slot)
        /\ ValidatePostState(tid, logline)

    \* --- Copy Insert To Next ---
    ELSE IF event = "copy_insert" THEN
        /\ CopyInsertToNext(ThreadMap(tid), logline.src_table, logline.src_slot,
                            logline.dst_table, logline.dst_slot)
        /\ ValidatePostState(tid, logline)

    \* --- Copy Mark Copied ---
    ELSE IF event = "copy_mark_copied" THEN
        /\ CopyMarkCopied(ThreadMap(tid), logline.table, logline.slot)
        /\ ValidatePostState(tid, logline)

    \* --- Alloc Next Table ---
    ELSE IF event = "alloc_next" THEN
        /\ AllocNextTable(ThreadMap(tid), logline.table)
        /\ nextTable'[logline.table] = logline.next_table
        /\ ValidatePostState(tid, logline)

    \* --- Try Promote ---
    ELSE IF event = "try_promote" THEN
        /\ TryPromote(ThreadMap(tid), logline.old_root)
        /\ ValidatePostState(tid, logline)

    \* --- Abort Resize ---
    ELSE IF event = "abort_resize" THEN
        /\ AbortResize(ThreadMap(tid), logline.src_table, logline.aborted_table)
        /\ ValidatePostState(tid, logline)

    \* --- Init Table ---
    ELSE IF event = "init_table" THEN
        /\ InitTable(ThreadMap(tid))
        /\ rootTable' = logline.table
        /\ ValidatePostState(tid, logline)

    \* --- Park Thread ---
    ELSE IF event = "park" THEN
        /\ ParkThread(ThreadMap(tid), logline.table)
        /\ ValidatePostState(tid, logline)

    ELSE FALSE  \* Unknown event

(* ================================================================
 * SILENT ACTIONS
 * Tightly constrained: only fire when needed for next trace event
 * ================================================================ *)

\* Silent batch null-slot copy: processes ALL null/tombstone slots for a table
\* in one action. Needed for copiedCount to reach TableLen for promotion.
\* Fires once before try_promote — avoids per-slot combinatorial explosion.
SilentBatchCopyNullSlots ==
    /\ ThreadsWithEvents /= {}
    /\ \E tid \in ViablePIDs :
        LET logline == traces[tid][pc[tid]] IN
        /\ logline.event = "try_promote"
        /\ \E srcT \in 1..MaxTables :
            /\ nextTable[srcT] /= NULL
            /\ resizeStatus[nextTable[srcT]] /= ABORTED
            /\ LET nt == nextTable[srcT]
                   nullSlots == {s \in Slot :
                       /\ tableEntry[srcT][s] = NULL
                       /\ tableMeta[srcT][s] /= META_TOMBSTONE}
               IN
                /\ nullSlots /= {}
                /\ tableMeta' = [tableMeta EXCEPT ![srcT] =
                    [s \in Slot |-> IF s \in nullSlots
                                    THEN META_TOMBSTONE
                                    ELSE tableMeta[srcT][s]]]
                /\ claimCount' = [claimCount EXCEPT ![nt] =
                    claimCount[nt] + Cardinality(nullSlots)]
                /\ copiedCount' = [copiedCount EXCEPT ![nt] =
                    copiedCount[nt] + Cardinality(nullSlots)]
                /\ UNCHANGED <<rootTable, tableEntry, nextTable, resizeStatus,
                                insertVars, parkerVars, reclaimVars, logicalVars>>
    /\ UNCHANGED pc

SilentActions ==
    \/ SilentBatchCopyNullSlots

(* ================================================================
 * TRACE INIT / NEXT
 * ================================================================ *)

TraceInit ==
    /\ Init
    /\ pc = [tid \in TraceThreads |-> 1]

TraceNext ==
    \* Event matching: pick a viable thread, match its event, advance cursor
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            LET logline == traces[tid][pc[tid]] IN
            /\ MatchEvent(tid, logline)
            /\ pc' = [pc EXCEPT ![tid] = pc[tid] + 1]
    \* Silent actions: fire without advancing any cursor
    \/ /\ ThreadsWithEvents /= {}
       /\ SilentActions
       /\ UNCHANGED pc
    \* Completion stutter: all events consumed, allow stuttering to avoid deadlock
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED <<vars, pc>>

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

(* ================================================================
 * COMPLETION CHECK
 * ================================================================ *)

\* Temporal property: all trace events must be consumed
TraceFullyConsumed == <>(ThreadsWithEvents = {})

============================================================================
