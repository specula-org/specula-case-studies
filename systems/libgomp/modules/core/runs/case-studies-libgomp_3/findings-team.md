# libgomp Team / Parallel Deep-Analysis — Findings

Files read in full: `team.c` (1125 LoC), `parallel.c` (342 LoC), `config/posix/pool.h` (67 LoC). Cross-referenced: `libgomp.h` struct defs, `config/linux/bar.[ch]`, `config/posix/simple-bar.h`, `task.c` (PR122314 race comment).

## A. Synchronization vocabulary

| Primitive | Notes |
|---|---|
| `pool->threads_dock` (gomp_simple_barrier_t / wraps gomp_barrier_t) | Futex-backed. No task-pending/cancel bits handled by users; `reinit` mutates `total` and `awaited`. |
| `team->barrier` (gomp_barrier_t) | Futex on `bar->generation`. Carries `BAR_TASK_PENDING`, `BAR_CANCELLED`, `BAR_WAITING_FOR_TASK`, BAR_INCR=8. |
| `team->task_lock` | Held when manipulating `task_queue`, `task_count`, BAR_TASK_PENDING/BAR_WAITING_FOR_TASK/BAR_CANCELLED on `team->barrier.generation`. |
| `team->work_share_list_free_lock` | Only when `!HAVE_SYNC_BUILTINS`; protects `work_share_list_free`. |
| `gomp_managed_threads_lock` | Fallback (no `__sync_*`) for `gomp_managed_threads` and `pool->threads_busy`. |
| `team->ordered_release[]` | Per-thread sem ptrs, set by master (line 666) or secondary (line 102) per region. |

**TODO/FIXME/XXX/HACK:** none in `team.c` or `parallel.c`. Race comments live in `team.c:460-464` ("perhaps that's reading too much into things") and `team.c:875-882` (affinity arithmetic). `task.c:1562-1571` documents PR122314.

## B. Findings

### F1 — `pool->last_team` cache is a producer/consumer slot with no fence on cross-thread paths
- **team.c:150-165** reader (`get_last_team`) does a plain load `pool->last_team`, plain store `pool->last_team = NULL`.
- **team.c:1004-1014** writer (`gomp_team_end`) does a plain store `pool->last_team = team` after release fence inside `gomp_team_barrier_wait_final`.
- Mechanism: On POSIX the pool is always owned by one master (line 460 comment), so the read/write are on the same thread — safe by program order. **On the RTEMS reservoir path** (`config/rtems/pool.h:73-109`) a pool can migrate masters between `gomp_release_thread_pool` and the next master's `gomp_get_thread_pool`. There is no acquire fence on the new master's `pool->last_team` read.
- Compensating: spin-lock `res->lock` around reservoir push/pop, but not around `last_team` itself.
- **Classification:** code-review-only on POSIX; **model-checkable** on RTEMS variant.

### F2 — Cached team retains `BAR_CANCELLED` on `team->barrier.generation` across reuse (strong candidate)
- **team.c:175-194** — `get_last_team` returns a cached team. On the reuse path the body skips `gomp_barrier_init` (only run inside the `if (team == NULL)` block).
- **team.c:217-218** — `work_share_cancelled = 0; team_cancelled = 0;` are re-zeroed on reuse, but **`team->barrier.generation`'s `BAR_CANCELLED` bit is not cleared.**
- Trace: a cancelled region's `gomp_team_end` calls `gomp_team_barrier_wait_final` (line 957). The last-arriver branch at `bar.c:100-107` does `state += BAR_INCR - BAR_WAS_LAST; __atomic_store_n(&bar->generation, state, RELEASE);` — and `state` was loaded by `gomp_barrier_wait_final_start` (`bar.h:115`) with mask `-BAR_INCR | BAR_CANCELLED`, **preserving** the cancel bit. So the cached team's `generation` still has `BAR_CANCELLED` set.
- Next region: `GOMP_cancellation_point` (parallel.c:228-229) returns `gomp_team_barrier_cancelled(&team->barrier)` → `bar.h:156-160` checks `bar->generation & BAR_CANCELLED` → returns true on a fresh region.
- The bit is only cleared by the next *non-cancellable* `wait_end` last-arriver store (`bar.c:102-104` `state &= ~BAR_CANCELLED; state += BAR_INCR - BAR_WAS_LAST;`). So the spurious cancel persists until the next implicit barrier is reached.
- **Classification:** model-checkable / test-verifiable. **Top candidate.**

