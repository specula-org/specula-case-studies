---- MODULE base ----
\* TLA+ spec for MongoDB TxnsCollectionIncarnation DDL + Transaction placementConflictTime.
\*
\* Extends the official TxnsCollectionIncarnation.tla to model:
\*   - Multi-phase DDL operations with failover (Bug Family 1)
\*   - Transaction statement interleaving with DDL, including separate commit (Bug Family 2, 5)
\*   - createdDatabases bypass with multiple databases (Bug Family 3)
\*   - Stale error retry with placementConflictTime reset (Bug Family 4)
\*   - Critical sections blocking shard operations during DDL commit (Bug Family 1, 2)
\*
\* Key difference from official spec: DDL operations are multi-phase (not atomic),
\* commit is a separate step, and failover can interrupt DDL between phases.

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Shards,
    NameSpaces,
    Keys,
    Txns,
    TXN_STMTS       \* statements per transaction

\* Status codes
STALE_DB_VERSION     == "staleDbVersion"
STALE_SHARD_VERSION  == "staleShardVersion"
SNAPSHOT_INCOMPATIBLE == "snapshotIncompatible"
OK                   == "ok"

\* Collection tracking types
UNKNOWN   == "unknown"
TRACKED   == "tracked"
UNTRACKED == "untracked"

INITIAL_CLUSTER_TIME == 1

\* Bug Family 3: Multiple databases to exercise bypass granularity
\* (official spec: DatabaseNames == {"db"} — makes bypass always active)
DatabaseNames == {"db1", "db2"}

\* DDL operation types (Bug Family 1)
\* Tracked and untracked creates are separate coordinator types — cannot mix phases
DDL_CREATE_TRACKED   == "createTracked"
DDL_CREATE_UNTRACKED == "createUntracked"
DDL_DROP     == "drop"
DDL_RENAME   == "rename"
DDL_MOVE     == "movePrimary"

\* DDL phases — abstracted from 6-10 implementation phases to key transitions
\* (Bug Family 1: multi-phase DDL non-atomicity under failover)
\* create_collection_coordinator.cpp phases: kUnset → ... → kExitCriticalSection
\* drop_collection_coordinator.cpp phases: kUnset → ... → kReleaseCriticalSection
\* rename_collection_coordinator.cpp phases: kUnset → ... → kSetResponse
\* move_primary_coordinator.cpp phases: kUnset → ... → kExitCriticalSection
PHASE_ACQUIRE_LOCK    == "acquireLock"
PHASE_ENTER_CS        == "enterCS"        \* Enter critical section on shards
PHASE_COMMIT_METADATA == "commitMetadata" \* Commit metadata to config server
PHASE_EXIT_CS         == "exitCS"         \* Exit critical section
PHASE_DONE            == "done"

\* Critical section types
\* rename_collection_coordinator.cpp:662-685 — write-blocks then read-blocks
\* drop_collection_coordinator.cpp:274-293 — reads and writes blocked
CS_NONE       == "none"
CS_WRITE      == "write"         \* Block writes only
CS_READWRITE  == "readWrite"     \* Block reads and writes

\* Assumptions
ASSUME Cardinality(Shards) > 1
ASSUME Cardinality(NameSpaces) > 0
ASSUME Cardinality(Txns) > 0
ASSUME TXN_STMTS \in 2..100

Max(S) == CHOOSE x \in S : \A y \in S : x >= y
IsInjective(f) == \A a,b \in DOMAIN f : f[a] = f[b] => a = b

\* Transaction Runtime Context — sent with all requests
\* transaction_router.cpp:954-1001 — attachTxnFieldsIfNeeded
TxnRuntimeContext == [
    startTransaction: BOOLEAN,
    placementConflictTime: Int,
    createdDatabases: SUBSET DatabaseNames
]

DroppedNamespaceUUID == 0
Stmts == 1..TXN_STMTS
ReqEntry == [shard: Shards, ns: NameSpaces, dbVersion: Nat,
             collectionGen: Nat, txnRuntimeContext: TxnRuntimeContext]

CreateReqEntry(s, ns, dbVersion, collectionGen, txnCtx) ==
    [shard |-> s, ns |-> ns, dbVersion |-> dbVersion,
     collectionGen |-> collectionGen, txnRuntimeContext |-> txnCtx]

IsValidDataDistribution(d) ==
    /\ UNION {d[s] : s \in Shards} = Keys
    /\ \A s1, s2 \in Shards : s1 = s2 \/ d[s1] \cap d[s2] = {}
