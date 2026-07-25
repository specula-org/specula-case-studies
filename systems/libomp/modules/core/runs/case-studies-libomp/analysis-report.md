# Analysis Report: LLVM libomp (OpenMP Barrier + Tasking)

## Coverage Statistics

### Git History Mining
- **Total bug-fix commits analyzed**: 65+ commits touching core files
- **Commits deeply examined** (via `git show`): 27
- **Keywords searched**: fix, race, deadlock, bug, crash, hang, steal, hidden helper, cancel, proxy, detach, task_team

### GitHub Issues
- **Total issues collected**: 50+
- **Issues deeply read** (full comment thread): 38
- **Confirmed bugs**: 30
- **Design defects**: 3
- **False positives excluded**: 2 (user error / misconfiguration)
- **Uncertain**: 3

### GitHub Pull Requests
- **Total PRs reviewed**: 18
- **PRs deeply read** (full discussion): 15
- **Bug-fix PRs**: 14
- **Feature PRs**: 4

### Deep Analysis
- **Files fully read**: 5 (kmp_barrier.cpp, kmp_tasking.cpp, kmp_taskdeps.cpp, kmp_wait_release.h, kmp.h)
- **Total LOC analyzed**: ~15,300
- **New findings from code analysis**: 12

---

## Phase 1: Reconnaissance Summary

### File Inventory

| File | Lines | Purpose |
|------|-------|---------|
| kmp.h | 4,893 | Core data structures, enums, macros |
| kmp_barrier.cpp | 2,718 | 5 barrier algorithms (linear, tree, hyper, hierarchical, distributed) |
| kmp_tasking.cpp | 5,486 | Task alloc, execute, steal, task teams |
| kmp_taskdeps.cpp | 1,068 | Task dependency graph and resolution |
| kmp_wait_release.h | 1,057 | Wait/release primitives, sleep/wake protocol |
| kmp_barrier.h | 143 | Distributed barrier class definition |
| kmp_taskdeps.h | 212 | Dependency node structures |
| kmp_lock.h | 1,306 | Lock implementations |
| kmp_os.h | 1,320 | Atomic macros (TCR/TCW, KMP_TEST_THEN_*) |
| kmp_runtime.cpp | 9,388 | Fork/join, team management |

### Core Data Structures

**kmp_base_info_t** (thread): Contains `th_task_team` (current task team pointer), `th_current_task` (executing task), `th_task_state` (0/1 parity), `th_reap_state` (safe-to-reap flag), `th_bar[]` (per-barrier-type state).

**kmp_base_team_t** (team): Contains `t_task_team[2]` (dual task team slots), `t_cancel_request` (cancellation flag), `t_bar[]` (team barrier state), `t_primary_task_state` (saved primary parity).

**kmp_base_task_team_t** (task team): Contains `tt_threads_data[]` (per-thread deques), `tt_unfinished_threads` (atomic counter), `tt_active` (volatile flag), `tt_found_tasks`/`tt_found_proxy_tasks`/`tt_hidden_helper_task_encountered` (task type flags).

**kmp_taskdata_t** (task): Contains `td_flags` (32-bit bitfield: tied, proxy, detachable, etc.), `td_incomplete_child_tasks` (atomic counter), `td_parent` (parent task), `td_task_team`, `td_allow_completion_event` (detach event).

**kmp_base_thread_data_t** (per-thread deque): Contains `td_deque[]` (circular buffer), `td_deque_head`/`td_deque_tail`/`td_deque_ntasks`, `td_deque_lock` (bootstrap lock).

### Concurrency Model

- **Threads**: N worker threads + 1 primary per parallel region, pooled via hot teams
- **Locks**: Bootstrap locks on task deques, TAS locks on task events
- **Atomics**: `td_incomplete_child_tasks`, `tt_unfinished_threads` (std::atomic); `b_arrived`, `b_go` (volatile + TCR/TCW)
- **TCR/TCW**: Platform-specific macros. On x86/ARM-LE, these are **plain reads/writes** with no CPU fence (kmp_os.h:1137-1146). FIXME at line 1124 acknowledges this is probably wrong.
- **Memory barriers**: `KMP_MB()` (compiler barrier only on x86), `KMP_MFENCE()` (full fence, used in distributed barrier)

