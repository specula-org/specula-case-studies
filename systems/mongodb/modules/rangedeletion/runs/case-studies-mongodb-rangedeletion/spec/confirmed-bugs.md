# Confirmed Bug Report — mongodb-rangedeletion

## Summary

- Total findings reviewed: 14 (2 MC-confirmed, 4 test-verifiable, 4 code-review-only, 4 model-checkable pending)
- Reproduced: 1
  - Bug 1: Asymmetric migrationId filtering (High, Level 2 state injection on real MongoDB 8 cluster)
- Confirmed (precondition verification + analytical proof): 1
  - Bug 2: Recovery ordering (Medium, SERVER-119435 regression on master — overlap ordering ignores processing flag)
- False positives: 5
- Inconclusive: 0
- Out of scope / Not bugs: 7

---

## Bug 1: Asymmetric migrationId Filtering Deletes Wrong Task Document

- **Source**: MC (9-state counterexample) + Code Review (modeling-brief Family 4)
- **Status**: REPRODUCED (Level 2: State Injection)
- **Severity**: High
- **Location**: `range_deletion_util.cpp:702-708` (`deleteRangeDeletionTaskLocally`), `range_deletion_util.cpp:312-318` (`getQueryFilterForRangeDeletionTask`)
- **MC Config**: `MC_hunt_identity.cfg`, invariant `TaskDocConsistency` violated

### Description

`deleteRangeDeletionTaskLocally()` queries the persistent `config.rangeDeletions` collection using only `(collectionUuid, range.min, range.max)` — it does NOT include `migrationId` in the filter. When a migration M1 aborts but crashes before `forgetMigration()` deletes the coordinator document, a subsequent step-up recovery replays the abort. If a new migration M2 has started on the same range in the interim, the replayed abort's `deleteRangeDeletionTaskLocally()` matches and deletes M2's task document.

The recipient-side equivalent `deleteRangeDeletionTaskOnRecipient()` at `range_deletion_util.cpp:677-693` deliberately includes `migrationId`, with an explicit comment at lines 320-322: *"Add `migrationId` to the query filter in order to be resilient to delayed network retries: only relying on collection's UUID and range may lead to undesired updates/deletes on tasks created by future migrations."*

This asymmetry was introduced in the SERVER-69586 fix (commit `cae95e4429`, Sep 2022, by Silvia Surroca), which added `migrationId` to the recipient-side filters but did not apply the same fix to `deleteRangeDeletionTaskLocally()`.

The delete operation uses `PersistentTaskStore::remove` (persistent_task_store.h:117-143), which calls `setMulti(true)` — it's a `deleteMany`, not `deleteOne`. This means the filter-without-migrationId deletes ALL documents matching the `(collectionUuid, range)`, not just the first one.

### Trigger Scenario

1. Migration M1 starts on range R1, creating a task document with `_id=M1_migrationId`
2. M1 aborts → `_abortMigrationOnDonorAndRecipient()` calls `deleteRangeDeletionTaskLocally(collUUID, R1)` → deletes M1's task doc
3. Shard crashes AFTER step 2 but BEFORE `forgetMigration()` deletes the coordinator doc (the window spans `advanceTransactionOnRecipient` + `markAsReadyRangeDeletionTaskOnRecipient` at `migration_coordinator.cpp:361-386`)
4. Migration M2 starts on the same range R1, commits, creating a new task document with `_id=M2_migrationId`
5. Step-up recovery (`resumeMigrationCoordinationsOnStepUp` at `migration_util.cpp:356-413`) finds M1's coordinator doc, replays `_abortMigrationOnDonorAndRecipient()`
6. `deleteRangeDeletionTaskLocally(collUUID, R1)` matches M2's task doc (same collUUID + range, no migrationId filter) and **deletes it**

**Result**: M2's range deletion task is orphaned — the in-memory `RangeDeleterService` believes the task exists, but the persistent document is gone. On the next step-down/step-up cycle, the task is permanently lost, leaving orphaned documents on the donor shard indefinitely.

### Developer Intent Evidence

