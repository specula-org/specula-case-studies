# Bug Report — LLVM libomp (Barrier + Tasking)

## Summary

- Bug families tested: 6 (parity, steal, detach, cancel+parity, shutdown-race, nested-serial) + 4 cross-family
- **Bugs found: 1** (steal-after-finish race, HIGH severity)
- Configs run: 14 BFS configs + 2 simulation runs
- Spec convergence: 2 rounds (Round 1 baseline, Round 2 deep hunting with extended spec)

## Bug: Steal-After-Finish Race (Direction 2)

**Severity**: HIGH — data race / use-after-free risk
**Config**: MC_hunt_shutdown_race.cfg (13-state BFS counterexample, <1s)
**Invariant**: `ActiveTasksImplyActiveTeam` violated
**Related**: D28377, GitHub Issues #156741, #176451

### Description

After all threads decrement `tt_unfinished_threads` to 0, the primary deactivates the task team (`tt_active = FALSE`). However, a thread that already marked `thread_finished = TRUE` can still steal a task from another thread's deque (re-incrementing `tt_unfinished_threads`). The stolen task then executes in a **deactivated task team**.

### Counterexample Trace

| State | Action | Key State |
|-------|--------|-----------|
| 1-9 | Barrier setup, all threads enter barrier_tasks | Normal barrier |
| 10 | Thread 2 schedules T1 (queued, slot 0) | Task in queue |
| 11 | Thread 2 marks finished via ThreadFinishTasksWeak | **unfinished→0, T1 still queued** |
| 12 | PrimaryTaskTeamWait: unfinished=0 → deactivates task team | **tt_active = FALSE** |
| 13 | Thread 1 steals T1 from "finished" state | **T1 EXECUTING in deactivated task team** |

### Root Cause (Code Analysis)

1. **No `tt_active` check in steal loop**: `__kmp_execute_tasks_template` (kmp_tasking.cpp:3296-3417) checks `th_task_team == NULL` but not `tt_active`. A finished thread with non-null `th_task_team` continues stealing.

2. **Worker `th_task_team` not cleared**: Only the primary clears `th_task_team = NULL` (kmp_tasking.cpp:4155). Workers retain their task team pointer through barrier sync, so the NULL check doesn't protect them.

3. **`KMP_MB()` is a no-op on x86_64**: The memory barrier at kmp_tasking.cpp:4148 (after setting `tt_active = FALSE`) is `#define KMP_MB() /* Nothing */` on x86 (kmp_os.h:1066). This means the deactivation may not be visible to other cores in time.

4. **Race window**: Between the last thread's `tt_unfinished_threads` decrement (→0) and a steal that re-increments it, the primary can observe unfinished=0 and deactivate the task team.

### Proxy Task OOO Trigger Path

The race is concretely triggerable through the detachable task / proxy OOO completion path:

1. Thread 0 creates a detachable task. The task body returns without fulfilling the event → becomes a proxy task (`td_flags.proxy = TASK_PROXY`).
2. An external (non-team) thread calls `omp_fulfill_event` → `__kmp_fulfill_event` → `__kmpc_proxy_task_completed_ooo`.
3. `__kmpc_proxy_task_completed_ooo` (kmp_tasking.cpp:4458-4479):
   - Calls `__kmpc_give_task(ptask)` → **enqueues** proxy bottom-half to a worker's deque
   - Then calls `__kmp_second_top_half_finish_proxy` → **decrements** `td_incomplete_child_tasks` (ICC) to 0
4. All team threads are in `execute_tasks_template` with `final_spin=TRUE`. Their inner steal loops find no tasks (proxy was enqueued AFTER the loop checked that deque). The 500μs window between "no tasks found" and the ICC check allows the OOO path to complete.
5. All threads check ICC=0, set `thread_finished=TRUE`, decrement `tt_unfinished_threads`.
6. Primary sees `unfinished_threads==0`, exits `flag.wait`, deactivates task team (`tt_active=FALSE`).
7. **Proxy task is orphaned in a worker's deque** in the deactivated task team.

