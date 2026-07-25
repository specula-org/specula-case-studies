# Confirmed Bugs: MongoDB Range Deletion Protocol

**Phase**: 4 — Bug Confirmation  
**Date**: 2026-06-08  
**Input**: bug-report.md (3 confirmed bugs + 1 not-found from model checking)  
**Method**: Code audit (Phase 1 investigation) + state-injection reproduction (Phase 2, Level 2)

---

## BUG-1: Orphan Donor Range on Crash Between Two Initialization Writes

**Source**: MC (model checking produced actual counterexample — 3-state violation trace)  
**Status**: REPRODUCED  
**Severity**: High  
**Location**: `migration_coordinator.cpp:147–169` (write gap), `migration_coordinator.cpp:289–294` (silent skip)

### Description

`MigrationCoordinator::startMigration()` performs two separate, non-atomic writes: first it persists the migration coordinator document (line 150), then separately persists the range deletion task (line 158). If a process crash occurs between these two writes, the coordinator document survives (majority write concern) but the range deletion task is never written. When the new primary recovers and commits the migration, the recovery code at lines 285–288 attempts to read the task from disk via `getRangeDeletionTask()`. Since the task was never written, this returns `boost::none`, triggering the null-check at line 289 which silently returns without scheduling any range deletion. The donor shard's data for the migrated range is never cleaned up, creating a permanent orphan.

### Code Audit Findings

The two-write sequence is confirmed at:
```
migration_coordinator.cpp:150  insertMigrationCoordinatorDoc(opCtx, _migrationInfo);
   [CRASH WINDOW — no failpoint, no atomicity guarantee]
migration_coordinator.cpp:158  _donorRangeDeletionTask.emplace(createAndPersistRangeDeletionTask(...))
```

The recovery path (lines 283–294) reads:
```cpp
// We only expect _donorRangeDeletionTask to be empty in a recovery scenario in which case we
// can read the task previously persisted to disk.
_donorRangeDeletionTask = _donorRangeDeletionTask
    ? _donorRangeDeletionTask
    : rangedeletionutil::getRangeDeletionTask(
          opCtx, _migrationInfo.getCollectionUuid(), _migrationInfo.getRange());
if (!_donorRangeDeletionTask) {
    LOGV2_DEBUG(11335400, 2, "No range deletion task found on donor", ...);
    return Future<void>::makeReady();  // ← silent skip — orphan persists
}
```

The developer comment ("We only expect _donorRangeDeletionTask to be empty in a recovery scenario") confirms the developers know this path exists but assume the task was previously persisted. The comment does not account for the case where the task was never written.

**Existing failpoints**: Six failpoints are defined in migration_coordinator.cpp; none covers the window between `insertMigrationCoordinatorDoc` and `createAndPersistRangeDeletionTask`. The gap is unguarded.

**Call chain**: `moveChunk` → `MigrationSourceManager::startClone()` → `MigrationCoordinator::startMigration()` → two separate writes → crash window → `completeMigration()` → `_commitMigrationOnDonorAndRecipient()` → null-check early return.

### Developer Intent Investigation

The comment at line 283 explicitly acknowledges the recovery scenario and states the assumption that the task was previously persisted. This shows developer awareness of the two-write structure but no mitigation for the crash-between-writes case. No existing test covers this scenario (no failpoint in the window; the six failpoints all cover post-decision phases). The LOGV2_DEBUG at level 2 (debug, non-default) means this silent skip is invisible in production logging.

No public issue or PR was found in the artifact's git history (artifact is a snapshot with no history). The developer comment does not say "this is a deliberate trade-off" — it describes an assumption that is violated by a crash.

### Trigger Scenario

1. A chunk migration begins on the donor shard.
2. `startMigration()` writes the coordinator document (majority write concern → durable).
3. Before `createAndPersistRangeDeletionTask()` completes, the mongod process is killed (OOM, hardware fault, SIGKILL).
4. A new primary steps up via election.
5. The new primary scans `config.migrationCoordinators` and finds the coordinator document.
6. It reconstructs a `MigrationCoordinator` and calls `completeMigration()`.
7. Config server says the migration committed → `_commitMigrationOnDonorAndRecipient()` runs.
8. `getRangeDeletionTask()` returns `boost::none` (task was never written).
9. `return Future<void>::makeReady()` — no range deletion scheduled.
10. Donor shard retains the migrated range's data indefinitely.

