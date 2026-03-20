# libomp Trace Instrumentation Guide

## Overview

This harness instruments LLVM's libomp (OpenMP runtime) to emit NDJSON traces for TLA+ trace validation. The instrumentation covers barrier synchronization, task scheduling/execution/stealing, detachable tasks, and cancellation.

## Quick Start

```bash
cd case-studies/libomp
bash harness/run.sh          # Apply patch, build, run tests, collect traces
```

Traces land in `traces/`. Validate with:

```bash
JSON=traces/test_basic_barrier.ndjson \
  java -cp ../../lib/tla2tools.jar:../../lib/CommunityModules-deps.jar \
  tlc2.TLC spec/Trace -config spec/Trace.cfg -deadlock -workers auto -cleanup
```

Use `Trace_steal.cfg` for `test_task_steal.ndjson` (8 tasks instead of 2).

## File Layout

```
harness/
  apply.sh                    # Patches the artifact
  run.sh                      # Full pipeline: apply, build, test, collect
  src/
    omp_trace.h               # Trace emission API (header-only + stubs)
    omp_trace.cpp              # Global state definition
    preprocess_trace.py        # Sort, filter, reorder trace events
    test_basic_barrier.c       # 3 threads, 2 tasks, 1 barrier round
    test_task_steal.c          # 3 threads, 8 tasks, stealing
    test_detach_task.c         # Detachable task with omp_fulfill_event
    test_cancel_barrier.c      # Barrier cancellation
  patches/
    instrumentation.patch      # Patch against llvm-project/openmp/runtime/src/
```

## Instrumentation Points

The patch modifies three files in `openmp/runtime/src/`:

### kmp_barrier.cpp — Barrier Lifecycle

| Location | Event | TLA+ Action |
|----------|-------|-------------|
| `__kmp_barrier_template` entry (primary) | `PrimaryEnterBarrier` | `TracePrimaryEnterBarrier` |
| `__kmp_barrier_template` entry (worker) | `WorkerEnterBarrier` | `TraceWorkerEnterBarrier` |
| `__kmp_execute_tasks` call in release wait | `WorkerStartTasks` | `TraceWorkerStartTasks` |
| `__kmp_task_team_wait` entry | `PrimaryStartTaskWait` | `TracePrimaryStartTaskWait` |
| `__kmp_task_team_wait` after unfinished==0 | `PrimaryTaskTeamWait` | `TracePrimaryTaskTeamWait` |
| Release phase (primary) | `PrimaryRelease` | `TracePrimaryRelease` |
| Release phase (worker wakeup) | `WorkerReceiveRelease` | `TraceWorkerReceiveRelease` |
| `__kmp_task_team_sync` | `TaskTeamSync` | `TraceTaskTeamSync` |
| Barrier completion | `BarrierDone` | `TraceBarrierDone` |
| Cancellation set | `CancelBarrier` | `TraceCancelBarrier` |
| Primary cancelled path | `PrimaryCancelledBarrier` | `TracePrimaryCancelledBarrier` |
| Worker cancelled path | `WorkerCancelledBarrier` | `TraceWorkerCancelledBarrier` |

### kmp_tasking.cpp — Task Lifecycle

| Location | Event | TLA+ Action |
|----------|-------|-------------|
| `__kmp_push_task` (after enqueue) | `ScheduleTask` | `TraceScheduleTask` |
| `__kmp_push_task` (detachable) | `ScheduleDetachTask` | `TraceScheduleDetachTask` |
| `__kmp_execute_tasks_template` (dequeue) | `ExecuteTask` | `TraceExecuteTask` |
| `__kmp_steal_task` (after steal) | `StealTask` | `TraceStealTask` |
| `__kmp_task_finish` (normal complete) | `CompleteTask` | `TraceCompleteTask` |
| `__kmp_task_finish` (detach) | `DetachTask` | `TraceDetachTask` |
| `__kmp_fulfill_event` (post-detach) | `FulfillEvent` | `TraceFulfillEvent` |
| `__kmp_fulfill_event` (early) | `EarlyFulfillEvent` | `TraceEarlyFulfillEvent` |
| Bottom-half proxy completion | `ProxyTaskComplete` | `TraceProxyTaskComplete` |
| `__kmp_execute_tasks_template` (finish) | `ThreadFinishTasks` | `TraceThreadFinishTasks` |

## Trace Event Format

All events are NDJSON with `tag: "trace"` and a monotonic `ts` (nanoseconds):

```json
{"tag":"trace","ts":12345,"event":"ScheduleTask","tid":0,"task":"T1","taskDetachable":false,"parentTask":null}
{"tag":"trace","ts":12346,"event":"WorkerEnterBarrier","tid":1,"state":{"pc":"barrier_gather","taskTeamSlot":1,"threadFinished":false,"barrierRound":0,"cancelled":false}}
{"tag":"trace","ts":12347,"event":"StealTask","tid":2,"victim":0,"task":"T1"}
```

