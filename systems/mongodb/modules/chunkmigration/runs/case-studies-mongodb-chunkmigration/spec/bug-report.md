# Bug Report — MongoDB Chunk Migration

## Summary

- Bug families tested: 4 (Family 1, 2, 3, 5)
- Bugs found: 4
- Configs run: MC_hunt_family1.cfg, MC_hunt_family1_commit.cfg, MC_hunt_family2.cfg, MC_hunt_family3.cfg, MC_hunt_family5.cfg
- Convergence: 1 round (7,105 states, depth 65)

---

## Bug 1: markAsReadyRangeDeletionTaskLocally Marks Wrong Migration's Task

- **Bug Family**: Family 1 — Missing migrationId in local range deletion operations
- **Severity**: Critical
- **Invariant violated**: NoPrematureRangeDeletion
- **Config**: MC_hunt_family1_commit.cfg
- **Counterexample**: 24 states (output/MC_hunt_family1_commit.out)

### Trace Summary

1. **States 1-12**: Migration M1 commits successfully. Commit cleanup runs through all sub-steps. `forgetMigration` removes the coordinator doc with w:1 write concern. `CleanupComplete` marks M1 as done.
2. **State 14**: Range deleter processes M1's ready task (donorTasks becomes empty).
3. **State 15**: Migration M2 starts on the same range. Creates a new coordinator doc and range deletion task for M2 (`{id: m2, pending: true}`).
4. **State 16**: **Stepdown.** The w:1 `forgetMigration` write for M1 is rolled back. `coordDocs[m1]` is restored to `"committed"`. M2's coordinator doc (`coordDocs[m2] = "none"`) persists (majority-written).
5. **State 17**: **RecoverMigration(m1)** — new primary finds M1's coordinator doc with "committed" decision. Restarts M1's commit cleanup from the beginning.
6. **States 18-22**: M1's commit cleanup replays: persistCommitDecision, advanceTxn, retrieveOrphans, persistOrphans, deleteRecipientTask.
7. **State 23**: **DoCommitGetDonorTask(m1)** — `getRangeDeletionTask` (range_deletion_util.cpp:841) uses `getQueryFilterForRangeDeletionTask(collUuid, range)` with **no migrationId**. Finds M2's task.
8. **State 24**: **DoCommitMarkReady(m1)** — `markAsReadyRangeDeletionTaskLocally` (range_deletion_util.cpp:721-725) marks M2's task as ready (`pending: false`). **M2's data becomes eligible for deletion while M2 is still in progress.**

### Root Cause

`markAsReadyRangeDeletionTaskLocally` (range_deletion_util.cpp:721-725) and `getRangeDeletionTask` (range_deletion_util.cpp:841) build their query filter using only `{collectionUuid, range.min, range.max}`, without including `migrationId`. During recovery replay of M1's commit cleanup, these functions match M2's range deletion task (which covers the same range) instead of the already-deleted M1 task.

The asymmetry is explicit in the code: `getQueryFilterForRangeDeletionTaskOnRecipient` (line 323-328) correctly includes migrationId via `addFields(BSON(kIdFieldName << migrationId))`, with a comment (line 320-322) explaining this is needed "to be resilient to delayed network retries." The local-side functions lack this protection.

### Affected Code

- `range_deletion_util.cpp:721-725`: `markAsReadyRangeDeletionTaskLocally` — filter without migrationId
- `range_deletion_util.cpp:841`: `getRangeDeletionTask` — filter without migrationId
- `range_deletion_util.cpp:312-318`: `getQueryFilterForRangeDeletionTask` — helper missing migrationId
- `migration_coordinator.cpp:285-321`: commit cleanup path calls these functions

### Recommendation

Add `migrationId` to `getQueryFilterForRangeDeletionTask`, matching the pattern already used in `getQueryFilterForRangeDeletionTaskOnRecipient`. This protects all callers: `deleteRangeDeletionTaskLocally`, `markAsReadyRangeDeletionTaskLocally`, `getRangeDeletionTask`, and `persistUpdatedNumOrphans`.

