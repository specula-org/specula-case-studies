# Bug Report: mongodb-rangedeletions-secondary

**System**: MongoDB RangeDeleterService — orphan deletion on secondaries  
**Model checking date**: 2026-06-08  
**Spec**: `base.tla` / `MC.tla`  
**TLC version**: 2.20  

---

## Summary

Three spec-level issues were found and fixed during convergence. No real implementation bugs were confirmed by model checking. All three bug-family hunting configs passed cleanly after spec fixes.

| ID | Type | Invariant | Classification | Status |
|----|------|-----------|----------------|--------|
| SPB-1 | Spec Bug | `ElectionSafety` | Case B — Spec Modeling Issue | Fixed, re-run passed |
| SPB-2 | Spec Bug | `InMemoryImpliesDisk` | Case B — Spec Modeling Issue | Fixed, re-run passed |
| SPB-3 | Spec Bug | `NoLostReadyTasks` | Case A — Invariant Too Strong | Fixed, re-run passed |
| F1 | Bug Hunt | `OrphanDeletionBeforeTaskDocRemoval`, `CompletionFutureImpliesMajorityOrphans` | No violation | Clean (1,932 distinct states) |
| F2 | Bug Hunt | `NoLostReadyTasks` | No violation | Clean (460,818 distinct states) |
| F3 | Bug Hunt | `CompletionFutureImpliesMajorityOrphans`, `OrphanDeletionBeforeTaskDocRemoval` | No violation | Clean (1,838 distinct states) |

Base check: **18,656,336 distinct states, no violations** (130M states generated, ~2 min).

---

## SPB-1 — Spec Modeling Issue: StepUp Missing Mutual-Exclusion Guard

**Classification**: Case B — Spec allows behavior the implementation prevents  
**Invariant Violated**: `ElectionSafety`  
**Severity**: Spec bug (not an implementation bug)

### Root Cause

`StepUp(n)` lacked a guard ensuring no other node is currently primary. The comment on line 207 of the original `base.tla` said "No other node is primary in the new term (safe for model: bump to fresh term)" but the guard was never added. TLC could fire `StepUp(n1)` followed by `StepUp(n2)` in the same term (both `term[n]=0`, both increment to `term[n]=1`), making two nodes simultaneously primary.

In the real MongoDB replica set, elections require a quorum — two nodes cannot both win the primary role for the same term.

### Counterexample Summary

**6 states**, shortest path:

| Step | Action | Effect |
|------|--------|--------|
| 1 | Initial | All nodes Secondary, term=0 |
| 2–5 | OpObserverClearPending (various) | Tasks transition pending→ready |
| 6 | `StepUp(n1)` | n1→Primary, term[n1]=1 |
| 7 | `StepUp(n2)` | n2→Primary, term[n2]=1 — **VIOLATION** |

Both n1 and n2 are simultaneously Primary at term=1, violating `ElectionSafety`.

### Fix Applied

Added `\A m \in Nodes : ~IsPrimary(m)` guard to `StepUp` in `base.tla`:

```tla
StepUp(n) ==
    /\ IsSecondary(n)
    /\ term[n] < MaxTerm
    /\ \A m \in Nodes : ~IsPrimary(m)   \* ← added
    /\ LET newTerm == term[n] + 1 IN
        ...
```

### Affected Code

Not applicable (spec modeling issue, not an implementation bug).

---

## SPB-2 — Spec Modeling Issue: Stale Op-Observer Registration After Task Completion

**Classification**: Case B — Spec over-models delay of `registerTask` call  
**Invariant Violated**: `InMemoryImpliesDisk`  
**Severity**: Spec bug (not an implementation bug)

### Root Cause

`CompleteInMemory(n, t)` removed `t` from `inMemoryTasks[n]` but did not clear `opObserverPending[n][t]`. If an op-observer registration (`OpObserverClearPending`) had fired for `t` at node `n` before task completion but had not yet been processed by `OpObserverRegisterTask`, the pending registration could fire AFTER `CompleteInMemory`, re-adding `t` to `inMemoryTasks[n]`. When `RemovePersistentTask` then deleted the disk document, `t` remained in `inMemoryTasks[n]` while `diskTaskState[n][t]=TaskDeleted` — violating `InMemoryImpliesDisk`.

