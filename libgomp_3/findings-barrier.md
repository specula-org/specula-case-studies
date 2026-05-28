# Phase 3 Deep Analysis — libgomp Linux Barrier / Sync Primitives

Target: **Category B (Concurrent / Lock-Free / Runtime)**. The barrier (`bar.c`/`bar.h`) is the central coordination primitive for OpenMP team lifecycle and tasking. All paths absolute.

---

## 0. State machine — `gomp_barrier_t` and `bar->generation`

Layout (`/home/ubuntu/Specula/case-studies/libgomp_3/artifact/gcc/libgomp/config/linux/bar.h:35-43`):

```c
typedef struct {
  unsigned total           __attribute__((aligned (64)));
  unsigned generation;
  unsigned awaited         __attribute__((aligned (64)));
  unsigned awaited_final;
} gomp_barrier_t;
```

### 0.1 `bar->generation` flag bits (bar.h:47-54)

| Bit | Name | Meaning | Slot sharing |
|-----|------|---------|--------------|
| 1 | `BAR_TASK_PENDING` | (stored) explicit task queued | shares slot with `BAR_WAS_LAST` |
| 1 | `BAR_WAS_LAST` | (caller-local `state` only; never stored back) this thread closed barrier | shares slot with `BAR_TASK_PENDING` |
| 2 | `BAR_WAITING_FOR_TASK` | (stored) last arriver but task queue non-empty | own slot |
| 4 | `BAR_CANCELLED` | (stored) `#pragma omp cancel` raised | own slot |
| 8 | `BAR_INCR` | counter step (low 3 bits flags, high bits counter) | — |

### 0.2 Transitions

| Site | Operation | Memory model |
|------|-----------|--------------|
| bar.h:91 | `__atomic_load_n(&generation, ACQUIRE)` (snapshot, drops PENDING/WAITING bits via `& -BAR_INCR \| BAR_CANCELLED`) | ACQUIRE |
| bar.h:98 | `__atomic_add_fetch(&awaited, -1)` | ACQ_REL |
| bar.h:115/118 | mirror on `awaited_final` | ACQUIRE / ACQ_REL |
| bar.c:41-43 (simple `wait_end`, last) | `__atomic_store_n(&generation, generation+INCR)` + futex_wake INT_MAX | RELEASE |
| bar.c:48 (simple `wait_end`, waiter) | `do_wait` then `__atomic_load_n … ACQUIRE` | ACQUIRE |
| bar.c:104 (team `wait_end`, last, no-task) | store `(state & ~BAR_CANCELLED) + INCR - BAR_WAS_LAST` + wake INT_MAX | RELEASE |
| bar.c:115/119 (team `wait_end`, waiter) | `__atomic_load_n … ACQUIRE` | ACQUIRE |
| bar.c:169 (team `wait_cancel_end`, last, no-task) | store new generation (does NOT clear CANCELLED) + wake INT_MAX | RELEASE |
| bar.c:212 (`gomp_team_barrier_cancel`) | **`generation \|= BAR_CANCELLED` plain RMW** under `task_lock` + wake INT_MAX | **NON-ATOMIC** |
| bar.h:135/141/147 (`set_task_pending`/`clear_task_pending`/`set_waiting_for_tasks`) | **plain `\|=` / `&=`** under `task_lock` | **NON-ATOMIC** |
| bar.h:167 (`gomp_team_barrier_done`) | `__atomic_store_n(&generation, (state & -INCR) + INCR)` — **PR112356 fix** | RELEASE |

### 0.3 Lifecycle (one barrier round)

```
state == G
   N-1 arrivers:  awaited--, snapshot G, do_wait
   last arriver:  awaited-- == 0  → state |= BAR_WAS_LAST
        +-- no-task: store G+INCR + clear BAR_CANCELLED, futex_wake INT_MAX (bar.c:104)
        +-- task path: gomp_barrier_handle_tasks(state)
                       ├─ if task_count==0: gomp_team_barrier_done (publish), wake
                       └─ else: set WAITING_FOR_TASK, drain tasks, then done, wake
```

---

## 1. Findings

### 1.1 `gomp_team_barrier_cancel` plain RMW on shared `generation` (HIGH)

**File:** `bar.c:203-215`

