# Modeling Brief: libgomp (GCC OpenMP Runtime — Barrier + Tasking)

## 1. System Overview

- **System**: GCC's `libgomp` — OpenMP runtime library shipped with GCC trunk (HEAD: `ab6c415e1`, May 2026).
- **Language**: C, ~7,300 LOC core logic (barrier 215, bar.h 187, task.c 2798, team.c 1125, parallel.c 342, work/iter/loop/sections ~2100, primitives 500).
- **System category**: **Category B (Concurrent / Lock-Free / Runtime)** — atomics + futex + a single per-team `task_lock` mutex coordinate the implicit-task barrier (`bar.c`/`bar.h`), the team-wide task scheduler (`task.c`), and team lifecycle (`team.c`, `parallel.c`). No network, no persistence, no message passing.
- **Reference algorithm**: Centralized "last-arriver wins" barrier — the only OpenMP barrier shipped in mainline as of HEAD. (A "flat barrier" patch series by Matthew Malcomson is in flight but not merged; that is the subject of the separate `libgomp/` case study.)
- **Concurrency model**:
  - One implicit task per team thread. The pthread thread pool docks at `pool->threads_dock` (a `gomp_simple_barrier_t`) between regions.
  - Explicit tasks (`#pragma omp task`) are queued in a single per-team priority queue under `team->task_lock`. Any team thread can drain the queue inside `gomp_barrier_handle_tasks` while waiting at a team barrier.
  - Cancellation (`#pragma omp cancel parallel`) is signalled by setting `BAR_CANCELLED` on `team->barrier.generation`.
  - Detachable tasks (`detach` clause) can be completed by an external (non-OpenMP) thread via `omp_fulfill_event`.
- **Key architectural choices that matter for modelling**:
  1. `bar->generation` is a packed 32-bit field — low 3 bits are flags (`BAR_TASK_PENDING=1`, `BAR_WAITING_FOR_TASK=2`, `BAR_CANCELLED=4`), high bits are a generation counter advanced by `BAR_INCR=8`. The flag bits are mutated under `team->task_lock` via plain RMW (bar.h:132-148); the counter bits are published outside the lock via `__atomic_store_n(..., RELEASE)` (bar.c:104, bar.h:167).
  2. `team->task_count` is read atomically (ACQUIRE) outside `task_lock` from the barrier (bar.c:94, 160), but decremented under `task_lock` — and only the drop-to-zero in `gomp_barrier_handle_tasks` (task.c:1708) uses `__atomic_store_n(..., RELEASE)`. The PR122356 fix made the cross-thread acquire-release pair valid only for that one decrement site.
  3. `pool->last_team` caches the just-ended team to amortize team-struct allocation. The cached team is reused on the next region, **skipping `gomp_barrier_init`** (team.c:175-194); only a subset of fields are re-zeroed.
  4. `gomp_team_barrier_cancel` (bar.c:204-215) sets `BAR_CANCELLED` via a **plain `|=`** under `task_lock` — not an `__atomic_fetch_or`. This is the pre-PR112356 idiom; the analogous race in `gomp_team_barrier_done` was fixed, the cancel write was not.

## 2. Bug Families

### Family 1: Cancel-vs-Publish Race on `bar->generation` (HIGH)

**Mechanism**: `gomp_team_barrier_cancel` sets `BAR_CANCELLED` with a plain load-OR-store under `task_lock`. The atomic RELEASE publishers in `gomp_team_barrier_wait_end` (bar.c:104) and `gomp_team_barrier_done` (bar.h:167) do not take that lock. The two writes race on the same memory word.

Two failure modes have been hand-derived:
- **(A) Lost cancellation.** Cancel arrives, plain read sees `G`; publisher atomically stores `G+BAR_INCR` (stripping `BAR_CANCELLED` per bar.c:102); cancel writes `G | BAR_CANCELLED`, **overwriting** the just-published `G+BAR_INCR`. Counter regresses by one round.
- **(B) Sibling waiter spin-loop.** Non-cancellable `gomp_team_barrier_wait_end` waiters (e.g. at the implicit barrier after `#pragma omp single` inside a `cancel parallel` region) sleep on the old `G`. After the overwrite, `bar->generation = G | BAR_CANCELLED < G+BAR_INCR`, so `gomp_barrier_state_is_incremented(gen, state)` returns false; `do_wait` returns EAGAIN immediately because `*addr != val`; the loop **busy-spins** until the next barrier round restores the counter.