The spec models `OpObserverClearPending` (write commits) and `OpObserverRegisterTask` (registerTask call) as independent actions with arbitrary delay. In the real code, `registerTask` is called synchronously by the op-observer callback during the commit, long before `completeTask` is reached in the deletion pipeline. By the time `completeTask` is called, the op-observer registration has already joined the in-progress deletion (dedup: `kJoinedExistingTask`) or been processed earlier. There is no realistic path where a pending `registerTask` call arrives after `completeTask`.

### Counterexample Summary

**12 states**:

| Step | Action | Effect |
|------|--------|--------|
| 1–5 | Setup | OpObserverClearPending(n3,t1) fires while n3 secondary (termInitReady=FALSE — no queue), then n3 steps up |
| 5 | `OpObserverClearPending(n3,t1)` | t1→TaskReady at n3; termInitReady[n3]=TRUE → opObserverPending[n3]={t1} |
| 6–7 | Recovery Phase 1 + Phase 2 | t1 found as TaskReady → inMemoryTasks[n3]={t1}. opObserverPending still {t1} |
| 8–10 | DeleteOrphans, MajorityWait, CompleteInMemory | t1 completed; inMemoryTasks[n3]={} |
| 11 | `OpObserverRegisterTask(n3,t1)` | Stale registration fires — inMemoryTasks[n3]={t1} again |
| 12 | `RemovePersistentTask(n3,t1)` | diskTaskState[n3][t1]=TaskDeleted, but t1∈inMemoryTasks — **VIOLATION** |

### Fix Applied

`CompleteInMemory` now clears `opObserverPending[n][t]` to discard any pending registration for a completing task:

```tla
CompleteInMemory(n, t) ==
    ...
    /\ opObserverPending' = [opObserverPending EXCEPT ![n] = @ \ {t}]
    /\ UNCHANGED <<nodeVars, diskVars, termInitReady, recovVars, f1Vars, diskDocExists>>
```

### Affected Code

Not an implementation bug. Models the semantic constraint that the op-observer's `registerTask` call for `t` at node `n` cannot arrive after `completeTask(t)` has finalized `t`'s lifecycle (because it already joined the in-progress deletion earlier).

---

## SPB-3 — Invariant Too Strong: NoLostReadyTasks Fires in Transient Op-Observer Window

**Classification**: Case A — Invariant excludes a legitimate transient state  
**Invariant Violated**: `NoLostReadyTasks`  
**Severity**: Spec bug (false positive)

### Root Cause

`NoLostReadyTasks` required that after `RecoveryDone`, every `TaskReady`/`TaskProcessing` task on disk is either in memory, being processed, or completed. The spec models `OpObserverClearPending` (write commits, task→ready) and `OpObserverRegisterTask` (registerTask succeeds) as separate actions. TLC found a state between these two actions where the invariant fired:

- `OpObserverClearPending(n1,t2)` committed, making `diskTaskState[n1][t2]=TaskReady`
- `opObserverPending[n1]={t2}` (registration queued because `termInitReady[n1]=TRUE`)
- `OpObserverRegisterTask` had not yet fired
- Invariant required `t2 ∈ inMemoryTasks[n1]` — but it wasn't yet

The task was NOT permanently lost; `OpObserverRegisterTask(n1,t2)` was enabled and would register t2 immediately. In the real code, `registerTask` is called synchronously by the op-observer callback during the commit, so no intermediate state with `diskTaskState=TaskReady` and `t ∉ inMemoryTasks` exists.

### Counterexample Summary

**6 states** (minimal path from F2 hunt config):

| Step | Action | Key State |
|------|--------|-----------|
| 2 | `OpObserverClearPending(n1,t1)` | diskTaskState[n1][t1]=TaskReady (no queue: termInitReady=FALSE) |
| 3 | `StepUp(n1)` | n1→Primary; termInitReady[n1]=TRUE |
| 4 | RecoveryPhase1Scan | No processing tasks |
| 5 | RecoveryPhase2Scan | t1 found (TaskReady), inMemoryTasks[n1]={t1} |
| **6** | `OpObserverClearPending(n1,t2)` | diskTaskState[n1][t2]=TaskReady; opObserverPending={t2} — **VIOLATION** |