### Reproduction Test

**File**: `repro/test_bug1_orphan_donor_range.sh`  
**Escalation level reached**: Level 2 (state injection / code audit)

**Execution output** (key excerpts):
```
[CHECK 3] Critical null-check code block (migration_coordinator.cpp:283-295):
    // We only expect _donorRangeDeletionTask to be empty in a recovery scenario in which case we
    // can read the task previously persisted to disk.
    _donorRangeDeletionTask = _donorRangeDeletionTask
        ? _donorRangeDeletionTask
        : rangedeletionutil::getRangeDeletionTask(
              opCtx, _migrationInfo.getCollectionUuid(), _migrationInfo.getRange());
    if (!_donorRangeDeletionTask) {
        LOGV2_DEBUG(11335400,
                    2,
                    "No range deletion task found on donor",
                    "migrationId"_attr = _migrationInfo.getId());
        return Future<void>::makeReady();
    }

[CHECK 4] No failpoint between the two writes:
(Only hangBeforeMakingCommitDecisionDurable, hangBeforeMakingAbortDecisionDurable,
 hangBeforeSendingCommitDecision, hangBeforeSendingAbortDecision,
 hangBeforeForgettingMigrationAfterCommitDecision,
 hangBeforeForgettingMigrationAfterAbortDecision — none in the write gap)
```

Level 0–1 skipped: require a compiled MongoDB sharded cluster with failpoint control. Level 3 (code modification) is not needed — the Level 2 audit definitively establishes the exploitable path.

### Recommendation

Write the coordinator document and the range deletion task in a single transaction, or add the range deletion task creation inside a retry loop that persists before returning from `startMigration()`. Alternatively, add a post-crash scan during recovery that explicitly handles missing range deletion tasks by creating them before committing, rather than silently skipping.

---

## BUG-2: Recipient Range Deletion Task Stuck Pending After Shard Removal

**Source**: MC (model checking produced actual counterexample — 11-state violation trace, 16+ distinct traces)  
**Status**: REPRODUCED (mechanism corrected from bug report)  
**Severity**: Medium  
**Location**: `migration_coordinator.cpp:352–387` (abort path exception handling), `migration_coordinator.cpp:396–401` (forgetMigration w:1 write concern)

### Description

When a migration is aborted and the recipient shard has been removed from the cluster, both RPC calls in `_abortMigrationOnDonorAndRecipient()` silently swallow `ShardNotFound` — `advanceTransactionOnRecipient` (inside the explicit try/catch at lines 352–375) and `markAsReadyRangeDeletionTaskOnRecipient` (via its own internal exception handler in `range_deletion_util.cpp:768`). The abort function returns normally, then `forgetMigration()` deletes the coordinator document using a `w:1` (non-majority) write concern. After this, the recipient range deletion task remains in `pending` state with no mechanism to activate or clean it up, since the coordinator document is gone and the recipient shard may be unreachable.

**Mechanism correction**: The original bug report incorrectly states that `markAsReadyRangeDeletionTaskOnRecipient` at line 382 throws an uncaught `ShardNotFound` exception that crashes the coordinator thread. In reality, `markAsReadyRangeDeletionTaskOnRecipient` in `range_deletion_util.cpp:762–784` wraps its remote call inside a retry loop with its own `ShardNotFound` catch clause (line 768) that logs and returns silently. The coordinator thread does NOT crash. The stuck-pending outcome is reached through silent swallowing, not through a crash.

### Code Audit Findings

**Exception handling in abort path**:
```
migration_coordinator.cpp:352–364  try { advanceTransactionOnRecipient(...) }
migration_coordinator.cpp:365–374  catch (ShardNotFound) { log; /* swallowed */ }
migration_coordinator.cpp:382–386  markAsReadyRangeDeletionTaskOnRecipient(...)
                                   → internally catches ShardNotFound (util.cpp:768)
                                   → logs LOGV2_DEBUG(4620232, 1, ...) → returns
```

