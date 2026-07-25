--------------------------------- MODULE base ----------------------------------
\* TLA+ specification for MongoDB multi-statement transactions during chunk
\* range migration.  Extends the existing TxnsMoveRange.tla (327 lines) which
\* models MoveRange as atomic and has already been model-checked by MongoDB.
\*
\* This spec targets the GAPS in the existing spec:
\*   Family 1 — Non-atomic migration (critical-section windows)
\*   Family 2 — placementConflictTime propagation & router retry
\*   Family 3 — Donor failover during migration with active transactions
\*   Family 4 — Stale-routing error propagation (write-then-error)
\*   Family 5 — kSingleWriteShard commit atomicity gap
\*
\* Reference: case-studies/mongodb-txnsmoverange/modeling-brief.md

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Shards,       \* Set of shard identifiers
    Keys,         \* Set of keys (routing granularity)
    NameSpaces,   \* Set of namespaces (collections)
    Txns,         \* Set of transaction identifiers
    MIGRATIONS,   \* Max number of migrations (counter bound)
    TXN_STMTS     \* Number of statements per transaction

ASSUME Cardinality(Shards) > 1
ASSUME Cardinality(Keys) > 0
ASSUME Cardinality(NameSpaces) > 0
ASSUME Cardinality(Txns) > 0
ASSUME MIGRATIONS \in 0..100
ASSUME TXN_STMTS \in 1..100

\* ============================================================================
\* Status and phase constants
\* ============================================================================

\* Response status
staleRouter         == "staleRouter"       \* StaleConfig / critical section
migrationConflict   == "migrationConflict" \* placementConflictTime violation
ok                  == "ok"

\* Migration phases  (Family 1: migration_source_manager.cpp 6-step protocol)
MigIdle       == "Idle"         \* No active migration
MigCritSec    == "CritSec"     \* Critical section active on donor
                                \* (migration_source_manager.cpp:550-593)
MigCommitted  == "Committed"   \* Config server committed, CS still active
                                \* (migration_coordinator.cpp:183-229)

\* Coordinator document states  (Family 3: migration_coordinator.cpp)
DocNone       == "NoDoc"       \* No coordinator doc
DocPending    == "Pending"     \* Doc written, no decision yet
DocCommitted  == "Committed"   \* Commit decision persisted
DocAborted    == "Aborted"     \* Abort decision persisted

\* Timestamp domain
INIT_MIGRATION_TS   == 100
MIGRATION_TS_DOMAIN == INIT_MIGRATION_TS .. INIT_MIGRATION_TS + MIGRATIONS

Stmts == 1..TXN_STMTS
Status == {staleRouter, migrationConflict, ok}
DatabaseNames == {"db"}

\* ============================================================================
\* Record types and pure helpers (no variable references)
\* ============================================================================

\* Transaction runtime context — sent with every request
\* transaction_router.cpp:2559-2649 (start), :626-699 (continue)
TxnRuntimeContext == [
    startTransaction:      BOOLEAN,
    placementConflictTime: Int,
    createdDatabases:      SUBSET DatabaseNames
]

\* Shard-side per-txn resources
\* transaction_participant.cpp:1056-1070
EmptyTxnResources == [placementConflictTime |-> -1, createdDatabases |-> {}]

\* Request entry: router -> shard
ReqEntry == [s: Shards, ns: NameSpaces, k: Keys, v: 0..MIGRATIONS,
             txnRuntimeContext: TxnRuntimeContext]

CreateReq(s, ns, k, v, txnCtx) ==
    [s |-> s, ns |-> ns, k |-> k, v |-> v, txnRuntimeContext |-> txnCtx]

\* Response entry: shard -> router
RspEntry == [rsp: Status, found: {TRUE, FALSE}]
CreateRsp(rsp, found) == [rsp |-> rsp, found |-> found]
HasResponse(stmt) == Cardinality(DOMAIN stmt) # 0

Max(S) == CHOOSE x \in S : \A y \in S : x >= y

\* ============================================================================
\* Variables  (declared BEFORE helpers that reference them)
\* ============================================================================

\* --- Global state ---
VARIABLE ranges              \* [NameSpaces -> [Keys -> Shards]]
VARIABLE versions            \* [Shards -> [NameSpaces -> Nat]]

\* --- Network ---
VARIABLE request             \* [Txns -> Seq(ReqEntry)]
VARIABLE response            \* [Txns -> [Stmts -> RspEntry | <<>>]]

\* --- Router state ---
VARIABLE rCachedRanges       \* [NameSpaces -> [Keys -> Shards]]
VARIABLE rCachedVersions     \* [NameSpaces -> [Shards -> Nat]]
VARIABLE rCompletedStmt      \* [Txns -> 0..TXN_STMTS]
VARIABLE rPlacementConflictTime \* [Txns -> Int]
VARIABLE rCreatedDatabases   \* [Txns -> SUBSET DatabaseNames]

\* --- Shard state ---
VARIABLE shardLastMigrationTs \* [Shards -> [NameSpaces -> Nat]]
VARIABLE shardSnapshotted    \* [Shards -> [Txns -> BOOLEAN]]
VARIABLE shardSnapshot       \* [Shards -> [Txns -> [NameSpaces -> SUBSET Keys]]]
VARIABLE shardLocked         \* [Shards -> [Txns -> [NameSpaces -> BOOLEAN]]]
VARIABLE shardTxnResources   \* [Shards -> [Txns -> TxnResources]]

