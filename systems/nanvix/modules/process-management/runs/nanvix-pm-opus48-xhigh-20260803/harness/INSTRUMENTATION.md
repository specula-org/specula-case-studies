# Nanvix PM Trace Harness — Instrumentation Guide

This harness instruments the **real** Nanvix process-management (PM) subsystem so that its thread
type-state transitions and signal/mutex/condvar/process operations emit an NDJSON trace that is
validated, offline, against `spec/Trace.tla` (the trace-refinement of `spec/base.tla`).

It is written for the **Phase 3** agent who needs to adjust the instrumentation when the spec, the
source, or the desired coverage changes. Read this end-to-end before editing anything.

--------------------------------------------------------------------------------------------------
## 1. What is instrumented, and how

The trace is produced by driving the **actual** PM code paths from an in-kernel test scenario. The
harness adds two new modules to the kernel tree and wires them in with a 3-line patch; nothing in
the protocol logic is re-implemented.

| File (in the artifact)                                | Role |
|-------------------------------------------------------|------|
| `src/kernel/src/pm/tla_trace.rs`                      | NDJSON emitter — streams one JSON line per event to the kernel console via `klog::puts`. |
| `src/kernel/src/pm/process/state/tla_world.rs`        | Scenario driver — builds real thread/process objects, applies real transitions, reads back the observable post-state, and calls the emitter. |
| `src/kernel/src/pm/mod.rs` (patched)                  | `#[cfg(feature="test")] pub(crate) mod tla_trace;` |
| `src/kernel/src/pm/process/state/mod.rs` (patched)    | `#[cfg(feature="test")] pub(crate) mod tla_world;` |
| `src/kernel/src/pm/test.rs` (patched)                 | `pm::test()` calls `tla_world::run_all()`. |

Everything is behind `#[cfg(feature = "test")]`, so a normal (non-test) kernel build is unaffected.

### Real transitions used (ground truth)

The thread lifecycle is driven by consuming one real type-state object and producing the next, using
the exact methods the process manager uses internally:

- `ReadyThread::new / run / terminate / set_detached`
- `RunningThread::schedule / sleep / exit / exit_for_exec`
- `SleepingThread::wakeup / interrupt`
- `InterruptedThread::resume`
- `ZombieThread::harvest`
- `ThreadState::{blocked,set_blocked,take_saved_blocked,set_saved_blocked}` (per-thread mask)

Process/signal state is driven on real objects too:

- `ProcessState::{new,signals,signals_mut,set_stopped,is_stopped}`
- `SignalControl::{set_disposition,post,pending,clear_pending,inherited_for_fork,reset_for_exec}`
- A real `Mutex` + `MutexGuard` (`try_lock`, `Drop`-based unlock).

The observable post-state fields the spec checks (`th[t].st`, `th[t].det`, `th[t].bl`, `pr[p].st`,
`pr[p].sp`, `pr[p].pd`, `pr[p].dp[s]`, `mu[m].ow/ex`, `co[c].ex`) are **read back off these real
objects** after the transition, not computed by the harness.

--------------------------------------------------------------------------------------------------
## 2. Trace schema (must match `spec/Trace.tla`)

Each console line is:

```
@@TLA@@ {"action":"<Name>", <args...>, <observable post-state...>, "tlive":N, "plive":M}
```

`Trace.tla` reads the file with `ndJsonDeserialize`, dispatches on `Lg.action`, **fires the base
action with the recorded arguments**, then asserts the recorded post-state fields equal the state the
base action produced, and finally advances a single linear cursor `l`. `TraceMatched` requires the
whole file to be consumed.

Key schema facts (do **not** "fix" these to the generic Specula default):

- **No `tag`, no `ts` field.** The current `Trace.tla` does not read them.
- `tlive` / `plive` are emitted on **every** line and checked on every line by `Acct`.
- Identity mapping is a fixed bijection: thread slot `i` → `"t{i+1}"`, process slot `p` →
  `"p{p+1}"`, the single mutex → `"mx1"`, the single condvar → `"cv1"`, absent ref → `"NULL"`.
