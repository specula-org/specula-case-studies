# libgomp Work-Share Runtime — Phase 3 Deep Analysis

All paths absolute under `/home/ubuntu/Specula/case-studies/libgomp_3/artifact/gcc/libgomp/`.

## 1. Linearization points in `gomp_iter_dynamic_next` (iter.c:184-252)

The "lockless" dynamic iterator has **two distinct linearization points** depending on `ws->mode == 1`:
- Fast path: `iter.c:196` `long tmp = __sync_fetch_and_add (&ws->next, chunk);`
- Fallback CAS loop: `iter.c:242` `tmp = __sync_val_compare_and_swap (&ws->next, start, nend);`

Participants of one logical "claim a chunk" operation:
1. `ws->next` (only mutated; atomic via `__sync_*`).
2. Local snapshots of `ws->end/incr/chunk_size/mode` read once at entry (iter.c:190-194). These are written exactly once by `gomp_loop_init` (loop.c:39-83) under the publication protocol of `gomp_work_share_init_done` (libgomp.h:1515-1521) / `gomp_ptrlock_set`.
3. The handoff that lets readers see the init: writer's `gomp_ptrlock_set` (MEMMODEL_RELEASE at config/linux/ptrlock.h:65-70) pairs with each reader's `gomp_ptrlock_get` (MEMMODEL_ACQUIRE at ptrlock.h:48-62) in `gomp_work_share_start` (work.c:209).

**Classification: model-checkable.** Trivially provable in TLA+ that no iteration is delivered twice as long as the initial snapshot is published-before-claim.

**Subtle observation (mode==1 path).** `__sync_fetch_and_add` commits even when `ws->next` is already past `ws->end`. The mode heuristic in loop.c:70 — `ws->mode = ws->end < (LONG_MAX - (nthreads + 1) * ws->chunk_size);` — bounds the overshoot to `nthreads + 1`. If `gomp_iter_dynamic_next` is ever called from a non-team helper (e.g. a task helper inside `gomp_barrier_handle_tasks`), `ws->next` could wrap. **Code-review-only.**

## 2. Work-share alloc/free protocol — "second entry onward" invariant

The header contract at `libgomp.h:816-821` says free can race alloc; alloc may only consume from the second entry onward. The actual code is `work.c:52-64`:

```
#ifdef HAVE_SYNC_BUILTINS
  ws = team->work_share_list_free;
  /* We need atomic read from work_share_list_free,
     as free_work_share can be called concurrently.  */
  __asm ("" : "+r" (ws));
  if (ws && ws->next_free)
    {
      struct gomp_work_share *next = ws->next_free;
      ws->next_free = NULL;
      team->work_share_list_alloc = next->next_free;
      return next;
    }
```

Concurrent free is at `work.c:163-170` via `__sync_bool_compare_and_swap`.

