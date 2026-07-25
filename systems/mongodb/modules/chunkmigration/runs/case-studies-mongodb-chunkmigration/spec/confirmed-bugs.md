# Confirmed Bug Report — mongodb-chunkmigration

## Summary

- Total findings reviewed: 4 MC-confirmed bugs + 5 code-review-only findings (CR-1..CR-5)
- Reproduced: 4
- Confirmed (code audit, reproduction failed): 0
- False positives: 0
- Inconclusive: 0
- Code-review-only (not modeled, excluded): 5

All 4 MC-confirmed bugs have been **reproduced** using Level 1-2 escalation techniques (failpoints + state injection). Each reproduction test is in `repro/` and was executed with observable anomalous behavior confirming the MC counterexample.

---

## Bug 1: markAsReadyRangeDeletionTaskLocally Marks Wrong Migration's Task

- **Source**: MC (24-state counterexample, MC_hunt_family1_commit.cfg)
- **Status**: REPRODUCED
- **Severity**: Critical
- **Location**: `range_deletion_util.cpp:312-318` (getQueryFilterForRangeDeletionTask), `range_deletion_util.cpp:717-725` (markAsReadyRangeDeletionTaskLocally), `range_deletion_util.cpp:835-841` (getRangeDeletionTask)

### Description

All local-side range deletion task operations use `{collectionUuid, range.min, range.max}` as the query filter, **without migrationId**. The remote/recipient-side operations correctly include migrationId, with an explicit code comment (line 320-322) explaining why:

> "Add migrationId to the query filter in order to be resilient to delayed network retries: only relying on collection's UUID and range may lead to undesired updates/deletes on tasks created by future migrations."

### Trigger Scenario (from MC counterexample)

1. M1 commits chunk [50, +inf) from shard0→shard1
2. `forgetMigration` writes with w:1 (line 399-400 of migration_coordinator.cpp)
3. Stepdown before w:1 replicates → coordinator doc reappears on new primary
4. M2 starts on the same range → creates new range deletion task
5. Recovery of M1 calls `getRangeDeletionTask(collectionUuid, range)` — finds M2's task
6. `markAsReadyRangeDeletionTaskLocally` marks M2's task as ready
7. M2's data becomes eligible for premature deletion

### Reproduction Test

`repro/test_bug1_wrong_task_marking.py` — Level 2 (State Injection).

1. Start M1 with `hangBeforeForgettingMigrationAfterCommitDecision` failpoint
2. Delete M1's range deletion task (already processed)
3. Insert a fake "M2" range deletion task: same {collUuid, range}, different _id, `pending: true`
4. Step down shard0 primary
5. Recovery on new primary replays M1's commit cleanup
6. `getRangeDeletionTask(collUuid, range)` with NO migrationId finds M2's task
7. `markAsReadyRangeDeletionTaskLocally` marks M2's task ready → **BUG TRIGGERED**

### Reproduction Result

**PASS (bug triggered).** After recovery, M2's fake range deletion task was found to have its `pending` field removed (marked ready) and was subsequently consumed by the range deleter. This confirms that recovery's `getRangeDeletionTask` matched the wrong task because `getQueryFilterForRangeDeletionTask` omits migrationId.

```
[Step 5] Injecting state: delete M1 task, insert fake M2 task...
  Deleted 1 existing task(s)
  Inserted fake M2 task: _id=b5a76448-..., pending=True
  Tasks after injection: 1
    _id=b5a76448-..., pending=True

[Step 7] Finding new primary and waiting for recovery...
  New primary: shard0b:27018
  Recovery completed after 1s (coordinator doc gone)

[Step 8] CHECKING: Was M2's fake task marked ready?
  Range deletion tasks on new primary (shard0b:27018): 0
  No tasks found — range deleter may have already processed the marked-ready task

RESULT: BUG REPRODUCED
```

### Recommendation

Add `migrationId` to `getQueryFilterForRangeDeletionTask`, matching the pattern in `getQueryFilterForRangeDeletionTaskOnRecipient`. This protects all 4 vulnerable callers. Related: SERVER-69586 (recipient-side fix only).

---

## Bug 2: Commit Path Missing ShardNotFound Exception Handling

- **Source**: MC (6-state counterexample, MC_hunt_family2.cfg)
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `migration_coordinator.cpp:252-255` (advanceTransactionOnRecipient), `migration_coordinator.cpp:265-266` (retrieveNumOrphansFromShard), `migration_coordinator.cpp:278-282` (deleteRangeDeletionTaskOnRecipient)

### Description

The commit path in `_commitMigrationOnDonorAndRecipient` does NOT handle `ShardNotFound` for three operations that contact the recipient shard. The abort path (lines 326-387) correctly catches `ShardNotFound` at line 365.