---

## Phase 2: Bug Archaeology — Detailed Findings

### Historical Bug-Fix Commits (27 deeply analyzed)

#### Barrier-Tasking Interaction

1. **`581490e713`** (2017): Race in shutdown — stealing thread accesses reaped thread. Fix: `th_reap_state` flag (KMP_SAFE_TO_REAP / KMP_NOT_SAFE_TO_REAP).

2. **`b0b83c8b0c`** (2015): `__kmp_task_team_setup` called AFTER gather for non-forkjoin barriers, but threads already switching task teams. Fix: move setup BEFORE gather.

3. **`a764af68be`** (2018): Shutdown deallocates resources while threads spin-waiting in `__kmp_wait_template`. Fix: `th_blocking` atomic flag.

4. **`a4a9c48c78`** (2018): Hot team nthreads decrease — freed thread has `current_task = NULL`, stealer dereferences. Fix: NULL check in execute_tasks.

5. **`d26e213d11`** (2015): `b_arrived` counter wraps after UINT_MAX parallel regions. Fix: widen to `kmp_uint64`.

#### Task Team Parity

6. **`41ca9104ac`** (2024): Major refactoring — serial teams now use linked-list stack for task teams instead of 2-element array. Fixed issues #50602, #69368, #69733, #79416.

7. **`41f148e61d`** (2023): `th_task_state_memo_stack` corrupted by proxy/hidden helper tasks in serialized regions. Fix: `__kmp_shift_task_state_stack`.

8. **`54127981be`** (2015): Refactor of task_team code — added dual-slot mechanism.

#### Detachable Tasks

9. **`d23131a3c0`** (2020): Race — `__kmp_task_finish` writes taskdata fields AFTER setting `proxy = TASK_PROXY`, but `__kmp_fulfill_event` could free taskdata. Fix: reorder writes before proxy flag.

10. **`3c76e99291`** (2021): Deadlock — `td_incomplete_child_tasks` used for both child counting AND proxy task synchronization. Fix: high-order bit flag `PROXY_TASK_FLAG = 0x40000000`.

11. **`57d8b8d6f0`** (2020): Hang — serialized detachable task doesn't decrement child counter. Fix: decrement even when serialized if task is detachable.

12. **`3c31b78455`** (2021): Taskwait ignores detachable tasks — `tt_found_proxy_tasks` not set. Fix: add detachable check.

#### Task Stealing

13. **`3895148d7c`** (2020): Race — deque fullness checked before lock, stale by lock acquisition time, causing corrupt realloc. Fix: recheck after lock.

14. **`4ea24946e3`** (2024): Nested parallel tid race — primary resets tid, stealer reads stale value from thread struct. Fix: pass tid by value, not by pointer.

15. **`71483f2dda`** (2017): `memcpy` in `__kmp_realloc_task_threads_data` used `sizeof(kmp_taskdata_t *)` instead of `sizeof(kmp_thread_data_t)`.

#### Task Dependencies

16. **`b999e631c0`** (2024): Stack-allocated depnode freed while another thread holds reference. Fix: nrefs drain wait.

17. **`2fdf191e24`** (2025): Same race on early-return path. Fix: nrefs drain + bit-0 stack marker.

18. **`c2c43132f6`** (2021): `release_deps` called AFTER decrementing child counter — dependent task missed. Fix: release deps BEFORE decrement.

19. **`be29d92854`** (2019): Dephash resize: `nconflicts` uninitialized, `next_in_bucket` set before check.

#### Hidden Helper Tasks

20. **`458db51c10`**: Missing `tt_hidden_helper_task_encountered` alongside `tt_found_proxy_tasks` in barrier.