**Evidence**:
- Historical: `gomp_team_barrier_done` was non-atomic until **PR112356** (commit `304d08fea9e` only converted that one site — the cancel `|=` was missed).
- Historical: **PR122356** (Jan 2026, Malcomson, NVIDIA) — added atomic RELEASE on `task_count` zero-store and acknowledged that mixing atomic and plain accesses on the same field "is a data race and hence UB."
- Code analysis: bar.c:204-215 (cancel write); bar.c:100-107 (publisher path that strips `BAR_CANCELLED`); bar.c:166-172 (cancellable-publisher that *retains* `BAR_CANCELLED` — see Family 4); bar.h:150-153 (comment "BAR_CANCELLED should never be set in state here" — informal reasoning).

**Affected code paths**:
- `gomp_team_barrier_cancel` (config/linux/bar.c:204-215) — plain `|=`
- `gomp_team_barrier_wait_end` last-arriver no-task path (config/linux/bar.c:100-107) — atomic RELEASE that strips `BAR_CANCELLED`
- `gomp_team_barrier_done` (config/linux/bar.h:162-169) — atomic RELEASE that strips `BAR_CANCELLED` via `& -BAR_INCR`
- `GOMP_cancel(GOMP_CANCEL_PARALLEL, true)` (parallel.c:235-272) — the only caller of `gomp_team_barrier_cancel`

**Suggested modeling approach**:
- Variables: `barGen[Team]` (counter + flag bits), `awaited[Team]`, `taskCount[Team]`, `taskLockHolder[Team]`.
- Split actions at every atomic access: `BarrierArrive` (decrement `awaited` ACQ_REL), `BarrierPublishNoTask` (atomic RELEASE store), `BarrierPublishDone` (atomic RELEASE store), `CancelReadGen`, `CancelWriteGen` (separate sub-actions to expose the read-modify-write window).
- Granularity: `gomp_team_barrier_cancel` must be split as two actions because the read and the OR-store can be separated by an atomic store from any other thread.
- Key invariant: `barGen[Team]` is monotonically non-decreasing modulo wrap.

**Priority**: High
**Rationale**: New (unfixed) finding directly analogous to a recently-fixed bug (PR112356). The cancel-write path was missed by the recent atomic-conversion pass; the busy-spin failure mode is a real liveness/CPU-burn bug, and the lost-cancellation failure mode is a real OpenMP-semantics violation. TLA+ can mechanically discover both interleavings.

---

### Family 2: Barrier Completion ↔ task_count Handshake (HIGH)

**Mechanism**: The barrier's "last arriver decides whether to drain tasks" depends on a lock-free ACQUIRE-load of `team->task_count` paired against scattered decrements. Two recent PRs (PR122314, PR122356) fixed concrete races in this area; the **invariant** is "after the last `task_count--`, the next entry into `gomp_barrier_handle_tasks` from any team thread reaches the 1617 branch (`task_count == 0 && waiting_for_tasks`) and finalises the barrier." Sibling non-atomic decrements in `GOMP_taskwait`/`GOMP_taskgroup_end`/`gomp_task_maybe_wait_for_dependencies`/`omp_fulfill_event` were *not* converted by PR122356.

**Evidence**:
- Historical: **PR88707** (open since 2018, fixed 2026) — "barrier executes tasks scheduled after said barrier."
- Historical: **PR122314** (Jan 2026) — race condition between barrier completion and subsequent task scheduling; fix introduced `gomp_barrier_state_is_incremented` and the `task_count != 0 && gomp_barrier_has_completed(state, &team->barrier)` guard at task.c:1572.
- Historical: **PR122356** (Jan 2026) — `task_count` decrement-to-zero made atomic RELEASE; `bar->generation` store in `gomp_team_barrier_done` made atomic RELEASE.
- Code analysis: task.c:1562-1571 (developer comment acknowledging the non-atomic-load of `bar->generation` as a "conflict" only saved by `task_count != 0`); task.c:1708-1711 (asymmetric atomic-vs-plain decrement); bar.c:94/160 (ACQUIRE-load of `task_count`); the four other decrement sites at task.c:1870/2172/2382/2762.

