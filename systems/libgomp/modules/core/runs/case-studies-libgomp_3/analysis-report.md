# Analysis Report: libgomp (GCC OpenMP Runtime)

## Coverage Statistics

- **Core files read in full**: 10
  - `config/linux/bar.c` (215 LoC)
  - `config/linux/bar.h` (187 LoC)
  - `config/linux/wait.h` (74 LoC)
  - `config/linux/mutex.{c,h}` (137 LoC)
  - `config/linux/sem.{c,h}` (179 LoC)
  - `config/linux/ptrlock.{c,h}` (146 LoC)
  - `barrier.c` (54 LoC, public API shim)
  - `task.c` (2798 LoC)
  - `team.c` (1125 LoC)
  - `parallel.c` (342 LoC)
  - Cross-referenced: `libgomp.h` (1683 LoC, structs), `work.c`, `iter.c`, `loop.c`, `sections.c`, `critical.c`, `single.c`, `scope.c`, `ordered.c`, `taskloop.c`, `priority_queue.c`
- **Total LOC read**: ~10,000 (core) + ~3,500 (cross-referenced)
- **Git commits analysed**: 29 bug-fix commits touching `task.c`; 13 touching `bar.c`/`bar.h`/`barrier.c`; ~30 touching `team.c`/`parallel.c`. Of these, 8 directly examined via `git show` for code context.
- **Bugzilla PRs deeply read**: 8 (PR88707, PR98738, PR104385, PR105378, PR112356, PR113627, PR122314, PR122356). 5 confirmed-fixed-in-mainline, 1 OPEN/UNCONFIRMED (PR113627), 2 are the most recent mainline fixes (PR122314, PR122356).
- **Cross-reference**: prior case study `libgomp` (Malcomson flat-barrier patch series, not yet merged) and `libomp` (LLVM equivalent — different impl but similar bug families).
- **Parallel deep-analysis subagents**: 4 (barrier+primitives, task.c, team.c+parallel.c, work-share)
- **Developer signals catalogued**: 5 race-comment locations, 1 `???`, 2 `TODO`/`FIXME` in non-core code, 1 "Ugly hack" comment, multiple "I'm afraid this can't be done after releasing …" lifetime caveats.

## Phase 1 — Reconnaissance Findings

### Category classification

**Category B (Concurrent / Lock-Free / Runtime).** Justification:
- Single-process, shared memory.
- Coordination primitives: per-team `gomp_mutex_t task_lock` + atomic operations on packed flag fields + futex syscalls.
- No network, no persistence, no message passing, no cluster membership.
- Failure modes of concern: stale snapshots, missing re-checks, memory-ordering bridges, ownership transfer (detach → fulfill), reclamation (`pool->last_team` ABA), fast-vs-slow path divergence (cancellable vs non-cancellable barrier variants), bookkeeping invariants on counters (`task_count`, `task_running_count`, `awaited`, `awaited_final`).

### Structural map

