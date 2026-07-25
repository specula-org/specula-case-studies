# Task: Add Trace Validation to libgomp Case Study

## Goal

Write `Trace.tla`, `Trace.cfg`, and collect validated traces for the libgomp flat barrier spec in `case-studies/libgomp/spec/`. The main spec (`base.tla`) already exists and has been verified via model checking. We need trace validation to ground the spec in real execution behavior.

## What Already Exists

### Main spec (DO NOT MODIFY unless trace validation reveals a genuine spec bug)
- `case-studies/libgomp/spec/base.tla` — 1057 lines, 25+ variables, 30+ actions, 4 bug families
- `case-studies/libgomp/spec/MC.tla` — model checking wrapper
- `case-studies/libgomp/spec/MC.cfg` — convergence config (12K states, all pass)

### Existing harness from ablation experiment (USE AS STARTING POINT)
A previous experiment already instrumented libgomp and collected traces. All artifacts are at:

**Harness code:**
- `scripts/exp/ablation/results/20260321_full/full/libgomp/harness/src/tla_trace.h` — C header for NDJSON trace emission (thread-safe, mutex-protected, env-var controlled via `TLA_TRACE_FILE`)
- `scripts/exp/ablation/results/20260321_full/full/libgomp/harness/src/test_barrier_basic.c` — basic barrier + task test
- `scripts/exp/ablation/results/20260321_full/full/libgomp/harness/src/test_cancel.c` — cancel barrier test
- `scripts/exp/ablation/results/20260321_full/full/libgomp/harness/src/test_task_regions.c` — multi-round task test
- `scripts/exp/ablation/results/20260321_full/full/libgomp/harness/patches/instrumentation.patch` — git patch for libgomp source
- `scripts/exp/ablation/results/20260321_full/full/libgomp/harness/apply.sh` — apply script
- `scripts/exp/ablation/results/20260321_full/full/libgomp/harness/run.sh` — end-to-end run script
- `scripts/exp/ablation/results/20260321_full/full/libgomp/harness/INSTRUMENTATION.md` — instrumentation guide

**Existing traces (310 lines total across 6 files):**
- `scripts/exp/ablation/results/20260321_full/full/libgomp/traces/barrier_basic.ndjson` (48 lines)
- `scripts/exp/ablation/results/20260321_full/full/libgomp/traces/cancel.ndjson` (34 lines)
- `scripts/exp/ablation/results/20260321_full/full/libgomp/traces/task_regions.ndjson` (80 lines)
- (plus 3 test_ variants)

**Trace format (from tla_trace.h):**
```json
{"tag":"barrier","event":"<EventName>","thread":<id>,"timestamp":<monotonic_ns>,"state":{"generation":<uint>,"taskCount":<uint>,"phase":"<string>","cancelled":<bool>,"taskPending":<bool>,"waitingForTask":<bool>,"taskLockHolder":<int>}}
```

**Events already instrumented:**
- `BarrierWaitStart` — barrier entry (primary and secondary)
- `EnsureLast` — primary finished scanning all secondaries
- `CreateTask` — task scheduled
- `HandleTasks_AcquireLock`, `HandleTasks_ReleaseLock`, `HandleTasks_ExecuteTask`, `HandleTasks_SetWaitingForTask`, `HandleTasks_AllDone` — task handling lifecycle
- `Cancel` — cancellation event

### GCC source code
- `case-studies/libgomp/artifact/gcc/` — GCC source with NVIDIA flat barrier patches applied

## What You Need to Do

### Step 1: Copy and adapt the harness

Copy the ablation harness to the main case study location:
```
case-studies/libgomp/harness/src/tla_trace.h
case-studies/libgomp/harness/src/test_barrier_basic.c
case-studies/libgomp/harness/src/test_cancel.c
case-studies/libgomp/harness/src/test_task_regions.c
case-studies/libgomp/harness/patches/instrumentation.patch
case-studies/libgomp/harness/apply.sh
case-studies/libgomp/harness/run.sh
case-studies/libgomp/harness/INSTRUMENTATION.md
```

You may need to adapt paths in apply.sh and run.sh (the ablation used a different directory structure).

### Step 2: Build instrumented libgomp and collect traces

Apply the instrumentation patch to the GCC source, build libgomp, and run the test scenarios to collect traces into `case-studies/libgomp/traces/`.

Build instructions (from the existing repro/README.md):
```bash
cd case-studies/libgomp/artifact/gcc
git checkout -- .  # clean state
git apply ../../harness/patches/instrumentation.patch
mkdir -p /tmp/libgomp-build && cd /tmp/libgomp-build
../../artifact/gcc/libgomp/configure --disable-multilib CC=gcc CXX=g++ CFLAGS="-g -O2" CXXFLAGS="-g -O2"
make -j$(nproc) libgomp.la
```

Then run tests with `LD_LIBRARY_PATH=/tmp/libgomp-build/.libs` and `TLA_TRACE_FILE=<output_path>`.

### Step 3: Write Trace.tla

Write `case-studies/libgomp/spec/Trace.tla` that maps trace events to the MAIN spec's actions in `base.tla`.

**Key mapping (trace events → base.tla actions):**

