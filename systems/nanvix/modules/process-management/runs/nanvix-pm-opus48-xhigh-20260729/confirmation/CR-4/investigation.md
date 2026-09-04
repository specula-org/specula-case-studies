# CR-4 Investigation — Thread exiting while holding a mutex defers unlock to zombie harvest

## Finding
A thread that exits while holding a mutex moves the `MutexGuard` into its zombie
(`thread/running.rs:195-197`). The actual unlock + `Condvar::notify_first` only fire when the
zombie is dropped (at harvest); `ThreadState::drop` merely logs. A sibling blocked on the mutex
cannot make progress until harvest → liveness / priority-inversion hazard.

Source: **Code Review** (code-review TV-4). No MC counterexample.

## Step 1 — Code audit (facts)

### Where the guard lives / how it is released normally
- `ThreadState` holds `locked_mutexes: BTreeMap<MutexAddress, MutexGuard>` (`thread/state.rs:83`).
- `lock_mutex` kcall: `mutex.lock()` → guard → `ProcessManager::put_mutex_guard` →
  `RunningThread::put_mutex_guard` → `ThreadState::store_mutex_guard` inserts the guard into
  `locked_mutexes` (`thread/state.rs:223-225`).
- `unlock_mutex` kcall: `ProcessManager::take_mutex_guard` → `ThreadState::take_mutex_guard`
  (`remove`) → the guard is returned and **dropped promptly**. `MutexGuard::drop`
  (`sync/mutex.rs:200-207`) → `unlock_unchecked` (`sync/mutex.rs:78-81`) which does
  `locked.store(false)` **and** `sleeping.notify_first()` — i.e. wakes one waiter. This is the
  correct/prompt release path.

### The exit path (the bug)
- `RunningThread::exit` (`thread/running.rs:195-197`):
  ```rust
  pub fn exit(mut self, status: ExitStatus) -> (ZombieThread, *mut ContextInformation) {
      let ctx = self.state.context_mut();
      (ZombieThread::from_state(self.state, status), ctx)   // state (with locked_mutexes) moved in
  }
  ```
  The whole `ThreadState`, including a still-populated `locked_mutexes`, is moved into the
  `ZombieThread`. Nothing iterates/drops the guards. So `locked==true` remains and **no
  `notify_first` is issued at exit**.
- No exit/terminate path releases held mutexes. `take_mutex_guard`/`store_mutex_guard` are only
  called from `unlock_mutex.rs`, `wait_cond.rs`, and `lock_mutex.rs`. The process-exit and
  thread-exit paths (`process/state/running.rs::exit`, `exit_thread`; `ReadyThread::terminate`)
  never drain `locked_mutexes`.
- The guard is finally dropped only when the `ZombieThread` is dropped. That happens at harvest:
  - intra-process, non-detached: `join_thread` → `harvest_zombie_thread` (`manager/unsafe.rs:758`)
  - intra-process, detached: deferred to `deferred_reap`, reaped at next PM entry via
    `reap_deferred` (`manager/unsafe.rs:610-615`)
  - process exit: `harvest_zombies` (`manager/mod.rs:3444-3483`) pops each zombie thread and
    `harvest()`s it; the `ZombieThread` is dropped at the end of the loop iteration
  - admission pressure: `reap_pending_zombies` / `reap_deferred_zombie_threads`
  In every case, dropping the `ZombieThread` → `Box<ThreadState>` dropped → `ThreadState::drop`
  runs (logs the error at `thread/state.rs:574-584`) → fields dropped → `locked_mutexes` dropped
  → each `MutexGuard::drop` → `unlock_unchecked` → `notify_first`. THIS is the deferred unlock.