- Signals are bare JSON integers from `Sig = {1,9,15,19}`; masks/pending/deferred/queues are JSON
  arrays (`nm`,`tBl`,`tempmask`,`pPd`,`pd` are signal-number arrays; `muQ`,`coQ`,`deferred` are
  thread-name arrays). A signal `s` occupies bit `1 << (s-1)` (matches `state/signal.rs`).
- `JsonFile` is **hard-coded** in `Trace.tla` line 29 to `"../traces/trace.ndjson"`. There is no env
  override, so `run.sh` validates each scenario by copying it onto `traces/trace.ndjson` in turn.
  **Do not edit `Trace.tla`.**

The exact per-action field list is the corresponding `W_<Action>` wrapper in `spec/Trace.tla`
(lines 52–231). If you add or change an emitted field, cross-check it against that wrapper.

--------------------------------------------------------------------------------------------------
## 3. Scenario ↔ action coverage

`run_all()` runs 11 independent scenarios, each booted fresh at `TraceInit` (process `p1` alive
owning running thread `t1`; free `mx1`/`cv1`; `tlive = plive = 1`). Every scenario is an independent
model-valid trajectory and is validated on its own. All 32 base actions are covered.

| Scenario         | Actions exercised |
|------------------|-------------------|
| `lifecycle`      | CreateThread, Preempt, Schedule, LockAcquire, Unlock, ExitThread, JoinThread (reap) |
| `join`           | CreateThread, JoinThread (park), ExitThread, JoinResume, DetachThread |
| `defer_safe`     | ExitThread (detached → deferred), ReapDeferredSafe |
| `proc_zombie`    | ExitThread (last thread), HarvestZombies |
| `defer_unsafe`   | ExitThread, HarvestZombies, ReapDeferredUnsafe (buried → live-count leak, finding MC1) |
| `mutex`          | LockAcquire, LockBlock, LockResume, Unlock, PutMutex |
| `condvar`        | WaitCondPark, SignalCond, CondResumeReacquire, CondInterrupt, PutCond |
| `sleep_wake`     | Sleep, Wake |
| `signals`        | Sigaction, Sigprocmask, Kill (handler + stop), AsyncDeliver, Sigreturn, Sigsuspend, ContinueProcess |
| `kill_terminate` | Kill (SIGKILL → whole-process terminate) |
| `fork_exec`      | Fork, ExecReplace, ExecRefuse |

--------------------------------------------------------------------------------------------------
## 4. Fidelity boundary (READ THIS before trusting a result)

The harness is faithful for everything the spec observes about a **single** thread/process object,
because those fields are read back off real transitions. A few quantities are, by necessity,
**world-tracked** (maintained by the harness per the modeled arithmetic) rather than read from a
real global:

- **`tlive` / `plive`.** The bare type-state transitions (`run`, `terminate`, `exit`, …) are
  self-contained control-block moves; they do **not** touch the process manager's global
  `thread_live_count` / `proc_live_count` (that bookkeeping lives in `ProcessManager`, which the
  bare-object harness deliberately does not drive). The counts are therefore maintained in
  `tla_world.rs` following exactly the base spec's arithmetic — including the intentional
  `ReapDeferredUnsafe`-after-burial leak (MC1). **Consequence:** `Acct` (the `tlive`/`plive` check)
  is largely *tautological* here — it confirms the emitted numbers match the model's arithmetic, not
  that the real global counter agrees. To make `Acct` load-bearing, extend the harness to create
  real manager-tracked threads and read `ProcessManager`'s real counters (see §6).
- **`deferred`, mutex/condvar wait queues (`muQ`,`coQ`), and the slot-exists flags (`muEx`,`coEx`).**
  Modeled as `Vec`/`bool` in the world. The mutex *ownership* (`muOw`) is backed by a real
  `MutexGuard`; the *queue* ordering and the `ex` destroy flags are world-tracked.