```c
void gomp_team_barrier_cancel (struct gomp_team *team)
{
  gomp_mutex_lock (&team->task_lock);
  if (team->barrier.generation & BAR_CANCELLED)
    { gomp_mutex_unlock (&team->task_lock); return; }
  team->barrier.generation |= BAR_CANCELLED;
  gomp_mutex_unlock (&team->task_lock);
  futex_wake ((int *) &team->barrier.generation, INT_MAX);
}
```

**Interleaving.** All other generation accesses are `__atomic_*`. Here the load+store is *plain* and serialised against other callers only by `task_lock`. But the racing publisher `gomp_team_barrier_wait_end` at bar.c:104 does `__atomic_store_n(&bar->generation, …, MEMMODEL_RELEASE)` *without holding `task_lock`*.

Schedule:
1. T_cancel: lock; read `generation = G` (plain).
2. T_last (no-task path): atomically stores `G+INCR` with RELEASE (no lock).
3. T_cancel: writes `G | BAR_CANCELLED`, **overwriting** the published `G+INCR`. Counter regresses.
4. Waiters in `do_wait(addr, G)` see the futex value change (G → G+INCR → G|BAR_CANCELLED), futex_wait may return EAGAIN, but the loop condition `state_is_incremented` (bar.c:123) sees `gen < next_state` and re-sleeps. Team wedges until something else bumps the counter.

The comment at bar.c:150-153 claims "on a cancellable barrier we should never see all threads to arrive" justifying that BAR_WAS_LAST + BAR_CANCELLED is impossible — but `gomp_team_barrier_wait_end` (non-cancellable variant) is called from non-cancellable barriers that can run concurrently with `GOMP_cancel_parallel` reaching `gomp_team_barrier_cancel`.

The other RELEASE publisher in the task path (`gomp_team_barrier_done` at task.c:1583/1620) *is* called under `task_lock`, so that one is safe.

**Compensating mechanism.** None against the no-task path (bar.c:104). On x86 the 32-bit load+store happens to be benign at the hardware level (single uops), but the C11 model classifies it as UB and the compiler is allowed to reorder/optimise.

**Classification:** model-checkable + code-review.

---

### 1.2 No-task `wait_end` clears `BAR_CANCELLED` (LOW; composes with 1.1)

**File:** `bar.c:100-107`

```c
else {
  state &= ~BAR_CANCELLED;
  state += BAR_INCR - BAR_WAS_LAST;
  __atomic_store_n (&bar->generation, state, MEMMODEL_RELEASE);
  futex_wake ((int *) &bar->generation, INT_MAX);
  return;
}
```

Non-cancellable `wait_end` intentionally drops `BAR_CANCELLED`; cancellable variant (bar.c:166-172) keeps it. Intent is clean, but combined with § 1.1, a `cancel` racing this path can be silently lost (overwrite) *or* persist past the next generation (cancel runs after publish).

**Classification:** code-review.

---

### 1.3 PR112356 fix in `gomp_team_barrier_done` (REFERENCE)

**File:** `bar.h:162-169`

```c
static inline void gomp_team_barrier_done (gomp_barrier_t *bar, gomp_barrier_state_t state)
{
  /* Need the atomic store for acquire-release synchronisation with the
     load in `gomp_team_barrier_wait_{cancel_,}end`.  See PR112356  */
  __atomic_store_n (&bar->generation, (state & -BAR_INCR) + BAR_INCR,
                    MEMMODEL_RELEASE);
}
```

**Original bug.** Pre-fix this was a plain `bar->generation = …`. Waiters at bar.c:115 do `__atomic_load_n … MEMMODEL_ACQUIRE`. The atomic-load/plain-store pair is a C11 data race (UB) and provides no acquire-release synchronisation, so waiters could (a) miss the update and (b) read stale heap state behind the barrier.

**Surfaces only in task path.** The no-task path at bar.c:104 already used RELEASE. The task path published through `gomp_team_barrier_done` (called from `gomp_barrier_handle_tasks` at task.c:1583 and 1620). PR112356 made the task path match.

