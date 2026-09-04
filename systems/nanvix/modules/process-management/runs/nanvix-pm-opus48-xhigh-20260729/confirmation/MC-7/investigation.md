# MC-7 — Investigation record (Phase 1, evidence only)

Finding: "Orphaned mutex-map slot after an interrupted cond_wait reacquire".
Source: model-checking (real counterexample `spec/output/MC_hunt_MC-7.out`, invariant
`MCSyncSlotConservation`, cfg `MC_hunt_scenario5.cfg`).

## Step 1 — Code audit (facts)

### Cited sites
- `src/kernel/src/pm/kcall/wait_cond.rs:104-130` — the cond_wait body:
  - L104-107: `take_mutex_guard(pid,tid,mutex_addr)?` — releases the mutex the thread
    entered holding (drops the guard, notifies).
  - L110-123: sleep on the condition variable (`cond.wait(alarm)`), then `put_cond`.
  - **L126: `get_mutex(mutex_addr)?`** — re-obtains (recreates if absent) the mutex map entry.
  - **L127: `mutex.lock(None)?`** — reacquire; blocks if contended. `?` propagates a
    `SleepError`. On interruption this returns EARLY, so:
  - L128: `put_mutex_guard(mutex_addr, guard)?` — **never runs**; the guard is never stored.
- `src/kernel/src/pm/process/state/mod.rs:622-666`:
  - `get_mutex` (L622): `if !contains_key && len >= MUTEX_OPEN_MAX { return OutOfMemory }`;
    else `entry(addr).or_insert_with(Mutex::new).clone()`. Creating an entry consumes a slot.
  - `put_mutex` (L652): the **only** map reclaimer. Requires `contains_key`, then
    `extract_if(.., |addr,mutex| addr==mutex_addr && mutex.reference_count() <= 2)`.
- `src/kernel/src/pm/process/manager/mod.rs:2616-2638` `remove_mutex_guard`:
  takes the guard from the running thread; **if the thread does not own it → returns
  `OperationNotPermitted` ("thread does not own mutex") BEFORE calling `put_mutex`.**
- `src/kernel/src/pm/kcall/unlock_mutex.rs:56` calls `take_mutex_guard` → `remove_mutex_guard`.
  So an unlock by a thread that holds no guard is a "foreign unlock" that never reaches `put_mutex`.

### Mutex refcount model (crux)
`Mutex(Arc<MutexInner>)`; `reference_count()==Arc::strong_count`. `MutexGuard` holds a
clone of the same `Arc<MutexInner>`. `put_mutex` reclaims only when `strong_count <= 2`
(map entry + at most the one guard being dropped). A concurrently in-flight `get_mutex`
clone (held on the reacquiring thread's stack while it is blocked in `mutex.lock`) raises
the count to 3, so a *different* holder's `put_mutex` cannot reclaim the slot.

### Interruption machinery (MC-6 mechanism; reacquire is interruptible while thread survives)
- `mutex.lock(None)` (sync/mutex.rs:174) loops: `try_lock`; on failure `sleeping.wait(None)`
  → `ProcessManager::sleep(None)` (manager/unsafe.rs:845) which returns
  `Err(SleepError::Interrupted(reason))` when the thread was interrupted (L867-870).
- `InterruptReason` (thread/interrupted.rs:24): `Killed` / `TimedOut` / **`Signaled`
  ("a deliverable, caught signal interrupted the call")**.
- A caught signal to a thread blocked in the reacquire → `interrupt_suspended_thread`
  → `interrupt_thread(tid, Signaled)` (manager/mod.rs:1034-1052). `Signaled`/`TimedOut`
  **return to user mode; the thread keeps running** (tla_world.rs:814 comment,
  DispatcherCheckpoint). Only `Killed` drives exit.
- `handle_sleep_error` (kcall/dispatcher.rs:263-289): on `Signaled` it records the
  restart args and returns `EINTR`. **It performs NO mutex-map cleanup.** The comment
  (L279-281) asserts "the current blocking calls make no observable partial progress" —
  but `wait_cond` *did* make progress (it released + re-touched the mutex map).

### Trigger scenario (concrete, reachable)
Real, requires contention (2 threads A,B; 1 mutex m1; 1 cond c1), all via real kcalls:
1. A `lock_mutex(m1)`; A `cond_wait(c1,m1)` → releases m1 (its original slot reclaimed at
   L105 since strong_count==2), parks on c1.
2. B `lock_mutex(m1)` (recreates the m1 slot, now held by B).
3. B `cond_signal(c1)` → A wakes, resumes `wait_cond` at L126: `get_mutex(m1)` (slot present,
   B holds it, A now holds an in-flight clone), L127 `mutex.lock(None)` → blocks (B holds it).
4. B `unlock_mutex(m1)`: `put_mutex` sees strong_count==3 (map + B's guard + A's in-flight
   clone) → `3 <= 2` FALSE → **slot NOT reclaimed**. B's guard drop wakes A.
5. A is delivered a caught signal in that window → reacquire returns
   `EINTR`(`Signaled`); `wait_cond` returns early WITHOUT storing a guard; A drops its clone
   (strong_count → 1 = map only). A returns to user mode alive.
   **Result: m1 slot present, unlocked, unowned, unheld — an orphan (== CE State 4).**
6. Nobody reclaims it: only `put_mutex` (via a guard-holding unlock) reclaims, and no thread
   holds m1. A `unlock_mutex(m1)` by A is a foreign unlock → rejected before `put_mutex`.
   Slot lingers until the same address is re-locked+unlocked, or the process exits.

### Consequence & real consumer
Each orphaned slot counts against `MUTEX_OPEN_MAX` (=32, build/kernel_config.toml:129).
`get_mutex` (mod.rs:626) rejects new addresses once `len>=32`. Real consumer: a subsequent
`lock_mutex`/`wait_cond` on a fresh mutex address in the SAME living process fails with
`OutOfMemory` ("maximum number of mutexes reached") though nothing is actually locked/held.

## Step 2 — Developer-knowledge search (evidence)
- `git log` on wait_cond.rs / state/mod.rs: mutex/cond kcalls + signal-delivery series
  (b89338f99 Cond Signal/Wait; c7cb73b66 Deliver Caught Signals). No commit mentions the
  mutex-map leak on interrupted reacquire.
- No inline TODO/FIXME/"known" about mutex-map reclamation near the cited sites.
- Issue #2695 "[signals] Blocking-Call Interruption (EINTR/SA_RESTART/sigsuspend)" (closed,
  completed) is the FEATURE that makes `wait_cond`/`lock_mutex` interruptible. It routes all
  interrupted sleeps through `handle_sleep_error` and **explicitly assumes** the blocking
  calls "make no observable partial progress before interruption" — the assumption this bug
  violates. It does not report the slot leak.