**Affected code paths**:
- `gomp_barrier_handle_tasks` (task.c:1551-1714)
- `gomp_team_barrier_wait_end` task path (config/linux/bar.c:93-107) — and same for `wait_cancel_end` (bar.c:159-172)
- `GOMP_taskwait` decrement at task.c:1870
- `gomp_task_maybe_wait_for_dependencies` decrement at task.c:2172
- `GOMP_taskgroup_end` decrement at task.c:2382
- `omp_fulfill_event` decrement at task.c:2762

**Suggested modeling approach**:
- Variables: `taskQueue[Team]`, `taskCount[Team]`, `taskRunningCount[Team]`, `taskQueuedCount[Team]`, `barGen[Team]` (with flag bits separated), `awaited[Team]`, `taskLockHolder[Team]`.
- Split actions at every atomic boundary:
  - `BarrierArriveAndDecrAwaited` (atomic ACQ_REL on `awaited`)
  - `BarrierLastReadTaskCount` (atomic ACQUIRE on `task_count`)
  - `HandleTasksCheckCompleted` (non-atomic read of `bar->generation`)
  - `HandleTasksDecTaskCount` (under lock; atomic RELEASE only on zero-transition)
  - `BarrierFinalDone` (atomic RELEASE store)
- Granularity for explicit-task creation in `GOMP_task`:
  - `EnqueueTask` (under lock; ++task_count, ++task_queued_count, set BAR_TASK_PENDING)
  - `WakeAfterEnqueue` (unlock then wake)
- Granularity for task completion in `gomp_barrier_handle_tasks`:
  - `DequeueAndRunTask` (under lock; ++task_running_count, unlock, run fn, relock)
  - `FinishTask` (under lock; --task_running_count; either plain --task_count or atomic-RELEASE store-zero)

**Proposed invariants**:
- `taskCount[t] = 0  =>  eventually some thread observes BAR_INCR has been added to bar->generation` (liveness)
- `bar->generation observed by waiter via ACQUIRE => writes-before-publish on task->fn user data are visible` (memory ordering — but TLA+ models SC; this becomes a sequential consistency check)
- `at most one thread reaches the BarrierPublishDone action per round`

**Priority**: High
**Rationale**: Two recent CVEs-in-effect (PR122314, PR122356) plus a 7-year-old open companion (PR88707). The fix surface area is large, the invariant is non-local, and the asymmetric atomic/plain decrement remains in four other paths. New unaudited mechanism question: can a `GOMP_taskwait`/`GOMP_taskgroup_end`-driven decrement complete *while* the barrier ACQUIRE-read is in flight, such that the barrier sees a stale non-zero `task_count` even though all tasks are done?

---

### Family 3: Detached Task / `omp_fulfill_event` Lifetime (HIGH)

**Mechanism**: A deferred-detach task ends its body but cannot finish until an external thread calls `omp_fulfill_event`. The task is queued as `GOMP_TASK_DETACHED` (task.c:1678-1680, 1843, 2365), incrementing `task_detach_count`. `omp_fulfill_event` (task.c:2724-2796) loads `task->detach_team` RELAXED, locks the team, releases the task back to the dependers/parent/taskgroup/team-barrier, and frees the task.

Three sub-mechanisms that can fail:
1. **Stale `detach_team` pointer**: the RELAXED load + lock-acquire pair is the *only* synchronisation between the fulfilling thread and the team's lifetime.
2. **Asymmetric double-unlock**: `omp_fulfill_event` releases `task_lock` either before *or* after `gomp_team_barrier_wake`, depending on `shackled_thread_p` (task.c:2787-2792). The non-shackled (external) thread keeps the lock across the wake to prevent the team from being freed.
3. **Last-detach must-wake**: task.c:2776-2782 wakes the barrier if "no other wake, no remaining detaches, barrier waiting." If this guard is wrong, the team barrier hangs forever.