**Sibling sites still plain.** `set_task_pending` (bar.h:135), `clear_task_pending` (bar.h:141), `set_waiting_for_tasks` (bar.h:147) all do plain RMW. The header comment (bar.h:129-130) claims `task_lock` is held during these calls, but `bar.c:104`'s unlocked RELEASE store is the formal-race partner. Disjoint-phase reasoning saves it in practice.

**Classification:** code-review (fix is in place); model-checkable for the sibling racy sites (§ 1.1).

---

### 1.4 `task.c:1620` unlock-then-wake (LOW)

`gomp_team_barrier_done` publishes under `task_lock`; then unlock; then `gomp_team_barrier_wake(0)`. Between unlock and wake a different thread can observe the new generation, exit the barrier, and enter the next region's `gomp_create_task` (which increments `task_count` under the same lock). PR122356 fixed `task_count` decrement to use RELEASE on the `0` transition (task.c:1708-1711) so `bar.c:94`'s ACQUIRE read sees current state.

**Classification:** code-review.

---

### 1.5 `state`/`generation` re-anchor in waiter loop; wrap edge in `state_is_incremented` (MEDIUM)

**File:** `bar.c:110-124`, `bar.h:171-177`

```c
generation = state;
state &= ~BAR_CANCELLED;
do {
  do_wait ((int *) &bar->generation, generation);
  gen = __atomic_load_n (&bar->generation, MEMMODEL_ACQUIRE);
  if (__builtin_expect (gen & BAR_TASK_PENDING, 0)) {
    gomp_barrier_handle_tasks (state);
    gen = __atomic_load_n (&bar->generation, MEMMODEL_ACQUIRE);
  }
  generation |= gen & BAR_WAITING_FOR_TASK;
} while (!gomp_barrier_state_is_incremented (gen, state));
```

```c
static inline bool gomp_barrier_state_is_incremented (gen, state) {
  unsigned next_state = (state & -BAR_INCR) + BAR_INCR;
  return next_state > state ? gen >= next_state : gen < state;
}
```

**Wrap window.** `state` carries flag bits (BAR_CANCELLED stripped, BAR_WAITING_FOR_TASK accumulated). When the counter wraps (UINT_MAX − INCR + 1), `next_state = 0`, the function picks the `gen < state` branch — but `state` can carry `BAR_WAITING_FOR_TASK = 2`, so `gen < state` becomes `gen < 2` — a much narrower wake window than intended. With BAR_INCR=8 and 32-bit counter, wrap occurs every 2^29 rounds.

The `generation |= gen & BAR_WAITING_FOR_TASK` re-anchor (bar.c:121) means consecutive iterations sleep on slightly different futex values; futex_wait will return EAGAIN when the published value differs from the cached `generation`, which is benign except across the wrap.

**Classification:** model-checkable (bounded wrap, 4-bit counter).

---

### 1.6 `awaited_final` reset plain store (LOW)

**File:** `bar.c:132-139`, `bar.h:113-121`

```c
void gomp_team_barrier_wait_final (gomp_barrier_t *bar)
{
  gomp_barrier_state_t state = gomp_barrier_wait_final_start (bar);
  if (__builtin_expect (state & BAR_WAS_LAST, 0))
    bar->awaited_final = bar->total;   /* plain store */
  gomp_team_barrier_wait_end (bar, state);
}
```

`awaited_final` exists *because* `awaited` may be inconsistent post-cancellation (see comment at team.c:953-956). The reset is plain, depends on the calling convention that `wait_final` is called exactly once per team-end per thread (team.c:115, 130, 957).

**Classification:** code-review.

---

### 1.7 `gomp_mutex_lock_slow` three-state invariant fragility (LOW)

**File:** `mutex.c:36-64`, `mutex.h:60-66`

States: 0 = unlocked, 1 = locked uncontended, -1 = locked with waiters.

```c
/* Second loop waits until mutex is unlocked. We always exit this
   loop with wait flag set, so next unlock will awaken a thread. */
while ((oldval = __atomic_exchange_n (mutex, -1, MEMMODEL_ACQUIRE)))
  do_wait (mutex, -1);
```

The invariant: *whenever a sleeper exists in `futex_wait(mutex, -1)`, the mutex value is `-1`*. This holds because (a) sleepers wrote -1 themselves before sleeping; (b) other contenders also exchange-to-(-1), preserving the flag; (c) the fast-path CAS(0→1) only succeeds when `mutex == 0`, which only happens right after a successful unlock that has already returned. So a fast-path lock that sets `mutex = 1` cannot race with a sleeper.

