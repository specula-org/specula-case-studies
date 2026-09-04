# Nanvix PM Trace Harness — Instrumentation Guide

This document tells the Phase-3 (validation) agent how the harness is wired, how to adjust it, and
what remains uncovered. The harness instruments the **real** Nanvix process-management (PM)
state-transition code and emits one NDJSON line per spec action; `spec/Trace.tla` replays those
lines and validates the captured post-state.

---

## 1. What the harness is (and is not)

- It **drives the real leaf type-state transitions** of the PM subsystem — the same
  `RunnableProcess::run` / `RunningProcess::{schedule,sleep,exit}` /
  `SleepingProcess::{terminate,wakeup,wakeup_alarm}` / `InterruptedProcess::{resume,terminate}` /
  `ZombieProcess::bury` transitions, the real `SignalControl` / `ThreadState` signal methods, and
  the real `Mutex::try_lock` / guard-drop / `ProcessState::{get_mutex,put_mutex}` mutex path — that
  the process manager uses internally. It is the trace analogue of the existing in-kernel tests
  `pm/process/state/kill_test.rs` and `test_detach.rs`.
- It is **not** a simulator. Every lifecycle decision (which subset a process folds into, whether a
  terminate yields a zombie or an interrupted process, whether a mutex map entry is reclaimed, …)
  is taken by the real transition method. The harness only records *which manager list* each real
  object currently occupies (a value dictated by the real transition's return type) and reads the
  real objects back to build the snapshot.

**Why in-kernel and not host-side?** The PM types are `#![no_std]` and deeply coupled to the HAL,
memory manager, and the global `ProcessManager` singleton (e.g. `Condvar::wait`/`notify_first` call
`ProcessManager::get()`). They cannot be constructed on the host. The harness therefore runs inside
the real kernel's in-kernel test phase (`pm::test::test()`), booted in the standalone UserVM.

---

## 2. File map (after `apply.sh`)

| File | Role |
|---|---|
| `src/kernel/src/pm/tla_trace.rs` | **New.** NDJSON emitter. `emit_line()` streams a JSON object to the kernel console via `klog::puts` + `klog::flush` (see §5). `KlogWriter` is an `fmt::Write` adapter; `write_str_lit` escapes string values; `emit_marker(name)` writes a `@@SCENARIO@@` boundary. |
| `src/kernel/src/pm/process/state/tla_world.rs` | **New.** The `World` (five real process lists + running slot + exit window + condvar FIFO + mutex state), the snapshot serializer, one method per spec action, and the scenarios. `run_all()` is the entry point. |
| `src/kernel/src/pm/mod.rs` | +`#[cfg(feature="test")] pub(crate) mod tla_trace;` |
| `src/kernel/src/pm/process/state/mod.rs` | +`#[cfg(feature="test")] pub(crate) mod tla_world;` and a read-only `ProcessState::contains_mutex` getter (`mod.rs:603`). |
| `src/kernel/src/pm/test.rs` | Calls `crate::pm::process::state::tla_world::run_all()` from `pm::test::test()`. |
| `src/kernel/src/pm/thread/state.rs` | Read-only observation getters: `interrupt_reason_ref` (`:266`), `clear_interrupt_reason` (`:278`), `set_interrupt_reason_trace` (`:292`), `saved_blocked_ref` (`:502`). All `#[cfg(feature="test")]`. |

Everything is behind `#[cfg(feature = "test")]`; a normal (non-test) build is untouched. The edits
to the four existing files live in `patches/instrumentation.patch`; the two new modules are copied
verbatim from `src/`.

**Each action's emit point is the corresponding method in `tla_world.rs`** — e.g. `Schedule` is
`schedule()` (`tla_world.rs:590`), `RunnableTerminate` is `runnable_terminate()` (`:617`),
`LockMutexAcquire` is `lock_mutex_acquire()` (`:1122`). Each method (1) performs the real
transition, then (2) calls `self.emit("<Action>", |w| …extra fields…)`, which appends the full
`state` snapshot from `write_state()` (`:496`).

---

## 3. Action coverage

**Emitted and validated (24 actions, 9 scenarios — all `PASS` against the given `Trace.tla`):**

| Scenario (`traces/<name>.ndjson`) | Actions exercised |
|---|---|
| `lifecycle` | CreateProcess, Preempt, Schedule, RunnableTerminate, HarvestZombieProc |
| `alarm_resume` | Sleep, AlarmFire, ResumeInterrupted, DispatcherCheckpoint (return-to-user branch) |
| `terminate` | Sleep, SuspendedTerminate, InterruptedTerminate, ResumeInterrupted, DispatcherCheckpoint (killed→exit branch), HarvestZombieProc |
| `exit` | ExitTakeRunning, ExitCleanupRendezvous, ExitReinsert, HarvestZombieProc |
| `rendezvous` | RegisterRendezvous, SuspendedTerminate |
| `multithread` | CreateThread, Sleep (with-siblings→ready branch) |
| `notify` | NotifyDequeue, WakeDequeued |
| `signal_disposition` | SetDisposition, InstallHandler, Exec, MarkInterruptedBySignal |
| `sync` | LockMutexAcquire, UnlockMutex |

**Implemented in the harness but NOT emitted by default** (methods `mask_change`,
`sigsuspend_install`, `sigreturn`; `scenario_signal_mask`): **MaskChange, SigSuspendInstall,
SigReturn**. These carry a `mask` array that `Trace.tla` passes to the base action unchanged, but
`base!MaskChange`/`base!SigSuspendInstall` require a **set** (`newmask \subseteq Signal`). A JSON
array deserializes to a TLA **sequence**, which is not enumerable for `\subseteq`, so validation
throws at `base.tla:1025`. See §6 for the one-line Phase-3 fix; with it, `MaskChange` validates
(confirmed). To emit them, uncomment the two lines in `run_all()`.

**Not covered (with reasons):**

- **CreateProcessSpuriousOOM** — a *modeled-bug* action that sets the `spuriousOOM` ghost `TRUE`. A
  faithful, non-buggy execution never takes it; emitting it would fail `ChkGhosts` (which asserts
  ghosts stay `FALSE`). Intentionally omitted.
- **PostSignalHandler, PostSignalDefaultTerminate** — cross-process `kill` via the manager's
  `interrupt_signal_candidate` scan. This is manager-glue (it needs the target process on a real
  manager list and the candidate-scan/fold logic), not a leaf transition. To add: extend `World`
  with a real signal-post path (drive `SignalControl::post` on the *target* process object, then
  apply the fold/interrupt to the target), or add a `#[cfg(feature="test")]` hook on
  `ProcessManager` that runs `kill()` against an injected process.
- **DeliverSignal** — `try_deliver_signal` at the kcall-return checkpoint (lowest-deliverable
  selection, mask install, SA_RESTART attribution). Manager/signal-coupled. To add: drive
  `SignalControl` + `ThreadState` directly to reproduce the selection, keeping `restartMisattributed`
  false (deliver == interrupting signal).
- **LockMutexCancel, CondWaitUnlock, CondWaitSleep, CondWaitRelock, CondWaitRelockInterrupted** —
  the cond-wait cycle and contended-lock cancellation go through `Condvar::wait`/`notify_first`,
  which call the global `ProcessManager` and **block** (context switch), so they cannot be driven
  from a straight-line in-kernel test. `CondWaitUnlock`/`CondWaitRelock`/`CondWaitSleep` could be
  decomposed into their real non-blocking sub-steps (guard drop → enqueue bookkeeping → relock);
  `LockMutexCancel` needs the `mutexExtraRef` refcount-leak path, which requires holding a second
  `Mutex` clone. Guidance: mirror the `lock_mutex_acquire`/`unlock_mutex` pattern in `tla_world.rs`.

---

## 4. How to adjust the instrumentation

### Add a new field to an event
Widen the `write_extra` closure at the action's `self.emit(...)` call. Example (`set_disposition`,
`tla_world.rs:992`):
```rust
self.emit("SetDisposition", |w| {
    write!(w, ",\"pid\":\"p{}\",\"sig\":{},\"disp\":\"{}\"", i + 1, sig, disp)
});
```
Top-level event fields (`pid`, `sig`, `mutex`, `cond`, `mask`, `disp`, `sar`) go here. State fields
go in `write_state()`.