### F3 — Cancel-bit set is racy: `team->barrier.generation |= BAR_CANCELLED` under task_lock vs `__atomic_store_n` RELEASE without that lock
- **bar.c:204-215** (`gomp_team_barrier_cancel`):
  - `gomp_mutex_lock(&team->task_lock); ... team->barrier.generation |= BAR_CANCELLED; gomp_mutex_unlock(...); futex_wake(...);`
- Concurrent writer: **bar.c:100-107** last-arriver `__atomic_store_n(&bar->generation, state, RELEASE)` is **not** taken under task_lock.
- Race: cancel does plain `|=` (which compiles to load, OR, store). The atomic store from `wait_end` can clobber the bit if interleaved. Waiters never observe cancellation.
- Compensation: `futex_wake(INT_MAX)` wakes everyone; the wait_cancel path reloads generation and re-checks `gen & BAR_CANCELLED` (`bar.c:183`). But if the bit was stomped, the reload won't see it.
- **Classification:** model-checkable. PR112356 addressed an analogous data-race; the cancel `|=` was not converted.

### F4 — `pool->last_team` ABA via team-address reuse: `task.c:1562-1577` PR122314 race
- A secondary in `gomp_barrier_handle_tasks` has captured `bar = &team->barrier` from `thr->ts.team`. Master ends the team, caches it in `pool->last_team`, starts a new region that **reuses the same struct** via `get_last_team`. Secondary's stale `team` pointer now refers to the same struct now used by the new region.
- Defense: `task_count != 0` guard at task.c:1572 plus `gomp_new_team` resetting `task_count = 0` (team.c:214). The cache is invalidated only by `task_count` being zero at reuse — extremely fragile.
- **Classification:** model-checkable (already attempted in libgomp_2 Family 4).

### F5 — Split publication in `gomp_team_start`: long observable intermediate states (lines 319-940)
Observable intermediate state during one `gomp_team_start`:
1. **354:** `team->prev_ts = thr->ts;` (plain write)
2. **356-358:** `thr->ts.team = team; thr->ts.team_id = 0; ++thr->ts.level;` (plain, no fence)
3. **474/482:** `gomp_simple_barrier_init/reinit(&pool->threads_dock, nthreads)`
4. **488:** `pool->threads_used = nthreads;` (plain) — **published before** realloc at 496
5. **497:** `gomp_realloc(pool->threads, ...)` — between `pool->threads_used = nthreads` and the realloc, an outside reader of `pool->threads_used` could index into the **old** `pool->threads`.
6. **501:** `pool->threads[0] = thr;` re-establishes master slot.
7. **505-667:** affinity reshuffle loop; mutates `pool->threads[i]`, writes to live secondaries' `nthr->ts.*`, `nthr->fn`, `nthr->data`, `team->ordered_release[i]`.
8. **740:** `__sync_fetch_and_add(&gomp_managed_threads, diff)` — global counter inflated.
9. **764-864:** `pthread_create` loop — new threads start running `gomp_thread_start` in parallel.
10. **873:** `gomp_simple_barrier_wait(&pool->threads_dock)` — release-acquire fence.
11. **891:** if `affinity_count`, `gomp_simple_barrier_reinit(&pool->threads_dock, nthreads)` — **after** release, while secondaries are running `local_fn`.
12. **894:** `__sync_fetch_and_add(&gomp_managed_threads, diff)` decrement.

Stage 11 reinits the dock **while threads are running user code**. Compensation: by construction, no secondary can re-dock until after `local_fn` completes — far past the reinit at 891.
- **Classification:** code-review-only; protocol is implicit.

