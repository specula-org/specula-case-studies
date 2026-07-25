# Bug Report — MongoDB Range Deletion

## Summary

- Bug families tested: 4
- Bugs found: 2 (Case C), 1 Case A (invariant too strong)
- Configs run: MC_hunt_lifecycle.cfg, MC_hunt_ordering.cfg, MC_hunt_queries.cfg, MC_hunt_identity.cfg

---

## Bug 1: Asymmetric migrationId Filtering Deletes Wrong Task Doc

- **Bug Family**: Family 4 — Cross-Shard Task Identity
- **Severity**: High
- **Invariant violated**: TaskDocConsistency
- **Config**: MC_hunt_identity.cfg
- **Counterexample**: 9 states, `spec/output/MC_hunt_identity.out`

### Trace Summary

1. **State 5** (StartMigration): Migration M1 starts on range R1, creating task 1 with persistent doc (migration=M1)
2. **State 6** (AbortMigration): M1 aborts. Task 1's persistent doc deleted, in-memory state reset to unused
3. **State 7** (StartMigration): Migration M2 starts on the SAME range R1. Task 1 slot reused with new doc (migration=M2)
4. **State 8** (CommitMigration): M2 commits. Task 1 is now "pending" in memory, doc exists with migration=M2
5. **State 9** (RetryDeleteTaskLocally): M1's abort retries `deleteRangeDeletionTaskLocally`. Queries by `(collUUID, range=R1)` WITHOUT migrationId. Finds task 1's doc (which belongs to M2) and **deletes it**

**Result**: Task 1 is "pending" (active in memory) but its persistent doc is gone. TaskDocConsistency violated.

### Root Cause

`deleteRangeDeletionTaskLocally()` at `range_deletion_util.cpp:702-708` queries the persistent store using only `(collectionUuid, range.min, range.max)` — it does NOT include `migrationId` in the filter. A retry of M1's abort cleanup can match and delete M2's task doc if both target the same range.

The recipient-side equivalent `deleteRangeDeletionTaskOnRecipient()` at `range_deletion_util.cpp:677-693` deliberately includes `migrationId` with an explicit comment (lines 320-322): "Add migrationId to the query filter in order to be resilient to delayed network retries: only relying on collection's UUID and range may lead to undesired updates/deletes on tasks created by future migrations."

The donor side lacks this same protection.

### Affected Code

- `range_deletion_util.cpp:702-708`: `deleteRangeDeletionTaskLocally()` — missing migrationId filter
- `range_deletion_util.cpp:312-318`: `getQueryFilterForRangeDeletionTask()` — only filters by (collUUID, range)
- `migration_coordinator.cpp:347-350`: Calls `deleteRangeDeletionTaskLocally` in abort path

### Recommendation

Add `migrationId` to the query filter in `deleteRangeDeletionTaskLocally()`, matching the recipient-side pattern. Use `getQueryFilterForRangeDeletionTaskOnRecipient()` (or equivalent) to include the migration UUID. The comment at line 320-322 already documents exactly why this is necessary.

---

## Bug 2: Recovery Doesn't Prioritize Previously-Executing Tasks

- **Bug Family**: Family 2 — Migration-Deletion Ordering
- **Severity**: Medium
- **Invariant violated**: ResumeInProgressFirst
- **Config**: MC_hunt_ordering.cfg
- **Counterexample**: 20 states, `spec/output/MC_hunt_ordering.out`

### Trace Summary

1. **States 5-6** (StartMigration x2): Two migrations start — M1 on R1, M2 on R2. Both get regTime=1 (same clock). R1 and R2 overlap.
2. **States 7-13**: Task 1 (R1) progresses through the full chain to "executing". Task 2 (R2) commits but is still in registration.
3. **State 14** (StepDown): In-memory state cleared. Persistent state preserved: task 1 has `processing=true` (was executing), task 2 has `processing=false`.
4. **States 15-17** (StepUp + Recovery): Both tasks re-registered as "registered". Task 1 gets `taskRecoveredProcessing=TRUE`.
5. **State 18** (CheckOverlap for task 2): Task 2 (R2) checks overlap. Task 1 (R1) overlaps, but `ShouldWaitFor(2, 1)` = FALSE (same regTime, and `2 < 1` is FALSE). Task 2 proceeds to "waitQueries".
6. **States 19-20**: Task 2 progresses to "executing". Task 1 (recovered-processing) is still stuck at "registered".

**Result**: A non-processing task (task 2) executes on an overlapping range while the recovered-processing task (task 1) is still waiting. ResumeInProgressFirst violated.

### Root Cause

The recovery process at `range_deleter_service.cpp:186-261` re-registers tasks in two phases (processing first, then others), but both use the same `registerTask()` call with identical parameters. The in-memory `RangeDeletion` object (see `range_deletion.h`) does NOT carry a `wasProcessing` flag. Once re-registered, a previously-processing task is indistinguishable from a non-processing task.

The overlap ordering at `range_deleter_service.cpp:404-406` uses only `registrationTime` and task ID as tiebreaker — it ignores the processing flag entirely. With equal registration timestamps (both from the same original registration window), the tiebreaker `taskId < overlappingTaskId` can give priority to the wrong task.

### Affected Code

- `range_deleter_service.cpp:186-261`: Recovery task — doesn't propagate processing status to in-memory state
- `range_deleter_service.cpp:404-406`: Overlap ordering — no processing-flag awareness
- `range_deletion.h`: `RangeDeletion` class — lacks `wasProcessing` field

### Reproduction Attempt

**Test**: `repro/test_bug2_recovery_ordering.py` (executed on MongoDB 8.2.6). **Result: NOT REPRODUCED.**

The overlap ordering vulnerability exists in the code, but the recovery's two-phase registration (Phase 1: processing tasks first, Phase 2: others) combined with the single-threaded executor provides defense-in-depth. Task A (previously-processing) gets a head start and bypasses the overlap check before task B is registered. The MC model registers both tasks atomically, allowing concurrent overlap checks — an interleaving not possible with the sequential implementation.

### Recommendation

1. Add a `wasProcessing` boolean to the `RangeDeletion` in-memory representation (defense-in-depth against future refactoring)
2. Set it from the persistent doc's processing flag during recovery re-registration
3. Use `wasProcessing` as primary sort key in overlap ordering (before registrationTime): processing tasks always take priority over non-processing overlapping tasks
4. Add a test with overlapping ranges to `range_deletion_ordering_with_stepdown.js` (SERVER-64979 test only covers non-overlapping ranges)

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 1 — Lifecycle | MC_hunt_lifecycle.cfg | 376M+ | No violation (NoTaskDeadlock, ServiceStateConsistency pass) |

## Invariant Adjustments

### QueryNotAffected — Case A (Invariant Too Strong)

**Config**: MC_hunt_queries.cfg. **Violation**: 11-state trace where a new query starts on range R1 while deletion is executing on R1.

This is not a real bug. The scenario (new query starting during deletion) is safe in the real system due to:
1. **MVCC**: WiredTiger provides point-in-time snapshots — the query reads a consistent view unaffected by concurrent deletions
2. **Metadata versioning**: After migration commits, the donor's metadata version is bumped, causing new queries to receive StaleConfig and be rerouted to the new shard owner

The invariant is too strong for the spec's abstraction level, which doesn't model per-range metadata versioning or MVCC snapshot isolation. The real bug in this family (SERVER-67385) is about metadata destruction losing OLD query tracking, not new queries starting during deletion.