\* --- Migration state (Family 1) ---
VARIABLE migrationPhase      \* [NameSpaces -> MigPhase]
VARIABLE migrationFrom       \* [NameSpaces -> Shards]   (donor)
VARIABLE migrationTo         \* [NameSpaces -> Shards]   (recipient)
VARIABLE migrationKey        \* [NameSpaces -> Keys]     (key being migrated)
VARIABLE coordinatorDoc      \* [NameSpaces -> DocState]  (Family 3)
VARIABLE migrations          \* Nat (counter)

\* --- Failover state (Family 3) ---
VARIABLE donorAlive          \* [Shards -> BOOLEAN]

\* --- Error tracking (Family 4) ---
VARIABLE execCount           \* [Txns -> [Stmts -> 0..2]]

\* --- Variable groups for UNCHANGED ---
globalVars   == <<ranges, versions>>
networkVars  == <<request, response>>
routerVars   == <<rCachedRanges, rCachedVersions, rCompletedStmt,
                  rPlacementConflictTime, rCreatedDatabases>>
shardVars    == <<shardSnapshotted, shardSnapshot, shardTxnResources, shardLocked>>
migStateVars == <<migrationPhase, migrationFrom, migrationTo, migrationKey,
                  coordinatorDoc, migrations>>

vars == <<globalVars, networkVars, routerVars, shardVars, shardLastMigrationTs,
          migStateVars, donorAlive, execCount>>

\* ============================================================================
\* Helpers (reference variables — must follow VARIABLE declarations)
\* ============================================================================

\* Critical section check  (Family 1)
\* collection_sharding_runtime.cpp:617-639 — CS blocks operations on donor
IsCritSecActive(s, ns) ==
    /\ migrationPhase[ns] \in {MigCritSec, MigCommitted}
    /\ migrationFrom[ns] = s

\* Response status determination
\* collection_sharding_runtime.cpp:617-686 (CS + version + PCT checks)
\* database_sharding_runtime.cpp:103-149  (createdDatabases exemption)
RespondStatus(self, ns, k, receivedV, shardV, pct, lastMigTs, createdDbs) ==
    \* 1. Critical section check (Family 1)
    \*    collection_sharding_runtime.cpp:617-639
    IF IsCritSecActive(self, ns) THEN staleRouter
    \* 2. Chunk ownership check
    \*    Shard verifies it owns the requested chunk — part of placement version
    \*    check in collection_sharding_runtime.cpp:649-671
    ELSE IF ranges[ns][k] # self THEN staleRouter
    \* 3. Placement version check
    \*    collection_sharding_runtime.cpp:649-671
    ELSE IF receivedV < shardV THEN staleRouter
    \* 4. placementConflictTime check (collection-level)
    \*    collection_sharding_runtime.cpp:676-677
    \*    NOTE: createdDatabases exemption (database_sharding_runtime.cpp:112-114)
    \*    only applies to DATABASE-level movePrimary checks, NOT to collection-level
    \*    chunk migration checks. Removed from here per code analysis.
    ELSE IF pct # -1 /\ pct < lastMigTs THEN migrationConflict
    \* 5. All checks passed
    ELSE ok

\* Latest migration timestamp across all shards/namespaces
LatestMigrationTs == Max(UNION {{shardLastMigrationTs[n][x] :
                                    x \in DOMAIN shardLastMigrationTs[n]} :
                                        n \in DOMAIN shardLastMigrationTs})

\* Transaction state predicates
TxnCommitted(t) == HasResponse(response[t][TXN_STMTS]) /\ response[t][TXN_STMTS]["rsp"] = ok
TxnAborted(t)   == \E s \in Stmts : HasResponse(response[t][s]) /\ response[t][s]["rsp"] \notin {ok}

\* Lock helpers
IsNamespaceLocked(s, ns) == \E t \in Txns : shardLocked[s][t][ns]
Lock(lk, t, s, ns) == [lk EXCEPT ![s][t][ns] = TRUE]
Unlock(t) == [s \in Shards |->
                [txn \in Txns |->
                    [ns \in NameSpaces |-> IF txn = t THEN FALSE
                                          ELSE shardLocked[s][txn][ns]]]]
ClearShardTxnResources(t) ==
    [s \in Shards |-> [shardTxnResources[s] EXCEPT ![t] = EmptyTxnResources]]
ClearShardSnapshots(t) ==
    [s \in Shards |-> [shardSnapshotted[s] EXCEPT ![t] = FALSE]]
ClearShardSnapshotData(t) ==
    [s \in Shards |-> [shardSnapshot[s] EXCEPT ![t] = [n \in NameSpaces |-> {}]]]

\* ============================================================================
\* Init
\* ============================================================================