### F6 — `gomp_thread_start` idle-loop relies on dock barrier's RELEASE for `thr->fn`/`thr->data`/`thr->ts.*` handoff
- **team.c:135-138** reader (secondary): `local_fn = thr->fn; local_data = thr->data; thr->fn = NULL;`
- **team.c:664-665** writer (master): `nthr->fn = fn; nthr->data = data;` (plain)
- Synchronization: the dock barrier's last-arriver `__atomic_store_n(&bar->generation, ..., RELEASE)` (bar.c:41) and waiters' `__atomic_load_n(..., ACQUIRE)` (bar.c:49) provide cross-write ordering.
- **Subtle**: master writes `pool->threads[i] = nthr` (team.c:635) when reshuffling for affinity, but the secondary in the idle loop never reads `pool->threads`. The reverse-direction write (`pool->threads[thr->ts.team_id] = thr` at team.c:121) happens **before first dock wait**. So `pool->threads` is master-only after that.
- **Classification:** code-review-only; the implicit invariant "every thread released from dock has had `thr->fn` initialised" is not asserted.

### F7 — `gomp_free_pool_helper` / `gomp_pause_pool_helper` exit protocol: ordering of `thread_pool = NULL` vs `pthread_detach`/`pthread_exit`
- **team.c:240-260** (free helper): wait_last → `gomp_sem_destroy(&thr->release)` → `thr->thread_pool = NULL; thr->task = NULL;` → `pthread_detach; pthread_exit(NULL);`
- **team.c:1046-1057** (pause helper): wait_last → `gomp_sem_destroy(&thr->release)` → `thr->thread_pool = NULL; thr->task = NULL;` → `pthread_exit(NULL);`
- **team.c:142-146** (idle-loop self-exit on shrunk team): `gomp_sem_destroy(&thr->release); pthread_detach(pthread_self()); thr->thread_pool = NULL; thr->task = NULL;` — order of `detach` vs `NULL` is reversed compared to helpers.
- Mechanism: the TLS destructor `gomp_free_thread` (team.c:265) checks `if (pool)`. If `thr->thread_pool` is still non-NULL when the destructor fires, it will **double-free** the pool.
- For the helpers, NULL is written before `pthread_exit`, so the TLS destructor short-circuits.
- For team.c:142-146 (idle-loop exit) the `thr->thread_pool = NULL` happens **after** `pthread_detach` but **before** `return NULL`. The pthread is still alive after `detach` — exit is delayed until `return NULL`, so the NULL write completes first. **Holds — but extremely subtle.**
- **Classification:** code-review-only.

### F8 — `gomp_resolve_num_threads` unsigned underflow in CAS loop (parallel.c:105-115, 117-122)
- `busy = pool->threads_busy` (unsigned long), `icv->thread_limit_var` (unsigned int): the expression `icv->thread_limit_var - busy + 1` is computed in unsigned arithmetic. If `busy > thread_limit_var + 1`, the result wraps to a huge value and `num_threads` is **not** clamped.
- Both the `HAVE_SYNC_BUILTINS` CAS path and the mutex-protected fallback have the same arithmetic bug.
- Compensation: `busy <= thread_limit_var` is supposed to be an invariant, but the CAS loop is what enforces it. The invariant breaks if any sibling team has not yet decremented (parallel.c:155-157 in `GOMP_parallel_end` happens after `gomp_team_end`).
- **Classification:** test-verifiable; write a stress test with deeply nested teams.

### F9 — `pool->threads_busy` increment is in `gomp_resolve_num_threads` but decrement is in `GOMP_parallel_end` only
- `parallel.c:130-135` `GOMP_parallel_start` calls `gomp_resolve_num_threads` (which bumps `threads_busy`) and `gomp_team_start`, but does **not** call `GOMP_parallel_end`. The matching decrement is the user's eventual `GOMP_parallel_end` call (or compiler-emitted equivalent).
- If `gomp_team_start` aborts (e.g. `pthread_create` fails → `gomp_fatal` at line 863), the increment is leaked.
- **Classification:** code-review-only.