Fragile because any patch that changes the fast-path lock could break the invariant.

**Classification:** code-review.

---

### 1.8 `gomp_sem_post` SEM_WAIT chained-wake liveness (MEDIUM)

**File:** `sem.h:66-85`, `sem.c:33-78`

```c
static inline void gomp_sem_post (gomp_sem_t *sem)
{
  int count = *sem;
  while (!__atomic_compare_exchange_n (sem, &count,
                                       (count + SEM_INC) & ~SEM_WAIT, true,
                                       MEMMODEL_RELEASE, MEMMODEL_RELAXED))
    continue;
  if (__builtin_expect (count & SEM_WAIT, 0))
    gomp_sem_post_slow (sem);
}
```

**Claim** (sem.h:71-77): "if there are waiting threads then when one is awoken it will set SEM_WAIT again, so other waiting threads are woken on a future gomp_sem_post. Furthermore, the awoken thread will wake other threads in case gomp_sem_post was called again before it had time to set SEM_WAIT."

Walking the slow waiter (sem.c:55-78):

```c
while (1) {
  unsigned int wake = count & ~SEM_WAIT;
  int newval = SEM_WAIT;
  if (wake != 0) newval |= wake - SEM_INC;
  if (__atomic_compare_exchange_n (sem, &count, newval, false,
                                   MEMMODEL_ACQUIRE, MEMMODEL_RELAXED)) {
    if (wake != 0) {
      if (wake > SEM_INC) gomp_sem_post_slow (sem);  /* chain */
      break;
    }
    do_wait (sem, SEM_WAIT);
    count = *sem;
  }
}
```

**Invariant required.** "Whenever a poster finds `SEM_WAIT` clear, there is at least one currently-running awakened-but-not-yet-CASed waiter that will see the increased count and chain a wake."

**Edge scenario.** Two sleepers (one armed `SEM_WAIT` via CAS, the other reached the second loop with count=SEM_WAIT, did CAS(SEM_WAIT→SEM_WAIT), and slept). Posts accumulate while waiter T2 is preempted in its wake-to-CAS window; subsequent posts find SEM_WAIT clear and do *not* call `post_slow`. When T2 resumes, it observes the accumulated count and chains wakes via `post_slow` for `wake > SEM_INC`. Correctness depends on T2 making forward progress.

**Classification:** model-checkable; depends on scheduler fairness.

---

### 1.9 `do_wait` then plain `count = *sem` (LOW; formal data race)

**File:** `sem.c:74-75`

```c
do_wait (sem, SEM_WAIT);
count = *sem;          /* plain int read */
```

All other `do_wait` callers re-read via `__atomic_*`. sem.c:74 is the outlier: plain read of int. Race with posters' atomic CAS. On x86 the aligned 32-bit load is benign at the hardware level, but the C11 model considers this UB and the compiler may legally hoist or elide. The subsequent CAS at sem.c:64 self-corrects `count`, so the bug is benign.

**Classification:** code-review.

---

### 1.10 `ptrlock` RELAXED intermediate; compiler barrier + ACQUIRE rescues (LOW)

**File:** `ptrlock.c:34-57`

```c
__atomic_compare_exchange_n (ptrlock, &oldval, 2, false,
                             MEMMODEL_RELAXED, MEMMODEL_RELAXED);
…
do  do_wait (intptr, 2);
while (__atomic_load_n (intptr, MEMMODEL_RELAXED) == 2);
__asm volatile ("" : : : "memory");
return (void *) __atomic_load_n (ptrlock, MEMMODEL_ACQUIRE);
```

RELAXED CAS on the 1→2 flag transition is OK because the setter (ptrlock.h:67-69) uses `__atomic_exchange_n … MEMMODEL_RELEASE` and the *final* ACQUIRE load (ptrlock.c:56) supplies the necessary release-acquire pair against the setter's RELEASE.

**Classification:** code-review.

---

### 1.11 `gomp_barrier_reinit` plain store to `total` (LOW)

**File:** `bar.h:64-68`

