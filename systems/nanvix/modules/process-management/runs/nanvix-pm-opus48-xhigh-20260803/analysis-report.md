# Nanvix Process Management — Code Analysis Report

**System:** nanvix/nanvix — microkernel process/thread lifecycle management
**Scope:** `src/kernel/src/pm` (process manager, thread manager, signals, sync)
**Language:** Rust (`#![no_std]`, x86 32-bit, ring 0)
**Repo state:** HEAD `6f1e9a0d3` (local clone; no remote configured)
**Category:** **B (Concurrent / Runtime)**
**Methodology:** Specula `code-analysis` skill, Phases 0–4.

---

## 1. Phase 0 — Classification

**Category B (Concurrent / Runtime).** The subsystem is a single-core kernel scheduler with
explicit thread/process state machines, run queues, signals, mutexes, and condition variables.
There is no message-passing consensus protocol; the "concurrency" is **logical interleaving**
inside one CPU:

- Kernel executes **interrupts-disabled**; all shared atomics use `Ordering::Relaxed`
  (`pm/mod.rs:46`). Memory-ordering races are therefore out of scope; **control-flow
  interleaving** is the modeling target.
- Two interleaving sources:
  1. **Timer preemption** — fires only in user mode → `tick()` → `giveup()` → `schedule()` →
     `switch()` (`unsafe.rs:899, 937, 1258`).
  2. **Kernel-call scheduling points** — any kcall that sleeps/blocks (sleep, join, mutex/cond
     wait) yields via a context switch and re-enters later.
- The IKC IRQ handler is intentionally ack-only because "polling from user-process context
  corrupts run-queue bookkeeping and leaks a process" (`pm/mod.rs:82`) — direct evidence that
  interleaving at kernel entry is the dominant hazard class.

This matches the Category B playbook (`concurrent-analysis.md`): model the state machine +
interleaving, check safety (exactly-one-location, reaped-exactly-once) and liveness
(no-stuck-waiter, no-lost-wakeup).

---

## 2. Phase 1 — Reconnaissance

**Scale (PM subsystem):** ~17.7K LOC total, ~14.9K non-test. 227 commits touch
`src/kernel/src/pm`.

**Process-level states** (ProcessManager, `manager/mod.rs:199-255`) — each process is in exactly
one container:

| Container | Type | State |
|-----------|------|-------|
| `running` | `Option<RunningProcess>` | Running |
| `ready` | `LinkedList<RunnableProcess>` | Runnable |
| `suspended` | `LinkedList<SleepingProcess>` | Sleeping |
| `interrupted` | `LinkedList<InterruptedProcess>` | Interrupted |
| `zombies` | `LinkedList<ZombieProcess>` | Zombie |
| `deferred_reap` | `Vec<(Pid, ZombieThread)>` | (transient thread-level) |

**Nested state machine (key modeling insight, confirmed by deep-procstate):** a process's
PM-level state is a *function of its threads' sub-states*. Each process owns internal thread
sub-lists (ready/running/sleeping/interrupted/zombie). Precedence: a process is `Running` if it
has a running thread; else `Runnable` if any ready; else `Sleeping`; else `Interrupted`; else
`Zombie` (`process/state/{running,runnable,sleeping,interrupted,zombie}.rs`).

**Thread-level states** (ownership wrappers around one `Box<ThreadState>`): `ReadyThread`,
`RunningThread`, `SleepingThread`, `InterruptedThread`, `ZombieThread`.

