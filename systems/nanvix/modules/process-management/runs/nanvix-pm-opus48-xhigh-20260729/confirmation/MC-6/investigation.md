# MC-6 Investigation — cond_wait returns EINTR without re-holding the mutex

## Finding
`wait_cond` releases the caller's mutex, waits on the condition variable, then reacquires the
mutex with `let guard = mutex.lock(None)?;` (wait_cond.rs:127). If that relock is interrupted by a
signal, `?` propagates the error and `wait_cond` returns **without the mutex held** (line 128,
`put_mutex_guard`, is skipped). POSIX requires `pthread_cond_wait` to return with the mutex locked
even on error. Same for `put_cond(...)?` (wait_cond.rs:123) which early-returns before the relock.

## Step 1 — Code audit (facts)

Cited site (`src/kernel/src/pm/kcall/wait_cond.rs`):
```
105:  ProcessManager::take_mutex_guard(pid, tid, mutex_addr)...?;   // releases the mutex (guard dropped)
111:  Ok(cond) => cond.wait(alarm),                                 // waits; result stored
123:  ProcessManager::put_cond(cond_addr)...?;                      // early-return possible
126:  let mutex = ProcessManager::get_mutex(mutex_addr)...?;
127:  let guard = mutex.lock(None)?;                                // <-- ? returns WITHOUT the mutex on interrupt
128:  ProcessManager::put_mutex_guard(mutex_addr, guard)...?;       // SKIPPED on the :127 error
130:  result
```

Interrupt path is real and reachable:
- `Mutex::lock` (sync/mutex.rs:174) loops: `try_lock`; on contention `self.0.sleeping.wait(timeout)?`.
- `Condvar::wait` (sync/condvar.rs:259) calls `ProcessManager::sleep(alarm)`.
- `ProcessManager::sleep` (process/manager/unsafe.rs:867-870) returns `Err(SleepError::Interrupted(reason))`
  when a signal interrupted the sleep.
- So a signal delivered while the woken waiter is **blocked reacquiring a contended mutex** makes
  `mutex.lock(None)` at :127 return `Err(Interrupted)` → `wait_cond` returns EINTR, mutex NOT held,
  `put_mutex_guard` never called (kernel per-thread `locked_mutexes` set stays empty; the atomic
  `MutexInner.locked` stays owned by the contender).

Note: the interrupt-during-*cond-wait* path is handled correctly — `cond.wait` returns Err, but
execution still falls through to :126-128 and reacquires the mutex before `return result`. The
defect is specifically the interrupt-during-*relock* path (and the :123 early return).

Reachability of contention at relock: after a `pthread_cond_signal`, the signaller still holds the
mutex (classic idiom: `lock; ready=1; signal; unlock`), so the woken waiter must block to
reacquire → `try_lock` fails → it sleeps in `Mutex::lock` → a caught signal interrupts that sleep.

## Trigger scenario (natural)
- t1: `lock(M); while(!ready) cond_wait(C,M); <CS>; unlock(M)`.
- t2: `lock(M); ready=1; cond_signal(C); <work while holding M>; unlock(M)`.
- signal thread: post a caught signal (handler installed WITHOUT SA_RESTART) to t1 after it is woken
  and blocked reacquiring M.
- Result: `pthread_cond_wait` returns EINTR to t1 with M **not** held. t1 resumes its critical
  section unlocked (races with t2) and/or later calls `pthread_mutex_unlock(M)` — unlocking a mutex
  it does not own (foreign/double unlock), breaking mutual exclusion.

## Real consumers
- `src/libs/syscall/src/pthread/syscall/cond.rs`: `pthread_cond_wait` / `pthread_cond_timedwait`
  call `__kcall_wait_cond(...)?` and, per POSIX, hand control back to the application expecting the
  mutex to be held.
- `src/libs/syscall/src/pthread/syscall/rwlock.rs:259,311`: rd/wrlock call `__kcall_wait_cond(...)?`
  inside a loop that re-reads shared state assuming the mutex is held on return.

## Developer intent (Step 2)
- `git blame`: line 127 authored in `a1347bc3e` ("[libs] E: Timed Mutex Lock"); no comment
  acknowledging the missing relock-error handling.
- `src/kernel/src/kcall/dispatcher.rs:274-281` (`handle_sleep_error`, `InterruptReason::Signaled`)
  states verbatim: *"The current blocking calls make no observable partial progress before
  interruption, so reporting `EINTR` (rather than a short count) is always correct here."* This is
  the developers' stated invariant — but `wait_cond` DOES make observable partial progress: it has
  already released the mutex. The comment shows the relock/ownership gap was not considered, i.e.
  this is an unreported defect, not a documented trade-off.
- SA_RESTART restart (dispatcher.rs:283) records the kcall for transparent restart. On restart
  `wait_cond` re-runs `take_mutex_guard(pid,tid,M)` — but t1 no longer holds M's guard (it was
  released and never reacquired), so `take_mutex_guard`/`remove_mutex_guard` fails → EINTR again.
  The restart cannot recover the mutex either, so the bad state is not masked by SA_RESTART.

## Step 3 — Known status
- Upstream `nanvix/nanvix` HEAD (`src/kernel/src/pm/kcall/wait_cond.rs`, SHA e7fd221) is byte-for-
  byte identical to the worktree — still unfixed.
- Issue-tracker search (`repo:nanvix/nanvix`): #2695 "[signals] Blocking-Call Interruption
  (EINTR/SA_RESTART/sigsuspend)" (CLOSED) is the feature that MADE `wait_cond`/`lock_mutex`
  interruptible (it lists them as the blocking calls funnelled through `handle_sleep_error`); it
  does NOT report that `wait_cond` returns without re-holding the mutex. #2612 is about mutex/cond
  re-init across fork — different mechanism. No issue/PR/CVE reports THIS defect (cond_wait relock
  returning EINTR mutex-not-held). → Novelty: NEW.

## Reachability & consequence
- Reachable: yes, via the real signal + contended-relock sequence above (Level-2 admissible; matches
  CE step `MCCondWaitRelockInterrupted`).
- Consequence: permanent — nothing reacquires the mutex after the EINTR return; the userspace caller
  resumes its critical section without the lock. Not masked by any downstream mechanism.
