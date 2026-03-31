# Instrumentation Spec: MongoDB TxnsMoveRange

Action-to-code mapping for generating trace harnesses compatible with `Trace.tla`.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "txn": "<txn_id>",         // optional, for txn-related events
  "shard": "<shard_id>",     // optional, for shard-related events
  "ns": "<namespace>",       // optional, for ns-related events
  "key": "<key>",            // optional
  "stm": <stmt_number>,      // optional
  "from": "<shard_id>",      // optional, for migration
  "to": "<shard_id>",        // optional, for migration
  "status": "<status>",      // optional, response status
  "found": <boolean>,        // optional, key found in snapshot
  "rCompletedStmt": <int>,   // optional, router state
  "rPlacementConflictTime": <int>,  // optional
  "migrationPhase": "<phase>"       // optional, migration state
}
```

### State Fields

| Implementation getter/field | TLA+ variable | Type | Notes |
|---|---|---|---|
| `TransactionRouter::_latestStmtId` | `rCompletedStmt[t]` | Int | Completed statement count |
| `TransactionRouter::_placementConflictTimeForNonSnapshotReadConcern` | `rPlacementConflictTime[t]` | Int | -1 if unset |
| `TransactionRouter::_createdDatabases` | `rCreatedDatabases[t]` | Set(String) | Set of db names |
| `MigrationSourceManager::_state` | `migrationPhase[ns]` | String | "Idle", "CritSec", "Committed" |
| `MigrationCoordinatorDocument::_decision` | `coordinatorDoc[ns]` | String | "NoDoc", "Pending", "Committed", "Aborted" |
| `ShardingState::enabled` | `donorAlive[s]` | Boolean | Is shard primary |
| `ChunkManager::getShardMaxValidAfter` | `shardLastMigrationTs[s][ns]` | Int | validAfter timestamp |

## Section 2: Action-to-Code Mapping

### 2.1 RouterSendTxnStmt

- **Spec action**: `RouterSendTxnStmt(t, ns, k)`
- **Code location**: `src/mongo/s/transaction_router.cpp:2559-2649` (appendFieldsForStartTransaction), `:626-699` (appendFieldsForContinueTransaction)
- **Trigger point**: After the router dispatches the request to the target shard
- **Trace event name**: `RouterSendTxnStmt`
- **Fields**: `txn`, `ns`, `key`, `stm` (statement number), `shard` (target shard), `rPlacementConflictTime`
- **Notes**: Capture `placementConflictTimeForNonSnapshotReadConcern` value. For the first statement (`isStartTransaction`), the PCT is freshly set. For subsequent statements, it's the stored value.

### 2.2 RouterHandleOk

- **Spec action**: `RouterHandleOk(t, stm)`
- **Code location**: `src/mongo/s/transaction_router.cpp` — response processing (successful path in `processParticipantResponse`)
- **Trigger point**: After router processes a successful response
- **Trace event name**: `RouterHandleOk`
- **Fields**: `txn`, `stm`, `rCompletedStmt`
- **Notes**: Emitted when the router advances `latestStmtId` on success.

### 2.3 RouterHandleAbort

- **Spec action**: `RouterHandleAbort(t, stm)`
- **Code location**: `src/mongo/s/transaction_router.cpp:1207-1235` (onStaleShardOrDbError — non-retryable path), general error handling
- **Trigger point**: After router decides to abort the transaction on error
- **Trace event name**: `RouterHandleAbort`
- **Fields**: `txn`, `stm`, `status` (error type: "staleRouter" or "migrationConflict")
- **Notes**: Only emitted when error is non-retryable (migrationConflict, or staleRouter on non-first stmt).

### 2.4 RouterRetryOnStale

- **Spec action**: `RouterRetryOnStale(t)`
- **Code location**: `src/mongo/s/transaction_router.cpp:1207-1235` (onStaleShardOrDbError — retryable path)
- **Trigger point**: After router decides to retry (clears participants, resets PCT)
- **Trace event name**: `RouterRetryOnStale`
- **Fields**: `txn`, `rPlacementConflictTime` (should be -1 after reset)
- **Notes**: Only fires on first statement. After this event, the router will re-send via `RouterSendTxnStmt`.

### 2.5 CreateDatabase

- **Spec action**: `CreateDatabase(t)`
- **Code location**: `src/mongo/s/transaction_router.cpp:331-349` (setPlacementConflictTimeToDatabaseVersionIfNeeded)
- **Trigger point**: After a database is added to `_createdDatabases`
- **Trace event name**: `CreateDatabase`
- **Fields**: `txn`, `db` (database name)
- **Notes**: Rare event — only when transaction creates a new database.

### 2.6 ShardRespond

- **Spec action**: `ShardRespond(t, self)`
- **Code location**: `src/mongo/db/shard_role/shard_catalog/collection_sharding_runtime.cpp:617-686` (check), `src/mongo/db/shard_role/shard_catalog/database_sharding_runtime.cpp:95-150` (db check)
- **Trigger point**: After the shard completes processing the request and sends the response
- **Trace event name**: `ShardRespond`
- **Fields**: `txn`, `shard`, `ns`, `status`, `found`, `stm`
- **Notes**: Capture the response status (ok/staleRouter/migrationConflict) and whether the key was found. The critical section check (lines 617-639) determines if `staleRouter` is returned.

### 2.7 ShardRespondAfterExec

- **Spec action**: `ShardRespondAfterExec(t, self)`
- **Code location**: `src/mongo/db/ops/write_ops_exec.cpp` — write execution followed by `ShardCannotRefreshDueToLocksHeld`
- **Trigger point**: After write is executed but error is thrown
- **Trace event name**: `ShardRespondAfterExec`
- **Fields**: `txn`, `shard`, `ns`, `stm`
- **Notes**: This is a fault-injection event. In normal operation, it won't fire. For testing, use failpoints to trigger `ShardCannotRefreshDueToLocksHeld` after write execution. SERVER-81508 reference.

### 2.8 StartMigration

- **Spec action**: `StartMigration(ns, k, from, to)`
- **Code location**: `src/mongo/db/s/migration_source_manager.cpp:550-593` (enterCriticalSection)
- **Trigger point**: After critical section is entered on the donor
- **Trace event name**: `StartMigration`
- **Fields**: `ns`, `key`, `from`, `to`, `migrationPhase` ("CritSec")
- **Notes**: Abstracts steps 1-4 (clone) into the CS entry. The coordinator doc is written before this point (`persistMigrationCoordinatorDoc`).

### 2.9 ConfigCommit

- **Spec action**: `ConfigCommit(ns)`
- **Code location**: `src/mongo/db/s/migration_source_manager.cpp:665-671` (CommitChunkMigrationRequest), `src/mongo/db/s/migration_coordinator.cpp:240` (persistCommitDecision)
- **Trigger point**: After config server confirms the commit AND the coordinator doc is updated
- **Trace event name**: `ConfigCommit`
- **Fields**: `ns`, `migrationPhase` ("Committed"), `validAfter` (shardLastMigrationTs)
- **Notes**: This is the critical Family 1 event — separate from CS entry. The `validAfter` timestamp is set by the config server.

### 2.10 ConfigCommitFail

- **Spec action**: `ConfigCommitFail(ns)`
- **Code location**: `src/mongo/db/s/migration_source_manager.cpp:681-698` (config commit failure path), `src/mongo/db/s/migration_coordinator.cpp:334` (persistAbortDecision)
- **Trigger point**: After config commit fails and abort decision is persisted
- **Trace event name**: `ConfigCommitFail`
- **Fields**: `ns`, `migrationPhase` ("Idle")
- **Notes**: Fault injection. Use failpoints: `migrationCommitNetworkError`, `failMigrationCommit`.

### 2.11 ReleaseCriticalSection

- **Spec action**: `ReleaseCriticalSection(ns)`
- **Code location**: `src/mongo/db/s/migration_source_manager.cpp:925-926` (_critSec.reset())
- **Trigger point**: After critical section is released
- **Trace event name**: `ReleaseCriticalSection`
- **Fields**: `ns`, `migrationPhase` ("Idle")
- **Notes**: Only fires from Committed phase (after successful config commit).

### 2.12 DonorStepDown

- **Spec action**: `DonorStepDown(s)`
- **Code location**: `src/mongo/db/s/migration_source_manager.cpp:863-868` (abort on step-down), `:903-994` (_cleanup)
- **Trigger point**: After the shard detects step-down during migration
- **Trace event name**: `DonorStepDown`
- **Fields**: `shard`, `ns`, `migrationPhase` (phase at time of step-down)
- **Notes**: The non-deterministic config commit outcome is determined by checking config server state after step-up.

### 2.13 DonorStepUp

- **Spec action**: `DonorStepUp(s)`
- **Code location**: `src/mongo/db/s/shard_filtering_metadata_refresh.cpp:495-634` (_recoverMigrationCoordinations)
- **Trigger point**: After new primary starts and begins migration recovery
- **Trace event name**: `DonorStepUp`
- **Fields**: `shard`
- **Notes**: Triggers migration recovery if coordinator docs exist.

### 2.14 DonorRecovery

- **Spec action**: `DonorRecovery(s, ns)`
- **Code location**: `src/mongo/db/s/migration_coordinator.cpp:183-229` (completeMigration), `src/mongo/db/s/migration_util.cpp:356-414` (resumeMigrationCoordinationsOnStepUp)
- **Trigger point**: After recovery completes (coordinator doc cleaned up)
- **Trace event name**: `DonorRecovery`
- **Fields**: `shard`, `ns`, `coordinatorDoc` (decision inferred: "Committed" or "Aborted")
- **Notes**: For DocPending recovery, the decision is inferred from config server metadata.

## Section 3: Special Considerations

### 3.1 State Accessibility

| State | Access method | Notes |
|---|---|---|
| `rPlacementConflictTime` | `TransactionRouter::Observer::_placementConflictTimeForNonSnapshotReadConcern` | Private member, may need accessor or friend function |
| `coordinatorDoc` decision | `MigrationCoordinatorDocument::getDecision()` | Stored in `config.migrationCoordinators` collection |
| `donorAlive` | Replica set primary status | Use `ReplicationCoordinator::getMemberState()` |
| `shardLastMigrationTs` | `ChunkManager::getShardMaxValidAfter()` | Requires filtering metadata access |

### 3.2 Concurrency

- **Router and shard threads**: Router dispatches requests on one thread; shard processes on another. Events may interleave across different transactions. Use per-transaction sequence numbers to order events within a transaction.
- **Migration thread**: Runs on a separate thread from shard request processing. Migration events and ShardRespond events for the same namespace can interleave.
- **Step-down**: Detected asynchronously. The step-down event should be emitted when the migration cleanup begins, not when the step-down is first detected.

### 3.3 Bootstrap State

- `TraceInit` uses the base `Init` which allows arbitrary initial `ranges`. For trace validation, the initial routing should match the cluster's initial state. Set `ranges` via the first trace event or use a special `Init` event.
- `shardLastMigrationTs` starts at `INIT_MIGRATION_TS = 100`. The real system starts at 0. Adjust the trace preprocessing to add the offset, or change `INIT_MIGRATION_TS` to match.

### 3.4 Docker Compose Setup

See `case-studies/mongodb-shared-harness.md` for the sharding cluster Docker template. Key configuration:
- 2-shard cluster (shard0, shard1)
- Config server replica set
- mongos router
- Map shard0 → s1, shard1 → s2

### 3.5 Trace Preprocessing

The raw MongoDB logs need preprocessing into the NDJSON format expected by `Trace.tla`:
1. Parse mongos (router) and mongod (shard) logs
2. Extract relevant operations (transaction statements, migration events)
3. Map internal identifiers to spec constants (shard names, namespace names)
4. Order events by timestamp (causal ordering within a transaction)
5. Add `event` field matching the spec action names

### 3.6 Failpoints for Fault Injection Events

| Event | Failpoint | Notes |
|---|---|---|
| ConfigCommitFail | `migrationCommitNetworkError` | Simulates network error during config commit |
| ShardRespondAfterExec | `hangAfterBatchUpdate` + manual kill | Requires careful timing |
| DonorStepDown | `moveChunkHangAtStep5` + `replSetStepDown` | Step down during config commit phase |
