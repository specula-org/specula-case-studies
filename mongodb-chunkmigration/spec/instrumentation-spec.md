# Instrumentation Spec: MongoDB Chunk Migration

Action-to-code mapping for trace harness generation.

## Section 1: Trace Event Schema

### Common Envelope

```json
{
  "tag": "trace",
  "ts": "<ISO-8601>",
  "event": {
    "name": "<action-name>",
    "mid": "<migration-id>",
    "state": {
      "activeMigration": "<mid|nil>",
      "migrationPhase": "<phase>",
      "cleanupPhase": "<step>",
      "cleanupMid": "<mid|nil>"
    }
  }
}
```

### State Fields

| Implementation getter | TLA+ variable | Type |
|---|---|---|
| `_state` (MigrationSourceManager) | `migrationPhase` | string: idle/prepared/committingOnConfig/cleaning |
| Active migration ID or null | `activeMigration` | string: migration UUID or "nil" |
| Cleanup sub-step tracker | `cleanupPhase` | string: noCleanup/cmtPersist/.../cleanupDone |
| Migration being cleaned up | `cleanupMid` | string: migration UUID or "nil" |

## Section 2: Action-to-Code Mapping

### Lifecycle Actions

| Spec Action | Code Location | Trigger Point | Event Name | Notes |
|---|---|---|---|---|
| `StartMigration` | `migration_coordinator.cpp:147-170` | After `createAndPersistRangeDeletionTask` returns (line 169) | `StartMigration` | Capture migration ID from `_migrationInfo.getId()` |
| `AdvanceToConfigCommit` | `migration_source_manager.cpp:661` | After `_state = kCommittingOnConfig` | `AdvanceToConfigCommit` | Abstraction: emit once when entering CommittingOnConfig |
| `ConfigCommitSucceed` | `migration_source_manager.cpp:778` | After `setMigrationDecision(kCommitted)` | `ConfigCommitSucceed` | Only on success path |
| `ConfigCommitFail` | `migration_source_manager.cpp:694` | Before `_cleanup(false)` in error handler | `ConfigCommitFail` | Captures limbo entry point |
| `AbortBeforeConfigCommit` | `migration_source_manager.cpp:953-954` | After `setMigrationDecision(kAborted)` in `_cleanup` | `AbortBeforeConfigCommit` | Only when `_state < kCommittingOnConfig` |

### Commit Cleanup Sub-Steps

| Spec Action | Code Location | Trigger Point | Event Name | Notes |
|---|---|---|---|---|
| `DoCommitPersist` | `migration_coordinator.cpp:240` | After `persistCommitDecision` returns | `DoCommitPersist` | Idempotent — NoMatchingDocument caught |
| `DoCommitAdvanceTxn` | `migration_coordinator.cpp:252-255` | After `advanceTransactionOnRecipient` returns | `DoCommitAdvanceTxn` | Bug Family 2: no ShardNotFound handling |
| `DoCommitRetrieveOrphans` | `migration_coordinator.cpp:265-266` | After `retrieveNumOrphansFromShard` returns | `DoCommitRetrieveOrphans` | Bug Family 2: no ShardNotFound handling |
| `DoCommitPersistOrphans` | `migration_coordinator.cpp:269-271` | After `persistUpdatedNumOrphans` returns | `DoCommitPersistOrphans` | Only if `numOrphans > 0`. Bug Family 1+5 |
| `DoCommitDeleteRecipientTask` | `migration_coordinator.cpp:278-282` | After `deleteRangeDeletionTaskOnRecipient` returns | `DoCommitDeleteRecipientTask` | Bug Family 2: no ShardNotFound handling |
| `DoCommitGetDonorTask` | `migration_coordinator.cpp:285-294` | After `getRangeDeletionTask` returns | `DoCommitGetDonorTask` | Bug Family 1: no migrationId in filter |
| `DoCommitMarkReady` | `migration_coordinator.cpp:320-321` | After `markAsReadyRangeDeletionTaskLocally` returns | `DoCommitMarkReady` | Bug Family 1: no migrationId in filter |
| `DoCommitForget` | `migration_coordinator.cpp:226` | After `forgetMigration` returns | `DoCommitForget` | Bug Family 5: w:1 write concern |

