---- MODULE Trace ----
\* Trace validation spec for MongoDB TxnsCollectionIncarnation.
\* Replays implementation traces against the base spec to verify consistency.

EXTENDS base, Json, Sequences, TLC, TLCExt, IOUtils, Naturals

\* ===========================================================================
\* Trace Loading
\* ===========================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTraceLog == ndJsonDeserialize(JsonFile)

\* Filter to events with "event" field
TraceLog == SelectSeq(RawTraceLog, LAMBDA e : "event" \in DOMAIN e)

VARIABLE l  \* Trace cursor: indexes into TraceLog

traceVars == <<l>>
allVars == <<vars, traceVars>>

\* ===========================================================================
\* Helpers
\* ===========================================================================

logline == TraceLog[l]

\* Event matching predicates
IsEvent(name) == logline.event = name

\* No mapping needed — Trace.cfg uses implementation IDs directly
\* (e.g., Shards = {"shard0000", "shard0001"}, NameSpaces = {"test.coll1", "test.coll2"})

\* Advance cursor
AdvanceCursor == l' = l + 1

\* ===========================================================================
\* Post-State Validation
\* ===========================================================================

\* Validate that spec state matches trace after each action.
\* Strong validation: check all key state fields.
\* Weak validation: check only what the trace records.

ValidateClusterTime ==
    IF "clusterTime" \in DOMAIN logline
    THEN clusterTime' = logline.clusterTime
    ELSE TRUE

ValidatePlacementConflictTime(t) ==
    IF "placementConflictTime" \in DOMAIN logline
    THEN rPlacementConflictTime'[t] = logline.placementConflictTime
    ELSE TRUE

ValidateDDLPhase(ns) ==
    IF "ddlPhase" \in DOMAIN logline
    THEN ddlPhase'[ns] = logline.ddlPhase
    ELSE TRUE

ValidateResponseStatus(t, stm) ==
    IF "responseStatus" \in DOMAIN logline
    THEN \E rsp \in response'[t][stm] : rsp.status = logline.responseStatus
    ELSE TRUE

\* ===========================================================================
\* Trace Action Wrappers
\* ===========================================================================

\* --- Router actions ---

TraceRouterSendTxnStmt ==
    /\ IsEvent("RouterSendTxnStmt")
    /\ \E t \in Txns, ns \in NameSpaces :
        /\ logline.txn = t
        /\ logline.ns = ns
        /\ RouterSendTxnStmt(t, ns)
        /\ ValidatePlacementConflictTime(t)
    /\ AdvanceCursor

TraceRouterAnnotateCreatedDatabase ==
    /\ IsEvent("RouterAnnotateCreatedDatabase")
    /\ \E t \in Txns, dbName \in DatabaseNames :
        /\ logline.txn = t
        /\ logline.dbName = dbName
        /\ RouterAnnotateCreatedDatabase(t, dbName)
    /\ AdvanceCursor

TraceRouterHandleAbort ==
    /\ IsEvent("RouterHandleAbort")
    /\ \E t \in Txns, stm \in Stmts :
        /\ logline.txn = t
        /\ logline.stmt = stm
        /\ RouterHandleAbort(t, stm)
        /\ ValidateResponseStatus(t, stm)
    /\ AdvanceCursor

TraceRouterHandleOK ==
    /\ IsEvent("RouterHandleOK")
    /\ \E t \in Txns, stm \in Stmts :
        /\ logline.txn = t
        /\ logline.stmt = stm
        /\ RouterHandleOK(t, stm)
    /\ AdvanceCursor

TraceRouterSendCommit ==
    /\ IsEvent("RouterSendCommit")
    /\ \E t \in Txns :
        /\ logline.txn = t
        /\ RouterSendCommit(t)
    /\ AdvanceCursor

TraceRouterReceiveStaleError ==
    /\ IsEvent("RouterReceiveStaleError")
    /\ \E t \in Txns :
        /\ logline.txn = t
        /\ RouterReceiveStaleError(t)
    /\ AdvanceCursor