At State 6, `t2` is TaskReady at a primary with RecoveryDone, but `t2 ∉ inMemoryTasks` and `t2 ∉ opObserverPending` (after the check, `t2 ∈ opObserverPending`). The invariant fires before `registerTask` can be called.

### Fix Applied

Weakened `NoLostReadyTasks` to allow tasks in `opObserverPending`:

```tla
NoLostReadyTasks ==
    \A n \in Nodes, t \in Tasks :
        (IsPrimary(n) /\ recoveryPhase[n] = RecoveryDone /\
         diskTaskState[n][t] \in {TaskReady, TaskProcessing}) =>
            (t \in inMemoryTasks[n] \/ deletionStep[n][t] /= "idle" \/ completionFulfilled[n][t]
             \/ t \in opObserverPending[n])   \* ← added
```

This allows the legitimate transient window while still catching genuinely lost tasks (not in memory, not queued, not being processed, not completed).

---

## Bug Hunt: Family 1 — Orphan-Deletion-Before-Task-Removal Ordering

**Config**: `MC_hunt_family1.cfg` (2 nodes, 1 task, MaxStepDowns=2, MaxInterrupts=2, MaxMigrations=1)  
**Invariants checked**: `OrphanDeletionBeforeTaskDocRemoval`, `CompletionFutureImpliesMajorityOrphans`, `NoDiskDeleteBeforeMajority`  
**Result**: **No violation** — 1,932 distinct states, fully explored

### Analysis

The model fully explored all fault-injection scenarios for Family 1, including:
- Step-down mid-majority-wait (`MajorityWaitInterrupted`)
- Multiple step-up/step-down cycles
- Replication of disk state to secondaries

`OrphanDeletionBeforeTaskDocRemoval` held in all reachable states: `diskTaskState[n][t]=TaskDeleted` only appears after `orphansMajorityCommitted[t]=TRUE`.

`CompletionFutureImpliesMajorityOrphans` also held: `completionFulfilled[n][t]=TRUE` requires `deletionStep[n][t]` to have been `"waiting"` (which sets `orphansMajorityCommitted[t]=TRUE`) before `CompleteInMemory` fires.

**Interpretation**: The majority-wait ordering guarantee in `ready_range_deletions_processor.cpp:337-339` is correctly enforced. Step-down interrupts the majority wait without removing the task document (the primary resets `deletionStep` to `"idle"` and keeps the disk document for recovery), and recovery re-executes the full deletion pipeline including the majority wait. The ordering invariant holds.

**Confidence**: High. State space fully exhausted.

---

## Bug Hunt: Family 2 — Recovery Scan Completeness

**Config**: `MC_hunt_family2.cfg` (2 nodes, 2 tasks, MaxStepDowns=3, MaxInterrupts=0, MaxMigrations=2)  
**Invariants checked**: `NoLostReadyTasks`, `InMemoryImpliesDisk`  
**Result**: **No violation** — 460,818 distinct states, fully explored

### Analysis

After the invariant fix (SPB-3), the model explored all step-up/step-down cycles with op-observer and recovery interleaving. No genuinely lost task was found: every task that reaches `TaskReady` on disk at a primary with `RecoveryDone` is either in memory, in the `opObserverPending` queue, or already completed.

The key scenarios checked:
- `pending→ready` transition BEFORE step-up (task is TaskReady during recovery Phase 2 → picked up)
- `pending→ready` transition BETWEEN Phase 1 and Phase 2 (task is TaskReady when Phase 2 scans → picked up)
- `pending→ready` transition AFTER Phase 2 (task is queued via op-observer → registered by `OpObserverRegisterTask`)
- Multiple step-down cycles while tasks are in various states

**Interpretation**: The two-phase recovery scan with op-observer fallback correctly handles all pending→ready transitions. No task permanently escapes both the recovery scan and the op-observer registration. The dedup mechanism works as intended.

**Confidence**: High. State space fully exhausted.

---

## Bug Hunt: Family 3 — Non-Atomic Task Completion

**Config**: `MC_hunt_family3.cfg` (2 nodes, 1 task, MaxStepDowns=2, MaxInterrupts=0, MaxMigrations=1)  
**Invariants checked**: `CompletionFutureImpliesMajorityOrphans`, `OrphanDeletionBeforeTaskDocRemoval`, `CompletingImpliesFulfilled`  
**Result**: **No violation** — 1,838 distinct states, fully explored

