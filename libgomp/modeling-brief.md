# Modeling Brief: libgomp Flat Barrier (Patch 3/5)

## 1. System Overview

- **System**: libgomp — GCC's OpenMP runtime library
- **Language**: C (~900 LOC of core barrier logic in `config/linux/bar.c` + `bar.h`)
- **What it implements**: Flat barrier synchronization for `#pragma omp parallel` regions
- **Author**: Matthew Malcomson (NVIDIA), submitted Nov 2025, not yet merged
- **Concurrency model**: Shared-memory with atomics (acquire-release semantics) + futex syscalls
- **Key architectural choice**: Primary thread (id=0) is the fixed coordinator — replaces the centralized "last-arriver-wins" barrier with per-thread generation numbers scanned sequentially by the primary

## 2. Bug Families

### Family 1: Futex_waitv Fallback Protocol (PRIMARY_WAITING_TG / BAR_SECONDARY_ARRIVED)

**Mechanism**: On kernels < 5.16 without `futex_waitv`, primary cannot atomically wait on two addresses. A handshake protocol using flag bits coordinates primary sleep/wakeup on per-thread generation numbers. This is the most complex part of the code — the author marks it with `???` (futex_waitv.h:113).

**Evidence**:
- Code analysis: futex_waitv.h:83-129 (fallback implementation), bar.c:103-129 (secondary flag handling), bar.c:263-410 (primary polling loop with fallback)
- Developer signal: `???` at futex_waitv.h:113 acknowledges poor separation of concerns
- Complexity: Only place where a non-owner thread modifies a thread-local generation (bar.c:258-261 comment)

**Affected code paths**:
- `futex_waitv()` fallback (futex_waitv.h:83-129)
- `gomp_assert_and_increment_flag()` (bar.c:103-129)
- `gomp_team_barrier_ensure_last()` (bar.c:263-410)
- `gomp_assert_and_increment_cancel_flag()` (bar.c:588-629)
- `gomp_team_barrier_ensure_cancel_last()` (bar.c:631-721)

**Suggested modeling approach**:
- Variables: `bar_generation` (shared), `threadgens[i]` (per-thread), `primary_waiting` flag, `secondary_arrived` flag
- Actions: PrimaryStartWait, PrimaryCheckThread, PrimaryEnterFallback, SecondaryArrive, SecondaryNotifyArrival, PrimaryWakeFromFallback, PrimaryClearFlags
- Granularity: Each atomic operation as a separate TLA+ action (fetch_or, fetch_add, store are not atomic compounds)
- Key property: Primary never misses a secondary arrival. Primary never blocks forever when all secondaries have arrived.

**Priority**: High
**Rationale**: Highest complexity, author's own uncertainty marker, cross-thread modification of thread-local state, multiple re-entry scenarios

### Family 2: Cancellation + Barrier Flag Cleanup

**Mechanism**: When `#pragma omp cancel parallel` fires, `BAR_CANCELLED` is set on `bar->generation`. The cancellable barrier's flag cleanup protocol (`BAR_SECONDARY_CANCELLABLE_ARRIVED`) involves a three-party race between the canceller, the secondary setting the flag, and the primary scanning threads.

**Evidence**:
- Code analysis: bar.c:610-621 (secondary sets flag), bar.c:884-906 (canceller sets BAR_CANCELLED), bar.c:674-688 (primary detects cancel)
- Developer signal: Comment at bar.c:679-687 explicitly says "There are too many windows for race conditions" — author chose NOT to clean up stale flags in the primary
- Asymmetric memory ordering: bar.c:612 uses MEMMODEL_RELAXED for BAR_SECONDARY_CANCELLABLE_ARRIVED vs bar.c:120 uses MEMMODEL_RELEASE for BAR_SECONDARY_ARRIVED (non-cancellable path)

**Affected code paths**:
- `gomp_team_barrier_cancel()` (bar.c:872-907)
- `gomp_assert_and_increment_cancel_flag()` (bar.c:588-629)
- `gomp_team_barrier_ensure_cancel_last()` (bar.c:631-721)
- `gomp_team_barrier_wait_cancel_end()` (bar.c:723-853) — cgen reset at bar.c:828-830

**Suggested modeling approach**:
- Variables: `bar_generation` (with cancel/arrived/holding flag bits), per-thread `cgen`, cancel state
- Actions: CancelBarrier, SecondaryArriveCancel, SecondarySetCancellableArrived, PrimaryScanCancel, SecondaryCgenReset
- Model the lifecycle: cancel barrier → non-cancel barrier → next cancel barrier
- Key property: BAR_SECONDARY_CANCELLABLE_ARRIVED is always cleared before the next cancellable barrier. All thread-local `cgen` values are correct at next cancellable barrier entry.