### Add / change a state field in the snapshot
Edit `write_state()` (`tla_world.rs:496`). Each field is streamed by a `write_*` helper that reads
the **real** objects (`write_pending`, `write_blocked`, `write_disposition`, `write_savedblocked`
read the live `SignalControl`/`ThreadState`; `write_procstate`/`write_threadstate`/`write_running`
read the process/thread lists via `find_thread`). Keep every field a **total function** over the
symbolic universe (`p1..p2`, `t1..t3`, `Signal={1,2}`); free slots default (`"free"`, `[]`,
`"default"`, `"NoMask"`, `false`, `"NoThread"`). Remember: JSON **object keys deserialize to
strings**, **array elements to integers**, and a JSON **array becomes a TLA sequence** whose domain
is `1..len` (this is why `disposition[p]` is emitted as a signal-indexed array — its domain then
equals `Signal`).

### Add a new event type
Add a method on `World` that (1) drives the real transition(s), (2) updates any bookkeeping
(`running_pid`, `exit_phase`, `cond_waiters`, `notify_reg`, mutex fields), and (3) calls
`self.emit("<Name>", …)`. Then call it from a scenario and register the scenario in `run_all()` with
a `tla_trace::emit_marker("<scenario>")`. The `"<Name>"` must exactly match a `Trace.tla` wrapper.

