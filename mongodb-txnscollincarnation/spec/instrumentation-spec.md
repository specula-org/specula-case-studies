# Instrumentation Spec: MongoDB TxnsCollectionIncarnation

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "ts": "<ISO timestamp>",
  "node": "<mongos|shard_id>",
  "txn": "<txn_id>",
  "ns": "<namespace_string>",
  "shard": "<shard_id>",
  "clusterTime": <integer>,
  "ddlPhase": "<phase_string>",
  "placementConflictTime": <integer>,
  "responseStatus": "<ok|staleDbVersion|staleShardVersion|snapshotIncompatible>",
  ...action-specific fields...
}
```

### State Fields

| Implementation Getter/Field | TLA+ Variable | Notes |
|---|---|---|
| `VectorClock::get(opCtx)->getTime().clusterTime()` | `clusterTime` | Captured at DDL commit events |
| `TransactionRouter::o().placementConflictTimeForNonSnapshotReadConcern` | `rPlacementConflictTime[t]` | Captured at RouterSendTxnStmt |
| `TransactionRouter::p().createdDatabases` | `rCreatedDatabases[t]` | Captured at annotation events |
| `DDLCoordinator::_doc.getPhase()` | `ddlPhase[ns]` | Captured at each DDL phase transition |
| `response.getStatus()` | response status | Captured at ShardResponse |

### Mapping Files

First trace event should contain mappings:
```json
{
  "event": "_init",
  "shardMap": {"s1": "shard0000", "s2": "shard0001"},
  "nsMap": {"ns1": "test.coll1", "ns2": "test.coll2"},
  "txnMap": {"t1": "txn_abc123"}
}
```

## Section 2: Action-to-Code Mapping

### Router Actions

#### RouterSendTxnStmt
- **Code location**: `src/mongo/s/transaction_router.cpp:954-1001` (`attachTxnFieldsIfNeeded`)
- **Trigger point**: After `attachTxnFieldsIfNeeded` returns, before response wait
- **Trace event name**: `RouterSendTxnStmt`
- **Fields**: `txn` (txnNumber), `ns` (namespace), `shard` (target shard), `stmt` (statement number), `placementConflictTime` (from `o().placementConflictTimeForNonSnapshotReadConcern`)
- **Notes**: Emit once per shard targeted. The `isStartTransaction` flag determines if placementConflictTime is sent.

#### RouterAnnotateCreatedDatabase
- **Code location**: `src/mongo/db/global_catalog/ddl/cluster_ddl.cpp:129-131` (`annotateCreatedDatabase`)
- **Trigger point**: After `txnRouter.annotateCreatedDatabase(dbName)` call
- **Trace event name**: `RouterAnnotateCreatedDatabase`
- **Fields**: `txn`, `dbName` (database name string)
- **Notes**: Called BEFORE `_configsvrCreateDatabase` succeeds (Bug Family 3, F3-2). Capture even if create subsequently fails.

#### RouterHandleAbort
- **Code location**: `src/mongo/s/transaction_router.cpp` — `processParticipantResponse` error path
- **Trigger point**: When router determines transaction must abort due to non-OK response
- **Trace event name**: `RouterHandleAbort`
- **Fields**: `txn`, `stmt`, `responseStatus`, `ns` (namespace from stale error)
- **Notes**: Refresh cache state is implicit; trace the abort decision, not the refresh.

#### RouterHandleOK
- **Code location**: `src/mongo/s/transaction_router.cpp` — `processParticipantResponse` OK path
- **Trigger point**: When all responses for a statement are OK
- **Trace event name**: `RouterHandleOK`
- **Fields**: `txn`, `stmt`
- **Notes**: Emitted once per statement (after all shard responses collected), not per shard.

#### RouterSendCommit
- **Code location**: `src/mongo/s/transaction_router.cpp:1598-1630` (`commitTransaction`)
- **Trigger point**: At entry to `commitTransaction`, before `_commitTransaction` is called
- **Trace event name**: `RouterSendCommit`
- **Fields**: `txn`
- **Notes**: Bug Family 5 — this is the commit step that does NOT re-check placement. Critical to trace this as a distinct event from the last statement OK.

#### RouterReceiveStaleError
- **Code location**: `src/mongo/s/transaction_router.cpp:1181-1235` (`canContinueOnStaleShardOrDbError` + `onStaleShardOrDbError`)
- **Trigger point**: After `onStaleShardOrDbError` completes (participants cleared, placementConflictTime reset)
- **Trace event name**: `RouterReceiveStaleError`
- **Fields**: `txn`, `stmt` (always 1 for retriable), `responseStatus` (stale error type)
- **Notes**: Only fires on first statement. Second+ statement stale errors go through RouterHandleAbort instead.

#### RouterRetryFirstStatement
- **Code location**: `src/mongo/s/transaction_router.cpp:1331-1356` (`setDefaultAtClusterTime` on retry)
- **Trigger point**: When first statement is re-dispatched after stale error reset
- **Trace event name**: `RouterRetryFirstStatement`
- **Fields**: `txn`, `ns`, `placementConflictTime` (new value)
- **Notes**: Bug Family 4 — the fresh placementConflictTime from VectorClock. Trace the new time to verify monotonicity.

### Shard Actions

#### ShardResponse
- **Code location**: `src/mongo/db/shard_role/shard_catalog/collection_sharding_runtime.cpp:640-729` (`_getMetadataWithVersionCheckAt`)
- **Additional location**: `src/mongo/db/shard_role/shard_catalog/database_sharding_runtime.cpp:229-246` (`checkDbVersionOrThrow`)
- **Trigger point**: After metadata check completes (either OK or error), before response sent
- **Trace event name**: `ShardResponse`
- **Fields**: `shard`, `txn`, `ns`, `stmt`, `responseStatus`
- **Notes**: The metadata check order (DB version → shard version → local UUID) determines which error is returned. Capture the final status.

### DDL Actions — Create (Tracked)

#### CreateTrackedAcquireLock
- **Code location**: `src/mongo/db/global_catalog/ddl/create_collection_coordinator.cpp:1735-1738` (kEnterWriteCriticalSectionOnCoordinator)
- **Trigger point**: After DDL lock acquired, before entering CS
- **Trace event name**: `CreateTrackedAcquireLock`
- **Fields**: `ns`, `ddlPhase` ("acquireLock")

#### CreateTrackedEnterCS
- **Code location**: `src/mongo/db/global_catalog/ddl/create_collection_coordinator.cpp:2032-2058` (kEnterCriticalSection)
- **Trigger point**: After critical section entered on all shards
- **Trace event name**: `CreateTrackedEnterCS`
- **Fields**: `ns`, `ddlPhase` ("enterCS")

#### CreateTrackedCommitMetadata
- **Code location**: `src/mongo/db/global_catalog/ddl/create_collection_coordinator.cpp:2204-2311` (kCommitOnShardingCatalog)
- **Trigger point**: After metadata committed to config server
- **Trace event name**: `CreateTrackedCommitMetadata`
- **Fields**: `ns`, `ddlPhase` ("commitMetadata"), `clusterTime`

#### CreateTrackedExitCS
- **Code location**: `src/mongo/db/global_catalog/ddl/create_collection_coordinator.cpp:2384-2414` (kExitCriticalSection)
- **Trigger point**: After critical section released
- **Trace event name**: `CreateTrackedExitCS`
- **Fields**: `ns`, `ddlPhase` ("done")

### DDL Actions — Create (Untracked)

#### CreateUntrackedAcquireLock
- **Code location**: `src/mongo/db/global_catalog/ddl/create_collection_coordinator.cpp` (early phase for untracked)
- **Trigger point**: After DDL lock acquired
- **Trace event name**: `CreateUntrackedAcquireLock`
- **Fields**: `ns`

#### CreateUntrackedCommit
- **Code location**: `src/mongo/db/global_catalog/ddl/create_collection_coordinator.cpp` (commit for untracked)
- **Trigger point**: After collection created on primary shard
- **Trace event name**: `CreateUntrackedCommit`
- **Fields**: `ns`, `clusterTime`

### DDL Actions — Drop

#### DropAcquireLock
- **Code location**: `src/mongo/db/global_catalog/ddl/drop_collection_coordinator.cpp` (kFreezeCollection)
- **Trigger point**: After DDL lock acquired
- **Trace event name**: `DropAcquireLock`
- **Fields**: `ns`, `collType` ("tracked" or "untracked")

#### DropEnterCS
- **Code location**: `src/mongo/db/global_catalog/ddl/drop_collection_coordinator.cpp:274-293` (kEnterCriticalSection)
- **Trigger point**: After CS entered on all shards
- **Trace event name**: `DropEnterCS`
- **Fields**: `ns`

#### DropCommitMetadata
- **Code location**: `src/mongo/db/global_catalog/ddl/drop_collection_coordinator.cpp:295-429` (kDropCollection)
- **Trigger point**: After metadata removed from config + data dropped
- **Trace event name**: `DropCommitMetadata`
- **Fields**: `ns`, `clusterTime`

#### DropExitCS
- **Code location**: `src/mongo/db/global_catalog/ddl/drop_collection_coordinator.cpp:431-450` (kReleaseCriticalSection)
- **Trigger point**: After CS released
- **Trace event name**: `DropExitCS`
- **Fields**: `ns`

### DDL Actions — Rename

#### RenameAcquireLock
- **Code location**: `src/mongo/db/global_catalog/ddl/rename_collection_coordinator.cpp` (kCheckPreconditions / kFreezeMigrations)
- **Trigger point**: After DDL locks acquired for both source and target
- **Trace event name**: `RenameAcquireLock`
- **Fields**: `from` (source ns), `to` (target ns), `collType`

#### RenameEnterCS
- **Code location**: `src/mongo/db/global_catalog/ddl/rename_collection_coordinator.cpp:900-969` (kBlockCrudAndRename)
- **Trigger point**: After CS entered on all participants
- **Trace event name**: `RenameEnterCS`
- **Fields**: `ns` (source ns)

#### RenameCommitMetadata
- **Code location**: `src/mongo/db/global_catalog/ddl/rename_collection_coordinator.cpp:971-1051` (kRenameMetadata)
- **Trigger point**: After metadata committed to config
- **Trace event name**: `RenameCommitMetadata`
- **Fields**: `ns` (source ns), `clusterTime`

#### RenameExitCS
- **Code location**: `src/mongo/db/global_catalog/ddl/rename_collection_coordinator.cpp:1054-1089` (kUnblockCRUD)
- **Trigger point**: After CS released on all participants
- **Trace event name**: `RenameExitCS`
- **Fields**: `ns` (source ns)

### DDL Actions — MovePrimary

#### MovePrimaryAcquireLock
- **Code location**: `src/mongo/db/global_catalog/ddl/move_primary_coordinator.cpp` (kClone start)
- **Trigger point**: After DDL lock acquired and clone starts
- **Trace event name**: `MovePrimaryAcquireLock`
- **Fields**: `toShard` (destination shard)

#### MovePrimaryEnterCS
- **Code location**: `src/mongo/db/global_catalog/ddl/move_primary_coordinator.cpp:289` (kEnterCriticalSection)
- **Trigger point**: After CS entered (block reads)
- **Trace event name**: `MovePrimaryEnterCS`
- **Fields**: `toShard`

#### MovePrimaryCommitMetadata
- **Code location**: `src/mongo/db/global_catalog/ddl/move_primary_coordinator.cpp:311` (kCommit)
- **Trigger point**: After metadata committed to config and shards
- **Trace event name**: `MovePrimaryCommitMetadata`
- **Fields**: `toShard`, `clusterTime`

#### MovePrimaryExitCS
- **Code location**: `src/mongo/db/global_catalog/ddl/move_primary_coordinator.cpp:340-357` (kExitCriticalSection)
- **Trigger point**: After CS released
- **Trace event name**: `MovePrimaryExitCS`
- **Fields**: `toShard`

### DDL Failover

#### DDLFailover
- **Code location**: `src/mongo/db/global_catalog/ddl/sharding_coordinator.cpp:477-503` (recovery loop)
- **Trigger point**: When coordinator detects step-down or error and enters recovery
- **Trace event name**: `DDLFailover`
- **Fields**: `ns`, `ddlPhase` (phase after recovery)
- **Notes**: DDL lock lost on failover (ddl_lock_manager.h:73 — in-memory only). May recover to persisted phase or abort.

## Section 3: Special Considerations

### Instrumentation Approach

MongoDB's sharding cluster runs across multiple processes (mongos, config server, shard servers). Instrumentation must coordinate across processes:

1. **Mongos (router)**: Instrument `transaction_router.cpp` for router actions. Single-threaded per transaction, so no race in tracing.

2. **Shard servers**: Instrument `collection_sharding_runtime.cpp` and `database_sharding_runtime.cpp` for ShardResponse. Multiple concurrent transactions possible.

3. **Config server / DDL coordinators**: Instrument each DDL coordinator (`create_collection_coordinator.cpp`, `drop_collection_coordinator.cpp`, `rename_collection_coordinator.cpp`, `move_primary_coordinator.cpp`). Serialized per-namespace via DDL lock.

### Log Collection

Use the shared harness (see `case-studies/mongodb-shared-harness.md`):
- Docker compose with mongos + config + 2 shards
- Structured logging to files, post-processed into NDJSON
- Event ordering by cluster timestamp + wall clock

### Bootstrap State

- `clusterTime` starts at `INITIAL_CLUSTER_TIME` (1)
- Database metadata has initial primary shard
- All collections start as non-existent (UUID = 0)
- No transactions in progress

### Concurrent DDL Events

DDL coordinators are serialized per-namespace by DDL lock. However, different namespaces can have concurrent DDL operations. Trace events from different namespaces may interleave.

### Shard-Side State Access

The shard-side metadata check (`_getMetadataWithVersionCheckAt`) accesses metadata under the DSS lock (MODE_IS). The placementConflictTime comes from the TransactionParticipant, which stores it from the first statement. This is the key state to capture.

### Feature Flag

The `gAddTransactionRuntimeContextAsAGenericArgument` feature flag gates whether placementConflictTime is read from `ShardVersion` (deprecated) or `TransactionRuntimeContext` (new). Instrumentation should capture whichever path is active. For the spec, both paths produce the same semantic result.

### Failover Instrumentation

DDL failover is harder to instrument deterministically. Options:
1. **Stepdown injection**: Use `replSetStepDown` admin command to trigger failover at specific DDL phases
2. **Failpoint**: Use `hangBeforeMovePrimaryCriticalSection` and similar failpoints to pause DDL at phase boundaries, then trigger stepdown
3. **Log-based**: Parse MongoDB structured logs for step-down events and map to DDLFailover events

The failpoint approach is most reliable for targeted trace collection.