### F10 — Bookkeeping inflation: `gomp_managed_threads` temporarily counts dying threads (team.c:732-745, 883-900)
- When `affinity_count > 0`, line 740 bumps `gomp_managed_threads` by `nthreads + affinity_count - old_threads_used` (the "to die" threads are counted). Line 894 then decrements by `-affinity_count`. **Window**: between dock release at 873 and decrement at 894, a sibling contention group reading `gomp_managed_threads` sees inflated count and may refuse to spawn its own team.
- Not a correctness violation; oversubscription / undersubscription window only.
- **Classification:** code-review-only.

### F11 — `nthr->ts.level = team->prev_ts.level + 1` is plain-written by master to **live secondary's TLS** (team.c:647)
- For reused idle secondaries, the master plain-writes `nthr->ts.level`, `nthr->ts.active_level`, `nthr->ts.place_partition_off`, etc. (team.c:643-666).
- The secondary in the idle loop reads `thr->ts.*` only **after** dock release (team.c:126). Release-acquire on dock makes this safe.
- But: `omp_get_level()` (parallel.c:300-302) is callable from a docked secondary if some external code does so. A docked secondary's `thr->ts.level` is whatever it was set to in the previous region.
- **Classification:** code-review-only.

### F12 — `pool->last_team` is freed by **destructor** at team.c:297-298 without serialising against a concurrent `gomp_team_start` that just read it via `get_last_team`
- TLS destructor `gomp_free_thread` (team.c:265) runs when the master's pthread exits. Between `get_last_team` setting `pool->last_team = NULL` (team.c:160) and the master returning, the master is mid-`gomp_team_start` and the destructor could *not* fire. **Holds for the destructor case.**
- `gomp_pause_host` (team.c:1102-1103) similarly frees `pool->last_team` after the join — but `gomp_pause_host` runs on the master thread, same as any future `gomp_team_start`, so they cannot interleave.
- **Classification:** code-review-only — only matters if a non-master thread ever calls these.

### F13 — `team->ordered_release[i]` for `i > 0` writer is **different** in newly-created vs reused secondary paths
- Newly-created pthread: secondary writes its own slot at **team.c:102** before dock wait at line 123.
- Reused idle thread: **master** writes the slot at **team.c:666** before dock wait at line 873.
- Both paths converge at the dock release-acquire. Consumed in `ordered.c` (e.g. line 187 `gomp_sem_post(team->ordered_release[id])`) which runs **inside** the parallel region — after dock release. Safe.
- Concern: if a `team_malloc` returns uninitialised memory (it does — `team_malloc = gomp_malloc` on POSIX, not cleared), the `ordered_release[i]` slots for `i > 0` are garbage **before** team.c:102 / team.c:666 writes them. Holds for current callers.
- **Classification:** code-review-only.

### F14 — `team->barrier`'s `total` is set on alloc but not re-set on cached-team reuse
- **team.c:190** `gomp_barrier_init(&team->barrier, nthreads)` only runs on fresh allocation.
- Cached team: `team->barrier.total == nthreads` is invariant only if every prior reuse had the same `nthreads` (enforced by the `last_team->nthreads == nthreads` check at line 158).
- Hold.

### F15 — `gomp_team_start`'s `pthread_create` failure path calls `gomp_fatal` (team.c:862-863) → process exit
- Any `pthread_create` failure (EAGAIN due to thread limit reached, etc.) is unrecoverable: `gomp_fatal` terminates the process.
- **Classification:** code-review-only.

### F16 — `awaited` and `awaited_final` decremented by different code paths but consistently
- `gomp_team_barrier_wait_final` is called by the master at `gomp_team_end:957` and by each secondary at `gomp_thread_start:115/130`. Cancel sets `BAR_CANCELLED` but does **not** modify `awaited` / `awaited_final`. Threads that "exit early" due to cancellation still go through `gomp_team_barrier_wait_cancel_end` (which decrements `awaited` via `wait_start`) and `gomp_team_barrier_wait_final` (which decrements `awaited_final`). Both counters get decremented symmetrically.
- **Classification:** code-review-only.

