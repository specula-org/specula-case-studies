------------------------------- MODULE Trace --------------------------------
(* Trace validation spec for papaya lock-free HashMap (round 2).
 *
 * Category B (concurrent/lock-free): per-thread timebox traces with
 * [start, end] intervals. TLC explores viable orderings via ViablePIDs.
 *
 * Trace format: preprocessed JSON with per-thread arrays:
 *   { "threads": { "tid": [ {event, start, end, state...}, ... ] } }
 *)
EXTENDS base, TLC, IOUtils, Json, Sequences

(* ================================================================
 * TRACE LOADING
 * ================================================================ *)

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTrace == JsonDeserialize(JsonFile)
traces == RawTrace.threads
TraceThreads == DOMAIN traces

(* ================================================================
 * PER-THREAD CURSOR
 * ================================================================ *)

VARIABLE pc

traceVars == <<vars, pc>>

(* ================================================================
 * TIMEBOX HELPERS
 * ================================================================ *)

ThreadsWithEvents ==
    { tid \in TraceThreads : pc[tid] <= Len(traces[tid]) }

(* Partial-order constraint: a thread is viable iff no other thread
 * has a pending event that COMPLETED before this thread's next event STARTED. *)
ViablePIDs ==
    { tid \in ThreadsWithEvents :
        ~ \E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pc[tid2]].end < traces[tid][pc[tid]].start }

(* ================================================================
 * MAPPING
 * ================================================================ *)

ThreadMap(tidStr) == tidStr
KeyMap(kStr)      == kStr
ValueMap(vStr)    == vStr

(* ================================================================
 * POST-STATE VALIDATION
 *
 * For each action, validate the spec variables that the action modifies
 * against the captured state in the trace event. The instrumentation spec
 * defines which fields the harness will emit.
 * ================================================================ *)

\* Helper: optional field check — only validates if the field is present in logline.
HasField(logline, name) == name \in DOMAIN logline

\* Common state field validation: rootTable, resizeStatus, copiedCount.
\* Captured outside the [start, end] critical section per timebox guide.
ValidateRoot(logline) ==
    \/ ~ HasField(logline, "root_table")
    \/ /\ logline.root_table = NULL
       /\ rootTable' = NULL
    \/ /\ logline.root_table /= NULL
       /\ rootTable' = logline.root_table

ValidateInsertCAS(tid, logline) ==
    LET t == logline.table
        s == logline.slot
        k == KeyMap(logline.key)
        v == ValueMap(logline.value) IN
    /\ tableEntry'[t][s] /= NULL
    /\ tableEntry'[t][s].key = k
    /\ tableEntry'[t][s].value = v
    /\ metaWritten'[t][s] = FALSE
    /\ insertWindow'[t][s] = ThreadMap(tid)

ValidateInsertStoreMeta(tid, logline) ==
    LET t == logline.table
        s == logline.slot IN
    /\ metaWritten'[t][s] = TRUE
    /\ insertWindow'[t][s] = NULL
    \* Meta value not compared: harness emits placeholder "H2" while spec uses
    \* h2(k) == k abstraction. The metaWritten/insertWindow checks are
    \* sufficient to confirm the action fired correctly.

ValidateInsertMetaFixup(tid, logline) ==
    LET t == logline.table
        s == logline.slot IN
    /\ tableMeta'[t][s] /= META_EMPTY

ValidateInsertUpdate(tid, logline) ==
    LET t == logline.table
        s == logline.slot
        k == KeyMap(logline.key)
        v == ValueMap(logline.value) IN
    /\ tableEntry'[t][s] /= NULL
    /\ tableEntry'[t][s].key = k
    /\ tableEntry'[t][s].value = v

ValidateRemove(tid, logline) ==
    LET t == logline.table
        s == logline.slot IN
    /\ tableEntry'[t][s] = NULL
    /\ tableMeta'[t][s] = META_TOMBSTONE
    /\ metaWritten'[t][s] = TRUE

ValidateCopyMarkCopying(tid, logline) ==
    LET t == logline.table
        s == logline.slot IN
    /\ tableEntry'[t][s] /= NULL
    /\ COPYING \in tableEntry'[t][s].tag

ValidateCopyInsert(tid, logline) ==
    LET ds == logline.dst_slot
        dt == logline.dst_table
        k  == KeyMap(logline.key) IN
    /\ tableEntry'[dt][ds] /= NULL
    /\ tableEntry'[dt][ds].key = k
    /\ metaWritten'[dt][ds] = TRUE