ValidDataDistributions == {d \in [Shards -> SUBSET Keys] : IsValidDataDistribution(d)}
DistributionToOwnership(d) == {s \in Shards : d[s] # {}}

UntrackedCollectionGen == 0
CollectionMetadataType == {UNTRACKED, TRACKED}
UntrackedClusterMetadata == [type |-> UNTRACKED, collectionGen |-> UntrackedCollectionGen]
CollectionMetadataFormat ==
    [type: {TRACKED}, collectionGen: Nat \ {UntrackedCollectionGen}]
    \cup {UntrackedClusterMetadata}
CreateTrackedCollectionMetadata(g) == [type |-> TRACKED, collectionGen |-> g]

CollectionCacheMetadataFormat ==
    [type: CollectionMetadataType \cup {UNKNOWN}, collectionGen: Nat, ownership: SUBSET Shards]
UnknownCollectionCacheMetadata ==
    [type |-> UNKNOWN, collectionGen |-> UntrackedCollectionGen, ownership |-> {}]

NoDatabaseVersion == 0
DatabaseMetadataFormat == [primaryShard: Shards, dbVersion: Nat]

EmptyTxnResources == [
    snapshot |-> <<>>,
    locks |-> [n \in NameSpaces |-> FALSE],
    placementConflictTime |-> -1,
    createdDatabases |-> {}
]

\* ===========================================================================
\* State Variables
\* ===========================================================================

\* --- Global and networking variables ---
VARIABLE databaseMetadata   \* Authoritative database metadata (single DB)
VARIABLE collectionMetadata \* Authoritative collection metadata per namespace
VARIABLE clusterTime        \* Cluster time, advances on DDL operations
VARIABLES log, response     \* RPC queues between router and shards
VARIABLE nextUUID           \* Auxiliary for UUID generation

\* --- Router variables ---
VARIABLE rDatabaseCache         \* Router cache of database metadata
VARIABLE rCollectionCache       \* Per namespace, router cache of collection metadata
VARIABLE rCompletedStmt         \* Per txn, last completed statement number
VARIABLE rPlacementConflictTime \* Per txn, immutable timestamp (transaction_router.cpp:1331-1356)
VARIABLE rCreatedDatabases      \* Per txn, set of databases created during transaction
\* Bug Family 5: separate commit step (transaction_router.cpp:1598-1630)
VARIABLE rCommitSent            \* Per txn, whether commit has been sent
\* Bug Family 4: stale error retry (transaction_router.cpp:1181-1235)
VARIABLE rRetryState            \* Per txn, retry state: "none" | "pending" | "retried"

\* --- Shard variables ---
VARIABLE shardTxnResources  \* Per shard per txn: snapshot, locks, placementConflictTime, createdDBs
VARIABLE shardData          \* Per namespace per shard: set of keys
VARIABLE shardNamespaceUUID \* Per clusterTime per namespace per shard: UUID

\* --- DDL extension variables (Bug Family 1) ---
\* sharding_coordinator.cpp:477-503 — recovery loop
\* ddl_lock_manager.h:73 — in-memory only locks
VARIABLE ddlPhase           \* Per namespace: current DDL phase
VARIABLE ddlType            \* Per namespace: what DDL operation is in progress
VARIABLE ddlLockHeld        \* Per namespace: whether DDL lock is held (in-memory only)
VARIABLE criticalSection    \* Per namespace: critical section state on shards
VARIABLE ddlPendingMetadata \* Per namespace: staged metadata changes before commit
\* Bug Family 1: failover state
VARIABLE ddlPersistedPhase  \* Per namespace: last phase persisted to config server

\* --- Variable groups for UNCHANGED ---
global_vars  == <<databaseMetadata, collectionMetadata, log, response, clusterTime, nextUUID>>
router_vars  == <<rDatabaseCache, rCollectionCache, rCompletedStmt, rPlacementConflictTime,
                  rCreatedDatabases, rCommitSent, rRetryState>>
shard_vars   == <<shardTxnResources, shardData, shardNamespaceUUID>>
ddl_vars     == <<ddlPhase, ddlType, ddlLockHeld, criticalSection, ddlPendingMetadata,
                  ddlPersistedPhase>>
vars == <<global_vars, router_vars, shard_vars, ddl_vars>>

\* ===========================================================================
\* Init
\* ===========================================================================

Init ==
    \* Global and networking
    /\ databaseMetadata \in [primaryShard: Shards, dbVersion: {INITIAL_CLUSTER_TIME}]
    /\ collectionMetadata = [n \in NameSpaces |-> UntrackedClusterMetadata]
    /\ clusterTime = INITIAL_CLUSTER_TIME
    /\ log = [t \in Txns |-> <<>>]
    /\ response = [t \in Txns |-> [stm \in Stmts |-> {}]]
    /\ nextUUID = 1000
    \* Router
    /\ rDatabaseCache = databaseMetadata
    /\ rCollectionCache = [n \in NameSpaces |-> UnknownCollectionCacheMetadata]
    /\ rCompletedStmt = [t \in Txns |-> 0]
    /\ rPlacementConflictTime = [t \in Txns |-> -1]
    /\ rCreatedDatabases = [t \in Txns |-> {}]
    /\ rCommitSent = [t \in Txns |-> FALSE]
    /\ rRetryState = [t \in Txns |-> "none"]
    \* Shard
    /\ shardTxnResources = [s \in Shards |-> [t \in Txns |-> EmptyTxnResources]]
    /\ shardData = [n \in NameSpaces |-> [s \in Shards |-> {}]]
    /\ shardNamespaceUUID = [x \in {clusterTime} |->
            [n \in NameSpaces |-> [s \in Shards |-> DroppedNamespaceUUID]]]
    \* DDL extension (Bug Family 1)
    /\ ddlPhase = [n \in NameSpaces |-> PHASE_DONE]
    /\ ddlType = [n \in NameSpaces |-> "none"]
    /\ ddlLockHeld = [n \in NameSpaces |-> FALSE]
    /\ criticalSection = [n \in NameSpaces |-> CS_NONE]
    /\ ddlPendingMetadata = [n \in NameSpaces |-> <<>>]
    /\ ddlPersistedPhase = [n \in NameSpaces |-> PHASE_DONE]

\* ===========================================================================
\* Helpers
\* ===========================================================================

\* Database-level DDL lock: MovePrimary blocks all other DDL on the database
\* move_primary_coordinator.cpp acquires database DDL lock, not just namespace lock
NoMovePrimaryInProgress == ~\E ns \in NameSpaces : ddlType[ns] = DDL_MOVE

LatestShardNamespaceUUID == shardNamespaceUUID[Max(DOMAIN shardNamespaceUUID)]
LatestUUIDForNameSpace(ns) == Max({LatestShardNamespaceUUID[ns][s] : s \in Shards})
NextClusterTime == clusterTime + 1

HasResponse(stmt) == Cardinality(stmt) # 0
TxnCommitted(t) ==
    /\ rCommitSent[t]  \* Bug Family 5: commit must have been explicitly sent
    /\ HasResponse(response[t][TXN_STMTS])
    /\ Cardinality(log[t][TXN_STMTS].reqEntries) = Cardinality(response[t][TXN_STMTS])
    /\ \A rsp \in response[t][TXN_STMTS] : rsp.status = OK
TxnAborted(t) ==
    \E s \in Stmts : HasResponse(response[t][s]) /\ \E rsp \in response[t][s] : rsp.status # OK
TxnDone(t) == TxnCommitted(t) \/ TxnAborted(t)

\* DDL is in progress for namespace ns
DDLInProgress(ns) == ddlPhase[ns] # PHASE_DONE

\* Namespace is locked by DDL (in-memory lock — ddl_lock_manager.h:73)
IsNamespaceLocked(ns) == ddlLockHeld[ns]

\* Critical section blocks shard operations
\* collection_sharding_runtime.cpp:640-729 — operations blocked during CS
IsCriticalSectionBlocking(ns) == criticalSection[ns] # CS_NONE

NamespaceExists(ns) ==
    \E s \in DOMAIN(LatestShardNamespaceUUID[ns]) :
        LatestShardNamespaceUUID[ns][s] # DroppedNamespaceUUID

ClearResourcesForTxnInShard(t, s) ==
    [tmpTxn \in Txns |->
        IF t = tmpTxn THEN EmptyTxnResources ELSE shardTxnResources[s][tmpTxn]]
ClearResourcesForTxn(t) ==
    [s \in Shards |-> ClearResourcesForTxnInShard(t, s)]

GetForShard(s, f) == [ns \in DOMAIN(f) |-> f[ns][s]]
CreateTxnSnapshot(s) ==
    LET ts == Max(DOMAIN shardNamespaceUUID) IN
    [ts   |-> ts,
     uuid |-> GetForShard(s, shardNamespaceUUID[clusterTime]),
     data |-> GetForShard(s, shardData)]

\* Router cache lookup — always returns latest authoritative metadata
\* transaction_router.cpp:205 — rCollectionCache refresh on UNKNOWN
RouterCacheLookup(ns) ==
    collectionMetadata[ns] @@ [ownership |-> DistributionToOwnership(shardData[ns])]
OwnershipFromCacheEntry(cached, dbCache) ==
    IF cached.type = TRACKED THEN cached.ownership ELSE {dbCache.primaryShard}

\* Build request entries for a transaction statement
\* transaction_router.cpp:954-1001 — attachTxnFieldsIfNeeded
TxnStmtLogEntries(t, ns, isStartTransaction) ==
    LET owningShards == OwnershipFromCacheEntry(rCollectionCache'[ns], rDatabaseCache')
        collectionGen == rCollectionCache'[ns].collectionGen
        dbVersion == IF collectionGen # UntrackedCollectionGen
                     THEN NoDatabaseVersion ELSE rDatabaseCache'.dbVersion
        txnCtx == [
            startTransaction |-> isStartTransaction,
            placementConflictTime |-> IF isStartTransaction
                                      THEN rPlacementConflictTime'[t] ELSE -1,
            createdDatabases |-> rCreatedDatabases'[t]
        ]
    IN [reqEntries |->
            {CreateReqEntry(s, ns, dbVersion, collectionGen, txnCtx) : s \in owningShards}]

\* ===========================================================================
\* Metadata Check — Shard-side validation
\* ===========================================================================

\* database_sharding_runtime.cpp:95-150 — checkPlacementConflictTimestamp
\* Bug Family 3: createdDatabases bypass — per-database check (new path)
\* database_sharding_runtime.cpp:112-121:
\*   New path: std::ranges::find(createdDatabases, dbName) != createdDatabases.end()
\*   Only skip check for the specific database that was created
\* We model ALL namespaces as belonging to a single database ("db1") for simplicity.
\* The createdDatabases set tracks which databases the txn created.
DatabaseMetadataCheck(self, req, placementConflictTime, createdDatabases) ==
    IF req.dbVersion # databaseMetadata.dbVersion THEN STALE_DB_VERSION
    \* database_sharding_runtime.cpp:130-131 — skipAtClusterTimeAndPlacementConflictTimeChecks
    \* Per-database bypass: only skip if the database for THIS namespace was created by the txn
    \* Bug Family 3: using "db1" as the database name for all namespaces
    ELSE IF "db1" \in createdDatabases
         THEN OK  \* Bypass placementConflictTime check for created database
    ELSE IF placementConflictTime # -1
            /\ placementConflictTime < databaseMetadata.dbVersion
         THEN SNAPSHOT_INCOMPATIBLE
    ELSE OK

\* collection_sharding_runtime.cpp:640-729 — _getMetadataWithVersionCheckAt
ShardingMetadataCheck(req, placementConflictTime) ==
    LET receivedGen == req.collectionGen
        currentGen == collectionMetadata[req.ns].collectionGen
    IN
    IF receivedGen # currentGen THEN STALE_SHARD_VERSION
    ELSE IF placementConflictTime # -1 /\ placementConflictTime < currentGen
         THEN SNAPSHOT_INCOMPATIBLE
    ELSE OK

\* Local metadata check — UUID consistency
GetSnapshotForNs(snap, ns) == [uuid |-> snap.uuid[ns], data |-> snap.data[ns]]

LocalMetadataCheck(self, req, txnSnapshot) ==
    LET snapshotUUID == txnSnapshot.uuid[req.ns]
        latestUUID == LatestShardNamespaceUUID[req.ns][self]
    IN
    IF snapshotUUID # latestUUID THEN SNAPSHOT_INCOMPATIBLE
    ELSE OK

ResponseFromSnapshot(self, ns, status, txnSnapshot) ==
    [shard    |-> self,
     ns       |-> ns,
     status   |-> status,
     snapshot |-> IF status # OK THEN {} ELSE GetSnapshotForNs(txnSnapshot, ns)]

\* Combined metadata check — orchestrates DB, shard, and local checks
MetadataCheck(self, t, req, txnSnapshot, placementConflictTime, createdDatabases) ==
    LET databaseVersionStatus == DatabaseMetadataCheck(self, req, placementConflictTime, createdDatabases)
        shardVersionStatus == ShardingMetadataCheck(req, placementConflictTime)
        localStatus == LocalMetadataCheck(self, req, txnSnapshot)
    IN
    IF req.collectionGen # UntrackedCollectionGen THEN shardVersionStatus
    ELSE
        IF databaseVersionStatus # OK THEN databaseVersionStatus
        ELSE IF shardVersionStatus # OK THEN shardVersionStatus
        ELSE localStatus

\* ===========================================================================
\* Router Actions
\* ===========================================================================

\* Action: Router sends a transaction statement to owning shards.
\* transaction_router.cpp:954-1001 — attachTxnFieldsIfNeeded
\* transaction_router.cpp:1331-1356 — setDefaultAtClusterTime (first stmt only)
\* Bug Family 3: conditional createdDatabases annotation (cluster_ddl.cpp:129-131)
RouterSendTxnStmt(t, ns) ==
    /\ Len(log[t]) < TXN_STMTS
    /\ rCompletedStmt[t] = Len(log[t])
    /\ ~rCommitSent[t]                      \* Bug Family 5: can't send stmt after commit
    /\ rRetryState[t] # "pending"           \* Bug Family 4: can't send while retry pending
    /\ LET isStartTransaction == (Len(log[t]) = 0)
       IN
       \* transaction_router.cpp:1331-1356 — set placementConflictTime on first stmt
       /\ IF isStartTransaction
          THEN rPlacementConflictTime' = [rPlacementConflictTime EXCEPT ![t] = clusterTime]
          ELSE UNCHANGED rPlacementConflictTime
       \* Refresh database cache — models gossip/background refresh
       \* transaction_router.cpp: router uses CatalogCache which is refreshed via gossip
       /\ \/ rDatabaseCache' = databaseMetadata
          \/ UNCHANGED rDatabaseCache
       \* Refresh collection cache if UNKNOWN
       /\ rCollectionCache' = [rCollectionCache EXCEPT ![ns] =
              IF @.type = UNKNOWN THEN RouterCacheLookup(ns) ELSE @]
       \* Bug Family 3: conditional annotation — only annotate createdDatabases
       \* when database is actually being created (NOT unconditional like original spec line 207)
       \* cluster_ddl.cpp:129-131 — annotateCreatedDatabase called BEFORE create succeeds
       /\ UNCHANGED rCreatedDatabases
       /\ log' = [log EXCEPT ![t] = Append(log[t], TxnStmtLogEntries(t, ns, isStartTransaction))]
    /\ UNCHANGED <<databaseMetadata, collectionMetadata, response, clusterTime, nextUUID,
                   rCompletedStmt, rCommitSent, rRetryState,
                   shard_vars, ddl_vars>>

\* Action: Router annotates a created database — SEPARATE from stmt send
\* cluster_ddl.cpp:129-131 — annotateCreatedDatabase called before _configsvrCreateDatabase
\* Bug Family 3: F3-2 — premature annotation if create fails
RouterAnnotateCreatedDatabase(t, dbName) ==
    /\ Len(log[t]) > 0                     \* Transaction must have started
    /\ ~TxnDone(t)
    /\ ~rCommitSent[t]
    /\ dbName \notin rCreatedDatabases[t]   \* Not already annotated
    /\ rCreatedDatabases' = [rCreatedDatabases EXCEPT ![t] = @ \cup {dbName}]
    /\ UNCHANGED <<global_vars, rDatabaseCache, rCollectionCache, rCompletedStmt,
                   rPlacementConflictTime, rCommitSent, rRetryState,
                   shard_vars, ddl_vars>>

\* Action: Router handles abort — non-OK response from shard
\* transaction_router.cpp:212-231 — RouterHandleAbort
RouterHandleAbort(t, stm) ==
    /\ Cardinality(response[t][stm]) > 0
    /\ rCompletedStmt[t] < stm
    /\ \E rsp \in response[t][stm] :
        /\ rsp.status # OK
        /\ \/ /\ rsp.status = STALE_SHARD_VERSION
              /\ rCollectionCache' = [rCollectionCache EXCEPT ![rsp.ns] = RouterCacheLookup(rsp.ns)]
              /\ UNCHANGED rDatabaseCache
           \/ /\ rsp.status = STALE_DB_VERSION
              /\ rDatabaseCache' = databaseMetadata
              /\ UNCHANGED rCollectionCache
           \/ UNCHANGED <<rDatabaseCache, rCollectionCache>>
    /\ rCompletedStmt' = [rCompletedStmt EXCEPT ![t] = TXN_STMTS]
    /\ shardTxnResources' = ClearResourcesForTxn(t)
    /\ UNCHANGED <<global_vars, rPlacementConflictTime, rCreatedDatabases,
                   rCommitSent, rRetryState, shardData, shardNamespaceUUID, ddl_vars>>

\* Action: Router handles OK response from shard
\* transaction_router.cpp:237-251 — RouterHandleOK
RouterHandleOK(t, stm) ==
    /\ Cardinality(response[t][stm]) > 0
    /\ rCompletedStmt[t] < stm
    /\ stm \in DOMAIN log[t]
    /\ Cardinality(log[t][stm].reqEntries) = Cardinality(response[t][stm])
    /\ \A rsp \in response[t][stm] : rsp.status = OK  \* ALL responses must be OK
    /\ rRetryState[t] # "pending"                      \* Not in stale error retry
    /\ rCompletedStmt' = [rCompletedStmt EXCEPT ![t] = rCompletedStmt[t] + 1]
    /\ IF TxnDone(t)
       THEN shardTxnResources' = ClearResourcesForTxn(t)
       ELSE UNCHANGED shardTxnResources
    /\ UNCHANGED <<global_vars, rDatabaseCache, rCollectionCache, rPlacementConflictTime,
                   rCreatedDatabases, rCommitSent, rRetryState,
                   shardData, shardNamespaceUUID, ddl_vars>>

\* Bug Family 5: Router sends commit — SEPARATE from last statement OK
\* transaction_router.cpp:1598-1630 — commitTransaction
\* transaction_router.cpp:1632-1772 — _commitTransaction (no placement re-check)
\* F2-1: DDL can interleave between last statement OK and commit
RouterSendCommit(t) ==
    /\ ~rCommitSent[t]
    /\ Len(log[t]) = TXN_STMTS
    /\ rCompletedStmt[t] = TXN_STMTS      \* All statements completed
    /\ ~TxnAborted(t)                     \* Transaction not already aborted
    \* transaction_router.cpp:1598-1630 — commit does NOT check placement
    /\ rCommitSent' = [rCommitSent EXCEPT ![t] = TRUE]
    \* Commit clears resources atomically (simplification — actual impl sends
    \* commit to shards, but we model the effect)
    /\ shardTxnResources' = ClearResourcesForTxn(t)
    /\ UNCHANGED <<global_vars, rDatabaseCache, rCollectionCache, rCompletedStmt,
                   rPlacementConflictTime, rCreatedDatabases, rRetryState,
                   shardData, shardNamespaceUUID, ddl_vars>>

\* Bug Family 4: Router receives stale error on first statement — reset and retry
\* transaction_router.cpp:1181-1235 — canContinueOnStaleShardOrDbError + onStaleShardOrDbError
\* transaction_router.cpp:1220-1234 — first stmt: clear participants, reset placementConflictTime
RouterReceiveStaleError(t) ==
    /\ Len(log[t]) = 1                    \* Only first statement can be retried
    /\ rCompletedStmt[t] = 0              \* Statement not yet acknowledged
    /\ rRetryState[t] = "none"            \* Not already retrying
    /\ \E rsp \in response[t][1] :
        /\ rsp.status \in {STALE_SHARD_VERSION, STALE_DB_VERSION}
    \* transaction_router.cpp:1220-1234 — clear pending participants
    /\ shardTxnResources' = ClearResourcesForTxn(t)
    \* transaction_router.cpp:1226-1234 — reset placementConflictTime to uninitialized
    /\ rPlacementConflictTime' = [rPlacementConflictTime EXCEPT ![t] = -1]
    /\ rRetryState' = [rRetryState EXCEPT ![t] = "pending"]
    \* Refresh cache
    /\ \E rsp \in response[t][1] :
        \/ /\ rsp.status = STALE_SHARD_VERSION
           /\ rCollectionCache' = [rCollectionCache EXCEPT ![rsp.ns] = RouterCacheLookup(rsp.ns)]
           /\ UNCHANGED rDatabaseCache
        \/ /\ rsp.status = STALE_DB_VERSION
           /\ rDatabaseCache' = databaseMetadata
           /\ UNCHANGED rCollectionCache
    /\ UNCHANGED <<databaseMetadata, collectionMetadata, clusterTime, nextUUID,
                   rCompletedStmt, rCreatedDatabases, rCommitSent,
                   log, response, shardData, shardNamespaceUUID, ddl_vars>>

\* Bug Family 4: Router retries first statement with fresh placementConflictTime
\* transaction_router.cpp:1331-1356 — setDefaultAtClusterTime (VectorClock::get)
\* F4-1: new time from VectorClock may or may not have gotten DDL gossip
RouterRetryFirstStatement(t, ns) ==
    /\ rRetryState[t] = "pending"
    /\ Len(log[t]) = 1                    \* First statement logged
    \* transaction_router.cpp:1331-1356 — get fresh placementConflictTime
    /\ rPlacementConflictTime' = [rPlacementConflictTime EXCEPT ![t] = clusterTime]
    \* Clear old response
    /\ response' = [response EXCEPT ![t] = [stm \in Stmts |-> {}]]
    \* Refresh caches — models gossip/background refresh
    /\ \/ rDatabaseCache' = databaseMetadata
       \/ UNCHANGED rDatabaseCache
    /\ rCollectionCache' = [rCollectionCache EXCEPT ![ns] =
          IF @.type = UNKNOWN THEN RouterCacheLookup(ns) ELSE @]
    /\ UNCHANGED rCreatedDatabases
    \* Re-send as new first statement (replaces old log entry)
    /\ LET txnCtx == [
            startTransaction |-> TRUE,
            placementConflictTime |-> rPlacementConflictTime'[t],
            createdDatabases |-> rCreatedDatabases[t]
           ]
           owningShards == OwnershipFromCacheEntry(rCollectionCache'[ns], rDatabaseCache')
           collectionGen == rCollectionCache'[ns].collectionGen
           dbVersion == IF collectionGen # UntrackedCollectionGen
                        THEN NoDatabaseVersion ELSE rDatabaseCache'.dbVersion
       IN log' = [log EXCEPT ![t] = <<[reqEntries |->
              {CreateReqEntry(s, ns, dbVersion, collectionGen, txnCtx) : s \in owningShards}]>>]
    /\ rRetryState' = [rRetryState EXCEPT ![t] = "retried"]
    /\ UNCHANGED <<databaseMetadata, collectionMetadata, clusterTime, nextUUID,
                   rCompletedStmt, rCommitSent,
                   shard_vars, ddl_vars>>