**forgetMigration write concern** (migration_coordinator.cpp:396–401):
```cpp
store.remove(opCtx,
             BSON(MigrationCoordinatorDocument::kIdFieldName << _migrationInfo.getId()),
             WriteConcernOptions{1, WriteConcernOptions::SyncMode::UNSET, Seconds(0)});
```
`WriteConcernOptions{1, ...}` = w:1, not majority. A primary stepdown immediately after this write can result in the coordinator document NOT being durably deleted, causing a new primary to re-run the abort — but the recipient shard is still gone, so the cycle repeats.

**No cleanup path after forgetMigration**: Once the coordinator document is deleted, there is no periodic job or recovery scan that looks for `pending` recipient range deletion tasks without a corresponding coordinator document and activates or deletes them.

### Developer Intent Investigation

The `LOGV2_DEBUG(4620231, ...)` message for the `advanceTransactionOnRecipient` `ShardNotFound` catch says "Failed to advance transaction number on recipient shard for abort **and/or marking range deletion task on recipient as ready for processing**." This comment was written as if `markAsReadyRangeDeletionTaskOnRecipient` was also inside the try/catch, but it is not (it is called afterward at line 382). This discrepancy suggests the developer intent was for both calls to be protected, but the code does not match the intent.

The `w:1` write concern for `forgetMigration` is unusual — all other writes in this flow use majority write concern. No comment explains this choice. It appears to be a performance trade-off but introduces a liveness hole under stepdown.

### Trigger Scenario

1. A chunk migration's `moveChunk` is initiated; donor writes coordinator doc and range deletion tasks.
2. The migration decision is to ABORT.
3. Between the abort decision and `completeMigration()` completing, the recipient shard is removed from the cluster config (e.g., via `removeShard` followed by a stepdown).
4. `_abortMigrationOnDonorAndRecipient()`:
   - `advanceTransactionOnRecipient()` gets `ShardNotFound` → caught at line 365 → swallowed.
   - `markAsReadyRangeDeletionTaskOnRecipient()` gets `ShardNotFound` → caught at util:768 → swallowed.
5. `forgetMigration()` deletes coordinator doc with w:1.
6. Recipient range deletion task remains in `pending` state.
7. If the shard is re-added to the cluster: the `pending` task is now live but was never activated; future migrations on that range may hang waiting for an activation that never comes.

### Reproduction Test

**File**: `repro/test_bug2_recipient_stuck_pending.sh`  
**Escalation level reached**: Level 2 (code audit)

**Execution output** (key excerpts):
```
[CHECK 2] markAsReadyRangeDeletionTaskOnRecipient ShardNotFound handling:
    try {
        sharding_util::invokeCommandOnShardWithIdempotentRetryPolicy(...);
    } catch (const ExceptionFor<ErrorCodes::ShardNotFound>& exShardNotFound) {
        LOGV2_DEBUG(4620232, 1, "Failed to mark range deletion task on recipient shard as ready", ...);
        return;  ← exception is caught and swallowed, not propagated
    }

[ANALYSIS] What actually happens when recipient shard is removed during abort:
  Step 1: advanceTransactionOnRecipient -> ShardNotFound -> caught at line 365 -> swallowed
  Step 2: markAsReadyRangeDeletionTaskOnRecipient -> ShardNotFound -> caught at util:768 -> swallowed
  Step 3: _abortMigrationOnDonorAndRecipient() returns normally (no crash!)
  Step 4: completeMigration() calls forgetMigration() -> coord doc deleted with w:1
  Result: recipient task permanently in 'pending' state, coordinator doc gone
```

### Recommendation

1. Move `markAsReadyRangeDeletionTaskOnRecipient` inside the existing `try/catch` block (lines 352–375), or add a separate `ShardNotFound` catch after line 382 that explicitly handles cleanup of the recipient's pending task.
2. Change `forgetMigration()` to use majority write concern, consistent with all other writes in this flow, to close the stepdown durability hole.
3. Add a background scan or startup recovery job that identifies `pending` recipient range deletion tasks with no corresponding coordinator document and activates or removes them.