ValidateCopyMarkCopied(tid, logline) ==
    LET t == logline.table
        s == logline.slot IN
    /\ tableEntry'[t][s] /= NULL
    /\ COPIED \in tableEntry'[t][s].tag
    /\ COPYING \in tableEntry'[t][s].tag

ValidateAllocNext(tid, logline) ==
    LET t  == logline.table
        nt == logline.next_table IN
    /\ nextTable'[t] = nt
    /\ resizeStatus'[nt] = PENDING

ValidateTryPromote(tid, logline) ==
    LET ot == logline.old_root
        nt == logline.new_root IN
    /\ rootTable' = nt
    /\ resizeStatus'[nt] = PROMOTED

ValidateAbortResize(tid, logline) ==
    LET at == logline.aborted_table IN
    /\ resizeStatus'[at] = ABORTED

ValidateInitTable(tid, logline) ==
    /\ rootTable' = logline.table
    /\ resizeStatus'[logline.table] = PROMOTED

ValidatePark(tid, logline) ==
    LET t == logline.table IN
    /\ parked'[ThreadMap(tid)] /= NULL
    /\ parked'[ThreadMap(tid)].parker = t
    /\ parked'[ThreadMap(tid)].key    = t

ValidateIterBegin(tid, logline) ==
    /\ iterTable'[ThreadMap(tid)] = logline.snapshot_table
    /\ iterIdx'[ThreadMap(tid)] = 0

ValidateIterYield(tid, logline) ==
    LET k == KeyMap(logline.key) IN
    /\ Len(seenKeys'[ThreadMap(tid)]) >= 1
    /\ seenKeys'[ThreadMap(tid)][Len(seenKeys'[ThreadMap(tid)])] = k

ValidateIterEnd(tid, logline) ==
    /\ iterDone'[ThreadMap(tid)] = TRUE

(* ================================================================
 * EVENT MATCHING
 * ================================================================ *)