**Priority**: High
**Rationale**: Author explicitly acknowledges race condition windows. Asymmetric memory ordering between cancel/non-cancel paths is suspicious. Three-party interleaving is hard to reason about manually.

### Family 3: BAR_HOLDING_SECONDARIES Lifecycle (Patch 4/5 interaction)

**Mechanism**: At the final barrier (end of parallel region), primary sets `BAR_HOLDING_SECONDARIES` to proceed while keeping secondaries waiting. Secondaries are released later by `gomp_team_barrier_done_final` when the next parallel region starts. This spans two consecutive parallel regions.

**Evidence**:
- Code analysis: bar.c:482-563 (wait_for_tasks with HOLDING), bar.c:575-586 (done_final release), team.c:34-50 (release_held_threads), team.c:1133-1225 (gomp_team_end)
- The RELAXED store at bar.c:510 when task_count==0 (vs RELEASE in other paths)
- Potential assertion issue: bar.c:579 asserts flags == BAR_HOLDING_SECONDARIES, but stale BAR_SECONDARY_CANCELLABLE_ARRIVED could violate this

**Affected code paths**:
- `gomp_team_barrier_wait_for_tasks()` (bar.c:482-563)
- `gomp_team_barrier_done_final()` (bar.c:575-586)
- `gomp_release_held_threads()` (team.c:34-50)
- `gomp_team_end()` (team.c:1133-1225)
- `gomp_thread_start()` secondary loop (team.c:141-182)

**Suggested modeling approach**:
- Variables: `bar_generation`, `holding` flag, `prev_barrier` pointer, thread states (running/waiting/held)
- Actions: PrimaryFinishBarrier, PrimarySetHolding, PrimaryDoCleanup, PrimaryStartNextRegion, PrimaryReleasePrev, SecondaryWaitFinal, SecondaryResumeNextRegion
- Key property: No secondary accesses a freed/reinitialized team. No secondary runs user code from the next region before being properly initialized.

**Priority**: Medium
**Rationale**: Spans two parallel regions making manual reasoning difficult. Agent analysis found it correct but the cross-region lifecycle is inherently error-prone.

### Family 4: Team Reassignment Race (ABA-dependent defense)

**Mechanism**: During `gomp_barrier_handle_tasks`, a secondary may observe a new team on its TLS (stored by primary starting a new region). The defense is `&team->barrier != bar` (task.c:1583). If the old team is freed and a new team allocated at the same address, this check passes incorrectly (ABA). Safety relies on the new team having zero tasks.

**Evidence**:
- Code analysis: task.c:1551-1606 (handle_tasks with race comment), team.c:753 (RELEASE store of new team), team.c:1211-1213 (team caching/reuse)
- Developer signal: Detailed comment at task.c:1562-1584 describing the known race

**Suggested modeling approach**:
- Variables: `thr_team` (per-thread TLS), `bar` (barrier pointer captured at entry), `task_count`
- Actions: SecondaryEnterHandleTasks, PrimaryFinishBarrier, PrimaryStartNewRegion, PrimaryAssignNewTeam
- Key property: Secondary never executes tasks from a different parallel region

