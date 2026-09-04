# MC-3 Investigation

Finding: A mutex owned by a never-joined joinable zombie is held forever (blocks all
future `Mutex::lock` waiters, including the condvar reacquire in `wait_cond`).
Source: model-checking (real counterexample), invariant `MutexProgress`,
config `MC_hunt_scenario3_live.cfg`, CE `spec/output/MC_hunt_scenario3_live_final.out`.

## Step 1 — Code audit (facts)

Mutex ownership representation:
- `MutexGuard` holds `Arc<MutexInner>`; `Drop for MutexGuard` calls `unlock_unchecked`
  (`sync/mutex.rs:200`) → `locked.store(false)` + `notify_first`. So a mutex is released
  **exactly** when its `MutexGuard` is dropped.
- The owning guard is stored in the owner thread's `ThreadState.locked_mutexes`
  (`thread/state.rs:83`, a `BTreeMap<MutexAddress, MutexGuard>`).

Lock/unlock kcall paths:
- `lock_mutex` (`kcall/lock_mutex.rs:92`): `get_mutex(addr)` (global registry keyed by
  address) → `Mutex::lock(timeout)` (sleeps on the mutex's internal condvar while
  `locked`) → `put_mutex_guard` → `ProcessManager::store_mutex_guard`
  (`manager/unsafe.rs:1010`) → `RunningThread::put_mutex_guard` (`thread/running.rs:236`)
  → `ThreadState::store_mutex_guard`. Guard now lives in the CURRENT thread's ThreadState.
- `unlock_mutex` (`kcall/unlock_mutex.rs:56`): `take_mutex_guard(pid,tid,addr)` removes the
  guard from that thread's ThreadState and drops it → unlock.

Thread exit path (the gap):
- `exit_thread` (`manager/unsafe.rs:533`) → `do_exit_thread` → `RunningProcess::exit_thread`
  (`process/state/running.rs:341`) → `RunningThread::exit` (`thread/running.rs:195`) moves
  the whole `ThreadState` (incl. `locked_mutexes`) into a `ZombieThread`
  (`thread/zombie.rs:58`). **No owned mutex is released on exit.** For a **non-detached
  (joinable)** thread with a live sibling, `exit_thread` pushes the zombie into the
  process's `zombie_threads` deque (`running.rs:384-390`) and returns `deferred_zombie =
  None` — the zombie is *retained* in the live process, not dropped, not deferred.
- Kill: `kill`/`terminate` post a signal / move to zombie; they likewise never release
  owned mutexes.

Where the guard is finally released:
- Only `harvest_zombie_thread` (`manager/unsafe.rs:654`) consumes the `ZombieThread` via
  `ZombieThread::harvest` (`thread/zombie.rs:110`, takes `self` by value → `ThreadState`
  drops → `BTreeMap<MutexGuard>` drops → each `MutexGuard::drop` unlocks).
- `harvest_zombie_thread` is reached ONLY from: `join_thread` (joinable → on pthread_join),
  `detach_thread` (if already a zombie), and `reap_deferred` (detached auto-reap).
- Corroborating developer signal: `Drop for ThreadState` (`thread/state.rs:524`) logs
  `error!("drop(): dropping thread state with locked mutexes ...")` — the developers know a
  thread should not normally drop while owning mutexes, but the release is still tied to
  drop (== harvest), and for a never-joined joinable zombie the drop never happens.

Condvar instantiation (MC10): `wait_cond` (`kcall/wait_cond.rs`) releases the mutex
(line 105), waits on the condvar, then **reacquires** via `mutex.lock(None)` (line 127) →
if the mutex is orphaned by a zombie owner, this reacquire blocks forever too.

Reachability / trigger scenario (natural):
1. Process p1 has ≥2 threads (t1, t2) → p1 stays alive when one thread exits.
2. t1: `lock_mutex(mx)` → guard stored in t1's ThreadState.locked_mutexes.
3. t1: thread `exit()` (joinable, not detached) → t1 becomes a zombie retained in p1's
   zombie deque, still owning mx. Nobody `pthread_join`s t1.
4. t2 (or any later thread/process sharing mx): `lock_mutex(mx)` → `Mutex::lock` →
   `try_lock` fails (locked) → sleeps forever. No owner alive to unlock. Permanent block.

Safeguards considered: none. `try_lock`/`lock` have no owner-death detection (no robust
mutex). Join is the only release, and the scenario is precisely "join never happens".

## Step 2 — Developer-knowledge search (evidence)

- `git log` over 31k commits: commits exist for the *detached* zombie UAF and for on-demand
  reaping (harvest_zombie_thread extraction, defer/reap of detached zombies) but **none**
  about releasing owned mutexes on thread exit/kill, nor about a zombie holding a mutex.
- `Drop for ThreadState` error log = a diagnostic acknowledging the anomaly, but not a
  filed report and not a fix (release still only at drop/harvest).

## Step 3 — Known-status / precedent

Issue tracker (`nanvix/nanvix`):
- #2344 "Use-after-free in detached thread exit path causes kernel panic" — CLOSED. A
  *memory-safety* bug in the **detached** exit path (ZombieThread dropped early → dangling
  `ctx`). Different mechanism (UAF/panic), different path (detached), already fixed.
- #2495 "[kernel] On-demand zombie reaping when thread admission fails" — CLOSED. Thread
  **slot-count** exhaustion (`live_count` → MAX_THREADS) because zombies harvest lazily.
  About thread *slots/accounting*, not mutex ownership/liveness.
- 37 issues mention "mutex"; the nearest (#2612 robust mutex/cond re-init across fork) is a
  different mechanism. **None** report "a mutex owned by a zombie is held forever / release
  owned mutexes on thread death".

Conclusion: **NEW**. This exact mechanism (owned mutex not released on exit/kill; a
never-joined joinable zombie orphans the lock → permanent block of all waiters, incl.
condvar reacquire) is not reported. Related-but-distinct issues (#2344, #2495) stem from
lazy harvesting but neither concerns mutex ownership/liveness.

Source = MC (real counterexample). Not eligible for the code-review×known drop. Proceed to
Phase 2 reproduction.

## Counterexample mapping (MC_hunt_scenario3_live_final.out)

- S1: t1 running in p1, mx1 free (ow=NULL).
- S2: t2 created in p1 (ready).
- S3: t1 locks mx1 → `mu.ow=t1`, `t1.hd={mx1}`  ⇔ store_mutex_guard into t1.ThreadState.
- S4: t1 exits → `t1.st="zombie"` but `t1.hd={mx1}`, `mu.ow=t1` still  ⇔ ZombieThread keeps
  the guard; exit released nothing.
- S5: t2 running.
- S6: t2 locks mx1 → blocks: `t2.st="sleeping", bk="mutex", bo=mx1`, `mu.q=<<t2>>`.
- S7: Stuttering → t2 blocked forever → `MutexProgress` violated (t1 is a joinable zombie
  never harvested; nobody joins it).