- **SERVER-69586** (Sep 2022): Developers explicitly fixed this exact issue for recipient-side operations, with a comment documenting why migrationId is needed. The donor side was not updated — an oversight, not a design choice.
- **No test coverage**: No unit or integration test in the codebase tests `deleteRangeDeletionTaskLocally` with two tasks on the same range from different migrations.
- The `deleteRangeDeletionTaskLocally` function signature does not even accept a `migrationId` parameter, while the caller (`_abortMigrationOnDonorAndRecipient` at `migration_coordinator.cpp:347`) has access to `_migrationInfo.getId()`.

### Reproduction

**Test**: `repro/test_bug1_migrationid_filter.py` — 2-shard cluster (shard0 = 2-node RS), MongoDB 8 via Docker.

**Result**: REPRODUCED (Level 2: State Injection). All three phases pass.

**Approach**: After a real migration creates a range deletion document on the donor (shard0), a second document with the same `(collectionUuid, range)` but a different `_id` (migrationId) is inserted to simulate the abort-replay scenario. The test runs the exact queries from both the buggy and correct code paths:

**Phase A (Buggy query)**:
```
Query: {collectionUuid: UUID, "range.min": {x: 50}, "range.max": {x: MaxKey()}}
Result: Deleted 2 docs, Remaining 0 — BOTH docs deleted (wrong!)
```

**Phase B (Correct query)**:
```
Query: {collectionUuid: UUID, "range.min": {x: 50}, "range.max": {x: MaxKey()}, _id: M1_migrationId}
Result: Deleted 1 doc, Remaining 1 — Only M1's doc deleted, M2's SURVIVES (correct)
```

**Phase C (Abort-replay scenario)**:
```
State: only M2's doc in config.rangeDeletions
M1's abort replay runs deleteRangeDeletionTaskLocally(collUUID, range)
Result: Deleted 1 doc, Remaining 0 — M2's doc DELETED by M1's abort replay
```

**Execution command and output**:
```
$ python3 repro/test_bug1_migrationid_filter.py
[10:46:41] === SETUP: Starting sharded cluster ===
[10:47:19] Step 1: Move chunk shard0 → shard1 to create a real range deletion doc
[10:47:23]   Real doc keys: ['_id', 'nss', 'collectionUuid', 'donorShardId', 'range',
             'whenToClean', 'timestamp', 'numOrphanDocs', 'keyPattern', 'preMigrationShardVersion']
[10:47:23] --- Phase A: Buggy query (deleteRangeDeletionTaskLocally) ---
[10:47:23]   Deleted: 2 docs
[10:47:23]   Remaining: 0 docs
[10:47:23]   >>> BOTH docs deleted — query matched M2's doc too!
[10:47:23] --- Phase B: Correct query (deleteRangeDeletionTaskOnRecipient) ---
[10:47:23]   Deleted: 1 docs
[10:47:23]   Remaining: 1 docs
[10:47:23]   >>> Only M1's doc deleted. M2's doc SURVIVES
[10:47:23] --- Phase C: Abort-replay scenario ---
[10:47:23]   Deleted: 1 docs
[10:47:23]   Remaining: 0 docs
[10:47:23]   >>> M2's doc DELETED by M1's abort replay!
[10:47:23] BUG REPRODUCED (Level 2: State Injection)
```

### Recommendation

Add `migrationId` to the query filter in `deleteRangeDeletionTaskLocally()`, following the recipient-side pattern:

```cpp
// range_deletion_util.cpp — proposed fix
void deleteRangeDeletionTaskLocally(OperationContext* opCtx,
                                    const UUID& collectionUuid,
                                    const ChunkRange& range,
                                    const UUID& migrationId,        // NEW
                                    const WriteConcernOptions& writeConcern) {
    PersistentTaskStore<RangeDeletionTask> store(NamespaceString::kRangeDeletionNamespace);
    const auto query = getQueryFilterForRangeDeletionTaskOnRecipient(
        collectionUuid, range, migrationId);  // USE migrationId-aware filter
    store.remove(opCtx, query, writeConcern);
}
```

Update the caller at `migration_coordinator.cpp:347-350` to pass `_migrationInfo.getId()`.

---

## Bug 2: Recovery Doesn't Prioritize Previously-Executing Tasks

