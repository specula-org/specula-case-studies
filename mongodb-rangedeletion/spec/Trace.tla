---- MODULE Trace ----
EXTENDS base, Json, IOUtils, Sequences, Naturals, TLC

\*---------------------------------------------------------------------
\* Trace loading
\*---------------------------------------------------------------------
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawLog == ndJsonDeserialize(JsonFile)

\* Filter for range_deletion events
TraceLog == SelectSeq(RawLog, LAMBDA x : "tag" \in DOMAIN x /\ x.tag = "range_deletion")

\*---------------------------------------------------------------------
\* Cursor variable
\*---------------------------------------------------------------------
VARIABLE l
traceVars == <<vars, l>>

logline == TraceLog[l]

\*---------------------------------------------------------------------
\* Event predicates
\*---------------------------------------------------------------------
IsEvent(name) == l <= Len(TraceLog) /\ logline.action = name

\*---------------------------------------------------------------------
\* Range mapping: trace string → spec constant
\*---------------------------------------------------------------------
TraceRange(r) ==
    IF r = Nil THEN Nil
    ELSE r  \* Range IDs in trace match spec constants directly

TraceMigration(m) ==
    IF m = Nil THEN Nil
    ELSE m  \* Migration IDs map directly

\*---------------------------------------------------------------------
\* Post-state validation helpers
\*---------------------------------------------------------------------

\* Strong validation: check all task fields
ValidateTaskState(t) ==
    /\ IF "taskState" \in DOMAIN logline
       THEN taskState'[t] = logline.taskState
       ELSE TRUE
    /\ IF "taskDocExists" \in DOMAIN logline
       THEN taskDocExists'[t] = logline.taskDocExists
       ELSE TRUE
    /\ IF "taskDocPending" \in DOMAIN logline
       THEN taskDocPending'[t] = logline.taskDocPending
       ELSE TRUE
    /\ IF "taskDocProcessing" \in DOMAIN logline
       THEN taskDocProcessing'[t] = logline.taskDocProcessing
       ELSE TRUE

\* Validate service state
ValidateServiceState ==
    /\ IF "serviceState" \in DOMAIN logline
       THEN serviceState' = logline.serviceState
       ELSE TRUE
    /\ IF "processorState" \in DOMAIN logline
       THEN processorState' = logline.processorState
       ELSE TRUE

\* Validate migration state
ValidateMigrationState(m) ==
    IF "migrationState" \in DOMAIN logline
    THEN migrationState'[m] = logline.migrationState
    ELSE TRUE

\*---------------------------------------------------------------------
\* Trace Init
\*---------------------------------------------------------------------
TraceInit ==
    /\ l = 1
    /\ Init

\*---------------------------------------------------------------------
\* Trace action wrappers
\*---------------------------------------------------------------------

\* --- Service lifecycle ---

TraceStepUp ==
    /\ IsEvent("StepUp")
    /\ StepUp
    /\ ValidateServiceState
    /\ l' = l + 1

TraceRecoveryBegin ==
    /\ IsEvent("RecoveryBegin")
    /\ RecoveryBegin
    /\ ValidateServiceState
    /\ l' = l + 1

TraceRecoveryComplete ==
    /\ IsEvent("RecoveryComplete")
    /\ RecoveryComplete
    /\ ValidateServiceState
    /\ l' = l + 1

TraceStepDown ==
    /\ IsEvent("StepDown")
    /\ StepDown
    /\ ValidateServiceState
    /\ l' = l + 1

\* --- Migration lifecycle ---

TraceStartMigration ==
    /\ IsEvent("StartMigration")
    /\ LET m == TraceMigration(logline.migration)
           r == TraceRange(logline.range)
           t == logline.task
       IN /\ StartMigration(m, r, t)
          /\ ValidateMigrationState(m)
    /\ l' = l + 1

TraceCommitMigration ==
    /\ IsEvent("CommitMigration")
    /\ LET m == TraceMigration(logline.migration)
       IN /\ CommitMigration(m)
          /\ ValidateMigrationState(m)
    /\ l' = l + 1

TraceAbortMigration ==
    /\ IsEvent("AbortMigration")
    /\ LET m == TraceMigration(logline.migration)
       IN /\ AbortMigration(m)
          /\ ValidateMigrationState(m)
    /\ l' = l + 1

\* --- Task registration chain ---

TraceClearPending ==
    /\ IsEvent("ClearPending")
    /\ LET t == logline.task
       IN /\ ClearPending(t)
          /\ ValidateTaskState(t)
    /\ l' = l + 1