**Evidence**:
- Historical: **PR98738** (Jan 2021) — "task-detach-6.f90 hangs intermittently." Major refactor: introduced `GOMP_TASK_DETACHED` kind, `detach_team` field, `task_detach_count` counter.
- Historical: commit `ba886d0c488` — `omp_fulfill_event` was failing to wake the barrier when new dependents were unblocked. Added `gomp_team_barrier_set_task_pending`.
- Historical: **PR113627** (Jan 2024, **STILL OPEN/UNCONFIRMED**) — "Detached tasks released without call to omp_fulfill_event"; threshold-dependent (65+ iterations on 1 thread, 129+ on 2 threads), suggests overflow or counter wrap related to task scheduling, not a deterministic bug.
- Historical: commit `0af7ef050ae` (PR104385) — "segfault with posthumous orphan tasks": a child task is added to the depender queues with `task->parent` pointing to a freed parent.
- Code analysis: task.c:2738-2754 (RELAXED detach_team load + lock-acquire); task.c:2787-2792 (asymmetric double-unlock around wake); task.c:2776-2782 (last-detach wake guard); the comment at task.c:2784-2786 explicitly says "team-lifetime."

**Affected code paths**:
- `omp_fulfill_event` (task.c:2724-2796)
- `gomp_barrier_handle_tasks` detach-arm (task.c:1675-1687)
- `GOMP_taskwait` detach-arm (task.c:1839-1850)
- `GOMP_taskgroup_end` detach-arm (task.c:2361-2372)
- `gomp_task_run_post_handle_dependers` and `gomp_task_run_post_remove_parent` (task.c:1480-1518; relevant to PR104385-style orphaned-task crashes)

**Suggested modeling approach**:
- Variables: `taskState[Task] ∈ {WAITING, RUNNING, DETACHED, COMPLETED}`, `taskDetachCount[Team]`, `detachTeam[Task]` (pointer-or-NULL), `dependers[Task]` (set), `fulfillerThread` (an "external" thread without team membership).
- Actions:
  - `RunDetachableTask` — body finishes, task transitions WAITING → DETACHED, taskDetachCount++.
  - `FulfillFromInternalThread` — shackled call, releases lock before wake.
  - `FulfillFromExternalThread` — non-shackled, keeps lock across wake.
  - `LastDetachWake` — encode the task.c:2776-2782 guard precisely.
  - `BarrierFinaliseWhileDetachOutstanding` — model the scenario in PR113627 (dependent task released before fulfill).
- Granularity: `omp_fulfill_event` should be 4-5 separate actions because of the lock-drop window and asymmetric unlock branches.

**Proposed invariants**:
- `\A t \in tasks : DependentsOf(t) released => t.state \in {COMPLETED, DETACHED+fulfilled}` (the PR113627 violation)
- `taskDetachCount[team] == 0 \/ \E t : t.state == DETACHED \land detachTeam[t] == team`
- `BarrierWaitingForTasks(team) => eventually some thread reaches the 1617 branch of gomp_barrier_handle_tasks` (liveness)

**Priority**: High
**Rationale**: One **open** unconfirmed bug (PR113627) and a 5-year history of subtle fixes (PR98738, the `ba886d0c488` wake-up fix). The detach lifecycle is exactly the kind of "ownership transfer across threads + completion ordering" pattern that the concurrent-analysis playbook flags as a top concern. PR113627's threshold dependence (>64 iterations) strongly suggests a scheduling-counter / queue-state interaction that TLA+ should be able to surface.

---

### Family 4: Cached Team Reuse via `pool->last_team` (MEDIUM)

**Mechanism**: `gomp_team_end` caches the just-ended team in `pool->last_team` (team.c:1010-1012). `gomp_new_team` (called at the next region) reuses it via `get_last_team` (team.c:150-165) **without** reinitialising the barrier or task_lock. Meanwhile, a secondary thread that was running tasks inside `gomp_barrier_handle_tasks` for the *previous* region may still hold a captured `team`/`bar` pointer; if that secondary observes the now-stale team after a new region has begun, it can attempt to drain the new region's task queue.

The defense (task.c:1562-1577 + 1572) is the `task_count != 0 && gomp_barrier_has_completed(state, &team->barrier)` early-exit. Correctness relies on:
- the new region's `gomp_new_team` resets `task_count = 0` (team.c:214) — true;
- the secondary's captured `state` predates the new region's first generation, so `gomp_barrier_has_completed` returns true — true *if the counter has not wrapped*.