- **Signal-frame depth (`frLen`).** The user-stack signal frames are unobservable in the standalone
  UserVM, so their **depth** is world-tracked. The **mask** each frame saves/restores *is* applied
  for real on the thread's `blocked` state via `ThreadState::{set,take}_saved_blocked`.

None of these break validation (each scenario is a valid model trajectory), but a Phase-3 agent
hunting a *real* accounting/queue bug must be aware that those aggregates are modeled, not observed.

--------------------------------------------------------------------------------------------------
## 5. Build / run / validate

One command (from anywhere) applies the instrumentation, builds the test-kernel + UserVM, boots,
collects traces, and validates each against the spec:

```bash
bash harness/run.sh
```

Outputs:
- `traces/<scenario>.ndjson` — one file per scenario.
- Console `PASS`/`FAIL` per scenario.

Useful overrides: `ARTIFACT`, `TLA_JAR`, `CM_JAR`, `BUILD_TIMEOUT` (default 900s),
`BOOT_TIMEOUT` (default 180s). All build/boot commands are wrapped in `timeout`; a timeout is a
finding to investigate, not something to blindly retry.

Manual steps, if you need them:
- Apply only: `bash harness/apply.sh` (idempotent — it `git checkout`s the 3 tracked files first).
- Build: `make -C <artifact> all-test-kernel all-uservm`
- Boot: `<artifact>/bin/uservm.elf -kernel <artifact>/bin/kernel-test.elf -kernel-args "test_magic=0xDEADBEEF"`
  (success is the magic string `hello, world!`).
- Validate one file: copy it to `traces/trace.ndjson`, then from `spec/`
  `java -cp <tla2tools.jar>:<CommunityModules-deps.jar> tlc2.TLC -deadlock -config Trace.cfg Trace.tla`.

To revert the artifact to pristine: `git -C <artifact> checkout -- src/kernel/src/pm` and delete the
two copied modules (`tla_trace.rs`, `process/state/tla_world.rs`).

--------------------------------------------------------------------------------------------------
## 6. How to adjust the instrumentation

**Add a field to an existing action.** Find the action's `fn` in `tla_world.rs`, extend the
`self.emit("<Action>", |w| …)` closure to write the new key, and confirm the key/type matches the
`W_<Action>` wrapper in `Trace.tla`. Keep values streamed field-by-field (never build one big
`String` — the kernel slab heap rejects allocations > 512 bytes).

**Add a new scenario.** Write a `fn scenario_<name>() -> bool` that `boot!()`s a `World` and drives a
model-valid sequence (respect every base-action precondition — notably `Schedule` requires
`NoneRunning`, `Preempt` requires another ready thread, and `th[caller].st = "running"` for most
kcalls). Register it in `run_all()` with a preceding `tla_trace::emit_marker("<name>")`; `run.sh`
splits on that marker, so the name becomes the `.ndjson` stem.

**Add a new action wrapper (spec grew).** Add a driver `fn` that applies the real transition and
emits exactly the fields the new `W_*` wrapper reads, then exercise it from a scenario.

**Make `Acct` load-bearing (optional, higher-fidelity).** Replace the bare type-state objects with
threads/processes created and tracked through `ProcessManager`, and read the real
`thread_live_count` / `proc_live_count` for `tlive`/`plive`. This is a larger change (it must respect
the manager's slot allocation and cleanup), but removes the tautology noted in §4.

**Pitfalls.**
- `process/state/mod.rs` has `#![forbid(clippy::unwrap_used)]` / `expect_used`, which propagate into
  `tla_world`. Do not use `.unwrap()` / `.expect()`; use `unwrap_or`/`match`.
- The identity bijection (§2) is assumed everywhere — keep slot↔name mapping stable across a trace.
- Every scenario must start from `TraceInit`; do not carry state between scenarios.
- Do not modify `spec/Trace.tla`, `spec/Trace.cfg`, or `spec/base.tla` — they are the fixed oracle.