\* ===========================================================================
\* Shard Actions
\* ===========================================================================

\* Action: Shard responds to transaction statement.
\* collection_sharding_runtime.cpp:640-729 — _getMetadataWithVersionCheckAt
\* database_sharding_runtime.cpp:229-246 — checkDbVersionOrThrow
\* Bug Family 2: critical section blocks shard responses during DDL
ShardResponse(self, t) ==
    LET stmt == Len(log[t]) IN
    /\ stmt > 0
    /\ ~TxnAborted(t)
    /\ ~\E rsp \in response[t][stmt] : rsp.shard = self
    /\ \E req \in log[t][stmt].reqEntries :
        /\ req.shard = self
        \* Bug Family 1,2: Critical section blocks operations
        \* collection_sharding_runtime.cpp — checkCriticalSectionOrThrow called first
        /\ criticalSection[req.ns] = CS_NONE
        /\ shardTxnResources' = [shardTxnResources EXCEPT
              ![self][t].snapshot = IF DOMAIN(@) = {} THEN CreateTxnSnapshot(self) ELSE @,
              ![self][t].locks[req.ns] = TRUE,
              \* transaction_participant.cpp — store placementConflictTime from first stmt
              ![self][t].placementConflictTime =
                  IF @ = -1 /\ req.txnRuntimeContext.startTransaction
                  THEN req.txnRuntimeContext.placementConflictTime ELSE @,
              \* transaction_participant.cpp:1072-1074 — overwrite createdDatabases
              ![self][t].createdDatabases = req.txnRuntimeContext.createdDatabases]
        /\ LET txnSnapshot == shardTxnResources'[self][t].snapshot
               placementConflictTime == shardTxnResources'[self][t].placementConflictTime
               createdDatabases == shardTxnResources'[self][t].createdDatabases
               rspStatus == MetadataCheck(self, t, req, txnSnapshot,
                                          placementConflictTime, createdDatabases)
           IN response' = [response EXCEPT ![t][stmt] =
                  @ \cup {ResponseFromSnapshot(self, req.ns, rspStatus, txnSnapshot)}]
    /\ UNCHANGED <<databaseMetadata, collectionMetadata, log, clusterTime, nextUUID,
                   router_vars, shardData, shardNamespaceUUID, ddl_vars>>