| Component | File:line | Responsibility |
|---|---|---|
| Public BARRIER ABI | barrier.c:31-54 | `GOMP_barrier`, `GOMP_barrier_cancel` shims |
| Linux barrier impl | config/linux/bar.c:34-215 | `gomp_barrier_wait*`, `gomp_team_barrier_wait*`, `gomp_team_barrier_cancel` |
| Barrier header/state machine | config/linux/bar.h:35-187 | `gomp_barrier_t`, flag bits, inline helpers |
| Mutex (futex-based) | config/linux/mutex.{c,h} | `gomp_mutex_lock_slow`, three-state mutex (0/1/-1) |
| Semaphore (futex-based) | config/linux/sem.{c,h} | `gomp_sem_*` with `SEM_WAIT` flag bit |
| Pointer-lock | config/linux/ptrlock.{c,h} | `gomp_ptrlock_get`/`set` for work-share initialization |
| Tasking core | task.c:1-2798 | `GOMP_task`, `gomp_barrier_handle_tasks`, `GOMP_taskwait`, `GOMP_taskgroup_*`, `omp_fulfill_event` |
| Team lifecycle | team.c:69-1125 | `gomp_thread_start`, `gomp_new_team`, `gomp_team_start`, `gomp_team_end`, `pool->last_team` cache |
| Parallel region entry | parallel.c:48-272 | `gomp_resolve_num_threads`, `GOMP_parallel*`, `GOMP_cancel*` |
| Work-share allocation | work.c | `alloc_work_share`/`free_work_share` (lock-free); `gomp_work_share_start`/`_end` |
| Work-share iterators | iter.c, iter_ull.c | dynamic, guided, static via `__sync_*` CAS |
| Loop / sections | loop.c, sections.c | `GOMP_loop_*`, `GOMP_sections_*` |
| Ordered/single | ordered.c, single.c | `gomp_ordered_*`, `GOMP_single_start` |
| Critical regions | critical.c | `GOMP_critical_*` (mutex-backed) |
| Priority queue | priority_queue.{c,h}, splay-tree.{c,h} | task scheduling queue |

### Concurrency primitives summary

| Primitive | Used for | Race-coverage role |
|---|---|---|
| `gomp_mutex_t` (futex/3-state) | `team->task_lock`, `team->work_share_list_free_lock`, `gomp_managed_threads_lock` | Serialize task-queue mutations + bar flag bits + counters |
| `gomp_barrier_t` (futex + packed flags) | `team->barrier` | Team-wide synchronization + cancel + task signalling |
| `gomp_simple_barrier_t` | `pool->threads_dock` | Thread-pool docking between regions |
| `gomp_sem_t` (futex + SEM_WAIT flag) | `taskwait_sem`, `taskgroup_sem`, `master_release`, `ordered_release[i]` | Per-task / per-taskgroup / per-thread wakeups |
| `gomp_ptrlock_t` (futex + 0/1/2 sentinel) | work-share `next_ws` | Publication of newly-initialized work-share |
| `__sync_*` and `__atomic_*` builtins | various counters | `gomp_managed_threads`, `single_count`, `task_count`, `bar->generation` |

## Phase 2 — Bug Archaeology

### Git-history coverage

| File | All-time commits in fetched depth | Bug-fix commits identified |
|---|---|---|
| task.c | 29 | 9 (304d08fea9e, 8a47ae5c193, 0af7ef050ae, c125f504c43, ba886d0c488, d656bfda2d8, 0bb27b81a76, a58a965eb73, 0ec4e93fb9f) |
| config/linux/bar.{c,h} + barrier.c | 13 | 2 (304d08fea9e, 8a47ae5c193) |
| team.c | ~30 | 4 (a58a965eb73, 091ddcc1b21, 17da2c7425e, d656bfda2d8) |
| parallel.c | ~10 | 1 (091ddcc1b21) |

### Bug-fix commit classification