### Move a capture point (before ↔ after)
All snapshots are **post-state** (the spec validates primed variables). To capture an intermediate
point of a split action, perform the real sub-operation, emit, then continue — as
`exit_take_running` → `exit_cleanup_rendezvous` → `exit_reinsert` do around the real
`RunningProcess::exit`.

---

## 5. Output channel & extraction

- Each event is one line: `@@TLA@@ {json}` written via `klog::puts` (bypasses log-level gating) +
  `klog::flush`. Scenario boundaries are `@@SCENARIO@@ <name>` lines.
- **The kernel slab heap rejects any allocation > 512 bytes** (`mm::kheap::layout_to_allocator`).
  A trace line is 400–900 bytes, so it is **streamed** field-by-field through `KlogWriter`; never
  build a trace line as one `String`.
- `run.sh` boots the kernel in the UserVM, captures stdout, and splits it: for each line, strip
  everything up to and including the last `@@TLA@@ ` marker; group by the preceding `@@SCENARIO@@`.

---

## 6. Validating

```
cd spec
JSON=../traces/<scenario>.ndjson tlc -deadlock -config Trace.cfg Trace.tla
```
`-deadlock` is required (the trace-consumed terminal state has no successor). A faithful trace
prints `No error has been found`; a divergence disables the matching wrapper, stalls the cursor,
and violates `TraceMatched`. `harness/validate.sh <console.log> <traces_dir> <spec_dir>` and
`harness/run.sh` automate split + validation.

**Phase-3 spec fix to enable the mask family** (`MaskChange`/`SigSuspendInstall`/`SigReturn`): in
`Trace.tla`, wrap the raw mask argument with `AsSet` so the JSON array is converted to a set:
```
TMaskChange        == ... /\ MaskChange(AsSet(logline.mask)) /\ ...
TSigSuspendInstall == ... /\ SigSuspendInstall(AsSet(logline.mask)) /\ ...
```
Confirmed: with this fix `MaskChange` validates. (`SigSuspendInstall`/`SigReturn` surfaced a further
`Trace.tla` fingerprinting quirk to resolve in Phase 3; the harness emit for them is correct — the
per-thread `savedBlocked`/`blocked` post-states are read from the real `ThreadState`.)

---

## 7. Rebuild & re-run

```
cd .specula-output
bash harness/run.sh          # apply → build test-kernel+UserVM → boot → split → validate
# or, incrementally:
bash harness/apply.sh
make -C ../source check-test-kernel          # fast type-check
make -C ../source all-test-kernel all-uservm # build
../source/bin/uservm.elf -kernel ../source/bin/kernel-test.elf -kernel-args "test_magic=0xDEADBEEF" > /tmp/c.log 2>&1
bash harness/validate.sh /tmp/c.log traces spec
bash harness/clean.sh        # revert instrumentation
```

## 8. Capture-level / faithfulness notes

- **Interrupt reason.** `ReadyThread::run` *extracts* the interrupt reason into the dispatcher
  return value (clearing it from the thread). The spec models `threadReason` as persisting on the
  thread until `DispatcherCheckpoint`, so `schedule()` re-installs the real reason via
  `set_interrupt_reason_trace` for observation only — no protocol logic is changed.
- **Mutex guard.** The live `MutexGuard` is retained in `World.mutex_guard` (not in the thread's
  `locked_mutexes`) to keep the real lock held; dropping it fires the real `MutexInner::unlock`. The
  real `get_mutex`/`try_lock`/`put_mutex` mechanics (including the `MUTEX_OPEN_MAX` cap and refcount
  reclamation) are exercised; `mutexInMap` is read back from the real map via `contains_mutex`.
- **condWaiters.** The condvar FIFO is world bookkeeping (`cond_waiters`); the real `Condvar` queue
  cannot be enqueued without blocking through the manager. The *thread/process* state transitions
  around it are real. Only `Sleep`/`AlarmFire`/`NotifyDequeue`/`CondWaitSleep` validate `condWaiters`.
- **Boot state.** `World::boot()` reproduces `Trace.tla`'s pinned `TraceInit`: process `p1` (real
  pid 1) running with running thread `t1` (real tid 1); all else free. The first emitted event of a
  scenario is the first real transition from that state.
