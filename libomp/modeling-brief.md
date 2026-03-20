# Modeling Brief: LLVM libomp (OpenMP Barrier + Tasking)

## 1. System Overview

- **System**: LLVM libomp — C/C++ OpenMP runtime library (part of llvm/llvm-project)
- **Language**: C/C++, ~15,000 LOC core logic (barrier + tasking + deps + wait/release)
- **Protocol**: OpenMP 5.x barrier synchronization with work-stealing task scheduler
- **Key architectural choices**:
  - 5 barrier algorithms: linear, tree, hyper, hierarchical, distributed — selectable at runtime
  - Per-thread task deques with work-stealing (owner pops tail/LIFO, thief steals head/FIFO)
  - Dual task team parity: `t_task_team[0]`/`t_task_team[1]` alternating via `th_task_state` toggle
  - Detachable tasks with async `omp_fulfill_event` from non-OpenMP threads
  - Hidden helper thread pool for offload tasks
  - Counter-based synchronization: `td_incomplete_child_tasks` (per-task), `tt_unfinished_threads` (per-barrier)
- **Concurrency model**: N worker threads + 1 primary thread per team; bootstrap locks on task deques; atomic counters for completion; TCR/TCW macros (plain reads/writes, no CPU fences) for cross-thread signaling

## 2. Bug Families

### Family 1: Task Team State Parity Corruption (HIGH)

**Mechanism**: The `th_task_state` 0/1 toggle selects which `t_task_team[N]` slot is "current." Nested serial parallel regions, detached tasks, and hidden helper tasks cause parity to become misaligned between threads, leading to workers and primary using different task teams — corrupting `tt_unfinished_threads` tracking and causing deadlocks or assertion failures.

