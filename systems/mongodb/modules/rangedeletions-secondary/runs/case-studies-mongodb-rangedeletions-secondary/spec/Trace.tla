---- MODULE Trace ----
(***************************************************************************)
(* Trace validation spec for RangeDeletionsSecondaryNodes.                 *)
(*                                                                         *)
(* Category A (distributed/message-passing): Single-file linear trace.     *)
(* Traces are NDJSON files parsed from MongoDB LOGV2 structured logs.      *)
(*                                                                         *)
(* Trace format:                                                           *)
(*   Line 1: {"event": "init", "nodeRole": "SECONDARY",                   *)
(*            "trackerShardV": [v1, v2, ...],                              *)
(*            "rdPreMigShardV": [pv1, ...],                                *)
(*            "queryTracker": [t1, ...]}                                   *)
(*   Lines 2+: {"event": "<ActionName>", "rd": "rd1", ...}                *)
(*             or {"event": "<ActionName>", "query": "q1", ...}            *)
(***************************************************************************)
EXTENDS base, Sequences, SequencesExt, TLC, TLCExt, IOUtils, Json

(*====================================================================*)
(* Trace loading                                                       *)
(*====================================================================*)

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTraceLog == ndJsonDeserialize(JsonFile)

\* First line is the init config, rest are events
InitConfig == RawTraceLog[1]
TraceLog == SubSeq(RawTraceLog, 2, Len(RawTraceLog))

(*====================================================================*)
(* Cursor variable                                                     *)
(*====================================================================*)

VARIABLE l   \* Current position in TraceLog (1-indexed)

traceVars == <<vars, l>>

logline == TraceLog[l]

(*====================================================================*)
(* Identity mapping helpers                                            *)
(* Map trace strings to spec set elements                              *)
(*====================================================================*)

\* Map "rd1", "rd2", ... to elements of RangeDeletion set
\* Uses sequence indexing: RangeDeletion is ordered as a sequence
RDSeq == SetToSeq(RangeDeletion)
QuerySeq == SetToSeq(Query)

\* Find the RD element matching a trace string by index
\* Trace uses 1-based indices: "1" → first RD, "2" → second RD
MapRD(traceIdx) == RDSeq[traceIdx]
MapQuery(traceIdx) == QuerySeq[traceIdx]

(*====================================================================*)
(* Event predicates                                                    *)
(*====================================================================*)

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

(*====================================================================*)
(* Post-state validation                                               *)
(* Validates spec state matches trace state after each action.         *)
(* Strong validation: check all available fields.                      *)
(* Weak validation: check only fields present in the trace event.      *)
(*====================================================================*)

\* Validate tracker validity if present in trace event
ValidateTrackerValid ==
    ("trackerValid" \in DOMAIN logline) =>
        \A t \in Tracker :
            LET traceVal == logline.trackerValid[t] IN
            trackerValid'[t] = traceVal

\* Validate query state if present in trace event
ValidateQueryState(q) ==
    ("queryState" \in DOMAIN logline) =>
        queryState'[q] = logline.queryState

