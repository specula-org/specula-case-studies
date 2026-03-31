# Instrumentation Spec: MongoDB MoveRange Commit Protocol

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "shard": "<shard_id>",
  "key": "<key/range_id>",
  "donor": "<donor_shard_id>",
  "recipient": "<recipient_shard_id>",
  "migState": "<migration_state>",
  "configOwner": "<owning_shard_per_config>",
  "ts": "<ISO8601_timestamp>"
}
```

### State Fields

| Implementation Field | TLA+ Variable | Capture Method |
|---------------------|---------------|----------------|
| `MigrationCoordinatorDocument._id` | (migration identity) | `doc.getId()` |
| `MigrationCoordinatorDocument.decision` | `coordDoc[shard].decision` | `doc.getDecision()` |
| `MigrationCoordinatorDocument.donorShardId` | `migDonor[key]` | `doc.getDonorShardId()` |
| `MigrationCoordinatorDocument.recipientShardId` | `migRecipient[key]` | `doc.getRecipientShardId()` |
| `ShardingState::get()->enabled()` | `isPrimary[shard]` | Replication coordinator primary check |
| `CollectionShardingRuntime` critical section | `donorCritSec[shard]` / `recipientCritSec[shard]` | CSR metadata state |
| `config.rangeDeletions` task state | `rangeDel[shard][key]` | Query range deletion task document |
| Config server chunk ownership | `configOwner[key]` | `Grid::get()->catalogClient()->getChunks()` |

## Section 2: Action-to-Code Mapping

### 1. StartMigration
- **Code location**: `migration_coordinator.cpp:147-170` (`MigrationCoordinator::startMigration`)
- **Trigger point**: After `insertMigrationCoordinatorDoc` (line 150) and `createAndPersistRangeDeletionTask` (line 158)
- **Trace event name**: `StartMigration`
- **Fields**: `event`, `shard` (donor), `key` (range), `donor`, `recipient`
- **Notes**: Emit after both coordinator doc and range deletion task are persisted. The donor shard is the emitter.

### 2. RecipientEnterCriticalSection
- **Code location**: `migration_destination_manager.cpp` — when recipient acquires critical section during `_recvChunkCommit`
- **Trigger point**: After `_critSec->enterCriticalSection()` on recipient
- **Trace event name**: `RecipientEnterCriticalSection`
- **Fields**: `event`, `shard` (recipient), `key`
- **Notes**: The recipient shard emits this. Must be emitted AFTER the critical section is durably acquired.

### 3. DonorEnterCriticalSection
- **Code location**: `migration_source_manager.cpp:659` (`_critSec->enterCommitPhase()`)
- **Trigger point**: After `_critSec->enterCommitPhase()` succeeds
- **Trace event name**: `DonorEnterCriticalSection`
- **Fields**: `event`, `shard` (donor), `key`
- **Notes**: Donor emits. This is the commit phase of the two-phase critical section.

### 4. CommitOnConfigServer
- **Code location**: `migration_source_manager.cpp:665-671` (config shard `runCommand`)
- **Trigger point**: After receiving successful response from config server (line 678, `migrationCommitStatus.isOK()`)
- **Trace event name**: `CommitOnConfigServer`
- **Fields**: `event`, `key`, `configOwner` (new owner = recipient)
- **Notes**: Donor emits. Capture the new config ownership state. This is the point of no return for the migration.

### 5. PersistCommitDecision
- **Code location**: `migration_util.cpp:282-302` (`persistCommitDecision`)
- **Trigger point**: After `updateMigrationCoordinatorDoc` (line 289) succeeds or `NoMatchingDocument` is caught (line 291)
- **Trace event name**: `PersistCommitDecision`
- **Fields**: `event`, `shard` (donor), `migState` ("commitReleaseCritSec")
- **Notes**: Emit after the function completes (whether doc update succeeded or was swallowed). The swallowed NoMatchingDocument case is a code-level finding (DA-5).

### 6. CommitReleaseCritSec
- **Code location**: `migration_coordinator.cpp:242` (`_waitForReleaseRecipientCriticalSectionFutureIgnoreShardNotFound`)
- **Trigger point**: After the future completes (success or ShardNotFound caught)
- **Trace event name**: `CommitReleaseCritSec`
- **Fields**: `event`, `shard` (donor)
- **Notes**: Donor emits. The actual release is async (launched at line 205), but we emit at the wait point.

### 7. CommitBumpRecipientTxn
- **Code location**: `migration_coordinator.cpp:252-255` (`advanceTransactionOnRecipient`)
- **Trigger point**: After `advanceTransactionOnRecipient` returns (line 255)
- **Trace event name**: `CommitBumpRecipientTxn`
- **Fields**: `event`, `shard` (donor)
- **Notes**: Donor emits. NOT in try-catch for ShardNotFound (Bug Family 3). If this throws, no event is emitted (trace will stop).

### 8. CommitDeleteRecipientRangeDel
- **Code location**: `migration_coordinator.cpp:278-282` (`deleteRangeDeletionTaskOnRecipient`)
- **Trigger point**: After `deleteRangeDeletionTaskOnRecipient` returns
- **Trace event name**: `CommitDeleteRecipientRangeDel`
- **Fields**: `event`, `shard` (donor)
- **Notes**: Donor emits. Remote operation to recipient shard.

### 9. CommitMarkDonorRangeDelReady
- **Code location**: `migration_coordinator.cpp:320-321` (`markAsReadyRangeDeletionTaskLocally`)
- **Trigger point**: After `markAsReadyRangeDeletionTaskLocally` returns
- **Trace event name**: `CommitMarkDonorRangeDelReady`
- **Fields**: `event`, `shard` (donor)
- **Notes**: Donor emits. Also covers `registerTask` at line 309 (combined for simplicity).

### 10. CommitForgetMigration
- **Code location**: `migration_coordinator.cpp:389-401` (`forgetMigration`)
- **Trigger point**: After `store.remove` (line 398) returns
- **Trace event name**: `CommitForgetMigration`
- **Fields**: `event`, `shard` (donor)
- **Notes**: Uses w:1 write concern (line 400). Critical for Bug Family 1 MC-2.

### 11. DecideAbort
- **Code location**: `migration_source_manager.cpp:832+` (`_cleanupOnError`)
- **Trigger point**: When migration decision is set to abort and cleanup begins
- **Trace event name**: `DecideAbort`
- **Fields**: `event`, `key`, `shard` (donor)
- **Notes**: Multiple code paths lead to abort (clone failure, config commit failure, etc.).

### 12. AbortPersistDecision
- **Code location**: `migration_util.cpp:304-322` (`persistAbortDecision`)
- **Trigger point**: After `updateMigrationCoordinatorDoc` (line 309) completes
- **Trace event name**: `AbortPersistDecision`
- **Fields**: `event`, `shard` (donor)

### 13. AbortReleaseCritSec
- **Code location**: `migration_coordinator.cpp:338` (`_waitForReleaseRecipientCriticalSectionFuture`)
- **Trigger point**: After the future completes
- **Trace event name**: `AbortReleaseCritSec`
- **Fields**: `event`, `shard` (donor)

### 14. AbortDeleteDonorRangeDel
- **Code location**: `migration_coordinator.cpp:347-350` (`deleteRangeDeletionTaskLocally`)
- **Trigger point**: After `deleteRangeDeletionTaskLocally` returns
- **Trace event name**: `AbortDeleteDonorRangeDel`
- **Fields**: `event`, `shard` (donor)
- **Notes**: NOT in try-catch (Bug Family 3, MC-9). Failure here prevents subsequent steps.

### 15. AbortBumpRecipientTxn
- **Code location**: `migration_coordinator.cpp:361-365` (`advanceTransactionOnRecipient`)
- **Trigger point**: After the try-catch block completes (success or ShardNotFound caught)
- **Trace event name**: `AbortBumpRecipientTxn`
- **Fields**: `event`, `shard` (donor)
- **Notes**: IS in try-catch for ShardNotFound (unlike commit path).

### 16. AbortMarkRecipientRangeDelReady
- **Code location**: `migration_coordinator.cpp:382-386` (`markAsReadyRangeDeletionTaskOnRecipient`)
- **Trigger point**: After function returns
- **Trace event name**: `AbortMarkRecipientRangeDelReady`
- **Fields**: `event`, `shard` (donor)

### 17. AbortForgetMigration
- **Code location**: `migration_coordinator.cpp:389-401` (same `forgetMigration`)
- **Trigger point**: After `store.remove` returns
- **Trace event name**: `AbortForgetMigration`
- **Fields**: `event`, `shard` (donor)

### 18. Stepdown
- **Code location**: Replication coordinator stepdown notification
- **Trigger point**: When `onStepDown` callback fires
- **Trace event name**: `Stepdown`
- **Fields**: `event`, `shard`
- **Notes**: Can be triggered via `replSetStepDown` command or automatic stepdown.

### 19. StepUp
- **Code location**: `migration_util.cpp:356` (`resumeMigrationCoordinationsOnStepUp`)
- **Trigger point**: At the beginning of `resumeMigrationCoordinationsOnStepUp`
- **Trace event name**: `StepUp`
- **Fields**: `event`, `shard`

### 20. RecoverMigration
- **Code location**: `shard_filtering_metadata_refresh.cpp:495-635` (`_recoverMigrationCoordinations`)
- **Trigger point**: After decision is derived (line 610-633) and before `completeMigration` is called
- **Trace event name**: `RecoverMigration`
- **Fields**: `event`, `shard`, `key`, `migState` (derived decision)
- **Notes**: This is the critical recovery path. Emit the derived decision for validation.

### 21. DeleteRange
- **Code location**: `range_deletion_util.cpp:335-437` (`deleteRangeInBatches`)
- **Trigger point**: After the batch deletion loop completes and the range deletion task document is removed
- **Trace event name**: `DeleteRange`
- **Fields**: `event`, `shard`, `key`
- **Notes**: May complete across multiple batches; emit once when the full range is deleted.

### 22. MajorityReplicateForget
- **Code location**: No explicit code point — models w:1 write becoming majority-replicated
- **Trigger point**: After the w:1 write from `forgetMigration` is confirmed to have replicated to majority (observable via `getLastError` or replication monitoring)
- **Trace event name**: `MajorityReplicateForget`
- **Fields**: `event`, `shard`
- **Notes**: This is a system-level event, not an explicit code call. May need to be inferred from replication oplog position.

## Section 3: Special Considerations

### Instrumentation Approach

MongoDB's migration protocol spans multiple C++ files and threads. The recommended instrumentation approach is:

1. **Centralized trace emitter**: Create a `TlaTraceEmitter` class that writes NDJSON to a file specified by the `MONGO_TLA_TRACE_FILE` environment variable.

2. **Shared harness**: Use the Docker Compose sharding cluster template from `case-studies/mongodb-shared-harness.md`. The cluster provides:
   - 2 shard replica sets (each with 3 members for stepdown testing)
   - 1 config server replica set
   - 1 mongos router

3. **Log-based instrumentation**: Alternative to code patches — parse MongoDB's existing structured logs (logv2) to extract migration events. Key log IDs:
   - `23889`: "Persisting migration coordinator doc" (StartMigration)
   - `23893`: "MigrationCoordinator delivering decision" (completeMigration)
   - `23894`: "Making commit decision durable" (PersistCommitDecision)
   - `23899`: "Making abort decision durable" (AbortPersistDecision)
   - `23903`: "Deleting migration coordinator document" (ForgetMigration)
   - `6376300`: "Retrieving number of orphan documents" (mid-commit)
   - `4798510`: "Starting migration coordinator step-up recovery" (StepUp)

### Threading Model

- **Migration thread**: Single thread per shard (enforced by `ActiveMigrationsRegistry`). All commit/abort sub-steps execute sequentially on this thread.
- **Range deleter**: Separate single-threaded executor (`RangeDeleterService`). Events may interleave with migration events.
- **Recovery**: Runs on the fixed executor pool after step-up. May overlap with range deleter events.

### Bootstrap State

- `TraceInit` assumes all shards start as primary with no active migrations
- Initial `configOwner` assignment must match the actual cluster's chunk distribution
- Verify initial state by querying `config.chunks` before starting the test

### Non-Obvious Details

1. **Critical section persistence**: The recipient's critical section survives stepdown via `MigrationRecipientRecoveryDocument`. The donor's critical section is volatile. This asymmetry is modeled in `Stepdown()`.

2. **w:1 forgetMigration**: The `WriteConcernOptions{1,...}` at `migration_coordinator.cpp:400` means the coordinator doc deletion can be rolled back on stepdown. To observe this in traces, you need:
   - A stepdown immediately after `forgetMigration`
   - The new primary will see the coordinator doc reappear
   - The recovery event on the new primary confirms the rollback

3. **Abort path ordering**: The abort path deletes the donor's range deletion task BEFORE bumping the recipient transaction (lines 347-365). This is the opposite order from commit. If `deleteRangeDeletionTaskLocally` throws, the recipient's task is never marked ready (MC-9).

4. **Recovery decision derivation**: Recovery at `shard_filtering_metadata_refresh.cpp:610-633` checks `keyBelongsToMe(midKey)`. If the key still belongs to the recovering shard, decision is abort; otherwise commit. This relies on the config server being the source of truth.

5. **Dedup considerations**: If a stepdown/recovery cycle causes the commit/abort path to re-execute, events like `PersistCommitDecision` may appear twice in the trace. The trace preprocessor should handle idempotent duplicate events.