\* InitBase: all state except router cached ranges (for TraceInit flexibility)
InitBase ==
    \* Global
    /\ ranges \in [NameSpaces -> [Keys -> Shards]]
    /\ versions = [s \in Shards |-> [n \in NameSpaces |-> 0]]
    \* Network
    /\ request = [t \in Txns |-> <<>>]
    /\ response = [t \in Txns |-> [stm \in Stmts |-> <<>>]]
    \* Router (except rCachedRanges)
    /\ rCachedVersions = [n \in NameSpaces |-> [s \in Shards |-> 0]]
    /\ rPlacementConflictTime = [t \in Txns |-> -1]
    /\ rCreatedDatabases = [t \in Txns |-> {}]
    /\ rCompletedStmt = [t \in Txns |-> 0]
    \* Shard
    /\ shardSnapshotted = [s \in Shards |-> [t \in Txns |-> FALSE]]
    /\ shardSnapshot = [s \in Shards |-> [t \in Txns |-> [n \in NameSpaces |-> {}]]]
    /\ shardLastMigrationTs = [s \in Shards |-> [n \in NameSpaces |-> INIT_MIGRATION_TS]]
    /\ shardLocked = [s \in Shards |-> [t \in Txns |-> [n \in NameSpaces |-> FALSE]]]
    /\ shardTxnResources = [s \in Shards |-> [t \in Txns |-> EmptyTxnResources]]
    \* Migration (Family 1)
    /\ migrationPhase = [n \in NameSpaces |-> MigIdle]
    /\ migrationFrom = [n \in NameSpaces |-> CHOOSE s \in Shards : TRUE]
    /\ migrationTo = [n \in NameSpaces |-> CHOOSE s \in Shards : TRUE]
    /\ migrationKey = [n \in NameSpaces |-> CHOOSE k \in Keys : TRUE]
    /\ coordinatorDoc = [n \in NameSpaces |-> DocNone]
    /\ migrations = 0
    \* Failover (Family 3)
    /\ donorAlive = [s \in Shards |-> TRUE]
    \* Error tracking (Family 4)
    /\ execCount = [t \in Txns |-> [stm \in Stmts |-> 0]]

Init ==
    /\ InitBase
    /\ rCachedRanges = [n \in NameSpaces |-> ranges[n]]

\* ============================================================================
\* Router Actions
\* ============================================================================

\* Action: Router forwards a transaction statement to the shard owning the key.
\* transaction_router.cpp:2559-2649 (startTransaction fields)
\* transaction_router.cpp:626-699  (continueTransaction fields)
RouterSendTxnStmt(t, ns, k) ==
    /\ Len(request[t]) < TXN_STMTS
    /\ rCompletedStmt[t] = Len(request[t])
    /\ LET isStartTransaction == (Len(request[t]) = 0)
       IN
        \* Set placementConflictTime on first statement
        \* transaction_router.cpp:2035-2039
        /\ IF isStartTransaction
            THEN rPlacementConflictTime' = [rPlacementConflictTime EXCEPT ![t] = LatestMigrationTs]
            ELSE UNCHANGED rPlacementConflictTime
        /\ LET s == rCachedRanges[ns][k]
               \* Build transaction runtime context
               \* Always include placementConflictTime so new participants get it
               \* transaction_router.cpp:626-699 — attached on every statement
               txnCtx == [
                   startTransaction      |-> isStartTransaction,
                   placementConflictTime  |-> IF isStartTransaction
                                              THEN rPlacementConflictTime'[t]
                                              ELSE rPlacementConflictTime[t],
                   createdDatabases       |-> rCreatedDatabases[t]
               ]
           IN
            /\ request' = [request EXCEPT ![t] = Append(request[t],
                                                        CreateReq(s, ns, k,
                                                                  rCachedVersions[ns][s],
                                                                  txnCtx))]
    /\ UNCHANGED <<response, rCachedRanges, rCachedVersions, rCompletedStmt,
                   rCreatedDatabases, shardVars, shardLastMigrationTs,
                   globalVars, migStateVars, donorAlive, execCount>>

\* Action: Router processes an ok response from a shard.
\* transaction_router.cpp — response handling
RouterHandleOk(t, stm) ==
    /\ HasResponse(response[t][stm])
    /\ rCompletedStmt[t] < stm
    /\ response[t][stm]["rsp"] = ok
    /\ rCompletedStmt' = [rCompletedStmt EXCEPT ![t] = rCompletedStmt[t] + 1]
    \* On last statement: release locks and clear txn resources
    /\ IF rCompletedStmt'[t] = TXN_STMTS
       THEN /\ shardLocked' = Unlock(t)
            /\ shardTxnResources' = ClearShardTxnResources(t)
       ELSE UNCHANGED <<shardLocked, shardTxnResources>>
    /\ UNCHANGED <<shardSnapshotted, shardSnapshot, response, request,
                   rCachedVersions, rCachedRanges, rPlacementConflictTime,
                   rCreatedDatabases, globalVars, shardLastMigrationTs,
                   migStateVars, donorAlive, execCount>>

