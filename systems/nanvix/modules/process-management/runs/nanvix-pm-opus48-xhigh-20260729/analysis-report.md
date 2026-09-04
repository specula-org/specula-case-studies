# Nanvix Process-Management (`src/kernel/src/pm`) — Code Analysis Report

**Target**: nanvix/nanvix — kernel process/thread lifecycle management under `src/kernel/src/pm`
**Repository (ground truth)**: local checkout at `Nanvix 0.21.51`, commit `6f1e9a0d3`
**Methodology**: Specula `code-analysis` skill (4 phases). This document is the detailed audit trail; the
concise handoff is `modeling-brief.md`.

---

## Phase 0 — System Category

**Category B (Concurrent / Lock-Free / Runtime).** Justification: the PM subsystem is a preemptive/cooperative
kernel scheduler and lifecycle manager. It is **single-core with interrupts disabled in kernel code**, and every
atomic uses `Ordering::Relaxed` (`src/kernel/src/pm/mod.rs:43-46`). Therefore there are **no memory-ordering
races**; the entire concurrency surface is **logical interleaving at scheduling points**:

- **Preemption**: timer IRQ → `tick()` → `giveup()` → `schedule()` (`unsafe.rs:899-959`).
- **Voluntary blocking**: `sleep`, `join_thread`, `Mutex::lock`, `Condvar::wait` context-switch to another thread.
- **Cross-process signals**: `kill()` is executed by a userspace process-manager daemon that is the *running*
  process during the kcall; it mutates *other* processes' scheduling state.

This is the correct lens for TLA+: model per-thread program counters and a shared `ProcessManager` state; split
actions at each blocking/preemption boundary; there is no need to model weak memory.

---

## Phase 1 — Reconnaissance (structural map)

### Scale
~17.7 KLOC total under `pm/` (~12 KLOC non-test). Core files: `process/manager/mod.rs` (3887),
`process/manager/unsafe.rs` (1346), `process/state/running.rs` (820), `process/state/mod.rs` (732),
`process/manager/signal.rs` (656), `thread/state.rs` (534), `process/state/signal.rs` (509), plus
`process/state/{runnable,sleeping,interrupted,zombie}.rs`, `thread/{mod,running,ready,sleeping,interrupted,zombie}.rs`,
`sync/{mutex,condvar,spinlock,fence}.rs`, and `kcall/*`.

### Two-level state machine
**Process level** — `ProcessManager` owns exactly one container per process (`manager/mod.rs:199-255`):
`running: Option<RunningProcess>`, and `LinkedList`s `ready` (Runnable), `suspended` (Sleeping),
`interrupted` (Interrupted), `zombies` (Zombie).

**Thread level** — within a process, threads are partitioned into subsets. `RunningProcess`
(`state/running.rs:55-68`) has exactly one `running` thread plus `Option<NonEmptyVecDeque<_>>` for
ready / interrupted / sleeping / zombie threads. `RunnableProcess`, `SleepingProcess`, `InterruptedProcess`,
`ZombieProcess` are the four non-running shapes; **crucially a Runnable or Interrupted process may still
contain sleeping threads** — this drives Scenarios 1 & 2.

### Accounting / caps
- `ThreadManager.live_count` (cap `MAX_THREADS`) via `try_next_tid` / `commit_next_tid` / `on_thread_reaped`
  (`thread/mod.rs:227-282`).