| Trace Event | base.tla Action | Notes |
|-------------|-----------------|-------|
| `BarrierWaitStart` (thread=0) | `PrimaryEnterBarrier` | Primary always enters scanning |
| `BarrierWaitStart` (thread>0) | `SecondaryEnterBarrier(t)` or `SecondaryEnterCancelBarrier(t)` | Depends on barrier type |
| `EnsureLast` | After all `PrimaryCheckThread` / `PrimaryCheckCancelThread` complete | May need silent actions for individual check steps |
| `HandleTasks_SetWaitingForTask` | Part of `PrimaryCompleteBarrier` (taskCount > 0 path) | Sets waitingForTask=TRUE |
| `HandleTasks_ExecuteTask` | `PrimaryHandleTaskLast` or `SecondaryHandleTask(t)` | Depends on which thread |
| `HandleTasks_AllDone` | `PrimaryHandleTaskLast` (taskCount=0 path) | Barrier completion |
| `CreateTask` | `ScheduleTask` | |
| `Cancel` | `CancelBarrier` | |

**Silent actions needed** (spec actions with no trace event):
- `PrimaryCheckThread` / `PrimaryCheckCancelThread` — primary checks one secondary at a time; no individual trace events
- `SecondaryPassBarrier(t)` / `SecondaryPassCancelBarrier(t)` — secondary exits barrier
- `PrimaryStartNextRound` — round transition
- `PrimaryReleasePrev` — release held secondaries
- `SecondaryCheckFallback(t)` — fallback protocol
- Various fallback actions

**Important patterns (from `src/skills/harness-generation/guide.md` and other case studies):**

1. Use `tIdx` cursor variable to walk through trace log
2. Filter trace by tag: `SelectSeq(RawTraceLog, LAMBDA e : e.tag = "barrier")`
3. Use `IsEvent(name)` helper: `tIdx <= Len(TraceLog) /\ TraceLog[tIdx].event = name`
4. Silent actions must have `tIdx' = tIdx` (don't advance cursor)
5. Trace actions must have `tIdx' = tIdx + 1`
6. Terminal action: `tIdx > Len(TraceLog) /\ UNCHANGED traceVars`
7. Use INIT/NEXT style (not SPECIFICATION) for deadlock-based completion checking

**Post-state validation:**
The trace captures `generation`, `taskCount`, `cancelled`, `taskPending`, `waitingForTask`. Use these to validate post-state:
```tla
ValidatePostState(ll) ==
    /\ generation' = ll.state.generation
    /\ taskCount' = ll.state.taskCount
    /\ cancelled' = ll.state.cancelled
    /\ taskPending' = ll.state.taskPending
    /\ waitingForTask' = ll.state.waitingForTask
```

Not all fields can be validated at every event (some events capture state before the action completes). Use `ValidatePostStateWeak` for events where only a subset of fields is reliable.

### Step 4: Write Trace.cfg

```
INIT TraceInit
NEXT TraceNext

CONSTANTS
    Thread = {0, 1, 2}
    MaxBarriers = 10
    MaxTasks = 10
    Nil = Nil
    BarrierNormal = "BarrierNormal"
    BarrierFinal = "BarrierFinal"
    BarrierCancel = "BarrierCancel"

ALIAS TraceAlias
```

Use large bounds for MaxBarriers/MaxTasks since trace validation only explores the trace path (no explosion).

### Step 5: Run trace validation

Use the `tla-trace-workflow` skill or run manually:
```bash
cd case-studies/libgomp/spec
java -jar ../../../lib/tla2tools.jar -config Trace.cfg -deadlock Trace.tla \
  -DJSON=../traces/barrier_basic.ndjson
```

A successful trace validation ends with "Deadlock reached" at `tIdx > Len(TraceLog)` — this means the entire trace was consumed.

If validation stops early (deadlocks before consuming all events), debug by examining which event couldn't be matched to any action.

### Step 6: Iterate

If trace validation fails:
1. Check if the trace event's state fields match what the spec expects
2. Check if silent actions are missing (spec needs intermediate steps between traced events)
3. Check if the event-to-action mapping is wrong
4. Only modify base.tla if you discover a genuine spec-vs-code inconsistency

## Important Notes

- The main spec uses `tag: "barrier"` format (not `tag: "trace"`). Match the existing trace format.
- Thread IDs in traces are 0, 1, 2 (matching spec's Thread = {0, 1, 2})
- The harness instrumentation was done against the NVIDIA flat barrier patch. Make sure you build from `case-studies/libgomp/artifact/gcc/` which has the patches applied.
- The `instrumentation.patch` from ablation may need rebasing if the artifact source has changed. Check `git status` in the artifact dir before applying.
- Prioritize getting at least ONE trace (barrier_basic) to validate successfully. Cancel and task_regions traces are bonus.

## Reference

- Harness generation skill guide: `src/skills/harness-generation/guide.md`
- Trace validation workflow: `src/skills/tla-trace-workflow/guide.md`
- Example Trace.tla patterns: `case-studies/libomp/spec/Trace.tla`, `case-studies/cometbft/spec/Trace.tla`
- TLC JARs: `lib/tla2tools.jar`, `lib/CommunityModules-deps.jar`