\* Action: Router aborts transaction on non-retryable error.
\* Handles: migrationConflict (any stmt), staleRouter on non-first stmt
\* transaction_router.cpp:1207-1235  (onStaleShardOrDbError)
\* transaction_router.cpp:2280-2300 (_errorAllowsRetryOnStaleShardOrDb)
RouterHandleAbort(t, stm) ==
    /\ HasResponse(response[t][stm])
    /\ rCompletedStmt[t] < stm
    /\ response[t][stm]["rsp"] \notin {ok}
    \* Refresh cache on staleRouter
    /\ IF response[t][stm]["rsp"] = staleRouter
        THEN LET ns == request[t][Len(request[t])]["ns"] IN
            /\ rCachedVersions' = [rCachedVersions EXCEPT ![ns] =
                                    [x \in Shards |-> versions[x][ns]]]
            /\ rCachedRanges' = [rCachedRanges EXCEPT ![ns] = ranges[ns]]
        ELSE UNCHANGED <<rCachedVersions, rCachedRanges>>
    \* Abort: mark txn as done
    /\ rCompletedStmt' = [rCompletedStmt EXCEPT ![t] = TXN_STMTS]
    /\ shardLocked' = Unlock(t)
    /\ shardTxnResources' = ClearShardTxnResources(t)
    /\ UNCHANGED <<shardSnapshotted, shardSnapshot, response, request,
                   rPlacementConflictTime, rCreatedDatabases,
                   globalVars, shardLastMigrationTs,
                   migStateVars, donorAlive, execCount>>

\* Action: Router retries first statement after StaleConfig.  (Family 2, 4)
\* transaction_router.cpp:1207-1235  — onStaleShardOrDbError
\* transaction_router.cpp:2280-2300  — retry allowed only on first stmt, <=1 participant
\* Resets placementConflictTime (SERVER-87660 class)
RouterRetryOnStale(t) ==
    /\ Len(request[t]) = 1           \* First statement only
    /\ rCompletedStmt[t] = 0
    /\ HasResponse(response[t][1])
    /\ response[t][1]["rsp"] = staleRouter
    \* Refresh cache
    \* transaction_router.cpp:1228-1234
    /\ LET ns == request[t][1]["ns"] IN
        /\ rCachedVersions' = [rCachedVersions EXCEPT ![ns] =
                                [x \in Shards |-> versions[x][ns]]]
        /\ rCachedRanges' = [rCachedRanges EXCEPT ![ns] = ranges[ns]]
    \* Reset placementConflictTime — will be set fresh on next send
    \* transaction_router.cpp:1233
    /\ rPlacementConflictTime' = [rPlacementConflictTime EXCEPT ![t] = -1]
    \* Clear request/response to allow re-send
    /\ request' = [request EXCEPT ![t] = <<>>]
    /\ response' = [response EXCEPT ![t][1] = <<>>]
    \* Clear shard state for this txn
    /\ shardLocked' = Unlock(t)
    /\ shardTxnResources' = ClearShardTxnResources(t)
    /\ shardSnapshotted' = ClearShardSnapshots(t)
    /\ shardSnapshot' = ClearShardSnapshotData(t)
    /\ UNCHANGED <<rCompletedStmt, rCreatedDatabases, globalVars,
                   shardLastMigrationTs, migStateVars, donorAlive, execCount>>

\* Action: Router marks a database as created within the transaction.  (Family 2)
\* transaction_router.cpp:331-349  — setPlacementConflictTimeToDatabaseVersionIfNeeded
\* database_sharding_runtime.cpp:112-114 — exemption check
CreateDatabase(t) ==
    /\ rCreatedDatabases[t] = {}
    /\ Len(request[t]) = 0         \* Before any statements sent
    /\ rCreatedDatabases' = [rCreatedDatabases EXCEPT ![t] = {"db"}]
    /\ UNCHANGED <<request, response, rCachedRanges, rCachedVersions,
                   rCompletedStmt, rPlacementConflictTime,
                   shardVars, shardLastMigrationTs,
                   globalVars, migStateVars, donorAlive, execCount>>

\* ============================================================================
\* Shard Actions
\* ============================================================================