The barrier's `bar->generation` and `awaited_final` are not reset on cached reuse; only `work_share_cancelled` and `team_cancelled` are (team.c:217-218).

**Evidence**:
- Historical: This is the documented "race comment" cited in `task.c:1562-1571` (PR122314 fix area).
- Historical: The libgomp_2 case study (Malcomson flat-barrier patches) flagged this as Family 4 ("Team Reassignment Race / ABA-dependent defense").
- Code analysis: team.c:175-194 (cached-reuse path skips `gomp_barrier_init`); team.c:213-220 (per-region resets — note `barrier.generation` is NOT reset); task.c:1572 (the only defense against ABA).

**Affected code paths**:
- `gomp_new_team` cached-reuse path (team.c:175-194)
- `gomp_team_end` caching (team.c:1004-1014)
- `gomp_barrier_handle_tasks` early-exit guard (task.c:1562-1577)

**Suggested modeling approach**:
- Variables: `teamGeneration[Team]` (a sequence number incremented on team reuse, NOT the same as `barGen`), `secondaryViewTeam[Thread]` (cached team pointer), `secondaryViewState[Thread]` (cached barrier state).
- Actions:
  - `SecondaryEnterHandleTasks` — captures team/state.
  - `PrimaryEndRegion` — caches team.
  - `PrimaryStartNewRegion` — reuses cached team; new generation.
  - `SecondaryCheckCompleted` — reads current bar->generation, compares with cached state.
- Key edge: model what happens when the secondary's captured `state` IS the same as the new region's initial `state` (because the cache reused the team and counter never reset). The `gomp_barrier_has_completed` check would falsely return false, and the secondary would proceed to drain the new region's queue.

**Proposed invariants**:
- `\A thr, t : if thr's captured team == t and t has been reused, then thr observes either task_count == 0 OR has_completed(thr.state, t.barrier)` (this is what the code is trying to guarantee; modeling it tests whether the guarantee actually holds).

**Priority**: Medium
**Rationale**: Documented race-comment in the code. The defense is fragile (single-condition check) and depends on the previous region's barrier having strictly fewer rounds than the next region observes — non-trivial under generation wrap (Family 5).

---

### Family 5: Generation Wrap & Flag-bit Edge Cases (LOW-MEDIUM)

**Mechanism**: `bar->generation` is a 32-bit packed counter+flags. `gomp_barrier_state_is_incremented` (bar.h:171-177) handles unsigned wrap with `next_state > state ? gen >= next_state : gen < state`. With BAR_INCR=8 and a 32-bit counter, wrap occurs every 2^29 = 536M rounds — reachable in long-running HPC programs (~9 minutes at 1M barriers/s).

A second hazard: `gomp_team_barrier_wait_final_start` (bar.h:113-121) returns `state` with mask `-BAR_INCR | BAR_CANCELLED`, so `state` can carry `BAR_CANCELLED`. Subsequent `gomp_team_barrier_wait_end` then conditionally strips it. The cancellable variant `gomp_team_barrier_wait_cancel_end` (bar.c:166-172) **does not strip** `BAR_CANCELLED` on the no-task last-arriver publish, relying on the informal claim at bar.c:150-153 ("BAR_CANCELLED should never be set in state here"). The claim is *not* enforced by any check — if both `BAR_CANCELLED` and `BAR_WAS_LAST` are set in state, the cancellable publish would carry `BAR_CANCELLED` forward to the next round.

**Evidence**:
- Code analysis: bar.h:171-177 (wrap handling); bar.c:150-153 (informal correctness claim); bar.c:166-172 (cancellable publish that retains `BAR_CANCELLED`).

**Affected code paths**:
- `gomp_barrier_state_is_incremented` (bar.h:171-177)
- `gomp_team_barrier_wait_cancel_end` no-task path (bar.c:166-172)

**Suggested modeling approach**:
- Use a small bounded counter (3-4 bits + flags) so the wrap point is reachable in MC.
- Add a `ForceCancelDuringFinalBarrier` action to exercise the claim "BAR_CANCELLED never set in state here."

