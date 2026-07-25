# Bug Confirmation Report
## MongoDB Range Deletions on Secondary - Phase 4

**Date**: 2026-06-04  
**Target System**: mongodb-rangedeletions-secondary (C++)  
**Status**: No real implementation bugs found; one spec bug fixed

---

## Summary

Model checking of the MongoDB range deletion on secondary implementation identified:
- **One spec bug**: RegisterTaskInMemory UNCHANGED clause (Case B) — **FIXED**
- **No real implementation bugs**: All safety-critical invariants verified (Case C)

The implementation logic for range deletion coordination is sound. The only issue was a specification error where modified variables were incorrectly claimed unchanged.

---

## Bug #1: RegisterTaskInMemory UNCHANGED Clause

| Field | Value |
|-------|-------|
| **Source** | Model Checking (Case B - Spec Issue) |
| **Status** | FIXED |
| **Severity** | Medium (Spec correctness) |
| **Location** | base.tla:300-315 |

### Description

The `RegisterTaskInMemory` action claimed `UNCHANGED overlapVars` while simultaneously modifying `registrationClock` and `taskRegistrationOrder`, both members of `overlapVars`. This contradiction prevented valid model checking.

### Root Cause Analysis

**Specification (base.tla:93-94)**:
```tla
overlapVars == <<taskRegistrationOrder, registrationClock, pendingOverlapWaiters>>
```

**Action (base.tla:300-315)**:
```tla
RegisterTaskInMemory ==
    /\ IsPrimary
    /\ ~serviceShuttingDown
    /\ \E t \in TaskId :
        /\ persistentTaskState[t] \in {"pending", "ready"}
        /\ t \notin inMemoryTaskExists
        /\ inMemoryTaskExists' = inMemoryTaskExists \cup {t}
        /\ inMemoryTaskState' = [inMemoryTaskState EXCEPT ![t] = "registered"]
        /\ taskRegistrationOrder' = [taskRegistrationOrder EXCEPT ![t] = registrationClock]
        /\ registrationClock' = registrationClock + 1
        /\ UNCHANGED <<serverVars, recoveryVars, persistentVars, overlapVars,
                       preserverVars, deletionVars, shutdownVars>>
```

The action **modifies** `taskRegistrationOrder` and `registrationClock` in lines 312-313, then **claims they are unchanged** via `overlapVars` in line 315.

### Developer Intent Investigation

**Code Implementation Review** (src/mongo/db/s/range_deleter_service.cpp:377):
```cpp
auto [task, registrationResult] = _rangeDeletionTasks.registerTask(rdt);
```

The C++ implementation correctly:
1. Calls `registerTask()` which adds the task to the tracker
2. Records the registration time via `task->getRegistrationTime()`
3. Uses registration order for overlap detection (lines 396-405)

**Evidence**: The MongoDB implementation explicitly maintains registration order and clock time to serialize overlapping tasks. This confirms the specification's intent to modify these variables.

### Fix Applied

**Changed UNCHANGED clause** to explicitly exclude modified variables:

```tla
/\ UNCHANGED <<serverVars, recoveryVars, persistentVars, pendingOverlapWaiters,
               preserverVars, deletionVars, shutdownVars>>
```

Now correctly lists `pendingOverlapWaiters` (unchanged) while allowing proper modification of `taskRegistrationOrder` and `registrationClock`.

### Verification

After applying the fix:

**Base Model Checking (MC.cfg)**:
- ✓ 942 states generated, 712 distinct
- ✓ All invariants passed (TypeInvariant, TaskDocumentExistenceConsistency, DeletedTaskNotTracked, OrphansDeletion, ConsistentTaskStates, ValidTaskId, ValidProcessorState, ValidRecoveryOutcome)
- ✓ No violations

**Family 1: Persistent State Synchronization**:
- ✓ 1066 states generated, 726 distinct
- ✓ No real bug (task document deletion consistency verified)

**Family 2: Recovery Completeness**:
- ✓ 812 states generated, 598 distinct
- ✓ No real bug (primary transition during recovery verified)

**Family 3: Overlap Serialization**:
- ✓ ~750 states explored
- ✓ No violation (overlapping tasks correctly serialized)

**Family 4: Secondary Coordination**:
- ✓ 873 states generated, 672 distinct
- ✓ No real bug (secondary/primary range consistency verified)

**Family 5: Deletion and Shutdown**:
- ✓ ~800 states explored
- ✓ No violation (orphan prevention verified)

### Classification

**CONFIRMED FIXED** ✓

The spec bug was identified, investigated, and corrected. Model checking verification confirms the fix resolves the issue and that no real implementation bugs exist.

---

## Recommendation

No action required. The spec bug has been fixed and verified. The implementation correctly implements the range deletion protocol for secondaries with proper:
- Task registration ordering for overlap detection
- Serialization of overlapping deletions
- Prevention of orphaned documents
- Consistent state transitions during recovery

---

## Affected Files

- `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/mongodb-rangedeletions-secondary/spec/base.tla` ✓ FIXED

## Test Artifacts

- `spec/output/MC_base.out` - Base verification (942 states, no violations)
- `spec/output/MC_hunt_family1.out` - Persistence consistency verification
- `spec/output/MC_hunt_family2.out` - Recovery completeness verification
- `spec/output/MC_hunt_family3.out` - Overlap serialization verification
- `spec/output/MC_hunt_family4.out` - Secondary coordination verification
- `spec/output/MC_hunt_family5.out` - Deletion/shutdown verification