Related historical fix: SERVER-69586 (added migrationId to recipient-side filter only).

---

## Bug 2: Commit Path Missing ShardNotFound Exception Handling

- **Bug Family**: Family 2 — Missing ShardNotFound handling on commit path
- **Severity**: High
- **Invariant violated**: CommitPathHandlesRecipientRemoval
- **Config**: MC_hunt_family2.cfg
- **Counterexample**: 6 states (output/MC_hunt_family2.out)

### Trace Summary

1. **State 2**: Migration M1 starts.
2. **State 3**: M1 advances to CommittingOnConfig phase.
3. **State 4**: **Recipient shard is removed** (e.g., via removeShard admin command).
4. **State 5**: Config server commits M1 successfully. Donor enters commit cleanup at `cmtPersist`.
5. **State 6**: `DoCommitPersist` succeeds (local operation). Advances to `cmtAdvTxn`.
6. **Deadlock**: `DoCommitAdvanceTxn` requires `recipientExists = TRUE`. The commit path is **permanently stuck** at `cmtAdvTxn`. The coordinator doc persists forever, blocking future migrations.

### Root Cause

`advanceTransactionOnRecipient` (migration_coordinator.cpp:252-255) on the commit path is NOT wrapped in a try-catch for `ShardNotFound`. When the recipient shard has been removed, this call throws `ShardNotFound`, which propagates uncaught. The cleanup path cannot complete, and the coordinator document persists indefinitely.

The abort path correctly handles this: migration_coordinator.cpp:361-375 wraps the same call in `catch (const ExceptionFor<ErrorCodes::ShardNotFound>&)`.

Two additional commit-path operations are also unprotected:
- `retrieveNumOrphansFromShard` (line 265-266)
- `deleteRangeDeletionTaskOnRecipient` (line 278-282)

### Affected Code

- `migration_coordinator.cpp:252-255`: `advanceTransactionOnRecipient` — no ShardNotFound handling
- `migration_coordinator.cpp:265-266`: `retrieveNumOrphansFromShard` — no ShardNotFound handling
- `migration_coordinator.cpp:278-282`: `deleteRangeDeletionTaskOnRecipient` — no ShardNotFound handling

### Recommendation

Wrap the three recipient-contacting operations in try-catch for `ShardNotFound`, matching the abort path pattern (line 361-375). When the recipient is gone, these operations can be safely skipped: the transaction will expire, the orphan count is advisory, and the recipient's task no longer exists.

---

## Bug 3: Limbo Coordinator Document After Config Commit Failure

- **Bug Family**: Family 3 — Coordinator commit path limbo state
- **Severity**: High
- **Invariant violated**: NoLimboCoordinatorDoc
- **Config**: MC_hunt_family3.cfg
- **Counterexample**: 4 states (output/MC_hunt_family3.out)

### Trace Summary

1. **State 2**: Migration M1 starts. Coordinator doc created with `NoDecision`.
2. **State 3**: M1 advances to CommittingOnConfig phase.
3. **State 4**: **ConfigCommitFail** — the config server commit RPC fails (network error, timeout, etc.). The donor calls `_cleanup(false)`.
4. **Violation**: `coordDocs[m1] = "none"` (NoDecision) persists, but `activeMigration = Nil` and `migrationPhase = "idle"`. No migration is active, yet a coordinator doc with no decision exists. It will persist until the next step-up triggers `resumeMigrationCoordinationsOnStepUp`.

### Root Cause

`_cleanup(false)` (migration_source_manager.cpp:950-955) only sets the decision to `kAborted` when `_state < kCommittingOnConfig`. When called from the config commit error handler (line 694), `_state == kCommittingOnConfig`, so the condition is FALSE and no decision is set. `completeMigration` is also not called (line 966-971, `completeMigration` param is false).

The coordinator doc persists with `NoDecision`. `asyncRecoverMigrationUntilSuccessOrStepDown` (line 695-697) only refreshes metadata — it does NOT complete the coordinator.

The `migrationCommitNetworkError` failpoint at line 673 confirms MongoDB is aware of this scenario.

### Affected Code

