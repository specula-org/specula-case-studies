--------------------------------- MODULE Trace ---------------------------------
\* Trace validation spec for MongoDB TxnsMoveRange.
\* Replays implementation traces against the base spec to verify consistency.
\*
\* Trace file format: NDJSON with events for router and shard actions.
\* Cursor variable `l` walks through trace events.
\* Silent actions handle state changes without trace events.

EXTENDS base, Sequences, TLC, TLCExt, IOUtils, Json

\* ============================================================================
\* Trace loading
\* ============================================================================

\* Trace file path — override via IOEnv.JSON for per-run selection
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load and deserialize trace
RawTraceLog == ndJsonDeserialize(JsonFile)

\* Filter to only events with our expected tag
TraceLog == SelectSeq(RawTraceLog, LAMBDA e : "event" \in DOMAIN e)

\* ============================================================================
\* Trace cursor
\* ============================================================================

VARIABLE l  \* Trace cursor: position in TraceLog

traceVars == <<vars, l>>

logline == TraceLog[l]

\* ============================================================================
\* Event predicates
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

\* ============================================================================
\* Mapping helpers — implementation values to spec constants
\* ============================================================================

\* Map shard name strings to Shard constants
MapShard(name) ==
    CASE name = "s1" -> CHOOSE s \in Shards : ToString(s) = "s1"
      [] name = "s2" -> CHOOSE s \in Shards : ToString(s) = "s2"
      [] OTHER -> CHOOSE s \in Shards : TRUE

\* Map namespace strings to NameSpace constants
MapNameSpace(name) ==
    CASE name = "ns1" -> CHOOSE n \in NameSpaces : ToString(n) = "ns1"
      [] OTHER -> CHOOSE n \in NameSpaces : TRUE

\* Map key strings to Key constants
\* k3, k4 from the real system map to k2 (abstract second key)
MapKey(name) ==
    CASE name = "k1" -> CHOOSE k \in Keys : ToString(k) = "k1"
      [] name = "k2" -> CHOOSE k \in Keys : ToString(k) = "k2"
      [] name = "k3" -> CHOOSE k \in Keys : ToString(k) = "k2"
      [] name = "k4" -> CHOOSE k \in Keys : ToString(k) = "k2"
      [] OTHER -> CHOOSE k \in Keys : TRUE

\* Map transaction ID strings to Txn constants
MapTxn(name) ==
    CASE name = "t1" -> CHOOSE t \in Txns : ToString(t) = "t1"
      [] OTHER -> CHOOSE t \in Txns : TRUE

\* Map status strings
MapStatus(s) ==
    CASE s = "ok"                 -> ok
      [] s = "staleRouter"       -> staleRouter
      [] s = "migrationConflict" -> migrationConflict
      [] OTHER -> ok

\* ============================================================================
\* Post-state validation
\* ============================================================================

\* Strong validation: check router state after router actions
ValidateRouterState ==
    /\ IF "rCompletedStmt" \in DOMAIN logline
       THEN rCompletedStmt[MapTxn(logline.txn)] = logline.rCompletedStmt
       ELSE TRUE
    /\ IF "rPlacementConflictTime" \in DOMAIN logline
       THEN rPlacementConflictTime[MapTxn(logline.txn)] = logline.rPlacementConflictTime
       ELSE TRUE

\* Weak validation: check migration phase
ValidateMigrationState ==
    /\ IF "migrationPhase" \in DOMAIN logline
       THEN migrationPhase[MapNameSpace(logline.ns)] = logline.migrationPhase
       ELSE TRUE

\* ============================================================================
\* Trace action wrappers
\* ============================================================================

\* Router sends a transaction statement
TraceRouterSendTxnStmt ==
    /\ IsEvent("RouterSendTxnStmt")
    /\ LET t  == MapTxn(logline.txn)
           ns == MapNameSpace(logline.ns)
           k  == MapKey(logline.key)
       IN RouterSendTxnStmt(t, ns, k)
    /\ l' = l + 1

\* Router handles ok response
TraceRouterHandleOk ==
    /\ IsEvent("RouterHandleOk")
    /\ LET t   == MapTxn(logline.txn)
           stm == logline.stm
       IN RouterHandleOk(t, stm)
    /\ l' = l + 1

\* Router handles abort (non-retryable error)
TraceRouterHandleAbort ==
    /\ IsEvent("RouterHandleAbort")
    /\ LET t   == MapTxn(logline.txn)
           stm == logline.stm
       IN RouterHandleAbort(t, stm)
    /\ l' = l + 1

\* Router retries on stale error
TraceRouterRetryOnStale ==
    /\ IsEvent("RouterRetryOnStale")
    /\ LET t == MapTxn(logline.txn)
       IN RouterRetryOnStale(t)
    /\ l' = l + 1

\* Router creates database
TraceCreateDatabase ==
    /\ IsEvent("CreateDatabase")
    /\ LET t == MapTxn(logline.txn)
       IN CreateDatabase(t)
    /\ l' = l + 1

\* Shard responds to statement
TraceShardRespond ==
    /\ IsEvent("ShardRespond")
    /\ LET t    == MapTxn(logline.txn)
           self == MapShard(logline.shard)
       IN ShardRespond(t, self)
    /\ l' = l + 1

\* Shard responds after executing write (error after exec)
TraceShardRespondAfterExec ==
    /\ IsEvent("ShardRespondAfterExec")
    /\ LET t    == MapTxn(logline.txn)
           self == MapShard(logline.shard)
       IN ShardRespondAfterExec(t, self)
    /\ l' = l + 1