### Analysis

The model checked the non-atomic window between `CompleteInMemory` (`completeTask()` fulfills the future) and `RemovePersistentTask` (`removePersistentTask()` deletes the disk document), including step-down in that window.

`CompletionFutureImpliesMajorityOrphans` held in all states: `completionFulfilled[n][t]=TRUE` requires the path `DeleteOrphans → MajorityWaitSuccess → CompleteInMemory`, which always sets `orphansMajorityCommitted[t]=TRUE` before `completionFulfilled` can become TRUE.

**Interpretation**: The non-atomic completion is safe for the primary safety invariant. The crash window between `completeTask` and `removePersistentTask` causes the disk document to survive a step-down, but recovery will re-execute the deletion (not re-fulfill the future) — callers who received the fulfilled future already have an accurate answer (orphans ARE majority committed at that point). Re-execution on the next primary repeats the majority wait for the new deletions, which is correct.

**Confidence**: High. State space fully exhausted.

---

## Spec Changes Summary

All changes are in `base.tla`. No changes to `MC.tla` or any config files.

### Change 1: `StepUp` — add mutual exclusion guard

```diff
  StepUp(n) ==
      /\ IsSecondary(n)
      /\ term[n] < MaxTerm
+     /\ \A m \in Nodes : ~IsPrimary(m)
      /\ LET newTerm == term[n] + 1 IN
```

### Change 2: `CompleteInMemory` — clear opObserverPending for completing task

```diff
  CompleteInMemory(n, t) ==
      ...
+     /\ opObserverPending' = [opObserverPending EXCEPT ![n] = @ \ {t}]
-     /\ UNCHANGED <<nodeVars, diskVars, termInitReady, recovVars, f1Vars, diskDocExists, obsVars>>
+     /\ UNCHANGED <<nodeVars, diskVars, termInitReady, recovVars, f1Vars, diskDocExists>>
```

### Change 3: `NoLostReadyTasks` — allow tasks in opObserverPending

```diff
  NoLostReadyTasks ==
      \A n \in Nodes, t \in Tasks :
          (IsPrimary(n) /\ recoveryPhase[n] = RecoveryDone /\
           diskTaskState[n][t] \in {TaskReady, TaskProcessing}) =>
              (t \in inMemoryTasks[n] \/ deletionStep[n][t] /= "idle" \/ completionFulfilled[n][t]
+              \/ t \in opObserverPending[n])
```

---

## Model Checking Run Summary

| Run | Config | States | Violations | Notes |
|-----|--------|--------|------------|-------|
| MC_base.out | MC.cfg | 514 | `ElectionSafety` | SPB-1 found, fixed |
| MC_base_r2.out | MC.cfg | 27,643 | `InMemoryImpliesDisk` | SPB-2 found, fixed |
| MC_base_r3.out | MC.cfg | 10,432,251 | Deadlock (model artifact) | Terminal state with exhausted fault budget — disabled deadlock detection with `-deadlock` |
| MC_base_r4.out | MC.cfg | 18,663,813 | None | Full clean base check |
| MC_hunt_f1.out | MC_hunt_family1.cfg | 1,932 | None | F1 family clean |
| MC_hunt_f2.out | MC_hunt_family2.cfg | 328 | `NoLostReadyTasks` | SPB-3 found, fixed |
| MC_hunt_f2_r2.out | MC_hunt_family2.cfg | 460,818 | None | F2 family clean after fix |
| MC_hunt_f3.out | MC_hunt_family3.cfg | 1,838 | None | F3 family clean |
| MC_base_final2.out | MC.cfg | 18,656,336 | None | Final clean base check |

---

## Phase 4: Bug Confirmation

**Date**: 2026-06-08  
**Outcome**: No implementation bugs confirmed. All model checking findings were spec-level issues.

### Summary

The model checking run produced no implementation bug candidates. All three findings (SPB-1, SPB-2, SPB-3) were identified and classified as spec modeling errors during the model checking phase itself, and all three bug-family hunting runs returned clean. Per the confirmation guide: no bugs found → brief confirmation note.

### Code Audit — Spec Bug Assessments Verified

