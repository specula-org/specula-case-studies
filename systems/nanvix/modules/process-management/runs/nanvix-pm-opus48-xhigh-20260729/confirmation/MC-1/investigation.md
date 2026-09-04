# MC-1 Investigation — Lost condvar/join notification to a sleeper embedded in an interrupted process

Source: model-checking (counterexample `spec/output/MC_hunt_MC-1.out`), invariant `MCNoLostNotify`.

## Step 1 — Code audit (facts)

### Cited sites
- `src/kernel/src/pm/process/manager/mod.rs:1880` — `fn try_wakeup(&mut self, tid) -> Option<RunnableProcess>`
  scans ONLY `self.suspended` (1883-1906) then `self.ready` (1910-1933). It never scans
  `self.interrupted`, `self.running`, or `self.zombies`.
- `src/kernel/src/pm/process/manager/mod.rs:1852` — `fn try_wakeup_thread(&mut self, tid) -> bool`
  checks the running process (1854), else delegates to `try_wakeup` (suspended+ready). Returns
  `false` if not found.
- `do_wakeup` (mod.rs:1821) wraps `try_wakeup_thread`; returns `Err(NoSuchEntry)` on `false`.
- `ProcessManager::wakeup_waiter` (manager/unsafe.rs:1142) = `try_wakeup_thread` (returns bool),
  used by condvar notify.
- `src/kernel/src/pm/sync/condvar.rs` — `notify_first` (118-130): pops the front waiter off the
  condvar FIFO, calls `ProcessManager::wakeup_waiter(tid)`; if it returns `false` the waiter is
  DISCARDED (treated as a stale/timed-out entry) and the loop continues. So a `false` return
  silently consumes the notification for a genuinely-sleeping thread. `notify_all` (196-208) and
  `notify_thread` (155-174) have the same discard-on-false behavior.

### Manager process lists
`ProcessManager` (mod.rs:207-215) has five lists: `running`, `ready` (Runnable), `suspended`
(Sleeping), `interrupted` (Interrupted), `zombies`.

### How a still-sleeping thread ends up in an INTERRUPTED process
An `InterruptedProcess` (state/interrupted.rs:39-44) carries
`sleeping_threads: Option<NonEmptyVecDeque<SleepingThread>>` in addition to its interrupted
threads. It is produced with residual sleepers by:
- `SleepingProcess::wakeup_alarm` (state/sleeping.rs:179-248): when a fully-suspended multi-thread
  process has ONE thread whose alarm expired, that thread becomes InterruptedThread(TimedOut) and
  the process moves to Interrupted, but sibling threads whose alarm has NOT expired (or have no
  alarm) are RETAINED as `SleepingThread`s (lines 190-211). => AlarmFire path.
- `SleepingProcess::interrupt_thread(tid, Signaled)` (state/sleeping.rs:154-177): interrupts ONE
  sleeping thread, keeps the rest sleeping, returns InterruptedProcess. Called by
  `interrupt_suspended_thread` (manager/mod.rs:1034-1052) from `interrupt_signal_candidate`
  (1009-1018) on the SIGNAL-delivery path. => Signal path.
- `InterruptedProcess::find_thread` (interrupted.rs:163-188) DOES find the retained sleeping
  thread, and `RunnableProcess::wakeup`/`SleepingProcess::wakeup` can wake such a thread — the
  capability exists; `try_wakeup` simply never looks in the interrupted list.

### Trigger scenarios and reachability
Two ways to reach "sleeper embedded in a non-suspended process", both real:

1. ALARM path (the MC counterexample). `check_alarm` (mod.rs:1704-1736) is called ONLY from
   `schedule()` (mod.rs:1676). Immediately after, the SAME `schedule()` DRAINS the entire
   interrupted list (mod.rs:1679-1682): every InterruptedProcess is `resume()`d (interrupted.rs:82)
   to a RunnableProcess (carrying the residual sleeper) and pushed to `ready`. So an alarm-interrupted
   process NEVER survives a single `schedule()` call: by the time any later kcall (notify) runs, the
   process is on `ready`, which `try_wakeup` DOES scan and CAN wake (RunnableProcess::wakeup,
   runnable.rs:205-227). => The alarm trigger is MASKED by the schedule()-drain.