\* Start migration
TraceStartMigration ==
    /\ IsEvent("StartMigration")
    /\ LET ns   == MapNameSpace(logline.ns)
           k    == MapKey(logline.key)
           from == MapShard(logline.from)
           to   == MapShard(logline.to)
       IN StartMigration(ns, k, from, to)
    /\ l' = l + 1

\* Config commit
TraceConfigCommit ==
    /\ IsEvent("ConfigCommit")
    /\ LET ns == MapNameSpace(logline.ns)
       IN ConfigCommit(ns)
    /\ l' = l + 1

\* Config commit failure
TraceConfigCommitFail ==
    /\ IsEvent("ConfigCommitFail")
    /\ LET ns == MapNameSpace(logline.ns)
       IN ConfigCommitFail(ns)
    /\ l' = l + 1

\* Release critical section
TraceReleaseCriticalSection ==
    /\ IsEvent("ReleaseCriticalSection")
    /\ LET ns == MapNameSpace(logline.ns)
       IN ReleaseCriticalSection(ns)
    /\ l' = l + 1

\* Donor step down
TraceDonorStepDown ==
    /\ IsEvent("DonorStepDown")
    /\ LET s == MapShard(logline.shard)
       IN DonorStepDown(s)
    /\ l' = l + 1

\* Donor step up
TraceDonorStepUp ==
    /\ IsEvent("DonorStepUp")
    /\ LET s == MapShard(logline.shard)
       IN DonorStepUp(s)
    /\ l' = l + 1

\* Donor recovery
TraceDonorRecovery ==
    /\ IsEvent("DonorRecovery")
    /\ LET s  == MapShard(logline.shard)
           ns == MapNameSpace(logline.ns)
       IN DonorRecovery(s, ns)
    /\ l' = l + 1

\* ============================================================================
\* Silent actions (no trace event consumed)
\* Tightly constrained to prevent state space explosion.
\* ============================================================================

\* Silent config commit: migration commits without explicit trace event.
\* Constrained: only when next event requires committed state.
SilentConfigCommit ==
    /\ l <= Len(TraceLog)
    /\ \E ns \in NameSpaces :
        /\ migrationPhase[ns] = MigCritSec
        /\ coordinatorDoc[ns] = DocPending
        \* Only fire if next event is ReleaseCriticalSection for this ns
        /\ logline.event = "ReleaseCriticalSection"
        /\ MapNameSpace(logline.ns) = ns
        /\ ConfigCommit(ns)
    /\ UNCHANGED l

\* Silent release critical section: CS released without trace event.
\* Constrained: only when migration is in Committed phase.
SilentReleaseCriticalSection ==
    /\ l <= Len(TraceLog)
    /\ \E ns \in NameSpaces :
        /\ migrationPhase[ns] = MigCommitted
        /\ coordinatorDoc[ns] = DocCommitted
        \* Only fire if next event requires Idle phase
        /\ \/ logline.event = "StartMigration"
           \/ logline.event = "ShardRespond"
        /\ ReleaseCriticalSection(ns)
    /\ UNCHANGED l

\* Silent donor step-up: shard comes back without trace event.
SilentDonorStepUp ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Shards :
        /\ donorAlive[s] = FALSE
        /\ DonorStepUp(s)
    /\ UNCHANGED l

\* Silent donor recovery: recovery completes without trace event.
SilentDonorRecovery ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Shards, ns \in NameSpaces :
        /\ donorAlive[s] = TRUE
        /\ migrationPhase[ns] = MigIdle
        /\ migrationFrom[ns] = s
        /\ coordinatorDoc[ns] \in {DocPending, DocCommitted, DocAborted}
        /\ DonorRecovery(s, ns)
    /\ UNCHANGED l

\* ============================================================================
\* Trace Init
\* ============================================================================

TraceInit ==
    /\ InitBase
    \* Router cache may be stale (e.g., after a prior migration not in this trace)
    /\ rCachedRanges \in [NameSpaces -> [Keys -> Shards]]
    /\ l = 1

\* ============================================================================
\* Trace Next
\* ============================================================================

TraceNext ==
    \* --- Traced actions (consume one event) ---
    \/ TraceRouterSendTxnStmt
    \/ TraceRouterHandleOk
    \/ TraceRouterHandleAbort
    \/ TraceRouterRetryOnStale
    \/ TraceCreateDatabase
    \/ TraceShardRespond
    \/ TraceShardRespondAfterExec
    \/ TraceStartMigration
    \/ TraceConfigCommit
    \/ TraceConfigCommitFail
    \/ TraceReleaseCriticalSection
    \/ TraceDonorStepDown
    \/ TraceDonorStepUp
    \/ TraceDonorRecovery
    \* --- Silent actions (no event consumed) ---
    \/ SilentConfigCommit
    \/ SilentReleaseCriticalSection
    \/ SilentDonorStepUp
    \/ SilentDonorRecovery

\* ============================================================================
\* Trace completion check
\* ============================================================================

\* Temporal property: the entire trace was consumed.
TraceMatched == <>(l = Len(TraceLog) + 1)

\* Alternative: check via deadlock detection.
\* Run with -deadlock and check that TLC terminates at l = Len(TraceLog) + 1.
TraceFinished == l = Len(TraceLog) + 1

================================================================================