**Accounting.** `ThreadManager.live_count` (init 1), `ProcessManager.live_count` (init 1).
Two-phase reservation avoids leaking IDs on failure: `try_next_tid()` checks `MAX_THREADS`
without mutating (`thread/mod.rs:227`), work happens, then `commit_next_tid()` advances +
`live_count += 1` (`thread/mod.rs:261`); `on_thread_reaped()` decrements with
`assert(live_count>1)` (`thread/mod.rs:272`). Same pattern for PID. **IDs are never recycled**
(FIXME #1440, OPEN, `thread/mod.rs:222`).

**Reaping architecture.**
- Non-detached zombie thread → stays in the process's zombie sub-list → harvested by
  `join_thread` → `harvest_zombie_thread` → `on_thread_reaped`.
- Detached zombie thread whose exit produced an outgoing `ContextInformation` still needed by an
  in-progress `switch()` → returned as `deferred_zombie` → pushed to `deferred_reap` → drained by
  `reap_deferred()` at every PM entry point *after* the switch completes (avoids UAF, #2345).
- Admission self-heals: `try_next_tid_reaping()` reaps zombies on `OutOfMemory` then retries
  once (`manager/mod.rs:3410`).
- `reap_pending_zombies` never reaps PROCD (its termination is the kernel-shutdown signal,
  `manager/mod.rs:3287`).

---

## 3. Phase 2 — Bug Archaeology

**Git mining.** 40 `] B:` (bug) commits touch pm; ~12 read in full. Recurring mechanism
clusters:

- **Zombie loss / double-consume:** `take()` consumed twice dropped a zombie → join "thread not
  found" (#1635 / `4f6d6af26`); detached-zombie UAF because the outgoing `ContextInformation`
  switch still writes it → introduced `deferred_reap` (#2345 / `92bad91f2`); "Don't Drop Zombie
  Threads" (`ca08d5de0`); reap-on-admission (#2495 / #2506).
- **Condvar stale-waiter / lost-wakeup:** timed wait + alarm removes the thread from the sleeping
  list before notify pops the tid → the notification is consumed by an already-woken thread →
  "Skip stale condvar waiters" (`6055a7366`); `notify_first` return-count fix (`387a1a6ae`);
  wait-failure must remove the tid from the queue (`2d36cd4bc`); drop join condvar on exit
  (#585 / `2bcda508b`).
- **Scheduler quantum / fairness:** intra-process quantum-inheritance starvation
  (#1695 / `61c309003`); alarm-servicing starvation (#2491); `try_wait` FIFO starvation (#2558);
  switch-same-process optimization (`84ba4fc4c`); preserve-order-in-queues (`8b454e36e`).
- **Signal interruption of blocking IPC (OPEN, mostly userspace RPC):** EINTR contract assumes
  no partial progress, violated by userspace send/recv (#3013 meta, #3008, #3014);
  KcallRestart / SA_RESTART / sigsuspend (#2695); async signal delivery (#2694).
- **Mutex/cond across fork (OPEN):** per-process kernel mutex/cond tables are dropped in the
  child and lazily recreated; userspace registry diverges (#2612 / PR #2606).

**GitHub issues/PRs collected (~25):** #1440 (OPEN, ID recycling), #1695 (closed, quantum),
#570/#585/#1635/#2345/#2495/#2506 (closed, reaping/zombie), #2491/#2558 (closed, fairness),
#2612/#2606 (OPEN, fork sync), #3013/#3008/#3014 (OPEN, EINTR), #2694/#2695 (OPEN, signals).

**Archaeology rule applied:** closed/fixed bugs are treated as **evidence of mechanism
bug-proneness** and **reference pointers**, NOT as model-checkable targets. We do not re-derive
`git revert` of a merged fix. The model-checkable findings in §5 below are *forward* questions
about currently-unaudited behavior.

---

## 4. Phase 3 — Deep Analysis (method)

Manager core (`manager/mod.rs` 3887 LOC + `unsafe.rs` 1346 LOC), `condvar.rs`, `mutex.rs`, and
`wait_cond.rs` were read personally. Five parallel general-purpose subagents deep-read the
remaining clusters with full shared context; every subagent finding cited below was
cross-checked against exact `file:line`:

| Cluster | Files | Result |
|---------|-------|--------|
| deep-thread | `thread/{state,mod,ready,running,sleeping,interrupted,zombie}.rs` | F1 join-reap-claim race |
| deep-procstate | `process/state/*` | self-stop scheduling window; no #1635 regression |
| deep-signal | `process/{state/signal,sigframe}.rs`, `manager/signal.rs`, kcalls | 6 findings + signal model |
| deep-sync | `sync/{mutex,condvar,spinlock,fence}.rs`, `lock/unlock/wait_cond` kcalls | 3 findings + sync model |
| deep-kcall | `kcall/*`, create/dup/exec/mmap rollback | 4 findings + rollback map |

---

## 5. Findings (verified)

### 5.1 Model-checkable (forward, unaudited behavior)

**MC1 — Deferred detached-zombie `live_count` leak (divergent reaping paths). HIGH.**
Two functions that are documented to do the same thing handle the missing-process case
differently:
- `harvest_zombie_thread` (entry-point path via `reap_deferred()`): on `find_process_mut(pid)`
  failure it **`return`s early at `unsafe.rs:668`**, skipping `on_thread_reaped()` at
  `unsafe.rs:708`.
- `reap_deferred_zombie_threads` (on-demand admission path): on the same failure it **logs and
  falls through** to `on_thread_reaped()` at `manager/mod.rs:3387` (see `3375-3388`).

The doc comment at `manager/mod.rs:3318` says the latter "mirrors `harvest_zombie_thread`", but
it does not. Trigger: a detached thread exits while sibling threads remain (deferred zombie
created, `running.rs:367-382`, stored `manager/mod.rs:2225-2236`); the owner process is then
externally terminated and *buried by the idle harvest* (`kcall/handler.rs:79-82,155-163`;
`pop_zombie_process`/`harvest_zombies` clear the process, `manager/mod.rs:2444-2459, 3485-3494`)
**before** `reap_deferred()` drains the pending zombie. The subsequent entry-point harvest can no
longer find the process → early return → **`ThreadManager.live_count` is never decremented**.
Because TIDs are also never recycled, each occurrence permanently reduces effective
`MAX_THREADS`. Observable output: `create_thread`/`fork` later fails `OutOfMemory` with slots
that should be free. **Passes output-value litmus.** Class: model-checkable + test-verifiable.

**MC2 — `join` has no exclusive reap claim; a joiner can lose the exit status. HIGH.**
`try_join_thread` returns only the target's cloned join condvar for a live target and records no
"join in progress" claim (`process/state/running.rs:573-613`); the joiner sleeps and retries
(`unsafe.rs:751-764`). Meanwhile a concurrent `detach` on the same target just sets `detached`
for a live target (`running.rs:663-703`) or removes/harvests the zombie immediately
(`running.rs:650-655`, `unsafe.rs:807-810`), and a detached zombie with surviving siblings is
routed to `deferred_reap` outside normal thread lookup (`running.rs:377-381`,
`manager/mod.rs:2225-2226`). Interleavings: (a) joiner waits, detach detaches, target exits,
joiner wakes and fails `ThreadNotFound` (`running.rs:618-620`); (b) target exits and reaps before
the joiner runs; (c) multiple joiners — the first reaps, later joiners fail. `notify_all()` on
exit prevents *permanent* sleep (`unsafe.rs:558`), but no mechanism guarantees a waiting joiner
receives the status. Observable output: `join` returns error instead of the child's exit status.
Class: model-checkable + test-verifiable.

**MC3 — A thread that dies holding a mutex keeps it locked until the zombie is harvested;
mutex waiters can block indefinitely. HIGH.**
Mutex ownership lives *only* in `ThreadState.locked_mutexes: BTreeMap<_, MutexGuard>`
(`thread/state.rs:82`). The guard releases the lock **only when it is dropped**
(`sync/mutex.rs:200-206`: `unlock_unchecked` clears `locked` + `notify_first`). But the guard is
dropped with the `ThreadState`, which is not dropped until the `ZombieThread` is harvested. On
exit/kill, `ThreadState::drop` **only logs** a warning about held mutexes (`thread/state.rs:524-532`)
— it performs no proactive `put_mutex`/unlock. Consequences:
- A **non-detached** dying thread keeps the mutex locked until it is *joined* (harvest is
  join-driven); if nobody joins, the lock is held for the rest of the process lifetime.
- Any sibling in `mutex.lock(None)` (`sync/mutex.rs:174-186`) or in the `wait_cond` reacquire
  (`kcall/wait_cond.rs:126-128`) sleeps in that mutex's internal condvar with `timeout=None` and
  is only woken by the `notify_first` that runs at guard-drop = harvest time → blocks until then
  (or forever). Observable: liveness violation (stuck waiter). Class: model-checkable +
  test-verifiable. **Secondary accounting effect:** the process's `mutexes` map entry is never
  `put_mutex`'d on this path, so a `MUTEX_OPEN_MAX` slot is also leaked for the process lifetime.

**MC4 — Blocked default-action signal is acted on immediately (mask ignored). HIGH.**
In the signal-post primitive, only the `Handler` disposition posts to `pending` and defers
(`manager/mod.rs:854-856`, `PostAction::Interrupt`). The `Default` disposition computes
`default_action` and applies `Terminate`/`Stop` **without consulting any thread's `blocked`
mask** (`manager/mod.rs:858-875, 892-897`). Trigger: a process blocks e.g. `SIGTERM`/`SIGTSTP`;
another process sends it → the target is terminated/stopped immediately. Expected (POSIX):
blockable signals stay pending until unmasked; only `SIGKILL`/`SIGSTOP` are unmaskable (handled
separately, `manager/mod.rs:842`). Observable: a process with `SIGTERM` masked dies. Class:
model-checkable + test-verifiable.

**MC5 — Caught signal can miss an unblocked sleeping thread in a runnable process. MEDIUM.**
`interrupt_signal_candidate` only scans `self.suspended` processes (`manager/mod.rs:1009-1014`),
assuming ready/running processes need no wakeup (`1000-1002`). But a `Runnable` process may hold
one ready thread that has the signal blocked and one sleeping thread that does not; the sleeping
thread is never interrupted (`state/signal.rs:242-245` masks delivery on the ready thread) → the
signal starves in `pending`. Observable: a deliverable signal is not delivered while an eligible
sleeping thread waits. Class: model-checkable + test-verifiable.

**MC6 — Nested signal during `sigsuspend()` restores the wrong mask. MEDIUM.**
`sigsuspend` saves exactly one per-thread `saved_blocked` (`manager/mod.rs:733-735`), and every
`sigreturn` gives `saved_blocked` precedence over the frame mask (`state/signal.rs:600-610`). If
handler A (running under sigsuspend) is itself interrupted by signal B, **B's `sigreturn`
consumes A's saved mask**; A later returns using only the frame's temporary mask → the thread is
left with the wrong final `blocked`. No nesting depth/token. Observable: wrong `blocked` mask
after nested delivery. Class: model-checkable + test-verifiable.

**MC7 — Pending caught signal stranded after a disposition change. MEDIUM.**
`sigaction` installs a new disposition but neither clears nor re-applies already-pending signals
(`manager/mod.rs:603-611`); async delivery skips non-`Handler` dispositions and leaves the bit
pending (`state/signal.rs:234-253`). Trigger: post while a handler is installed but blocked →
change disposition to `SIG_DFL`/`SIG_IGN` → unblock. Result: the pending bit is neither delivered
nor discarded (default/ignore semantics never applied). Observable: a signal permanently stuck
pending. Class: model-checkable + test-verifiable.

**MC8 — `kill()` mutates zombie signal state; fatal-vs-caught handling is inconsistent for
zombies. MEDIUM.** Process lookup includes zombies (`manager/mod.rs:2824-2852`). A caught signal
to an unreaped zombie is posted into the zombie's `SignalControl` (`manager/mod.rs:850-856`) and
returns `Done`, but no thread will ever run it; a fatal signal instead reaches `terminate()`,
which does not handle zombies and reports `NoSuchProcess` (`manager/mod.rs:2294-2327`).
Observable: signal posted to a dead process / inconsistent error. Ties to the exactly-one-location
invariant. Class: model-checkable + test-verifiable.

**MC9 — `execv()` temporarily inflates `live_count` and can spuriously fail admission at
`MAX_THREADS`. MEDIUM.** `execv` reserves a *new* TID before replacing the single running thread
(`manager/mod.rs:2022-2023`) and commits it after replacement (`2062-2065`); the old thread's
`live_count` is decremented only later via deferred reap (`2070-2076`, `unsafe.rs:610-632,
707-708`). It uses `try_next_tid()` (not the self-healing `try_next_tid_reaping()`), so when
global `live_count == MAX_THREADS`, a net-zero-delta exec is rejected. Observable: exec fails
`OutOfMemory` when it should succeed. Class: model-checkable + test-verifiable.

**MC10 — Killed cond-waiter deadlocks re-locking a zombie-held mutex. HIGH (variant of MC3).**
`wait_cond` always reacquires the mutex before returning the sleep result
(`kcall/wait_cond.rs:125-130`). If process termination converts a mutex owner to a (not-yet-
harvested) zombie and interrupts the cond-waiter (`state/runnable.rs:165-168`, `thread/ready.rs:188`,
`state/sleeping.rs:97-108`), the waiter resumes, then blocks forever in `mutex.lock(None)`
(`wait_cond.rs:126-128`) on the zombie-held guard — it only observes `Killed` *after* the
(never-returning) reacquire. No compensating mechanism. Class: model-checkable + test-verifiable.

**Self-stop scheduling window (modeling nuance).** `stop_process` only sets `stopped=true`
(`manager/mod.rs:951-964`); a running process that stops itself keeps running until the next
scheduling point, where `schedule()` enqueues it (`1671-1675`) and `take_earliest_ready` skips
stopped ready processes (`2674-2697`). So a stopped process may execute up to one extra quantum.
This is the deferred-stop design; recorded as a modeling nuance for the exactly-one-location /
"no stopped process runs" invariant, demoted to §6.3 (predicted verdict: documented design).

### 5.2 Verified-clean / false positives ruled out

- **No reachable double-state / schedule-after-zombie.** All thread and process transitions
  consume `self` and move the same `Box`; scheduler selects only ready, non-stopped members
  (`manager/mod.rs:1671-1692`; `runnable.rs:141-149`). Zombies have no run path.
- **No #1635 regression.** `exit_thread` extracts each sub-list exactly once and routes it
  totally (`running.rs:357-448`); `pending_exit_status` is set-once (`state/mod.rs:288-291`).
- **Stale condvar notifications are compensated.** `notify_first/all` skip stale waiters
  (`condvar.rs:118-129, 196-208`); `wait` removes itself on sleep error (`condvar.rs:259-265`);
  `notify_all` is total and always returns `Ok` (so the `?` on `exit_thread`'s
  `join_cond.notify_all()?` at `unsafe.rs:558` is a **dead defensive path** — code-review only).
- **No destroy-with-live-waiter.** Mutex waiters hold a `Mutex` clone and cond waiters a
  `Condvar` clone across the sleep, so refcount-threshold destruction (`put_mutex` at `<=2`,
  `put_cond` at `<=1`, `state/mod.rs:638-713`) cannot remove an object with a parked waiter;
  `CondvarInner::drop` panic on non-empty queue (`condvar.rs:286`) is therefore unreachable in
  normal flows.
- **No double unlock / non-owner unlock.** Guards are per-running-thread and removed before the
  second attempt, which returns `OperationNotPermitted` (`manager/mod.rs:2622-2637`).
- **Creation/fork/exec ID accounting is leak-free on failure.** `try_next_{tid,pid}` reserve
  without mutating; commits happen only after all fallible work
  (`create_thread` `manager/mod.rs:445-466`; `create_process` `1202-1233`; `duplicate_process`
  `1621-1638`; `execv` `2064-2076`). `build_user_image` failure paths call `clear_user_space`
  (`1435-1447`).
- **Unblockable masks enforced.** `SIGKILL`/`SIGSTOP` are cleared from every public mask path
  (`state/signal.rs:175-176`; `manager/mod.rs:730-735, 774-775`; `state/signal.rs:296, 419,
  607-610`) and `sigaction` rejects changing them (`kcall/sigaction.rs:88-92`).

### 5.3 Test-verifiable / code-review-only

- **`wait_cond` error paths skip mutex reacquire (test/model).** On `get_cond` failure
  (`COND_OPEN_MAX`) the subsequent `put_cond` returns `NoSuchEntry` and `?`-returns before the
  reacquire at `wait_cond.rs:126-128`; the caller believes it holds the mutex but the kernel does
  not.
- **Missing restorer drops an async caught signal (test / ABI code-review).** With no registered
  restorer, async delivery clears the pending bits and returns `None` (`state/signal.rs:257-268`),
  while the sync path terminates (`388-393`); if the signal had interrupted a blocking call, the
  restart record was already consumed (`state/signal.rs:218-220`).
- **Failed fork leaves parent pages CoW (test / mm code-review).** Parent writable pages are
  marked CoW before the child mark can fail; rollback intentionally does not restore parent flags
  (`mm/virt/manager.rs:390-399, 443-453`). Correctness preserved by CoW fault handling; effect is
  extra CoW faults only.
- **`mmap` rollback is best-effort (test / code-review).** A later-batch failure rolls back
  earlier batches, but a `try_unmap_upage` failure during rollback only warns
  (`manager/mod.rs:3548-3599`); process exit later reclaims the space.
- **Fork lazy-recreates independent kernel sync objects (code-review, #2612 OPEN).** Child gets
  empty mutex/cond maps; per-process caps hold but parent/child synchronization diverges
  (`state/mod.rs:256-257, 436-438, 619-622, 679-683`).
- **`take_earliest_ready` `.expect` panics if every ready process is stopped
  (`manager/mod.rs:2674`).** Argued safe because the kernel process is never stopped and is always
  ready when a non-kernel process runs; recorded as a liveness invariant to confirm.

---

## 6. Coverage summary

- Personally read: `manager/mod.rs` (scheduling, reaping, accounting, signal-post, mmap),
  `manager/unsafe.rs` (all entry points), `sync/condvar.rs`, `sync/mutex.rs`,
  `kcall/wait_cond.rs`, plus `thread/mod.rs`, `thread/state.rs`, `process/state/mod.rs`.
- Subagent-covered (cross-checked): all `thread/*`, all `process/state/*`,
  `manager/signal.rs` + signal kcalls, `sync/*` + lock/unlock/wait kcalls, all `kcall/*` +
  create/dup/exec/mmap rollback.
- Git: 40 bug commits identified, ~12 read fully. GitHub: ~25 issues/PRs collected, key ones
  read (discussions, not just titles).
- **11 model-checkable findings** (MC1–MC10 + self-stop nuance), **5 test/code-review findings**,
  **7 false positives explicitly ruled out**.

The modeling brief (`modeling-brief.md`) organizes these into 5 mechanism-grouped Scenarios with
proposed extensions, invariants, and a filtered §6.1 model-checkable list.