**Priority**: Medium
**Rationale**: Known fragile defense. ABA scenario requires specific allocation pattern but is not impossible.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Flat barrier core protocol | Foundation for all other checks | Per-thread gen array, primary scanning, global generation |
| Futex_waitv fallback handshake | Family 1: highest complexity, author uncertainty | PRIMARY_WAITING_TG / BAR_SECONDARY_ARRIVED flags as separate actions |
| Cancellation flag lifecycle | Family 2: explicit "too many race windows" comment | BAR_CANCELLED + BAR_SECONDARY_CANCELLABLE_ARRIVED cleanup across 2 barriers |
| BAR_HOLDING_SECONDARIES | Family 3: cross-region lifecycle | HOLDING flag, release in next region |
| Task handling during barrier | Families 1,3,4: tasks interleave with barrier protocol | BAR_TASK_PENDING, gomp_barrier_handle_tasks as interruptible action |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| futex kernel semantics | Out of TLA+ scope. Assume futex_wait/wake behave correctly. Model as abstract wait/notify. |
| Memory ordering (acquire/release) | TLA+ models sequential consistency. Cannot find memory ordering bugs. The asymmetric RELAXED in Family 2 is noted but cannot be checked. |
| Thread affinity / placement | Performance optimization, no correctness impact |
| gomp_simple_barrier (old centralized) | Not part of patch 3/5 — retained only for thread pool dock |
| Nested parallel regions | Different code path (uses gomp_barrier_wait not team variant), less interesting |
| Work share management | Orthogonal to barrier protocol |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Fallback protocol | `primary_waiting[i]`, `secondary_arrived` | Model PRIMARY_WAITING_TG / BAR_SECONDARY_ARRIVED handshake | Family 1 |
| Cancel flag tracking | `cancelled`, `cancel_arrived`, `cgen[i]` | Model BAR_CANCELLED + BAR_SECONDARY_CANCELLABLE_ARRIVED lifecycle | Family 2 |
| Holding mechanism | `holding`, `prev_barrier` | Model BAR_HOLDING_SECONDARIES across regions | Family 3 |
| Task pending | `task_pending`, `task_count` | Model BAR_TASK_PENDING interrupting primary's scan | Family 1, 3 |
| Team pointer | `team[i]` (per-thread) | Model team reassignment race | Family 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| BarrierSafety | Safety | No secondary proceeds past barrier before all have arrived | Core protocol |
| DeadlockFreedom | Liveness | If all secondaries eventually arrive, primary eventually completes | Core + Family 1 |
| FallbackCorrectness | Safety | PRIMARY_WAITING_TG is always cleared before thread's next barrier entry | Family 1 |
| NoMissedArrival | Safety | If secondary set BAR_SECONDARY_ARRIVED, primary eventually observes it | Family 1 |
| CancelFlagCleanup | Safety | BAR_SECONDARY_CANCELLABLE_ARRIVED is cleared before next cancellable barrier | Family 2 |
| CgenConsistency | Safety | At cancellable barrier entry, all cgen values match global cancel generation | Family 2 |
| HoldingRelease | Liveness | Secondaries held by BAR_HOLDING_SECONDARIES are eventually released | Family 3 |
| NoUseAfterFree | Safety | No secondary accesses team after it could be freed | Family 3, 4 |
| TaskIsolation | Safety | No secondary executes tasks from a different parallel region | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Fallback re-entry: primary exits futex_wait (task wakeup), handles task, re-enters fallback for same thread while PRIMARY_WAITING_TG still set and secondary arrives between iterations | FallbackCorrectness or DeadlockFreedom | Family 1 |
| MC-2 | Three-party race: canceller sets BAR_CANCELLED, secondary sets BAR_SECONDARY_CANCELLABLE_ARRIVED, primary in ensure_cancel_last — verify flag always cleaned up before next cancel barrier | CancelFlagCleanup | Family 2 |
| MC-3 | Cancel during primary scan: primary at index i when cancel fires — verify cgen consistency for threads at all indices | CgenConsistency | Family 2 |
| MC-4 | BAR_HOLDING_SECONDARIES + task handling: secondary tries gomp_barrier_handle_tasks while held — verify it bails out correctly | HoldingRelease, TaskIsolation | Family 3 |
| MC-5 | Team ABA: old team freed, new team at same address, secondary in handle_tasks sees "matching" barrier pointer | TaskIsolation | Family 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Assertion at bar.c:579 (done_final) with stale cancel flags | Run cancel-heavy workload with _LIBGOMP_CHECKING_=1 on kernel < 5.16 |
| TV-2 | Performance degradation from stale BAR_SECONDARY_CANCELLABLE_ARRIVED | Benchmark cancel-heavy regions on old kernels |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Asymmetric MEMMODEL_RELAXED (bar.c:612) vs MEMMODEL_RELEASE (bar.c:120) for fallback flag | Ask author: is this intentional? Does the cancellable path not need flush semantics? |
| CR-2 | TODO at bar.h:238 — author unsure about MEMMODEL_ACQUIRE in gomp_barrier_wait_start | Author should resolve |
| CR-3 | Overly permissive assertion at futex_waitv.h:118-120 (the ??? area) | Assertion accepts both cancel and non-cancel increments — could mask bugs |

## 7. Reference Pointers

- **Core barrier implementation**: `config/linux/bar.c` (908 lines), `config/linux/bar.h` (425 lines)
- **Fallback**: `config/linux/futex_waitv.h` (129 lines)
- **Thread lifecycle**: `team.c` (1232 lines, key: lines 34-50, 86-191, 385-1126, 1133-1225)
- **Task handling**: `task.c` (lines 1551-1743: gomp_barrier_handle_tasks)
- **GCC Bug**: [PR119588](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=119588)
- **Mailing list**: [Patch 3/5](https://gcc.gnu.org/pipermail/gcc-patches/2025-November/702031.html)
- **Full analysis report**: `analysis-report.md` (in this directory)