TraceRouterRetryFirstStatement ==
    /\ IsEvent("RouterRetryFirstStatement")
    /\ \E t \in Txns, ns \in NameSpaces :
        /\ logline.txn = t
        /\ logline.ns = ns
        /\ RouterRetryFirstStatement(t, ns)
        /\ ValidatePlacementConflictTime(t)
    /\ AdvanceCursor

\* --- Shard actions ---

TraceShardResponse ==
    /\ IsEvent("ShardResponse")
    /\ \E self \in Shards, t \in Txns :
        /\ logline.shard = self
        /\ logline.txn = t
        /\ ShardResponse(self, t)
        /\ IF "responseStatus" \in DOMAIN logline
           THEN \E stm \in Stmts :
               \E rsp \in response'[t][stm] :
                   /\ rsp.shard = self
                   /\ rsp.status = logline.responseStatus
           ELSE TRUE
    /\ AdvanceCursor

\* --- DDL actions (multi-phase) ---

TraceCreateTrackedAcquireLock ==
    /\ IsEvent("CreateTrackedAcquireLock")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ CreateTrackedAcquireLock(ns)
        /\ ValidateDDLPhase(ns)
    /\ AdvanceCursor

TraceCreateTrackedEnterCS ==
    /\ IsEvent("CreateTrackedEnterCS")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ CreateTrackedEnterCS(ns)
        /\ ValidateDDLPhase(ns)
    /\ AdvanceCursor

TraceCreateTrackedCommitMetadata ==
    /\ IsEvent("CreateTrackedCommitMetadata")
    /\ \E ns \in NameSpaces, d \in ValidDataDistributions :
        /\ logline.ns = ns
        /\ CreateTrackedCommitMetadata(ns, d)
        /\ ValidateClusterTime
        /\ ValidateDDLPhase(ns)
    /\ AdvanceCursor

TraceCreateTrackedExitCS ==
    /\ IsEvent("CreateTrackedExitCS")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ CreateTrackedExitCS(ns)
        /\ ValidateDDLPhase(ns)
    /\ AdvanceCursor

TraceCreateUntrackedAcquireLock ==
    /\ IsEvent("CreateUntrackedAcquireLock")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ CreateUntrackedAcquireLock(ns)
    /\ AdvanceCursor

TraceCreateUntrackedCommit ==
    /\ IsEvent("CreateUntrackedCommit")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ CreateUntrackedCommit(ns)
        /\ ValidateClusterTime
    /\ AdvanceCursor

TraceDropAcquireLock ==
    /\ IsEvent("DropAcquireLock")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ LET type == IF "collType" \in DOMAIN logline THEN logline.collType ELSE TRACKED
           IN DropAcquireLock(ns, type)
    /\ AdvanceCursor

TraceDropEnterCS ==
    /\ IsEvent("DropEnterCS")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ DropEnterCS(ns)
    /\ AdvanceCursor

TraceDropCommitMetadata ==
    /\ IsEvent("DropCommitMetadata")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ DropCommitMetadata(ns)
        /\ ValidateClusterTime
    /\ AdvanceCursor

TraceDropExitCS ==
    /\ IsEvent("DropExitCS")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ DropExitCS(ns)
    /\ AdvanceCursor

TraceRenameAcquireLock ==
    /\ IsEvent("RenameAcquireLock")
    /\ \E from, to \in NameSpaces :
        /\ logline.from = from
        /\ logline.to = to
        /\ LET type == IF "collType" \in DOMAIN logline THEN logline.collType ELSE TRACKED
           IN RenameAcquireLock(from, to, type)
    /\ AdvanceCursor

TraceRenameEnterCS ==
    /\ IsEvent("RenameEnterCS")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ RenameEnterCS(ns)
    /\ AdvanceCursor