\* Action: Shard responds to a statement forwarded by the router.
\* collection_sharding_runtime.cpp:617-686  (CS + version + PCT checks)
\* database_sharding_runtime.cpp:95-150     (database-level check)
ShardRespond(t, self) ==
    /\ LET ln  == Len(request[t])
           req == request[t][ln] IN
        /\ ln > 0
        /\ req.s = self
        /\ response[t][ln] = <<>>
        /\ donorAlive[self] = TRUE     \* Shard must be alive (Family 3)
        \* Compute effective placementConflictTime
        \* transaction_participant.cpp:1056-1070 — store on first receipt
        /\ LET existingPCT == shardTxnResources[self][t].placementConflictTime
               effectivePCT == IF existingPCT # -1 THEN existingPCT
                                ELSE req.txnRuntimeContext.placementConflictTime
               status == RespondStatus(self, req.ns, req.k, req.v, versions[self][req.ns],
                                       effectivePCT,
                                       shardLastMigrationTs[self][req.ns],
                                       req.txnRuntimeContext.createdDatabases)
           IN
            IF status = ok
            THEN
                \* Success path: establish snapshot, lock, store resources
                /\ IF ~shardSnapshotted[self][t]
                   THEN /\ shardSnapshotted' = [shardSnapshotted EXCEPT ![self][t] = TRUE]
                        /\ shardSnapshot' = [shardSnapshot EXCEPT ![self][t] =
                            [n \in NameSpaces |->
                                {k \in DOMAIN(ranges[n]) : ranges[n][k] = self}]]
                   ELSE UNCHANGED <<shardSnapshotted, shardSnapshot>>
                /\ shardTxnResources' = [shardTxnResources EXCEPT
                    ![self][t].placementConflictTime =
                        IF @ = -1 THEN req.txnRuntimeContext.placementConflictTime ELSE @,
                    ![self][t].createdDatabases = req.txnRuntimeContext.createdDatabases]
                /\ shardLocked' = Lock(shardLocked, t, self, req.ns)
                /\ response' = [response EXCEPT ![t][ln] =
                    CreateRsp(ok, req.k \in shardSnapshot'[self][t][req.ns])]
                \* Track write execution (Family 4)
                /\ execCount' = [execCount EXCEPT ![t][ln] = @ + 1]
            ELSE
                \* Error path: don't modify shard state
                \* collection_sharding_runtime.cpp:617-639 — CS blocks before processing
                /\ response' = [response EXCEPT ![t][ln] = CreateRsp(status, FALSE)]
                /\ UNCHANGED <<shardSnapshotted, shardSnapshot,
                               shardTxnResources, shardLocked, execCount>>
    /\ UNCHANGED <<request, routerVars, globalVars, shardLastMigrationTs,
                   migStateVars, donorAlive>>

\* Action: Shard executes write THEN discovers error.  (Family 4)
\* SERVER-81508: ShardCannotRefreshDueToLocksHeld thrown AFTER write executed
\* write_ops_exec.cpp — write execution before metadata refresh attempt
\* Fault injection: write happens, then error returned to router
ShardRespondAfterExec(t, self) ==
    /\ LET ln  == Len(request[t])
           req == request[t][ln] IN
        /\ ln > 0
        /\ req.s = self
        /\ response[t][ln] = <<>>
        /\ donorAlive[self] = TRUE
        \* The write IS executed (Family 4: at-most-once violation risk)
        /\ execCount' = [execCount EXCEPT ![t][ln] = @ + 1]
        \* But shard returns staleRouter error after execution
        /\ response' = [response EXCEPT ![t][ln] = CreateRsp(staleRouter, FALSE)]
        \* Snapshot/lock established since operation started executing
        /\ IF ~shardSnapshotted[self][t]
           THEN /\ shardSnapshotted' = [shardSnapshotted EXCEPT ![self][t] = TRUE]
                /\ shardSnapshot' = [shardSnapshot EXCEPT ![self][t] =
                    [n \in NameSpaces |->
                        {k \in DOMAIN(ranges[n]) : ranges[n][k] = self}]]
           ELSE UNCHANGED <<shardSnapshotted, shardSnapshot>>
        /\ shardTxnResources' = [shardTxnResources EXCEPT
            ![self][t].placementConflictTime =
                IF @ = -1 THEN req.txnRuntimeContext.placementConflictTime ELSE @,
            ![self][t].createdDatabases = req.txnRuntimeContext.createdDatabases]
        /\ shardLocked' = Lock(shardLocked, t, self, req.ns)
    /\ UNCHANGED <<request, routerVars, globalVars, shardLastMigrationTs,
                   migStateVars, donorAlive>>

\* ============================================================================
\* Migration Actions  (Family 1)
\* ============================================================================

\* Action: Start migration — donor enters critical section.
\* migration_source_manager.cpp:303-305 (step 1), :526-527 (step 3),
\*   :545-546 (step 4), :550-593 (enterCriticalSection)
\* Abstracts cloning (steps 2-4) into the CS entry.
StartMigration(ns, k, from, to) ==
    /\ migrations < MIGRATIONS
    /\ migrationPhase[ns] = MigIdle
    /\ from = ranges[ns][k]        \* Donor owns the key
    /\ to # from                    \* Different shards
    /\ donorAlive[from] = TRUE      \* Donor must be primary (Family 3)
    \* Enter critical section on donor
    \* migration_source_manager.cpp:566 — _critSec.emplace()
    /\ migrationPhase' = [migrationPhase EXCEPT ![ns] = MigCritSec]
    /\ migrationFrom' = [migrationFrom EXCEPT ![ns] = from]
    /\ migrationTo' = [migrationTo EXCEPT ![ns] = to]
    /\ migrationKey' = [migrationKey EXCEPT ![ns] = k]
    \* Write coordinator document (no decision yet)
    \* migration_coordinator.cpp — persistMigrationCoordinatorDoc
    /\ coordinatorDoc' = [coordinatorDoc EXCEPT ![ns] = DocPending]
    /\ migrations' = migrations + 1
    /\ UNCHANGED <<globalVars, networkVars, routerVars, shardVars,
                   shardLastMigrationTs, donorAlive, execCount>>

\* Action: Config server commits the migration.
\* migration_source_manager.cpp:621-699 (commitChunkMetadataOnConfig)
\* migration_coordinator.cpp:231-324    (_commitMigrationOnDonorAndRecipient)
\* The config commit is a SEPARATE network hop from CS entry (Family 1 core).
ConfigCommit(ns) ==
    /\ migrationPhase[ns] = MigCritSec
    /\ coordinatorDoc[ns] = DocPending
    /\ donorAlive[migrationFrom[ns]] = TRUE
    \* Config server commits: update authoritative routing
    \* migration_source_manager.cpp:665-671 — CommitChunkMigrationRequest
    /\ LET v == Max({versions[s][ns] : s \in Shards}) IN
        /\ ranges' = [ranges EXCEPT ![ns][migrationKey[ns]] = migrationTo[ns]]
        /\ versions' = [versions EXCEPT ![migrationFrom[ns]][ns] = v + 1,
                                        ![migrationTo[ns]][ns] = v + 1]
        \* Set validAfter timestamp on recipient
        /\ shardLastMigrationTs' = [shardLastMigrationTs EXCEPT
            ![migrationTo[ns]][ns] = LatestMigrationTs + 1]
    \* Transition to Committed phase (CS still active)
    /\ migrationPhase' = [migrationPhase EXCEPT ![ns] = MigCommitted]
    \* Persist commit decision in coordinator doc
    \* migration_coordinator.cpp:240 — persistCommitDecision
    /\ coordinatorDoc' = [coordinatorDoc EXCEPT ![ns] = DocCommitted]
    /\ UNCHANGED <<networkVars, routerVars, shardVars,
                   migrationFrom, migrationTo, migrationKey, migrations,
                   donorAlive, execCount>>

