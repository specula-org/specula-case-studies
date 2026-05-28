# libgomp `task.c` – Phase-3 Concurrent-Analysis Findings

**File:** `/home/ubuntu/Specula/case-studies/libgomp_3/artifact/gcc/libgomp/task.c` (2798 lines)
**Companion:** `/home/ubuntu/Specula/case-studies/libgomp_3/artifact/gcc/libgomp/libgomp.h` (lines 778–862 for `gomp_team` / `gomp_task`)
**Companion:** `/home/ubuntu/Specula/case-studies/libgomp_3/artifact/gcc/libgomp/config/linux/bar.c` (lines 94, 160 for atomic ACQUIRE of `task_count`)

Synchronization model: A single per-team `gomp_mutex_t task_lock` protects the team-wide task scheduling state. A handful of fields (`team->task_count`, `taskgroup->num_children`, `task->detach_team`) are *also* touched with `__atomic_*` outside the lock to bridge to the team-barrier code. All long scheduling functions repeatedly drop and re-acquire the lock around the user task body, `gomp_sem_wait`, `gomp_team_barrier_wake`, and `free()`.

---

## 1. State variables touched under `team->task_lock`

Team-wide:
- `team->task_queue` — every insert/remove
- `team->task_count` — ++ under lock; -- under lock except 1709 uses `__atomic_store_n(..., RELEASE)` for the drop-to-0 case
- `team->task_queued_count` — ++/-- under lock
- `team->task_running_count` — ++/-- under lock (read at 730, 838, 1090, 1701, 1873, 2175, 2385, 2771)
- `team->task_detach_count` — ++ at 1679/1843/2365, -- at 2763, read at 2778

Per-task: `kind`, `dependers`, `depend_hash` (parent), `depend[i].next/prev/redundant`, `depend_all_memory`, `num_dependees`, `parent_depends_on`, `children_queue`, `pnode[]`, `taskwait`. `detach_team` is RELAXED-stored under lock at 2751 but ACQUIRE-loaded outside lock at 2738.

Per-taskgroup: `num_children` — RELEASE-stored-to-0 at 1400 & 1542 to pair with ACQUIRE load outside lock at 2256; otherwise plain. Also `taskgroup_queue`, `in_taskgroup_wait`, `taskgroup_sem`.

`parent->taskwait->{n_depend, in_depend_wait, in_taskwait, taskwait_sem}` — only modified under lock; `taskwait` struct lives on the *parent's* stack.

## 2. Unlock + re-lock points in the long scheduling functions

- **`gomp_barrier_handle_tasks`** (1551–1714): lock at 1561; unlocks at 1575, 1584, 1621, 1630; re-locks at 1650 (target task) and 1672 (after fn).
- **`GOMP_taskwait`** (1720–1880): lock at 1743; unlocks at 1751, 1795; re-locks at 1815, 1836.
- **`gomp_task_maybe_wait_for_dependencies`** (1934–2182): lock at 1960; unlocks at 2048, 2063, 2113; re-locks at 2133, 2154.
- **`GOMP_taskgroup_end`** (2225–2397): lock at 2260; unlocks at 2279, 2317; re-locks at 2337, 2358.
- **`omp_fulfill_event`** (2724–2796): asymmetric double-release at 2787–2792 — releases either before *or* after the wake depending on whether the calling thread belongs to the team (`shackled_thread_p`).

## 3. Findings (numbered F-/G-/B-)

### F-1. `do_wake` in `GOMP_task` computed under-lock, wake out-of-lock (task.c:730–734)
```c
do_wake = team->task_running_count + !parent->in_tied_task < team->nthreads;
gomp_mutex_unlock (&team->task_lock);
if (do_wake) gomp_team_barrier_wake (&team->barrier, 1);
```
Mechanism: snapshot stale by wake time. Compensation: excess wake is harmless (futex no-op). **Class: code-review-only.**

### F-2. `task_count != 0` non-atomic read paired with non-atomic `bar->generation` (task.c:1562–1577)
```c
/* Avoid running tasks from next task scheduling region (PR122314).
   N.b. we check that `team->task_count != 0` in order to avoid the
   non-atomic read of `bar->generation` "conflicting" ... */
if (team->task_count != 0
    && gomp_barrier_has_completed (state, &team->barrier)) { ... return; }
```
Developer-acknowledged data race; argument that `task_count == 0` ⇒ won't run any tasks ⇒ safe is informal. The RELEASE store at 1709 pairs with ACQUIRE in bar.c:94/160. **Class: model-checkable** (PR122314 was a real bug here).