21. **`9f5d6ea52e`** (2021): Hidden helper tasks must be untied (TASK_UNTIED) — tied tasks can't be executed by helper threads.

22. **`996baa58a4`** (2021): Taskgroup only checked `tt_found_proxy_tasks`, not `tt_hidden_helper_task_encountered`.

23. **`8442967fe3`** (2021): Regular tasks in serialized team not tracked by `td_incomplete_child_tasks` when hidden helper tasks present.

#### Cancellation

24. **`dbdcfa127f`**: Reset cancellation status only for loop/sections, not parallel.

25. **`4fe5271fa0`**: Adding GOMP-compatible cancellation barrier (`__kmp_barrier_gomp_cancel`).

#### Barrier Algorithm

26. **`4fe17ada55`** (2021): Hierarchical barrier offset calculation wrong for leaf threads.

27. **`2208a85101`**: Performance fix after removing monitor thread — affected barrier sleep/wake.

### GitHub Issues — Key Open Bugs

| Issue | Status | Severity | Summary |
|-------|--------|----------|---------|
| #50602 | OPEN | HIGH | Task team assertion: serialized parallel + detached task |
| #59190 | OPEN | HIGH | Deadlock: workers/primary disagree on task team slot |
| #80664 | FIXED | HIGH | Distributed barrier + passive wait deadlock |
| #81488 | OPEN | MEDIUM | Assertion: OMP_NUM_THREADS=1 + target nowait |
| #77575 | OPEN | MEDIUM | `tt_unfinished_threads` goes to -1 with extra_barrier mode |
| #116215 | OPEN | HIGH | Hierarchical barrier endian bug on s390x |
| #132218 | OPEN | MEDIUM | Tests hang on AArch64 with passive policy |
| #156741 | OPEN | MEDIUM | issue-94260-2.c still segfaults sporadically |
| #49969 | OPEN | MEDIUM | Memory leak for detachable tasks |
| #127395 | OPEN | HIGH | Stack overflow with untied tasks (10M children) |
| #44742 | OPEN | HIGH | Sporadic segfault in `__kmp_free_fast_memory` at shutdown |

---

## Phase 3: Deep Analysis — New Findings

### kmp_barrier.cpp

**B-1 (MEDIUM-HIGH)**: Hierarchical barrier release uses non-atomic `b_go |= leaf_state` (line 1703) which races with children's byte-store to `parent_bar->b_go` (line 1592) during team size changes with infinite blocktime.

**B-2 (MEDIUM)**: After cancelled barrier, `task_team_setup` was called (line 1913) but `task_team_wait` and `task_team_sync` are skipped (lines 1951, 2063 check `!cancelled`), potentially misaligning task team parity for the next barrier.

