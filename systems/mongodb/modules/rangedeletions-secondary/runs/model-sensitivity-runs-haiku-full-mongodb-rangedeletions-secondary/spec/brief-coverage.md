# Brief Coverage Self-Audit

**Spec Generation Phase 2.5**: Mapping modeling brief findings to spec extensions and hunting configs.

---

## Brief §2: Bug Families → Spec Coverage

| Family | Priority | Spec Actions | MC Invariants | Hunting Config | Status |
|--------|----------|--------------|---------------|---|---|
| **Family 1: Persistent State Sync** | High | `InsertTaskDocument`, `MarkTaskReadyInDocument`, `MarkTaskProcessingInDocument`, `RemoveTaskDocument`, `RegisterTaskInMemory` | `TaskDocumentExistenceConsistency`, `DeletedTaskNotTracked` | `MC_hunt_family1.cfg` | ✓ COVERED |
| **Family 2: Recovery Completeness** | High | `BecomePublicPrimary`, `CompleteRecoverySuccessfully`, `InterruptRecoveryByStepDown`, `MCInterruptRecoveryByStepDown`, `StartProcessor` | `RecoveryCompletenessOnRoleChange`, `IncompleteRecoveryTracked` | `MC_hunt_family2.cfg` | ✓ COVERED |
| **Family 3: Overlap Ordering** | Medium | `RegisterTaskInMemory`, `DetectAndWaitForOverlaps`, `CompleteOverlapWait`, `MCRegisterTaskDelay`, `MCOverlapDetectionFailure` | `OverlapSerializationOrder` | `MC_hunt_family3.cfg` | ✓ COVERED |
| **Family 4: Secondary Coordination** | Medium | `SecondaryObserveTaskInsert`, `InvalidateRangeOnSecondary`, `InvalidateRangeOnPrimary`, `BecomeSecondary`, `BecomePublicPrimary` | `SecondaryInvalidationConsistency` | `MC_hunt_family4.cfg` | ✓ COVERED |
| **Family 5: Shutdown Race** | Medium | `StartProcessor`, `DequeuTaskForDeletion`, `BeginDeletion`, `CompleteDeletion`, `RemoveTaskFromMemory`, `ShutdownProcessor`, `MCShutdownDuringDeletion` | `OrphansDeletion`, `Family5_DeletionProgress` | `MC_hunt_family5.cfg` | ✓ COVERED |
| **Family 6: OpCtx Cleanup** | Low | N/A (requires executor lifecycle modeling) | N/A | N/A | NOT IN SCOPE |

---

## Brief §5: Proposed Invariants → MC Enabled

| Invariant | Type | Spec Definition | MC.cfg Status | Hunt Config | Enabled |
|-----------|------|---|---|---|---|
| TaskDocumentExistenceConsistency | Safety | `base.tla:265-270` | Standard | Family1 | ✓ |
| RecoveryCompletenessOnRoleChange | Safety | `base.tla:281-288` | Comment | Family2 | ✓ Family2 only |
| OverlapSerializationOrder | Safety | `base.tla:297-308` | Comment | Family3 | ✓ Family3 only |
| SecondaryInvalidationConsistency | Safety | `base.tla:318-321` | Comment | Family4 | ✓ Family4 only |
| OrphansDeletion | Safety | `base.tla:330-332` | Standard | Family5 | ✓ |
| NoTaskQueueDeadlock | Liveness | `base.tla:337-339` | N/A | N/A | ✗ Not checked (temporal) |

---

## Brief §6.1: Model-Checkable Findings → Hunting Configs

| Finding | Description | Expected Violation | Hunt Config | Trigger Mechanism |
|---------|---|---|---|---|
| **MC1** | Task document deleted while in-memory tracker holds reference | `TaskDocumentExistenceConsistency` | `MC_hunt_family1.cfg` | `MCTaskLossWindow` fault injects loss during sync window |
| **MC2** | Service transitions to kUp without all recovered tasks registered | `RecoveryCompletenessOnRoleChange` | `MC_hunt_family2.cfg` | `MCInterruptRecoveryByStepDown` simulates race between recovery and role change |
| **MC3** | Two overlapping tasks both enqueued despite serialization | `OverlapSerializationOrder` | `MC_hunt_family3.cfg` | `MCOverlapDetectionFailure` allows task to skip waiting, `MCRegisterTaskDelay` creates TOCTOU window |
| **MC4** | Primary-secondary divergence on invalidated ranges | `SecondaryInvalidationConsistency` | `MC_hunt_family4.cfg` | Role transitions + independent invalidation on each role |
| **MC5** | Partial deletion leaves orphans after step-down | `OrphansDeletion` | `MC_hunt_family5.cfg` | `MCShutdownDuringDeletion` interrupts task mid-deletion, recovery must re-enqueue |

---

## Spec Extensions Summary