\* ===========================================================================
\* DDL Actions — Multi-Phase (Bug Family 1)
\* ===========================================================================

\* --- Create Collection (Tracked) ---
\* create_collection_coordinator.cpp phases:
\*   kEnterWriteCSOnCoordinator → kCreateCollectionOnParticipants → kCommitOnShardingCatalog → kExitCS

\* Phase 1: Acquire DDL lock and enter critical section
\* create_collection_coordinator.cpp:1735-1738 — kEnterWriteCriticalSectionOnCoordinator
CreateTrackedAcquireLock(ns) ==
    /\ ~DDLInProgress(ns)
    /\ ~ddlLockHeld[ns]         \* DDL lock not held by another operation (ddl_lock_manager)
    /\ NoMovePrimaryInProgress  \* Database-level DDL lock
    /\ ~NamespaceExists(ns)
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_ACQUIRE_LOCK]
    /\ ddlType' = [ddlType EXCEPT ![ns] = DDL_CREATE_TRACKED]
    /\ ddlLockHeld' = [ddlLockHeld EXCEPT ![ns] = TRUE]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_ACQUIRE_LOCK]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars,
                   criticalSection, ddlPendingMetadata>>

\* Phase 2: Enter critical section on shards — blocks reads/writes
\* create_collection_coordinator.cpp:2032-2058 — kEnterCriticalSection
CreateTrackedEnterCS(ns) ==
    /\ ddlPhase[ns] = PHASE_ACQUIRE_LOCK
    /\ ddlType[ns] = DDL_CREATE_TRACKED
    /\ ddlLockHeld[ns]
    /\ criticalSection' = [criticalSection EXCEPT ![ns] = CS_READWRITE]
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_ENTER_CS]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_ENTER_CS]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars,
                   ddlType, ddlLockHeld, ddlPendingMetadata>>

