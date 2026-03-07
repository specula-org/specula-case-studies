# libgomp Flat Barrier Bug Report

## Summary

- **Target**: NVIDIA's flat barrier patch (Patch 3/5) for GCC's libgomp OpenMP runtime
- **Patch series**: [gcc-patches mailing list, 2025](https://gcc.gnu.org/pipermail/gcc-patches/)
- **Bug found**: 1 (cancel+task race in `gomp_barrier_handle_tasks`)
- **Trigger path**: Final barrier (implicit barrier at end of parallel region)
- **Legitimate reproduction**: Yes (standard OpenMP only, no compiler bypass)

### Model Checking Coverage

| Config | Mode | States | Result |
|--------|------|--------|--------|
| MC.cfg | BFS | 434K | All 5 invariants hold |
| MC_hunt_cross_cancel_task.cfg | BFS | ~22K | **BarrierSafety violated** |
| MC_stress.cfg | BFS | 434K | All hold |
| MC_hunt_family1.cfg | BFS | ~15K | All hold |
| MC_hunt_family2.cfg | BFS | ~18K | All hold |
| MC_hunt_family3.cfg | BFS | ~12K | All hold |
| MC_hunt_family4.cfg | BFS | ~20K | All hold |

---

## Bug #28: BAR_CANCELLED Overwrite in gomp_barrier_handle_tasks

- **Severity**: Medium (code defect; checking builds: assertion failure at bar.c:521; production builds: no observable impact due to `team_cancelled` fallback)
- **Status**: Not yet reported upstream
- **Root cause**: `gomp_increment_gen` unconditionally strips all flag bits including BAR_CANCELLED

### Root Cause

In `config/linux/bar.h`, `gomp_increment_gen` computes the new barrier generation:

```c
static unsigned gomp_increment_gen(gomp_barrier_state_t gen, unsigned increment)
{
    unsigned gens = (gen & BAR_BOTH_GENS_MASK);  // strips ALL flags (bits 0-5)
    switch (increment) {
    case BAR_CANCEL_INCR:
        return BAR_INCREMENT_CANCEL(gens);
    case BAR_HOLDING_SECONDARIES:
        return gens | BAR_HOLDING_SECONDARIES;   // BAR_CANCELLED lost!
    // ...
    }
}
```

`BAR_BOTH_GENS_MASK` covers bits 6+ (generation counters). Bits 0-5 are flags:
- Bit 0: BAR_WAS_LAST
- Bit 1: BAR_WAITING_FOR_TASK
- Bit 2: **BAR_CANCELLED**
- Bit 3: BAR_TASK_PENDING
- Bit 5: BAR_HOLDING_SECONDARIES

`gomp_increment_gen` strips ALL of them, then only restores the increment-specific flag. BAR_CANCELLED is never preserved.

`gomp_team_barrier_done` calls `gomp_increment_gen` and performs an `__atomic_store_n` on `bar->generation`, unconditionally overwriting any BAR_CANCELLED that was set by `gomp_team_barrier_cancel`.

There are two call sites in `gomp_barrier_handle_tasks` (task.c) that trigger this:

1. **Line 1612-1614**: Primary enters handle_tasks, task_count is already 0
2. **Line 1648-1667**: All tasks finished/cancelled during the while(1) loop

Neither site checks BAR_CANCELLED before calling `gomp_team_barrier_done`.

### Trigger Path: Final Barrier (Legitimate OpenMP)

**File**: `repro/final_barrier_cancel_task.c`

This path uses only standard OpenMP constructs:

```
1. Thread 0 creates 500 deferred tasks (#pragma omp task)
2. Threads 0,2,3 reach implicit barrier at end of parallel region
3. Primary enters handle_tasks(BAR_HOLDING_SECONDARIES), starts executing tasks
4. Thread 1 issues #pragma omp cancel parallel (after 5ms delay)
   → gomp_team_barrier_cancel sets BAR_CANCELLED on bar->generation
5. Subsequent gomp_task_run_pre calls see BAR_CANCELLED → cancel remaining tasks
6. task_count drops to 0
7. gomp_team_barrier_done(state, BAR_HOLDING_SECONDARIES)
   → gomp_increment_gen strips BAR_CANCELLED
   → atomic_store overwrites bar->generation → BAR_CANCELLED LOST
```

**Consequences** (final barrier path):
- Checking builds (`_LIBGOMP_CHECKING_=1`): Assertion at bar.c:521 fires → abort
- Non-checking builds: BAR_CANCELLED inconsistency in bar->generation, but `team_cancelled` (independent field) handles cleanup correctly. Limited observable impact.

### Why NVIDIA's Tests Miss This

NVIDIA has three cancel-parallel tests in the testsuite:

| Test | Has cancel? | Has tasks? | Has final barrier + tasks? |
|------|-------------|------------|---------------------------|
| cancel-parallel-1.c | Yes | No | No |
| cancel-parallel-2.c | Yes | Yes | Tasks pending at explicit barrier, but `gomp_team_barrier_wait_cancel` returns early (line 860-861) before entering handle_tasks |
| cancel-parallel-3.c | Yes | No | Cancel during final barrier, but no tasks → handle_tasks not called |

The bug requires **cancel + pending tasks + handle_tasks at a barrier** — a combination none of their tests exercise.

NVIDIA's own comment at bar.c:526-533 acknowledges that BAR_CANCELLED can be set during the final barrier (the cancel-parallel-3.c scenario), but the interaction with handle_tasks was not tested.

### Suggested Fix

Option A — Preserve BAR_CANCELLED in `gomp_increment_gen`:
```c
case BAR_HOLDING_SECONDARIES:
    return gens | BAR_HOLDING_SECONDARIES | (gen & BAR_CANCELLED);
```

Option B — Check BAR_CANCELLED before calling `gomp_team_barrier_done` in handle_tasks:
```c
if (team->task_count == 0
    && gomp_team_barrier_waiting_for_tasks (&team->barrier))
{
    if (gomp_team_barrier_cancelled (&team->barrier))
        /* handle cancellation instead of overwriting */;
    gomp_team_barrier_done (&team->barrier, state, increment);
    ...
}
```

Option A is simpler and fixes the root cause for all barrier types at once.

### TLA+ Model

The bug was discovered through TLA+ model checking of the flat barrier protocol. The specification models:
- 4 threads, 4 barriers, 2 tasks, 3 cancellations
- Barrier lifecycle: arrival → ensure_last → handle_tasks → barrier_done
- Cancel semantics: BAR_CANCELLED flag set via atomic fetch_or
- Task scheduling: dequeue, execute, cancel interactions

Key invariant violated: `BarrierSafety` — asserts that no secondary thread proceeds past the barrier before all secondaries have arrived (`threadGen` ordering). The violation is indirect: `PrimaryHandleTaskLast` completes the barrier (increments generation) without checking BAR_CANCELLED, causing a split-brain where one secondary sees the cancel (undoes its arrival) while another sees the generation increment (passes normally). This creates inconsistent `threadGen` values among secondaries at "done".

Note: The model found this violation on the cancel barrier path (`BAR_CANCEL_INCR`). Investigation of the real code shows this path is blocked in practice by an early return at bar.c:860-861. However, the same root cause (`gomp_increment_gen` stripping BAR_CANCELLED) is reachable via the final barrier path (`BAR_HOLDING_SECONDARIES`), where it triggers the checking assertion at bar.c:521-534.

---

## Reproduction Instructions

See `repro/README.md` for step-by-step reproduction instructions.
