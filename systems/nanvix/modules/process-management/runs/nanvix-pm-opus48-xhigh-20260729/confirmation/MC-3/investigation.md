# MC-3 Investigation

## Finding
Terminated/exited process resumes user code on a carried-forward interrupted thread.
Invariant: `TerminatedThreadsDie`. Source: model-checking (real counterexample
`spec/output/MC_hunt_MC-3.out`, config `MC_hunt_scenario2.cfg`).

## Step 1 — Code audit (facts)

### The asymmetry (root cause)
- `InterruptedProcess::terminate` (interrupted.rs:110-125) force-marks every
  already-interrupted thread `Killed` via `thread.set_killed()` (thread/interrupted.rs:128),
  and folds remaining sleeping threads in as `Killed`. Doc string: "so that all of its
  threads exit once resumed."
- `RunnableProcess::terminate` (runnable.rs:165-203): line 180-181 does
  `self.interrupted_threads.take()` and re-attaches them **unchanged** (line 192-193) into
  the resulting `InterruptedProcess`. Sleeping threads it interrupts DO get `Killed`
  (line 185 → interrupted::interrupt → InterruptReason::Killed), but a pre-existing
  interrupted thread keeps its original reason (TimedOut/Signaled).
- `RunningProcess::exit` (running.rs:265-321): line 293-294 `self.interrupted_threads.take()`
  unchanged; folds sleeping→Killed (line 298) but leaves pre-existing interrupted reasons;
  then builds `InterruptedProcess::from_sleeping` and immediately `.resume()`s (line 313),
  returning `Ok((RunnableProcess, ctx))` — i.e. the "exited" process becomes runnable again
  with a live thread whose reason is TimedOut/Signaled.

### How "termination" is enforced (why reason matters)
There is NO separate "terminated" gate in ProcessManager scheduling. Termination is
implemented purely by marking threads `Killed`, so that when a thread resumes from its
blocking call the dispatcher tears the process down:
- `ProcessManager::sleep` (unsafe.rs:845-873) returns `Err(Interrupted(reason))` on resume.
- Sleep syscall: `pm::sleep` (kcall/sleep.rs:62-66) maps `Interrupted(TimedOut) → Ok(())`
  (return to user). Killed/Signaled → Err, handled by `handle_sleep_error`
  (kcall/dispatcher.rs:250-291): **Killed → ProcessManager::exit() (never returns)**;
  TimedOut → EOperationTimedOut; **Signaled → EINTR + restart record (returns to user)**.
- sigsuspend (kcall/sigsuspend.rs:113-128): **Killed → exit()**; any other Interrupted → EINTR.

Therefore a terminated process's thread whose reason is TimedOut/Signaled (not Killed) does
NOT exit — it returns to user code. That is exactly the invariant violation.

### Reachability of a live Running/Runnable process holding a TimedOut interrupted thread
`SleepingProcess::wakeup_alarm(now)` (sleeping.rs:179-235): when ≥2 sleeping threads have
expired alarms, it returns an `InterruptedProcess` with MULTIPLE interrupted threads all
reason `TimedOut`. `InterruptedProcess::resume()` (interrupted.rs:82-94) pops ONE to Ready
and carries the REST forward into a `RunnableProcess` (via from_state) as its
`interrupted_threads`. => A RunnableProcess legitimately holds an interrupted thread with
reason TimedOut. `RunnableProcess::run` then yields a RunningProcess carrying the same.

Real-API trigger sequence (all real type-state transitions the PM uses):
1. Process with threads t1,t2. t1 runs; add t2 ready.
2. t1 sleeps with alarm (has ready t2) → RunnableProcess(t1 sleeping, t2 ready).
3. run() → t2 running; t2 sleeps with alarm (no ready) → SleepingProcess(t1,t2 sleeping+alarm).
4. wakeup_alarm(later) → InterruptedProcess(t1 TimedOut, t2 TimedOut).
5. resume() → RunnableProcess(t1 ready, t2 interrupted/TimedOut).
6. terminate()  [or run()→exit()] → carries t2 forward with reason TimedOut (BUG;
   should be Killed). When t2 later resumes it returns to user via Ok(())/EINTR.