**Finding 2A (potential A-B-A on the head pointer).** The atomic read at work.c:53-56 is only a compiler barrier (`__asm("" : "+r"(ws))`), not even an acquire. Safety relies on the single-writer property: `alloc_work_share` runs in the critical section between work-shares (gated by the previous work-share's ptrlock). Any future refactor adding a second concurrent allocator (e.g. parallel target offload) silently breaks the invariant. **Code-review-only**, model-checkable if abstracted.

**Finding 2B (compiler-barrier strength).** Comment claims "atomic read" yet implementation provides only a compiler barrier. The subsequent `ws->next_free` load has an address dependency on the head load — preserved on aarch64/power, but the dependency on hardware semantics is undocumented. **Code-review-only.**

## 3. Work-share lifecycle vs barrier — `work_shares_to_free` invariant

`work.c:228-256` (`gomp_work_share_end`) only writes `team->work_shares_to_free` on the last thread out of the barrier:
```
work.c:245    if (gomp_barrier_last_thread (bstate))
work.c:249      team->work_shares_to_free = thr->ts.work_share;
work.c:250      free_work_share (team, thr->ts.last_work_share);
```

`team.c:960-969` walks this list during cancel cleanup:
```
team.c:960    struct gomp_work_share *ws = team->work_shares_to_free;
team.c:961    do { struct gomp_work_share *next_ws = gomp_ptrlock_get (&ws->next_ws);
team.c:964      if (next_ws == NULL) gomp_ptrlock_set (&ws->next_ws, ws);
team.c:966      gomp_fini_work_share (ws); ws = next_ws; } while (ws != NULL);
```

**Finding 3A (race on `work_shares_to_free` store under cancel + nowait).** The nowait completer also writes this field at work.c:316. If a team is cancelled while some threads are mid-nowait and others are at the barrier, both writers may attempt unordered, unsynchronized stores. The team-cancel cleanup walk at team.c:960 reads `work_shares_to_free` and traverses it via `next_ws` ptrlocks. A torn/stale store could cause the cleanup to skip a live work-share (leak of `ordered_team_ids`) or walk a freed one (use-after-free on the ptrlock). **Classification: model-checkable.**

**Finding 3B (ptrlock state-1 deadlock during cleanup).** `gomp_ptrlock_get` at team.c:963 has side effects: state-0 CASes to 1 and returns NULL; state-1 parks on futex (config/linux/ptrlock.c:53). If cancellation happens after `gomp_work_share_start` but before `gomp_work_share_init_done`, the ptrlock is in state 1 with no thread set to release it. The cleanup walk would block forever on the futex. Currently masked because all callers run init_done immediately, but no runtime assertion exists. **Code-review-only.**

## 4. Ordered loops and `ordered_release` handoff

`ordered.c:38-225`. The only `???` in the workshare code is at ordered.c:206-219 — an explicit dirty read of `ws->ordered_owner` outside the lock:

```
ordered.c:206  /* ??? I believe it to be safe to access this data without taking the
ordered.c:207     ws->lock.  ... */
ordered.c:220   __atomic_thread_fence (MEMMODEL_ACQ_REL);
ordered.c:221   if (ws->ordered_owner != thr->ts.team_id)
```

**Finding 4A.** `ws->ordered_owner` is plain `unsigned` shared across threads with no atomic load. Correct on current ISAs (no plain-store tearing), but TSAN **will** flag it. **Code-review-only for correctness; test-verifiable as TSAN.**

**Finding 4B.** `gomp_ordered_static_init` (ordered.c:152-162) always posts to `ordered_release[0]`, regardless of which thread allocates the workshare. Correct because OpenMP semantics start static-ordered at team_id 0, but it depends on the **compiler** emitting `static_trip` to begin at thread 0. **Code-review-only.**

## 5. `GOMP_loop_end` vs `GOMP_loop_end_nowait`

**Finding 5A (nowait + ordered + cancel leaves stale `ordered_release` posts).** `gomp_work_share_end_nowait` at work.c:287-320 never inspects `ws->ordered_owner` or `team->ordered_release[]`. `team->ordered_release[i]` is per-team, not per-workshare; the semaphore is never reset between workshares. If `omp for ordered nowait` is cancelled mid-way, a posted-but-unwaited semaphore poisons the next ordered loop — the next thread proceeds without blocking. **Classification: model-checkable.**

**Finding 5B (race on `threads_completed` -> `work_shares_to_free`).** Between work.c:307 (`__sync_add_and_fetch`) and work.c:316 (plain store of `work_shares_to_free`), there is no fence. Under aggressive cancel-during-nowait, the cleanup at team.c:960 could see `threads_completed == nthreads` while still reading a stale `work_shares_to_free`. **Classification: model-checkable.**

## 6. `single_count` atomic counter

`single.c:36-56` and team.c:198. The CAS at single.c:47 is the linearization point.

**Finding 6A (loser-path visibility).** The CAS provides RELEASE on the winner but the loser's load of post-single-region state is not ordered with respect to the failed CAS on `team->single_count`. Safety relies on the compiler emitting the only post-CAS code on the loser path as the barrier (or no single-region accesses). For `omp single nowait`, the runtime makes no guarantees. **Code-review-only** — contract between runtime and compiler.

**Finding 6B (per-thread/team divergence).** `thr->ts.single_count` is zero-init on thread creation. If a thread were ever to join a team mid-execution (not done today, but architecturally not prevented), its counter would diverge from `team->single_count` and CAS would fail forever for that thread. No detection. **Code-review-only.**

## 7. `gomp_work_share_start` ptrlock-acquire pattern

**Finding 7A (missing `init_done` deadlocks the team).** `work.c:213` shadows `ws` with the freshly allocated one. The previous ws's ptrlock is in state 1 (held). Publication happens lazily via the *caller* calling `gomp_work_share_init_done` (libgomp.h:1519-1520). Any early-return between `gomp_work_share_start` and `gomp_work_share_init_done` (none today, but no assertion) silently deadlocks all other threads on `gomp_ptrlock_get_slow`. **Code-review-only; bug-class candidate for static analysis.**

## 8. `critical` lock asymmetric fencing

`critical.c:37-46`. Entry has explicit `__atomic_thread_fence(MEMMODEL_RELEASE)` plus mutex acquire; exit has only `gomp_mutex_unlock`. The release fence is redundant on entry (mutex provides RELEASE on unlock and ACQUIRE on lock). The asymmetry is undocumented. Correct on x86 (full-barrier mutex), the implicit OpenMP "flush on entry" collapses to mutex ACQUIRE on weakly ordered ISAs. **Code-review-only.**

## 9. Scope construct lifetime

`scope.c:43-62` registers task reductions inside a fake workshare but never ends it. Lifetime relies on lowered compiler code emitting `GOMP_workshare_task_reduction_unregister`. Compiler/LTO mismatch would leak the workshare until team end. **Code-review-only.**

## 10. Catalog of TODO/FIXME/XXX/???

| File:line | Token | Excerpt |
|-----------|-------|---------|
| `ordered.c:206` | `???` | "I believe it to be safe to access this data without taking the ws->lock." |
| `loop.c:118` (comment) | inline | "current dynamic implementation is always monotonic ... could be changed to use work-stealing" |
| `loop.c:148` (comment) | inline | "how can the chunk sizes be decreased without a central locking or atomics" |
| `loop.c:196` (comment) | inline | "For now map to schedule(static), later on we could play with feedback driven choice" (GFS_AUTO) |
| `ordered.c:247-250` (comment) | inline | "current implementation has a flaw in that it does not allow the next thread into the ORDERED section immediately after the current thread exits ... in its last iteration" — performance flaw |
| `config/linux/doacross.h:42` | `FIXME` | "back off depending on how large expected - cur is" |
| `libgomp.h:1350` | `TODO` | goacc asyncqueue, not workshare |