- `ProcessManager.live_count` (cap `MAX_PROCESSES`), decremented only when a zombie is buried.
- IDs are **never recycled** (FIXME #1440, `thread/mod.rs:224`, `manager/mod.rs:2655`).

### Deferred cleanup
`deferred_reap` (detached-thread zombies whose `ContextInformation` is still the live "from" side of the
in-progress context switch), `deferred_exec_vmem` (execv'd-away address spaces), `pending_creations`,
`pending_terminations`. `reap_deferred()` runs at the top of every PM entry point (`unsafe.rs:610-633`).

### Legal transitions (verified)
Runnable→Running (`run`), Running→Runnable (`schedule`/`sleep` when ready sibling exists),
Running→Sleeping (`sleep`, no ready sibling), Sleeping→Runnable (`wakeup`), Sleeping→Interrupted
(alarm/signal/kill), Interrupted→Runnable (`resume`), and →Zombie via `exit`/`terminate`. `InterruptReason`
{Killed, TimedOut, Signaled} recorded on `resume`; **consumed** at the kcall-return checkpoint
(`kcall/dispatcher.rs:263-289`): **Killed → `exit()`**, **TimedOut → return ETIMEDOUT to user**,
**Signaled → EINTR (+SA_RESTART record)**. This asymmetry is the crux of Scenario 2.

---

## Phase 2 — Bug Archaeology

### Git history mining
- 227 commits touch `src/kernel/src/pm`; 177 match bug-keyword grep (fix/bug/race/leak/panic/deadlock/zombie/
  signal/wakeup/...). ~15 lifecycle-critical `B:`/`E:` commits read in full via `git show`.
- **Bug-prone mechanisms revealed by fixes** (used as evidence, NOT as modeling targets — per skill §1.4):

| Commit | Mechanism | Relevance |
|---|---|---|
| `4f6d6af26` B: Fix zombie loss on exit | double `.take()` of zombie set dropped zombies → unjoinable | Scenario 2 area (state-subset preservation) |
| `92bad91f2` B: Defer detached zombie reap | ContextInformation UAF: zombie freed while outgoing switch still writes it | deferred_reap mechanism |
| `4113651ed` B: Reap deferred thread zombies on demand | deferred zombies hold thread slots | Scenario 4 |
| `6055a7366` E: Skip stale condvar waiters | timed wait + alarm removes sleeper before notify pops tid → lost wakeup | Scenario 1 / 5 |
| `cfeba73ab` E: Service per-thread timer alarms | sleeping thread parked inside a *runnable* process; alarm unserviced | Scenario 1 (confirms Runnable holds sleepers) |
| `a85226542` E: Reap zombies on demand (#2495) | thread cap held by unharvested zombies → spurious OOM | Scenario 4 (fixed for thread cap only) |
| `61c309003` B: Fix intra-process thread starvation (#1695) | shared REMAINING_QUANTUM inheritance | scheduler quantum (reference) |
| `0cfd3537a` B: Require capability on terminate (#1434) | any process could terminate any other | capctl analogue (Code-review CR-1) |
| `515ecafcf` E: interrupted-process termination tests | terminating an *already-interrupted* process re-marks threads Killed | Scenario 2 (only the InterruptedProcess path is tested/correct) |
| `4bea8929f` B: Check overflow when bumping PID/TID (#627) | unchecked ID increment | reference |

### GitHub issue/PR verification (via `gh`, authenticated)
Coverage: **20 relevant issues/PRs found, 20 deeply read** (full threads), 9 confirmed bugs/defects, 2 excluded,
**5 still open** (4 issues + 1 unfiled code FIXME). Full detail in
`~/.copilot/session-state/.../files/issue-mining-report.md`.

| # | Title | State | Verdict | Maps to |
|---|---|---|---|---|
| #2495 | On-demand zombie reap on thread-admission fail | CLOSED | Confirmed (fixed, thread cap only) | Scenario 4 evidence |
| **#1440** | Mitigate PID/TID exhaustion (never recycled) | **OPEN** | Confirmed design defect | Reference / CR |
| #627 | Overflow check on ID bump | CLOSED | Confirmed (fixed) | Reference |
| #1434 | Permission check on `terminate()` | CLOSED | Confirmed (fixed) | CR-1 (capctl analogue) |
| **capctl FIXME** | No priv check in `capctl()` | **OPEN (unfiled)** | Confirmed escalation | CR-1 |
| #1695 | Quantum inheritance starvation | CLOSED | Confirmed (fixed) | Reference |
| #2690–#2697 | POSIX signal subsystem (7 phases) | CLOSED | Feature (new → bug-prone) | Scenarios 6,7 |
| **#2612** | Mutex/cond re-init across fork (two sources of truth) | **OPEN** | Confirmed design defect | Reference |
| **#1665** | `EXCP_STACK_GUARD` per-core for SMP | **OPEN** | Design defect (SMP) | Out of scope (single-core) |
| #2558 | Event delivery starvation (procd feed) | CLOSED | Confirmed (fixed) | Reference (Scenario 4 liveness) |

Excluded as non-PM/false-positive: #1251 (AMD perf/env), #2908 (IPC bulk-pull timeout, not PM core).

---

## Phase 3 — Deep Analysis (5 parallel subagents + independent verification)

Five `general-purpose` subagents each read a coherent file group in full and applied the concurrent-analysis
patterns; the main context then cross-referenced and I independently verified the top scenarios against source.
Findings below are grouped by mechanism (Scenarios). Every finding cites `file:line` and was re-read.

### Scenario 1 — Incomplete "where a blocked thread lives" search set  (HIGH)
**Root cause**: a thread's *sub-state* (sleeping) can differ from its *process-level* list. Operations that must
locate a sleeping thread scan only a subset of the five process lists.

- **1a — lost condvar/join wakeup**: `try_wakeup(tid)` scans `suspended` then `ready`, **never `interrupted`**
  (`manager/mod.rs:1880-1936`). But an `InterruptedProcess` can hold sleeping threads
  (`state/sleeping.rs` `wakeup_alarm` → `InterruptedProcess::from_sleeping(state, remaining_sleepers, [interrupted], ...)`;
  `state/interrupted.rs:173-177` `find_thread` returns `ThreadRef::Sleeping`). Trigger: process P suspended with
  sleepers T1 (untimed cond-wait) and T2 (timed); T2's alarm fires → P moves to the `interrupted` list, T1 still
  sleeping inside. A notifier calls `Condvar::notify_first` → pops T1's tid → `wakeup_waiter(T1)` →
  `try_wakeup_thread` → not found in running/suspended/ready → returns `false`. The notification is **consumed
  (tid popped) but T1 is never woken** → if T1's wait is untimed, it is stuck forever.
- **1b — undelivered caught signal**: `interrupt_signal_candidate(pid, signum)` scans only `self.suspended`
  (`manager/mod.rs:1009-1017`). A caught signal posted to a Runnable process whose only *unmasked* candidate is
  a *sleeping* thread (a masked sibling is the ready thread) is left pending and never interrupts the sleeper.
  Async delivery only ever inspects the currently-running thread (`manager/signal.rs:207-243`).

Three subagents independently converged on this mechanism. **Model-checkable** (safety+liveness).

### Scenario 2 — Terminate/exit doesn't force-kill already-interrupted threads  (HIGH, CONFIRMED BUG)
**Root cause**: code-path inconsistency across the three termination sinks.
- `InterruptedProcess::terminate()` **correctly** re-marks: `for t in interrupted_threads { t.set_killed() }`
  then folds sleepers as Killed (`state/interrupted.rs:110-125`); the `interrupt` helper assigns
  `InterruptReason::Killed` (`state/interrupted.rs:235-237`).
- `RunnableProcess::terminate()` (`state/runnable.rs:165-203`): ready→zombie, sleeping→interrupted(Killed), but
  `self.interrupted_threads.take()` is **carried forward unchanged** (lines 180-193) — no `set_killed`.
- `RunningProcess::exit()` (process-wide) (`state/running.rs:265-321`): same omission at lines 293-294.

Because `kcall/dispatcher.rs:263-289` maps **Killed→`exit()`** but **TimedOut→ETIMEDOUT** and **Signaled→EINTR**
(both *return to user code*), a thread that had already been interrupted with TimedOut/Signaled, when its process
is terminated-while-Runnable or exits process-wide, **resumes user execution after its process was terminated**.
The documented intent at `state/interrupted.rs:100-104` ("Every interrupted thread has its reason overridden to
Killed") is honored only on the Interrupted path (the one `515ecafcf` added tests for). Trigger: process P with
ready T1 and timed-out-interrupted T2 sits in the `ready` list; another process (with `ProcessManagement`) calls
`terminate(P)`; T2 survives as TimedOut and continues running. **Model-checkable** (safety: "after terminate(P)
no thread of P resumes user code / every thread reaches Zombie").

### Scenario 3 — `running == None` reentrancy in `do_exit` → kernel panic  (HIGH, CONFIRMED)
`do_exit` (`manager/mod.rs:2103-2162`) executes `take_running()` (→ `self.running = None`, line 2116) and *then*
`cleanup_rendezvous(pid)` (line 2130) *before* re-inserting the process. `cleanup_rendezvous`
(`manager/mod.rs:2766-2778`) calls `do_wakeup(tid)` for each orphaned rendezvous counterpart. `do_wakeup` →
`try_wakeup_thread` → **`self.get_running()`** (`manager/mod.rs:1854`) → `self.running.as_ref().expect("the kernel
should be running")` → **panic** because `running` is `None`. `rendezvous::cleanup_process`
(`ipc/rendezvous.rs:651-...`) returns counterpart TIDs (in *other* processes) whenever a thread is blocked in a
push/pull with `dst_pid`/`src_pid == exiting pid`. So: **a process that voluntarily `exit()`s while another
process's thread is blocked in a rendezvous targeting it panics the kernel.** `terminate()` avoids this because
it never nulls `running` (the target is not the running process). Directly confirmable + model-checkable
(invariant: `running` valid at every wakeup).

### Scenario 4 — Reclaimable slots not reaped before cap rejection  (MEDIUM)
`#2495` made *thread* admission self-heal, but only inside `create_thread`/`duplicate_process`. Two unaudited
sites of the same mechanism remain:
- **4a — process cap**: `create_process`/`duplicate_process` reject on `live_count >= MAX_PROCESSES`
  (`manager/mod.rs:1138-1147`, `1529-1538`) **before** any zombie harvest; `live_count` decrements only when a
  zombie is buried. A burst of exit-then-duplicate keeps process slots occupied by unburied zombies → spurious
  `OutOfMemory`.
- **4b — execv**: `do_execv` reserves a TID with `self.tm.try_next_tid()` (`manager/mod.rs:2022`) not the
  self-healing `try_next_tid_reaping()` used by the other two paths → spurious thread-cap `OutOfMemory`.
Model-checkable **liveness**; genuinely open (generalization to unaudited sites, not a re-derivation of #2495).

### Scenario 5 — Blocking-sync cancellation half-releases ownership  (MEDIUM-HIGH)
- **5a — cond wait returns without the mutex held**: `wait_cond` re-acquires the mutex after the wait with a
  blocking `mutex.lock(None)?` (`kcall/wait_cond.rs:126-128`); if that lock is itself interrupted, the kcall
  returns EINTR **without a guard** — violating the POSIX rule that `pthread_cond_wait` returns with the mutex
  locked. A secondary gap: the intervening `put_cond(cond_addr)?` (`kcall/wait_cond.rs:123`) can early-return on
  error **before** the reacquire, also leaving the caller without the mutex. (Note: a `get_cond` *lookup* failure
  does still flow through to the reacquire at `:126-128`, so that path re-locks; the interruptible reacquire and
  the `put_cond?` early-return are the real gaps.)
- **5b — mutex map-entry leak on failed lock**: `lock_mutex` on timeout/interrupt returns without ever calling
  `put_mutex` (`kcall/lock_mutex.rs:92-94`); with the `<=2` destroy threshold, a lingering entry can remain at
  refcount 1 → slow leak toward `MUTEX_OPEN_MAX`.
- **5c — mutex held across thread exit**: guards live in `ThreadState.locked_mutexes` (`thread/state.rs:82`),
  moved intact into `ZombieThread` on exit (`thread/running.rs:195-197`); the guard (and thus the unlock +
  `notify_first`) only fires when the zombie is dropped at harvest. `ThreadState::drop` merely **logs**
  (`thread/state.rs:524-533`). A sibling blocked on that mutex waits until harvest.
- **5d — SA_RESTART replay of wait_cond** re-runs a call whose precondition (owning the mutex) was already
  consumed by the unlock at the top → immediate failure.
Verified **non-findings** (excluded): the `<=2` (mutex) vs `<=1` (condvar) destroy thresholds are both correct
(a blocked waiter holds a local `Mutex`/`Condvar` clone on its kernel stack, keeping refcount above threshold);
there is **no** user-condvar lost-wakeup window at enqueue time (single-core, enqueue precedes the context
switch, `sync/condvar.rs:257-259`); foreign/double unlock is rejected (`manager/mod.rs:2622-2632`).
Note: `CondvarInner::drop` **panics** on a non-empty queue (`sync/condvar.rs:286-291`) — a robustness asymmetry
vs `ThreadState::drop`'s log-only; not shown reachable given the refcount guard, but worth a code-review note.

### Scenario 6 — Signal pending/mask/disposition/lifecycle consistency  (MEDIUM)
- **6a** default `Terminate`/`Stop` bypass the per-thread mask: a blocked-but-default `SIGTERM`/`SIGTSTP` still
  acts immediately (`manager/mod.rs:858-871, 892-895`) instead of staying pending until unblocked.
- **6b** a pending handler-signal becomes **immortal** if the disposition is then changed to `SIG_DFL`/`SIG_IGN`:
  async delivery only acts on `Handler` dispositions and leaves other pending bits set (`manager/signal.rs:247-252`);
  `sigaction` never re-evaluates the pending set (`manager/mod.rs:603-611`).
- **6c** `execv`'s `reset_for_exec()` zeroes the process pending set (`state/signal.rs:490-497`,
  `state/running.rs:186-189`) — POSIX preserves pending signals across exec.
- **6d** async delivery with **no restorer** clears pending and drops the signal (`manager/signal.rs:257-268`);
  from `sigsuspend` this also leaks the temporary mask (no `sigreturn` runs).
- **6e** no timer-return signal checkpoint (delivery only at kcall return): a CPU-bound thread that makes no
  kcalls never receives a caught signal (`kcall/dispatcher.rs:240`, `clock.rs`/`tick()` `unsafe.rs:899-909`).
Excluded non-findings: same-numbered signals intentionally coalesce (one bit); delivery order is defined (lowest
number); pending bit cleared before handler redirect; blocked running thread not delivered (`& !blocked`); sync
faults tied to the faulting thread; frame-copy failure terminates and clears pending only after frame success.

### Scenario 7 — sigsuspend/sigreturn/SA_RESTART reentrancy corruption  (MEDIUM)
- **7a** `saved_blocked` is a single `Option<u64>` (`thread/state.rs:100-105`); a nested handler or nested
  `sigsuspend` overwrites/consumes the outer saved mask (`manager/mod.rs:733-735`, `signal.rs:607-610`) → wrong
  final mask after `sigreturn`.
- **7b** `KcallRestart{number,args}` has **no signum** (`thread/state.rs:57-62`); `InterruptReason::Signaled`
  carries none (`thread/interrupted.rs:23-30`); delivery picks the lowest pending caught signal
  (`signal.rs:247-249`) and applies `SA_RESTART` from *that* signal's flags — so with two pending signals the
  restart decision can be attributed to the wrong signal (`dispatcher.rs:274-287`, `signal.rs:280-283`).
Model-checkable.

### Scenario 8 — Side-effect-before-validation in kcall return paths  (LOW-MEDIUM)
An irreversible side effect is committed before the fallible copy/count step, so a late failure loses data or
mis-accounts:
- **8a** `join_thread` harvests the zombie and decrements the thread `live_count` **before** `copy_to_user` of
  the status (`kcall/join_thread.rs:70-75`, `unsafe.rs:756-759`): a bad `retval` pointer loses the exit status
  and the join is unretryable (thread already reaped).
- **8b** `post_message` enqueues the message **then** `note_message_posted()` (`manager/mod.rs:3787-3796`); a
  counter-overflow error returns after the message is already buffered.
- **8c** `try_recv` removes the message and decrements the count **before** `copy_to_user` in `recv`
  (`ipc/recv.rs:56-60`, `unsafe.rs:1087-1090`): a bad receive buffer loses the message.
(8b/8c are IPC-adjacent; included because they share the mechanism and touch PM accounting.)

### Code-review / security (not model-checkable)
- **CR-1 (HIGH) — `capctl` unprivileged self-grant**: `kcall/capctl.rs:32` has only `//FIXME: check if process
  has enough privileges…`; `capctl` then sets the capability bit unconditionally (`manager/mod.rs:2345-2362`).
  Any process can grant itself `ProcessManagement`/`MemoryManagement`/`IoManagement`, defeating the whole
  capability model and bypassing the #1434 `terminate` hardening (self-grant then `terminate`). Unfiled.
- **CR-2 — `duplicate` does not inherit capabilities**: the child's `ProcessState` uses `Capabilities::default()`
  (`state/mod.rs:246-251`), unlike the inherited signal state. Likely intentional (security default) but
  undocumented; flag for review.
- **CR-3 — MMIO** (MM-adjacent, borderline scope): under the release `nightly-performance-optimizations` feature
  `mmio_alloc` maps page-by-page without the debug two-pass dry-run/rollback (`manager/mod.rs:3650-3670`) → partial
  mapping not recorded in process state on failure; `mmio_free` drops ownership without revoking PTEs
  (`manager/mod.rs:3689-3694`). Stale user-accessible MMIO / `has_special_resources()` inconsistency.

---

## Phase 4 — see `modeling-brief.md`

The scenarios above are prioritized and translated into proposed TLA+ extensions, invariants, and a
verification-method classification in the modeling brief. Reference/closed bugs (#1440, #2612, #1665, #2495,
#1695, #627, #1434) are carried as **evidence of bug-prone mechanisms** and reference pointers only, per the
skill's "closed bugs are reference, not target" rule — they are **not** listed as model-checking targets.

### Verification discipline notes
- Scenarios 2 and 3 were re-read and traced end-to-end by the main agent (not only the subagents): Scenario 2 via
  `interrupt` helper + `dispatcher.rs` reason semantics; Scenario 3 via `cleanup_process` return value + the
  `get_running()` unwrap.
- Every subagent was instructed to exclude false positives with reasons; excluded items are recorded inline above
  (mutex/condvar refcount thresholds, enqueue-before-sleep window, foreign-unlock rejection, signal coalescing,
  delivery ordering, sync-fault targeting).