### F17 — Memory ordering: `bar.c:212` `team->barrier.generation |= BAR_CANCELLED` is plain (not atomic); only the futex_wake is "atomic" (kernel syscall)
- See F3.

---

## Catalog: state variables under each lock

| Lock | Variables protected |
|---|---|
| `team->task_lock` | `task_queue` (priority queue ops), `task_count`, `task_running_count`, `task_queued_count`, `task_detach_count`, `team->barrier.generation` flag bits (`BAR_CANCELLED`, `BAR_TASK_PENDING`, `BAR_WAITING_FOR_TASK`) via inline helpers `bar.h:132-148` ("All the inlines below must be called with team->task_lock held"). `taskgroup->cancelled` write (parallel.c:262-265). |
| `team->work_share_list_free_lock` | `work_share_list_free` (only when `!HAVE_SYNC_BUILTINS`). |
| `gomp_managed_threads_lock` | `gomp_managed_threads` and `pool->threads_busy` (only when `!HAVE_SYNC_BUILTINS`). |
| dock barrier (futex+atomic on `bar->generation`) | dock entry/exit; provides release-acquire pairing for `nthr->fn`, `nthr->data`, `nthr->ts.*`, `team->ordered_release[i]`, `pool->threads[i]`. |
| (no lock) | `pool->last_team`, `pool->threads`, `pool->threads_used`, `pool->threads_size` — single-master discipline. |

---

## Top 4-5 candidate bug families (one-page summary)

**1. Stale `BAR_CANCELLED` on cached team's `team->barrier.generation` (F2).** A cancelled region's `gomp_team_end` runs `gomp_team_barrier_wait_final`; the last-arriver store preserves the cancel bit (`bar.c:100-107` adds BAR_INCR to a state that already had `BAR_CANCELLED` set). The team is then cached in `pool->last_team` (team.c:1010-1012). `gomp_new_team` resets `work_share_cancelled`/`team_cancelled` (team.c:217-218) but **does not** clear `bar->generation`'s cancel bit, because the `gomp_barrier_init` call is skipped on the reuse path. The next region's `GOMP_cancellation_point` (parallel.c:228-229) returns true spuriously until the next non-cancellable last-arriver store explicitly clears the bit (`bar.c:102`). Strong, model-checkable.

**2. Lost cancel via plain `|=` race on `team->barrier.generation` (F3).** `gomp_team_barrier_cancel` (bar.c:204-215) sets `BAR_CANCELLED` via plain `|=` under `task_lock`, but the last-arriver in `gomp_team_barrier_wait_end` (bar.c:104) does an `__atomic_store_n` RELEASE **without** the lock. The atomic store can clobber the cancel bit. Waiters never observe cancellation; futex_wake reaches them but they immediately re-sleep on the next generation. Related to PR112356 fix; cancel-write path was not converted.

**3. PR122314 ABA on `team->barrier` via `pool->last_team` reuse (F4).** A secondary in `gomp_barrier_handle_tasks` holds a stale `team`/`bar` pointer; master ends, caches, and reuses the same team struct for a new region. Defense `task_count != 0` (task.c:1572) is the **only** thing preventing the secondary from running tasks from a different region. Documented but fragile.

**4. Split-window publication in `gomp_team_start` (F5).** Long function (lines 319-940) with many observable intermediate states: `pool->threads_used = nthreads` published before `realloc` (488 vs 497); `gomp_managed_threads` temporarily inflated by "to die" threads (740 vs 894); dock `reinit` between two non-atomic writes. Single-master discipline saves the day, but is implicit and unasserted.

**5. Cross-thread `thr->fn`/`thr->data` handoff (F6) and idle-loop self-exit ordering (F7).** The master plain-writes `nthr->fn`/`nthr->data` and relies on the dock barrier's RELEASE for visibility. The idle-loop self-exit at team.c:142-146 sequences `gomp_sem_destroy → pthread_detach → thr->thread_pool = NULL`; double-free protection depends on the NULL write happening before the pthread actually exits. Sound but unasserted.