### F-3. `gomp_target_task_completion` wake-inside-lock for lifetime (task.c:834–839)
```c
/* I'm afraid this can't be done after releasing team->task_lock,
   as gomp_target_task_completion is run from unrelated thread and
   therefore in between gomp_mutex_unlock and gomp_team_barrier_wake
   the team could be gone already.  */
if (team->nthreads > team->task_running_count)
  gomp_team_barrier_wake (&team->barrier, 1);
```
Explicit team-lifetime mitigation; mirrored in F-9/F-10. **Class: code-review-only.**

### F-4. Stale `do_wake` carried across loop iterations in `gomp_barrier_handle_tasks`
`do_wake` set under lock at 1701–1704 (iteration N) is consumed at 1633 (iteration N+1) after the lock has been released and re-taken. Stale value can only cause excess wakes. **Class: code-review-only.**

### F-5. `taskgroup->num_children` `> 1` check followed by RELEASE store-to-0 (task.c:1394–1407, also 1533–1543)
```c
if (taskgroup->num_children > 1) --taskgroup->num_children;
else __atomic_store_n (&taskgroup->num_children, 0, MEMMODEL_RELEASE);
```
Under lock, but the RELEASE pairs with the lock-free ACQUIRE at 2256. Bridges all child-task body writes to a `GOMP_taskgroup_end` fast-exit. **Class: code-review-only**, worth modeling because of the lock-free fast path.

### F-6. `task_count == 0` + `waiting_for_tasks` completion handshake (task.c:1579–1589 vs 1617–1629)
Two distinct early-exits of the barrier-handle loop must together ensure every barrier eventually completes. The combined liveness property:
> After the last `task_count--`, the next entry into `gomp_barrier_handle_tasks` from any team thread reaches the 1617 branch and finalizes the barrier.

**Class: model-checkable** (central liveness).

### F-7. `GOMP_taskwait` fast path with ACQUIRE load (task.c:1737–1739)
Safe only because *only the owning thread* creates children of its own task. **Class: code-review-only.**

### F-8. `GOMP_taskgroup_end` fast path acquire-load (task.c:2256–2257)
Pairs with RELEASE writes at 1400 & 1542. `taskgroup` then freed at 2395–2396 *outside* the lock — safe because `num_children == 0` ⇒ no live writer can post the sem or touch the taskgroup. **Class: code-review-only.**

### F-9. `omp_fulfill_event` RELAXED load of `detach_team` (task.c:2738–2754)
```c
struct gomp_team *team = __atomic_load_n (&task->detach_team, MEMMODEL_RELAXED);
if (!team) gomp_fatal (...);
gomp_mutex_lock (&team->task_lock);
if (task->kind != GOMP_TASK_DETACHED) {
    __atomic_store_n (&task->detach_team, NULL, MEMMODEL_RELAXED);
    gomp_mutex_unlock (&team->task_lock); return;
}
```
RELAXED is justified only because the mutex acquire/release provides the actual ordering. Team-lifetime relies on a user-side contract; no refcount/grace period in libgomp. **Class: model-checkable** (interesting race: last detach event arriving as the team finalizes its barrier).

### F-10. `omp_fulfill_event` double-release around wake (task.c:2787–2792)
```c
if (shackled_thread_p) gomp_mutex_unlock (&team->task_lock);
if (do_wake) gomp_team_barrier_wake (&team->barrier, do_wake);
if (!shackled_thread_p) gomp_mutex_unlock (&team->task_lock);
```
Mirror image of F-3 lifetime pattern. `free(task)` at 2795 runs after both branches release. **Class: code-review-only.**

### F-11. Last-detach wake-at-least-one guard (task.c:2776–2782)
Triggers `do_wake = 1` exactly when *unshackled, no other wake needed, no remaining detaches, barrier waiting*. The last-fulfill-must-wake invariant. Looks sound. **Class: code-review-only.**

