# Meeting Script: Detailed Phase-by-Phase Walkthrough

This is the detailed version. Use this when they ask "can you show us the actual outputs?" or when you want to go deeper on a specific phase.

---

## Phase 1: Code Analysis → modeling-brief.md

The first agent reads the source code. For libgomp, it reads about 3,500 lines across five core files. The output is a document called a "modeling brief." Let me show you what's in it.

### Section 1: System Overview

The brief starts with a one-paragraph summary. It identifies the system — libgomp, GCC's OpenMP runtime. It identifies the concurrency model — shared memory with atomics, acquire-release semantics, futex syscalls. And it identifies the key architectural choice — thread 0 is a fixed coordinator, the "primary," that sequentially scans per-thread generation numbers. This is different from the old centralized "last arriver wins" design.

### Section 2: Bug Families

This is the most important part. The agent groups its findings into "bug families" — clusters of code paths that share a common mechanism where bugs could hide. For libgomp, we got four:

**Family 1: Futex_waitv Fallback.** On older kernels without futex_waitv, the primary can't atomically wait on multiple addresses. So there's a handshake protocol using PRIMARY_WAITING_TG and BAR_SECONDARY_ARRIVED flags. This is the most complex part of the patch — the author marked one line with triple question marks. Our agent found this, and flagged it as highest priority.

**Family 2: Cancellation Flag Cleanup.** When cancel fires, BAR_CANCELLED is set on bar->generation. Then there's a three-party race between the cancelling thread, the secondary setting BAR_SECONDARY_CANCELLABLE_ARRIVED, and the primary scanning threads. The author's own comment at bar.c:679 says — and I'm quoting — "There are too many windows for race conditions." So the author chose NOT to clean up stale flags. Our agent found this comment and flagged it.

**Family 3: BAR_HOLDING_SECONDARIES Lifecycle.** At the final barrier, the primary sets a holding flag to keep secondaries waiting while it proceeds. The secondaries are only released when the next parallel region starts. This spans two consecutive parallel regions, which makes it hard to reason about manually.

**Family 4: Team ABA.** During handle_tasks, a secondary may see a new team on its thread-local storage. The defense is a pointer comparison — check if the barrier pointer matches. But if the old team is freed and a new one is allocated at the same address, this ABA check passes incorrectly. The code has a detailed comment explaining this known race.

### Section 3: Model / Do Not Model

The brief also explicitly states what NOT to model. We don't model futex kernel semantics — that's below TLA+'s abstraction level. We don't model memory ordering — TLA+ works under sequential consistency. We don't model thread affinity, nested parallel regions, or work sharing. These are either out of scope or orthogonal to the barrier protocol.

This is important because it sets clear boundaries. We focus on where the bugs are.

### Section 4: Proposed Invariants

The brief proposes nine safety invariants, one or more per bug family. For example:

- BarrierSafety: no secondary passes the barrier before all secondaries have arrived.
- FallbackCorrectness: PRIMARY_WAITING_TG is always cleared before the next barrier round.
- CgenConsistency: at cancel barrier entry, all thread-local cancel generation values match.
- DetachFulfillNoDeadlock: the system never reaches a state where all threads are waiting, task count is zero, but nobody can enter handle_tasks.

That last one is the invariant that caught Bug 29.

---

## Phase 2: Spec Generation → base.tla, MC.tla, hunting configs

The second agent takes the modeling brief and writes TLA+ specifications. There are three layers.

### Layer 1: base.tla — The Core Spec

This is a thousand-line TLA+ specification that models the barrier protocol. Let me show you what it looks like.

**Variables.** We have 25 state variables, each mapping directly to the C implementation. `generation` is bar->generation. `taskPending` is the BAR_TASK_PENDING bit. `threadGen` is the per-thread generation array. `cancelled` is BAR_CANCELLED. And so on. The variable declarations include comments with exact source file and line references — bar.h:58, bar.h:69, bar.h:75.

**Actions.** Each action models a step in the barrier protocol. Let me show you one. `PrimaryEnterFallback` — this models futex_waitv.h:87, where the primary sets PRIMARY_WAITING_TG on a secondary's generation number. The action has two branches: if the secondary already arrived, clear the flag and go back to scanning. If not, enter the wait state. The comment says exactly which source lines this corresponds to.