\* Action: Config commit fails — migration aborted.  (Family 1)
\* migration_source_manager.cpp:681-698 — config commit failure handling
\* migration_coordinator.cpp:326-387    — _abortMigrationOnDonorAndRecipient
ConfigCommitFail(ns) ==
    /\ migrationPhase[ns] = MigCritSec
    /\ coordinatorDoc[ns] = DocPending
    \* Config commit failed: no routing changes
    \* Persist abort decision
    \* migration_coordinator.cpp:334 — persistAbortDecision
    /\ coordinatorDoc' = [coordinatorDoc EXCEPT ![ns] = DocAborted]
    \* Release CS and return to idle
    /\ migrationPhase' = [migrationPhase EXCEPT ![ns] = MigIdle]
    /\ UNCHANGED <<globalVars, networkVars, routerVars, shardVars,
                   shardLastMigrationTs, migrationFrom, migrationTo,
                   migrationKey, migrations, donorAlive, execCount>>

\* Action: Release critical section after successful commit.
\* migration_source_manager.cpp:925-926 — _critSec.reset()
\* This transitions Committed -> Idle (CS released, migration complete).
ReleaseCriticalSection(ns) ==
    /\ migrationPhase[ns] = MigCommitted
    /\ coordinatorDoc[ns] = DocCommitted
    \* Release CS, clean up coordinator doc
    /\ migrationPhase' = [migrationPhase EXCEPT ![ns] = MigIdle]
    \* migration_coordinator.cpp:226 — forgetMigration
    /\ coordinatorDoc' = [coordinatorDoc EXCEPT ![ns] = DocNone]
    /\ UNCHANGED <<globalVars, networkVars, routerVars, shardVars,
                   shardLastMigrationTs, migrationFrom, migrationTo,
                   migrationKey, migrations, donorAlive, execCount>>

\* ============================================================================
\* Failover Actions  (Family 3)
\* ============================================================================