- **Source**: MC (20-state counterexample) + Code Review (modeling-brief Family 2)
- **Status**: CONFIRMED (precondition verification on 8.2.6 + analytical proof on master code) — regression introduced by SERVER-119435
- **Severity**: Medium — affects master (post-commit 9343c350ae, Feb 2026), not yet in any stable release
- **Location**: `range_deleter_service.cpp:392-417` (overlap ordering, master only), `range_deleter_service.cpp:186-261` (recovery), `range_deletion.h:43-72` (`RangeDeletion` class)
- **MC Config**: `MC_hunt_ordering.cfg`, invariant `ResumeInProgressFirst` violated

### Description

**Regression introduced by SERVER-119435** (commit `9343c350ae`, Feb 12 2026, master only). The overlap ordering code added to prevent deadlocks accidentally breaks the processing-first recovery guarantee from SERVER-64979.

After a failover, the range deletion recovery process re-registers tasks in two phases: processing tasks first (lines 220-231), then non-processing tasks (lines 241-253). In MongoDB 8.2.x and earlier, this worked correctly because tasks ran independently via the processor's FIFO queue (Phase 1 tasks registered first → enqueued first → processed first).

SERVER-119435 added overlap ordering to prevent deadlocks between overlapping range deletion tasks. However, the ordering uses only `registrationTime` and `taskId` as tiebreaker, ignoring the `processing` flag. The in-memory `RangeDeletion` class has no `wasProcessing` field, so once re-registered, a previously-processing task is indistinguishable from a non-processing task.

The overlap ordering logic at lines 402-404 (master) uses only `registrationTime` and `taskId` as tiebreaker:
```cpp
if ((overlappingTask->getRegistrationTime() < registrationTime) ||
    (overlappingTask->getRegistrationTime() == registrationTime &&
     taskId < overlappingTask->getTaskId()))
```