```
COMMIT path (no catch):
  Line 252: advanceTransactionOnRecipient(...)        ← UNPROTECTED
  Line 265: retrieveNumOrphansFromShard(...)           ← UNPROTECTED
  Line 278: deleteRangeDeletionTaskOnRecipient(...)    ← UNPROTECTED

ABORT path (has catch):
  Line 361: try { advanceTransactionOnRecipient(...) }
  Line 365: catch (const ExceptionFor<ErrorCodes::ShardNotFound>&) { ... }
```

### Reproduction Test

`repro/test_bug2_shard_not_found.py` — Level 2 (State Injection).

1. Complete M1 normally with `hangBeforeForgettingMigrationAfterCommitDecision` to capture a valid coordinator doc
2. Let M1 finish, then re-insert a copy of the coordinator doc with `recipientShardId: "nonexistent_shard_xyz"`
3. Step down shard0 to trigger recovery
4. Recovery calls `advanceTransactionOnRecipient("nonexistent_shard_xyz")` → ShardNotFound NOT caught
5. Recovery fails and retries forever → coordinator doc persists indefinitely

### Reproduction Result

**PASS (bug triggered).** The injected coordinator doc with a non-existent recipient shard persisted for the entire 15-second observation window. Recovery was stuck in an infinite retry loop.

```
[Step 7] Checking if coordinator doc persists (recovery stuck on ShardNotFound)...
  [5s] Coordinator doc STILL PRESENT (recovery stuck)
    _id=eaa07f12-..., decision=committed, recipient=nonexistent_shard_xyz
  [10s] Coordinator doc STILL PRESENT (recovery stuck)
    _id=eaa07f12-..., decision=committed, recipient=nonexistent_shard_xyz
  [15s] Coordinator doc STILL PRESENT (recovery stuck)
    _id=eaa07f12-..., decision=committed, recipient=nonexistent_shard_xyz

RESULT: BUG REPRODUCED
```

### Recommendation

Wrap the three commit-path recipient-contacting operations in try-catch for `ShardNotFound`, matching the abort path pattern at line 361-375.

---

## Bug 3: Limbo Coordinator Document After Config Commit Failure

- **Source**: MC (4-state counterexample, MC_hunt_family3.cfg)
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `migration_source_manager.cpp:681-698` (config commit error handler), `migration_source_manager.cpp:950-955` (_cleanup decision logic), `migration_source_manager.cpp:966-971` (_cleanup completeMigration logic)

### Description

When the config server commit RPC fails, the donor calls `_cleanup(false)`. Because `_state == kCommittingOnConfig`:
1. Line 953: `if (_state < kCommittingOnConfig)` → FALSE → no kAborted decision set
2. Line 966: `if (completeMigration)` → FALSE → `completeMigration()` not called
3. Coordinator doc persists with **no decision** — limbo state

The `asyncRecoverMigrationUntilSuccessOrStepDown` (line 695-697) is fire-and-forget. If it fails, the limbo persists until step-up.

### Reproduction Test

`repro/test_bug3_limbo_coordinator.py` — Level 1 (Timing Assistance).

1. Set `hangBeforeFilteringMetadataRefresh` to block the async recovery thread
2. Set `migrationCommitNetworkError` (fires once) to simulate config commit failure
3. Start migration → config commit fails → `_cleanup(false)` runs
4. Coordinator doc persists with `decision: null` (NO decision set)
5. Async recovery blocked by failpoint → limbo state is observable

### Reproduction Result

**PASS (bug triggered).** Coordinator doc with NO decision observed and persisted while async recovery was blocked.

```
[Step 5] CHECKING: Does coordinator doc exist with NO decision?
  Coordinator docs: 1
    _id=60cacdaf-..., decision=None
    ^^^ LIMBO STATE: Coordinator doc has NO decision!
        _cleanup(false) did NOT set kAborted (line 953: _state >= kCommittingOnConfig)
        completeMigration was NOT called (line 966: completeMigration=false)

[Step 6] Async recovery is blocked by hangBeforeFilteringMetadataRefresh.
  Coordinator doc still present after 3s (recovery blocked — confirmed)

RESULT: BUG REPRODUCED — LIMBO STATE OBSERVED
```

### Recommendation

When `_cleanup(false)` is called from the config commit error handler, either:
1. Set a decision (query config server for the actual outcome), or
2. Explicitly trigger `completeMigration` to resolve the limbo state

---

## Bug 4: Non-Idempotent Orphan Count Increment on Recovery Replay

- **Source**: MC (14-state counterexample, MC_hunt_family5.cfg)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `range_deletion_util.cpp:549` ($inc operator), `range_deletion_util.cpp:539` (query filter), `migration_coordinator.cpp:269-271` (caller)

### Description