**B-3 (HIGH, known)**: Hierarchical barrier byte indexing `[7 - i]` (lines 1354-1378) is wrong on big-endian platforms (Issue #116215).

### kmp_tasking.cpp

**T-1 (MEDIUM)**: `__kmpc_give_task` (line 4314-4323) increments `k` before passing to `__kmp_give_task`, causing tid/thread mismatch — wrong thread's memory allocator used for deque reallocation.

**T-2 (HIGH)**: `__kmp_get_priority_task` (lines 2866-2877): after CAS reservation, if another thread consumes the task, the linear search exhausts all priority deque lists and hits `KMP_ASSERT(list != NULL)` or dereferences NULL.

**T-3 (MEDIUM)**: Detachable task comment at line 898 says "no access to taskdata after this point" but line 901 writes `taskdata->td_flags.proxy`. Currently safe under lock but extremely fragile.

### kmp_taskdeps.cpp

**D-1 (CRITICAL)**: OMPT heap buffer overflow in `__kmpc_omp_taskwait_deps_51` (lines 964-968): copy-paste error writes to `ompt_deps[ndeps + i]` instead of `ompt_deps[i]` for mtx/set dependencies. When `ndeps > ndeps_noalias`, writes beyond allocated buffer.

**D-2 (MEDIUM)**: `KMP_TASK_TO_TASKDATA(task)` evaluated before `if (task)` null check in OMPX_TASKGRAPH code (lines 357-358).

### kmp_wait_release.h

**W-1 (MEDIUM)**: `kmp_flag_native::load()` (line 164) uses volatile dereference without explicit memory ordering — relies on x86 TSO, potentially broken on ARM/POWER.

**W-2 (MEDIUM)**: `kmp_flag_oncore::internal_release` byte-level write (line 986) lacks atomicity guarantee on non-x86 architectures.

**W-3 (LOW)**: `__kmp_null_resume_wrapper` reads `th_sleep_loc` without acquiring suspend mutex (line 1029).

### kmp.h

**H-1 (HIGH)**: TCR/TCW macros are plain C assignments with no CPU fences (kmp_os.h:1124-1146). FIXME comment acknowledges this is wrong but unfixed due to performance fear. All cross-thread signaling in barrier and tasking code is affected.

**H-2 (MEDIUM)**: `td_deque_ntasks` acknowledged by developer as needing volatile (kmp.h:2832 comment) but remains unfixed.

**H-3 (MEDIUM)**: Tasking fields `th_task_team`, `th_current_task`, `th_task_state`, `th_reap_state` (kmp.h:3035-3039) share a cache line with random number state — false sharing between task execution and steal victim selection.

**H-4 (LOW)**: 1024-byte `dummy_padding` in `kmp_base_team_t` (kmp.h:3213) is an unexplained workaround for a performance regression, with TODO to investigate.

---

## Phase 3: Cross-Implementation Comparison (libomp vs libgomp)

### libgomp Bug #28 (cancel + task race) analog: NOT PRESENT

libomp's architecture prevents this: task completion never directly triggers barrier completion. Tasks decrement `td_incomplete_child_tasks`, workers check this before decrementing `tt_unfinished_threads`. There is no single "task completes barrier" code path that could skip a cancellation check.

### libgomp Bug #29 (fulfill event deadlock) analog: NOT PRESENT

libomp's counter-based design prevents this: `td_incomplete_child_tasks` is incremented at task creation and stays incremented until `__kmp_fulfill_event` → `__kmp_second_top_half_finish_proxy` decrements it. No separate "pending" flag that could be forgotten.

### Key Architectural Difference

libgomp uses **boolean flags** (`BAR_TASK_PENDING`, `BAR_CANCELLED`) that must be explicitly set at every relevant path — easy to forget. libomp uses **counters** (`td_incomplete_child_tasks`, `tt_unfinished_threads`) that are maintained by construction — increment at creation, decrement at completion. The counter approach is structurally more robust against the "forgot to set flag" bug class.

However, libomp has its own systemic vulnerability: the **task team parity scheme** (Family 1) is a protocol-level design that is fragile across nesting and special task types. This has no analog in libgomp (which uses a simpler single-barrier approach).

---

## Bug Family Summary

| Family | Bugs (Historical) | Bugs (Open) | New Findings | Priority |
|--------|-------------------|-------------|--------------|----------|
| 1: Task team parity | 7 | 3 | 1 (B-2) | HIGH |
| 2: Steal during transitions | 6 | 2 | 0 | HIGH |
| 3: Detachable task protocol | 6 | 1 | 1 (T-3) | MEDIUM-HIGH |
| 4: Stack depnode UAF | 2 | 1 | 0 | MEDIUM |
| 5: Barrier algorithm inconsistencies | 5 | 3 | 2 (B-1, B-3) | MEDIUM |
| 6: Priority task deque race | 0 | 0 | 1 (T-2) | LOW-MEDIUM |
| Standalone: OMPT buffer overflow | 0 | 0 | 1 (D-1) | CRITICAL (test-verifiable) |
| Standalone: TCR/TCW memory model | 0 | 0 | 1 (H-1) | HIGH (code-review) |