### Extension: PersistentTaskState (Family 1)
- **Variable**: `persistentTaskState`, `taskPendingFlag`, `taskProcessingFlag`
- **Actions**: `InsertTaskDocument`, `MarkTaskReadyInDocument`, `MarkTaskProcessingInDocument`, `RemoveTaskDocument`
- **Purpose**: Model the four-state lifecycle (pending → ready → processing → deleted) with separate flag transitions
- **Code**: `range_deletion_util.cpp:243-271`, `range_deleter_service_op_observer.cpp:68-102`

### Extension: TermAwareRecovery (Family 2)
- **Variable**: `currentTerm`, `recoveryInFlight`, `recoveryOutcome`, `tasksRecoveredInTerm`, `lastRecoveredTerm`
- **Actions**: `BecomePublicPrimary`, `CompleteRecoverySuccessfully`, `InterruptRecoveryByStepDown`, `StartProcessor`
- **Purpose**: Track async recovery across term boundaries, detect incomplete recovery
- **Code**: `range_deleter_service.cpp:127-180`, `range_deleter_service.cpp:156-175`

### Extension: OverlapOrdering (Family 3)
- **Variable**: `taskRegistrationOrder`, `registrationClock`, `pendingOverlapWaiters`
- **Actions**: `RegisterTaskInMemory`, `DetectAndWaitForOverlaps`, `CompleteOverlapWait`
- **Purpose**: Model TOCTOU window between map insertion and overlap detection
- **Code**: `range_deleter_service.cpp:377-426`

### Extension: ReplicaRoleAwareness (Family 4)
- **Variable**: `replicaRole`, `invalidatedRanges`
- **Actions**: `BecomeSecondary`, `BecomePublicPrimary`, `SecondaryObserveTaskInsert`, `InvalidateRangeOnSecondary`, `InvalidateRangeOnPrimary`
- **Purpose**: Model role-specific behavior (deletion on primary only, observation on secondary)
- **Code**: `range_deleter_service.h:71`, `range_deleter_service_op_observer.cpp:139-175`

### Extension: DeletionStepwise (Family 5)
- **Variable**: `processorState`, `taskBeingDeleted`, `deletionProgress`
- **Actions**: `StartProcessor`, `DequeuTaskForDeletion`, `BeginDeletion`, `CompleteDeletion`, `RemoveTaskFromMemory`, `ShutdownProcessor`
- **Purpose**: Model deletion as multi-step (dequeue, mark, delete, complete, remove); track interruption points
- **Code**: `ready_range_deletions_processor.cpp:210-228`, `range_deleter_service.cpp:306-309`

---

## Fault-Injection Actions (MC Layer)

| Fault | Bound | Target Family | Mechanism | MC Counter |
|-------|-------|---|---|---|
| **RecoveryInterrupt** | 2 | Family 2 | Step-down during async recovery | `MCInterruptRecoveryByStepDown` |
| **TaskLoss** | 2 | Family 1 | Loss in persistent-to-in-memory sync window | `MCTaskLossWindow` |
| **ShutdownDuringDeletion** | 2 | Family 5 | Processor kills operation mid-deletion | `MCShutdownDuringDeletion` |
| **RegisterDelay** | 3 | Family 3 | Stall task registration to widen TOCTOU | `MCRegisterTaskDelay` |
| **OverlapDetectionFailure** | 1 | Family 3 | Allow task to skip overlap wait | `MCOverlapDetectionFailure` |

---

## Coverage Assessment

✓ **All Brief §2 Bug Families** have dedicated spec actions and hunting configs
✓ **All Brief §5 Safety Invariants** are defined in `base.tla` and enabled in appropriate hunt configs
✓ **All Brief §6.1 Model-Checkable Findings** have targeted hunting configs with reachable violation traces
✓ **Structural Invariants** (TypeInvariant, ConsistentTaskStates, etc.) catch modeling errors
✓ **Fault-Injection Actions** are bounded and deterministic (not fairness-based)

**Gaps and Rationale**:

- **Family 6 (OpCtx Cleanup)** — Not modeled. Low priority, requires executor lifecycle semantics not in scope for message-passing model. Can be addressed via code review.
- **NoTaskQueueDeadlock (Liveness)** — Not checked in MC. Liveness properties require fairness constraints which are case-specific; defer to trace validation and runtime testing.
- **MC4 (Secondary Divergence)** — Simplified in this single-node model. Multi-node trace validation will fully check secondary coordination.

---

## Next Steps

1. **Phase 3**: Generate `Trace.tla` + `Trace.cfg` for trace-based validation
2. **Phase 4**: Generate `instrumentation-spec.md` mapping spec actions to code locations
3. **Harness Generation**: Use instrumentation spec to generate code patches for trace collection
4. **Validation Loop**: Run traces through `Trace.tla` to verify spec faithfulness