\* Phase 3: Commit metadata to config server
\* create_collection_coordinator.cpp:2204-2311 — kCommitOnShardingCatalog
CreateTrackedCommitMetadata(ns, distribution) ==
    /\ ddlPhase[ns] = PHASE_ENTER_CS
    /\ ddlType[ns] = DDL_CREATE_TRACKED
    /\ ddlLockHeld[ns]
    \* Commit: write collection metadata + shard data + UUID
    /\ collectionMetadata' = [collectionMetadata EXCEPT ![ns] =
          CreateTrackedCollectionMetadata(NextClusterTime)]
    /\ LET ownership == DistributionToOwnership(distribution) \cup {databaseMetadata.primaryShard}
       IN shardNamespaceUUID' = shardNamespaceUUID @@ [x \in {NextClusterTime} |->
              [LatestShardNamespaceUUID EXCEPT
                  ![ns] = [s \in Shards |->
                      IF s \in ownership THEN nextUUID ELSE DroppedNamespaceUUID]]]
    /\ shardData' = [shardData EXCEPT ![ns] = distribution]
    /\ clusterTime' = NextClusterTime
    /\ nextUUID' = nextUUID + 1
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_COMMIT_METADATA]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_COMMIT_METADATA]
    /\ UNCHANGED <<databaseMetadata, log, response, router_vars, shardTxnResources,
                   ddlType, ddlLockHeld, criticalSection, ddlPendingMetadata>>

\* Phase 4: Exit critical section and release lock
\* create_collection_coordinator.cpp:2384-2414 — kExitCriticalSection
CreateTrackedExitCS(ns) ==
    /\ ddlPhase[ns] = PHASE_COMMIT_METADATA
    /\ ddlType[ns] = DDL_CREATE_TRACKED
    /\ criticalSection' = [criticalSection EXCEPT ![ns] = CS_NONE]
    /\ ddlLockHeld' = [ddlLockHeld EXCEPT ![ns] = FALSE]
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_DONE]
    /\ ddlType' = [ddlType EXCEPT ![ns] = "none"]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_DONE]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars, ddlPendingMetadata>>

\* --- Create Untracked ---
\* Simplified: untracked create is less complex (no config server commit needed)
CreateUntrackedAcquireLock(ns) ==
    /\ ~DDLInProgress(ns)
    /\ ~ddlLockHeld[ns]         \* DDL lock not held by another operation
    /\ NoMovePrimaryInProgress  \* Database-level DDL lock
    /\ ~NamespaceExists(ns)
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_ACQUIRE_LOCK]
    /\ ddlType' = [ddlType EXCEPT ![ns] = DDL_CREATE_UNTRACKED]
    /\ ddlLockHeld' = [ddlLockHeld EXCEPT ![ns] = TRUE]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_ACQUIRE_LOCK]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars,
                   criticalSection, ddlPendingMetadata>>

CreateUntrackedCommit(ns) ==
    /\ ddlPhase[ns] = PHASE_ACQUIRE_LOCK
    /\ ddlType[ns] = DDL_CREATE_UNTRACKED
    /\ ddlLockHeld[ns]
    /\ ~NamespaceExists(ns)
    /\ shardNamespaceUUID' = shardNamespaceUUID @@ [x \in {NextClusterTime} |->
          [LatestShardNamespaceUUID EXCEPT
              ![ns][databaseMetadata.primaryShard] = nextUUID]]
    /\ shardData' = [shardData EXCEPT ![ns][databaseMetadata.primaryShard] = Keys]
    /\ clusterTime' = NextClusterTime
    /\ nextUUID' = nextUUID + 1
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_DONE]
    /\ ddlType' = [ddlType EXCEPT ![ns] = "none"]
    /\ ddlLockHeld' = [ddlLockHeld EXCEPT ![ns] = FALSE]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_DONE]
    /\ UNCHANGED <<databaseMetadata, collectionMetadata, log, response, router_vars,
                   shardTxnResources, criticalSection, ddlPendingMetadata>>

\* --- Drop Collection ---
\* drop_collection_coordinator.cpp:274-429 — kEnterCriticalSection → kReleaseCriticalSection

DropAcquireLock(ns, type) ==
    /\ ~DDLInProgress(ns)
    /\ ~ddlLockHeld[ns]         \* DDL lock not held by another operation
    /\ NoMovePrimaryInProgress  \* Database-level DDL lock
    /\ NamespaceExists(ns)
    /\ collectionMetadata[ns].type = type
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_ACQUIRE_LOCK]
    /\ ddlType' = [ddlType EXCEPT ![ns] = DDL_DROP]
    /\ ddlLockHeld' = [ddlLockHeld EXCEPT ![ns] = TRUE]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_ACQUIRE_LOCK]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars,
                   criticalSection, ddlPendingMetadata>>

\* drop_collection_coordinator.cpp:274-293 — kEnterCriticalSection
DropEnterCS(ns) ==
    /\ ddlPhase[ns] = PHASE_ACQUIRE_LOCK
    /\ ddlType[ns] = DDL_DROP
    /\ ddlLockHeld[ns]
    /\ criticalSection' = [criticalSection EXCEPT ![ns] = CS_READWRITE]
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_ENTER_CS]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_ENTER_CS]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars,
                   ddlType, ddlLockHeld, ddlPendingMetadata>>

\* drop_collection_coordinator.cpp:295-429 — kDropCollection (metadata removed then data dropped)
DropCommitMetadata(ns) ==
    /\ ddlPhase[ns] = PHASE_ENTER_CS
    /\ ddlType[ns] = DDL_DROP
    /\ ddlLockHeld[ns]
    \* Remove metadata + data
    /\ collectionMetadata' = [collectionMetadata EXCEPT ![ns] = UntrackedClusterMetadata]
    /\ shardNamespaceUUID' = shardNamespaceUUID @@ [x \in {NextClusterTime} |->
          [LatestShardNamespaceUUID EXCEPT
              ![ns] = [s \in Shards |-> DroppedNamespaceUUID]]]
    /\ shardData' = [shardData EXCEPT ![ns] = [s \in Shards |-> {}]]
    /\ clusterTime' = NextClusterTime
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_COMMIT_METADATA]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_COMMIT_METADATA]
    /\ UNCHANGED <<databaseMetadata, log, response, nextUUID, router_vars,
                   shardTxnResources, ddlType, ddlLockHeld, criticalSection, ddlPendingMetadata>>

\* drop_collection_coordinator.cpp:431-450 — kReleaseCriticalSection
DropExitCS(ns) ==
    /\ ddlPhase[ns] = PHASE_COMMIT_METADATA
    /\ ddlType[ns] = DDL_DROP
    /\ criticalSection' = [criticalSection EXCEPT ![ns] = CS_NONE]
    /\ ddlLockHeld' = [ddlLockHeld EXCEPT ![ns] = FALSE]
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_DONE]
    /\ ddlType' = [ddlType EXCEPT ![ns] = "none"]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_DONE]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars, ddlPendingMetadata>>

\* --- Rename Collection ---
\* rename_collection_coordinator.cpp:900-1089 — kBlockCrudAndRename → kUnblockCRUD

RenameAcquireLock(from, to, type) ==
    /\ ~DDLInProgress(from) /\ ~DDLInProgress(to)
    /\ ~ddlLockHeld[from] /\ ~ddlLockHeld[to]  \* DDL locks not held
    /\ NoMovePrimaryInProgress  \* Database-level DDL lock
    /\ from # to
    /\ NamespaceExists(from)
    /\ ~NamespaceExists(to)
    /\ collectionMetadata[from].type = type
    /\ ddlPhase' = [ddlPhase EXCEPT ![from] = PHASE_ACQUIRE_LOCK]
    /\ ddlType' = [ddlType EXCEPT ![from] = DDL_RENAME]
    /\ ddlLockHeld' = [ddlLockHeld EXCEPT ![from] = TRUE, ![to] = TRUE]
    /\ ddlPendingMetadata' = [ddlPendingMetadata EXCEPT ![from] = <<to, type>>]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![from] = PHASE_ACQUIRE_LOCK]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars, criticalSection>>

