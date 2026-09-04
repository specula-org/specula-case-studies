# MC-5 Investigation — NoUndeliverableCaught

## Finding
A caught (handler) signal pending on a non-suspended process is never delivered when every
running/ready thread masks it and the only unmasked recipient is a sleeping thread parked inside
the (still runnable) process.

## Counterexample (spec/output/MC_hunt_scenario4_mc5_final.out)
7-state trace, invariant `NoUndeliverableCaught` violated:
1. p1 alive, t1 running.
2. t2 created (ready) on p1.
3. t1 -> sleeping (bk=sleep), t2 ready.
4. t2 -> running, t1 sleeping.
5. p1 disposition for sig 1 set to `handler` (caught).
6. sig 1 posted -> p1 pending = [1] (dp=handler, sp=false -> non-suspended, caught, pending).
7. t2 (running) has bl=[1] (masks sig 1); t1 (sleeping) unmasked. => undeliverable caught signal.

## Code audit (worktree)
- `ProcessManager` lists (mod.rs:207-215): `running` (1), `ready: LinkedList<RunnableProcess>`,
  `suspended: LinkedList<SleepingProcess>`, `interrupted`, `zombies`.
  - A process with >=1 ready/running thread lives in `running`/`ready` (a `RunnableProcess` may
    also hold `sleeping_threads`). A process becomes a `SleepingProcess` in `suspended` ONLY when
    ALL its threads are sleeping (do_sleep Err branch, mod.rs:1783-1787).
- `kill()` (mod.rs:810-899): a caught signal -> `signals.post(signum)` + `PostAction::Interrupt`
  -> `interrupt_signal_candidate(target, signum)` (mod.rs:894).
- `interrupt_signal_candidate` (mod.rs:1009-1018): scans **only `self.suspended`** for the pid,
  then `candidate_tid_for(signum)`. A runnable process (in `running`/`ready`) is never scanned,
  so its sleeping threads are invisible here.
- `candidate_tid_for` (state/sleeping.rs:89-95) exists ONLY on `SleepingProcess`. `RunnableProcess`
  (state/runnable.rs) has NO candidate-selection / signal-interrupt method at all.
- Running-thread delivery `try_deliver_signal` (manager/signal.rs:206-316):
  `deliverable = (signals.pending() | thread_pending) & !blocked`. If the running thread masks the
  signal (`blocked` bit set), deliverable=0 -> `SignalDeliveryOutcome::None`; the process-pending
  signal is left pending.
- Developer intent (doc comment mod.rs:1000-1002): "Only a fully-suspended process needs explicit
  help; a process that still has a ready or running thread reaches its own checkpoint without being
  woken." This assumption is the root cause: it is false when that ready/running thread MASKS the
  signal — it reaches its checkpoint but skips delivery, and the sleeping unmasked thread (the only
  valid recipient) is never interrupted.

## Reachability (real kernel-call sequence)
create_process(p1,t1) -> create_thread(t2) -> t2 sigprocmask blocks S (unmasked t1) -> t1 sleeps
(cond/mutex/nanosleep) while t2 runs/ready -> another process sigaction installs handler for S ->
kill(p1,S). All are real kcall entry points (kcall/{create,thread,sleep,sigprocmask,sigaction,
kill}.rs). No suspended entry exists for p1, so interrupt_signal_candidate finds no candidate.

## Permanence / downstream mask check
- No periodic re-scan of pending caught signals for suspended/runnable processes exists.
  `check_alarm` (mod.rs:1704-1736) only services timer alarms. The transition runnable->suspended
  (do_sleep) does NOT re-run interrupt_signal_candidate for already-pending signals.
- So while t2 keeps S masked and t1 keeps sleeping, S stays pending forever. Only a voluntary
  t2 sigprocmask-unblock would deliver it — not guaranteed for a program that intentionally
  dedicates t1 to handle S. => permanent; not masked by any safeguard.

## Consumer
User process p1: its installed handler for S never runs though S was accepted (pending) at the
process level — POSIX requires a process-directed signal be delivered to any thread not blocking
it (t1). Liveness violation (also SignalEventuallyDelivered, scenario4_live).

## Known-status (Step 3)
See git-history search in the verdict body. No filed issue/PR for this mechanism found.
