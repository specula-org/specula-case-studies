# MongoDB Chunk Migration: Instrumentation Spec

Maps TLA+ spec actions to source code locations and trace event fields for real execution tracing.

## Section 1: Trace Event Schema

### Event Envelope
```json
{
  "type": "string",              // Action name (e.g., "DonorPersistCommitDecision")
  "timestamp": "integer",        // Wallclock timestamp (us)
  "nodeId": "string",            // Node identifier (donor, recipient, configServer)
  "migrationId": "string"        // Unique migration identifier
}
```

### State Fields (captured at every event)

| TLA+ Variable | Implementation | Event Field | Type | Notes |
|---|---|---|---|---|
| `donorState` | `MigrationSourceManager::_state` | `donorState` | string | From state machine |
| `recipientState` | `MigrationDestinationManager::_state` | `recipientState` | string | From state machine |
| `configState` | (implicit in coordinator flow) | `configState` | string | Inferred from decision persistence |
| `donorMetadata` | `CollectionShardingRuntime` | `donorMetadata` | string | "owned" or "not_owned" |
| `recipientMetadata` | `CollectionShardingRuntime` | `recipientMetadata` | string | "owned" or "not_owned" |
| `criticalSectionActive` | `CollectionShardingRuntime::_critSec` | `criticalSectionActive` | boolean | Is critical section active |
| `donorRangeDeletionTask` | `MigrationCoordinator::_donorRangeDeletionTask` | `donorRangeDeletionTask` | string | pending/ready/deleted |
| `recipientRangeDeletionTask` | (recipient-side task doc) | `recipientRangeDeletionTask` | string | pending/ready/deleted |
| `coordinatorDecision` | `MigrationCoordinatorDocument::_decision` | `decision` | string | Commit/Abort/Undecided |
| `recipientCritSectionReleased` | `MigrationCoordinator::_releaseRecipientCriticalSectionFuture` | `releaseState` | string | not_released/in_flight/released |

---

## Section 2: Action-to-Code Mapping

### RecipientStartClone
- **Spec action**: `RecipientStartClone`
- **Code location**: `migration_destination_manager.cpp` (recipient initialization)
- **Trigger point**: Before recipient starts cloning
- **Trace event name**: `RecipientStartClone`
- **Fields to capture**: `recipientState` (should be "Init")
- **Notes**: Marks start of data transfer phase

### RecipientCloneComplete
- **Spec action**: `RecipientCloneComplete`
- **Code location**: `migration_destination_manager.cpp` (after clone completes)
- **Trigger point**: After recipient completes cloning documents
- **Trace event name**: `RecipientCloneComplete`
- **Fields to capture**: `recipientClone` (should be "cloned"), `recipientState`
- **Notes**: Indicates readiness to enter critical section

### DonorEnterCriticalSection
- **Spec action**: `DonorEnterCriticalSection`
- **Code location**: `migration_source_manager.cpp:550-593`
- **Trigger point**: Before entering critical section (read-only mode)
- **Trace event name**: `DonorEnterCriticalSection`
- **Fields to capture**: `criticalSectionActive` (should be TRUE), `donorState`
- **Notes**: Donor transitions from cloning to read-only; recipient must have completed clone

### DonorPersistCommitDecision
- **Spec action**: `DonorPersistCommitDecision`
- **Code location**: `migration_coordinator.cpp:233-240`
- **Trigger point**: After `migrationutil::persistCommitDecision(opCtx, _migrationInfo)` completes
- **Trace event name**: `DonorPersistCommitDecision`
- **Fields to capture**: `coordinatorDecision` (should be "Commit"), `timestamp`
- **Notes**: **CRITICAL CRASH WINDOW 1**: Donor has persisted decision but recipient not yet released

### DonorPersistAbortDecision
- **Spec action**: `DonorPersistAbortDecision`
- **Code location**: `migration_coordinator.cpp:327-334`
- **Trigger point**: After `migrationutil::persistAbortDecision(opCtx, _migrationInfo)` completes
- **Trace event name**: `DonorPersistAbortDecision`
- **Fields to capture**: `coordinatorDecision` (should be "Abort")
- **Notes**: Marks decision to abort the migration

### DonorSendConfigServerCommit
- **Spec action**: `DonorSendConfigServerCommit`
- **Code location**: `migration_source_manager.cpp:626-672`
- **Trigger point**: Before `shardRegistry()->getConfigShard()->runCommand()` for commit
- **Trace event name**: `DonorSendConfigServerCommit`
- **Fields to capture**: `donorState` (should be "CommittingOnConfig"), `timestamp`
- **Notes**: Donor enters commit phase with config server; critical section enforced on donor