- PR #1694 "[kernel] Fix mutex/condvar capacity check" fixed a *different* defect in the same
  file (the `get_mutex` capacity double-count / `contains_key` guard), not the interrupted
  reacquire leak.

## Step 3 — Known-status / precedent
Searched nanvix/nanvix issues+PRs (open and closed/merged): mutex leak, put_mutex, wait_cond,
get_mutex, reacquire/relock, orphan mutex, MUTEX_OPEN_MAX, interrupted mutex reacquire. No
existing report describes THIS mechanism (orphaned mutex-map slot after an interrupted
cond_wait reacquire; foreign unlock never calls `put_mutex`) at THIS site. → **Novelty: NEW.**
Source is MC (real counterexample) → not subject to the code-review×known pre-filter; proceed
to Phase 2 regardless.

---

## Phase 2 — Reproduction result (this turn)

**Escalation level reached: 2** (state injection through the REAL `ProcessState`/`Mutex` API).

Injected in the worktree: `run_mc7_repro()` in
`src/kernel/src/pm/process/state/tla_world.rs`, wired into the in-kernel PM test suite
(`pm/test.rs::test()` via `run_test!(mc7_repro_orphaned_mutex_map_slot)`). It drives the REAL
`ProcessState::{get_mutex,put_mutex,contains_mutex}` and REAL `Mutex`/`MutexGuard` through the exact
wait_cond operation sequence (CE States 2→3→4), with a baseline control (normal lock/unlock reclaims
the slot) and a consumer-harm probe (fill to MUTEX_OPEN_MAX, then a fresh get_mutex).

Built (`make all-test-kernel all-uservm`) and booted (`uservm.elf -kernel kernel-test.elf`). Console:

```
[INFO][tla_world] run_mc7_repro(): MC7_REPRO: baseline OK -- a normal lock/unlock reclaims the mutex-map slot (mutexInMap=false)
[ERROR][tla_world] run_mc7_repro(): MC7_REPRO: LEAK CONFIRMED -- mutexInMap=true while the mutex is unlocked & unowned (SyncSlotConservation VIOLATED, matches spec/output/MC_hunt_MC-7.out State 4)
[ERROR][tla_world] run_mc7_repro(): MC7_REPRO: CONSUMER HARM CONFIRMED -- after 32 interrupted reacquires get_mutex rejects a NEW mutex with OutOfMemory, though the process holds none
[INFO][test] test(): passed: mc7_repro_orphaned_mutex_map_slot
[DEBUG][kernel] kernel_magic_string(): hello, world!   <- clean boot, no panic
```

Self-contained driver: `repro/test_bugMC-7_mutex_map_leak.sh` (exit 0 = reproduced). Executed end-to-end → exit 0.

**Verdict: REPRODUCED.** Reachable via admissible CE steps / real wait_cond op sequence; real
consumer (`get_mutex`, `mod.rs:626`) observes OutOfMemory though the process holds no mutex; state is
permanent for any leaked mutex not subsequently re-locked (only reclaimer `put_mutex` is unreachable
after the interrupt — a later `unlock_mutex` is rejected as a foreign unlock). Novelty: NEW.