### Reproduction

**Status**: REPRODUCED — 5/5 runs, 100% trigger rate

**Reproducer**: `repro/steal_after_finish.c`
**Delay patch**: `repro/patches/steal-after-finish-delay.patch`
**Build**: libomp with `-DLIBOMP_REPRO_DELAY` (delays only, no logic alteration)

Three delay injection points (all guarded by `#ifdef LIBOMP_REPRO_DELAY`):

1. **Worker inner-loop delay** (kmp_tasking.cpp, `execute_tasks_template` inner loop):
   Workers that already marked `thread_finished=TRUE` sleep 10ms before each deque access.
   Purpose: Prevents workers from stealing the proxy before primary deactivates.

2. **OOO window delay** (kmp_tasking.cpp, between inner loop break and ICC check):
   All threads sleep 500μs after the inner loop finds no tasks.
   Purpose: Widens the window for the OOO path to enqueue proxy and decrement ICC.

3. **Safety property detector** (kmp_tasking.cpp, `__kmp_task_team_wait` after deactivation):
   Iterates all deques after `tt_active=FALSE`; aborts if any deque has `ntasks > 0`.

**Reproducer design**:
- 4 threads; each creates a dummy task to pre-allocate worker deques
- **No explicit `#pragma omp barrier`** between dummy tasks and the detachable task — an explicit barrier toggles `th_task_state`, causing the implicit barrier to use a different task team whose worker deques are NOT allocated. Without the barrier, all tasks use the same task team, so `__kmpc_give_task` can enqueue the proxy to a worker's deque (not thread 0's own deque).
- Thread 0 creates a detachable task; task body stores event handle and returns (→ proxy)
- External pthread waits 1ms then calls `omp_fulfill_event` → OOO path
- Signal handlers catch SIGSEGV/SIGBUS/SIGABRT for crash detection

**Output**:
```
*** BUG REPRODUCED: orphaned task after deactivation ***
  deque[1] has 1 task(s) in deactivated task team 0x...
  This is the steal-after-finish race.
```

### Impact

**1. Proxy bottom-half never executes (resource leak)**

The orphaned proxy task's `__kmp_bottom_half_finish_proxy` is never called. This skips `__kmp_release_deps` (dependency release) and `__kmp_free_task_and_ancestors` (task + ancestor chain deallocation). Each trigger leaks a `kmp_taskdata_t` and its dependency chain. Programs that repeatedly enter parallel regions accumulate leaked task objects.

**2. Use-after-free on task team reuse**

Task teams are reused across parallel regions. When the same task team is reactivated, `__kmp_realloc_task_threads_data` reinitializes `td_thr` pointers but does **not** reset `td_deque_ntasks`, `td_deque_head`, or `td_deque_tail`. A worker entering the new region's `execute_tasks_template` sees `td_deque_ntasks > 0` (stale from the orphaned proxy), dequeues a `kmp_taskdata_t *` that may point to freed/recycled memory, and dereferences it — **use-after-free**.

**3. Barrier counter corruption**

If a thread eventually steals and executes the orphaned proxy's bottom-half, `__kmp_free_task_and_ancestors` decrements `td_allocated_child_tasks` on the proxy's parent (the implicit task). But by then the implicit task belongs to a **new** parallel region with its own counter semantics. The stale decrement can cause the counter to underflow, leading to a subsequent barrier's `tt_unfinished_threads` reaching 0 prematurely (threads released before all tasks complete) or going negative (barrier deadlock).

## Spec Convergence Notes

### Round 1 (Baseline)

Two spec modeling issues (Case B) fixed:

1. **PrimaryCancelledBarrier**: Added `barrier_task_wait` to accepted pc states — primary can reach task_wait then detect cancel at release check.