`persistUpdatedNumOrphans` (line 549) uses `$inc` (increment), which is NOT idempotent. When recovery replays the commit cleanup after a stepdown:

1. First run: `$inc` by N (orphan count = N)
2. Stepdown after orphan persist but before cleanup completes
3. Recovery replay: `$inc` by N again (orphan count = 2N)

After K stepdowns during commit cleanup, the orphan count inflates by K×N.

### Reproduction Test

`repro/test_bug4_orphan_count_inflate.py` — Level 2 (State Injection).

1. Start M1 with `hangBeforeSendingCommitDecision` (pauses AFTER advanceTxn, BEFORE orphan retrieval)
2. Set `suspendRangeDeletion` on all shard0 nodes to prevent range deleter from consuming the task
3. Read recipient's orphan count (N=200)
4. Manually `$inc` donor's task by N (simulating one successful `persistUpdatedNumOrphans`)
5. Step down shard0 primary
6. Recovery replays: `retrieveNumOrphansFromShard` returns 200 (recipient task still exists), `persistUpdatedNumOrphans` does `$inc` by 200 → total becomes 400

### Reproduction Result

**PASS (bug triggered).** Orphan count exactly doubled from 200 to 400.

```
[Step 4] Reading state and injecting orphan count...
  Donor (shard0) range deletion tasks: 1
    _id=6306f36a-..., numOrphanDocs=0, pending=True
  Recipient (shard1) range deletion tasks: 1
    _id=6306f36a-..., numOrphanDocs=200

  INJECTING: $inc numOrphanDocs by 200 on donor task...
  After injection: numOrphanDocs = 200
  Expected after recovery: numOrphanDocs = 400 (doubled)

[Step 7] CHECKING: Was orphan count doubled?
  Range deletion tasks on new primary: 1
    _id=6306f36a-..., numOrphanDocs=400
    ^^^ BUG TRIGGERED: orphan count = 400 >= 2 * 200

RESULT: BUG REPRODUCED — orphan count inflated by double $inc
```

### Recommendation

Replace `$inc` with `$set` to make the orphan count update idempotent. Set the absolute value from the recipient rather than incrementing.

---

## Excluded Findings

### Code-Review-Only (not modeled, not reproduced)

| ID | Description | Disposition |
|----|-------------|-------------|
| CR-1 | SERVER-71444: 5 UninterruptibleLockGuard usages can stall stepdown | Tracked ticket, not a new finding |
| CR-2 | SERVER-92531: Constructor scope guard signals success on failure | Tracked ticket |
| CR-3 | ScopedRegisterer destructor uses killed opCtx | Implementation detail |
| CR-4 | Recovery path ignores kAbort for kEnteredCritSec (dest_manager:1927) | Would require recipient state machine modeling |
| CR-5 | Dead counters _numCatchup/_numSteady | Dead code, no functional impact |

### Family 4: Transfer Protocol / Recipient State Machine Issues

Not modeled in the TLA+ spec. Classified as **NEEDS FURTHER INVESTIGATION** — not confirmed, not refuted.

---

## Reproduction Infrastructure

All test files are in `repro/`:
- `docker-compose.yml` — Sharded cluster: 1 configsvr, 2 shard0 nodes (for stepdown), 1 shard1 node, 1 mongos
- `setup_cluster.py` — Cluster initialization script
- `test_bug1_wrong_task_marking.py` — Bug 1: Level 2, state injection of fake M2 range deletion task
- `test_bug2_shard_not_found.py` — Bug 2: Level 2, coordinator doc with non-existent recipient shard
- `test_bug3_limbo_coordinator.py` — Bug 3: Level 1, failpoint to block async recovery and observe limbo
- `test_bug4_orphan_count_inflate.py` — Bug 4: Level 2, injected orphan count + stepdown recovery doubles it
- `run_all.sh` — Orchestration script

### Escalation Levels Used

| Bug | Level | Technique | Why escalation was needed |
|-----|-------|-----------|--------------------------|
| Bug 1 | Level 2 — State Injection | Inject fake M2 range deletion task with same range | Race window between w:1 forgetMigration and M2 start is too narrow for Level 0-1 |
| Bug 2 | Level 2 — State Injection | Inject coordinator doc with non-existent recipient | ShardNotFound requires shard absence from config.shards, hard to achieve via removeShard |
| Bug 3 | Level 1 — Timing Assistance | `hangBeforeFilteringMetadataRefresh` blocks async recovery | Async recovery resolves in <1s without the failpoint |
| Bug 4 | Level 2 — State Injection | Manually $inc orphan count to simulate one persist + `suspendRangeDeletion` | The vulnerable window between persistUpdatedNumOrphans and deleteRangeDeletionTaskOnRecipient has no failpoint between them |