\* rename_collection_coordinator.cpp:900-969 — kBlockCrudAndRename
RenameEnterCS(ns) ==
    /\ ddlPhase[ns] = PHASE_ACQUIRE_LOCK
    /\ ddlType[ns] = DDL_RENAME
    /\ ddlLockHeld[ns]
    /\ ddlPendingMetadata[ns] # <<>>
    /\ LET to == ddlPendingMetadata[ns][1] IN
       /\ criticalSection' = [criticalSection EXCEPT ![ns] = CS_READWRITE, ![to] = CS_READWRITE]
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_ENTER_CS]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_ENTER_CS]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars,
                   ddlType, ddlLockHeld, ddlPendingMetadata>>

\* rename_collection_coordinator.cpp:971-1051 — kRenameMetadata
RenameCommitMetadata(ns) ==
    /\ ddlPhase[ns] = PHASE_ENTER_CS
    /\ ddlType[ns] = DDL_RENAME
    /\ ddlLockHeld[ns]
    /\ ddlPendingMetadata[ns] # <<>>
    /\ LET to == ddlPendingMetadata[ns][1]
           type == ddlPendingMetadata[ns][2]
       IN
       \* Move UUID and data from source to target
       /\ shardNamespaceUUID' = shardNamespaceUUID @@ [x \in {NextClusterTime} |->
              [LatestShardNamespaceUUID EXCEPT
                  ![to] = [s \in Shards |-> LatestShardNamespaceUUID[ns][s]],
                  ![ns] = [s \in Shards |-> DroppedNamespaceUUID]]]
       /\ shardData' = [shardData EXCEPT ![to] = shardData[ns],
                                         ![ns] = [s \in Shards |-> {}]]
       \* Update collection metadata
       /\ IF type = TRACKED
          THEN collectionMetadata' = [collectionMetadata EXCEPT
                  ![to] = CreateTrackedCollectionMetadata(NextClusterTime),
                  ![ns] = UntrackedClusterMetadata]
          ELSE UNCHANGED collectionMetadata
    /\ clusterTime' = NextClusterTime
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_COMMIT_METADATA]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_COMMIT_METADATA]
    /\ UNCHANGED <<databaseMetadata, log, response, nextUUID, router_vars,
                   shardTxnResources, ddlType, ddlLockHeld, criticalSection, ddlPendingMetadata>>

\* rename_collection_coordinator.cpp:1054-1089 — kUnblockCRUD
RenameExitCS(ns) ==
    /\ ddlPhase[ns] = PHASE_COMMIT_METADATA
    /\ ddlType[ns] = DDL_RENAME
    /\ ddlPendingMetadata[ns] # <<>>
    /\ LET to == ddlPendingMetadata[ns][1] IN
       /\ criticalSection' = [criticalSection EXCEPT ![ns] = CS_NONE, ![to] = CS_NONE]
    /\ ddlLockHeld' = [ddlLockHeld EXCEPT ![ns] = FALSE,
          ![ddlPendingMetadata[ns][1]] = FALSE]
    /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_DONE]
    /\ ddlType' = [ddlType EXCEPT ![ns] = "none"]
    /\ ddlPendingMetadata' = [ddlPendingMetadata EXCEPT ![ns] = <<>>]
    /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_DONE]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars>>

\* --- MovePrimary ---
\* move_primary_coordinator.cpp:278-348 — kClone → kExitCriticalSection

IsUntrackedAndExists(ns) ==
    /\ collectionMetadata[ns].type = UNTRACKED
    /\ LatestShardNamespaceUUID[ns][databaseMetadata.primaryShard] # DroppedNamespaceUUID

MovePrimaryAcquireLock(toShard) ==
    LET fromShard == databaseMetadata.primaryShard IN
    /\ toShard # fromShard
    /\ \A ns \in NameSpaces : ~DDLInProgress(ns)
    /\ ddlPhase' = [ns \in NameSpaces |->
          IF IsUntrackedAndExists(ns) THEN PHASE_ACQUIRE_LOCK ELSE ddlPhase[ns]]
    /\ ddlType' = [ns \in NameSpaces |->
          IF IsUntrackedAndExists(ns) THEN DDL_MOVE ELSE ddlType[ns]]
    /\ ddlLockHeld' = [ns \in NameSpaces |->
          IF IsUntrackedAndExists(ns) THEN TRUE ELSE ddlLockHeld[ns]]
    /\ ddlPendingMetadata' = [ns \in NameSpaces |->
          IF IsUntrackedAndExists(ns) THEN <<toShard>> ELSE ddlPendingMetadata[ns]]
    /\ ddlPersistedPhase' = [ns \in NameSpaces |->
          IF IsUntrackedAndExists(ns) THEN PHASE_ACQUIRE_LOCK ELSE ddlPersistedPhase[ns]]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars, criticalSection>>

\* move_primary_coordinator.cpp:289 — kEnterCriticalSection (block reads/writes)
MovePrimaryEnterCS(toShard) ==
    LET nsToMove == {ns \in NameSpaces : ddlType[ns] = DDL_MOVE /\ ddlPhase[ns] = PHASE_ACQUIRE_LOCK}
    IN
    /\ nsToMove # {}
    /\ criticalSection' = [ns \in NameSpaces |->
          IF ns \in nsToMove THEN CS_READWRITE ELSE criticalSection[ns]]
    /\ ddlPhase' = [ns \in NameSpaces |->
          IF ns \in nsToMove THEN PHASE_ENTER_CS ELSE ddlPhase[ns]]
    /\ ddlPersistedPhase' = [ns \in NameSpaces |->
          IF ns \in nsToMove THEN PHASE_ENTER_CS ELSE ddlPersistedPhase[ns]]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars,
                   ddlType, ddlLockHeld, ddlPendingMetadata>>

\* move_primary_coordinator.cpp:311 — kCommit (commit metadata + move data)
MovePrimaryCommitMetadata(toShard) ==
    LET nsToMove == {ns \in NameSpaces : ddlType[ns] = DDL_MOVE /\ ddlPhase[ns] = PHASE_ENTER_CS}
        fromShard == databaseMetadata.primaryShard
    IN
    /\ nsToMove # {}
    /\ toShard # fromShard
    /\ LET uuidSet == nextUUID..(nextUUID + Cardinality(nsToMove))
           newUUIDForNs == CHOOSE s \in [nsToMove -> uuidSet] : IsInjective(s)
       IN
       /\ shardNamespaceUUID' = shardNamespaceUUID @@ [x \in {NextClusterTime} |->
              [ns \in NameSpaces |->
                  IF ns \in nsToMove
                  THEN [s \in Shards |->
                      IF s = toShard THEN newUUIDForNs[ns] ELSE DroppedNamespaceUUID]
                  ELSE [s \in Shards |->
                      IF s = toShard THEN LatestUUIDForNameSpace(ns)
                      ELSE LatestShardNamespaceUUID[ns][s]]]]
       /\ nextUUID' = nextUUID + Cardinality(nsToMove)
    /\ shardData' = [ns \in NameSpaces |->
          IF ns \in nsToMove
          THEN [shardData[ns] EXCEPT ![fromShard] = {}, ![toShard] = shardData[ns][fromShard]]
          ELSE shardData[ns]]
    /\ databaseMetadata' = [primaryShard |-> toShard, dbVersion |-> NextClusterTime]
    /\ clusterTime' = NextClusterTime
    /\ ddlPhase' = [ns \in NameSpaces |->
          IF ns \in nsToMove THEN PHASE_COMMIT_METADATA ELSE ddlPhase[ns]]
    /\ ddlPersistedPhase' = [ns \in NameSpaces |->
          IF ns \in nsToMove THEN PHASE_COMMIT_METADATA ELSE ddlPersistedPhase[ns]]
    /\ UNCHANGED <<collectionMetadata, log, response, router_vars, shardTxnResources,
                   ddlType, ddlLockHeld, criticalSection, ddlPendingMetadata>>

