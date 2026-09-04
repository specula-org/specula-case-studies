# Instrumentation Spec — Nanvix Process Management

Maps each TLA+ base-spec action to the kernel source location(s) where a trace event
must be emitted, and the fields to capture. The trace is a single **linearly-ordered**
NDJSON file (Nanvix PM is single-core with interrupts disabled, so all kernel events are
totally ordered — no per-thread timebox is needed). One trace event drives exactly one
base-spec action; `Trace.tla` replays them through the cursor `l` and validates the
captured post-state against the spec's primed state.

Source root: `src/kernel/src/pm/` (paths below are relative to it).

---

## Section 1: Trace Event Schema

### Event envelope

```json
{
  "event": "<ActionName>",     // matches a base-spec action / Trace.tla wrapper
  "pid":   "<pStr>",           // target process (PostSignal*, SetDisposition, InstallHandler)
  "tid":   "<tStr>",           // acting thread, where relevant
  "cond":  "<cStr>",           // CondAddr (Sleep, NotifyDequeue, CondWaitUnlock)
  "mutex": "<mStr>",           // MutexAddr (Lock*/Unlock/CondWait*)
  "sig":   <int>,              // signal number (PostSignal*, Sigaction, MarkInterrupted)
  "disp":  "default|ignore|handler",   // SetDisposition
  "sar":   true|false,         // InstallHandler SA_RESTART flag
  "mask":  [<int>, ...],       // MaskChange / SigSuspendInstall temporary mask
  "state": { ... }             // post-action snapshot (see below)
}
```

### `state` snapshot fields

Captured **after** the action commits (post-state). The core three are captured at
every event; sub-state and ghost fields are captured only for the events whose validator
reads them (see Section 2). Model-value mapping: real `ProcessIdentifier`/`ThreadIdentifier`
values are rendered to the small symbolic set (`"p1".."p2"`, `"t1".."t3"`); a free slot is
omitted from the process/thread set or rendered `"free"`; the empty running slot is
`"NoProc"`.

| JSON field (`state.…`) | TLA+ variable | Encoding | Source getter |
|---|---|---|---|
| `procState` | `procState` | obj `pid→state` | manager list membership: `running`/`ready`/`suspended`/`interrupted`/`zombies` (manager/mod.rs:199-215) |
| `threadState` | `threadState` | obj `tid→sub` | thread subset within its process (running/ready/sleeping/interrupted/zombie) |
| `running` | `running` | `pid` or `"NoProc"` | `self.running` occupancy (manager/mod.rs:2780-2788) |
| `threadReason` | `threadReason` | obj `tid→reason` | `InterruptedThread.reason` / `ThreadState.interrupt_reason` (thread/interrupted.rs:24, thread/state.rs:85) |
| `exitPhase` | `exitPhase` | `"none"/"taken"/"cleaned"` | do_exit window marker (manager/mod.rs:2116-2144) |
| `pending` | `pending` | obj `pid→[int]` | `SignalControl.pending` (state/signal.rs:110) |
| `blocked` | `blocked` | obj `tid→[int]` | `ThreadState.blocked` (thread/state.rs:93) |
| `disposition` | `disposition` | obj `pid→[sig→disp]` | `SignalControl.dispositions` (state/signal.rs:106) |
| `savedBlocked` | `savedBlocked` | obj `tid→[int]`or`"NoMask"` | `ThreadState.saved_blocked` (thread/state.rs:105) |
| `condWaiters` | `condWaiters` | obj `cond→[tid]` | `CondvarInner.sleeping` (sync/condvar.rs:43) |
| `mutexInMap` | `mutexInMap` | obj `mutex→bool` | key present in `ProcessState.mutexes` (state/mod.rs:608-623) |
| `mutexLocked` | `mutexLocked` | obj `mutex→bool` | `MutexInner.locked` (sync/mutex.rs:36) |
| `mutexOwner` | `mutexOwner` | obj `mutex→tid`or`"NoThread"` | thread whose `locked_mutexes` holds the guard (thread/state.rs:83) |
| `held` | `held` | obj `tid→[mutex]` | keys of `ThreadState.locked_mutexes` |
| `panicked` … `spuriousOOM` | ghost flags | bool (always `false` on a real run) | see Section 3 |

