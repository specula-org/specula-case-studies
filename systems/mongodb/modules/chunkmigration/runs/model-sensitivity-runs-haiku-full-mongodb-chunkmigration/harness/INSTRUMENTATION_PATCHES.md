# MongoDB Chunk Migration: Instrumentation Patch Points

This document lists where trace emission calls would be inserted in real MongoDB source code, organized by instrumentation spec section.

## File: migration_coordinator.cpp

### DonorPersistCommitDecision (line 240)

**Location**: `_commitMigrationOnDonorAndRecipient()` function, after `persistCommitDecision()`

```cpp
// BEFORE:
migrationutil::persistCommitDecision(opCtx, _migrationInfo);

// AFTER (add):
{
    std::map<std::string, std::string> fields;
    fields["decision"] = "Commit";
    // ... capture all state ...
    TraceEmitter::getInstance().emitEvent("DonorPersistCommitDecision", "donor", fields);
}
migrationutil::persistCommitDecision(opCtx, _migrationInfo);
```

**State to capture**:
- `coordinatorDecision = Commit` → field "decision"
- Donor/recipient states from migration context
- Critical section active flag from collection sharding runtime

### DonorPersistAbortDecision (line 334)

**Location**: `_abortMigrationOnDonorAndRecipient()` function, after `persistAbortDecision()`

```cpp
migrationutil::persistAbortDecision(opCtx, _migrationInfo);
// ADD TRACE:
{
    std::map<std::string, std::string> fields;
    fields["decision"] = "Abort";
    // ... capture all state ...
    TraceEmitter::getInstance().emitEvent("DonorPersistAbortDecision", "donor", fields);
}
```

### LaunchReleaseRecipientCriticalSection (line 405)

**Location**: `launchReleaseRecipientCriticalSection()` function, after future assignment

```cpp
void MigrationCoordinator::launchReleaseRecipientCriticalSection(OperationContext* opCtx) {
    _releaseRecipientCriticalSectionFuture =
        migrationutil::launchReleaseCriticalSectionOnRecipientFuture(
            opCtx,
            _migrationInfo.getRecipientShardId(),
            _migrationInfo.getNss(),
            _migrationInfo.getMigrationSessionId());
    
    // ADD TRACE:
    {
        std::map<std::string, std::string> fields;
        fields["releaseState"] = "in_flight";
        // ... capture all state ...
        TraceEmitter::getInstance().emitEvent("LaunchReleaseRecipientCriticalSection", "donor", fields);
    }
}
```

### DonorDeleteRangeDeletionTaskLocally (line 347)

**Location**: `_abortMigrationOnDonorAndRecipient()` function, after `deleteRangeDeletionTaskLocally()`

```cpp
rangedeletionutil::deleteRangeDeletionTaskLocally(opCtx, ...);
// ADD TRACE:
{
    std::map<std::string, std::string> fields;
    fields["taskState"] = "deleted";
    TraceEmitter::getInstance().emitEvent("DonorDeleteRangeDeletionTaskLocally", "donor", fields);
}
```

### AbortBumpRecipientTxnNumber (line 361)

**Location**: `_abortMigrationOnDonorAndRecipient()` function, after `advanceTransactionOnRecipient()`

```cpp
migrationutil::advanceTransactionOnRecipient(opCtx, ...);
// ADD TRACE:
{
    std::map<std::string, std::string> fields;
    fields["decision"] = "Abort";
    TraceEmitter::getInstance().emitEvent("AbortBumpRecipientTxnNumber", "donor", fields);
}
```

### AbortRecipientNotificationFails (line 365)

**Location**: Inside catch block in `_abortMigrationOnDonorAndRecipient()`

```cpp
try {
    migrationutil::advanceTransactionOnRecipient(opCtx, ...);
    rangedeletionutil::markAsReadyRangeDeletionTaskOnRecipient(opCtx, ...);
} catch (const ExceptionFor<ErrorCodes::ShardNotFound>& exShardNotFound) {
    // ADD TRACE:
    {
        std::map<std::string, std::string> fields;
        fields["failureType"] = "ShardNotFound";
        fields["recipientTaskState"] = "pending";
        TraceEmitter::getInstance().emitEvent("AbortRecipientNotificationFails", "donor", fields);
    }
    LOGV2_DEBUG(...);
}
```

### AbortMarkRecipientRangeDeletionReady (line 382)

**Location**: After `markAsReadyRangeDeletionTaskOnRecipient()` in abort path

```cpp
rangedeletionutil::markAsReadyRangeDeletionTaskOnRecipient(opCtx, ...);
// ADD TRACE:
{
    std::map<std::string, std::string> fields;
    fields["recipientTaskState"] = "ready";
    TraceEmitter::getInstance().emitEvent("AbortMarkRecipientRangeDeletionReady", "donor", fields);
}
```

### ForgetMigration (line 389)

**Location**: `forgetMigration()` function, after coordinator doc deletion

```cpp
void MigrationCoordinator::forgetMigration(OperationContext* opCtx) {
    PersistentTaskStore<MigrationCoordinatorDocument> store(...);
    store.remove(opCtx, ...);
    
    // ADD TRACE:
    {
        std::map<std::string, std::string> fields;
        fields["donorState"] = "Done";
        TraceEmitter::getInstance().emitEvent("ForgetMigration", "donor", fields);
    }
}
```

## File: migration_source_manager.cpp

### DonorEnterCriticalSection (line 550-593)

**Location**: Function that enters critical section on donor

