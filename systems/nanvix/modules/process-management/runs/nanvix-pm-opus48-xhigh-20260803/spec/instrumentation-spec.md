# Instrumentation Spec — Nanvix Process Management

Context handoff from spec generation to instrumentation. It defines the trace-event
schema consumed by `Trace.tla` and maps every base-spec action to the `src/kernel/src/pm`
source location(s) where the event must be emitted. There is a strict **1:1**
correspondence: one base action ⇄ one trace-event name ⇄ one instrumentation point family.

All line numbers are relative to `nanvix/nanvix  src/kernel/src/pm/**` and were taken from
the anchors already recorded in `base.tla` (which mirror the modeling brief). Confirm exact
lines against the working tree before patching — they drift with edits.

---

## Section 1 — Trace Event Schema

The trace is a single NDJSON file (`../traces/trace.ndjson`), one JSON object per line,
in the total order in which the atomic kernel calls commit (single-core, interrupts
disabled → observable PM events are totally ordered). `Trace.tla` reads it with
`ndJsonDeserialize` and walks it with the linear cursor `l`.

### Event envelope (every event)

| Key | Type | Meaning |
|---|---|---|
| `action` | string | base-action name (see Section 2); selects the `Trace.tla` wrapper |
| `tlive` | int | `thread_live_count` **after** the call (validated every event) |
| `plive` | int | `proc_live_count` **after** the call (validated every event) |

### Identity mapping (harness responsibility)

The harness must emit **stable slot names**, not raw kernel pointers/ids:
- process → `"p1".."pN"` (a fixed bijection from `ProcessIdentifier` to slot name for the
  run), thread → `"t1".."tN"` (from `ThreadIdentifier`), mutex → `"mx1"..`, cond → `"cv1"..`.
- absent reference (null owner / no target) → the string `"NULL"`.
- signal numbers are emitted as integers (`1,9,15,19`), signal sets as JSON arrays of ints.
- disposition → one of `"default" | "ignore" | "handler"`.

`Trace.cfg` declares these constants as the same strings, so mapping is by identity.
The bijection must be **stable for the whole trace** (a reused slot after reap keeps its
name) so the cursor sees a consistent state machine.

### State fields (per-action, post-state)

Captured **after** the call commits. Ghost/model-only state (`g.*`, the per-thread
pre-suspend ghost `ps`, and the reap counter `rp`) is **not** observable and **not**
emitted. Field-name ⇄ TLA+ mapping:

| Field | TLA+ post-state | Type |
|---|---|---|
| `tSt`,`ntSt`,`ctidSt`,`callerSt`,`uSt` | `th'[x].st` for the named thread | string |
| `ntPr`,`ctidPr` | `th'[x].pr` | proc name |
| `uDet` | `th'[u].det` | bool |
| `tBl` | `th'[t].bl` (blocked mask) | array of int |
| `frLen` | `Len(th'[t].fr)` (signal-frame depth) | int |
| `pSt`,`cpSt` | `pr'[p].st` | string |
| `pSp` | `pr'[p].sp` (stopped flag) | bool |
| `pPd` | `pr'[p].pd` (process pending set) | array of int |
| `dpS` | `pr'[p].dp[s]` (disposition of `s`) | string |
| `muOw` | `mu'[m].ow` (owner, or `"NULL"`) | thread name / `"NULL"` |
| `muQ` | `mu'[m].q` (wait queue) | array of thread names |
| `muEx` | `mu'[m].ex` (slot exists) | bool |
| `coQ` | `co'[c].q` | array of thread names |
| `coEx` | `co'[c].ex` | bool |
| `deferred` | `deferred'` (deferred-reap set) | array of thread names |

---

## Section 2 — Action-to-Code Mapping

One row per base action. **Trigger** = when to snapshot: "commit" = right after the call's
state mutation completes; "yield" = at the block/enqueue point just before the thread
deschedules. Args = event keys carrying the action parameters.