### ConfigServerPersistCommit
- **Spec action**: `ConfigServerPersistCommit`
- **Code location**: `config_server.cpp` (config server commit logic)
- **Trigger point**: After config server persists commit decision
- **Trace event name**: `ConfigServerPersistCommit`
- **Fields to capture**: `configState` (should be "Committed")
- **Notes**: Only traced if config server instrumentation available; else infer from success

### ConfigServerCommitFails
- **Spec action**: `ConfigServerCommitFails`
- **Code location**: `migration_source_manager.cpp:681-690`
- **Trigger point**: After commit RPC fails and metadata is cleared
- **Trace event name**: `ConfigServerCommitFails`
- **Fields to capture**: `donorMetadata` (should be "not_owned"), `failureType`
- **Notes**: **CRITICAL RACE WINDOW (Family 2)**: Donor has cleared metadata but recipient critical section still active

### LaunchReleaseRecipientCriticalSection
- **Spec action**: `LaunchReleaseRecipientCriticalSection`
- **Code location**: `migration_coordinator.cpp:403-410`
- **Trigger point**: After `_releaseRecipientCriticalSectionFuture = migrationutil::launchReleaseCriticalSectionOnRecipientFuture(...)`
- **Trace event name**: `LaunchReleaseRecipientCriticalSection`
- **Fields to capture**: `releaseState` (should be "in_flight")
- **Notes**: Launches async RPC to release recipient critical section

### CriticalSectionReleaseSucceeds
- **Spec action**: `CriticalSectionReleaseSucceeds`
- **Code location**: `migration_destination_manager.cpp` (critical section release handler)
- **Trigger point**: After recipient successfully exits critical section
- **Trace event name**: `CriticalSectionReleaseSucceeds`
- **Fields to capture**: `criticalSectionActive` (should be FALSE), `releaseState` (should be "released")
- **Notes**: Recipient no longer blocks reads/writes

### CriticalSectionReleaseFails
- **Spec action**: `CriticalSectionReleaseFails`
- **Code location**: `migration_coordinator.cpp:412-424`
- **Trigger point**: After release RPC times out or fails with ShardNotFound
- **Trace event name**: `CriticalSectionReleaseFails`
- **Fields to capture**: `failureType` (should be "ShardNotFound"), `releaseState` (should be "released")
- **Notes**: **CRITICAL LIVENESS ISSUE (Family 4)**: Coordinator gives up but recipient may still be blocked

### DonorDeleteRangeDeletionTaskLocally
- **Spec action**: `DonorDeleteRangeDeletionTaskLocally`
- **Code location**: `migration_coordinator.cpp:285-288` (commit path)
- **Trigger point**: After reading/preparing donor range deletion task for processing
- **Trace event name**: `DonorDeleteRangeDeletionTaskLocally`
- **Fields to capture**: `donorRangeDeletionTask` (should be "ready")
- **Notes**: Part of commit cleanup; task is registered for async deletion

### DonorRegisterRangeDeletionTask
- **Spec action**: `DonorRegisterRangeDeletionTask`
- **Code location**: `migration_coordinator.cpp:309-311`
- **Trigger point**: After `rangeDeleterService->registerTask()` completes
- **Trace event name**: `DonorRegisterRangeDeletionTask`
- **Fields to capture**: `donorRangeDeletionTask` (should be "ready")
- **Notes**: Task is now pending deletion; must wait for recipient critical section release

### DonorDeleteRecipientRangeDeletionTask
- **Spec action**: `DonorDeleteRecipientRangeDeletionTask`
- **Code location**: `migration_coordinator.cpp:278-282`
- **Trigger point**: After `rangedeletionutil::deleteRangeDeletionTaskOnRecipient()` RPC completes
- **Trace event name**: `DonorDeleteRecipientRangeDeletionTask`
- **Fields to capture**: `recipientRangeDeletionTask` (should be "deleted")
- **Notes**: Cleanup of orphaned data on recipient side during commit

### AbortDeleteDonorRangeDeletionTask
- **Spec action**: `AbortDeleteDonorRangeDeletionTask`
- **Code location**: `migration_coordinator.cpp:347-350`
- **Trigger point**: After `rangedeletionutil::deleteRangeDeletionTaskLocally()` completes in abort path
- **Trace event name**: `AbortDeleteDonorRangeDeletionTask`
- **Fields to capture**: `donorRangeDeletionTask` (should be "deleted")
- **Notes**: **CRITICAL CRASH WINDOW 1 (Family 3)**: Donor task deleted but recipient not yet notified

### AbortBumpRecipientTxnNumber
- **Spec action**: `AbortBumpRecipientTxnNumber`
- **Code location**: `migration_coordinator.cpp:361-364`
- **Trigger point**: After `advanceTransactionOnRecipient()` RPC completes
- **Trace event name**: `AbortBumpRecipientTxnNumber`
- **Fields to capture**: `decision` (should be "Abort")
- **Notes**: **CRASH WINDOW 2 (Family 3)**: Txn bumped but task not yet marked ready