Set-valued fields (`pending`, `blocked`, `held`, and the set form of `savedBlocked`) are
emitted as JSON arrays; `Trace.tla`'s `AsSet` converts them back to sets. `condWaiters`
values stay ordered arrays (they map to spec sequences).

---

## Section 2: Action-to-Code Mapping

One entry per base-spec action / `Trace.tla` wrapper. "Trigger" is the instrumentation
point where the post-state snapshot is taken.

| Spec action | Code location(s) | Trigger (emit after) | Event | Key fields validated |
|---|---|---|---|---|
| `Schedule` | `RunnableProcess::run` (runnable.rs:134) via `take_earliest_ready`; commit at manager/mod.rs:1697,1803,2159 | after `self.running = Some(next)` | `Schedule` | core |
| `Preempt` | `tick`→`giveup`→`schedule` (unsafe.rs; manager/mod.rs) | after the outgoing thread is re-queued and `running` cleared | `Preempt` | core |
| `CreateProcess` | `create_process` (manager/mod.rs:1129-1216) | after `self.ready.push_back(process)` (:1211) | `CreateProcess` | core, `pending` |
| `CreateThread` | `create_thread` (manager/mod.rs:~417) | after the new ready thread is installed | `CreateThread` | core, `blocked` |
| `CreateProcessSpuriousOOM` | `create_process` cap gate (manager/mod.rs:1139-1147) | after the OutOfMemory return when a zombie is reclaimable | `CreateProcessSpuriousOOM` | core, ghosts |
| `HarvestZombieProc` | `harvest_zombies`→`pop_zombie_process` (manager/mod.rs:3430,2460) | after the zombie is buried and `live_count--` | `HarvestZombieProc` | core, `mutexLocked`, `mutexOwner`, `held` |
| `Sleep` | `do_sleep` (manager/mod.rs:1756-1806); `Condvar::wait` enqueue (condvar.rs:257) | after `push_back(tid)` + process re-queued | `Sleep` | core, `condWaiters` (+`cond`) |
| `AlarmFire` | `check_alarm` (manager/mod.rs:1704-1735); `SleepingProcess::wakeup_alarm`; `RunnableProcess::wakeup_expired_alarms` (runnable.rs:252) | after the fired sleeper is moved to interrupted/ready | `AlarmFire` | core, `threadReason`, `condWaiters` |
| `NotifyDequeue` | `Condvar::notify_first` pop (condvar.rs:123) | after the waiter tid is popped from the queue | `NotifyDequeue` | `condWaiters` (+`cond`) |
| `WakeDequeued` | `wakeup_waiter`→`try_wakeup_thread`→`try_wakeup` (unsafe.rs:1142; manager/mod.rs:1852,1880) | after the search returns (woken / not found / panic) | `WakeDequeued` | core, `threadReason`, ghosts |
| `RunnableTerminate` | `ProcessManager::terminate` ready branch (manager/mod.rs:2294-2308)→`RunnableProcess::terminate` (runnable.rs:165-203) | after the process is re-listed | `RunnableTerminate` | core, `threadReason` |
| `SuspendedTerminate` | terminate suspended branch (manager/mod.rs:2311-2315)→`SleepingProcess::terminate` | after move to interrupted | `SuspendedTerminate` | core, `threadReason` |
| `InterruptedTerminate` | terminate interrupted branch (manager/mod.rs:2318-2320)→`InterruptedProcess::terminate` (interrupted.rs:110-125) | after set_killed fold | `InterruptedTerminate` | core, `threadReason` |
| `ResumeInterrupted` | `InterruptedProcess::resume` (interrupted.rs:82-94,115-118); manager interrupted→ready move (manager/mod.rs:1679) | after the resumed thread is in the ready subset | `ResumeInterrupted` | core, `threadReason` |
| `DispatcherCheckpoint` | `dispatcher.rs:263-289` (InterruptReason→exit/ETIMEDOUT/EINTR) | after the reason is acted on (exit or return-to-user) | `DispatcherCheckpoint` | core, `threadReason`, ghosts |
| `RegisterRendezvous` | rendezvous push/pull registration (ipc/rendezvous.rs) + caller blocks | after the counterpart tid is recorded and the caller sleeps | `RegisterRendezvous` | core |
| `ExitTakeRunning` | `do_exit` `take_running()` (manager/mod.rs:2116) | after `self.running` is nulled | `ExitTakeRunning` | core (`running`=`"NoProc"`), `exitPhase` |
| `ExitCleanupRendezvous` | `cleanup_rendezvous` (manager/mod.rs:2130,2766)→`do_wakeup` | after the wakeup loop (or the panic point) | `ExitCleanupRendezvous` | `exitPhase`, ghosts (`panicked`) |
| `ExitReinsert` | `running_process.exit()` fold + re-list (manager/mod.rs:2133-2159; running.rs:265-321) | after the process is placed on ready/zombie and next scheduled | `ExitReinsert` | core, `threadReason`, `exitPhase` |
| `LockMutexAcquire` | `lock_mutex` success (lock_mutex.rs:92-94); `get_mutex` (state/mod.rs:608), `try_lock` (sync/mutex.rs:133) | after `put_mutex_guard` records the guard | `LockMutexAcquire` | `mutexInMap`, `mutexLocked`, `mutexOwner`, `held` (+`mutex`) |
| `LockMutexCancel` | `lock_mutex` timeout/interrupt (lock_mutex.rs:93 `?`) | after the `?`-return that skips `put_mutex` | `LockMutexCancel` | `mutexInMap` (+`mutex`) |
| `UnlockMutex` | `unlock_mutex`→`remove_mutex_guard`→`put_mutex` (unlock_mutex.rs:56; manager/mod.rs:2635) | after `put_mutex` runs | `UnlockMutex` | `mutexInMap`, `mutexLocked`, `mutexOwner`, `held` (+`mutex`) |
| `CondWaitUnlock` | `wait_cond` `take_mutex_guard` (wait_cond.rs:105-107) | after the guard is dropped (mutex released) | `CondWaitUnlock` | `mutexLocked`, `mutexOwner`, `held` (+`cond`,`mutex`) |
| `CondWaitSleep` | `wait_cond` `cond.wait` (wait_cond.rs:111; condvar.rs:257-259) | after `push_back(tid)` + process re-queued | `CondWaitSleep` | core, `condWaiters` |
| `CondWaitRelock` | `wait_cond` reacquire success (wait_cond.rs:126-128) | after `put_mutex_guard` restores the guard | `CondWaitRelock` | `mutexLocked`, `mutexOwner`, `held` |
| `CondWaitRelockInterrupted` | `wait_cond` reacquire interrupted / `put_cond?` early return (wait_cond.rs:123,127) | after the `?`-return without the mutex held | `CondWaitRelockInterrupted` | `mutexLocked`, `held`, ghosts (`condWaitBad`) |
| `PostSignalHandler` | `kill` handler branch (manager/mod.rs:849-856)→`interrupt_signal_candidate` (:1009-1017) | after `signals.post` + candidate scan | `PostSignalHandler` | core, `pending`, `threadReason`, ghosts (+`pid`,`sig`) |
| `PostSignalDefaultTerminate` | `kill` default-Terminate branch (manager/mod.rs:858-893)→`kill_terminate` | after the target is terminated | `PostSignalDefaultTerminate` | core, `threadReason`, ghosts (+`pid`,`sig`) |
| `SetDisposition` | `sigaction` install (manager/mod.rs:603-611) | after `set_disposition` | `SetDisposition` | `disposition`, ghosts (+`pid`,`sig`,`disp`) |
| `InstallHandler` | `sigaction` install handler (manager/mod.rs:603-611; state/signal.rs:84) | after `set_disposition(Handler)` | `InstallHandler` | `disposition` (+`pid`,`sig`,`sar`) |
| `DeliverSignal` | `try_deliver_signal` (signal.rs:206-316) | after the deliver / discard decision commits | `DeliverSignal` | `pending`, `blocked`, ghosts |
| `MaskChange` | `sigprocmask` (manager/mod.rs:616+; state/signal.rs:175 `compute_blocked`) | after `set_blocked` | `MaskChange` | `blocked` (+`mask`) |
| `Exec` | `do_execv`→`reset_for_exec` (state/signal.rs:490-497) | after pending zeroed / dispositions reset | `Exec` | `pending`, `disposition` |
| `SigSuspendInstall` | `install_sigsuspend_mask` (manager/mod.rs:722-749) | after `set_saved_blocked` + `set_blocked` | `SigSuspendInstall` | `blocked`, `savedBlocked`, ghosts (`savedMaskViolated`) (+`mask`) |
| `SigReturn` | `sigreturn_restore` (signal.rs:546-611) | after `take_saved_blocked` + `set_blocked` | `SigReturn` | `blocked`, `savedBlocked` |
| `MarkInterruptedBySignal` | `set_running_thread_restart` (signal.rs:184-189); dispatcher Signaled branch (dispatcher.rs:274-286) | after the KcallRestart record is set | `MarkInterruptedBySignal` | (+`sig`) |