| # | Action / event `action` | Code location(s) | Trigger | Args | Post-state fields |
|---|---|---|---|---|---|
| 1 | `Schedule` | `manager/mod.rs:1658-1936` (pick ready non-stopped, `1671-1692`; `runnable.rs:141-149`) | after switch-in | `t` | `tSt` |
| 2 | `Preempt` | tick→`giveup`→`schedule` (timer preemption path) | after requeue | `t` | `tSt` |
| 3 | `CreateThread` | `manager/mod.rs:402-467`; admit `try_next_tid_reaping 3410-3425`; commit `thread/mod.rs:261`; cap `thread/mod.rs:227` | commit | `caller`,`nt`,`det` | `ntSt`,`ntPr`,`deferred` |
| 4 | `Fork` | `manager/mod.rs:1485-1642`; commit `1621-1638` | commit | `caller`,`cp`,`ctid` | `cpSt`,`ctidSt`,`ctidPr`,`deferred` |
| 5 | `ExecRefuse` | `do_execv manager/mod.rs:1973-2083`; non-healing `try_next_tid 2022-2023` | at refusal | `caller` | — (accounting only) |
| 6 | `ExecReplace` | `do_execv` success `1973-2083`; `reset_for_exec` | commit | `caller`,`nt` | `ntSt`,`callerSt`,`pPd` |
| 7 | `ExitThread` | `do_exit_thread` (`unsafe.rs`; `running.rs:367-382`) | commit (before switch) | `t` | `tSt`,`pSt`,`deferred` |
| 8 | `JoinThread` | `try_join_thread running.rs:541-621` | commit (park or reap) | `caller`,`u` | `callerSt`,`uSt` |
| 9 | `JoinResume` | joiner re-check on resume `running.rs:541-621` | commit | `caller` | `callerSt`,`uSt` |
| 10 | `DetachThread` | `do_detach_thread manager/mod.rs:2513` | commit | `caller`,`u` | `uSt`,`uDet` |
| 11 | `HarvestZombies` | `harvest_zombies mod.rs:3430`; idle harvest `kcall/handler.rs:79-82,155-163`; `on_thread_reaped` | commit (after bury) | `p` | `pSt` |
| 12 | `ReapDeferredSafe` | `reap_deferred_zombie_threads mod.rs:3330-3391` (`on_thread_reaped 3387`) | commit | `t` | `tSt`,`deferred` |
| 13 | `ReapDeferredUnsafe` | `reap_deferred`→`harvest_zombie_thread unsafe.rs:610-709` (early-return `668`, normal `708`) | commit | `t` | `tSt`,`deferred` |
| 14 | `LockAcquire` | `Mutex::lock` fast path (`mutex.rs`); guard store `thread/state.rs:82` | commit | `t`,`m` | `muOw` |
| 15 | `LockBlock` | `Mutex::lock` contended (`mutex.rs`) | yield (after enqueue) | `t`,`m` | `tSt`,`muQ` |
| 16 | `LockResume` | `Mutex::lock` re-check on wake (`mutex.rs`) | commit | `t`,`m` | `tSt`,`muOw` |
| 17 | `Unlock` | `MutexGuard::drop`/`unlock_unchecked mutex.rs:200-206` | commit | `t`,`m` | `muOw` |
| 18 | `PutMutex` | `get/put_mutex state/mod.rs:608-713` | commit | `caller`,`m` | `muEx` |
| 19 | `WaitCondPark` | `wait_cond kcall/wait_cond.rs:65-131` | yield (after release+enqueue) | `t`,`c`,`m` | `tSt`,`coQ`,`muOw` |
| 20 | `SignalCond` | `Condvar::notify_first condvar.rs` (`387a1a6ae`) | commit | `caller`,`c` | `coQ` |
| 21 | `CondResumeReacquire` | reacquire `wait_cond.rs:125-130` | commit | `t` | `tSt`,`muOw` |
| 22 | `CondInterrupt` | skip-stale-condvar-waiters (`6055a7366`) | commit | `t` | `tSt`,`coQ` |
| 23 | `PutCond` | `get/put_cond state/mod.rs:638-713`; `Condvar::drop condvar.rs:286` | commit | `caller`,`c` | `coEx` |
| 24 | `Sleep` | `do_sleep` | yield | `t` | `tSt` |
| 25 | `Wake` | `do_wakeup`/`try_wakeup` | commit | `t` | `tSt` |
| 26 | `Kill` | `kill`/signal-post `manager/mod.rs:810-899`; `find_process 2824-2852`; default `858-897` | commit | `caller`,`p`,`s` | `pSt`,`pSp`,`pPd` |
| 27 | `ContinueProcess` | `continue_process` | commit | `caller`,`p` | `pSp` |
| 28 | `Sigaction` | `sigaction manager/mod.rs:583-614` (no pending-clear `603-611`) | commit | `caller`,`p`,`s`,`nd` | `dpS` |
| 29 | `Sigprocmask` | `sigprocmask manager/mod.rs:642-668` | commit | `t`,`nm` | `tBl` |
| 30 | `AsyncDeliver` | kcall-return delivery `dispatcher.rs:240-247`; select `state/signal.rs:240-268` | commit (after frame push) | `t` | `tBl`,`frLen`,`pPd` |
| 31 | `Sigsuspend` | `install_sigsuspend_mask manager/mod.rs:722-749` | commit | `t`,`tempmask` | `tBl` |
| 32 | `Sigreturn` | `sigreturn_restore state/signal.rs:546-618` (`take_saved_blocked 607-610`); precedence `manager/mod.rs:733-735` | commit | `t` | `tBl`,`frLen` |