### AbortMarkRecipientRangeDeletionReady
- **Spec action**: `AbortMarkRecipientRangeDeletionReady`
- **Code location**: `migration_coordinator.cpp:382-386`
- **Trigger point**: After `markAsReadyRangeDeletionTaskOnRecipient()` completes
- **Trace event name**: `AbortMarkRecipientRangeDeletionReady`
- **Fields to capture**: `recipientRangeDeletionTask` (should be "ready")
- **Notes**: Recipient can now proceed with orphan cleanup; can fail with ShardNotFound

### AbortRecipientNotificationFails
- **Spec action**: `AbortRecipientNotificationFails`
- **Code location**: `migration_coordinator.cpp:365-375`
- **Trigger point**: After catching exception during abort notification
- **Trace event name**: `AbortRecipientNotificationFails`
- **Fields to capture**: `failureType` (should be "ShardNotFound"), `recipientRangeDeletionTask` (should be "pending")
- **Notes**: **CRITICAL INCONSISTENCY (Family 5)**: Recipient left with orphaned task that will never be cleaned

### ForgetMigration
- **Spec action**: `ForgetMigration`
- **Code location**: `migration_coordinator.cpp:389-401`
- **Trigger point**: After migration coordinator document is deleted
- **Trace event name**: `ForgetMigration`
- **Fields to capture**: `donorState` (should be "Done")
- **Notes**: Final cleanup; migration coordinator doc removed from durable storage

### AbortCleanup
- **Spec action**: `AbortCleanup`
- **Code location**: `migration_destination_manager.cpp` (abort cleanup on recipient)
- **Trigger point**: After recipient cleanup completes
- **Trace event name**: `AbortCleanup`
- **Fields to capture**: `recipientState` (should be "Done")
- **Notes**: Recipient has cleaned up critical section and is done

---

## Section 3: Special Considerations

### Async RPC Timing
- **Release critical section** (`CriticalSectionReleaseSucceeds` vs `CriticalSectionReleaseFails`): The RPC is launched early (line 205 in `completeMigration`) but awaited later (line 242 for commit, line 338 for abort). Trace the completion point, not the launch.
- **Donor range deletion task registration**: Task registration is async via `registerTask()` future. Trace after the future completes (line 311).

### Crash/Recovery Instrumentation
- **Donor crash**: Trace when donor loses in-memory state (at `donorState` reset to "Init"). Recovery is when it re-enters state machine.
- **Recipient crash**: Similar pattern; only trace if explicitly handled in code paths we're modeling.

### Bootstrap/Initial State
- **Coordinator doc creation**: Happens early in `startMigration()` (line 150). If not modeling clone phase, trace the coordinator doc insertion.
- **Range deletion task creation**: Persisted in `startMigration()` (lines 158-169). Capture initial task state as "pending".

### Field Serialization Quirks
- **Decision fields**: May be stored as enum integers in MongoDB; map: 0 = Undecided, 1 = Commit, 2 = Abort.
- **Critical section state**: Stored implicitly via `_critSec` optional; capture as boolean (active vs not).
- **Range deletion task states**: Stored via `DeferredDeletionStatus` enum; map: 0 = pending, 1 = ready, 2 = completed/deleted.

### Multi-Location Actions
Some spec actions map to multiple code sites (e.g., error path + success path):
- **ConfigServerCommitFails**: Two paths in `migration_source_manager.cpp:681-690` (failure after RPC) and `migration_coordinator.cpp` (error handling). Instrument both.
- **AbortRecipientNotificationFails**: Try-catch in `migration_coordinator.cpp:352-375`. Trace the catch block.

### Liveness Properties Not Modeled
- **Interruptibility (Family 6)**: The five `UninterruptibleLockGuard` locations are implementation details. Not traced because they don't affect protocol correctness.
- **Batch cloning**: Cloning algorithm is not traced; only clone completion is modeled.

---

## Trace Event Examples

```json
{"type": "DonorPersistCommitDecision", "timestamp": 1234567890, "nodeId": "donor", "migrationId": "abc123", "decision": "Commit"}
{"type": "CriticalSectionReleaseFails", "timestamp": 1234567891, "nodeId": "donor", "migrationId": "abc123", "failureType": "ShardNotFound", "releaseState": "released"}
{"type": "AbortRecipientNotificationFails", "timestamp": 1234567892, "nodeId": "donor", "migrationId": "abc123", "failureType": "ShardNotFound", "recipientRangeDeletionTask": "pending"}
```