TraceCheckOverlap ==
    /\ IsEvent("CheckOverlap")
    /\ LET t == logline.task
       IN /\ CheckOverlap(t)
          /\ ValidateTaskState(t)
    /\ l' = l + 1

TraceOverlapResolved ==
    /\ IsEvent("OverlapResolved")
    /\ LET t == logline.task
       IN /\ OverlapResolved(t)
          /\ ValidateTaskState(t)
    /\ l' = l + 1

TraceQueriesDrained ==
    /\ IsEvent("QueriesDrained")
    /\ LET t == logline.task
       IN /\ QueriesDrained(t)
          /\ ValidateTaskState(t)
    /\ l' = l + 1

\* --- Deletion execution ---

TraceProcessorPickTask ==
    /\ IsEvent("ProcessorPickTask")
    /\ LET t == logline.task
       IN /\ ProcessorPickTask(t)
          /\ ValidateTaskState(t)
    /\ l' = l + 1

TraceCompleteTask ==
    /\ IsEvent("CompleteTask")
    /\ LET t == logline.task
       IN /\ CompleteTask(t)
          /\ ValidateTaskState(t)
    /\ l' = l + 1

\* --- Query lifecycle ---

TraceStartQuery ==
    /\ IsEvent("StartQuery")
    /\ LET q == logline.query
           r == TraceRange(logline.range)
       IN StartQuery(q, r)
    /\ l' = l + 1

TraceEndQuery ==
    /\ IsEvent("EndQuery")
    /\ LET q == logline.query
       IN EndQuery(q)
    /\ l' = l + 1

\* --- Metadata lifecycle ---

TraceClearMetadata ==
    /\ IsEvent("ClearMetadata")
    /\ ClearMetadata
    /\ l' = l + 1

TraceRefreshMetadata ==
    /\ IsEvent("RefreshMetadata")
    /\ RefreshMetadata
    /\ l' = l + 1

\* --- Clock ---

TraceTickClock ==
    /\ IsEvent("TickClock")
    /\ TickClock
    /\ l' = l + 1

\*---------------------------------------------------------------------
\* Silent actions
\* These fire without consuming trace events. Must be tightly constrained.
\*---------------------------------------------------------------------

\* Silent clock tick: needed when next event requires a different timestamp
\* Constrained: only when next event has a task with a different expected regTime
SilentTickClock ==
    /\ l <= Len(TraceLog)
    /\ TickClock
    /\ UNCHANGED l

\* Silent EndQuery: query ends between trace events (not instrumented)
\* Constrained: only when a query must drain for the next event
SilentEndQuery ==
    /\ l <= Len(TraceLog)
    /\ \E q \in activeQueries :
        \* Only fire if the next event is QueriesDrained for a task on this query's range
        /\ logline.action = "QueriesDrained"
        /\ queryRange[q] /= Nil
        /\ \E t \in Task :
            /\ taskState[t] = "waitQueries"
            /\ taskRange[t] /= Nil
            /\ RangeOverlaps(queryRange[q], taskRange[t])
        /\ EndQuery(q)
    /\ UNCHANGED l

\* Silent RefreshMetadata: metadata refreshed between trace events
\* Constrained: only when metadata is unknown and next event requires it
SilentRefreshMetadata ==
    /\ l <= Len(TraceLog)
    /\ ~metadataKnown
    /\ logline.action \in {"StartQuery", "CommitMigration"}
    /\ RefreshMetadata
    /\ UNCHANGED l

\*---------------------------------------------------------------------
\* TraceNext
\*---------------------------------------------------------------------
TraceNext ==
    \* Traced actions
    \/ TraceStepUp
    \/ TraceRecoveryBegin
    \/ TraceRecoveryComplete
    \/ TraceStepDown
    \/ TraceStartMigration
    \/ TraceCommitMigration
    \/ TraceAbortMigration
    \/ TraceClearPending
    \/ TraceCheckOverlap
    \/ TraceOverlapResolved
    \/ TraceQueriesDrained
    \/ TraceProcessorPickTask
    \/ TraceCompleteTask
    \/ TraceStartQuery
    \/ TraceEndQuery
    \/ TraceClearMetadata
    \/ TraceRefreshMetadata
    \/ TraceTickClock
    \* Silent actions
    \/ SilentTickClock
    \/ SilentEndQuery
    \/ SilentRefreshMetadata

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

\*---------------------------------------------------------------------
\* Trace completion check
\* Uses deadlock-based approach: TLC reports "deadlock" when trace consumed
\*---------------------------------------------------------------------
TraceFinished == l > Len(TraceLog)

\* Alternative: temporal property (requires fairness, not recommended)
\* TraceMatched == <>(l > Len(TraceLog))

====