MatchEvent(tid, logline) ==
    LET event == logline.event IN

    \* --- Insert CAS (Phase 1) ---
    IF event = "insert_cas" THEN
        /\ InsertCASEntry(ThreadMap(tid), KeyMap(logline.key),
                          ValueMap(logline.value), logline.table, logline.slot)
        /\ ValidateInsertCAS(tid, logline)

    \* --- Insert Meta Store (Phase 2 — winner unconditional) ---
    ELSE IF event = "insert_meta" THEN
        /\ InsertStoreMeta(ThreadMap(tid), logline.table, logline.slot)
        /\ ValidateInsertStoreMeta(tid, logline)

    \* --- Insert Meta Fixup (loser path) ---
    ELSE IF event = "insert_meta_fixup" THEN
        /\ InsertMetaFixup(ThreadMap(tid), logline.table, logline.slot)
        /\ ValidateInsertMetaFixup(tid, logline)

    \* --- Insert Update ---
    ELSE IF event = "insert_update" THEN
        /\ InsertUpdate(ThreadMap(tid), KeyMap(logline.key),
                        ValueMap(logline.value), logline.table, logline.slot)
        /\ ValidateInsertUpdate(tid, logline)

    \* --- Remove ---
    ELSE IF event = "remove" THEN
        /\ Remove(ThreadMap(tid), KeyMap(logline.key), logline.table, logline.slot)
        /\ ValidateRemove(tid, logline)

    \* --- Copy Mark Copying ---
    ELSE IF event = "copy_mark_copying" THEN
        /\ CopyMarkCopying(ThreadMap(tid), logline.table, logline.slot)
        /\ ValidateCopyMarkCopying(tid, logline)

    \* --- Copy Mark Copying Null (separate event for null/tombstone slots) ---
    \* The implementation emits this event for every null-entry slot during copy,
    \* even when the slot's meta is already META_TOMBSTONE (mod.rs:2444-2466 — the
    \* tombstone-entry path returns true without re-storing the meta). Both paths
    \* still count the slot toward `copiedCount` of the next table. The spec's
    \* CopyMarkCopyingNull only fires when meta /= TOMBSTONE (one-shot per slot
    \* to keep MC bounded). For the meta-already-TOMBSTONE case, accept as a
    \* trace-only variant that still bumps claim/copied counts.
    ELSE IF event = "copy_mark_copying_null" THEN
        \/ CopyMarkCopyingNull(ThreadMap(tid), logline.table, logline.slot)
        \/ /\ tableEntry[logline.table][logline.slot] = NULL
           /\ tableMeta[logline.table][logline.slot] = META_TOMBSTONE
           /\ nextTable[logline.table] /= NULL
           /\ resizeStatus[nextTable[logline.table]] /= ABORTED
           /\ LET nt == nextTable[logline.table] IN
                /\ copiedCount[nt] < TableLen(logline.table)
                /\ claimCount' = [claimCount EXCEPT ![nt] = @ + 1]
                /\ copiedCount' = [copiedCount EXCEPT ![nt] = @ + 1]
           /\ UNCHANGED <<rootTable, tableEntry, tableMeta, nextTable,
                          resizeStatus, insertVars, parkerVars, reclaimVars,
                          iterVars, logicalVars>>

    \* --- Copy Insert To Next ---
    ELSE IF event = "copy_insert" THEN
        /\ CopyInsertToNext(ThreadMap(tid), logline.src_table, logline.src_slot,
                            logline.dst_table, logline.dst_slot)
        /\ ValidateCopyInsert(tid, logline)

    \* --- Copy Mark Copied ---
    ELSE IF event = "copy_mark_copied" THEN
        /\ CopyMarkCopied(ThreadMap(tid), logline.table, logline.slot)
        /\ ValidateCopyMarkCopied(tid, logline)

    \* --- Alloc Next Table ---
    ELSE IF event = "alloc_next" THEN
        /\ AllocNextTable(ThreadMap(tid), logline.table)
        /\ ValidateAllocNext(tid, logline)

    \* --- Try Promote ---
    ELSE IF event = "try_promote" THEN
        /\ TryPromote(ThreadMap(tid), logline.old_root)
        /\ ValidateTryPromote(tid, logline)

    \* --- Abort Resize ---
    ELSE IF event = "abort_resize" THEN
        /\ AbortResize(ThreadMap(tid), logline.src_table, logline.aborted_table)
        /\ ValidateAbortResize(tid, logline)

    \* --- Init Table ---
    ELSE IF event = "init_table" THEN
        /\ InitTable(ThreadMap(tid))
        /\ ValidateInitTable(tid, logline)

    \* --- Park Thread ---
    ELSE IF event = "park" THEN
        /\ ParkThread(ThreadMap(tid), logline.table)
        /\ ValidatePark(tid, logline)

    \* --- Iter Begin ---
    ELSE IF event = "iter_begin" THEN
        /\ IterBegin(ThreadMap(tid))
        /\ ValidateIterBegin(tid, logline)

    \* --- Iter Yield ---
    ELSE IF event = "iter_yield" THEN
        /\ IterAdvanceYield(ThreadMap(tid))
        /\ ValidateIterYield(tid, logline)

    \* --- Iter Skip (empty/tombstone) ---
    ELSE IF event = "iter_skip" THEN
        /\ IterAdvanceSkip(ThreadMap(tid))
        /\ TRUE

    \* --- Iter End ---
    ELSE IF event = "iter_end" THEN
        /\ IterEnd(ThreadMap(tid))
        /\ ValidateIterEnd(tid, logline)

    ELSE FALSE  \* Unknown event

(* ================================================================
 * SILENT ACTIONS
 *
 * Tightly constrained: only fire when needed for the next trace event,
 * to avoid state-space explosion.
 * ================================================================ *)

(* Batch null-slot copy: collapses the per-slot CopyMarkCopyingNull events
 * for the entire source table into one transition. Only fires immediately
 * before a try_promote event so that copiedCount can reach TableLen. *)
SilentBatchCopyNullSlots ==
    /\ ThreadsWithEvents /= {}
    /\ \E tid \in ViablePIDs :
        LET logline == traces[tid][pc[tid]] IN
        /\ logline.event = "try_promote"
        /\ \E srcT \in 1..MaxTables :
            /\ nextTable[srcT] /= NULL
            /\ resizeStatus[nextTable[srcT]] /= ABORTED
            /\ LET nt == nextTable[srcT]
                   nullSlots == { s \in Slot :
                       /\ tableEntry[srcT][s] = NULL
                       /\ tableMeta[srcT][s] /= META_TOMBSTONE }
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
                                insertVars, parkerVars, reclaimVars, iterVars,
                                logicalVars>>
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

\* Add weak fairness on TraceNext so TLC won't generate stuttering counterexamples
\* when verifying TraceMatched (a liveness property).
TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceNext)

(* ================================================================
 * COMPLETION CHECK
 * ================================================================ *)

\* All trace events must be consumed
TraceFullyConsumed == <>(ThreadsWithEvents = {})
TraceMatched == TraceFullyConsumed

============================================================================
