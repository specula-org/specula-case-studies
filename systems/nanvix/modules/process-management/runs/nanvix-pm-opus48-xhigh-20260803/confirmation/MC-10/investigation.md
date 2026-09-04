# MC-10 Investigation

## Step 1 - Code audit
- put_mutex: src/kernel/src/pm/process/state/mod.rs:641-655
    extract_if(.., |&a,m| a==addr && m.reference_count() <= 2)
- get_mutex: mod.rs:611-626  (entry().or_insert_with(Mutex::new).clone())
- Mutex(Arc<MutexInner>), MutexGuard{mutex: Arc<MutexInner>}, reference_count = strong_count:
    src/kernel/src/pm/sync/mutex.rs:47,54,120-122,133-146,174-186,200-207
- ONLY caller of put_mutex: remove_mutex_guard, manager/mod.rs:2616-2637:
    let guard = take_mutex_guard(addr)?;  // removes owner's guard from locked_mutexes (thread/state.rs:241)
    put_mutex(addr)?;                     // refcount check
    Ok(guard)                             // guard dropped by outer kcall AFTER return
- remove_mutex_guard reachable via: unlock_mutex.rs:56 and wait_cond.rs:105 (take_mutex_guard).
- Execution model: single global `static mut PROCESS_MANAGER` via get_mut() (unsafe.rs:249-255),
  single CURRENT_TID atomic (unsafe.rs:103) => cooperative single-core, serialized non-preemptible
  kcalls; only yield point is ProcessManager::sleep().

## Reachability
- put_mutex fires ONLY during the owner's own release (guard already removed from locked_mutexes).
  => CE post-state (ex=FALSE AND ow=t1 AND hd={mx1}) is never realized.
- A thread blocked in Mutex::lock() keeps an Arc clone on its stackful suspended kcall
  (mutex.rs:174-186) => refcount>=3 => put_mutex's `<=2` predicate FALSE => real waiter never destroyed.
- Guard dropped in the SAME kcall after put_mutex, no sleep() between => no concurrent get_mutex
  can mint a distinct object while the old one is still locked. No split-brain reachable.

## Step 2 - Developer knowledge
- git log -L on put_mutex: threshold `<=2` present since b89338f99 ("Cond Signal/Wait Kernel Calls");
  deliberate (put_cond uses `<=1`; the extra +1 accounts for the in-flight owner guard).
- No comment/TODO/FIXME flagging destroy-while-held.

## Step 3 - Known status
- GitHub nanvix/nanvix issues searched: #1962 (perf: BTreeMap->SortedVec) DESCRIBES the extract_if
  removal pattern as correct behavior to preserve; #2612/#2606 about pthread mutex/cond re-init across
  fork(). NO issue/PR reports the destroy-while-held / split-brain mechanism. => Novelty: NEW.

## Reproduction
- repro/test_bugMC-10_put_mutex_destroy_held.rs (faithful mirror + real call graph). Executed.
- Level 0: real lock/unlock -> put_mutex removes still-locked mutex, but guard dropped same kcall (no harm).
- Level 1: blocked waiter -> refcount 3 -> NOT removed (waiter protected).
- Level 2: inject decoupled destroy (owner keeps holding) -> split-brain reproduces at DS level,
  but that step is not producible by the real API.

## Verdict
PENDING REPAIR (SPEC_REPAIR): model `putmutex` action over-permissive (decoupled from owner release,
missing the no-blocked-waiter guard). CE unreachable in implementation.