### F-12. `task_running_count++` skipped on cancellation (task.c:1602–1615 vs 1696–1697)
`++` happens *after* the cancellation check, so `if (!cancelled) team->task_running_count--;` is correct. Resolved — but extremely sensitive to reordering.

### F-13. Asymmetric atomic vs plain `task_count--` (task.c:1709 vs 1870/2172/2382/2762)
Only `gomp_barrier_handle_tasks` uses `__atomic_store_n(&team->task_count, 0, RELEASE)`. `GOMP_taskwait`, `gomp_task_maybe_wait_for_dependencies`, `GOMP_taskgroup_end`, `omp_fulfill_event` all use plain `team->task_count--`. The lock-free ACQUIRE reader in bar.c can see a stale non-zero `task_count` after a taskwait-driven decrement, causing it to spuriously enter `gomp_barrier_handle_tasks` — which immediately returns (1581–1586). Mitigated but mixing atomic + plain on the same object is technically UB and a footgun for future edits. **Class: code-review-only.**

### F-14. `taskwait->n_depend` decrement assumes `parent->taskwait != NULL` (task.c:1502, 1386)
```c
if (__builtin_expect (child_task->parent_depends_on, 0)
    && --parent->taskwait->n_depend == 0
    && parent->taskwait->in_depend_wait) { ... }
```
Invariant: `parent_depends_on` is only set in `gomp_task_maybe_wait_for_dependencies` *after* `task->taskwait = &taskwait` (line 2055). Fragile if anyone reorders that init. **Class: code-review-only.**

### F-15. `gomp_task_run_post_remove_parent` parent-lifetime — resolved (called only under lock; parent can't be freed while we hold the lock).

### F-16. `gomp_clear_parent` writes `parent = NULL` to children that may be running on other threads — all reads/writes under lock.

### F-17. Undeferred-detach `task.completion_sem` lifetime (task.c:557–590)
`task` lives on the stack; address published via `*(void **) detach = &task;`. Late `omp_fulfill_event` would read freed stack — user contract violation, not a libgomp bug. **Class: code-review-only.**

### F-18. `union { completion_sem; detach_team; }` (libgomp.h:695–706) — `gomp_init_task` writes the `completion_sem` arm to NULL, so deferred non-detach tasks see `detach_team == NULL`.

### F-19. `omp_fulfill_event` `gomp_fatal`s if called on a non-detach deferred task.

### F-20. `task_running_count++` at 1614 happens *after* `gomp_task_run_pre`'s cancellation check at 1602 — correctly skipped on cancellation (cf. F-12). Briefly between 1305 and 1614, `running + queued` is one less than expected, but no external observer reads either lock-free.

### F-21. `gomp_team_barrier_clear_task_pending` race (1305–1306) — within lock so a concurrent producer cannot re-set the bit until we release.

### F-22. `gomp_target_task_completion` lock-required — all 5 call sites hold the lock per its 785–788 contract.

### F-23. `gomp_sem_destroy(&taskwait.taskwait_sem)` outside lock (task.c:1758)
Safe because: (a) `task->taskwait = NULL` at 1750 under lock, (b) priority_queue_empty_p (1747) returned true ⇒ no live poster.

### F-24. Same pattern for `gomp_task_maybe_wait_for_dependencies` (task.c:2062–2069) — `taskwait.n_depend == 0` ⇒ no poster.

### F-25. `gomp_target_task_completion`'s `++team->task_queued_count` (832) — under lock; no external reader.

### F-26. Developer-acknowledged unbarriered read at task.c:592–600
```c
/* Access to "children" is normally done inside a task_lock
   mutex region, but the only way this particular task.children
   can be set is if this thread's task work function (fn)
   creates children.  So since the setter is *this* thread, we
   need no barriers here ... */
```
Justification holds because no sibling thread creates children of this task. **Class: code-review-only.**

## G – Reclamation

- **G-1.** `to_free` deferred-free idiom in all 4 long loops (1695, 1868, 2170, 2380) — safe because pointer is thread-local once removed from queues.
- **G-2.** `omp_fulfill_event` frees task at 2794–2795 after both unlock branches.
- **G-3.** `empty_task` inline free in `gomp_task_run_post_handle_dependers` (1409–1411) — task was never enqueued (it had unresolved deps until just now).
- **G-4–G-7.** Hash tables / dependers arrays — all under lock.
- **G-8.** Taskgroup free after `num_children == 0` (2256/2395) — no live writer.
- **G-9.** External fulfill thread holding stale `detach_team` — user contract; no refcount in libgomp.