### Abort Cleanup Sub-Steps

| Spec Action | Code Location | Trigger Point | Event Name | Notes |
|---|---|---|---|---|
| `DoAbortPersist` | `migration_coordinator.cpp:334` | After `persistAbortDecision` returns | `DoAbortPersist` | Idempotent |
| `DoAbortDeleteLocal` | `migration_coordinator.cpp:347-350` | After `deleteRangeDeletionTaskLocally` returns | `DoAbortDeleteLocal` | Bug Family 1: no migrationId in filter. Majority WC |
| `DoAbortAdvanceTxn` | `migration_coordinator.cpp:361-364` | After `advanceTransactionOnRecipient` returns (or catch) | `DoAbortAdvanceTxn` | Has ShardNotFound handling (line 365-375) |
| `DoAbortMarkRecipient` | `migration_coordinator.cpp:382-386` | After `markAsReadyRangeDeletionTaskOnRecipient` returns | `DoAbortMarkRecipient` | Has correct filter (migrationId) + ShardNotFound handling |
| `DoAbortForget` | `migration_coordinator.cpp:226` | After `forgetMigration` returns (abort path) | `DoAbortForget` | Bug Family 5: w:1 write concern |

### Completion and Recovery

| Spec Action | Code Location | Trigger Point | Event Name | Notes |
|---|---|---|---|---|
| `CleanupComplete` | `migration_source_manager.cpp:974` | After `_state = kDone` | `CleanupComplete` | |
| `Stepdown` | `migration_source_manager.cpp:863-869` | After `_opCtx->markKilled()` in `abort()`, or on replica set stepdown event | `Stepdown` | Captures all stepdown paths |
| `RecoverMigration` | `migration_util.cpp:362-386` | At start of `resumeMigrationCoordinationsOnStepUp` forEach, per doc | `RecoverMigration` | Emit migration ID from coordinator doc |
| `RecoverFromLimbo` | `migration_util.cpp:362-386` | When coordinator doc has no decision, after querying config | `RecoverFromLimbo` | Emit the resolved decision |

## Section 3: Special Considerations

### Migration ID Tracking

The migration ID (`_migrationInfo.getId()`) is a UUID generated in the `MigrationCoordinator` constructor (`migration_coordinator.cpp:101`). All trace events must capture this ID to enable the trace spec to map events to the correct migration.

For trace validation with `MigrationId = {m1, m2}`, the harness must map actual UUIDs to spec constants in order of first encounter.

### Coordinator Document Persistence

The coordinator document is created with majority write concern (`migration_coordinator.cpp:150`) and deleted with w:1 (`migration_coordinator.cpp:400`). The harness should capture the write concern used for each operation to validate the durability model.

### Range Deletion Task State

The harness should capture the `pending` field of range deletion tasks when they are created, updated, or deleted. This enables validation of Bug Family 1 (wrong task targeted).

### Recovery Path Instrumentation

Recovery runs on a new `OperationContext` (`migration_source_manager.cpp:957-961`). The harness must instrument the recovery code path in `migration_util.cpp:356-414` (`resumeMigrationCoordinationsOnStepUp`) separately from the normal migration path.

### Stepdown Detection

Stepdown can be detected via:
1. `MigrationSourceManager::abort()` (line 863-869) — explicit abort
2. Replica set stepdown event — implicit, detected by the replication coordinator

The harness should emit a `Stepdown` event from both paths.

### Thread Safety

The migration source manager runs on a single thread per shard (`ActiveMigrationsRegistry` enforcement at `migration_source_manager.cpp:193`). Recovery runs on separate threads via the executor pool. Trace events from recovery may interleave with the main thread — use the migration ID to disambiguate.