---

## Section 3 — Special Considerations

1. **Post-state snapshot timing.** Emit the event *after* the kernel call's state mutation
   is committed (for blocking calls #15/#19/#24, after the thread is enqueued and marked
   `sleeping` but before the actual context switch — the switch itself is the next
   `Schedule` event). Snapshotting before the mutation makes `Trace.tla`'s post-state
   checks fail spuriously.

2. **Two divergent reap paths must be distinct events.** `ReapDeferredSafe` (#12,
   `reap_deferred_zombie_threads`, always calls `on_thread_reaped`) and
   `ReapDeferredUnsafe` (#13, `harvest_zombie_thread`, early-returns at `unsafe.rs:668`
   when the process is buried) are separate `action` names. The instrumentation must tag
   which drain path ran — this is exactly the MC1/MC3 divergence, so conflating them
   defeats the purpose. Emit `tlive` as the **actual** post-call live count (a real leak
   surfaces as `tlive'` not decremented, which the base action reproduces).

3. **Scheduling / preemption events.** `Schedule` (#1) is emitted once a ready,
   non-stopped thread has been switched in; `Preempt` (#2) when a running user thread is
   requeued by the timer. These are the only two interleaving points in the model, so they
   must be instrumented even though they are not kcalls.

4. **Idle harvest vs entry-point reap ordering.** `HarvestZombies` (#11) fires both from
   the idle loop (`kcall/handler.rs:79-82,155-163`) and inline; both map to the same event.
   The *ordering* of a `HarvestZombies` (burial) event relative to a later
   `ReapDeferredUnsafe` event on the same target is the MC1 precondition — preserve the
   real commit order in the file.

5. **Signal accounting is per-process here.** `pPd` captures `pr[p].pending` (the
   process-level pending set). The model folds thread-level pending into async delivery
   selection; if the implementation carries a separate per-thread pending bitmap, emit its
   union into `pPd` at #26/#30 so the observable "still pending" set matches.

6. **Ghost fields are never emitted.** The finding witnesses (`execRefused`, `joinLost`,
   `maskedActed`, `sigToZombie`, `maskRestoreBad`, `destroyWaiter`, `condNoReacq`,
   `selfstopwin`, `rollbackLeak`), the per-thread `ps`, and `rp` are model bookkeeping. Do
   **not** add capture fields for them; the base action recomputes them internally during
   replay, and `Trace.tla` deliberately does not validate them.

7. **Bootstrap state.** `TraceInit` equals the base `Init`: one alive process (`p1`) with a
   single running thread (`t1`), `tlive = plive = 1`, all mutex/cond slots existing and
   free, empty deferred set. Begin the trace at the first PM event after boot reaches this
   state. If the real bootstrap differs (e.g., an idle/init thread already present), adjust
   `TraceInit` and the slot bijection accordingly before capturing.

8. **Slot reuse.** When a reaped thread/process slot is recycled by a later
   create/fork/exec, the harness must assign it a **fresh** slot name if the model treats
   it as a new entity (the base spec's `Thread`/`Proc` are fixed finite sets, so size the
   run's constant sets to the peak concurrent population, not the cumulative count).
