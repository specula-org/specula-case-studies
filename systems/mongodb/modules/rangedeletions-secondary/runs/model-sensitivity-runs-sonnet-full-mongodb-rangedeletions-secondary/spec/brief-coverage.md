# Brief Coverage Self-Audit

Maps brief §2 (Bug Families), §5 (Invariants), and §6.1 (Model-Checkable Findings) to spec artifacts.

---

## §2 Bug Families → Hunt Configs

| Brief Family | Hunt Config | Target Invariant(s) | Notes |
|---|---|---|---|
| F1: Orphan-Deletion-Before-Task-Removal | `MC_hunt_family1.cfg` | `OrphanDeletionBeforeTaskDocRemoval`, `CompletionFutureImpliesMajorityOrphans` | Models step-down mid-majority-wait via `MCMajorityWaitInterrupted`. Replication via `ReplicateDiskState`. |
| F2: Recovery Scan Completeness | `MC_hunt_family2.cfg` | `NoLostReadyTasks` | Models two-phase scan with op_observer interleaved via `OpObserverClearPending` + `OpObserverRegisterTask`. `MaxStepDowns=3` allows multiple step-up/step-down cycles. |
| F3: Non-Atomic Task Completion | `MC_hunt_family3.cfg` | `CompletionFutureImpliesMajorityOrphans`, `OrphanDeletionBeforeTaskDocRemoval` | `CompleteInMemory` and `RemovePersistentTask` are separate actions; `StepDown` between them is the fault. `MCStepDown` is bounded to expose this window. |

All three families have dedicated hunt configs. ✓

---

## §5 Invariants → Spec + Hunt Config Coverage

| Brief Invariant | Type | Spec Variable(s) | Enabled in Hunt Config |
|---|---|---|---|
| `OrphanDeletionBeforeTaskDocRemoval` | Safety | `diskTaskState`, `orphansMajorityCommitted` | `MC_hunt_family1.cfg`, `MC_hunt_family3.cfg` |
| `RecoveryCompleteness` | Liveness | `inMemoryTasks`, `recoveryPhase`, `diskTaskState` | `MC_hunt_family2.cfg` (as `NoLostReadyTasks` safety proxy) |
| `CompletionFutureImpliesMajorityOrphans` | Safety | `completionFulfilled`, `orphansMajorityCommitted` | `MC_hunt_family1.cfg`, `MC_hunt_family3.cfg` |
| `NoLostTasks` | Liveness | `diskTaskState`, `completionFulfilled`, `inMemoryTasks` | `MC_hunt_family2.cfg` (as `NoLostReadyTasks`) |
| `NoDuplicateActiveExecution` | Safety | `ElectionSafety` + `PrimaryOnlyExecution` | `MC.cfg` (structural invariants, always enabled) |

**Note on RecoveryCompleteness**: The liveness property `RecoveryCompleteness` (brief §5) requires fairness assumptions not yet encoded. The safety proxy `NoLostReadyTasks` checks the same gap: after recovery is done, every ready disk task is either in memory, executing, or completed. This is checkable without fairness and catches the same bugs as the liveness form.

All §5 invariants are either directly represented or have a safety-checkable proxy enabled in ≥1 hunt config. ✓

---

## §6.1 Model-Checkable Findings → Reachability via Hunt Configs

| Finding | Hunt Config | How the fault setup makes it reachable |
|---|---|---|
| MC1: step-down after orphan batch but before majority wait returns | `MC_hunt_family1.cfg` | `MCMajorityWaitInterrupted` fires during `"deleting"` step; `MCStepDown` then fires. `OrphanDeletionBeforeTaskDocRemoval` checked. Replication via `ReplicateDiskState` can then show secondary applying `TaskDeleted` without prior orphan deletion commit if the invariant is wrong. |
| MC2: task pending->ready between phase 1 and phase 2, op_observer fires before `_termInitializationPromise` | `MC_hunt_family2.cfg` | `OpObserverClearPending` can fire on a secondary (pending->ready on disk) while primary is in `RecoveryPhase1`. If `termInitReady` was not yet set when op_observer fires, `opObserverPending` is not updated, and the task is not registered by op_observer. Phase 2 scan must then pick it up. `MaxStepDowns=3` allows repeated cycles. `NoLostReadyTasks` checks the invariant. |
| MC3: step-down between `completeTask` and `removePersistentTask` | `MC_hunt_family3.cfg` | `CompleteInMemory` sets `completionFulfilled=TRUE` and moves to `"completing"`. `MCStepDown` then fires before `RemovePersistentTask`. Disk document survives (`diskTaskState=TaskProcessing`). New primary recovers and re-executes. `CompletionFutureImpliesMajorityOrphans` is checked to ensure callers who received the fulfilled future had their orphans correctly committed. |

All §6.1 findings have a hunt config whose fault setup makes them reachable. ✓

---

## Gaps and Out-of-Scope Items

| Item from brief | Status |
|---|---|
| `orphanCleanupDelaySecs` timer (brief §3.2) | Out of scope — time-based heuristic, not a safety invariant |
| `numOrphanDocs` counter accuracy (brief §3.2) | Out of scope — best-effort metric |
| `remainingJobCount` int8_t overflow (brief §3.2) | Out of scope — implementation artifact |
| CR1/CR2/CR3 code-review-only findings (brief §6.3) | Out of scope — not model-checkable |
| TV1/TV2 test-verifiable findings (brief §6.2) | Covered by instrumentation-spec.md (trace-level) |
| `NoDuplicateActiveExecution` | Captured via `ElectionSafety` + `PrimaryOnlyExecution` structural invariants; a single primary implies at most one active executor for any task. The brief's concern is already enforced by the election model. |
