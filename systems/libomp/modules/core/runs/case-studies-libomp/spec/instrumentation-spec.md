# Instrumentation Spec: LLVM libomp Barrier + Tasking

Maps TLA+ spec actions to source code locations for trace harness generation.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "tid": <thread_id>,
  "ts": <monotonic_timestamp_ns>,
  "state": {
    "pc": "<program_counter_state>",
    "taskTeamSlot": <0|1>,
    "threadFinished": <true|false>,
    "barrierRound": <round_number>,
    "cancelled": <true|false>
  },
  ... action-specific fields ...
}
```

### State Fields (captured at every event)

| Implementation Field | TLA+ Variable | Accessor |
|---------------------|---------------|----------|
| `th_task_state` (kmp.h:3037) | `taskTeamSlot[tid]` | `thread->th.th_task_state` |
| `thread_finished` local var (kmp_tasking.cpp:3331) | `threadFinished[tid]` | Local `thread_finished` boolean in `__kmp_execute_tasks_template` |
| barrier phase (derived from PC location) | `pc[tid]` | Inferred from instrumentation point |
| barrier round (team counter) | `barrierRound` | Internal counter maintained by harness |
| `t_cancel_request` (kmp.h:3219) | `cancelled` | `team->t.t_cancel_request != cancel_noreq` |

### Task Fields (for task-related events)

| Implementation Field | TLA+ Variable | Accessor |
|---------------------|---------------|----------|
| task pointer | `task` (mapped to Task ID) | Pointer-to-ID mapping in harness |
| `td_flags.detachable` (kmp.h:2732) | `taskDetachable[task]` | `taskdata->td_flags.detachable` |
| `td_flags.proxy` (kmp.h:2728) | (phase inference) | `taskdata->td_flags.proxy` |
| `td_incomplete_child_tasks` (kmp.h:2786) | `childCount[task]` | `KMP_ATOMIC_LD_ACQ(&taskdata->td_incomplete_child_tasks)` |
| `td_parent` (kmp.h:2773) | `taskParent[task]` | `taskdata->td_parent` (mapped to Task ID) |
| `td_allow_completion_event.type` (kmp.h:2805) | `eventFulfilled[task]` | `taskdata->td_allow_completion_event.type` |
| `tt_unfinished_threads` (kmp.h:2881) | `unfinished[slot]` | `KMP_ATOMIC_LD_ACQ(&task_team->tt.tt_unfinished_threads)` |

## Section 2: Action-to-Code Mapping

### 1. PrimaryEnterBarrier

- **Code location**: `kmp_barrier.cpp:1873-1913` (`__kmp_barrier_template`, pre-gather + `__kmp_task_team_setup` call)
- **Trigger point**: After `__kmp_task_team_setup()` call at line 1912, before gather dispatch at line 1915
- **Trace event name**: `"PrimaryEnterBarrier"`
- **Fields**: `tid=0`, state fields, `barrierRound`
- **Notes**: Only the primary thread (tid=0) emits this. The `__kmp_task_team_setup` initializes the other slot's `tt_unfinished_threads`.

### 2. WorkerEnterBarrier

- **Code location**: `kmp_barrier.cpp:1915-1945` (gather phase entry, worker side)
- **Trigger point**: At worker's gather entry, after `b_arrived` bump
- **Trace event name**: `"WorkerEnterBarrier"`
- **Fields**: `tid`, state fields
- **Notes**: Workers bump their `b_arrived` flag and then wait. Emit event after the arrival flag is set.

### 3. WorkerStartTasks

- **Code location**: `kmp_tasking.cpp:3152` (`__kmp_execute_tasks_template` entry)
- **Trigger point**: At the start of the task execution loop, when the thread begins looking for tasks during barrier wait
- **Trace event name**: `"WorkerStartTasks"`
- **Fields**: `tid`, state fields
- **Notes**: This event marks the transition from waiting in gather to actively executing tasks.

### 4. PrimaryStartTaskWait

- **Code location**: `kmp_barrier.cpp:1949-1953` (primary enters task execution phase after all gathered)
- **Trigger point**: After primary detects all workers arrived, before entering task execution loop
- **Trace event name**: `"PrimaryStartTaskWait"`
- **Fields**: `tid=0`, state fields
- **Notes**: Primary thread only. Guard: `!cancelled`.

### 5. ScheduleTask

- **Code location**: `kmp_tasking.cpp:1563` (`__kmpc_omp_task`) → `kmp_tasking.cpp:1501` (`__kmp_push_task`)
- **Trigger point**: After `__kmp_push_task` succeeds (task is in deque)
- **Trace event name**: `"ScheduleTask"`
- **Fields**: `tid`, `task` (pointer→ID), `taskDetachable=false`, `parentTask` (pointer→ID or null)
- **Notes**: `td_incomplete_child_tasks` of parent is incremented at `kmp_tasking.cpp:1390-1395` (before push). Capture after push.

### 6. ScheduleDetachTask

- **Code location**: `kmp_tasking.cpp:1563` (`__kmpc_omp_task`) with `td_flags.detachable == TASK_DETACHABLE`
- **Trigger point**: Same as ScheduleTask, but when `td_flags.detachable` is set
- **Trace event name**: `"ScheduleDetachTask"`
- **Fields**: `tid`, `task`, `taskDetachable=true`, `parentTask`
- **Notes**: Distinguish from ScheduleTask by checking `td_flags.detachable` at trace emission time.

### 7. ExecuteTask

- **Code location**: `kmp_tasking.cpp:3158-3175` (task pickup from own deque in `__kmp_execute_tasks_template`)
- **Trigger point**: After `__kmp_remove_my_task` or dequeue succeeds, before task body invocation
- **Trace event name**: `"ExecuteTask"`
- **Fields**: `tid`, `task` (pointer→ID)
- **Notes**: Also covers stolen tasks that are about to execute. The key distinction is task pickup vs. steal — for steal, emit StealTask instead.

### 8. StealTask

- **Code location**: `kmp_tasking.cpp:3011-3130` (`__kmp_steal_task`)
- **Trigger point**: After successful steal (line 3098: deque pop succeeds), before `__kmp_release_bootstrap_lock`
- **Trace event name**: `"StealTask"`
- **Fields**: `tid` (thief), `victim` (victim thread ID), `task` (pointer→ID)
- **Notes**: Must capture the re-increment of `tt_unfinished_threads` if `thread_finished` was true (lines 3113-3126). Emit **after** the re-increment and lock release to capture consistent state.

### 9. CompleteTask

- **Code location**: `kmp_tasking.cpp:924-970` (`__kmp_task_finish`, normal completion path)
- **Trigger point**: After `td_flags.complete = 1` (line 925) and `td_incomplete_child_tasks` decrement (line 943)
- **Trace event name**: `"CompleteTask"`
- **Fields**: `tid`, `task`, `childCount` of parent after decrement
- **Notes**: Only emitted on the `completed == true` path (not the detach path). Guard: `!taskDetachable || eventFulfilled`.

### 10. DetachTask

- **Code location**: `kmp_tasking.cpp:878-906` (`__kmp_task_finish`, detach path)
- **Trigger point**: After `td_flags.proxy = TASK_PROXY` (line 901), inside the lock
- **Trace event name**: `"DetachTask"`
- **Fields**: `tid`, `task`
- **Notes**: WARNING: After setting proxy, "no access to taskdata after this point" (line 898-899). Emit inside the lock before releasing it. The event must capture state before the ownership transfer completes.

### 11. FulfillEvent

- **Code location**: `kmp_tasking.cpp:4378-4423` (`__kmp_fulfill_event`)
- **Trigger point**: After detecting `proxy == TASK_PROXY` (line 4386) and setting `event->type = KMP_EVENT_UNINITIALIZED` (line 4399), inside the lock
- **Trace event name**: `"FulfillEvent"`
- **Fields**: `task` (from `event->ed.task`), fulfiller `tid` (may be -2 for non-OpenMP thread)
- **Notes**: The fulfiller may be a non-OpenMP thread (`gtid = -2`). Map to a special thread ID or use the `__kmp_get_global_thread_id()` value.

### 12. EarlyFulfillEvent

- **Code location**: `kmp_tasking.cpp:4385-4400` (`__kmp_fulfill_event`, `proxy != TASK_PROXY` path)
- **Trigger point**: When `proxy != TASK_PROXY` inside the lock (line 4392)
- **Trace event name**: `"EarlyFulfillEvent"`
- **Fields**: `task`, fulfiller `tid`
- **Notes**: The task body is still running. The event type is set to `KMP_EVENT_UNINITIALIZED`, causing `__kmp_task_finish` to take the normal completion path later.

### 13. ProxyTaskComplete

- **Code location**: `kmp_tasking.cpp:4254-4270` (`__kmp_bottom_half_finish_proxy`)
- **Trigger point**: After the PROXY_TASK_FLAG spin-wait completes (line 4266) and before `__kmp_free_task_and_ancestors` (line 4269)
- **Trace event name**: `"ProxyTaskComplete"`
- **Fields**: `task`
- **Notes**: This runs on a team thread. The task is freed after this event.

### 14. ThreadFinishTasks

- **Code location**: `kmp_tasking.cpp:3318-3332` (in `__kmp_execute_tasks_template`)
- **Trigger point**: After `KMP_ATOMIC_DEC(unfinished_threads)` (line 3327) and `thread_finished = TRUE` (line 3331)
- **Trace event name**: `"ThreadFinishTasks"`
- **Fields**: `tid`, `unfinished` (value after decrement), `taskTeamSlot`
- **Notes**: WARNING: After this decrement, "it is now unsafe to reference thread->th.th_team" (line 3334-3338). Capture state before the team becomes inaccessible.

### 15. PrimaryTaskTeamWait

- **Code location**: `kmp_tasking.cpp:4046-4083` (`__kmp_task_team_wait`)
- **Trigger point**: After `tt_unfinished_threads == 0` wait completes (line 4066), after `tt_active = FALSE` (line 4078)
- **Trace event name**: `"PrimaryTaskTeamWait"`
- **Fields**: `tid=0`, slot that was deactivated
- **Notes**: Primary thread only. The task team is deactivated at this point.

### 16. PrimaryRelease

- **Code location**: `kmp_barrier.cpp:2028-2066` (release phase entry)
- **Trigger point**: Before barrier release dispatch (line 2033)
- **Trace event name**: `"PrimaryRelease"`
- **Fields**: `tid=0`
- **Notes**: Guard: `!cancelled`. Primary releases workers via `b_go` flags.

### 17. WorkerReceiveRelease

- **Code location**: `kmp_barrier.cpp:2033-2061` (worker side of release)
- **Trigger point**: After worker's `b_go` flag matches expected value (release received)
- **Trace event name**: `"WorkerReceiveRelease"`
- **Fields**: `tid`
- **Notes**: Worker resets `b_go` to `KMP_INIT_BARRIER_STATE` after receiving release.

### 18. TaskTeamSync

- **Code location**: `kmp_tasking.cpp:4020-4038` (`__kmp_task_team_sync`)
- **Trigger point**: After `th_task_state = 1 - th_task_state` (line 4027) and task team pointer update (line 4031)
- **Trace event name**: `"TaskTeamSync"`
- **Fields**: `tid`, `taskTeamSlot` (new value after toggle)
- **Notes**: All threads emit this. The slot value in the event should be the **new** value (post-toggle).

### 19. BarrierDone

- **Code location**: `kmp_barrier.cpp:2066-2126` (barrier exit)
- **Trigger point**: At barrier function return
- **Trace event name**: `"BarrierDone"`
- **Fields**: `tid`

### 20. StartNextRound

- **Code location**: Synthetic event emitted by harness when all threads have completed a barrier round
- **Trigger point**: After all threads return from barrier, before next barrier call
- **Trace event name**: `"StartNextRound"`
- **Fields**: `barrierRound` (new round number)
- **Notes**: This is a harness-level event, not a single code location. The harness must synchronize thread completion detection.

### 21. CancelBarrier

- **Code location**: `kmp_barrier.cpp:2138-2157` (`__kmp_barrier_gomp_cancel`)
- **Trigger point**: When `cancel parallel` is invoked, setting `t_cancel_request`
- **Trace event name**: `"CancelBarrier"`
- **Fields**: (none beyond envelope)

### 22. PrimaryCancelledBarrier

- **Code location**: `kmp_barrier.cpp:1951, 2028, 2063` (cancelled path skips wait/release/sync)
- **Trigger point**: When primary detects cancellation and takes the cancelled path
- **Trace event name**: `"PrimaryCancelledBarrier"`
- **Fields**: `tid=0`
- **Notes**: Primary skips `__kmp_task_team_wait`, release, and `__kmp_task_team_sync`.

### 23. WorkerCancelledBarrier

- **Code location**: `kmp_barrier.cpp:2149-2150` (worker reverts `b_arrived`)
- **Trigger point**: When worker detects cancellation during barrier wait
- **Trace event name**: `"WorkerCancelledBarrier"`
- **Fields**: `tid`

## Section 3: Special Considerations

### 3.1 Task ID Mapping

The implementation uses `kmp_taskdata_t *` pointers to identify tasks. The harness must maintain a pointer-to-sequential-ID mapping (e.g., `T1`, `T2`, ...) that persists across the trace. Task IDs are reused after `__kmp_free_task_and_ancestors` frees a task — the harness should track allocation/deallocation to correctly map reused pointers.

### 3.2 Thread Identification

libomp uses `gtid` (global thread ID) internally. The primary thread is always `gtid = 0`. Workers are `gtid = 1, 2, ...`. For `__kmp_fulfill_event` called from non-OpenMP threads, `gtid = -2` — map this to a special value or the closest team thread.

### 3.3 Concurrent Event Ordering

Multiple threads emit events concurrently. The harness must use a monotonic timestamp (`clock_gettime(CLOCK_MONOTONIC)`) and sort events by timestamp. For events with identical timestamps, use `(timestamp, tid)` as the sort key.

### 3.4 Silent Actions in Trace

The trace spec includes silent actions for:
- `SilentExecuteTask` — task pickup not always instrumented (impl may batch dequeue+execute)
- `SilentCompleteTask` — implicit task completion at barrier entry
- `SilentThreadFinishTasks` — thread may finish tasks without explicit instrumentation point
- `SilentProxyTaskComplete` — bottom-half may run between other events

If the trace validation hits deadlocks, first check whether these silent actions need to fire by examining the expected next event and current spec state.

### 3.5 `tt_unfinished_threads` Access Window

After a thread decrements `tt_unfinished_threads` (ThreadFinishTasks event), it must NOT access `thread->th.th_team` (kmp_tasking.cpp:3334-3338). The harness must capture all team-related state **before** the decrement. The `unfinished` field in the event should reflect the post-decrement value (read the atomic after decrementing).

### 3.6 Detach Event Lock Timing

Both `DetachTask` and `FulfillEvent`/`EarlyFulfillEvent` occur inside `event->lock`. The harness must emit the trace event **inside** the lock to capture the correct interleaving. Emitting outside the lock could produce inconsistent traces where both events appear to happen "simultaneously."

### 3.7 Build Configuration

```bash
cmake -DCMAKE_BUILD_TYPE=Debug \
      -DLIBOMP_ENABLE_ASSERTIONS=ON \
      -DLIBOMP_TRACE=ON \        # custom flag for trace harness
      llvm-project/openmp
```

The harness should be gated behind a `LIBOMP_TRACE` compile flag and an `OMP_TRACE_FILE` environment variable (similar to libgomp's `GRANDPA_TRACE_FILE` pattern). When `OMP_TRACE_FILE` is unset, no tracing overhead is incurred.