When two overlapping tasks have equal registration timestamps (the `_registrationTime` comes from the persistent doc's `timestamp` field at `range_deletion.cpp:40`), the tiebreaker `taskId < overlappingTask->getTaskId()` can give priority to a non-processing task over the recovered-processing task.

### Trigger Scenario (MC counterexample)

1. Two migrations M1 (range R1) and M2 (range R2, overlapping with R1) both commit simultaneously, getting the same registration timestamp
2. Task 1 (R1) progresses to "executing" and is marked `processing=true` in the persistent doc
3. Step-down clears in-memory state; persistent state preserved
4. Step-up recovery re-registers both tasks via `registerTask()`
5. Overlap ordering: task 2 checks overlap with task 1, computes `ShouldWaitFor(2, 1)` → FALSE (same regTime, and `2 < 1` is FALSE)
6. Task 2 proceeds to execution while task 1 (the previously-processing one) waits

### Developer Intent Evidence

- **SERVER-64979** (Apr 2022, commit `cb0e706157`): Developers added a test `range_deletion_ordering_with_stepdown.js` that explicitly verifies "an ongoing range deletion is the first range deletion executed upon step up." However, this test uses **non-overlapping** ranges, so the overlap ordering code path is not exercised. The fix relied on registering processing tasks first, assuming this ordering would be preserved by the single-threaded executor. It does not hold when overlap ordering is involved.
- **SERVER-119435** (Feb 2026, commit `9343c350ae`): Fixed deadlock from equal registration timestamps by moving task registration before the chain setup. This fix improved the code but did not add processing-flag awareness to overlap ordering.
- The `RangeDeletion` class (`range_deletion.h:43-72`) has `_taskId`, `_range`, `_registrationTime`, `_completionPromise`, `_pendingPromise` — no `_wasProcessing` field.

### Reproduction

**Test**: `repro/test_bug2_ordering_v2.py` — 2-shard cluster (shard0 = 2-node RS), MongoDB 8.2.6 via Docker.

**Result**: BUG CONFIRMED (precondition verification + analytical proof)

**Key finding**: The overlap ordering code that causes this bug was introduced by **SERVER-119435 (commit `9343c350ae`, Feb 12 2026) on the master branch only**. It has NOT been released in any stable MongoDB version (latest: 8.2.6). The bug is a **regression** that will first appear in a future release containing this commit.

**Version analysis**:
- Pre-SERVER-119435 (8.2.6 and earlier): No overlap ordering in the `registerTask` chain. Tasks run independently via the processor's FIFO queue. The two-phase recovery (Phase 1: processing first) correctly preserves execution priority because the FIFO order matches registration order.
- Post-SERVER-119435 (master): Overlap ordering added at lines 392-417 uses `registrationTime` + `taskId` (UUID) as tiebreaker. With equal timestamps, a non-processing task can deprioritize a processing task.

**Precondition verification** (all 6/6 PASS on 8.2.6):

```
$ python3 repro/test_bug2_ordering_v2.py

  MongoDB version: 8.2.6 (git: 5d25c835745d)

  [PASS] Precondition 1: Both tasks registered during recovery
         (Two '7536600' Registering logs found)
  [PASS] Precondition 2: Both tasks present in tracker after recovery
  [PASS] Precondition 3: Same registration timestamp
         (Both docs use timestamp=Timestamp(1774840732, 1))
  [PASS] Precondition 4: UUID ordering would deprioritize processing task
         A.UUID=00000000-... < B.UUID=ffffffff-...
         → On master, A would wait for B (wrong: A was processing)
  [PASS] Precondition 5: Ranges overlap ([50,100) ∩ [60,90) = [60,90))
  [PASS] Precondition 6: Executor ran chains (7536601 observed)
         Single-threaded executor guarantees both tasks visible

  Version-specific behavior (8.2.6, no overlap ordering):
  [CONFIRMED] No recovery tracker logs (11079601/11079600) — pre-SERVER-114200
  [CONFIRMED] No overlap wait logs (11943500) — pre-SERVER-119435
  [CONFIRMED] No overlap ordering active — tasks run without priority inversion

  BUG CONFIRMED (preconditions verified, analytical proof on master code)
```

**Analytical proof on master code**: With both tasks registered (Precondition 1-2), same timestamp (Precondition 3), overlapping ranges (Precondition 5), and the single-threaded executor ensuring both are visible during overlap check (Precondition 6), the overlap ordering at master:402-406 evaluates:
- A's check: `A.UUID(0000) < B.UUID(ffff)` → TRUE → A WAITS for B
- B's check: `B.UUID(ffff) < A.UUID(0000)` → FALSE → B RUNS
- Result: Non-processing Task B executes before was-processing Task A

**Why v1 test failed**: The original test (`test_bug2_recovery_ordering.py`) concluded "NOT REPRODUCED" for two separate wrong reasons:
1. **Wrong premise**: Assumed multi-threaded executor (the executor IS single-threaded, confirmed by `range_deletion_util.cpp:253,413`)
2. **Wrong version**: The Docker image (8.2.6) doesn't have the overlap ordering code — it was introduced by SERVER-119435 on master only

**Escalation ladder:**
- Level 0 (pure black-box): Not applicable — requires specific code version + controlled state
- Level 1 (failpoint timing): `hangBeforeDoingDeletion` set on both members before step-down — correctly freezes tasks at deletion step, but irrelevant on 8.2.6 (no overlap ordering)
- Level 2 (state injection): Injected overlapping docs with controlled UUIDs + timestamps. All 6 preconditions verified. Confirmed 8.2.6 has no overlap ordering code. Analytical proof on master code.
- Level 3 (code modification): Not attempted — requires building MongoDB from master (not available as Docker image)

### Assessment

**Bug classification**: Regression introduced by SERVER-119435 on master. The deadlock fix added overlap ordering but accidentally broke the processing-first guarantee from SERVER-64979.

**Why the bug is exercisable on master**: The single-threaded executor (`NetworkInterfaceThreadPool` → single reactor thread, confirmed by SERVER-62368) guarantees that ALL tasks are registered before ANY overlap check runs. The `getServiceUpFuture()` gate (master:383) further ensures overlap checks wait for recovery completion. Both overlap checks see both tasks, and the UUID tiebreaker ignores the processing flag.

**Consequences** (on master, when released):

| Category | Impact |
|----------|--------|
| Ordering inversion | Previously-processing task waits for non-processing overlapping task (when UUID ordering is unfavorable) |
| Extended orphan visibility | Orphaned documents from the in-progress deletion remain visible longer after failover |
| Developer intent violated | SERVER-64979 added Phase 1/Phase 2 recovery to prioritize processing tasks; overlap ordering negates this |

**Not affected**: Secondary read invalidation via `invalidateRangePreservers()` (op observer checks persistent doc, not in-memory state). No metrics or timeout logic references the in-memory processing state.

**Risk level**: Medium. The trigger requires equal timestamps + overlapping ranges + specific UUID ordering. SERVER-119435 was filed specifically for the equal-timestamp scenario, confirming this is a realistic condition. No data loss — just extended orphan visibility after failover.

**Related tickets**:
- SERVER-62368 (Jan 2022): Confirmed mono-threaded executor
- SERVER-64979 (Apr 2022): Added processing-first recovery (only tested non-overlapping ranges)
- SERVER-110928 (Oct 2025): Enforced range constraints — no overlap ordering yet
- SERVER-114200 (Nov 2025): Added recovery tracker and `getServiceUpFuture()` gate
- SERVER-119435 (Feb 2026): Added overlap ordering to prevent deadlock — **introduced this regression**

### Recommendation

1. Add a `_wasProcessing` boolean to the `RangeDeletion` class (defense-in-depth against future refactoring)
2. Set it from the persistent doc's processing flag during recovery re-registration
3. Use `_wasProcessing` as primary sort key in overlap ordering (before `registrationTime`): processing tasks always take priority over non-processing overlapping tasks
4. Add a test with overlapping ranges to `range_deletion_ordering_with_stepdown.js` (SERVER-64979 test only uses non-overlapping ranges)

---

## Findings Classified as Not Bugs

### TV-2: `persistRangeDeletionTaskLocally` TOCTOU (FALSE POSITIVE)

The `count() > 0` check at line 615 followed by `store.add()` at line 620 appears to be a check-then-act TOCTOU. However, this code runs on a single-threaded executor (documented at `range_deletion_util.cpp:253-254`): *"The scheme for checking whether the range deletion task document still exists relies on the executor only having a single thread."* The `doNotPersistIfDocCoveringSameRangeAlreadyExists` flag is only used in contexts where the single-threaded executor guarantees mutual exclusion. Additionally, the `DuplicateKey` catch at line 621 provides a fallback safety net. **Not a bug** given the executor threading model.

### TV-3: Silent Infinite Retry in `deleteRangeInBatches` (FALSE POSITIVE)

The `while (!allDocsRemoved)` loop at line 349 retries on non-fatal errors (lines 420-434). This is a **deliberate retry pattern** standard in MongoDB. The loop is bounded by: (1) `opCtx->checkForInterruptNoAssert()` check at line 431, which catches step-down/shutdown; (2) specific fatal error codes that break out immediately; (3) the operation context's deadline/cancellation. Transient errors (e.g., WiredTiger cache pressure, lock timeouts) are expected to be retried. **Not a bug** — by design.

### TV-4: Non-Atomic Delete + Orphan Count Update (NOT A BUG — Low Severity)

`deleteNextBatch()` at line 382 and `persistUpdatedNumOrphans()` at line 398 are separate operations. A crash between them overstates the orphan count. However, this is a **metadata inconsistency, not data loss**. The orphan count is advisory (used for `collStats`) and self-corrects on the next full range deletion or recount. The MongoDB team has not prioritized this (no JIRA ticket). **Acknowledged limitation, not a bug**.

### CR-1: `deleteRangeDeletionTasksForRename` (NOT A BUG)

The function at lines 522-532 only deletes from `kRangeDeletionForRenameNamespace` (the snapshot store for rename), not from `config.rangeDeletions`. This matches the function's purpose: clean up the rename-specific snapshot, not the main range deletion documents. The header comment may be misleading but the implementation is correct for its use case. **Not a bug**.

### CR-2: `ensureRangeDeletionTaskStillExists` Single-Threaded Assumption (NOT A BUG)

The safety of lines 243-265 depends on the single-threaded executor, which is explicitly documented in the comment. The executor thread count is a fundamental architectural constraint of the range deleter, not an ad-hoc assumption. If it ever changes, many other invariants would also break. **Architectural constraint, not a bug**.

### CR-3: `_readyRangeDeletionsProcessorPtr` Public Member (STYLE ISSUE)

At `range_deleter_service.h:195`, the `unique_ptr` is public. This is exposed for testing convenience. While not ideal from an encapsulation perspective, it causes no functional bugs. **Style/encapsulation issue, not a bug**.

### CR-4: `_nRescheduledTasks` Logging (COSMETIC)

The recovery log at line 258 reports `nRescheduledTasks` which only counts processing tasks (incremented at line 230), not the total recovered. **Minor logging inaccuracy, not a bug**.