TraceRenameCommitMetadata ==
    /\ IsEvent("RenameCommitMetadata")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ RenameCommitMetadata(ns)
        /\ ValidateClusterTime
    /\ AdvanceCursor

TraceRenameExitCS ==
    /\ IsEvent("RenameExitCS")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ RenameExitCS(ns)
    /\ AdvanceCursor

TraceMovePrimaryAcquireLock ==
    /\ IsEvent("MovePrimaryAcquireLock")
    /\ \E to \in Shards :
        /\ logline.toShard = to
        /\ MovePrimaryAcquireLock(to)
    /\ AdvanceCursor

TraceMovePrimaryEnterCS ==
    /\ IsEvent("MovePrimaryEnterCS")
    /\ \E to \in Shards :
        /\ logline.toShard = to
        /\ MovePrimaryEnterCS(to)
    /\ AdvanceCursor

TraceMovePrimaryCommitMetadata ==
    /\ IsEvent("MovePrimaryCommitMetadata")
    /\ \E to \in Shards :
        /\ logline.toShard = to
        /\ MovePrimaryCommitMetadata(to)
        /\ ValidateClusterTime
    /\ AdvanceCursor

TraceMovePrimaryExitCS ==
    /\ IsEvent("MovePrimaryExitCS")
    /\ \E to \in Shards :
        /\ logline.toShard = to
        /\ MovePrimaryExitCS(to)
    /\ AdvanceCursor

TraceDDLFailover ==
    /\ IsEvent("DDLFailover")
    /\ \E ns \in NameSpaces :
        /\ logline.ns = ns
        /\ DDLFailover(ns)
        /\ ValidateDDLPhase(ns)
    /\ AdvanceCursor

TraceMovePrimaryFailover ==
    /\ IsEvent("MovePrimaryFailover")
    /\ MovePrimaryFailover
    /\ AdvanceCursor

\* ===========================================================================
\* Silent Actions
\* ===========================================================================

\* Silent actions handle state transitions without trace events.
\* CRITICAL: All silent actions must be tightly constrained to prevent
\* state space explosion.

\* No silent actions needed for initial version.
\* DDL phase transitions are always traced.
\* Router/Shard actions are always traced.
\* If needed during validation, add constrained silent actions here.

\* ===========================================================================
\* TraceInit / TraceNext / TraceMatched
\* ===========================================================================

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    /\ l <= Len(TraceLog)
    /\ \/ TraceRouterSendTxnStmt
       \/ TraceRouterAnnotateCreatedDatabase
       \/ TraceRouterHandleAbort
       \/ TraceRouterHandleOK
       \/ TraceRouterSendCommit
       \/ TraceRouterReceiveStaleError
       \/ TraceRouterRetryFirstStatement
       \/ TraceShardResponse
       \/ TraceCreateTrackedAcquireLock
       \/ TraceCreateTrackedEnterCS
       \/ TraceCreateTrackedCommitMetadata
       \/ TraceCreateTrackedExitCS
       \/ TraceCreateUntrackedAcquireLock
       \/ TraceCreateUntrackedCommit
       \/ TraceDropAcquireLock
       \/ TraceDropEnterCS
       \/ TraceDropCommitMetadata
       \/ TraceDropExitCS
       \/ TraceRenameAcquireLock
       \/ TraceRenameEnterCS
       \/ TraceRenameCommitMetadata
       \/ TraceRenameExitCS
       \/ TraceMovePrimaryAcquireLock
       \/ TraceMovePrimaryEnterCS
       \/ TraceMovePrimaryCommitMetadata
       \/ TraceMovePrimaryExitCS
       \/ TraceDDLFailover
       \/ TraceMovePrimaryFailover

\* Trace matched: all events consumed (deadlock-based check)
\* TLC hits deadlock when l > Len(TraceLog) which means trace fully consumed = success
TraceAccepted ==
    l > Len(TraceLog)

\* Temporal property: trace eventually fully consumed
TraceMatched == <>(l > Len(TraceLog))

====