---

## Section 3: Special Considerations

- **Bug-ghost fields** (`panicked`, `lostNotify`, `signalDeliveryFailed`,
  `resumedAfterTerminate`, `condWaitBad`, `maskViolated`, `immortalPending`,
  `savedMaskViolated`, `restartMisattributed`, `spuriousOOM`) are **modeling artifacts**,
  not real kernel state. On a real execution they are always `false` and the harness emits
  `false`. `Trace.tla`'s `ChkGhosts` then asserts the spec did not set a ghost while
  replaying — i.e. the implementation did not exhibit the modeled bug on that trace. If a
  ghost check fails during replay, the spec and implementation disagree about whether the
  bug fired (investigate; do not delete the check).

- **Split actions and granularity.** Several kernel operations are modeled as multiple
  sequential actions with their own events, because the interleaving between them is where
  the bugs live. Instrument each step separately:
  - `do_exit` → `ExitTakeRunning` → `ExitCleanupRendezvous` → `ExitReinsert`
    (the `running == None` window between take-running and reinsert is Scenario 3).
  - `wait_cond` → `CondWaitUnlock` → `CondWaitSleep` → (wakeup) → `CondWaitRelock` **or**
    `CondWaitRelockInterrupted` (the return-without-mutex window is Scenario 5).
  - condvar notify → `NotifyDequeue` → `WakeDequeued` (the consumed-but-not-woken window is
    Scenario 1); keep them as two events so the gap is observable.
  - interrupted resume → `ResumeInterrupted` → `DispatcherCheckpoint` (the return-to-user
    decision is Scenario 2).