2. SIGNAL path (durable, NOT masked). `kill(target, signum)` where the target has a Handler
   installed for `signum` sets `PostAction::Interrupt` (mod.rs:852-857) and calls
   `interrupt_signal_candidate` -> `interrupt_suspended_thread`, moving a suspended multi-thread
   target to `interrupted` while keeping the non-candidate sleeper asleep. This happens in the kill
   kcall handler (kcall/kill.rs), which returns `KcallResult::ok()` WITHOUT calling `schedule()`.
   So the target sits DURABLY in `interrupted`. The same running caller can then issue
   `cond_signal` (kcall/signal_cond.rs) -> `notify_first` -> `wakeup_waiter(sleeper)` ->
   `try_wakeup` misses the interrupted list -> returns false -> notify_first discards the waiter.
   The sleeping thread is stranded forever. (The terminate path, mod.rs:2311-2321, similarly leaves
   a durable interrupted process.)

Consequence: a condvar/join notification is consumed (waiter popped off the FIFO) while the
still-sleeping thread is never woken. Real consumer observing the wrong outcome: the notifier
(`Condvar::notify_first`, condvar.rs:118) returns 0 awakened and discards the waiter; the waiting
thread's `wait_cond`/`join` kernel call never returns (permanent liveness loss). Matches
`MCNoLostNotify` / `lostNotify=true` in the CE.

## Step 2 — Developer-knowledge search
- Comments at the cited sites (do_wakeup 1825-1831; try_wakeup_thread doc 1846-1851; condvar
  notify_first 118-127) frame a `false`/NoSuchEntry return as an EXPECTED race with an
  already-woken/timed-out/reaped waiter — i.e. developers assume a `false` return means the waiter
  legitimately left the sleeping state. They do NOT account for a waiter that is genuinely still
  sleeping but parked inside an interrupted (or ready-via-drain) process. No comment/TODO/FIXME
  acknowledges the interrupted-list omission.
- `try_wakeup` explicitly enumerates only "suspended or ready process" (comment mod.rs:1870); the
  interrupted list is simply not considered.
- Existing tests (`state/kill_test.rs::test_terminate_folds_sleeping_threads_as_killed`) already
  construct an InterruptedProcess that retains a still-sleeping thread, confirming this state is a
  recognized, real configuration — but no test exercises a wakeup against it.
- git history: to be checked (Step 3).

## Step 3 — Known-status / precedent
- MC-sourced with an actual counterexample => proceeds to Phase 2 regardless of novelty (no
  code-review×known pre-filter applies).