**Pseudo-code**:
```cpp
// In critical section entry function:
auto critSec = collection->getCollectionShardingRuntime()->acquireCriticalSectionLock(...);
// ADD TRACE:
{
    std::map<std::string, std::string> fields;
    fields["criticalSectionActive"] = "true";
    TraceEmitter::getInstance().emitEvent("DonorEnterCriticalSection", "donor", fields);
}
```

### DonorSendConfigServerCommit (line 626-672)

**Location**: Before config server commit RPC

```cpp
// Before:
auto commitRes = shardRegistry()->getConfigShard()->runCommand(
    opCtx,
    "admin",
    buildCommitCommand(),
    ...
);

// ADD TRACE (before RPC):
{
    std::map<std::string, std::string> fields;
    fields["donorState"] = "CommittingOnConfig";
    TraceEmitter::getInstance().emitEvent("DonorSendConfigServerCommit", "donor", fields);
}
```

### ConfigServerCommitFails (line 681-690)

**Location**: After commit RPC fails and metadata is cleared

```cpp
if (!commitRes.isOK()) {
    // Clear metadata
    collection->getCollectionShardingRuntime()->clearFilteringMetadata(opCtx);
    
    // ADD TRACE:
    {
        std::map<std::string, std::string> fields;
        fields["donorMetadata"] = "not_owned";
        fields["failureType"] = "CommitFailed";
        TraceEmitter::getInstance().emitEvent("ConfigServerCommitFails", "donor", fields);
    }
}
```

## File: migration_destination_manager.cpp

### RecipientStartClone (beginning of clone phase)

**Location**: When recipient starts cloning documents

```cpp
// In recipient clone initialization:
{
    std::map<std::string, std::string> fields;
    fields["recipientState"] = "Init";
    TraceEmitter::getInstance().emitEvent("RecipientStartClone", "recipient", fields);
}
```

### RecipientCloneComplete (after clone finishes)

**Location**: After recipient completes cloning

```cpp
// After clone documents complete:
{
    std::map<std::string, std::string> fields;
    fields["recipientState"] = "Cloned";
    TraceEmitter::getInstance().emitEvent("RecipientCloneComplete", "recipient", fields);
}
```

### CriticalSectionReleaseSucceeds (after release completes)

**Location**: Handler for successful critical section release on recipient

```cpp
// When recipient critical section is released:
{
    std::map<std::string, std::string> fields;
    fields["criticalSectionActive"] = "false";
    fields["releaseState"] = "released";
    TraceEmitter::getInstance().emitEvent("CriticalSectionReleaseSucceeds", "recipient", fields);
}
```

### CriticalSectionReleaseFails (when release fails)

**Location**: In exception handler for critical section release timeout

```cpp
catch (const DBException& ex) {
    if (ex.code() == ErrorCodes::ShardNotFound) {
        // ADD TRACE:
        {
            std::map<std::string, std::string> fields;
            fields["releaseState"] = "released";  // From spec validation
            fields["failureType"] = "ShardNotFound";
            TraceEmitter::getInstance().emitEvent("CriticalSectionReleaseFails", "recipient", fields);
        }
    }
}
```

### AbortCleanup (recipient abort cleanup)

**Location**: When recipient completes abort cleanup

```cpp
// At end of recipient abort:
{
    std::map<std::string, std::string> fields;
    fields["recipientState"] = "Done";
    TraceEmitter::getInstance().emitEvent("AbortCleanup", "recipient", fields);
}
```

## File: migration_util.cpp

### DonorDeleteRecipientRangeDeletionTask (after RPC completes)

**Location**: In `deleteRangeDeletionTaskOnRecipient()` function

```cpp
// After RPC to recipient succeeds:
{
    std::map<std::string, std::string> fields;
    fields["recipientTaskState"] = "deleted";
    TraceEmitter::getInstance().emitEvent("DonorDeleteRecipientRangeDeletionTask", "donor", fields);
}
```

### DonorRegisterRangeDeletionTask (after task registration)

**Location**: After `rangeDeleterService->registerTask()` completes

```cpp
auto future = rangeDeleterService->registerTask(rangeDeletionTask);
future.get(opCtx);  // Wait for completion
// ADD TRACE:
{
    std::map<std::string, std::string> fields;
    fields["taskState"] = "ready";
    TraceEmitter::getInstance().emitEvent("DonorRegisterRangeDeletionTask", "donor", fields);
}
```

## Integration Notes

### Initialization

In migration coordinator startup, initialize trace file:
```cpp
#include "mongo/db/s/tla_trace.h"

auto traceFile = std::getenv("TLA_TRACE_FILE");
if (traceFile) {
    tla_trace::TraceEmitter::getInstance().init(traceFile);
}
```

### Node ID Mapping

Currently all events use "donor" or "recipient" as node ID. For multi-shard tracing:
```cpp
std::string nodeId = shardId.toString();  // e.g., "shard-0"
```

### State Snapshots

Each event should capture the full state snapshot for validation. Recommended approach:
```cpp
std::map<std::string, std::string> fields;
// Donor state
fields["donorState"] = getDonorStateString();
// Recipient state  
fields["recipientState"] = getRecipientStateString();
// Coordinator decision
fields["decision"] = getDecisionString();
// ... all other fields from instrumentation spec ...
```

### Error Handling

Trace emission is fire-and-forget; failures should not affect migration flow:
```cpp
try {
    TraceEmitter::getInstance().emitEvent("EventName", nodeId, fields);
} catch (const std::exception& ex) {
    LOGV2_DEBUG(22222, "Trace emission failed (non-fatal)", "error"_attr = ex.what());
    // Continue with migration logic
}
```