### Relation to the MC counterexample
MC trace (MC_hunt_MC-3.out, 11 states) reaches the violation via a resume-after-terminate
re-sleep whose alarm fires (killed→resumed→re-sleep→TimedOut). The root cause and
consequence are identical to the finding's described mechanism (terminate/exit fail to
re-mark interrupted threads Killed). Final state: procTerminated[p1]=true, procState[p1]=running,
threadState[t1]=running, resumedAfterTerminate=true.

## Step 2 — Developer knowledge
- Existing in-kernel test `kill_test.rs::test_terminate_overrides_interrupted_reason`
  (lines 117-137) asserts `InterruptedProcess::terminate` re-marks a TimedOut interrupted
  thread as `Killed` "so that the thread exits rather than resuming its timed-out operation
  when next scheduled." This is direct evidence of the intended contract — which the two
  sibling paths (RunnableProcess::terminate, RunningProcess::exit) do NOT uphold.
- No TODO/FIXME acknowledging the gap at the two sibling sites.

## Step 3 — Known status
- MC-sourced with a real counterexample (spec/output/MC_hunt_MC-3.out, invariant
  TerminatedThreadsDie, config MC_hunt_scenario2.cfg) → proceeds to Phase 2 regardless of novelty.
- git log on the three state files: the only relevant commit is `515ecafcf` "[kernel] E:
  interrupted-process termination" (Pedro H. Penna), which ADDED the kill_test.rs tests asserting
  the contract for `InterruptedProcess::terminate` ONLY. No commit reports or fixes the
  runnable/running sibling gap; no TODO/FIXME acknowledges it.
- Issue-tracker search (github.com/nanvix/nanvix): found only general signal/interrupt issues
  (#2695 "Blocking-Call Interruption (EINTR/SA_RESTART/sigsuspend)", #1010 "Graceful Interrupt of
  Hyperlight Machine") — neither reports THIS mechanism (terminate/exit failing to re-mark a
  carried-forward interrupted thread Killed).
- Upstream `dev` re-check (fetched runnable.rs @ dev, SHA 0f58b3c5): `RunnableProcess::terminate`
  STILL does `self.interrupted_threads.take()` and re-attaches unchanged — the bug is UNFIXED
  upstream. => Novelty: NEW.

## Consumer path (corrected) — who observes the wrong outcome
- `RunnableProcess::run` (runnable.rs:134-162) returns `Option<InterruptReason>`; the scheduler
  stores it: `self.interrupt_reason = reason` (manager/mod.rs:1696/1802/2158/2262).
- `ProcessManager::sleep` (manager/unsafe.rs:864-869) reads it and returns `Err(Interrupted(reason))`.
- **Sleep syscall**: `pm::sleep` (kcall/sleep.rs:62-66) maps `Err(Interrupted(TimedOut)) → Ok(())`;
  outer dispatcher `src/kernel/src/kcall/dispatcher.rs:193-196` → `KcallResult::ok()` → RETURNS TO
  USER. For `Killed`, `pm::sleep` returns Err → `handle_sleep_error` (kcall/dispatcher.rs:250-291)
  → `ProcessManager::exit()` (never returns) → thread dies.
- So reason=TimedOut on a terminated process's thread ⇒ the Sleep syscall returns success and the
  thread resumes user code (TerminatedThreadsDie violation). Consumer: kcall/sleep.rs:64 +
  kcall/dispatcher.rs:193.

## Phase 2 — Reproduction result: REPRODUCED
- In-kernel test `process/state/terminate_mc3_test.rs` drives the REAL type-state machine
  (run/add_thread/sleep/wakeup_alarm/resume/terminate/exit); no illegal injection.
- [CONTROL] InterruptedProcess::terminate → both TimedOut threads re-marked Killed (correct).
- [A] RunnableProcess::terminate → survivor tid=2 keeps reason=TimedOut (BUG).
- [B] RunningProcess::exit → returns a RUNNABLE process; scheduling the carried thread surfaces
  Some(TimedOut) to the scheduler (== value pm::sleep maps to Ok() → user) (BUG).
- Kernel boots to completion ("hello, world!"), no panic/leak. Driver:
  repro/test_bugMC-3_terminated_thread_resumes.sh (exit 0).