- git log/grep: the interrupted-list-with-residual-sleeper machinery was introduced by the recent
  signal-delivery work (`c7cb73b66 [kernel] F: Deliver Caught Signals`, `094b4cd3d [kernel] F:
  Deliver Signals To Blocked Threads`). The nearest related commit, `90a7af4e5 [kernel] E: Quiet
  benign thread-not-found logs` (Closes #2651), DOWNGRADED do_wakeup's NoSuchEntry from ERROR to
  TRACE, explicitly framing a `false`/NoSuchEntry return as a benign race with an already-gone
  forked-applet thread — a DIFFERENT aspect; it does not address (and in fact further hides) the
  interrupted-list omission. No commit/issue reports try_wakeup omitting the interrupted list or a
  lost wakeup to a sleeper embedded in a non-suspended process.
- Web search for the mechanism returned only generic "lost wakeup" concurrency material; no Nanvix
  issue/PR for this site.
- Conclusion: NEW (looked, found nothing reporting THIS mechanism at THIS site).

## FINAL (post-reproduction) — fresh run 2026-07-29

- Verdict: **REPRODUCED** (Level 2 — reachable state injection, driven through the REAL PM
  transition `interrupt_suspended_thread` and the REAL wakeup path `try_wakeup_thread`
  == `wakeup_waiter`). Evidence:
  `repro/test_bugMC-1_lost_wakeup_interrupted.{sh,rs,fixture.rs,run.log,build.log}`.
- In-kernel test ran at boot (process-manager test aggregator) inside the standalone UserVM; the
  kernel compiled my modules fresh (build.log: `Compiling kernel ... Finished in 28.60s`), the test
  logged `passed: test_mc1_lost_wakeup_to_interrupted_sleeper`, and the kernel reached the boot magic
  string and shut down cleanly.
- Differential proven in the running kernel (identical `try_wakeup_thread` call, only the parent
  list differs):
  - `[BUG] parent on INTERRUPTED: try_wakeup_thread(t9102) = false (lost=true); sibling still = Some("sleeping")`
  - `[CONTROL] parent on SUSPENDED: try_wakeup_thread(t9202) = true (delivered=true)`
- Permanence: `[BUG][PERMANENCE] after resume() drains the interrupted process to ready: sibling
  t9102 = Some("sleeping")` — the real `resume()` (what schedule() does) does NOT wake the residual
  sleeper, and the consumed notification is not resent.
- Isolation: `[BUG][ISOLATION] parent now on READY: try_wakeup_thread(t9102) = true` — the exact
  same thread/call is wakeable the instant its process sits on a list `try_wakeup` scans, proving the
  loss is caused SOLELY by the interrupted-list omission.
- Alarm trigger (literal CE) is masked by the schedule() drain (mod.rs:1679-1682, verified by
  reading); the SIGNAL trigger (kill -> interrupt_signal_candidate -> interrupt_suspended_thread;
  kill kcall returns without scheduling, kcall/kill.rs:71) is durable and unmasked, making the lost
  notification permanent. Same code site (try_wakeup omitting interrupted), same invariant
  (MCNoLostNotify), same "sleeper embedded in a non-suspended process" mechanism.

### Novelty (my own search, this run)
- git history around the site: `6055a7366 [kernel] E: Skip stale condvar waiters` INTRODUCED the
  `wakeup_waiter`/`notify_first` discard-on-false design, under the stated assumption that a `false`
  return means the waiter "already left the sleeping state" (timed out / already woken) — a *benign*
  race. It does NOT address a `false` returned for a thread that is STILL genuinely sleeping inside
  an interrupted process. Adjacent commits (`cfeba73ab` per-thread alarms, `6f25051d9` faster list
  restoration, `8b454e36e` preserve queue order) touch the area but none reports the interrupted-list
  omission. Note manager/mod.rs:2943 (`Search thread in the list of interrupted processes`) shows
  other manager lookups DO scan the interrupted list — the `try_wakeup` omission is a genuine gap.
- Public tracker / web: only generic lost-wakeup material and unrelated issues (#1637 `.take()`
  anti-pattern, #1643 heap exhaustion); nothing reports THIS mechanism at THIS site.
- Conclusion: **NEW**.

## FINAL (post-reproduction) — fresh confirmation run 2026-07-30 (turn01_A)

- Verdict: **REPRODUCED** (Level 2 — reachable state injection, driven through REAL PM transitions
  `RunnableProcess::new/run/add_thread/sleep` and the REAL signal path `sigaction`+`kill` ->
  `interrupt_signal_candidate` -> `interrupt_suspended_thread`, then the REAL wakeup path
  `do_wakeup` == `try_wakeup_thread` == `wakeup_waiter` — the exact call `Condvar::notify_first`
  makes on a dequeued waiter). Evidence:
  `repro/test_bugMC-1_lost_wakeup_interrupted.{sh,rs,run.log,build.log}`.
- Fresh kernel compile (build.log: `Compiling kernel v0.21.51 ... Finished in 28.53s`, no errors),
  booted `bin/kernel-test.elf` in the standalone uservm, reached the clean-shutdown magic string.
- Markers (run.log lines 199-203):
  - `MC-1 PRECONDITION ...: waiter t9112=sleeping, signaled t9111=interrupted`
  - `MC-1 BUG [interrupted]: do_wakeup(t9112) = Err(Error { code: NoSuchEntry, ... }) lost=true; after the failed wakeup t9112=sleeping (still stranded)`
  - `MC-1 CONTROL [suspended]: do_wakeup(t9211) = Ok(()) delivered=true`
  - `MC-1 ISOLATION [after resume()->ready]: do_wakeup(t9112) = Ok(()) wakeable=true`
  - `MC-1 BUG REPRODUCED ...`
- Same site (`try_wakeup` omitting `interrupted`), same invariant (MCNoLostNotify), same mechanism
  (sleeper embedded in a non-suspended process). The literal-CE ALARM trigger is masked by the
  schedule() interrupted-drain (mod.rs:1679-1682); the SIGNAL trigger used here is durable (kill
  kcall returns without scheduling), so the lost notification is permanent.
- Novelty (my own search this run): git log -S "fn try_wakeup" shows the function was touched by
  `cfeba73ab`, `ef77f89d4`, `93fcd64c9` but none added the interrupted-list scan or reported a lost
  wakeup; no commit message matches lost wakeup/interrupted list/stale waiter; no TODO/FIXME/issue
  ref near the site. Public tracker/web: only generic lost-wakeup material and unrelated issues
  (#2695 EINTR/SA_RESTART blocking-call interruption; #1637 `.take()` cleanup) — nothing reports
  THIS mechanism at THIS site. Conclusion: **NEW**.