**Evidence**:
- Historical: Issue #50602 — assertion triggered: serialized parallel + detached task (OPEN, 4+ years)
- Historical: Issue #59190 — hang without hot teams: workers get `th_task_state=0`, primary keeps 1 (OPEN)
- Historical: Issue #69733, #56307, #79416 — `th_task_team` inconsistency assertions (CLOSED, partial fixes)
- Historical: Issue #81488 — assertion failure with `OMP_NUM_THREADS=1` + target nowait (OPEN)
- Historical: Commit `41ca9104ac` — major refactoring of serial team task teams (PR #86859, fixed 4 issues)
- Historical: Commit `41f148e61d` — `th_task_state_memo_stack` fix for proxy/helper tasks
- Historical: Commit `54127981be` — refactor of task_team code
- Code analysis: `kmp.h:3035-3037` — `th_task_team`, `th_current_task`, `th_task_state` are plain (non-atomic, non-volatile) fields in the same cache line with no ordering guarantees

**Affected code paths**:
- `__kmp_task_team_setup()` (kmp_tasking.cpp:3935) — primary thread allocates/initializes
- `__kmp_task_team_sync()` (kmp_tasking.cpp:4020) — workers toggle parity after barrier
- `__kmp_task_team_wait()` (kmp_tasking.cpp:4046) — primary waits for `tt_unfinished_threads==0`
- `__kmp_serialized_parallel()` (kmp_runtime.cpp) — serial team reuse breaks parity

**Suggested modeling approach**:
- Variables: `taskTeamSlot[thread] \in {0, 1}`, `taskTeam[team][0..1]`, `unfinishedThreads[team][0..1]`
- Actions: `BarrierGather`, `BarrierRelease`, `TaskTeamSync` (toggle slot), `TaskTeamSetup` (initialize next slot)
- Model nested serial parallel regions that reuse the same team structure
- Key invariant: all threads in a team must agree on which task team slot is "current"

**Priority**: High
**Rationale**: 6+ historical bugs, 3 still open. Systemic design defect acknowledged by Intel engineer. TLA+ well-suited: the parity protocol is a small state machine with subtle invariants.

---

### Family 2: Task Stealing During Team Transitions (HIGH)

**Mechanism**: When nested parallel regions end or teams resize, task-stealing threads read stale thread metadata (tid, team pointer, task_team) from victim threads that have already transitioned to a different context.

**Evidence**:
- Historical: D28377 / commit `581490e713` — race in shutdown: stealing thread accesses reaped thread
- Historical: Issue #87307 / PR #87309 — nested parallel tid race: primary resets tid, stealer reads stale value
- Historical: Issue #94260 / PR #95823 — `victim_tid < tt_nproc` assertion fails during steal
- Historical: Issue #156741, #176451 — `issue-94260-2.c` test still segfaults sporadically (OPEN)
- Historical: Commit `a4a9c48c78` — stealer reads NULL `current_task` from freed thread
- Historical: Commit `a764af68be` — `th_blocking` flag: threads spin-waiting during shutdown access freed resources
- Code analysis: kmp_tasking.cpp:3334-3338 — comment explicitly warns: "unsafe to reference thread->th.th_team" after decrementing `tt_unfinished_threads`
- Code analysis: kmp_barrier.cpp:2349-2352 — comment: "team data structure may be deallocated at any time by the primary thread"

**Affected code paths**:
- `__kmp_steal_task()` (kmp_tasking.cpp:3011) — reads victim's deque, tid, task_team
- `__kmp_execute_tasks_template()` (kmp_tasking.cpp:3152) — main stealing loop, decrement logic
- `__kmp_join_barrier()` (kmp_barrier.cpp:2205) — primary frees team while workers still active
- `__kmp_fork_barrier()` (kmp_barrier.cpp:2445) — workers read team pointer after release

**Suggested modeling approach**:
- Variables: `threadState[t] \in {"active", "transitioning", "reaped"}`, `teamValid[team] \in BOOLEAN`
- Actions: `StealTask(thief, victim)` — check victim state, `EndNestedParallel` — transition primary tid, `ReapThread` — free thread resources
- Key: model the window between `tt_unfinished_threads` decrement and team deallocation
- Invariant: no thread accesses team/victim data after team is freed

**Priority**: High
**Rationale**: 6+ historical bugs spanning 2017-2025, at least 2 still open. The pattern recurs because libomp's team lifecycle and task stealing have overlapping lifetimes. TLA+ can explore the interleaving space.

---

### Family 3: Detachable Task Completion Protocol (MEDIUM-HIGH)

**Mechanism**: Detachable tasks have a three-phase lifecycle (execute → detach → fulfill) where the task's ownership transfers from the executing thread to the fulfilling thread. Race conditions arise in the ordering of flag writes, counter decrements, and memory access relative to the ownership transfer point.

**Evidence**:
- Historical: Commit `d23131a3c0` — race: `__kmp_task_finish` accesses taskdata AFTER signaling ownership transfer via `proxy = TASK_PROXY`
- Historical: Commit `3c76e99291` — deadlock: detachable task with children — `td_incomplete_child_tasks` used as both child counter and proxy flag, causing confusion
- Historical: Commit `57d8b8d6f0` — hang: serialized detachable task never decrements child counter
- Historical: Commit `3c31b78455` — taskwait ignores detachable tasks: `tt_found_proxy_tasks` not set
- Historical: Issue #48410 — `omp_fulfill_event` deadlock with dependent child tasks
- Historical: Issue #49969 — memory leak: task team never freed for detachable tasks (OPEN)
- Code analysis: kmp_tasking.cpp:898-901 — comment says "no access to taskdata after this point" but line 901 writes `taskdata->td_flags.proxy`
- Code analysis: kmp_tasking.cpp:4378-4420 — `__kmp_fulfill_event` acquires TAS lock with `gtid=-2` for non-OpenMP threads; lock correctness depends on `KMP_LOCK_BUSY(-1, tas) != KMP_LOCK_FREE(tas)` — fragile boundary

**Affected code paths**:
- `__kmp_task_finish()` (kmp_tasking.cpp:799) — detach path at lines 879-906
- `__kmp_fulfill_event()` (kmp_tasking.cpp:4378) — ownership transfer
- `__kmp_second_top_half_finish_proxy()` (kmp_tasking.cpp:4222) — deferred completion
- `__kmp_proxy_task_completed_ooo()` (kmp_tasking.cpp:4259) — out-of-order completion

**Suggested modeling approach**:
- Variables: `taskPhase[task] \in {"executing", "detached", "fulfilled", "completed"}`, `childCount[task] \in Nat`, `proxyFlag[task] \in BOOLEAN`
- Actions: `DetachTask` (set proxy, clear executing), `FulfillEvent` (decrement parent counter, schedule bottom-half), `BottomHalfFinish` (mark complete, free)
- Key: model the ownership transfer — once `proxy = TASK_PROXY`, only the fulfiller thread may access taskdata
- Invariant: no thread accesses taskdata after proxy is set and lock is released

**Priority**: Medium-High
**Rationale**: 6 historical bugs, 1 open memory leak. The protocol is complex and has bitten the codebase repeatedly. Well-suited for TLA+ since the state machine is small but the interleaving space is dangerous.

---

### Family 4: Stack-Allocated Depnode Use-After-Free (MEDIUM)

**Mechanism**: `__kmpc_omp_taskwait_deps_51` allocates a `kmp_depnode_t` on the stack. After waiting for `npredecessors` to reach zero, the function returns and the stack frame is freed. A thread that just decremented `npredecessors` still holds a reference (`nrefs`) and accesses the freed stack memory.

**Evidence**:
- Historical: Commit `b999e631c0` / PR #86130 — nrefs drain wait added to prevent stack-use-after-return
- Historical: Commit `2fdf191e24` / PR #126049 — same race on early-return path; bit-0 "on_stack" marker added
- Historical: Issue #85963, #176451 — sporadic crashes on s390x and aarch64
- Code analysis: kmp_taskdeps.cpp:1031-1036, 1055-1060 — nrefs drain loops use implicit seq_cst load, hot-spinning with `KMP_YIELD`

**Affected code paths**:
- `__kmpc_omp_taskwait_deps_51()` (kmp_taskdeps.cpp:917) — stack-allocates depnode
- `__kmp_check_deps()` (kmp_taskdeps.cpp:999) — links depnode as predecessor
- `__kmp_release_deps()` (kmp_taskdeps.h) — decrements nrefs on completion
- `__kmp_node_deref()` (kmp_taskdeps.h) — final deref, checks bit-0 for stack marker

**Suggested modeling approach**:
- Variables: `nodeAllocated[node] \in {"stack", "heap", "freed"}`, `nrefs[node] \in Nat`
- Actions: `TaskwaitDeps` (allocate stack node, link deps), `ReleaseNode` (decrement nrefs), `ReturnFromTaskwait` (free stack if nrefs drained)
- Invariant: no thread accesses a node after its allocation is freed

**Priority**: Medium
**Rationale**: 2 historical bugs with targeted fixes. The fixes are fragile (busy-wait on refcount). TLA+ can verify the nrefs drain protocol is complete on all paths.

---

### Family 5: Barrier Algorithm Inconsistencies (MEDIUM)

**Mechanism**: The 5 barrier algorithms handle edge cases differently — cancellation forces a fallback to linear, distributed barrier deadlocks with passive wait policy, hierarchical barrier has endian-dependent byte indexing. These inconsistencies create correctness issues on non-default configurations.

**Evidence**:
- Historical: Issue #80664 / PR #83058 — distributed barrier + passive wait deadlock (FIXED)
- Historical: Issue #116215 / PR #117073 — hierarchical barrier endian bug on s390x (OPEN)
- Historical: Issue #77575 — `tskm_extra_barrier` mode: `tt_unfinished_threads` goes to -1 (OPEN)
- Historical: Commit `4fe17ada55` — hierarchical barrier offset calculation fix
- Historical: PR #143455 — `KMP_TASKING=1` (task barrier mode) was completely broken
- Code analysis: kmp_barrier.cpp:1915-1917 — cancellation hardcodes linear barrier regardless of configured pattern
- Code analysis: kmp_barrier.cpp:1695-1726 — hierarchical release uses non-atomic `b_go |=` that could race with child's byte-store
- Code analysis: kmp_barrier.cpp:4.1 — after cancelled barrier, `task_team_setup` was called but `task_team_wait`/`task_team_sync` are skipped, potentially misaligning parity

**Affected code paths**:
- `__kmp_barrier_template<cancellable>()` (kmp_barrier.cpp:1792) — dispatch to algorithm
- `__kmp_hierarchical_barrier_release()` (kmp_barrier.cpp:1552) — byte-level `b_go` manipulation
- `__kmp_dist_barrier_release()` (kmp_barrier.cpp:400) — `th_used_in_team` state machine

**Suggested modeling approach**:
- Model 2-3 barrier algorithms (linear + distributed) as separate action variants
- Variables: `barrierAlgo \in {"linear", "distributed"}`, `arrived[thread]`, `go[thread]`
- Add cancellation as a non-deterministic event during gather phase
- Key: verify that parity is consistent after cancellation regardless of barrier algorithm

**Priority**: Medium
**Rationale**: Multiple historical bugs across different algorithms. The cancellation + parity interaction (Finding 4.1) is the most model-checkable aspect.

---

### Family 6: Priority Task Deque Race (LOW-MEDIUM)

**Mechanism**: Priority task deques use a CAS-based "reservation" followed by a linear search through priority deque lists. If another thread consumes the reserved task between the CAS and the dequeue, the search exhausts all lists and dereferences NULL.

**Evidence**:
- Code analysis: kmp_tasking.cpp:2866-2877 — `__kmp_get_priority_task`: `KMP_ASSERT(list != NULL)` can fire when CAS reserves a task that another thread already consumed
- Code analysis: kmp_tasking.cpp:2851-2857 — CAS on `tt_num_task_pri` reserves, but no guarantee the task still exists when lock is acquired

**Affected code paths**:
- `__kmp_get_priority_task()` (kmp_tasking.cpp:2838)
- `__kmp_push_priority_task()` (kmp_tasking.cpp:187)

**Suggested modeling approach**:
- Variables: `priTaskCount \in Nat`, `priDeques[priority] \in Seq(Task)`
- Actions: `ReservePriTask` (CAS decrement), `DequeuePriTask` (lock + search), `StealPriTask` (concurrent consumption)
- Invariant: `priTaskCount >= 0` AND successful reservation implies a task exists to dequeue

**Priority**: Low-Medium
**Rationale**: Single finding from code analysis, no historical bug report. Could cause assertion failure under contention on priority tasks.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Task team parity toggle | Family 1: root cause of 6+ bugs, 3 unfixed | Two-slot state machine with `taskTeamSlot` toggle at barrier sync |
| Nested serial parallel | Family 1: serial team reuse breaks parity | `SerializedParallel` action that reuses team but must preserve parity |
| Task stealing lifecycle | Family 2: races between steal and team transition | `StealTask` action with victim state checks, `ReapThread` action |
| `tt_unfinished_threads` protocol | Families 1,2: counter must be decremented exactly once per thread | Counter variable with one-shot guard |
| Detachable task state machine | Family 3: 6 bugs in the detach/fulfill protocol | `taskPhase` variable with ownership transfer actions |
| `td_incomplete_child_tasks` | Family 3: counter consistency across all paths | Per-task counter incremented at alloc, decremented at completion/fulfill |
| Barrier cancellation + parity | Family 5: parity misalignment after cancelled barrier | `CancelParallel` action during gather, verify parity post-cancel |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Barrier algorithm internals (tree, hyper, hierarchical) | The gather/release algorithms are symmetric patterns; bugs are in the barrier-tasking interaction, not the tree topology |
| Memory ordering (TCR/TCW) | Memory model issues require different tools (C11 model checker, not TLA+) |
| OMPT callbacks | Observability only, no effect on correctness |
| Task dependencies (hash table, depnodes) | Family 4 is better verified by targeted testing; the nrefs drain protocol is low-level |
| Hidden helper thread pool management | Implementation detail; the task team interaction is captured by Family 1 |
| Priority task deques | Family 6 is a single code-level finding, not a protocol issue |
| ICV propagation | Performance optimization, no correctness impact |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Task team parity | `taskTeamSlot[t]`, `taskTeam[team][0..1]` | Model the 0/1 alternation scheme | Family 1 |
| Nested serial parallel | `serialNesting[t] \in Nat`, `teamReused[team]` | Capture serial team reuse | Family 1 |
| Unfinished threads counter | `unfinished[team][0..1] \in Nat` | Track per-slot worker completion | Families 1, 2 |
| Thread lifecycle | `threadState[t] \in {"active", "transitioning", "reaped"}` | Model team teardown races | Family 2 |
| Detachable task phases | `taskPhase[task] \in {"alloc", "exec", "detached", "fulfilled", "done"}` | Model ownership transfer | Family 3 |
| Child task counter | `childCount[task] \in Nat` | Track incomplete children | Family 3 |
| Barrier cancel state | `cancelReq[team] \in BOOLEAN` | Model cancellation during barrier | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ParityConsistency | Safety | All threads in a team use the same task team slot | Family 1 |
| UnfinishedNonNegative | Safety | `tt_unfinished_threads >= 0` (never underflows) | Families 1, 2 |
| UnfinishedExactlyOnce | Safety | Each thread decrements `tt_unfinished_threads` at most once per barrier | Family 2 |
| NoAccessAfterReap | Safety | No thread reads victim data after victim's team is freed | Family 2 |
| OwnershipExclusive | Safety | After proxy flag is set, only the fulfiller accesses taskdata | Family 3 |
| ChildCountConsistency | Safety | `td_incomplete_child_tasks` reaches 0 iff all children have completed | Family 3 |
| BarrierProgress | Liveness | All threads eventually exit the barrier (no deadlock) | Families 1, 5 |
| TaskCompletion | Liveness | All allocated tasks are eventually completed or discarded | Family 3 |
| ParityRestoredAfterCancel | Safety | After a cancelled barrier, parity is consistent for the next barrier | Family 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | Serial team reuse corrupts task team parity in nested parallel | ParityConsistency | 1 |
| MC-2 | `tt_unfinished_threads` underflow when workers and primary disagree on slot | UnfinishedNonNegative | 1 |
| MC-3 | Task stealer reads freed team data after `tt_unfinished_threads` decrement | NoAccessAfterReap | 2 |
| MC-4 | Thread marked "finished" steals again, double-decrements `tt_unfinished_threads` | UnfinishedExactlyOnce | 2 |
| MC-5 | `omp_fulfill_event` races with `__kmp_task_finish` on detachable task ownership | OwnershipExclusive | 3 |
| MC-6 | Detachable task with children: `td_incomplete_child_tasks` never reaches 0 | ChildCountConsistency, BarrierProgress | 3 |
| MC-7 | Cancelled barrier skips `task_team_wait`/`task_team_sync`, misaligning parity | ParityRestoredAfterCancel | 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | `__kmp_get_priority_task` NULL dereference under contention (kmp_tasking.cpp:2866) | Stress test with many threads pushing/stealing priority tasks |
| TV-2 | `__kmpc_give_task` tid/thread mismatch (kmp_tasking.cpp:4314-4323) | Address sanitizer test with hidden helper tasks |
| TV-3 | OMPT heap buffer overflow in `__kmpc_omp_taskwait_deps_51` (kmp_taskdeps.cpp:964-968) | ASAN test: taskwait with mutexinoutset deps where `ndeps > ndeps_noalias` |
| TV-4 | `issue-94260-2.c` still segfaults sporadically (Issue #156741) | Thread sanitizer + stress test |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | TCR/TCW macros are plain assignments — no CPU fences (kmp_os.h:1124-1146) | Audit all cross-thread signaling on ARM/POWER; consider `std::atomic` |
| CR-2 | `td_deque_ntasks` acknowledged as needing volatile (kmp.h:2832) | Add `volatile` or `std::atomic` |
| CR-3 | Detachable task comment "no access after this point" contradicted by next line (kmp_tasking.cpp:898-901) | Reorder or add comment explaining lock protection |
| CR-4 | 1024-byte mystery padding in `kmp_base_team_t` (kmp.h:3213) | Investigate false sharing root cause |
| CR-5 | `KMP_TASKING=1` (task barrier mode) silently broken (PR #143455) | Remove or fix the mode |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/libomp/analysis-report.md`
- **Key source files**:
  - `openmp/runtime/src/kmp_barrier.cpp` (2718 lines) — barrier algorithms
  - `openmp/runtime/src/kmp_tasking.cpp` (5486 lines) — task lifecycle, stealing, task teams
  - `openmp/runtime/src/kmp_taskdeps.cpp` (1068 lines) — task dependencies
  - `openmp/runtime/src/kmp_wait_release.h` (1057 lines) — wait/wake primitives
  - `openmp/runtime/src/kmp.h` (4893 lines) — data structures
- **GitHub issues**: #50602 (task team parity, OPEN), #59190 (hang, OPEN), #80664 (dist barrier, FIXED), #87307 (steal race, FIXED), #156741 (steal segfault, OPEN), #49969 (memory leak, OPEN)
- **Key commits**: `41ca9104ac` (serial team task team fix), `581490e713` (shutdown race), `d23131a3c0` (detach race), `3895148d7c` (deque realloc race)
- **Cross-implementation reference**: `case-studies/libgomp/` — GCC's OpenMP runtime, 2 confirmed bugs in barrier+tasking
- **Comparison**: libomp's counter-based design (`td_incomplete_child_tasks`, `tt_unfinished_threads`) is structurally more robust than libgomp's flag-based design (`BAR_TASK_PENDING`, `BAR_CANCELLED`); the libgomp Bug #28 and #29 patterns are architecturally prevented in libomp