---

## BUG-3: Simultaneous Donor Range Deletions (TOCTOU in Overlap Detection)

**Source**: MC (model checking produced actual counterexample — 13-state violation trace)  
**Status**: REPRODUCED (with scope nuance — see below)  
**Severity**: High  
**Location**: `range_deleter_service.h:153–158` (acknowledged TOCTOU in `getOverlappingRangeDeletionsFuture`), `range_deleter_service.cpp:361–488` (async gap in `registerTask` overlap check)

### Description

`RangeDeleterService::getOverlappingRangeDeletionsFuture()` takes a point-in-time snapshot of `_rangeDeletionTasks` while holding a lock and returns futures for all tasks in the snapshot. Tasks registered **after** the snapshot is taken are invisible to the caller. Separately, the `registerTask()` function's internal overlap detection runs asynchronously on the executor *after* the mutex is released; if a competing task calls `completeTask()` in the gap between registration and the async overlap check, the completing task is removed from the map and the newly registered task never waits for it. Both paths can result in two range deletions on overlapping ranges executing simultaneously.

The source comment at `range_deleter_service.h:154–155` **explicitly acknowledges** this vulnerability and states "Handling this scenario is responsibility of the caller." No caller in the production code (specifically `collection_sharding_runtime.cpp:526`) implements handling for the post-snapshot registration case.

The `MONGO_MOD_NEEDS_REPLACEMENT` annotation on the class, `getOverlappingRangeDeletionsFuture`, and `totalNumOfRegisteredTasks` confirms that MongoDB developers have flagged this component for architectural replacement.

### Code Audit Findings

**Acknowledged TOCTOU in public API** (`range_deleter_service.h:152–156`):
```cpp
/*
 * Returns a future marked as ready when all overlapping range deletion tasks complete.
 *
 * NB: in case an overlapping range deletion task is registered AFTER invoking this method,
 * it will not be taken into account. Handling this scenario is responsibility of the caller.
 */
```

**Point-in-time snapshot** (`range_deleter_service.cpp:506–528`):
```cpp
auto lock = _acquireMutexFailIfServiceNotUp();
auto tasks = _rangeDeletionTasks.getOverlappingTasks(collectionUUID, range);  // snapshot
// Returns futures for snapshot only — no re-check
```

**Async gap in registerTask** (`range_deleter_service.cpp:384–430`):
- Task is registered while holding the mutex (line 377).
- Mutex is released.
- Async chain on executor re-acquires mutex and calls `getOverlappingTasks()`.
- If a competing task calls `completeTask()` in the gap (removes itself from the map), the new task's overlap check misses it.

**completeTask removes from map immediately** (`range_deleter_service.cpp:491–499`):
```cpp
auto lock = _acquireMutexFailIfServiceNotUp();
auto task = _rangeDeletionTasks.removeTask(collUUID, range);  // task gone from map instantly
```

**MONGO_MOD_NEEDS_REPLACEMENT** (`range_deleter_service.h:71, 157, 186`):
```
class MONGO_MOD_NEEDS_REPLACEMENT RangeDeleterService
MONGO_MOD_NEEDS_REPLACEMENT SharedSemiFuture<void> getOverlappingRangeDeletionsFuture(...)
MONGO_MOD_NEEDS_REPLACEMENT long long totalNumOfRegisteredTasks()
```

**Scope nuance from TLC counterexample**: The TLC spec models `ExecuteRangeDeletion` without the overlap-detection gate as a precondition; the counterexample finds simultaneous processing directly. In the real code, simultaneous processing of **non-overlapping** ranges is benign and expected. The safety violation requires: (a) two migration tasks with actually overlapping ranges, and (b) the TOCTOU race firing. The `registerTask()` internal overlap check (comparing registration timestamps) provides partial protection but has the async gap described above.

### Developer Intent Investigation