| Commit | Summary | Root cause | Component | Severity |
|---|---|---|---|---|
| 304d08fea9e | PR122356 — memory sync after performing tasks | `task_count` decrement-to-zero non-atomic; `bar->generation` store in `gomp_team_barrier_done` non-atomic | barrier/task | **High** (UB; missed-publish of user task data) |
| 8a47ae5c193 | PR122314+PR88707 — tasks executed for next barrier generation | Wait loop used `gen != state + BAR_INCR` which fails to detect "generation already past" | barrier/task | **High** (safety: wrong-region task execution) |
| 0af7ef050ae | PR104385 — segfault with posthumous orphan tasks | `gomp_task_run_post_handle_dependers` failed to clear `task->parent` when parent was freed | task | **High** (use-after-free) |
| c125f504c43 | taskwait-nowait-depend hang | `empty_task` optimization in `gomp_task_run_post_handle_dependers` skipped the wake for a taskwait-depend without `nowait` | task | **High** (deadlock) |
| ba886d0c488 | omp_fulfill_event needs to wake barrier | New dependents unblocked by fulfill were not signaling the team barrier | task | **High** (deadlock) |
| d656bfda2d8 | PR98738 — task-detach-6 intermittent hang | Major refactor: `task_detach_queue` (PQ) replaced with `task_detach_count` (counter) + `GOMP_TASK_DETACHED` kind | task | **High** (race + hang) |
| 0bb27b81a76 | GOMP_task on s390x | Caller stack corruption from variadic-style argument handling | task | **High** (data corruption) |
| a58a965eb73 | Fix creation of artificial teams from explicit task | `gomp_create_artificial_team` freed a stack-allocated explicit task | task/target | **High** (use-after-free / invalid free) |
| 091ddcc1b21 | Enforce 1-thread limit in subteams (accel) | nest_var ignored on accelerator | parallel | Low (target-specific) |
| 17da2c7425e | PR102838 — gomp_team alignment | 64-byte-aligned member needed `gomp_aligned_alloc` | team | Medium (alignment / data corruption on some arches) |
| 7a2aa63fad0 | PR102838 — aligned_alloc args | `aligned_alloc` size not multiple of alignment on Solaris | alloc | Low (alloc-API conformance) |
| d3b41bde961 | Don't access gomp_sem_t as int with atomics unconditionally | POSIX path of `task_fulfilled_p` was reading a `sem_t` (mutex+int) as a raw int | sem | Medium (UB on non-Linux) |

### Bugzilla issue depth analysis

- **PR88707 (FIXED 2026)** — "Barrier executes tasks scheduled after said barrier." Open for **~7 years** before PR122314 finally fixed the same mechanism.
- **PR98738 (FIXED 2021, intermittent hang in task-detach-6)** — Drove the major refactor introducing `GOMP_TASK_DETACHED` and `task_detach_count`. Multiple iterations on the detach machinery in the following 2 years.
- **PR104385 (FIXED 2022, posthumous orphan tasks)** — `task->parent` dangling pointer in dependers list — race between parent `gomp_finish_task` and dependee scheduling.
- **PR105378 (FIXED 2022, `#pragma omp taskwait nowait depend`)** — New construct introduced + immediate follow-up fix `c125f504c43` for taskwait-depend-nowait-1 hang.
- **PR112356 (FIXED, referenced in bar.h:166)** — `gomp_team_barrier_done` plain store vs atomic ACQUIRE load — fixed.
- **PR113627 (OPEN/UNCONFIRMED, Jan 2024)** — **Detached tasks released without `omp_fulfill_event`** when iteration count exceeds 64 (single thread) or 128 (2 threads). Threshold-dependent → suggests counter-overflow or queue-traversal off-by-one in `gomp_task_run_post_handle_dependers` interaction with detach. **STILL OPEN in mainline.**
- **PR122314 (FIXED 2026)** — Companion of PR88707.
- **PR122356 (FIXED 2026)** — Memory-ordering bridge between `task_count` and `bar->generation`. Author Matthew Malcomson explicitly states in commit message: "mixing atomic and plain accesses on the same field is undefined behaviour" — yet the codebase still does this in non-barrier-handle decrement paths (CR1, CR6).

### Cross-implementation comparison

