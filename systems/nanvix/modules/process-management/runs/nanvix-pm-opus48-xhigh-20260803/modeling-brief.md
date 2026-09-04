# Modeling Brief — Nanvix Process Management

## 1. System Overview

- **System:** nanvix/nanvix microkernel, process/thread lifecycle management under
  `src/kernel/src/pm`. Rust `#![no_std]`, x86 32-bit, ring 0. ~14.9K non-test LOC; 227 commits.
- **Category: B (Concurrent / Runtime).** Single-core kernel scheduler with explicit
  thread/process state machines, run queues, signals, mutexes, condition variables — not a
  message-passing protocol.
- **Concurrency model:** kernel runs **interrupts-disabled**, all atomics `Ordering::Relaxed`
  (`pm/mod.rs:46`), so memory ordering is out of scope. Real concurrency is **logical
  control-flow interleaving** at (1) timer preemption (user-mode only → `tick→giveup→schedule→
  switch`) and (2) any kcall that sleeps/blocks (sleep, join, mutex/cond wait) yielding via a
  context switch and re-entering later.
- **Key architectural choices vs a textbook scheduler:** (a) a **nested** state machine — a
  process's PM-level state (Running/Runnable/Sleeping/Interrupted/Zombie) is *derived* from its
  threads' sub-states by precedence; (b) **IDs are never recycled** (#1440); (c) two-phase
  ID reservation (`try_next_*` then commit) to avoid leaks on failure; (d) **deferred reaping** of
  detached zombie threads via a global `deferred_reap` vec to keep an outgoing `ContextInformation`
  alive across `switch()` (#2345); (e) self-termination and self-stop are *deferred* to the next
  scheduling point rather than applied inline.

## 2. Scenarios

### Scenario 1: Location & State-Machine Integrity

**Mechanism:** Every process/thread must occupy **exactly one** queue/state; transitions must move
the same `Box` totally; nothing runs after it becomes a zombie or is stopped.

**Evidence:**
- Historical: preserve-order-in-queues (`8b454e36e`), remove-from-sleeping / race-on-PM,
  switch-same-process (`84ba4fc4c`).
- Code: process containers `manager/mod.rs:199-255`; nested precedence in
  `process/state/{running,runnable,sleeping,interrupted,zombie}.rs`; self-stop deferred
  `manager/mod.rs:951-964` + skipped-when-scheduled `2674-2697`; scheduler picks only ready
  non-stopped `1671-1692`, `runnable.rs:141-149`.

**Affected paths:** `schedule`, `do_sleep`, `do_wakeup/try_wakeup`, `check_alarm`, `do_exit`,
`do_exit_thread`, `terminate`, `stop_process`/`continue_process`, `take_earliest_ready`.

**Modeling:** Variables — per-process `pstate`, per-thread `tstate`, `stopped`, the
sublists→pstate precedence map. Model self-stop and self-terminate as *two-step* (mark, then
deschedule at next schedule point) to expose the one-quantum window and intermediate states.

**Priority:** High — spec backbone; the exactly-one-location invariant gates all others.

### Scenario 2: Zombie Reaping & ID/Slot Accounting

**Mechanism:** Each zombie thread/process must be reaped **exactly once** by **exactly one**
reaper; `live_count` must decrement once per burial; no slot leaked, double-freed, or left
unreapable. Two reaping code paths (`harvest_zombie_thread`, `reap_deferred_zombie_threads`) are
supposed to be equivalent.

**Evidence:**
- Historical: #1635 double-take zombie loss (`4f6d6af26`); #2345 detached-zombie UAF →
  `deferred_reap` (`92bad91f2`); #2495/#2506 reap-on-admission; #1440 IDs never recycled (OPEN).
- Code: divergent missing-process handling — early `return` at `unsafe.rs:668` (skips
  `on_thread_reaped` at `708`) vs fall-through at `manager/mod.rs:3375-3388`; deferred zombie
  creation `running.rs:367-382`, storage `mod.rs:2225-2236`; idle harvest ordering
  `kcall/handler.rs:79-82,155-163`; join reap-claim absence `running.rs:573-620`; execv TID
  reserve/commit `mod.rs:2022-2076`.

**Affected paths:** `harvest_zombie_thread`, `reap_deferred`/`reap_deferred_zombie_threads`,
`harvest_zombies`, `pop_zombie_process`, `try_join_thread`, `do_detach_thread`, `do_execv`,
`try_next_tid`/`commit_next_tid`/`on_thread_reaped`, `try_next_tid_reaping`.

**Modeling:** Variables — `thread_live_count`, `proc_live_count`, `deferred_reap` set, per-zombie
`reaped_by` tag, monotonic `next_tid`/`next_pid`. Model **both** reaping paths as *distinct*
actions (so the divergence is observable), the detach/join/exit/terminate interleavings on a
shared target, and idle-harvest vs entry-point-reap ordering. Fine granularity — the leak is an
ordering effect between burial and deferred drain.

**Priority:** High — direct slot-exhaustion (MC1), lost join status (MC2), spurious exec failure
(MC9).

### Scenario 3: Mutex/Condvar Ownership & Termination Liveness

**Mechanism:** A mutex is held via a `MutexGuard` stored in the owner **thread's** `ThreadState`;
the lock releases only when that guard is **dropped**, which happens at zombie *harvest*, not at
exit. Thread termination performs no proactive unlock. So a dying owner keeps the lock, and any
waiter (including the `wait_cond` reacquire) can block until harvest — or forever if never joined.

**Evidence:**
- Historical: skip-stale-condvar-waiters (`6055a7366`), `notify_first` count (`387a1a6ae`),
  drop-join-condvar-on-exit (#585), fork sync divergence (#2612, OPEN).
- Code: guard release only on drop `mutex.rs:200-206`; ownership only in
  `thread/state.rs:82`; `ThreadState::drop` merely logs `thread/state.rs:524-532`;
  `wait_cond` always reacquires `kcall/wait_cond.rs:125-130`; error-path skips reacquire
  `wait_cond.rs:104-123`; refcount-threshold destroy `state/mod.rs:638-713`; condvar drop-panic
  `condvar.rs:286`.

**Affected paths:** `Mutex::lock`, `MutexGuard::drop`/`unlock_unchecked`, `Condvar::{wait,
notify_first,notify_all}`, `wait_cond`, `do_exit_thread`/`terminate`, `harvest_zombie_thread`,
`get/put_mutex`, `get/put_cond`.

**Modeling:** Variables — mutex `locked`+`owner_tid`, mutex/cond wait queues, per-thread
`held_mutexes`, Arc refcounts, process mutex/cond map slot counts. Actions — `exit`/`kill` a
mutex owner *without* releasing (release only at harvest), a sibling `lock(None)`, a killed
cond-waiter reaching the reacquire. Model harvest as a distinct, possibly-never action
(join-driven) so the block-until-harvest liveness gap is reachable.

**Priority:** High — indefinite blocking / deadlock on termination (MC3, MC10) plus a
`MUTEX_OPEN_MAX` slot leak.

### Scenario 4: Signal Delivery, Masking & sigsuspend/sigreturn

**Mechanism:** Signals have two pending sources (per-process `SignalControl.pending` and
per-thread `pending`); async delivery selects the **lowest-numbered** deliverable signal
(`trailing_zeros`, signum-priority, not FIFO); masking, disposition changes, sigsuspend/sigreturn,
and zombie targets each interact with lifecycle state.

**Evidence:**
- Historical: async signal delivery (#2694), KcallRestart/SA_RESTART/sigsuspend (#2695) — OPEN.
- Code: default-action ignores mask `manager/mod.rs:858-897`; wakeup scans only suspended
  `manager/mod.rs:1000-1014`; `sigaction` ignores pending `603-611`; single `saved_blocked` +
  sigreturn precedence `manager/mod.rs:733-735` / `state/signal.rs:600-610`; async selection
  `state/signal.rs:240-268`; zombie in lookup `manager/mod.rs:2824-2852`.

**Affected paths:** `kill`/signal-post, `interrupt_signal_candidate`, `sigprocmask`, `sigsuspend`,
`sigreturn`, `sigaction`, async delivery at kcall return (`dispatcher.rs:240-247`), sync exception
delivery.

**Modeling:** Variables — `proc_pending`, per-thread `thread_pending`+`blocked`+`saved_blocked`,
per-process `disposition[sig]`, `restart`, `stopped`. Actions — post (caught vs default),
mask/unmask, async-deliver (signum-priority select), sigsuspend, sigreturn, sigaction,
deliver-to-zombie. Model per-thread vs per-process pending separately and nested delivery (to
expose the single-`saved_blocked` bug).

**Priority:** High — 5 distinct correctness findings (MC4–MC8), all matching the task's signal
questions.

### Scenario 5: Creation / Fork / Exec / Address-Space Rollback

**Mechanism:** Multi-step admission (`create_thread`, `create_process`, `duplicate_process`,
`execv`, `mmap`) reserves IDs/resources, does fallible work, then commits. Rollback must restore
*every* affected resource and accounting slot; two-phase reserve/commit is the safety property.

**Evidence:**
- Code: reserve-without-mutate then commit `mod.rs:445-466, 1202-1233, 1621-1638, 2064-2076`;
  parent CoW not restored on fork failure `mm/virt/manager.rs:390-399,443-453`; best-effort mmap
  rollback `mod.rs:3548-3599`; exec uses non-healing `try_next_tid` `mod.rs:2022-2023` vs
  `try_next_tid_reaping` `3410-3425`.

**Affected paths:** `create_thread`, `create_process`, `duplicate_process`, `do_execv`,
`do_mmap`/`rollback`, `try_next_{tid,pid}`, `commit_next_*`.

**Modeling:** Variables — reservation vs commit flags per ID, PTE CoW flag (only if modeling
memory), per-batch mmap state. Inject failure at each fallible step and assert full rollback of
IDs + `live_count`. Coarse for accounting (reserve/commit); the CoW/mmap rollback gaps are better
as targeted tests (§6.2).

**Priority:** Medium — ID accounting is verified clean; residual gaps (parent CoW, mmap
best-effort) are performance/test concerns, except the exec admission interaction (MC9, Scenario
2).

## 3. Modeling Recommendations

### 3.1 Model (with rationale)
- **Nested thread↔process state machine + exactly-one-location** (Scenario 1) — backbone; every
  other invariant references it. Model as derived pstate with the precedence rule.
- **Both reaping paths + `deferred_reap` ordering** (Scenario 2) — the MC1 leak is only visible if
  `harvest_zombie_thread` and `reap_deferred_zombie_threads` are modeled as *distinct* actions
  and process burial can interleave before the deferred drain.
- **Mutex ownership tied to thread lifetime, released at harvest** (Scenario 3) — the block-until-
  harvest liveness gap (MC3/MC10) requires modeling harvest as join-driven and possibly never.
- **Two pending sources + signum-priority delivery + mask/sigsuspend/sigreturn** (Scenario 4) —
  needed for MC4–MC8.
- **Reserve/commit accounting with failure injection** (Scenario 5) — cheap and confirms the
  clean paths while exposing MC9.

### 3.2 Do Not Model (with rationale)
- **Memory-ordering / atomic reordering** — everything is `Relaxed` under interrupts-disabled;
  no ordering races exist (`pm/mod.rs:46`).
- **Physical-frame allocator internals, page-table structure** — out of scope; model PTE CoW flag
  only abstractly if needed for the fork-rollback test, not as a spec target.
- **Scheduler fairness/quantum tuning** (#1695, #2491, #2558) — already fixed; pure performance
  unless it produces a stuck/never-run thread. Keep as reference, not target.
- **Userspace RPC EINTR partial-progress** (#3013/#3008/#3014) — the partial progress lives in the
  userspace send/recv layer, outside `pm`; not a kernel-internal state-machine property.
- **`notify_all()?` dead error branch** (`unsafe.rs:558`) — `notify_all` is total/always-`Ok`;
  copy-review only.

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|-----------|-----------|---------|----------|
| Deferred reap queue | `deferred_reap`, `reaped_by` | Expose divergent-path `live_count` leak | 2 |
| Monotonic IDs | `next_tid`, `next_pid` (never reused) | Model #1440 + exhaustion via leaks | 2 |
| Thread-held mutexes | `held_mutexes[t]`, mutex `owner` | Release-at-harvest liveness | 3 |
| Sync refcounts | `arc_refs(mutex/cond)` | Destroy-with-live-waiter guard | 3 |
| Dual pending sets | `proc_pending`, `thread_pending[t]` | Delivery-selection correctness | 4 |
| Sigsuspend state | `saved_blocked[t]`, `blocked[t]` | Nested-mask restore bug | 4 |
| Reserve/commit flags | `reserved`, `committed` per ID | Rollback completeness | 2,5 |
| Stopped/self-stop | `stopped[p]`, deferred deschedule | One-quantum stop window | 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ExactlyOneLocation | Safety | Each process is in exactly one of running/ready/suspended/interrupted/zombies; each thread in exactly one tstate | Scenario 1 |
| NestedStateConsistent | Safety | pstate equals the precedence-function of its thread sub-lists | Scenario 1 |
| NoRunAfterZombie | Safety | A zombie thread/process is never dispatched | Scenario 1 |
| NoStoppedDispatch | Safety | A stopped process is not run after its scheduling point | Scenario 1, self-stop |
| ReapedExactlyOnce | Safety | Each zombie thread reaped by exactly one reaper; `on_thread_reaped` called once | Scenario 2, MC1 |
| LiveCountAccurate | Safety | `thread_live_count` = live+zombie-unreaped threads; decremented once per burial | Scenario 2, MC1 |
| NoUnreapableZombie | Liveness | Every zombie is eventually reaped by some path | Scenario 2, MC1 |
| JoinGetsStatus | Liveness | A waiting joiner eventually receives the target's exit status (not ThreadNotFound) | Scenario 2, MC2 |
| ExecAdmission | Safety | A net-zero-delta exec is not refused while a reclaimable slot exists | Scenario 2, MC9 |
| MutexReleasedOnDeath | Liveness | A mutex held by a terminating thread is released so waiters can proceed | Scenario 3, MC3/MC10 |
| NoDestroyWithWaiter | Safety | No mutex/cond destroyed while a thread is parked on it | Scenario 3 |
| CondWaitReacquires | Safety | `wait_cond` returns holding the mutex on every path (or reports failure without claiming it) | Scenario 3, §6.2 |
| MaskedSignalDeferred | Safety | A blockable signal (incl. default-action) does not act while masked | Scenario 4, MC4 |
| SignalEventuallyDelivered | Liveness | A deliverable pending signal reaches some eligible thread | Scenario 4, MC5/MC7 |
| SigsuspendMaskRestored | Safety | After nested delivery, `blocked` returns to the pre-suspend mask | Scenario 4, MC6 |
| NoSignalToZombie | Safety | Signals are not posted/mutated on a zombie process | Scenario 4, MC8 |
| RollbackComplete | Safety | Failed create/fork/exec restores every reserved ID and `live_count` | Scenario 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|----|-------------|------------------------------|----------|
| MC1 | Deferred detached-zombie reaped via `harvest_zombie_thread` after its process is buried → early `return` skips `on_thread_reaped` (diverges from `reap_deferred_zombie_threads`) | ReapedExactlyOnce / LiveCountAccurate | 2 |
| MC2 | Concurrent detach/second-joiner reaps a target before a waiting joiner → joiner gets ThreadNotFound instead of status | JoinGetsStatus | 2 |
| MC3 | Thread exits/killed holding a mutex; guard releases only at harvest → siblings on `lock(None)` block until join (or forever) | MutexReleasedOnDeath | 3 |
| MC10 | Killed cond-waiter re-locks a zombie-held mutex in `wait_cond` reacquire → permanent block | MutexReleasedOnDeath | 3 |
| MC4 | Blocked default-action signal (e.g. masked SIGTERM) terminates/stops target immediately | MaskedSignalDeferred | 4 |
| MC5 | Caught signal to a Runnable process with a masked ready thread + unmasked sleeping thread never interrupts the sleeper | SignalEventuallyDelivered | 4 |
| MC6 | Nested signal during sigsuspend consumes the single `saved_blocked` → wrong final mask | SigsuspendMaskRestored | 4 |
| MC7 | Pending caught signal stranded after disposition change to DFL/IGN then unmask | SignalEventuallyDelivered | 4 |
| MC8 | `kill` posts a caught signal into a zombie / fatal-vs-caught inconsistency on zombies | NoSignalToZombie / ExactlyOneLocation | 4 |
| MC9 | `execv` reserves an extra TID via non-healing `try_next_tid`; at MAX_THREADS a net-zero exec is refused | ExecAdmission | 2 |

*All MC rows are forward questions about current, unaudited behavior (not reproductions of closed
fixes); each predicts an observable wrong output/state (litmus passed).*

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|-------------------------|
| T1 | `wait_cond` skips mutex reacquire on `get_cond`/`put_cond` failure | Exhaust `COND_OPEN_MAX`, then assert caller no longer holds the mutex |
| T2 | Missing restorer drops an async caught signal | Install handler with no `SigRestorer`, post caught signal, observe loss |
| T3 | Failed fork leaves parent pages CoW | Fault-inject `link_user_pages`/`forge_user_context`; count parent CoW faults |
| T4 | `mmap` rollback leaves earlier batches mapped when `try_unmap_upage` fails | Fault-inject rollback unmap; assert address space state |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|------------------|
| CR1 | `join_cond.notify_all()?` dead error branch (`unsafe.rs:558`; `notify_all` is total) | Drop `?` or document as defensive |
| CR2 | Self-stop runs up to one extra quantum before deschedule | Confirm deferred-stop latency is acceptable/documented |
| CR3 | `take_earliest_ready` `.expect` panics if all ready processes are stopped (`mod.rs:2674`) | Confirm kernel-never-stopped invariant; handle gracefully |
| CR4 | Fork lazy-recreates independent kernel mutex/cond tables (#2612) | Design decision: parent/child sync divergence |
| CR5 | Thread-exit leaves a `MUTEX_OPEN_MAX` process map slot occupied until process exit | Add `put_mutex` on owner death or document |

## 7. Reference Pointers

- **Full analysis report:** `.specula-output/analysis-report.md`.
- **Key source files:**
  - `src/kernel/src/pm/process/manager/mod.rs` — scheduling `1658-1936`, exit/terminate
    `2103-2327`, reaping/accounting `2441-2697, 3284-3495`, signal-post `838-900`,
    signal-wakeup `1000-1052`, mmap rollback `3523-3599`.
  - `src/kernel/src/pm/process/manager/unsafe.rs` — entry points `286-937`; `harvest_zombie_thread`
    `654-709` (MC1); `reap_deferred` `610-633`; `switch`/`next_thread_quantum` `1208-1300`.
  - `src/kernel/src/pm/process/state/{mod,signal,running,runnable,sleeping,interrupted,zombie}.rs`.
  - `src/kernel/src/pm/thread/{mod,state,ready,running,sleeping,interrupted,zombie}.rs`
    (#1440 FIXME `mod.rs:222`).
  - `src/kernel/src/pm/sync/{mutex,condvar}.rs`; `src/kernel/src/pm/kcall/wait_cond.rs`.
- **GitHub (context, not targets):** OPEN — #1440 (ID recycling), #2612/#2606 (fork sync),
  #2694/#2695 (signals), #3013/#3008/#3014 (EINTR). CLOSED (evidence of bug-proneness) — #1635,
  #2345, #2495/#2506, #585, #570, #1695, #2491, #2558.
- **Category carry-forward:** **Category B** — use concurrent-style modeling
  (`concurrent-analysis.md`): state machine + interleaving, safety (exactly-one-location,
  reaped-once) + liveness (no-stuck-waiter, no-lost-wakeup); trace-validate against kernel logs.