**SPB-1 — Simultaneous primaries (spec over-models elections)**

- **Code location**: `range_deleter_service.cpp:138` (`onStepUpComplete`), Raft election subsystem
- **Audit finding**: MongoDB elections require a quorum vote (`ReplicationCoordinator`). The `StepUp` action in the spec modeled a free solo action — unconstrained by the quorum requirement. In the real system, two nodes cannot both win primary for the same term because each node can vote only once per term, and two separate majorities for the same term are impossible (pigeonhole). The spec guard `\A m \in Nodes : ~IsPrimary(m)` correctly tightens the model to match this implementation invariant.
- **Developer intent**: MongoDB's Raft-based replication is documented to guarantee at most one primary per term. No developer commentary is needed — this is a foundational protocol property.
- **Classification**: **FALSE POSITIVE** (spec modeling issue; no implementation bug)

**SPB-2 — Stale op-observer registration after task completion (spec over-models op-observer delay)**

- **Code location**: `range_deleter_service_op_observer.cpp:75–143` (`registerTaskWithOngoingQueriesOnOpLogEntryCommit`), `ready_range_deletions_processor.cpp:362` (`completeTask` call site)
- **Audit finding**: `registerTask` is called synchronously inside the `onCommit` callback registered by the op-observer (op_observer.cpp line 109: `(void)RangeDeleterService::get(opCtx)->registerTask(...)`). This callback fires when the pending→ready write commits, which is always before the task enters the deletion pipeline. `completeTask` (range_deleter_service.cpp:513–521) is only reachable from the deletion pipeline, which begins only after `registerTask` has placed the task in memory. The scenario SPB-2 describes — a `registerTask` call arriving after `completeTask` — is structurally impossible: the two calls are in strict linear order, not independent asynchronous events.
- **Developer intent**: The op-observer callback is the sole mechanism that transitions a task from pending→ready on both the primary and secondaries; no parallel delayed-registration path exists in the code.
- **Classification**: **FALSE POSITIVE** (spec over-models op-observer delay; no implementation bug)

**SPB-3 — NoLostReadyTasks fires in transient window (invariant too strong)**

- **Code location**: `range_deleter_service_op_observer.cpp:75–144` (single `onCommit` closure)
- **Audit finding**: The `onCommit` callback is a single closure: it atomically (from the caller's perspective) runs the pending→ready disk commit AND calls `registerTask`. In the spec, `OpObserverClearPending` and `OpObserverRegisterTask` were modeled as two separate enabled actions, allowing TLC to fire `ClearPending` without yet firing `RegisterTask`. In the implementation, these are one indivisible callback — once the commit fires, `registerTask` is called immediately within the same stack frame before any other thread can observe the new `diskTaskState=TaskReady`. The transient window the invariant checked for does not exist in the real code.
- **Developer intent**: The single-callback design is intentional; registering the task synchronously in the commit callback avoids exactly the kind of lost-task window the invariant was checking for.
- **Classification**: **FALSE POSITIVE** (invariant too strong relative to implementation atomicity; no implementation bug)

### Bug-Family Hunting Results

All three family hunt configurations exhausted their full state spaces with no violations after the spec fixes:

| Family | Invariants | States Explored | Result |
|--------|-----------|----------------|--------|
| F1 — Orphan ordering | `OrphanDeletionBeforeTaskDocRemoval`, `CompletionFutureImpliesMajorityOrphans` | 1,932 | Clean |
| F2 — Recovery completeness | `NoLostReadyTasks`, `InMemoryImpliesDisk` | 460,818 | Clean |
| F3 — Non-atomic completion | `CompletionFutureImpliesMajorityOrphans`, `CompletingImpliesFulfilled` | 1,838 | Clean |

The majority-wait ordering in `ready_range_deletions_processor.cpp:337–353` is correctly enforced; the recovery two-phase scan correctly catches all tasks in all interleaving scenarios; the non-atomic completion window is safe because the caller already received a correct answer (orphans are majority-committed) before `removePersistentTask` is called.

### Final Classification

**No implementation bugs found.** The MongoDB range-deletion-on-secondaries protocol is correctly implemented with respect to the modeled properties. The three spec issues found were modeling artifacts, not reflections of defects in the source code.