\* Validate snapshot state if present in trace event
ValidateSnapshot ==
    ("lastAppliedSnapshotSize" \in DOMAIN logline) =>
        Cardinality(lastAppliedSnapshot') = logline.lastAppliedSnapshotSize

(*====================================================================*)
(* Trace-determined initial state                                      *)
(*====================================================================*)

\* RDDocs for trace: all RDs remove all docs (matches base spec default)
TraceRDDocs == [rd \in RangeDeletion |-> Doc]

TraceInit ==
    /\ l = 1
    \* Read initial state from init config (first line of trace)
    /\ nodeRole = InitConfig.nodeRole
    /\ trackerShardV = [t \in Tracker |-> InitConfig.trackerShardV[t]]
    /\ trackerValid = [t \in Tracker |-> TRUE]
    /\ signalState = [rd \in RangeDeletion |-> "INIT"]
    /\ deleteState = [rd \in RangeDeletion |-> "INIT"]
    /\ batchState = [rd \in RangeDeletion |-> "ONGOING"]
    /\ rdRecovered = [rd \in RangeDeletion |-> FALSE]
    /\ rdPreMigShardV = [rd \in RangeDeletion |->
            InitConfig.rdPreMigShardV[CHOOSE i \in 1..Cardinality(RangeDeletion) :
                RDSeq[i] = rd]]
    /\ queryState = [q \in Query |-> "RESTORE_START"]
    /\ queryTracker = [q \in Query |->
            InitConfig.queryTracker[CHOOSE i \in 1..Cardinality(Query) :
                QuerySeq[i] = q]]
    /\ querySnapshot = [q \in Query |-> {}]
    /\ lastAppliedSnapshot = Doc

(*====================================================================*)
(* Action wrappers                                                     *)
(* Each wrapper: match event → call base action → advance cursor       *)
(*====================================================================*)

TraceOpApplierSignalUpdate ==
    /\ IsEvent("SignalUpdate")
    /\ LET rd == MapRD(logline.rd) IN
        /\ OpApplierSignalUpdate(rd)
        /\ ValidateTrackerValid
    /\ l' = l + 1

TraceOpApplierSignalCommit ==
    /\ IsEvent("SignalCommit")
    /\ LET rd == MapRD(logline.rd) IN
        OpApplierSignalCommit(rd)
    /\ l' = l + 1

TraceOpApplierDeleteUpdate ==
    /\ IsEvent("DeleteUpdate")
    /\ LET rd == MapRD(logline.rd) IN
        OpApplierDeleteUpdate(rd)
    /\ l' = l + 1

TraceOpApplierDeleteCommit ==
    /\ IsEvent("DeleteCommit")
    /\ LET rd == MapRD(logline.rd) IN
        OpApplierDeleteCommit(rd)
    /\ l' = l + 1

TraceBatchCommitted ==
    /\ IsEvent("BatchCommitted")
    /\ LET rd == MapRD(logline.rd) IN
        /\ BatchCommitted(rd)
        /\ ValidateSnapshot
    /\ l' = l + 1

TraceQueryAdvanceSnapshot ==
    /\ IsEvent("QueryAdvanceSnapshot")
    /\ LET q == MapQuery(logline.query) IN
        QueryAdvanceSnapshot(q)
    /\ l' = l + 1

TraceQueryKilled ==
    /\ IsEvent("QueryKilled")
    /\ LET q == MapQuery(logline.query) IN
        /\ QueryKilled(q)
        /\ ValidateQueryState(q)
    /\ l' = l + 1

TraceQueryProceed ==
    /\ IsEvent("QueryProceed")
    /\ LET q == MapQuery(logline.query) IN
        /\ QueryProceed(q)
        /\ ValidateQueryState(q)
    /\ l' = l + 1

TraceStepUp ==
    /\ IsEvent("StepUp")
    /\ StepUp
    /\ l' = l + 1

TraceRecoverTask ==
    /\ IsEvent("RecoverTask")
    /\ LET rd == MapRD(logline.rd) IN
        RecoverTask(rd)
    /\ l' = l + 1

(*====================================================================*)
(* Silent actions                                                      *)
(* Handle spec state changes without trace events.                     *)
(* CRITICAL: Must be tightly constrained to prevent state explosion.   *)
(*====================================================================*)

\* Silent signal commit: if the trace expects a BatchCommitted next but
\* signal hasn't committed yet, allow it to commit silently.
\* This handles cases where the oplog commit isn't individually logged.
SilentOpApplierSignalCommit ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "BatchCommitted"
    /\ \E rd \in RangeDeletion :
        /\ signalState[rd] = "UPDATED"
        /\ OpApplierSignalCommit(rd)
    /\ UNCHANGED l

\* Silent delete commit: same pattern for delete ops
SilentOpApplierDeleteCommit ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "BatchCommitted"
    /\ \E rd \in RangeDeletion :
        /\ deleteState[rd] = "UPDATED"
        /\ OpApplierDeleteCommit(rd)
    /\ UNCHANGED l

\* Silent delete update: allow delete to progress when trace jumps ahead
SilentOpApplierDeleteUpdate ==
    /\ l <= Len(TraceLog)
    /\ logline.event \in {"DeleteCommit", "BatchCommitted"}
    /\ \E rd \in RangeDeletion :
        /\ deleteState[rd] = "INIT"
        /\ OpApplierDeleteUpdate(rd)
    /\ UNCHANGED l

(*====================================================================*)
(* TraceNext                                                           *)
(*====================================================================*)

TraceNext ==
    \* Traced actions
    \/ TraceOpApplierSignalUpdate
    \/ TraceOpApplierSignalCommit
    \/ TraceOpApplierDeleteUpdate
    \/ TraceOpApplierDeleteCommit
    \/ TraceBatchCommitted
    \/ TraceQueryAdvanceSnapshot
    \/ TraceQueryKilled
    \/ TraceQueryProceed
    \/ TraceStepUp
    \/ TraceRecoverTask
    \* Silent actions (tightly constrained)
    \/ SilentOpApplierSignalCommit
    \/ SilentOpApplierDeleteCommit
    \/ SilentOpApplierDeleteUpdate
    \* Terminal: advance l once more to signal completion, then deadlock
    \* (TLC with INIT/NEXT uses deadlock detection for trace completion)
    \/ (l = Len(TraceLog) + 1 /\ l' = l + 1 /\ UNCHANGED vars)

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

(*====================================================================*)
(* Trace completion                                                    *)
(* MUST be checked — without it, TLC reports "no errors" even if       *)
(* l never advances past line 1.                                       *)
(*====================================================================*)

TraceMatched == <>(l > Len(TraceLog))

====