## 4. Memory-ordering bridges

| Site | Op | Memorder | Pair |
|---|---|---|---|
| 1400 | store `taskgroup->num_children = 0` | RELEASE | 2256 ACQUIRE |
| 1542 | store `taskgroup->num_children = 0` | RELEASE | 2256 ACQUIRE |
| 1709 | store `team->task_count = 0` | RELEASE | bar.c:94/160 ACQUIRE |
| 2256 | load `taskgroup->num_children` | ACQUIRE | 1400/1542 |
| 2738 | load `task->detach_team` | RELAXED | (lock provides ordering) |
| 2751 | store `task->detach_team = NULL` | RELAXED | (lock provides ordering) |
| 1510 | priority_queue_remove | RELEASE | 1738 ACQUIRE (`priority_queue_empty_p` in taskwait fast path) |
| 601 | priority_queue_empty_p | RELAXED | comment 592–600 |

## 5. Acknowledged caveats & PR references

- **task.c:1562–1567** — PR122314 data-race in `bar->generation` non-atomic load
- **task.c:1706–1707** — PR122356 RELEASE store of `task_count = 0`
- **task.c:592–600** — relaxed read of own `children_queue`
- **task.c:834–837** — `gomp_target_task_completion` lifetime
- **task.c:2073–2085** — long comment about scheduling priorities being theoretically wrong (uses `PQ_IGNORED` and skips `priority_queue_next_task`'s real semantics)
- **task.c:2467–2470** — "Ugly hack" cast through asm to fool the compiler
- **task.c:2784–2786** — `omp_fulfill_event` team-lifetime
- **task.c:69–76** — intentional partial-`memset` for performance

No `TODO`/`FIXME`/`XXX` literals beyond the "Ugly hack" comment.

---

# Top 5 candidate bug families (one-page summary)

**A. PR122314-class barrier↔task_count window.** The handshake among `team->task_count` (mixed atomic/plain), `bar->generation` (non-atomic read), `BAR_TASK_PENDING`, `BAR_WAITING_FOR_TASK`, and the three `gomp_barrier_handle_tasks` exit-arms (1575, 1584, 1617) is the file's subtlest concurrency, with two recent PRs (122314, 122356) still in flight. New bugs would surface as stuck barriers or premature releases — perfect for TLA+ modeling. (F-2, F-6, F-13)

**B. omp_fulfill_event team-lifetime + RELAXED detach_team.** The RELAXED `__atomic_load_n` of `task->detach_team` at 2738 is justified only because the subsequent `gomp_mutex_lock(&team->task_lock)` provides the ordering. The asymmetric double-unlock at 2787–2792 keeps the lock across `gomp_team_barrier_wake` only for unshackled callers — a documented mitigation for a real lifetime race. Worth model-checking "last detach event arrives concurrently with team finalization." (F-9, F-10, F-11, G-9)

**C. Stale `do_wake` carried across lock-drop windows.** Several sites compute wake counts under-lock then consume them after dropping the lock; `gomp_barrier_handle_tasks` even carries `do_wake` across loop iterations through fn execution and a second lock acquisition. Excess wakes are benign but missed wakes can stall progress when bookkeeping shifts during the drop. (F-1, F-4, F-10)

**D. `task->taskwait` aliasing & teardown.** The `taskwait` struct lives on the caller's stack and is reachable by other threads via the parent pointer. The teardown invariant — "set `task->taskwait = NULL` before `gomp_sem_destroy`; we observed empty queue ⇒ no concurrent poster" — is correct only because removal happened under the same lock. Any future code that batches removals or relaxes the empty check would break it. (F-14, F-23, F-24)

**E. Mixed atomic + plain access to bookkeeping counters.** `task_count`, `taskgroup->num_children`, `task_running_count` are sometimes plain, sometimes atomic-RELEASE-to-zero. Mixing accesses to the same object is technically UB; currently safe only because lock-holders use plain and lock-free readers always check the "==0" sentinel. (F-13, F-5)