```c
static inline void gomp_barrier_reinit (gomp_barrier_t *bar, unsigned count) {
  __atomic_add_fetch (&bar->awaited, count - bar->total, MEMMODEL_ACQ_REL);
  bar->total = count;
}
```

`awaited` patched atomically; `total` reassigned non-atomically. Calling convention: only at team setup with no threads at the barrier.

**Classification:** code-review.

---

## 2. Summary table

| # | Site | Class | Severity |
|---|------|-------|----------|
| 1.1 | cancel plain RMW vs unlocked RELEASE | model-checkable | High |
| 1.2 | no-task path clears BAR_CANCELLED | code-review | Low (composes with 1.1) |
| 1.3 | PR112356 reference + sibling plain RMWs | code-review | Reference |
| 1.4 | task.c:1620 unlock-then-wake | code-review | Low |
| 1.5 | generation overflow wrap in state_is_incremented | model-checkable | Medium |
| 1.6 | awaited_final plain reset | code-review | Low |
| 1.7 | mutex three-state fragility | code-review | Low |
| 1.8 | sem chained-wake liveness | model-checkable | Medium |
| 1.9 | sem.c:75 plain read of `*sem` | code-review | Low |
| 1.10 | ptrlock RELAXED intermediate | code-review | Low |
| 1.11 | barrier reinit plain `total = count` | code-review | Low |

---

## 3. Modeling implications

TLA+ spec must capture:
- Per-thread program counter split at every atomic op in `wait_start`, both branches of `wait_end`, the wait loop with task re-check, `gomp_team_barrier_cancel`.
- Shared state: `awaited`, `generation` (flag bits broken out), `awaited_final`, `total`, `task_count`, `task_lock`.
- Memory-model labels at each access (most ACQ_REL/ACQUIRE/RELEASE; plain at bar.c:91, 137, 212 and bar.h:135/141/147).
- Futex parking + spurious EAGAIN wakeups.
- Cancellation arriving at any point during a barrier round.

---

# Top-5 Summary

**`bar->generation` state machine (32-bit packed):** bits 0–2 are flags, bits 3+ are a counter advanced by `BAR_INCR = 8` per round. Bit 1 (`BAR_TASK_PENDING`, stored) shares its slot with `BAR_WAS_LAST` (caller-local in `state`, never stored back). Bit 2 = `BAR_WAITING_FOR_TASK` (set by last arriver when tasks remain). Bit 4 = `BAR_CANCELLED`. Each round: arrivers `awaited--`; last arriver either (no-task path) stores `(state & ~BAR_CANCELLED) + BAR_INCR - BAR_WAS_LAST` with RELEASE (bar.c:104), or (task path) calls `gomp_barrier_handle_tasks` which publishes via `gomp_team_barrier_done` (bar.h:167, the PR112356 fix swapped plain assign for `__atomic_store_n … RELEASE`).

**Top 5 candidate bug families:**

1. **Cancel-vs-publish race on `generation` (bar.c:212).** `gomp_team_barrier_cancel` does a plain `generation |= BAR_CANCELLED` RMW under `task_lock`, but the unlocked RELEASE publisher at bar.c:104 is not serialised by that lock — formally a C11 data race, and a real interleaving can overwrite the just-published `G+INCR`, regressing the counter and wedging waiters.

2. **Generation counter wrap (bar.h:171-177).** `gomp_barrier_state_is_incremented` handles unsigned wrap via `next_state > state`, but when `state` carries `BAR_WAITING_FOR_TASK = 2` and counter wraps so `next_state == 0`, the wrap branch becomes `gen < 2` — a far narrower wake window than designed.

3. **Lost-wakeup chain in `gomp_sem_post` (sem.h:66-85 / sem.c:55-78).** Correctness relies on awakened waiters re-arming `SEM_WAIT` and chaining `gomp_sem_post_slow` on accumulated counts. Liveness assumes the awakened thread runs.

4. **Sibling plain RMWs on `bar->generation` (bar.h:135/141/147; bar.c:212).** All companion task-flag mutators rely on `task_lock` while the no-task RELEASE publisher does not.

5. **Plain stores `awaited = total` (bar.c:91), `awaited_final = total` (bar.c:137), `total = count` (bar.h:67).** Protected only by calling-convention quiescence; any future caller change could expose torn reads or stale snapshots.