2. **WorkerReceiveRelease**: Added `~cancelled` guard — workers detect cancellation in release spin loop.

One invariant weakening (Case A):

3. **ParityConsistency**: Weakened to exclude release/sync phases — threads toggle slot one-by-one, transient disagreement expected.

### Round 2 (Deep Hunting)

Spec extended with:
- `ThreadFinishTasksWeak`: weak finish that doesn't require globally empty queues (faithful to real code)
- `StealTask` guard extended to allow stealing from "finished" state
- `SerializedParallelEntry/Exit`: models nested serial parallel save/restore
- `inSerial[t]`, `savedSlot[t]`: serial parallel state tracking
- `~inSerial[t]` guards on barrier progression actions (6 Case B fixes for serial model)

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 1: Task Team Parity | MC_hunt_parity.cfg | 3,117 BFS | No violation |
| Family 2: Steal During Transitions | MC_hunt_steal.cfg | 352 BFS | No violation (see note 1) |
| Family 3: Detachable Task Completion | MC_hunt_detach.cfg | 8,517 BFS | No violation |
| Family 5: Cancel + Parity | MC_hunt_cancel_parity.cfg | 5,628 BFS | No violation |
| Cross-family: All invariants | MC_hunt_combined.cfg | 220,450 BFS | No violation |
| Cross-family: Cancel + Task | MC_hunt_cancel_task.cfg | 123,796 BFS | No violation |
| Family 6: Nested Serial Parallel | MC_hunt_nested_serial.cfg | 39,168 BFS | No violation |
| Family 6 x 3: Serial + Detach | MC_hunt_serial_detach.cfg | 70,627 BFS | No violation |
| Family 6 x 5: Serial + Cancel | MC_hunt_serial_cancel.cfg | 10,501 BFS | No violation |
| Cross-family: Serial + All | MC_hunt_serial_combined.cfg | 519,474 BFS | No violation |
| Deep simulation (Round 1) | MC.cfg | 194M states, 3.4M traces (10 min) | No violation |
| Deep simulation (Round 2) | MC_hunt_serial_combined.cfg | 2.66B states, 30M traces (35 min) | No violation |

### Notes

1. **Family 2 (Steal from reaped thread)**: The `StealFromReapedThread` action is never enabled because the spec correctly sequences barrier phases. Reproducing D28377 would require modeling `__kmp_fork_barrier`/`__kmp_join_barrier` separately.

2. **Family 6 (Nested serial parallel)**: The save/restore mechanism for `th_task_state` is correct at the state machine level. The open issues (#50602, #59190, #81488) are memory management bugs (use-after-free on serial team's task team) that operate below the TLA+ model's abstraction level.

3. **LLVM #53081** (`__kmp_remove_my_task` hang): Hidden helper tasks, not modeled.

4. **LLVM #80664** (passive wait policy deadlock): Hyper barrier algorithm, not modeled.

## Analysis

The libomp barrier + tasking specification covers 6 bug families across 14 BFS configs and 2 simulation runs:

**Confirmed bug (1, REPRODUCED)**:
- **Steal-after-finish race**: The `__kmpc_proxy_task_completed_ooo` enqueue-before-decrement ordering creates a window where a proxy task sits in a worker's deque while ICC=0. All threads mark finished without picking up the proxy, and the primary deactivates the task team with the task still queued. Reproduced 5/5 runs (100%) via external pthread fulfilling a detachable task through the OOO path, with timing delays to widen the race window. See `repro/steal_after_finish.c`.

**Verified safe (5)**:
- **Slot parity**: Correctly maintained through `__kmp_task_team_sync` toggle
- **Detachable task protocol**: Ownership exclusivity via `proxy` flag is correct
- **Cancellation + parity**: Cancel correctly skips task_team_sync, preserving slot consistency
- **Serial parallel parity**: Save/reset/restore of `th_task_state` is logically correct
- **Unfinished counter**: Double-decrement properly prevented by `thread_finished` flag