Task IDs are sequential strings `T1`, `T2`, ... assigned at first `__kmp_push_task` for each `kmp_taskdata_t*`.

## Preprocessor (`preprocess_trace.py`)

Raw traces need preprocessing before TLA+ validation:

1. **Sort by (timestamp, tid)** — deterministic ordering
2. **Reorder schedule/steal** — `__kmp_push_task` pushes to the deque BEFORE emitting `ScheduleTask` (the push happens in the if-condition, the trace emit in the else-branch). Another thread can steal before the schedule event is logged. The preprocessor moves `ScheduleTask`/`ScheduleDetachTask` before the first `StealTask`/`ExecuteTask` that references the same task.
3. **Filter fork barrier** — Remove events before the first explicit barrier entry
4. **Filter leaked TaskTeamSync** — Remove TaskTeamSync events for threads that haven't entered the explicit barrier
5. **Keep first round** — Track per-thread `BarrierDone`, discard subsequent rounds
6. **Null → "Nil"** — TLA+ cannot deserialize JSON null

## Trace.tla Design Decisions

### Task Identity Constraint

Task constants must be **strings** (not model values) in the cfg:

```
Task = {"T1", "T2"}        \* NOT: Task = {T1, T2}
```

All task-related trace actions constrain `task == logline.task` to bind the exact task from the trace event. Without this, TLC non-deterministically assigns tasks and all branches eventually deadlock for traces with many tasks.

### Idempotent Actions

Several trace actions accept wider preconditions than the base spec because implementation events can arrive in different orders:

- **TraceWorkerStartTasks**: Accepts `pc \in {"barrier_gather", "barrier_tasks"}` (workers may already be in barrier_tasks from a silent transition)
- **TracePrimaryStartTaskWait**: Same pattern
- **TraceExecuteTask**: Has an idempotent path — if StealTask already set the task to "executing" for this thread, the cursor advances without state changes
- **TraceProxyTaskComplete**: Accepts tasks in "fulfilled" or "completed" phase (SilentProxyTaskComplete may fire first)

### Silent Actions

Three silent actions fire base spec transitions without consuming trace events:

- **SilentWorkerStartTasks**: Worker transitions barrier_gather → barrier_tasks between observed events
- **SilentPrimaryStartTaskWait**: Primary transitions barrier_gather → barrier_tasks
- **SilentProxyTaskComplete**: Bottom-half proxy completion runs between observed events

### Initial State

`TraceInit` starts AFTER the fork barrier has run:
- `taskTeamSlot = 1` (toggled from 0 by fork barrier's `__kmp_task_team_sync`)
- `taskTeamActive[1] = TRUE` (set up by fork barrier's `__kmp_task_team_setup`)
- `unfinished[1] = NumThreads`

### TracePrimaryEnterBarrier Guard

The implementation's `__kmp_task_team_setup` checks if the task team is already active (from the fork barrier) and skips re-initialization. The trace action models this with an IF guard on `~taskTeamActive[slot]`.

## Adding New Instrumentation

To add a new trace event:

1. **Choose the instrumentation point** in `kmp_barrier.cpp` or `kmp_tasking.cpp`
2. **Add the emit call** using one of the helpers in `omp_trace.h`:
   - `__omp_trace_emit_barrier_event(name, tid, pc, slot, finished, round, cancelled)` — barrier lifecycle
   - `__omp_trace_emit_schedule_task(name, tid, task_ptr, detachable, parent_ptr)` — task scheduling
   - `__omp_trace_emit_task_event(name, tid, task_ptr)` — task execution
   - `__omp_trace_emit_steal(thief, victim, task_ptr)` — stealing
   - `__omp_trace_emit_raw(json)` — custom JSON
3. **Add a Trace action** in `Trace.tla` matching the event name
4. **Add it to TraceNext** in the action wrapper section
5. **Update the cfg** if new constants are needed (e.g., more tasks)
6. **Re-run `preprocess_trace.py`** if the event has ordering issues

## Build Configuration

The instrumentation is gated behind `LIBOMP_TRACE`:

```bash
cmake ... -DCMAKE_C_FLAGS="-DLIBOMP_TRACE" -DCMAKE_CXX_FLAGS="-DLIBOMP_TRACE"
```

Without this flag, all trace functions compile to no-ops. The `OMP_TRACE_FILE` environment variable controls the output path at runtime.

## Validated Traces

| Trace | Events | TLC States | Config |
|-------|--------|------------|--------|
| test_basic_barrier | 25 | 29 | Trace.cfg (2 tasks) |
| test_task_steal | 49 | 64 | Trace_steal.cfg (8 tasks) |
| test_detach_task | 30 | 35 | Trace.cfg (2 tasks) |