### Reachability
Fully reachable via public kcalls: thread A `lock_mutex(M)`; sibling B `lock_mutex(M)` (blocks,
sleeps on M's condvar); thread A exits/terminates without `unlock_mutex(M)`. Until A's zombie is
harvested, M stays locked and B is never notified. For a **non-detached, un-joined** A the delay
is unbounded (B, with an infinite timeout, sleeps forever while the process is otherwise live).

### Consumer that observes wrong outcome
Sibling B blocked in `Mutex::lock` (`sync/mutex.rs:174-186`) → `Condvar::wait`
(`sync/condvar.rs:232-267`). B is only re-awoken by `notify_first`/`notify_thread`/`notify_all`
(the mutex uses `notify_first`), which is emitted solely from `MutexGuard::drop`. No drop → no
wakeup.

## Step 2 — Developer knowledge (evidence, not verdict)
- `ThreadState::drop` logging was added by **PR #585 "[kernel] Drop Join CondVar when Exiting
  Thread"** (merged 2025-06-09). Its description: "adding a debug mechanism to detect improper
  mutex handling when a thread state is dropped." → developers are AWARE a thread state can be
  dropped while holding locked mutexes and treat it as "improper mutex handling" worth logging.
  Per the skill this awareness/debug-marker does NOT constitute a filed report of the
  deferred-unlock/sibling-blocked liveness mechanism.
- `git blame`: exit body `7e75c2db36` (2025-08-19), drop-log `7e75c2db36`. No commit releases held
  mutexes on exit.

## Step 3 — Known-status / precedent search (GitHub tracker + merged PRs)
Searched nanvix/nanvix issues+PRs (open and recently merged/closed):
- #2344 (closed, fixed 2026-05-16): UAF in **detached** thread exit — a *different* mechanism
  (dangling `ContextInformation` from `drop(zombie_thread)`), not deferred mutex unlock.
- #585 (merged): added the drop-log debug marker + join-condvar leak fix — awareness, not a report
  of this liveness bug.
- #1960 (open, perf): replace BTreeMap→SortedVec for `locked_mutexes` — refactor, not this bug.
- #2606/#2612 (fork mutex/cond re-init), #2511 (vfs fd table), #2688 (DT_NEEDED): unrelated.
No issue/PR/CVE reports THIS mechanism (thread exits holding mutex → deferred unlock at harvest →
sibling blocked) at this site.

**Novelty: NEW** (searched open issues + recently merged/closed PRs; nothing reports this
mechanism at this site). Code-review + not-already-reported → NOT dropped by pre-filter → proceed
to Phase 2.

## Trigger scenario (concrete)
1. Thread A: `lock_mutex(M)` → guard stored in A's `ThreadState.locked_mutexes`.
2. Sibling B: `lock_mutex(M, timeout=None)` → `try_lock` fails → sleeps on M's condvar.
3. Thread A exits (thread exit / terminate) WITHOUT `unlock_mutex(M)`.
   → A becomes a `ZombieThread` still owning the guard; `locked==true`; no `notify_first`.
4. B remains asleep — no wakeup is pending — until A's zombie is harvested (join / reap / process
   exit). For a non-detached, un-joined A this is unbounded.

## Phase 2 — Reproduction (booted kernel, real code)

Level 0 (real API, deterministic — no race/timing needed). In-kernel test
`src/kernel/src/pm/process/state/mutex_exit_test.rs` (feature `test`) drives the exact kernel
methods the kcalls use: `Mutex::try_lock` + `RunningThread::put_mutex_guard` (= lock_mutex),
`RunningThread::exit` (running.rs:195), then `drop(ZombieThread)` → `ThreadState::drop` (= harvest).
A sibling's `lock_mutex` acquisition is probed with `Mutex::try_lock`. Built with `make
all-test-kernel` and booted under the standalone `uservm`.

Serial output (real kernel):
```
[CR-4] owner holds mutex: sibling try_lock() -> Err (would block)
[CR-4] after owner exit(): sibling try_lock() -> Err (STILL LOCKED) (correct behavior would be Ok/unlocked)
[ERROR][state] drop(): dropping thread state with locked mutexes (self.id=1, self.locked_mutexes={MutexAddress { addr: 0xdead0000 }: MutexGuard { locked: true, condvar: Condvar { sleeping: [] } }})
[CR-4] after zombie harvest (ThreadState drop): sibling try_lock() -> Ok (released now)
[CR-4] CONFIRMED: mutex release+notify deferred from thread-exit to zombie-harvest
```

The `[ERROR][state]` line lands BETWEEN "after exit (still locked)" and "after harvest (released)",
proving the guard survives into the zombie and is released only at ThreadState drop.

Checklist:
1. Level 0 alone triggered it (real API order, deterministic). yes.
2. n/a (no state injection beyond the real put_mutex_guard the kcall itself uses).
3. Real consumer: sibling in `lock_mutex` (kcall/lock_mutex.rs:93 → Mutex::lock/try_lock) observes
   the mutex still locked after the owner terminated; no notify until harvest.
4. Not masked for the JOINABLE case: no automatic reaper for joinable per-thread zombies in a live
   process; release waits for an explicit `join_thread` or whole-process teardown (unbounded). The
   detached case IS bounded by `reap_deferred` at the next PM entry (largely masked) — but the
   confirmed defect is the joinable path.

Repro artifact: repro/test_bugCR-4_mutex_hold_on_exit_defers_release.{sh,rs,run.log}
Verdict: REPRODUCED (Source: Code Review; Novelty: NEW; Location: src/kernel/src/pm/thread/running.rs:195).