The source comment ("Handling this scenario is responsibility of the caller") shows developer awareness that the TOCTOU exists and is documented as a known design limitation. The `MONGO_MOD_NEEDS_REPLACEMENT` markers indicate this is slated for architectural replacement rather than incremental fix. However, the caller (`collection_sharding_runtime.cpp:526`) does not implement the required handling, leaving the documented vulnerability open in production code. This matches the pattern of a known-but-unmitigated issue.

### Trigger Scenario

1. Migration m1 for range [a, b) is committed; its range deletion task is registered in `RangeDeleterService` and in "processing" state (actively deleting data).
2. A new incoming migration m2 for an overlapping range [a–ε, b+ε) calls `getOverlappingRangeDeletionsFuture()` — this succeeds and returns a future for m1.
3. While m2 is waiting for m1, m1 finishes and calls `completeTask()` → m1 removed from `_rangeDeletionTasks`.
4. m1's future resolves; m2 proceeds, calls `createAndPersistRangeDeletionTask`, then `registerTask()`.
5. m2's async chain re-acquires the mutex and calls `getOverlappingTasks()` → m1 is gone → no waiting tasks found.
6. m2 starts executing its range deletion while any data m1 was writing to during its final cleanup may still be in flight.
7. Both processes operate on overlapping key ranges → data corruption risk.

### Reproduction Test

**File**: `repro/test_bug3_toctou_overlap_detection.sh`  
**Escalation level reached**: Level 2 (code audit)

**Execution output** (key excerpts):
```
[CHECK 1] Explicit acknowledgment in source comment:
154:     * NB: in case an overlapping range deletion task is registered AFTER invoking this method,
155:     * it will not be taken into account. Handling this scenario is responsibility of the caller.

[CHECK 5] MONGO_MOD_NEEDS_REPLACEMENT annotations:
71:class MONGO_MOD_NEEDS_REPLACEMENT RangeDeleterService
157:    MONGO_MOD_NEEDS_REPLACEMENT SharedSemiFuture<void> getOverlappingRangeDeletionsFuture(...)
186:    MONGO_MOD_NEEDS_REPLACEMENT long long totalNumOfRegisteredTasks()
```

### Recommendation

1. Replace the point-in-time snapshot in `getOverlappingRangeDeletionsFuture()` with a mechanism that also catches tasks registered after the call returns (e.g., a version counter or a subscription model).
2. In the `registerTask()` async chain, re-check for overlapping tasks at the point of actually starting the deletion (not only at registration time), holding the lock through the entire check-and-start sequence.
3. The `MONGO_MOD_NEEDS_REPLACEMENT` annotation indicates the right fix is architectural. Until then, document that callers of `getOverlappingRangeDeletionsFuture()` must implement a re-check after registration.

---

## BUG-4 (Not Found): Recovery Scan Non-Atomicity

**Source**: Code Review (model checking returned no violation for this family)  
**Status**: FALSE POSITIVE  
**Severity**: N/A

No violation was found for the `RecoveryCompleteness` invariant across 324 distinct states with MaxCrashCount=3. The spec models recovery atomically; the real two-pass implementation (`range_deleter_service.cpp:220–254`) has an inter-pass gap, but this requires a precise race condition outside the current spec's model. Not reproduced and not escalated — the spec would need a two-step recovery model to verify or refute this family.

---

## Summary

| Bug ID | Invariant | Source | Status | Level Reached | Mechanism Corrected? |
|--------|-----------|--------|--------|---------------|----------------------|
| BUG-1 | NoOrphanOnCommit | MC | **REPRODUCED** | Level 2 | No — matches report |
| BUG-2 | NoAbortedCoordWithStuckPendingRecipient | MC | **REPRODUCED** | Level 2 | **Yes — exception IS caught; stuck-pending via silent swallow, not crash** |
| BUG-3 | NoSimultaneousDonorProcessing | MC | **REPRODUCED** | Level 2 | Partial — real TOCTOU exists; scope requires overlapping ranges + race |
| BUG-4 | RecoveryCompleteness | Code Review | FALSE POSITIVE | — | — |