**Priority**: Low-Medium
**Rationale**: Wrap is a sanity-check (likely correct). The informal-claim hazard is more interesting but bounded by current call patterns. Worth a check, not a deep investment.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| `bar->generation` flag bits as separate variables | All families touch them | `barCounter[T]`, `barTaskPending[T] ∈ BOOLEAN`, `barWaitingForTask[T] ∈ BOOLEAN`, `barCancelled[T] ∈ BOOLEAN` |
| `gomp_team_barrier_cancel` as 3 actions | Family 1: expose the load-modify-store window | `CancelLoadGen`, `CancelOrAndStoreGen`, `CancelFutexWake` |
| Cancellable vs non-cancellable wait variants | Family 1, Family 5 | Two distinct `BarrierLastArriverPublish` actions |
| `task_count` as atomic counter with separate atomic/plain decrement actions | Family 2 | `DecrTaskCountAtomic` (release store-to-zero) vs `DecrTaskCountPlain` |
| `gomp_barrier_handle_tasks` 3 early-exit branches | Family 2 liveness | `HandleTasksExitTaskCompleted` (task.c:1575), `HandleTasksExitImmediateDone` (1584), `HandleTasksExitDrainDone` (1620) |
| `omp_fulfill_event` shackled vs non-shackled paths | Family 3 | Two distinct fulfill actions; an "external thread" with no `ts.team` |
| `detach_team` RELAXED load + lock-acquire | Family 3 | Two actions: `FulfillLoadDetachTeam`, `FulfillAcquireLock` |
| `task_detach_count` ↔ barrier wake handshake | Family 3 last-detach guard | Model the precise task.c:2776-2782 guard predicate |
| `pool->last_team` caching | Family 4 | A "team alive" / "team cached" / "team reused" lifecycle state |
| Generation wrap with small counter | Family 5 | Bound counter to 4-6 bits to make wrap MC-reachable |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Affinity / `proc_bind` / numa placement | Pure performance; team.c:392-739 ~350 LoC of bookkeeping with no protocol-level state machine. |
| Allocator (`alloc.c`, allocator.c, basic-allocator.c) | Out of scope; relies on libc. |
| Offloading (`target.c`, `oacc-*`, plugin/*) | Different lifecycle; not part of host barrier+tasking. |
| `gomp_resolve_num_threads` underflow (parallel.c:105-122) | Test-verifiable via stress test; pure arithmetic, no protocol interaction. |
| `gomp_sem_post` chained-wake liveness (sem.h:66-85) | Depends on scheduler fairness; not a TLA+ safety property. |
| `critical.c` thread-fence asymmetry | Memory-ordering issue below TLA+ abstraction level. |
| Plain RMW on `bar.h:135/141/147` (`set_task_pending` etc.) | Defended by `task_lock` + disjoint-phase argument; not a useful MC target. |
| Reproducing the PR122356 commit (atomic store-zero of task_count) | Already fixed in mainline; per `bug-archaeology.md` §1.4, target-painting closed bugs adds no value. |
| Reproducing PR122314 (`gomp_barrier_has_completed` guard) | Same — already fixed. Reference only. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Packed generation flags | `barCounter[T]`, `barTaskPending[T]`, `barWaitingForTask[T]`, `barCancelled[T]` | Express the bit-packed state separately for clarity | All |
| Plain RMW cancel | `cancelInProgress[T] ∈ BOOLEAN` (intermediate state) | Expose Family 1 read-modify-store window | 1 |
| Asymmetric task_count writers | `taskCount[T]`, plus `taskCountWriterPath[T] ∈ {atomic, plain}` per write | Family 2 unaudited paths | 2 |
| Detach state machine | `detachTeam[Task]`, `taskDetachCount[T]`, `externalFulfiller` (an extra Thread without team membership) | Family 3 | 3 |
| Team lifecycle | `teamPhase[T] ∈ {alloc, active, cached, reused, freed}`, `cachedAt[Pool]` | Family 4 ABA | 4 |
| Bounded generation counter | parameter `MaxGen` for wrap | Family 5 | 5 |
| Stale secondary view | `secondaryCapturedTeam[Thread]`, `secondaryCapturedState[Thread]` | Family 4 | 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| BarrierProgress | Liveness | After all N threads call `gomp_team_barrier_wait`, eventually `barCounter` advances | Family 2 (basic) |
| CancelEventuallyObserved | Liveness | After `GOMP_cancel(GOMP_CANCEL_PARALLEL)`, eventually every team thread's next cancellable barrier observes `BAR_CANCELLED` | Family 1 (lost-cancel mode A) |
| GenerationMonotone | Safety | `barCounter[T]` is monotone non-decreasing (modulo wrap) | Family 1 (counter-regress mode B) |
| TaskCountConsistency | Safety | When the barrier's ACQUIRE-load sees `task_count == 0`, no live `gomp_task` body is still writing user data without a happens-before to that load | Family 2 |
| DetachCompletion | Safety | A task with `dependers != ∅` cannot have its dependers released until either (a) its body completed and the task was non-detached, or (b) `omp_fulfill_event` was called | Family 3 (PR113627 scenario) |
| DetachWake | Liveness | The last `omp_fulfill_event` that drops `task_detach_count` to zero must wake every blocked team barrier | Family 3 (task.c:2776-2782 guard) |
| NoStaleTeamRead | Safety | A secondary in `gomp_barrier_handle_tasks` whose captured `team`/`bar` belongs to a previous region must early-exit before it dequeues any task from the reused team | Family 4 |
| NoStrandedCancel | Safety | If `gomp_team_barrier_cancel` was called and concurrent publishers exist, the resulting `bar->generation` is *either* in the "incremented" state for non-cancellable consumers *or* has `BAR_CANCELLED` set for cancellable consumers — never neither | Family 1 (composes A+B) |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC1 | Cancel-vs-publish race: cancel's plain `\|=` overwrites the just-published atomic store, regressing the counter | `GenerationMonotone` and/or busy-spin liveness in non-cancellable waiter | 1 |
| MC2 | Cancel-vs-publish race: cancel arrives first, publisher strips `BAR_CANCELLED`, observers in `GOMP_cancellation_point` miss the cancellation | `CancelEventuallyObserved` | 1 |
| MC3 | The `task_count != 0 && has_completed(state, bar)` guard at task.c:1572 may fail when a secondary holds a stale pre-reuse `state` and the new team starts with `task_count = 0` then quickly enqueues a task | `NoStaleTeamRead` | 4 |
| MC4 | A plain `--task_count` from `GOMP_taskgroup_end`/`GOMP_taskwait`/`gomp_task_maybe_wait_for_dependencies` is concurrent with the barrier ACQUIRE-load — is there any window where this can race? (Unaudited.) | `TaskCountConsistency` | 2 |
| MC5 | PR113627 mechanism — a detach-dependent task is released before `omp_fulfill_event` fires; threshold-dependent, suggests an off-by-one or queue-traversal bug in `gomp_task_run_post_handle_dependers` interaction with `GOMP_TASK_DETACHED` | `DetachCompletion` | 3 |
| MC6 | `omp_fulfill_event` last-fulfill guard (task.c:2776-2782) — under what interleaving with other `task_running_count` updates and barrier waits can the wake be skipped? | `DetachWake` | 3 |
| MC7 | Cancellable wait_end no-task path (bar.c:166-172) does not strip `BAR_CANCELLED`. Can a thread reach this code with `state & (BAR_CANCELLED \| BAR_WAS_LAST)` both set? | `NoStrandedCancel` | 1, 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T1 | Stale `team->ordered_release[]` semaphore posts survive `nowait + ordered + cancel` and poison the next loop | Three-thread test: cancel-in-flight + `omp for ordered nowait`; observe wrong ordering across the next region |
| T2 | `gomp_resolve_num_threads` unsigned underflow in nested-teams stress (parallel.c:105-122) | Nested-parallel stress test exceeding `thread_limit_var` repeatedly |
| T3 | TSAN of `ordered.c:206-221` dirty read of `ws->ordered_owner` | Run libgomp testsuite under `-fsanitize=thread` |
| T4 | TSAN of `gomp_team_barrier_cancel` plain `\|=` (Family 1) and sibling plain RMWs on `bar->generation` | Same |
| T5 | Test detached-task threshold from PR113627 (`OMP_NUM_THREADS=1 ./repro -t 65`) on current trunk to confirm reproducibility | Direct reproduction |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | Asymmetric atomic vs plain `--task_count` (only `gomp_barrier_handle_tasks` uses atomic RELEASE; four other decrement sites use plain) | Convert all decrement sites to RELEASE on zero-transition or document why not |
| CR2 | `gomp_team_barrier_cancel` should be `__atomic_fetch_or(generation, BAR_CANCELLED, RELEASE)` instead of plain `\|=` (the Family 1 fix) | Propose patch |
| CR3 | `set_task_pending`/`clear_task_pending`/`set_waiting_for_tasks` (bar.h:135/141/147) use plain RMW while sharing a memory word with atomic operations — formal C11 data race | Convert to `__atomic_fetch_or`/`__atomic_and_fetch` |
| CR4 | `gomp_team_barrier_done` cancellable variant (bar.c:166-172) does not strip `BAR_CANCELLED`; comment at bar.c:150-153 is informal | Either add an assertion or strip the bit unconditionally |
| CR5 | `do_wake` carried across lock-drop windows in `gomp_barrier_handle_tasks` may produce stale wake counts | Document or recompute under-lock |
| CR6 | Sibling `team->task_count--` paths in taskwait/taskgroup_end/etc. risk re-introducing PR122356 if a future patch makes the barrier path drop `task_lock` earlier | Add a comment or invariant test |
| CR7 | `pool->last_team` cache reuse skips `bar->generation` reset (team.c:175-194) — relies entirely on the task.c:1572 ABA defense | Either reset `barrier.generation` on reuse or document the contract |
| CR8 | `gomp_resolve_num_threads` busy-counter underflow on nested teams (parallel.c:105-115) | Bound-check before subtraction |
| CR9 | `nowait + ordered + cancel` leaves stale `ordered_release[]` posts (work.c:287-320, ordered.c) | Add a drain step in `gomp_work_share_end_nowait` |
| CR10 | `team.c:142-146` idle-loop self-exit sequences `gomp_sem_destroy → pthread_detach → thread_pool = NULL`; double-free protection depends on the pthread not exiting before `thread_pool = NULL` is durable | Add a comment justifying or reorder |

## 7. Reference Pointers

- **Full analysis report**: `.specula-output/analysis-report.md`
- **Per-file findings**:
  - `.specula-output/findings-barrier.md` — bar.c/bar.h/mutex/sem/ptrlock state-machine
  - `.specula-output/findings-task.md` — task.c (2798 lines) memory-ordering bridges and lock-drop windows
  - `.specula-output/findings-team.md` — team.c/parallel.c thread-pool, cached-team, cancel-bit lifecycle
  - `.specula-output/findings-workshare.md` — work.c/iter.c/loop.c/sections.c/ordered.c
- **Key source files** (under `artifact/gcc/libgomp/`):
  - `config/linux/bar.c` (215 lines, core barrier)
  - `config/linux/bar.h` (187 lines, packed state machine)
  - `config/linux/wait.h`, `mutex.c/h`, `sem.c/h`, `ptrlock.c/h` (~500 lines, primitives)
  - `task.c` (2798 lines, tasking/dependencies/detach/`gomp_barrier_handle_tasks`)
  - `team.c` (1125 lines, lifecycle/dock)
  - `parallel.c` (342 lines, `GOMP_parallel*`, `GOMP_cancel`)
  - `barrier.c` (54 lines, the public `GOMP_barrier` shim)
- **GCC Bugzilla PRs (cited)**: PR88707 (Family 2), PR98738 (Family 3), PR104385 (Family 3 supplement), PR105378 (Family 2), PR112356 (Family 1 reference), PR113627 (Family 3, **OPEN**), PR122314 (Family 2), PR122356 (Family 2)
- **Recent fix commits**: `304d08fea9e` (PR122356, Jan 2026), `8a47ae5c193` (PR122314+PR88707, Jan 2026), `0af7ef050ae` (PR104385, Feb 2022), `c125f504c43` (taskwait nowait depend, May 2022), `ba886d0c488` (fulfill-event wake, May 2021), `d656bfda2d8` (PR98738, Jan 2021)
- **Reference docs**:
  - GCC libgomp barrier overview: `https://gcc.gnu.org/onlinedocs/libgomp/Implementing-BARRIER-construct.html`
  - OpenMP 5.2 specification (cancel + detach semantics)
