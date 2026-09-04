# Modeling Brief: Nanvix Process Management (`src/kernel/src/pm`)

## 1. System Overview

- **System**: Nanvix microkernel process/thread lifecycle manager — `src/kernel/src/pm` (~12 KLOC non-test Rust).
- **Category**: **B (Concurrent / Lock-Free / Runtime)**. Justification: it is a preemptive/cooperative kernel
  scheduler + lifecycle manager. **Single-core, interrupts disabled in kernel, all atomics `Relaxed`**
  (`mod.rs:43-46`) ⇒ *no* memory-ordering races; the entire concurrency surface is **logical interleaving at
  scheduling points** (timer preemption `tick→giveup→schedule`; voluntary blocking `sleep`/`join`/`Mutex::lock`/
  `Condvar::wait`; cross-process `kill` run by the procd daemon that mutates *other* processes' state).
- **What it implements**: POSIX-like process/thread lifecycle — create/duplicate(fork)/exec/exit/terminate,
  wait/join/detach, zombie retention/harvest, signals (post/mask/deliver/sigsuspend/sigreturn/SA_RESTART),
  mutexes and condition variables.
- **Key architectural choices**: a **two-level state machine** — process level (`running` + `ready`/`suspended`/
  `interrupted`/`zombies` lists) × thread level (per-process running/ready/sleeping/interrupted/zombie subsets),
  where **a Runnable or Interrupted process may still hold sleeping threads**; deferred zombie reaping to avoid
  ContextInformation use-after-free during the outgoing context switch; monotonic never-recycled PID/TID; caps
  `MAX_PROCESSES`/`MAX_THREADS`; signal delivery only at the **kcall-return checkpoint**, where `InterruptReason`
  {Killed→exit, TimedOut→ETIMEDOUT, Signaled→EINTR} drives exit-vs-continue.
- **Concurrency model**: cooperative + timer-preemptive, single CPU, interrupts disabled in kernel — interleaving
  only at explicit block/preempt boundaries.

## 2. Scenarios

### Scenario 1: Incomplete "where a blocked thread lives" search set
**Mechanism**: a thread's sub-state (sleeping) can differ from its process's list membership, but the routines
that must locate a sleeping thread scan only a subset of the five process lists, so they miss threads nested in a
non-matching process state → lost wakeup / undelivered signal.

**Evidence**:
- Code: `try_wakeup` scans `suspended` then `ready`, **never `interrupted`** (`manager/mod.rs:1880-1936`), yet
  `InterruptedProcess` can hold sleepers (`state/interrupted.rs:173-177`; `state/sleeping.rs` `wakeup_alarm` →
  `from_sleeping(state, remaining_sleepers, …)`). Notifier pops the tid then `wakeup_waiter` returns false →
  notification consumed, thread never woken (untimed wait ⇒ stuck forever).
- Code: `interrupt_signal_candidate` scans only `self.suspended` (`manager/mod.rs:1009-1017`); async delivery only
  inspects the running thread (`manager/signal.rs:207-243`) ⇒ a caught signal whose only unmasked candidate is a
  sleeper inside a *Runnable* process is never delivered.
- Historical: `cfeba73ab` (per-thread alarms inside runnable processes) and `6055a7366` (stale condvar waiters)
  confirm this exact "sleeper embedded in a non-suspended process" mechanism is bug-prone.

**Affected code paths**: `try_wakeup`, `try_wakeup_thread`, `do_wakeup`, `interrupt_signal_candidate`,
`Condvar::notify_first/notify_all/notify_thread`, `check_alarm`.

**Suggested modeling approach**:
- Variables: `procState[p]` ∈ {Running,Runnable,Sleeping,Interrupted,Zombie}; `threadSub[t]` ∈ {running,ready,
  sleeping,interrupted,zombie}; `waiters[cond]` seq of tid; `blockedMask[t]`; `pending[p]`.
- Actions: split `Notify`(pop waiter → `WakeupSearch` over the *modeled* list set) from the actual thread wake;
  `AlarmFire` that moves one sleeper of a multi-sleeper process to Interrupted while leaving siblings sleeping;
  `PostCaughtSignal` → `InterruptCandidate` restricted to suspended processes.
- Granularity: keep `Notify` (dequeue) and `Wake` (state move) as separate steps so the "consumed-but-not-woken"
  gap is observable.

**Priority**: High
**Rationale**: three independent deep passes converged here; directly answers "missed wakeups / stale waiters /
signal delivered to the wrong lifecycle state"; clean finite-state model.

### Scenario 2: Terminate/exit does not force-kill already-interrupted threads
**Mechanism**: code-path inconsistency — only `InterruptedProcess::terminate` re-marks already-interrupted
threads `Killed`; the Runnable-terminate and process-wide-exit paths carry them forward with their original
TimedOut/Signaled reason, which resumes user code instead of exiting.

**Evidence**:
- Code: `InterruptedProcess::terminate` sets_killed all interrupted + folds sleepers Killed
  (`state/interrupted.rs:110-125`; helper `interrupt`→Killed at `:235-237`). But `RunnableProcess::terminate`
  (`state/runnable.rs:165-203`, lines 180-193) and `RunningProcess::exit` (`state/running.rs:265-321`, 293-294)
  **carry `interrupted_threads` forward unchanged**.
- Code: `kcall/dispatcher.rs:263-289` — **Killed→`exit()`** but **TimedOut→ETIMEDOUT**, **Signaled→EINTR**, both
  returning to user code. So a terminated-while-Runnable process retains a live thread.
- Historical: `515ecafcf` only added tests for the (correct) Interrupted path; documented intent
  (`state/interrupted.rs:100-104`) is violated on the other two paths.

**Affected code paths**: `RunnableProcess::terminate`, `RunningProcess::exit`, `ProcessManager::terminate`,
`do_exit`, `InterruptedThread::{resume,set_killed}`, `handle_sleep_error`.

**Suggested modeling approach**:
- Variables: `threadReason[t]` ∈ {None,Killed,TimedOut,Signaled}; `procTerminated[p]` flag.
- Actions: model `Terminate(p)` and `ExitProcess(p)` as transforming each thread subset; the current bug = the
  interrupted-subset transform is identity on those two paths. `ResumeInterrupted(t)` returns to user iff
  reason≠Killed.
- Granularity: one action per termination sink so the divergence is explicit; check the safety invariant below.

**Priority**: High
**Rationale**: confirmed bug (traced end-to-end); a thread runs after its process is terminated — a lifecycle
safety violation; not covered by existing tests.

### Scenario 3: `running == None` reentrancy in `do_exit` → kernel panic
**Mechanism**: `do_exit` nulls `self.running` then, before re-inserting the process, calls `cleanup_rendezvous`
whose wakeup path unwraps `self.running`, panicking.

**Evidence**:
- Code: `do_exit` `take_running()` (`manager/mod.rs:2116`) → `cleanup_rendezvous` (`:2130`) →
  `do_wakeup(tid)` (`:2771`) → `try_wakeup_thread` → `get_running()` = `self.running.expect(…)` (`:1854,:2785`).
- Code: `rendezvous::cleanup_process` returns counterpart TIDs of threads in *other* processes blocked on the
  exiting pid (`ipc/rendezvous.rs:651+`). `terminate()` is safe because it never nulls `running`.

**Affected code paths**: `do_exit`, `cleanup_rendezvous`, `do_wakeup`/`try_wakeup_thread`/`get_running`.

**Suggested modeling approach**:
- Variables: `running` ∈ Pid∪{None}; `rendezvousWaiters` ⊆ (pid,tid).
- Actions: `Exit(p)` split into (take-running) → (cleanup-wakeup of counterparts) → (reinsert); assert `running≠
  None` as precondition of any `Wakeup`.
- Granularity: keep take-running and cleanup as separate steps so the None window is reachable.

**Priority**: High
**Rationale**: reachable kernel panic (crash/DoS) on exit-with-blocked-rendezvous-counterpart; a strong,
directly-confirmable invariant violation.

### Scenario 4: Reclaimable slots not reaped before cap rejection
**Mechanism**: the self-healing "reap zombies on admission OOM" fix (#2495) was applied only to `create_thread`/
`duplicate_process`'s *thread* cap; the *process* cap and `execv`'s thread reservation are unaudited sites of the
same mechanism → spurious `OutOfMemory` while reclaimable zombies await burial.

**Evidence**:
- Code: process-cap check precedes any harvest in `create_process`/`duplicate_process`
  (`manager/mod.rs:1138-1147, 1529-1538`); `live_count` drops only at burial.
- Code: `do_execv` uses `self.tm.try_next_tid()` (`:2022`) not `try_next_tid_reaping()` (used at `:417`, `:1557`).
- Historical: `a85226542`/#2495 fixed the thread-cap analogue; `#2558` shows procd's termination-event feed can
  itself be delayed, prolonging the zombie backlog.

**Affected code paths**: `create_process`, `duplicate_process` (process-cap gate), `do_execv`,
`try_next_tid_reaping`, `reap_pending_zombies`, `harvest_zombies`.

**Suggested modeling approach**:
- Variables: `liveProc`, `liveThread`, `zombieProc` count, `zombieThread` count.
- Actions: `Admit*` that check cap-before-reap (bug) vs cap-with-reap; `Harvest` that converts zombie→free slot.
- Granularity: model the "reap-then-retry-once" step explicitly to expose which admission paths lack it.

**Priority**: Medium
**Rationale**: liveness; genuinely open, unaudited generalization of a fixed mechanism (adds information beyond
the closed #2495).

### Scenario 5: Blocking-sync cancellation half-releases ownership
**Mechanism**: interrupting/timing-out a blocking sync kcall doesn't restore its pre-call invariants (mutex
ownership, map-entry accounting), leaving a dropped mutex, a leaked slot, or a waiter that can't resume.

**Evidence**:
- Code: `wait_cond` re-locks with `mutex.lock(None)?`; interruption returns EINTR **without the mutex held**
  (`kcall/wait_cond.rs:126-128`) — POSIX requires cond_wait to return locked; the intervening `put_cond?`
  (`:123`) can also early-return before the reacquire.
- Code: `lock_mutex` timeout/interrupt never calls `put_mutex` (`kcall/lock_mutex.rs:92-94`) → map entry can
  linger at refcount 1 vs the `<=2` destroy threshold (`state/mod.rs:646-649`) → slow leak toward `MUTEX_OPEN_MAX`.
- Code: a thread exiting while holding a mutex moves the guard into its zombie (`thread/running.rs:195-197`);
  unlock+`notify_first` fire only at harvest; `ThreadState::drop` only logs (`thread/state.rs:524-533`).
- Historical: `6055a7366`/`6919e998f` (stale waiters / notify_all robustness) show this area is bug-prone.
- Excluded (verified non-findings): mutex `<=2` / condvar `<=1` thresholds are both correct; no enqueue-time
  lost-wakeup window on single-core (`condvar.rs:257-259`); foreign/double unlock rejected (`manager/mod.rs:2622`).

**Affected code paths**: `wait_cond`, `lock_mutex`, `Mutex::lock`, `Condvar::wait`, `put_mutex`/`put_cond`,
`ThreadState::drop`, thread-exit guard transfer.

**Suggested modeling approach**:
- Variables: `mutexLocked[a]`, `mutexOwner[a]` (ghost from per-thread `held`), `mutexPresent[a]`, `refcount[a]`,
  `held[t]`, `condWaiters[c]`.
- Actions: `CondWait` split into (unlock)→(enqueue+sleep)→(wake)→(relock, may block/interrupt); `LockInterrupted`
  that drops the local ref without `put_mutex`; `ThreadExitHoldingMutex`.
- Granularity: separate unlock and relock steps so "return without mutex held" and "leak" become observable.

**Priority**: Medium-High
**Rationale**: concrete ownership/leak violations; answers "waiter that can never resume / lost mutex ownership /
slot exhaustion."

### Scenario 6: Signal pending/mask/disposition/lifecycle consistency
**Mechanism**: the process-pending bitset interacts incorrectly with the per-thread mask, disposition changes,
and lifecycle transitions → lost, stuck, or wrong-masked signals.

**Evidence**:
- Code: default `Terminate`/`Stop` bypass the mask (`manager/mod.rs:858-895`); pending handler-signal is immortal
  after disposition→`SIG_DFL`/`SIG_IGN` (`signal.rs:247-252`, `manager/mod.rs:603-611`); `execv` zeroes pending
  (`state/signal.rs:490-497`); missing restorer drops async signal + leaks sigsuspend mask (`signal.rs:257-268`);
  no timer-return checkpoint (`kcall/dispatcher.rs:240`, `unsafe.rs:899-909`).
- Historical: whole signal subsystem is new (#2690–#2697, merged 2026-06) ⇒ bug-prone.
- Excluded: same-numbered coalescing, defined lowest-first order, clear-before-redirect, `& !blocked` gating,
  sync-fault targeting are all correct.

**Affected code paths**: `kill`/`PostAction`, `deliver_pending_signals`, `manager/signal.rs`, `sigaction`,
`reset_for_exec`, `tick`.

**Suggested modeling approach**:
- Variables: `pending[p]` bitset, `blocked[t]`, `disposition[p][sig]`, `stopped[p]`, `restorerSet[p]`.
- Actions: `Post`, `Deliver` (only Handler+unmasked, lowest-first, clear bit), `SetDisposition`, `Exec`,
  `MaskChange`. Check the pending/mask invariants below.
- Granularity: keep `Post` and `Deliver` separate; model disposition change between them.

**Priority**: Medium
**Rationale**: multiple concrete deviations in a freshly-added subsystem; several are model-checkable safety
properties (no stuck-pending, mask honored for blockable signals).

### Scenario 7: sigsuspend/sigreturn/SA_RESTART reentrancy corruption
**Mechanism**: single-slot per-thread saved state can't represent nested/multiple in-flight signal contexts.

**Evidence**:
- Code: `saved_blocked` is one `Option<u64>` (`thread/state.rs:100-105`), overwritten/consumed by a nested
  handler/sigsuspend (`manager/mod.rs:733-735`, `signal.rs:607-610`); `KcallRestart` has no signum
  (`thread/state.rs:57-62`), delivery picks the lowest pending caught signal and applies *its* SA_RESTART flag
  (`signal.rs:247-249, 280-283`, `dispatcher.rs:274-287`).
- Historical: #2695 (EINTR/SA_RESTART/sigsuspend) is new.

**Affected code paths**: `install_sigsuspend_mask`/`restore_sigsuspend_mask`, `sigreturn`, `deliver_pending_signals`,
`set_running_thread_restart`.

**Suggested modeling approach**:
- Variables: `savedBlocked[t]` (Option), `restart[t]` (Option, currently signum-less), `pending`, `blocked`.
- Actions: `SigSuspend`, `DeliverHandler`, `SigReturn`, `RestartDecision`; inject a second signal before
  `SigReturn` to expose overwrite / wrong-signal restart.
- Granularity: nest two signal-delivery frames.

**Priority**: Medium
**Rationale**: model-checkable reentrancy safety in new code; small state space.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)
| What | Why | How |
|------|-----|-----|
| Two-level state machine (proc list × thread subset) with sleepers-in-non-suspended processes | Scenario 1,2 root cause | `procState[p]`, `threadSub[t]`; allow Runnable/Interrupted to hold sleeping threads |
| Notify = dequeue-then-wake as two steps | Scenario 1 (consumed-but-not-woken) | split `Notify` and `Wake`; `WakeupSearch` over exactly the lists code scans |
| `InterruptReason` semantics {Killed→exit, TimedOut/Signaled→resume-user} | Scenario 2 | `threadReason[t]`; `ResumeInterrupted` returns-to-user iff ≠Killed |
| Termination sinks as distinct actions | Scenario 2,3 | one action per sink (`RunnableTerminate`, `ProcessExit`, `InterruptedTerminate`); split take-running / cleanup for Scenario 3 |
| Admission cap-before-reap vs reap-then-retry | Scenario 4 | `liveProc/liveThread/zombie*` counts; reap step optional per site |
| Sync ownership + refcounted destruction | Scenario 5 | `mutexLocked/Owner/Present/refcount`, `condWaiters`, `held[t]`; split unlock/relock |
| Signal pending/mask/disposition | Scenario 6,7 | `pending[p]`, `blocked[t]`, `disposition`, `savedBlocked[t]`, `restart[t]` |

### 3.2 Do Not Model (with rationale)
| What | Why |
|------|-----|
| Memory ordering / atomics | Single-core, interrupts disabled, all `Relaxed` — no weak-memory behavior exists to check |
| Physical-frame allocator, page-table internals, COW fault resolution | Out of scope; MM correctness, not PM lifecycle |
| PID/TID never-recycled exhaustion (#1440) | Acknowledged design defect (FIXME); trivial to state, no protocol subtlety; keep as reference |
| Quantum-inheritance fairness (#1695) | Fixed; performance/fairness, re-deriving adds nothing |
| SMP stack guard (#1665) | Out of scope: single-core target; SMP is future work |
| `capctl` self-grant, `duplicate` capability inheritance, MMIO alloc/free | Code-review/security & MM-adjacent; not a tractable protocol state machine |
| Userspace pthread mutex/cond fork divergence (#2612) | Userspace registry design; not kernel PM state |

## 4. Proposed Extensions
| Extension | Variables | Purpose | Scenario |
|-----------|-----------|---------|----------|
| Thread sub-state within process | `threadSub[t]`, per-proc subsets | model sleeper-in-non-suspended-process | 1,2 |
| Split notify/wake | `condWaiters[c]`, `woken[t]` | expose consumed-but-not-woken | 1 |
| Interrupt reason | `threadReason[t]∈{None,Killed,TimedOut,Signaled}` | exit-vs-resume-user decision | 2 |
| Running-slot occupancy | `running∈Pid∪{None}` | reentrant-wakeup panic window | 3 |
| Slot accounting | `liveProc,liveThread,zombieProc,zombieThread` | admission liveness | 4 |
| Sync ownership+refcount | `mutexLocked/Owner/Present/refcount[a]`, `held[t]`, `condWaiters[c]` | cancellation half-release | 5 |
| Signal control | `pending[p]`, `blocked[t]`, `disposition[p][s]`, `stopped[p]`, `savedBlocked[t]`, `restart[t]` | delivery/mask/restart consistency | 6,7 |
| Rendezvous waiters | `rvWaiters⊆(pid,tid)` | Scenario 3 trigger | 3 |

## 5. Proposed Invariants
| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| SingleOwner | Safety | every live process is in exactly one of running/ready/suspended/interrupted/zombies; every thread in exactly one subset | 1,2 |
| NoLostNotify | Safety/Liveness | a consumed condvar/join notification wakes exactly one still-waiting thread, or no waiter existed | 1 |
| SignalReaches | Liveness | a pending, unmasked, caught signal with an eligible thread is eventually delivered | 1,6 |
| TerminatedThreadsDie | Safety | after `terminate(p)`/`exit(p)`, no thread of `p` resumes user execution; all reach Zombie | 2 |
| RunningValidAtWakeup | Safety | `running ≠ None` whenever a wakeup path reads it | 3 |
| AdmissionLiveness | Liveness | if a slot is reclaimable and the non-zombie cap is not exceeded, admission eventually succeeds | 4 |
| CondWaitReturnsLocked | Safety | a `wait_cond` return (incl. EINTR) leaves the caller owning the mutex | 5 |
| SyncSlotConservation | Safety | mutex/cond map entries are freed on last release; no lingering refcount-1 entry after cancellation | 5 |
| MaskHonored | Safety | a blocked (non-KILL/STOP-uncatchable... i.e. blockable) signal never takes effect while masked | 6 |
| NoImmortalPending | Safety/Liveness | a pending signal is eventually delivered or discarded after a disposition change (never stuck) | 6 |
| SavedMaskRestored | Safety | after all nested handlers/sigsuspend complete, the thread mask equals its pre-suspend value | 7 |
| RestartAttribution | Safety | SA_RESTART is applied per the signal that actually interrupted the call | 7 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable
| ID | Description | Expected invariant violation | Scenario |
|----|-------------|------------------------------|----------|
| MC-1 | Notify a condvar/join waiter that is a sleeping thread inside an *interrupted* process | NoLostNotify (consumed, not woken) | 1 |
| MC-2 | Post a caught signal whose only unmasked candidate is a sleeper in a *runnable* process | SignalReaches / SingleOwner | 1 |
| MC-3 | Terminate a Runnable process (or process-wide exit) holding a TimedOut/Signaled interrupted thread | TerminatedThreadsDie (thread resumes user code) | 2 |
| MC-4 | Exit a process while another process's thread is blocked in a push/pull rendezvous on it | RunningValidAtWakeup (panic) | 3 |
| MC-5 | Burst exit+duplicate keeping process/thread slots as unburied zombies; also `execv` under thread-cap | AdmissionLiveness (spurious OOM) | 4 |
| MC-6 | Interrupt a `wait_cond` during mutex re-acquire (or fail cond lookup after unlock) | CondWaitReturnsLocked | 5 |
| MC-7 | Timeout/interrupt a `lock_mutex`; check map-entry conservation | SyncSlotConservation | 5 |
| MC-8 | Deliver a blockable default-Terminate/Stop signal while masked | MaskHonored | 6 |
| MC-9 | Post handler-signal, then change its disposition to SIG_DFL/SIG_IGN before delivery | NoImmortalPending | 6 |
| MC-10 | Nested handler/sigsuspend, then sigreturn; two pending signals with differing SA_RESTART | SavedMaskRestored / RestartAttribution | 7 |

Each MC-N is a **forward-looking question about open/unaudited behavior**, not a reproduction of a closed issue.
(#2495/#1695/#627/#1434 are carried only as § 2 mechanism evidence and § 7 references.)

### 6.2 Test-Verifiable
| ID | Description | Suggested test approach |
|----|-------------|-------------------------|
| TV-1 | `join_thread` loses exit status / cannot retry when `retval` pointer is bad (reap precedes copy) | join with an invalid status pointer; assert status not lost / slot not leaked (`join_thread.rs:70-75`) |
| TV-2 | `execv` clears the process pending-signal set | post+block a signal, exec, assert pending preserved per POSIX (`state/signal.rs:490-497`) |
| TV-3 | Async caught signal dropped when no restorer installed; sigsuspend temp mask leaks | install handler w/o restorer, deliver, assert termination not silent drop (`signal.rs:257-268`) |
| TV-4 | Thread exits holding a mutex → sibling blocks until zombie harvest | lock+exit; assert sibling makes progress promptly (`thread/running.rs:195-197`) |
| TV-5 | CPU-bound thread never receives caught signal (no kcall) | tight loop + kill(handler); assert delivery (or document limitation) (`dispatcher.rs:240`) |
| TV-6 | `post_message`/`recv` mutate-then-count / consume-then-copy loses a message on error | overflow / bad buffer; assert accounting + no loss (`manager/mod.rs:3787`, `ipc/recv.rs:56`) |

### 6.3 Code-Review-Only
| ID | Description | Suggested action |
|----|-------------|------------------|
| CR-1 | `capctl` has no privilege check (`kcall/capctl.rs:32` FIXME) — any process self-grants any capability, bypassing #1434 | add `ProcessManagement` (or dedicated) capability gate, mirroring `terminate.rs:49-56`; file an issue |
| CR-2 | `duplicate` child gets `Capabilities::default()` (no inheritance) unlike inherited signal state | confirm intended; document the fork capability policy |
| CR-3 | `CondvarInner::drop` **panics** on a non-empty waiter queue vs `ThreadState::drop` log-only | make destruction non-panicking or assert-unreachable with justification (`sync/condvar.rs:286-291`) |
| CR-4 | Release-only `mmio_alloc` skips two-pass dry-run/rollback → partial map not recorded; `mmio_free` drops ownership without revoking PTEs | unify release/debug paths; revoke mappings on free (`manager/mod.rs:3650-3694`) |
| CR-5 | `on_thread_reaped` uses a runtime `assert!` guard against `live_count` underflow — accounting-bug hardening | keep; ensure all reap paths (harvest_zombies, reap_deferred, reap_deferred_zombie_threads) are balanced |

## 7. Reference Pointers
- **Full analysis report**: `.specula-output/analysis-report.md` (this repo's output dir).
- **Issue-mining detail**: `~/.copilot/session-state/002c9ae7-.../files/issue-mining-report.md`.
- **Key source files (line anchors)**:
  - `process/manager/mod.rs` — kill/terminate/do_exit/do_exit_thread/do_sleep/schedule/try_wakeup/duplicate/
    create/do_execv/harvest_zombies/reap_pending_zombies (`:810,:1485,:1658,:1704,:1821,:1880,:2103,:2268,:3284,:3430`)
  - `process/manager/unsafe.rs` — exit/exec/exit_thread/reap_deferred/harvest_zombie_thread/join/detach/sleep/
    tick/giveup/switch (`:286,:351,:533,:610,:654,:742,:845,:937,:1258`)
  - `process/state/{running,runnable,sleeping,interrupted,zombie}.rs` — thread-subset transforms
  - `thread/{state,interrupted}.rs` — `ThreadState`, `InterruptReason`, `set_killed/resume`
  - `sync/{mutex,condvar}.rs` — lock/unlock, wait/notify, refcount destruction
  - `kcall/dispatcher.rs:263-289` — `InterruptReason` → exit/ETIMEDOUT/EINTR+restart
- **Open issues (reference, not targets)**: #1440 (ID exhaustion), #2612 (mutex/cond fork divergence), #1665
  (SMP stack guard). **Closed mechanism evidence**: #2495, #1695, #627, #1434, #2558, #2690–#2697.
- **Category carry-forward**: **Category B** — model per-thread PCs + shared `ProcessManager`; split actions at
  block/preempt boundaries; **no weak-memory modeling**; use concurrent-style trace validation.