\* move_primary_coordinator.cpp:340-357 — kExitCriticalSection
MovePrimaryExitCS(toShard) ==
    LET nsToMove == {ns \in NameSpaces : ddlType[ns] = DDL_MOVE /\ ddlPhase[ns] = PHASE_COMMIT_METADATA}
    IN
    /\ nsToMove # {}
    /\ criticalSection' = [ns \in NameSpaces |->
          IF ns \in nsToMove THEN CS_NONE ELSE criticalSection[ns]]
    /\ ddlLockHeld' = [ns \in NameSpaces |->
          IF ns \in nsToMove THEN FALSE ELSE ddlLockHeld[ns]]
    /\ ddlPhase' = [ns \in NameSpaces |->
          IF ns \in nsToMove THEN PHASE_DONE ELSE ddlPhase[ns]]
    /\ ddlType' = [ns \in NameSpaces |->
          IF ns \in nsToMove THEN "none" ELSE ddlType[ns]]
    /\ ddlPendingMetadata' = [ns \in NameSpaces |->
          IF ns \in nsToMove THEN <<>> ELSE ddlPendingMetadata[ns]]
    /\ ddlPersistedPhase' = [ns \in NameSpaces |->
          IF ns \in nsToMove THEN PHASE_DONE ELSE ddlPersistedPhase[ns]]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars>>

\* ===========================================================================
\* DDL Failover (Bug Family 1)
\* ===========================================================================

\* DDL coordinator failover — in-memory DDL locks are lost
\* sharding_coordinator.cpp:477-503 — recovery loop
\* ddl_lock_manager.h:73 — DDL locks are in-memory only, lost on failover
\* F1-1: DDL failover between commit-metadata and release-lock
DDLFailover(ns) ==
    /\ DDLInProgress(ns)
    /\ ddlType[ns] # DDL_MOVE    \* MovePrimary has its own failover (single coordinator)
    \* Two recovery outcomes:
    /\ \/ \* Outcome A: Recovery succeeds — restart from persisted phase
          \* DDL lock lost momentarily then re-acquired (SERVER-88147 window)
          /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = ddlPersistedPhase[ns]]
          /\ ddlLockHeld' = [ddlLockHeld EXCEPT ![ns] = TRUE]
          /\ UNCHANGED <<criticalSection, ddlType, ddlPendingMetadata, ddlPersistedPhase>>
       \/ \* Outcome B: Recovery aborts DDL — cleanup releases everything
          \* create_collection_coordinator.cpp:2416-2488 — _cleanupOnAbort
          \* Only possible in early phases (before metadata commit)
          /\ ddlPersistedPhase[ns] \in {PHASE_ACQUIRE_LOCK, PHASE_ENTER_CS}
          /\ ddlPhase' = [ddlPhase EXCEPT ![ns] = PHASE_DONE]
          /\ ddlType' = [ddlType EXCEPT ![ns] = "none"]
          /\ ddlPersistedPhase' = [ddlPersistedPhase EXCEPT ![ns] = PHASE_DONE]
          \* Clean up CS + locks for this namespace AND rename target if applicable
          /\ IF ddlPendingMetadata[ns] # <<>>
             THEN LET target == ddlPendingMetadata[ns][1] IN
                  /\ ddlLockHeld' = [ddlLockHeld EXCEPT ![ns] = FALSE, ![target] = FALSE]
                  /\ criticalSection' = [criticalSection EXCEPT ![ns] = CS_NONE, ![target] = CS_NONE]
                  /\ ddlPendingMetadata' = [ddlPendingMetadata EXCEPT ![ns] = <<>>]
             ELSE /\ ddlLockHeld' = [ddlLockHeld EXCEPT ![ns] = FALSE]
                  /\ criticalSection' = [criticalSection EXCEPT ![ns] = CS_NONE]
                  /\ ddlPendingMetadata' = [ddlPendingMetadata EXCEPT ![ns] = <<>>]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars>>

\* MovePrimary failover — affects ALL namespaces being moved atomically
\* move_primary_coordinator.cpp:363-376 — single coordinator for all namespaces
MovePrimaryFailover ==
    LET moveNs == {n \in NameSpaces : ddlType[n] = DDL_MOVE} IN
    /\ moveNs # {}
    /\ \/ \* Outcome A: Recovery succeeds — restart all from persisted phase
          /\ ddlPhase' = [n \in NameSpaces |->
                IF n \in moveNs THEN ddlPersistedPhase[n] ELSE ddlPhase[n]]
          /\ ddlLockHeld' = [n \in NameSpaces |->
                IF n \in moveNs THEN TRUE ELSE ddlLockHeld[n]]
          /\ UNCHANGED <<criticalSection, ddlType, ddlPendingMetadata, ddlPersistedPhase>>
       \/ \* Outcome B: Recovery aborts — all move namespaces cleaned up
          /\ \A n \in moveNs : ddlPersistedPhase[n] \in {PHASE_ACQUIRE_LOCK, PHASE_ENTER_CS}
          /\ ddlPhase' = [n \in NameSpaces |->
                IF n \in moveNs THEN PHASE_DONE ELSE ddlPhase[n]]
          /\ ddlType' = [n \in NameSpaces |->
                IF n \in moveNs THEN "none" ELSE ddlType[n]]
          /\ ddlPersistedPhase' = [n \in NameSpaces |->
                IF n \in moveNs THEN PHASE_DONE ELSE ddlPersistedPhase[n]]
          /\ ddlLockHeld' = [n \in NameSpaces |->
                IF n \in moveNs THEN FALSE ELSE ddlLockHeld[n]]
          /\ criticalSection' = [n \in NameSpaces |->
                IF n \in moveNs THEN CS_NONE ELSE criticalSection[n]]
          /\ ddlPendingMetadata' = [n \in NameSpaces |->
                IF n \in moveNs THEN <<>> ELSE ddlPendingMetadata[n]]
    /\ UNCHANGED <<global_vars, router_vars, shard_vars>>

\* ===========================================================================
\* Next State Relation
\* ===========================================================================

Next ==
    \* Router actions
    \/ \E t \in Txns, ns \in NameSpaces : RouterSendTxnStmt(t, ns)
    \/ \E t \in Txns, dbName \in DatabaseNames : RouterAnnotateCreatedDatabase(t, dbName)
    \/ \E t \in Txns, stm \in Stmts : RouterHandleAbort(t, stm)
    \/ \E t \in Txns, stm \in Stmts : RouterHandleOK(t, stm)
    \/ \E t \in Txns : RouterSendCommit(t)
    \/ \E t \in Txns : RouterReceiveStaleError(t)
    \/ \E t \in Txns, ns \in NameSpaces : RouterRetryFirstStatement(t, ns)
    \* Shard actions
    \/ \E s \in Shards, t \in Txns : ShardResponse(s, t)
    \* DDL actions — Create (tracked, multi-phase)
    \/ \E ns \in NameSpaces : CreateTrackedAcquireLock(ns)
    \/ \E ns \in NameSpaces : CreateTrackedEnterCS(ns)
    \/ \E ns \in NameSpaces, d \in ValidDataDistributions : CreateTrackedCommitMetadata(ns, d)
    \/ \E ns \in NameSpaces : CreateTrackedExitCS(ns)
    \* DDL actions — Create (untracked)
    \/ \E ns \in NameSpaces : CreateUntrackedAcquireLock(ns)
    \/ \E ns \in NameSpaces : CreateUntrackedCommit(ns)
    \* DDL actions — Drop (multi-phase)
    \/ \E ns \in NameSpaces : DropAcquireLock(ns, TRACKED)
    \/ \E ns \in NameSpaces : DropAcquireLock(ns, UNTRACKED)
    \/ \E ns \in NameSpaces : DropEnterCS(ns)
    \/ \E ns \in NameSpaces : DropCommitMetadata(ns)
    \/ \E ns \in NameSpaces : DropExitCS(ns)
    \* DDL actions — Rename (multi-phase)
    \/ \E from, to \in NameSpaces : RenameAcquireLock(from, to, TRACKED)
    \/ \E from, to \in NameSpaces : RenameAcquireLock(from, to, UNTRACKED)
    \/ \E ns \in NameSpaces : RenameEnterCS(ns)
    \/ \E ns \in NameSpaces : RenameCommitMetadata(ns)
    \/ \E ns \in NameSpaces : RenameExitCS(ns)
    \* DDL actions — MovePrimary (multi-phase)
    \/ \E to \in Shards : MovePrimaryAcquireLock(to)
    \/ \E to \in Shards : MovePrimaryEnterCS(to)
    \/ \E to \in Shards : MovePrimaryCommitMetadata(to)
    \/ \E to \in Shards : MovePrimaryExitCS(to)
    \* DDL Failover (Bug Family 1)
    \/ \E ns \in NameSpaces : DDLFailover(ns)
    \/ MovePrimaryFailover
    \* Termination — allow infinite stuttering
    \/ (\A t \in Txns : rCompletedStmt[t] = TXN_STMTS /\ UNCHANGED vars)