- `migration_source_manager.cpp:681-698`: config commit error handler — calls `_cleanup(false)`
- `migration_source_manager.cpp:950-955`: `_cleanup` — condition prevents setting decision
- `migration_source_manager.cpp:966-971`: `_cleanup` — `completeMigration` not called

### Recommendation

When `_cleanup(false)` is called from the config commit error handler, the coordinator doc should either:
1. Set a decision (query config server for the actual outcome), or
2. Explicitly trigger `completeMigration` to resolve the limbo state

Currently, the system relies on the next primary step-up to recover, which creates an unbounded limbo window.

---

## Bug 4: Non-Idempotent Orphan Count Increment on Recovery Replay

- **Bug Family**: Family 5 — Non-idempotent recovery operations
- **Severity**: Medium
- **Invariant violated**: OrphanCountBounded
- **Config**: MC_hunt_family5.cfg
- **Counterexample**: 14 states (output/MC_hunt_family5.out)

### Trace Summary

1. **States 1-7**: Migration M1 commits successfully. Commit cleanup begins.
2. **State 8**: `DoCommitPersistOrphans` — `persistUpdatedNumOrphans` increments orphan count by 1 (`orphanDelta = 1`).
3. **State 9**: **Stepdown** after orphan count persisted but before cleanup completes. Cleanup state is lost.
4. **State 10**: **RecoverMigration(m1)** — new primary finds M1's coordinator doc with "committed" decision. Restarts commit cleanup from the beginning.
5. **States 11-13**: Commit cleanup replays: persistCommitDecision, advanceTxn, retrieveOrphans.
6. **State 14**: `DoCommitPersistOrphans` runs **again** — orphan count incremented a second time (`orphanDelta = 2`). But only 1 migration committed, so the true orphan delta should be 1.

### Root Cause

`persistUpdatedNumOrphans` (range_deletion_util.cpp:549) uses `$inc` (increment), which is NOT idempotent. When recovery replays the commit cleanup from the beginning, the orphan count is incremented again. After N stepdowns during commit cleanup, the orphan count is inflated by N times.

The filter in `persistUpdatedNumOrphans` (line 539) also uses `getQueryFilterForRangeDeletionTask` (no migrationId), compounding with Bug 1 if multiple tasks exist for the same range.

### Affected Code

- `range_deletion_util.cpp:549`: `$inc` operator — non-idempotent
- `range_deletion_util.cpp:539`: filter without migrationId
- `migration_coordinator.cpp:269-271`: calls `persistUpdatedNumOrphans`

### Recommendation

Replace `$inc` with `$set` to make the update idempotent. The orphan count should be set to the absolute value retrieved from the recipient, not incremented. Alternatively, track whether the orphan count was already persisted in the coordinator doc to skip the step on recovery replay.

---

## Not Reproduced

| Bug Family | Config | States Explored | Diameter | Result |
|------------|--------|-----------------|----------|--------|
| Family 1 (abort path) | MC_hunt_family1.cfg | 118 distinct | 16 | ActiveMigrationHasTask violated — **Case A** (invariant too strong). Partial abort cleanup + stepdown leaves task deleted but coordDoc persists. The invariant should only require task existence for NoDecision docs. The cross-migration wrong-task-deletion bug is captured by Family 1 commit path instead. |

## State Space Coverage

| Config | States Generated | Distinct States | Diameter | Duration |
|--------|-----------------|-----------------|----------|----------|
| MC.cfg (convergence) | 16,624 | 7,105 | 65 | <1s |
| MC_hunt_family1.cfg | 222 | 118 | 16 | <1s |
| MC_hunt_family1_commit.cfg | 867 | 526 | 28 | <1s |
| MC_hunt_family2.cfg | 84 | 58 | 15 | <1s |
| MC_hunt_family3.cfg | 112 | 73 | 16 | <1s |
| MC_hunt_family5.cfg | 340 | 200 | 20 | <1s |

All hunting configs completed exhaustive BFS in under 1 second. The state spaces are small because the spec deliberately focuses on the coordinator cleanup path (not the full data transfer), enabling complete exploration.