\* Action: Donor shard steps down during active migration.
\* migration_source_manager.cpp:863-868 (abort)
\* migration_source_manager.cpp:903-994 (_cleanup)
\* Non-deterministic: if in CritSec, config may or may not have committed
\*   before the step-down (models "config committed but response lost").
DonorStepDown(s) ==
    /\ donorAlive[s] = TRUE
    /\ \E ns \in NameSpaces :
        /\ migrationFrom[ns] = s
        /\ migrationPhase[ns] \in {MigCritSec, MigCommitted}
        \* Donor dies: migration interrupted
        /\ donorAlive' = [donorAlive EXCEPT ![s] = FALSE]
        /\ migrationPhase' = [migrationPhase EXCEPT ![ns] = MigIdle]
        \* Non-deterministic config commit outcome if stepping down from CritSec
        /\ IF migrationPhase[ns] = MigCritSec
           THEN
                \* migration_coordinator.cpp:531-617 — recovery must infer decision
                \/ \* Path A: Config DID commit before step-down (response lost)
                   \*   Config server has committed routing change
                   /\ LET v == Max({versions[x][ns] : x \in Shards}) IN
                      /\ ranges' = [ranges EXCEPT ![ns][migrationKey[ns]] = migrationTo[ns]]
                      /\ versions' = [versions EXCEPT ![migrationFrom[ns]][ns] = v + 1,
                                                      ![migrationTo[ns]][ns] = v + 1]
                      /\ shardLastMigrationTs' = [shardLastMigrationTs EXCEPT
                            ![migrationTo[ns]][ns] = LatestMigrationTs + 1]
                   \* Coordinator doc stays Pending (donor didn't get response)
                   /\ UNCHANGED coordinatorDoc
                \/ \* Path B: Config did NOT commit
                   /\ UNCHANGED <<ranges, versions, shardLastMigrationTs, coordinatorDoc>>
           ELSE
                \* Stepping down from Committed: config already committed
                /\ UNCHANGED <<ranges, versions, shardLastMigrationTs, coordinatorDoc>>
    /\ UNCHANGED <<networkVars, routerVars, shardVars,
                   migrationFrom, migrationTo, migrationKey, migrations, execCount>>

\* Action: Donor shard steps back up (new primary).
\* shard_filtering_metadata_refresh.cpp:495-634 (_recoverMigrationCoordinations)
DonorStepUp(s) ==
    /\ donorAlive[s] = FALSE
    /\ donorAlive' = [donorAlive EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<globalVars, networkVars, routerVars, shardVars,
                   shardLastMigrationTs, migStateVars, execCount>>

\* Action: Donor recovers migration after step-up.
\* migration_coordinator.cpp:183-229 (completeMigration)
\* migration_util.cpp:356-414        (resumeMigrationCoordinationsOnStepUp)
\* Reads coordinator doc, checks config server state, completes or aborts.
DonorRecovery(s, ns) ==
    /\ donorAlive[s] = TRUE
    /\ migrationPhase[ns] = MigIdle
    /\ migrationFrom[ns] = s
    /\ coordinatorDoc[ns] \in {DocPending, DocCommitted, DocAborted}
    /\ IF coordinatorDoc[ns] = DocCommitted
       THEN \* Decision known: committed. Clean up.
            coordinatorDoc' = [coordinatorDoc EXCEPT ![ns] = DocNone]
       ELSE IF coordinatorDoc[ns] = DocAborted
       THEN \* Decision known: aborted. Clean up.
            coordinatorDoc' = [coordinatorDoc EXCEPT ![ns] = DocNone]
       ELSE \* DocPending: infer decision from config server (authoritative)
            \* migration_coordinator.cpp:531-617 — check config metadata
            IF ranges[ns][migrationKey[ns]] = migrationTo[ns]
            THEN \* Config committed -> complete migration
                 coordinatorDoc' = [coordinatorDoc EXCEPT ![ns] = DocNone]
            ELSE \* Config didn't commit -> abort migration
                 coordinatorDoc' = [coordinatorDoc EXCEPT ![ns] = DocNone]
    /\ UNCHANGED <<globalVars, networkVars, routerVars, shardVars,
                   shardLastMigrationTs, migrationPhase, migrationFrom,
                   migrationTo, migrationKey, migrations, donorAlive, execCount>>

\* Action: Donor recovery infers WRONG decision.  (Family 3, fault injection)
\* Models: config committed but recovery incorrectly infers abort, or vice versa.
\* This targets MC-2: "Config commit succeeds but response lost; donor
\*   recovery infers wrong decision" -> RecoveryPreservesDecision violation.
DonorRecoveryWrongInference(s, ns) ==
    /\ donorAlive[s] = TRUE
    /\ migrationPhase[ns] = MigIdle
    /\ migrationFrom[ns] = s
    /\ coordinatorDoc[ns] = DocPending  \* Decision unknown
    \* Config committed (ranges updated by DonorStepDown path A)
    \* BUT recovery incorrectly infers abort
    /\ ranges[ns][migrationKey[ns]] = migrationTo[ns]
    \* Clean up as if aborted (but config says committed -> inconsistency)
    /\ coordinatorDoc' = [coordinatorDoc EXCEPT ![ns] = DocNone]
    \* Note: ranges remain updated (config is authoritative, can't undo)
    \* This creates a state where migration is "done" but cleanup was wrong.
    /\ UNCHANGED <<globalVars, networkVars, routerVars, shardVars,
                   shardLastMigrationTs, migrationPhase, migrationFrom,
                   migrationTo, migrationKey, migrations, donorAlive, execCount>>

\* ============================================================================
\* Next and Spec
\* ============================================================================

Next ==
    \* --- Router actions ---
    \/ \E t \in Txns, ns \in NameSpaces, k \in Keys : RouterSendTxnStmt(t, ns, k)
    \/ \E t \in Txns, stm \in Stmts : RouterHandleOk(t, stm)
    \/ \E t \in Txns, stm \in Stmts : RouterHandleAbort(t, stm)
    \/ \E t \in Txns : RouterRetryOnStale(t)
    \/ \E t \in Txns : CreateDatabase(t)
    \* --- Shard actions ---
    \/ \E s \in Shards, t \in Txns : ShardRespond(t, s)
    \/ \E s \in Shards, t \in Txns : ShardRespondAfterExec(t, s)
    \* --- Migration actions (Family 1) ---
    \/ \E ns \in NameSpaces, k \in Keys, from, to \in Shards :
        StartMigration(ns, k, from, to)
    \/ \E ns \in NameSpaces : ConfigCommit(ns)
    \/ \E ns \in NameSpaces : ConfigCommitFail(ns)
    \/ \E ns \in NameSpaces : ReleaseCriticalSection(ns)
    \* --- Failover actions (Family 3) ---
    \/ \E s \in Shards : DonorStepDown(s)
    \/ \E s \in Shards : DonorStepUp(s)
    \/ \E s \in Shards, ns \in NameSpaces : DonorRecovery(s, ns)
    \/ \E s \in Shards, ns \in NameSpaces : DonorRecoveryWrongInference(s, ns)
    \* --- Stuttering ---
    \/ UNCHANGED vars

Fairness ==
    /\ WF_vars(\E t \in Txns, ns \in NameSpaces, k \in Keys : RouterSendTxnStmt(t, ns, k))
    /\ WF_vars(\E t \in Txns, stm \in Stmts : RouterHandleAbort(t, stm))
    /\ WF_vars(\E t \in Txns, stm \in Stmts : RouterHandleOk(t, stm))
    /\ WF_vars(\E t \in Txns : RouterRetryOnStale(t))
    /\ WF_vars(\E s \in Shards, t \in Txns : ShardRespond(t, s))
    /\ WF_vars(\E ns \in NameSpaces : ConfigCommit(ns))
    /\ WF_vars(\E ns \in NameSpaces : ReleaseCriticalSection(ns))
    /\ WF_vars(\E s \in Shards : DonorStepUp(s))
    /\ WF_vars(\E s \in Shards, ns \in NameSpaces : DonorRecovery(s, ns))

Spec == Init /\ [][Next]_vars /\ Fairness

\* ============================================================================
\* Invariants
\* ============================================================================

\* --- Standard safety (from existing spec) ---

\* If a transaction committed, all its statements received ok.
CommittedTxnImpliesAllStmtsSuccessful ==
    \A t \in Txns : TxnCommitted(t) =>
        \A s \in Stmts : response[t][s]["rsp"] = ok

\* If a transaction committed, all its keys were found.
CommittedTxnImpliesKeysAreVisible ==
    \A t \in Txns : TxnCommitted(t) =>
        \A s \in Stmts : response[t][s]["found"] = TRUE

\* --- Family 1: Non-atomic migration invariants ---

\* NoPrematureCSRelease: if coordinator doc says committed, ranges must reflect it.
\* Targets SERVER-62580: recipient told to exit CS before config commit confirmed.
NoPrematureCSRelease ==
    \A ns \in NameSpaces :
        coordinatorDoc[ns] = DocCommitted =>
            ranges[ns][migrationKey[ns]] = migrationTo[ns]

\* CriticalSectionCoversCommit: config commit only while CS active.
CriticalSectionCoversCommit ==
    \A ns \in NameSpaces :
        coordinatorDoc[ns] = DocCommitted =>
            migrationPhase[ns] \in {MigCritSec, MigCommitted, MigIdle}

\* --- Family 2: placementConflictTime invariants ---

\* AllParticipantsSameTimestamp: committed txn participants used same PCT.
\* Targets SERVER-87660: PCT mutation during retry.
AllParticipantsSameTimestamp ==
    \A t \in Txns : TxnCommitted(t) =>
        \A s1, s2 \in Shards :
            (/\ shardTxnResources[s1][t].placementConflictTime # -1
             /\ shardTxnResources[s2][t].placementConflictTime # -1)
            => shardTxnResources[s1][t].placementConflictTime =
               shardTxnResources[s2][t].placementConflictTime

\* --- Family 3: Failover invariants ---

\* RecoveryPreservesDecision: after recovery completes, routing must be
\* consistent with coordinator doc outcome.
\* If doc is committed but ranges don't reflect migration, state is corrupt.
\* If doc is none (cleaned up) and donor is alive, versions must be consistent.
RecoveryPreservesDecision ==
    \A ns \in NameSpaces :
        \* Committed doc implies ranges were updated
        /\ (coordinatorDoc[ns] = DocCommitted =>
              ranges[ns][migrationKey[ns]] = migrationTo[ns])
        \* After full cleanup (doc=None, donor alive, idle), shard versions
        \* must agree (both bumped by ConfigCommit or neither bumped)
        /\ (coordinatorDoc[ns] = DocNone /\ migrationPhase[ns] = MigIdle /\
            donorAlive[migrationFrom[ns]] = TRUE) =>
              versions[migrationFrom[ns]][ns] = versions[migrationTo[ns]][ns]

\* MigrationPhaseConsistency: structural invariant.
MigrationPhaseConsistency ==
    \A ns \in NameSpaces :
        \* Committed phase requires coordinator doc to be committed
        /\ (migrationPhase[ns] = MigCommitted => coordinatorDoc[ns] = DocCommitted)
        \* CritSec phase requires coordinator doc to be pending
        /\ (migrationPhase[ns] = MigCritSec => coordinatorDoc[ns] = DocPending)

\* --- Family 4: Error propagation invariant ---

\* AtMostOnceExecution: no statement executed more than once.
\* Targets SERVER-81508: write executed, error thrown, router retries, double exec.
AtMostOnceExecution ==
    \A t \in Txns : \A stm \in Stmts : execCount[t][stm] <= 1

\* --- Structural invariants ---

TypeOK ==
    /\ ranges \in [NameSpaces -> [Keys -> Shards]]
    /\ versions \in [Shards -> [NameSpaces -> 0..MIGRATIONS]]
    /\ migrationPhase \in [NameSpaces -> {MigIdle, MigCritSec, MigCommitted}]
    /\ coordinatorDoc \in [NameSpaces -> {DocNone, DocPending, DocCommitted, DocAborted}]
    /\ donorAlive \in [Shards -> BOOLEAN]
    /\ rPlacementConflictTime \in [Txns -> Int]
    /\ rCreatedDatabases \in [Txns -> SUBSET DatabaseNames]

\* --- Temporal properties ---

AllTxnsEventuallyDone == <> \A t \in Txns : TxnCommitted(t) \/ TxnAborted(t)
MigrationEventuallyCompletes ==
    \A ns \in NameSpaces :
        migrationPhase[ns] # MigIdle ~> migrationPhase[ns] = MigIdle

\* --- Miscellaneous helpers (from existing spec) ---

NSsetofTxn(t)    == {request[t][x].ns : x \in 1..Len(request[t])}
ShardsetofTxn(t) == {request[t][x].s  : x \in 1..Len(request[t])}

================================================================================