\* ===========================================================================
\* Fairness and Spec
\* ===========================================================================

Fairness ==
    /\ WF_vars(\E t \in Txns, ns \in NameSpaces : RouterSendTxnStmt(t, ns))
    /\ WF_vars(\E t \in Txns, stm \in Stmts : RouterHandleAbort(t, stm))
    /\ WF_vars(\E t \in Txns, stm \in Stmts : RouterHandleOK(t, stm))
    /\ WF_vars(\E t \in Txns : RouterSendCommit(t))
    /\ WF_vars(\E s \in Shards, t \in Txns : ShardResponse(s, t))
    \* DDL phases have fairness so they eventually complete
    /\ WF_vars(\E ns \in NameSpaces : CreateTrackedEnterCS(ns))
    /\ WF_vars(\E ns \in NameSpaces, d \in ValidDataDistributions : CreateTrackedCommitMetadata(ns, d))
    /\ WF_vars(\E ns \in NameSpaces : CreateTrackedExitCS(ns))
    /\ WF_vars(\E ns \in NameSpaces : CreateUntrackedCommit(ns))
    /\ WF_vars(\E ns \in NameSpaces : DropEnterCS(ns))
    /\ WF_vars(\E ns \in NameSpaces : DropCommitMetadata(ns))
    /\ WF_vars(\E ns \in NameSpaces : DropExitCS(ns))
    /\ WF_vars(\E ns \in NameSpaces : RenameEnterCS(ns))
    /\ WF_vars(\E ns \in NameSpaces : RenameCommitMetadata(ns))
    /\ WF_vars(\E ns \in NameSpaces : RenameExitCS(ns))
    /\ WF_vars(\E to \in Shards : MovePrimaryEnterCS(to))
    /\ WF_vars(\E to \in Shards : MovePrimaryCommitMetadata(to))
    /\ WF_vars(\E to \in Shards : MovePrimaryExitCS(to))

Spec == /\ Init /\ [][Next]_vars /\ Fairness

\* ===========================================================================
\* Invariants
\* ===========================================================================

\* --- Standard safety invariants (from original spec) ---

\* All committed txn statements returned OK
CommittedTxnImpliesAllStmtsSuccessful ==
    \A t \in Txns : TxnCommitted(t) =>
        \A s \in Stmts : \A rsp \in response[t][s] : rsp.status = OK

\* Committed txn has consistent UUIDs and data across shards
UnionCompleteIntersectionNull(keySets) ==
    /\ UNION keySets = Keys
    /\ \A ks1, ks2 \in keySets : ks1 = ks2 \/ ks1 \cap ks2 = {}

StmtResponseDataCompleteAndUnique(stmtRsp) ==
    UnionCompleteIntersectionNull({rsp.snapshot.data : rsp \in stmtRsp})

StmtResponsesHaveConsistentKeySet(t, stmt) ==
    LET txnUUIDs == {rsp.snapshot.uuid : rsp \in response[t][stmt]}
        isDropUUID == \E uid \in txnUUIDs : uid = DroppedNamespaceUUID
    IN
    /\ Cardinality(txnUUIDs) = 1
    /\ IF ~isDropUUID THEN StmtResponseDataCompleteAndUnique(response[t][stmt])
       ELSE \A rsp \in response[t][stmt] : rsp.snapshot.data = {}

CommittedTxnImpliesConsistentKeySet ==
    \A t \in Txns : TxnCommitted(t) =>
        \A stmt \in Stmts : StmtResponsesHaveConsistentKeySet(t, stmt)

\* Shard data consistent with UUID
ShardDataConsistentWithUUID ==
    \A ns \in NameSpaces :
        /\ (\A s \in Shards : shardData[ns][s] = {}) <=>
           (\A s \in Shards : LatestShardNamespaceUUID[ns][s] = DroppedNamespaceUUID)
        /\ (\E s \in Shards : shardData[ns][s] # {}) <=>
           LatestShardNamespaceUUID[ns][databaseMetadata.primaryShard] # DroppedNamespaceUUID

\* Router sends at most one statement request per shard
RouterSendsOneStmtRequestPerShard ==
    \A txn \in Txns :
        \A i \in DOMAIN(log[txn]) :
            LET stmtReqs == log[txn][i].reqEntries
            IN \A s \in Shards : Cardinality({entry \in stmtReqs : entry.shard = s}) <= 1

\* --- Bug Family 1: DDL Lock invariants ---

\* DDL lock must be held whenever metadata is being committed to config server
\* F1-1: DDL failover between commit-metadata and release-lock
DDLLockHeldDuringCommit ==
    \A ns \in NameSpaces :
        ddlPhase[ns] = PHASE_COMMIT_METADATA => ddlLockHeld[ns]

\* No orphaned critical section without DDL in progress
\* After DDL failover recovery, CS should be consistent with DDL state
\* Exception: rename target ns has CS but its DDL phase is managed by the source ns
NoOrphanedCriticalSection ==
    \A ns \in NameSpaces :
        criticalSection[ns] # CS_NONE =>
            \/ DDLInProgress(ns)
            \/ \E src \in NameSpaces :
                /\ ddlType[src] = DDL_RENAME
                /\ ddlPendingMetadata[src] # <<>>
                /\ ddlPendingMetadata[src][1] = ns

\* --- Bug Family 2: Transaction-DDL interleaving invariants ---

\* If all statements passed placement checks, committed txn is consistent
\* F2-1: DDL between last statement and commit
CommitSafeAfterStatements ==
    \A t \in Txns : TxnCommitted(t) =>
        CommittedTxnImpliesConsistentKeySet

\* --- Bug Family 3: createdDatabases bypass invariants ---

\* createdDatabases bypass only skips check for databases actually created by this txn
\* F3-1: legacy all-or-nothing bypass allows stale read on unrelated database
NoCrossDatabaseBypassLeak ==
    \A t \in Txns :
        \A s \in Shards :
            LET res == shardTxnResources[s][t] IN
            \A db \in res.createdDatabases :
                db \in DatabaseNames

\* --- Bug Family 4: Stale error retry invariants ---

\* After retry, new placementConflictTime >= any DDL commit time
\* F4-1: reset captures time before DDL gossip arrives
PlacementConflictTimeMonotonicity ==
    \A t \in Txns :
        rRetryState[t] = "retried" =>
            rPlacementConflictTime[t] >= INITIAL_CLUSTER_TIME

\* --- Bug Family 5: Commit safety invariants ---

\* Commit without re-check is safe if snapshot isolation + locks protect data
\* (This is the design assumption we're testing)
CommittedTxnConsistentKeySet == CommittedTxnImpliesConsistentKeySet

\* --- Structural invariants ---

\* DDL phase consistency: if DDL is in progress, type is set
DDLPhaseTypeConsistency ==
    \A ns \in NameSpaces :
        /\ (ddlPhase[ns] # PHASE_DONE) => (ddlType[ns] # "none")
        /\ (ddlPhase[ns] = PHASE_DONE) => (ddlType[ns] = "none")

\* Critical section only active during DDL enter-CS or commit-metadata phases
\* Note: Rename creates CS on both source and target; target's DDL phase stays DONE
\* but it is referenced in source's ddlPendingMetadata
CriticalSectionPhaseConsistency ==
    \A ns \in NameSpaces :
        criticalSection[ns] # CS_NONE =>
            \/ ddlPhase[ns] \in {PHASE_ENTER_CS, PHASE_COMMIT_METADATA}
            \/ \* ns is a rename target — source holds the DDL state
               \E src \in NameSpaces :
                   /\ ddlType[src] = DDL_RENAME
                   /\ ddlPendingMetadata[src] # <<>>
                   /\ ddlPendingMetadata[src][1] = ns
                   /\ ddlPhase[src] \in {PHASE_ENTER_CS, PHASE_COMMIT_METADATA}

\* --- Liveness ---
AllTxnsEventuallyDone == <>[] \A t \in Txns : TxnDone(t)

====
