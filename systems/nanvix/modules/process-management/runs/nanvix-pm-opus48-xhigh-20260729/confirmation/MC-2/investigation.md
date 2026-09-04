# MC-2 Investigation — Caught signal never delivered to a sleeper in a non-suspended process

## Finding
- id: MC-2, source: model-checking, invariant: SignalReachesSafety, config: MC_hunt_scenario1.cfg
- counterexample: spec/output/MC_hunt_MC-2.out
- cited code: manager/mod.rs:1009 (interrupt_signal_candidate), manager/mod.rs:892 (kill dispatch)

## Counterexample trace (from MC_hunt_MC-2.out; analyzed with inv tool)
Actions: Initial, MCCreateProcess, MCCreateThread, MCSetDisposition, MCSleep, MCSchedule, MCPostSignalHandler.
Final state (index 7):
- threadOwner: t1->p1, t2->p2, t3->p1  (p1 owns t1 and t3)
- threadState: t1=sleeping, t2=running, t3=ready
- procState: p1=ready, p2=running ; running=p2
- disposition[p1][sig1]=handler ; pending[p1]=[1]
- blocked: t1=[], t3=[]  (both UNMASKED in this trace)
- signalDeliveryFailed=true  (the SignalReachesSafety violation)

p1 has a sleeping thread t1 and a ready thread t3; a caught (handler) signal 1 is posted to p1;
MC flags delivery as failed.

## Step 1 — Code audit (ground truth = Rust)
- interrupt_signal_candidate (mod.rs:1009-1018) resolves a candidate ONLY from self.suspended:
  self.suspended.iter().find(|p| p.state().pid()==pid).and_then(|p| p.candidate_tid_for(signum)).
- candidate_tid_for exists ONLY on SleepingProcess (sleeping.rs:89): picks a sleeping thread that
  does not block signum.
- do_sleep (mod.rs:1777-1788) / RunningProcess::sleep (running.rs:218-262): when a thread sleeps and
  the process STILL has ready threads, the process is pushed to self.ready as a RunnableProcess
  (which carries sleeping_threads: Option<...>), NOT to self.suspended. Only a fully-suspended
  process becomes a SleepingProcess in suspended.
- try_deliver_signal (signal.rs:206-316) is the ONLY async-delivery checkpoint; called ONLY from
  kcall/handler.rs:190 (kernel-call return). It delivers to the RUNNING thread using THAT thread's
  own mask: deliverable = (signals.pending() | thread_pending) & !blocked.

### Consequence
A caught signal posted to a process with a sleeping thread + a ready/running thread:
- interrupt_signal_candidate scans suspended; the process is in ready (RunnableProcess) -> NO
  candidate -> sleeper NOT interrupted.
- Delivery then depends on a running/ready sibling reaching a kernel-call checkpoint AND not masking
  the signal.

Variant 1 (literal CE: ready sibling t3 UNMASKED): delivered when t3 next returns from a kernel call
(t3 unmasked). No permanent harm — consequence MASKED by the ready sibling's checkpoint delivery.
The CE's signalDeliveryFailed over-flags this state (model omits the ready-thread checkpoint path).

Variant 2 (ready sibling MASKS the signal; sole UNMASKED eligible thread is the sleeper — the
mechanism in the finding summary): masked sibling never delivers (& !blocked excludes the signal) AND
the sleeper is never interrupted (process not in suspended) => PERMANENT non-delivery. Real live harm.
Reachable via real API (a per-thread sigprocmask step — the classic "block signal in worker threads,
handle on one dedicated thread" POSIX idiom).

### Reachability
Real interface: create process, create 2nd thread (pthread), install caught handler (sigaction), one
thread sleeps (nanosleep/recv), another stays runnable, cross-process kill() posts the caught signal.
Variant 2 adds a per-thread sigprocmask (real API).

## Step 2 — Developer knowledge
- Introduced by commit 094b4cd3d "[kernel] F: Deliver Signals To Blocked Threads" (P.H. Penna):
  "Replace the (terminate, wake) post-action pair in kill() with a PostAction enum that also
  interrupts a suspended candidate thread, selecting a sleeping thread that does not block the
  signal." Design explicitly scopes the interrupt to a *suspended* candidate.
- Doc comment (mod.rs:1000-1002): "Only a fully-suspended process needs explicit help; a process that
  still has a ready or running thread reaches its own checkpoint without being woken." Developer
  assumption; WRONG when that ready/running thread MASKS the signal (variant 2).
- Developer *assumption*, not a filed report. Not a known duplicate.

## Step 3 — Known-status
- No prior public issue/PR/CVE or dataset entry found reporting this exact mechanism at this site.
- Novelty: NEW. MC-sourced with a real counterexample; reproduced regardless.

## Reproduction vehicle
Kernel feature=test in-kernel harness (boots via uservm — see boot-mc2.log). New module
process/state/mc2_repro.rs constructs REAL process/thread objects via REAL transitions
(RunnableProcess::new -> run -> add_thread -> RunningProcess::sleep), builds the manager's real
suspended: LinkedList<SleepingProcess>, and runs the VERBATIM interrupt_signal_candidate scan
(mod.rs:1010-1014) with a positive control (fully-suspended process) vs the CE case (runnable process
with a sleeping thread). Also evaluates the real delivery predicate for the masked sibling.