- **Cross-process `kill`.** `PostSignalHandler` / `PostSignalDefaultTerminate` carry an
  explicit `pid` (the target) because procd signals *other* processes; the acting (running)
  process is the caller. `SetDisposition` / `InstallHandler` / `MaskChange` /
  `SigSuspendInstall` / `SigReturn` are self-directed, so their `pid`/`tid` is the running
  process/thread.

- **Bootstrap.** The trace begins after the first process is running with a single running
  thread. `Trace.tla`'s `TraceInit` pins this deterministically (`bootProc`/`bootThread`);
  the first real event must transition from that state. If the harness cannot guarantee the
  boot layout maps to `bootProc`/`bootThread`, emit a leading `"Init"` event carrying the
  full `state` and have `TraceInit` adopt it.

- **Model-value mapping.** The harness must maintain a stable mapping from live kernel
  PIDs/TIDs to the small symbolic set `{"p1","p2"}` / `{"t1","t2","t3"}` for the duration of
  a trace (reuse a symbol only after its slot is harvested), and from real signal numbers to
  the modeled `{1,2}`. Keep the trace within the modeled bounds (`MaxProc`, `MaxThread`,
  `MutexOpenMax`) or widen the `Trace.cfg` constants accordingly.

- **Running the validator.** `tlc -deadlock -config Trace.cfg Trace.tla` (deadlock detection
  **off**, so the trace-consumed terminal state does not mask the `TraceMatched` liveness
  check). Point at a specific trace with `JSON=/path/to/trace.ndjson`; the default is
  `../traces/trace.ndjson`.