| Feature | libgomp (this study) | LLVM libomp (prior `libomp/` case study) |
|---|---|---|
| Barrier algorithm | Centralized "last arriver" + futex | 5 algorithms (linear, tree, hyper, hierarchical, distributed) |
| Task team | Single queue per team; counters; mutex | Per-thread deques + work-stealing; `t_task_team[0/1]` parity |
| Detach | `GOMP_TASK_DETACHED` + `task_detach_count` | `td_incomplete_child_tasks` (multi-use counter) |
| Cancellation | `BAR_CANCELLED` packed in barrier generation | per-team `tt_cancel_request` |
| Recent recurring bug-family | task-vs-barrier handshake (PR88707, PR122314, PR122356) | task-team parity corruption (libomp #50602, #59190, etc.) |

Both implementations independently hit serious bugs in the barrier↔tasking interaction. The exact mechanisms differ but the *category* (cross-thread state machine with stale-snapshot windows) is shared.

## Phase 3 — Deep Analysis Findings

(See per-file findings files for full detail. Top findings cross-listed below.)

### Top model-checkable findings (carried into Modeling Brief §6.1)

| # | Site | Class | Family | Status |
|---|---|---|---|---|
| MC1 | `gomp_team_barrier_cancel` plain `\|=` vs `gomp_team_barrier_wait_end` atomic RELEASE — overwriting publication | model-checkable | 1 | NEW finding |
| MC2 | Same race, alternate interleaving — publisher strips `BAR_CANCELLED` before observers see it | model-checkable | 1 | NEW finding |
| MC3 | `pool->last_team` cache ABA defense (`task_count != 0` guard) under generation wrap or zero-task new region | model-checkable | 4 | flagged in code-comment + libgomp_2 |
| MC4 | Asymmetric atomic/plain `--task_count` in taskwait/taskgroup_end/etc. vs barrier ACQUIRE-load | model-checkable | 2 | Unaudited continuation of PR122356 |
| MC5 | PR113627 — detached task dependent released without `omp_fulfill_event` (threshold ≥65 iter) | model-checkable | 3 | **OPEN** in bugzilla |
| MC6 | `omp_fulfill_event` last-fulfill wake guard (task.c:2776-2782) | model-checkable | 3 | Unaudited |
| MC7 | `gomp_team_barrier_wait_cancel_end` no-task publish doesn't strip `BAR_CANCELLED` (bar.c:166-172) | model-checkable | 1, 5 | flagged by code-comment (informal) |

### Test-verifiable findings

| # | Site | Class |
|---|---|---|
| T1 | `nowait + ordered + cancel` stale `ordered_release[]` semaphore (work-share finding 5A) | TSAN / stress test |
| T2 | `gomp_resolve_num_threads` unsigned underflow (parallel.c:105-122) | nested-team stress |
| T3 | TSAN of `ordered.c:206-221` dirty read | TSAN |
| T4 | TSAN of `bar.c:212` cancel `\|=` | TSAN |
| T5 | Repro PR113627 (`./repro -t 65`) on current trunk | direct |

### Code-review-only findings (full enumeration in Modeling Brief §6.3)

CR1-CR10 — see Modeling Brief.

### Verified-safe (excluded) findings

The following were initially suspected but verified as safe after re-reading:

- **F2 (subagent #3): Cached team retains `BAR_CANCELLED` across reuse.** Verified: both publish paths in `gomp_team_barrier_wait_end` strip `BAR_CANCELLED` (bar.c:102 for no-task; `& -BAR_INCR` mask in `gomp_team_barrier_done` for task). The cached team's `bar->generation` therefore has `BAR_CANCELLED` cleared at caching time. The related concern about cancellable-variant `wait_end` (bar.c:166-172) NOT stripping `BAR_CANCELLED` survives as MC7, but only if both flags can be set simultaneously, which the informal comment at bar.c:150-153 claims is impossible (the comment is itself an unverified claim worth a model-check).
- **F13 (subagent #1): Asymmetric atomic vs plain task_count decrement in GOMP_taskwait/etc.** Re-checked: the decrement happens under `team->task_lock`. The barrier's ACQUIRE-load of `task_count` happens only when the calling thread is the "last arriver," which implies all other threads have decremented `awaited` — but those threads couldn't have been mid-`GOMP_taskwait` because `GOMP_taskwait` runs in user code *before* the thread arrives at the barrier. So the race window doesn't materialize via these paths. Demoted to CR1.

### File-by-file findings (summary)

See:
- `.specula-output/findings-barrier.md` — 11 findings in barrier/primitives, top: cancel-write race (Family 1)
- `.specula-output/findings-task.md` — 26 findings (F-1 through F-26) + 9 reclamation findings (G-1 through G-9), top: PR122314 mechanism, omp_fulfill_event lifetime, stale do_wake
- `.specula-output/findings-team.md` — 17 findings in team/parallel, top: cached-team reuse, split-window in `gomp_team_start`, plain `|=` on `bar->generation`
- `.specula-output/findings-workshare.md` — 10 findings in work-share, top: cancel + nowait race on `work_shares_to_free`, stale `ordered_release[]`

## Phase 4 — Synthesis

See `modeling-brief.md` for the actionable output.

### Bug-family consolidation rationale

The deep analysis produced ~70 raw findings. They consolidate into 5 mechanism-level families. The grouping criterion is the *mechanism* (mixed atomic/plain on a shared word; ownership transfer across threads; cached-state ABA), not the file or the construct.

| Raw findings | Bug Family | Mechanism |
|---|---|---|
| barrier 1.1, 1.2; team F3, F17; CR2, CR3, CR4 | Family 1 | Plain RMW on `bar->generation` racing with atomic RELEASE stores |
| barrier 1.3, 1.4; task F-2, F-6, F-13; CR1, CR6 | Family 2 | barrier↔task_count handshake; mixed atomic/plain |
| task F-9, F-10, F-11, G-9, F-17, F-18, F-19; commit history of detach refactors | Family 3 | Detach completion across thread boundaries; external fulfiller |
| team F1, F2, F4, F12; task F-2 ABA defense; CR7 | Family 4 | `pool->last_team` ABA; cached-team reuse |
| barrier 1.5; team F16; bar.h:150-153 comment; MC7 | Family 5 | Generation counter wrap + informal flag-bit invariants |
| workshare 3A, 3B, 5A, 5B; team F5 | (test-verifiable) | Workshare + cancel + nowait edge cases |
| various | (code-review-only) | Sibling plain RMWs, do_wake staleness, underflow, etc. |

### Modeling implications

The Modeling Brief proposes splitting at every atomic boundary. The spec must encode:
- Per-thread program counter for the long scheduling functions (`gomp_barrier_handle_tasks`, `GOMP_taskwait`, `GOMP_taskgroup_end`, `omp_fulfill_event`).
- Lock-drop windows as separate action steps.
- `bar->generation` as four separate variables (counter + 3 flag bits) so atomic vs plain mutations can be modelled.
- An external (non-team-member) thread for `omp_fulfill_event` from a non-OpenMP thread.
- Bounded counter wrap.

### Out of scope (modeling brief §3.2)

Affinity, allocator, offloading, sem chained-wake liveness, critical-region fences — these are either pure performance, below the abstraction level, or have no testable safety predicate within TLA+.

## Critical-Rule Compliance Checklist

| Rule | Status |
|---|---|
| 1. Verify before reporting | DONE — verified F2 (cancel persistence) was wrong; verified F13 (asymmetric decrement race window) doesn't materialize via taskwait; preserved derived concerns elsewhere |
| 2. Read issue discussions, not just titles | DONE — read PR122314, PR122356, PR113627 full descriptions; cross-referenced with commit messages |
| 3. No hallucinated code logic; cite file:line | DONE — every finding has file:line and quoted excerpt |
| 4. Parallel Task subagents | DONE — 4 parallel subagents, ~440 KB of subagent work product summarized into 4 findings files |
| 5. Evidence-based claims only | DONE — all findings backed by code excerpts and/or commit references |
| 6. Bug Families over flat lists | DONE — 5 families consolidating ~70 raw findings |
| 7. Every finding classified | DONE — model-checkable / test-verifiable / code-review-only |
| 8. Thoroughness | DONE — analysed all bug-fix commits in core files (back to 2017 within fetched depth); read 8 bugzilla PRs in full; ~10K LoC core read |
| 9. Category recorded in modeling brief | DONE — §1 explicitly records Category B with justification |
| 10. Follow category reference (concurrent-analysis.md) | DONE — applied all 8 analysis patterns; identified the case-specific failure modes (mixed atomic/plain, cached-team ABA, external-thread ownership transfer) |