We have about 30 actions total — barrier entry, primary scanning, fallback protocol, barrier completion, secondary waiting, task handling, detach task lifecycle, cancellation, holding lifecycle, round transitions.

**The Bug.** Let me show you the FulfillEvent action — this is where Bug 29 lives. The action models omp_fulfill_event from an unshackled thread. Look at line 731: `UNCHANGED taskPending`. That's the bug, right there in the spec. The code does `do_wake = 1` but doesn't set BAR_TASK_PENDING. The fix is on line 735, commented out: `taskPending' = TRUE`.

**Invariants.** At the bottom of the spec, we define 18 safety invariants. The one that catches Bug 29 is `DetachFulfillNoDeadlock` — just four lines of TLA+. It says: it should never be the case that all threads are in the "waiting" state, task count is zero, waiting for task is true, and task pending is false. If that state is reached, nobody will ever enter handle_tasks, nobody will call barrier_done, and you have a deadlock.

### Layer 2: MC.tla — Model Checking Wrapper

The base spec has unbounded non-determinism — tasks can be scheduled at any time, cancellation can fire at any time. TLC needs finite state space. So MC.tla wraps the base with counter-bounded actions.

There are three bounded actions: ScheduleTask, ScheduleDetachTask, and CancelBarrier. Each has a counter. When the counter reaches the limit — say, MaxScheduleTaskLimit = 2 — that action is disabled. All other actions — barrier entry, primary scanning, task handling, barrier completion — are unbounded because they're reactive, they only respond to existing state.

MC.tla also restricts barrier types. For hunting, we might only allow BarrierNormal, or only BarrierCancel, to focus the search.

### Layer 3: Hunting Configs

Each bug family gets its own config file with tuned bounds. Let me show you two.

**MC_hunt_detach_deadlock.cfg** — for Bug 29. Three threads. One barrier round. Zero regular tasks. One detach task. Zero cancellations. Only normal barriers. Three invariants checked: DetachFulfillNoDeadlock, BarrierSafety, WaitingForTaskImpliesAllArrived. Result: 492 states, violation found in under one second.

**MC.cfg** — the convergence config. Three threads. Two barrier rounds. Two regular tasks. One detach task. One cancellation. All barrier types. All 18 invariants checked. Result: 1.45 million states, all pass, 20 seconds.

The hunting config is minimal — just enough to trigger the bug. The convergence config is maximal — it checks everything and confirms the spec is sound.

---

## Phase 2.5: Trace Harness → tla_trace.h, instrumentation patch, test scenarios, NDJSON traces

The third agent instruments the real C code to collect execution traces.

### Trace Module: tla_trace.h

This is a 178-line C header. It provides a thread-safe trace emit function. Each call writes one NDJSON line with: event name, thread ID, monotonic timestamp, and a state snapshot.

The state snapshot extracts fields from bar->generation using bitmask operations — generation counter, BAR_TASK_PENDING, BAR_WAITING_FOR_TASK, BAR_CANCELLED. It also captures task_count and a per-thread phase string.

The trace file is controlled by the TLA_TRACE_FILE environment variable. If it's not set, no tracing happens — zero overhead for normal builds.

### Instrumentation Patch

We insert trace emit calls at about 15 points in two source files — bar.c and task.c. Each insertion is a small block:

```c
/* TLA+ trace: BarrierWaitStart */
{
  unsigned _tla_gen = __atomic_load_n(&bar->generation, MEMMODEL_RELAXED);
  tla_emit_simple("BarrierWaitStart", id, _tla_gen, team->task_count);
}
```

The key events: BarrierWaitStart, EnsureLast, HandleTasks_AcquireLock, HandleTasks_ExecuteTask, HandleTasks_AllDone, CreateTask, Cancel.

### Test Scenarios

We have three test programs:

- test_barrier_basic.c — 3 threads, multiple barrier rounds with tasks. Exercises the core protocol.
- test_cancel.c — cancellation during barrier. Exercises Family 2.
- test_task_regions.c — multiple rounds with different task counts. Exercises Family 1 and 3.

Each test links against the instrumented libgomp and writes a trace file.

### Collected Traces

We get NDJSON files like this:

```json
{"tag":"barrier","event":"BarrierWaitStart","thread":0,"timestamp":2067790031935132,"state":{"generation":0,"taskCount":0,"phase":"arriving","cancelled":false,"taskPending":true,"waitingForTask":false}}
{"tag":"barrier","event":"EnsureLast","thread":0,"timestamp":2067790032036564,"state":{"generation":0,...}}
{"tag":"barrier","event":"HandleTasks_AllDone","thread":2,"timestamp":2067790032143175,"state":{"generation":1,...}}
```

Real timestamps. Real state. Real interleavings from the OS scheduler.

---

## Phase 3: Verification Loop → convergence, then hunting

### Step 1: Trace Validation

We replay each trace against the spec. The Trace.tla file maps each trace event to a base spec action. For example, a `BarrierWaitStart` event from thread 0 maps to `PrimaryEnterBarrier`. A `HandleTasks_ExecuteTask` event from thread 2 maps to `SecondaryHandleTask(2)`.

Between traced events, the spec may need intermediate steps — we call these "silent actions." For example, PrimaryCheckThread fires once per secondary during the scan, but the trace only emits one EnsureLast event at the end. So the individual check steps are silent.

Trace validation succeeds when TLC can replay the entire trace — consuming every event — without getting stuck.

### Step 2: Model Checking

We run TLC with the convergence config — MC.cfg, 18 invariants. If any invariant is violated, we classify the counterexample:

- Case A: the invariant is too strong. We weaken it.
- Case B: the spec doesn't match the code. We fix the spec.
- Case C: it's a real bug. We stop and report.

Only Case C goes into the bug report.

### Step 3: Iteration

If model checking changes the spec, we go back to trace validation. The spec change might break a trace that was passing before. We iterate until both pass in the same round — that's convergence.

### Step 4: Bug Hunting

After convergence, we run each hunting config. For libgomp:

| Config | Target | States | Result |
|--------|--------|--------|--------|
| MC_hunt_detach_deadlock | Bug 29: fulfill_event deadlock | 492 | **DetachFulfillNoDeadlock violated** |
| MC_hunt_family1 | Futex fallback | 441 | All pass |
| MC_hunt_family2 | Cancel flags | 1,022 | All pass |
| MC_hunt_family3 | Holding lifecycle | 4,613 | All pass |
| MC_hunt_family4 | Team ABA | 3,309 | All pass |
| MC_stress (convergence) | All families | 1.45M | All 18 invariants pass |

Five families checked. One bug found. Four clean.

---

## Phase 4: Bug Confirmation → reproducer, patch, bug report

### Code Audit

The agent reads omp_fulfill_event in task.c. It traces the two wake paths:

Path 1 — dependent tasks exist. The code calls `gomp_team_barrier_set_task_pending` before waking. This is correct. This was fixed in commit ba886d0c, May 2021.

Path 2 — no dependent tasks, unshackled thread. The code sets `do_wake = 1` but does NOT call `gomp_team_barrier_set_task_pending`. This is the bug.

The agent explains why this causes a deadlock: futex_wake only wakes a thread from futex_wait. It does NOT change bar->generation. Without BAR_TASK_PENDING modifying bar->generation, the woken thread sees no change and goes back to sleep. Since handle_tasks is the only path to call barrier_done, nobody ever completes the barrier.

### Reproducer

The agent writes detach_fulfill_deadlock.c — 132 lines, standard OpenMP 5.0 plus POSIX pthread. A parallel region with a detached task and an external thread that calls omp_fulfill_event.

```bash
gcc -fopenmp -O2 -lpthread -o repro detach_fulfill_deadlock.c
timeout 5 ./repro    # exit 124 = deadlock
```

5 out of 5 deadlock. With the one-line fix: 5 out of 5 pass.

### Patch

One line added: `gomp_team_barrier_set_task_pending(&team->barrier);` before `do_wake = 1`. This matches the pattern already used three lines above in the same function. The patch follows GCC's ChangeLog format and is ready for upstream submission.

### Why This Bug Survived

1. Test gap: GCC's task-detach-13 test uses depend clauses, which triggers the new_tasks > 0 path — the one that's already fixed. No test covers new_tasks == 0 plus unshackled thread.
2. Subtle semantics: it's natural to think futex_wake plus do_wake = 1 is enough. The subtlety is that futex_wake doesn't change bar->generation.
3. Same author, three months apart: the set_task_pending fix was added in May 2021, but only to one of two symmetric paths. The other path was written in February 2021.
