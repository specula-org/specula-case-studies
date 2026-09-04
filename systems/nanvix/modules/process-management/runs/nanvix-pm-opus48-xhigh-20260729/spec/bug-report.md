# Bug Report — Nanvix Process Management (`src/kernel/src/pm`)

## Summary

- Scenarios tested: 7 (`MC_hunt_scenario1.cfg` … `MC_hunt_scenario7.cfg`)
- Target invariants: 11 (10 findings MC-1…MC-10; MC-10 carries two independent invariants, reported as Bug 10 and Bug 11)
- Bugs found: 11 (all Case C, confirmed against ground-truth Rust)
- Configs run: MC_hunt_scenario1..7.cfg. Because a bundled config stops at the first violated invariant, each target invariant was additionally run in an isolated per-invariant config (`spec/iso/iso_scenarioN_MC-*.cfg`) with deadlock detection disabled (the bounded MC specs terminate naturally, so deadlock detection must be off), producing one clean counterexample per finding under `spec/output/MC_hunt_MC-*.out`.
- Method: BFS. Every hunt config reached its target violation, so no simulation follow-up was required. Each counterexample was cross-referenced against the real implementation before classification.
- Spec adjustment during hunting: one Case B fidelity gap in `HarvestZombieProc` was fixed (see *Spec fixes during hunting* at the end). It did not affect any other finding; all 9 traces and the structural MC.cfg BFS still pass afterward.

The base spec models these mechanisms as bugs by design; the seven scenario invariants are enabled only in the hunt configs (kept out of `MC.cfg`). Convergence (`MC.cfg`: `TypeOK`, `SingleOwner`) passed exhaustively (2,910,732 distinct states, depth 26, no error), so the spec is trusted.

---

## Bug 1: Lost condvar/join notification to a sleeper embedded in an interrupted process

- **Scenario**: 1 (incomplete "where a blocked thread lives" wakeup search set)
- **Severity**: High
- **Invariant violated**: NoLostNotify
- **Config**: MC_hunt_scenario1.cfg (isolated: iso/iso_scenario1_MC-1.cfg)
- **Counterexample**: 10 states, `spec/output/MC_hunt_MC-1.out`

### Trace Summary
Build a process with two threads that both `Sleep` on condvar `c1`. An `AlarmFire` on one sleeper of a *suspended* process moves the whole process to the **interrupted** list while the sibling stays `sleeping` inside it (`from_sleeping`). `NotifyDequeue(c1)` then pops the still-sleeping sibling off the condvar FIFO, and `WakeDequeued` runs the real `try_wakeup` search — which scans only the suspended and ready lists, never the interrupted list — so the waiter is not found. The notification is consumed but the thread is never woken: `lostNotify = TRUE`.

### Root Cause
`ProcessManager::try_wakeup` (`process/manager/mod.rs:1880-1936`) searches `self.suspended` (line 1883) then `self.ready` (line 1910) and returns `None` otherwise; it never scans `self.interrupted`. `try_wakeup_thread` (`:1852`) checks the running process, then delegates to `try_wakeup`; on `None`, `do_wakeup` (`:1821`) returns `NoSuchEntry`. Meanwhile `Condvar::notify_first` already popped the waiter from the queue, so an untimed waiter embedded in an interrupted process is stranded forever.

### Affected Code
- `process/manager/mod.rs:1880-1936`: `try_wakeup` omits the interrupted list.
- `process/manager/mod.rs:1852-1878`: `try_wakeup_thread` has no interrupted-list fallback.
- `sync/condvar.rs` (`notify_first`): dequeues before the wake, so a failed wake loses the notification.

### Recommendation
Extend `try_wakeup` (and `interrupt_signal_candidate`, Bug 2) to also scan `self.interrupted`, or make `notify_first` re-enqueue / not consume the waiter when the wake fails.

---

## Bug 2: Caught signal never delivered to a sleeper in a non-suspended process

- **Scenario**: 1
- **Severity**: High
- **Invariant violated**: SignalReachesSafety (safety proxy for SignalReaches liveness)
- **Config**: MC_hunt_scenario1.cfg (isolated: iso/iso_scenario1_MC-2.cfg)
- **Counterexample**: 7 states, `spec/output/MC_hunt_MC-2.out`

### Trace Summary
Install a `handler` disposition for signal 1 on a process, `Sleep` its (only unmasked) thread so the process is Runnable/ready with an embedded sleeper, then `PostSignalHandler(p,1)`. `kill()` posts the signal to the pending set and calls `interrupt_signal_candidate`, which scans only the suspended list; the target is on the ready list, so no candidate is found and no thread is interrupted. `signalDeliveryFailed = TRUE` — the caught signal is never delivered.

### Root Cause
`ProcessManager::interrupt_signal_candidate` (`process/manager/mod.rs:1009-1018`) resolves the candidate only from `self.suspended` (line 1011). A runnable or interrupted process that holds the sole eligible (unmasked, caught) sleeper is skipped, and no other path interrupts it, so the signal is not delivered until the process happens to make an unrelated kernel call.

### Affected Code
- `process/manager/mod.rs:1009-1018`: `interrupt_signal_candidate` restricted to `self.suspended`.
- `process/manager/mod.rs:892-894`: `kill()` `PostAction::Interrupt` path relies on that scan.

### Recommendation
Search all lists that can hold a sleeper (suspended, ready, interrupted) for an eligible candidate when posting a caught signal.

### Repair (Phase 3 — RR-001, SPEC_REPAIR, CONSUMED)
Phase-4 confirmation judged this counterexample a **spec artifact**: the CE has an
UNMASKED ready sibling (`t3`) in the target process, which self-delivers the pending
caught signal at its own return-to-user checkpoint (`try_deliver_signal`, `signal.rs:242`;
`deliver_pending_signals`, `kcall/handler.rs:189`; design note `manager/mod.rs:1000-1002`).
`MCPostSignalHandler` was tightened so `signalDeliveryFailed` is set **only** when the
sole unmasked eligible thread is a sleeper in a non-suspended process AND no unmasked
ready/running/interrupted sibling exists to self-deliver. After the fix,
`iso/iso_scenario1_MC-2.cfg` explores the full state space with **no violation**
(`spec/output/MC_hunt_scenario1_MC-2_repair.out`), while MC-1 (NoLostNotify) still
violates in scenario1. The genuine stranding gap (every runnable sibling masks the signal,
only the sleeper is unmasked) remains detectable as a real `SignalReachesSafety` violation.

---

## Bug 3: Terminated/exited process resumes user code on a carried-forward interrupted thread

- **Scenario**: 2 (terminate/exit does not force-kill already-interrupted threads)
- **Severity**: High
- **Invariant violated**: TerminatedThreadsDie
- **Config**: MC_hunt_scenario2.cfg (isolated: iso/iso_scenario2_MC-3.cfg)
- **Counterexample**: 11 states, `spec/output/MC_hunt_MC-3.out`

### Trace Summary
A process is driven so one thread becomes `interrupted`/TimedOut (alarm), and the process is terminated while Runnable. `RunnableProcess::terminate` carries the already-interrupted thread forward **unchanged** (still TimedOut). After `ResumeInterrupted` and `Schedule`, the thread reaches the kcall-return checkpoint (`DispatcherCheckpoint`) where TimedOut maps to a normal return; `resumedAfterTerminate = TRUE` — the thread runs user code although `procTerminated[p] = TRUE`.

### Root Cause
`RunnableProcess::terminate` (`process/state/runnable.rs:165-203`) `take()`s `self.interrupted_threads` (lines 180-181) and re-attaches them unchanged (lines 192-193); only *sleeping* threads are folded to Killed. The correct `InterruptedProcess::terminate` (`process/state/interrupted.rs:110-125`, `:236`) forces every interrupted thread to Killed, but the Runnable-terminate and process-wide `RunningProcess::exit` paths do not. When such a thread is later resumed, `ProcessManager::sleep` (`process/manager/unsafe.rs:864-869`) returns `Interrupted(TimedOut)`, which `kcall/sleep.rs:64` maps to `Ok(())` (and `Signaled` → `EINTR`), returning to user code instead of exiting.

### Affected Code
- `process/state/runnable.rs:180-193`: interrupted threads carried forward with original reason.
- `process/manager/unsafe.rs:864-869`: `sleep()` surfaces the carried reason.
- `kcall/sleep.rs:64`: TimedOut → `Ok(())` (return to user).
- Contrast: `process/state/interrupted.rs:110-125` (correct force-Killed path).

### Recommendation
On the Runnable-terminate and process-exit paths, re-mark every interrupted thread `Killed` (mirroring `InterruptedProcess::terminate`) so the dispatcher checkpoint exits the thread.

---

## Bug 4: Kernel panic: do_exit dereferences the emptied running slot during rendezvous cleanup

- **Scenario**: 3 (`running == None` reentrancy in `do_exit`)
- **Severity**: Critical (reachable kernel panic / DoS)
- **Invariant violated**: RunningValidAtWakeup
- **Config**: MC_hunt_scenario3.cfg (isolated: iso/iso_scenario3_MC-4.cfg)
- **Counterexample**: 6 states, `spec/output/MC_hunt_MC-4.out`

### Trace Summary
A thread in another process (`t1` in `p2`) registers as a rendezvous counterpart blocked on the exiting process (`rvWaiter[t1] = p2`… targeting the exiter). The exiting process runs `do_exit`: `ExitTakeRunning` nulls `running` (`running = NoProc`, `exitPhase = "taken"`), then `ExitCleanupRendezvous` wakes the counterpart via `do_wakeup` → `try_wakeup_thread` → `get_running()`, which dereferences the empty running slot and panics: `panicked = TRUE`.

### Root Cause
`do_exit` (`process/manager/mod.rs:2103`) calls `take_running()` (`:2116`, sets `self.running = None`) and only *then* calls `cleanup_rendezvous` (`:2130`). `cleanup_rendezvous` (`:2766-2778`) calls `do_wakeup(tid)` for each orphaned counterpart; `try_wakeup_thread` (`:1852-1854`) starts with `self.get_running()`, and `get_running` (`:2785-2787`) is `self.running.as_ref().expect("the kernel should be running")` — which panics because `running` is `None`. `terminate()` is safe because it never nulls `running`.

### Affected Code
- `process/manager/mod.rs:2116`: `take_running()` empties `running` before cleanup.
- `process/manager/mod.rs:2130,2766-2778`: `cleanup_rendezvous` → `do_wakeup`.
- `process/manager/mod.rs:1854,2785-2787`: `try_wakeup_thread` → `get_running().expect(...)`.

### Recommendation
Perform `cleanup_rendezvous` before `take_running()`, or make the wakeup path tolerate an empty running slot (the exiting thread is not a valid wakeup target anyway).

---

## Bug 5: Spurious OutOfMemory: process admission rejected before reclaimable zombies are reaped

- **Scenario**: 4 (reclaimable slots not reaped before cap rejection)
- **Severity**: Medium (liveness / availability)
- **Invariant violated**: NoSpuriousOOM (safety proxy for AdmissionLiveness)
- **Config**: MC_hunt_scenario4.cfg (isolated: iso/iso_scenario4_MC-5.cfg)
- **Counterexample**: 4 states, `spec/output/MC_hunt_scenario4_MC-5_repair.out` (originally `spec/output/MC_hunt_MC-5.out`, before the RR-004 re-gating to the thread-cap defect)

### Trace Summary
With the system-wide thread cap reached and a terminated-but-unharvested zombie thread present (its slot reclaimable), `create_process` (and `do_execv`) reserve their main-thread slot with the non-reaping `try_next_tid` and return `OutOfMemory` even though reaping the zombie would free a slot (`spuriousOOM = TRUE`). The process-count cap (`:1139`) never binds first: `MAX_THREADS`(32) < `MAX_PROCESSES`(255) and every live process owns ≥1 live thread, so the thread cap is the binding constraint.

### Root Cause
`create_process` (`process/manager/mod.rs:1164`) and `do_execv` (`:2023`) reserve the new image's main-thread slot with the **non-reaping** `TheadManager::try_next_tid` (`thread/mod.rs:227`), which rejects with `OutOfMemory` when `live_count >= MAX_THREADS` without harvesting reclaimable zombies. The reap-then-retry variant `try_next_tid_reaping` (`:3410`, fix #2495, commit `a85226542`) is used only by `create_thread` (`:421`) and `duplicate_process` (`:1558`). So a thread slot held purely by a terminated-but-unharvested zombie is not reclaimed before the cap is enforced on the create_process / execv paths.

### Affected Code
- `process/manager/mod.rs:1164`: `create_process` non-reaping `try_next_tid` reservation.
- `process/manager/mod.rs:2023`: `do_execv` non-reaping `try_next_tid` reservation.
- Contrast `process/manager/mod.rs:3410` `try_next_tid_reaping` (reap-then-retry) used by `create_thread`/`duplicate_process`.

### Recommendation
Route the `create_process` and `do_execv` thread-slot reservations through `try_next_tid_reaping` (reap-then-retry once on `OutOfMemory`) so a reclaimable zombie is harvested before admission fails, mirroring fix #2495.

---

## Bug 6: cond_wait returns EINTR without re-holding the mutex

- **Scenario**: 5 (blocking-sync cancellation half-releases ownership)
- **Severity**: High (POSIX violation; enables data races in caller critical sections)
- **Invariant violated**: CondWaitReturnsLocked
- **Config**: MC_hunt_scenario5.cfg (isolated: iso/iso_scenario5_MC-6.cfg)
- **Counterexample**: 4 states, `spec/output/MC_hunt_MC-6.out`

### Trace Summary
A thread `LockMutexAcquire(m1)`, then `CondWaitUnlock(c1,m1)` drops the guard and parks. On wakeup the mutex reacquire is interrupted (`CondWaitRelockInterrupted`): `syncPc` returns to idle without re-taking the mutex; `condWaitBad = TRUE`. The caller returns EINTR believing it holds `m1`, but it does not.

### Root Cause
`wait_cond` (`kcall/wait_cond.rs`) releases the mutex at `take_mutex_guard` (`:105`), then after the wait reacquires with `let guard = mutex.lock(None)?;` (`:127`). The `?` propagates an interrupt/error and returns **without the mutex held**; the earlier `put_cond(cond_addr)?` (`:123`) can likewise early-return before the reacquire. POSIX requires `pthread_cond_wait` to return with the mutex locked even on error.

### Affected Code
- `kcall/wait_cond.rs:123`: `put_cond(...)?` early return before reacquire.
- `kcall/wait_cond.rs:126-128`: reacquire `mutex.lock(None)?` can return unlocked.

### Recommendation
Guarantee the mutex is reacquired before returning from `wait_cond` on every path (retry the lock unconditionally, or re-lock before propagating the error).

---

## Bug 7: Orphaned mutex-map slot after an interrupted cond_wait reacquire

- **Scenario**: 5
- **Severity**: Medium (resource/accounting leak; shares root cause with Bug 6)
- **Invariant violated**: SyncSlotConservation
- **Config**: MC_hunt_scenario5.cfg (isolated: iso/iso_scenario5_MC-7.cfg)
- **Counterexample**: 4 states, `spec/output/MC_hunt_MC-7.out`

### Trace Summary
Same path as Bug 6 (`LockMutexAcquire → CondWaitUnlock → CondWaitRelockInterrupted`). Afterward the mutex-map entry for `m1` is still present (`mutexInMap[m1] = TRUE`) while the mutex is unlocked, unowned, held by no thread, and no in-flight `cond_wait` is reacquiring it — an orphaned slot.

### Root Cause
`wait_cond` reclaims the map entry only implicitly via the caller's later `unlock_mutex` → `put_mutex` (`process/state/mod.rs:652-666`, the only reclaimer, which removes an entry when `reference_count() <= 2`). When the reacquire is interrupted (Bug 6), the caller does **not** hold the guard, so its subsequent `unlock_mutex` is rejected as a foreign/double unlock and never calls `put_mutex`; the entry lingers, counting against `MUTEX_OPEN_MAX` until the process exits and is reaped. `lock_mutex` cancellation (`kcall/lock_mutex.rs`) is the analogous site — a timed-out/interrupted `mutex.lock(timeout)?` returns before `put_mutex`, orphaning the entry `get_mutex` created — but it requires a contended lock (two threads), which scenario5 (`CreateThreadLimit=0`) cannot set up, so TLC surfaces the equivalent leak through the reachable `cond_wait` path.

### Affected Code
- `kcall/wait_cond.rs:126-128`: interrupted reacquire leaves the entry orphaned and unreleasable by the caller.
- `kcall/lock_mutex.rs`: cancelled `mutex.lock(timeout)?` returns without `put_mutex` (same leak, needs contention).
- `process/state/mod.rs:652-666`: `put_mutex` is the sole reclaimer and is only reached from a successful unlock.

### Recommendation
Fixing Bug 6 (always reacquire) also fixes this leak. Additionally, ensure every cancellation path in `lock_mutex`/`wait_cond` releases the `get_mutex` reference (call `put_mutex`) on error.

### Repair (Phase 3 — RR-002, SPEC_REPAIR, CONSUMED)
Phase-4 confirmation judged the orphaned-slot counterexample a **spec artifact**:
`CondWaitUnlock` was the only unlock path that did **not** model `put_mutex`
(`process/state/mod.rs:652-666`, reached on every unlock via `remove_mutex_guard`,
`manager/mod.rs:2635`, including the cond_wait initial unlock at `wait_cond.rs:105`).
Because a `MutexGuard` holds its own `Arc` clone (`sync/mutex.rs:142-144`), a sole-holder
waiter satisfies `reference_count() <= 2` at the initial unlock and the entry is removed;
the reacquire then re-creates a fresh entry via `get_mutex` (`wait_cond.rs:126`).
`CondWaitUnlock` now reclaims the map entry exactly like `UnlockMutex`
(`mutexInMap' = IF mutexExtraRef THEN TRUE ELSE FALSE`) and `CondWaitRelock` re-inserts it,
so an interrupted single-thread reacquire can no longer strand an in-map/unlocked/unowned
/unheld slot. After the fix, `iso/iso_scenario5_MC-7.cfg` explores the full state space with
**no violation** (`spec/output/MC_hunt_scenario5_MC-7_repair.out`). The genuine leak
(`lock_mutex` cancellation → `mutexExtraRef`) still violates `SyncSlotConservation` where
contention is modeled. Bug 6 (CondWaitReturnsLocked) is out of this request's scope and
still violates in scenario5 (`iso/iso_scenario5_MC-6.cfg`).

---

## Bug 8: Blockable default-Terminate signal ignores the per-thread mask

- **Scenario**: 6 (signal pending/mask/disposition/lifecycle consistency)
- **Severity**: Medium-High (POSIX masking violation; can kill a process that blocked the signal)
- **Invariant violated**: MaskHonored
- **Config**: MC_hunt_scenario6.cfg (isolated: iso/iso_scenario6_MC-8.cfg)
- **Counterexample**: 6 states, `spec/output/MC_hunt_MC-8.out`

### Trace Summary
The target's only thread masks signal 1 (`MaskChange` → `blocked = {1}`) and sleeps. `PostSignalDefaultTerminate(p,1)` (default disposition, Terminate action) terminates the target anyway — `maskViolated = TRUE` — even though every eligible thread has the signal blocked.

### Root Cause
`kill()` (`process/manager/mod.rs:810`) maps a `SignalDisposition::Default` whose `default_action` is `Terminate`/`Core` to `PostAction::Terminate` (`:858-866`) and calls `kill_terminate` unconditionally (`:892-893`) without consulting any thread's blocked mask. Only the `Handler` path (`:854-856`) posts to pending (later mask-gated at delivery). SIGKILL is handled separately (`:842`), so this affects ordinary blockable signals whose default action is fatal, which POSIX allows to be blocked and left pending.

### Affected Code
- `process/manager/mod.rs:858-866`: default fatal actions resolve to `PostAction::Terminate`.
- `process/manager/mod.rs:892-893`: `PostAction::Terminate` → `kill_terminate`, no mask check.

### Recommendation
For non-uncatchable signals with a default fatal action, honor the per-thread mask: if blocked by all eligible threads, leave the signal pending instead of terminating.

---

## Bug 9: Immortal pending signal after a disposition change

- **Scenario**: 6
- **Severity**: Medium
- **Invariant violated**: NoImmortalPending
- **Config**: MC_hunt_scenario6.cfg (isolated: iso/iso_scenario6_MC-9.cfg)
- **Counterexample**: 5 states, `spec/output/MC_hunt_MC-9.out`

### Trace Summary
Install a `handler` for signal 1, `PostSignalHandler(p,1)` (bit set in pending), then `SetDisposition(p,1,default|ignore)`. The pending bit is left set; `immortalPending = TRUE`. `try_deliver_signal` will skip it forever (no longer a handler) and nothing clears it.

### Root Cause
`sigaction` (`process/manager/mod.rs:583-605`) calls `SignalControl::set_disposition` (`:605`), and `set_disposition` (`process/state/signal.rs:364-370`) only replaces the disposition slot — it never clears a pending instance. `try_deliver_signal` (`process/manager/signal.rs:243-254`) delivers only `Handler` dispositions and leaves others pending (`:251-252`). So a signal posted while caught, then re-dispositioned to Default/Ignore, is neither delivered nor discarded. POSIX requires SIG_IGN (and SIG_DFL for ignore-default signals) to discard pending instances.

### Affected Code
- `process/state/signal.rs:364-370`: `set_disposition` does not clear pending.
- `process/manager/mod.rs:605`: `sigaction` install path.
- `process/manager/signal.rs:243-254`: delivery skips non-handler pending signals.

### Recommendation
When `sigaction` sets a disposition to Ignore (or Default with an ignore/no-op default), clear the corresponding pending bit.

---

## Bug 10: Nested sigsuspend overwrites the single saved-mask slot

- **Scenario**: 7 (sigsuspend/sigreturn/SA_RESTART reentrancy)
- **Severity**: Medium
- **Invariant violated**: SavedMaskRestored
- **Config**: MC_hunt_scenario7.cfg (isolated: iso/iso_scenario7_MC-10a.cfg)
- **Counterexample**: 4 states, `spec/output/MC_hunt_MC-10a.out`

### Trace Summary
`SigSuspendInstall(mask_A)` saves the pre-suspend mask into `saved_blocked`; a nested `SigSuspendInstall(mask_B)` (from a handler running before the outer `sigreturn`) overwrites it. `savedMaskViolated = TRUE` — the original pre-suspend mask is lost, so the outer `sigreturn` will restore the wrong value.

### Root Cause
`install_sigsuspend_mask` (`process/manager/mod.rs:722-749`) unconditionally `state.set_saved_blocked(Some(previous))` (`:734`) into `ThreadState.saved_blocked`, which is a single `Option<u64>` (`thread/state.rs:105`). A single slot cannot represent two nested in-flight sigsuspend/handler contexts, so nesting corrupts the outer save.

### Affected Code
- `process/manager/mod.rs:734`: overwrites `saved_blocked` without checking for an existing save.
- `thread/state.rs:105`: `saved_blocked: Option<u64>` — single slot.

### Recommendation
Stack the saved masks (e.g., a per-thread stack keyed by signal frame), or carry the pre-suspend mask in the signal frame that `sigreturn` restores, so nested contexts do not clobber each other.

---

## Bug 11: SA_RESTART applied per the delivered signal, not the interrupting one

- **Scenario**: 7
- **Severity**: Medium
- **Invariant violated**: RestartAttribution
- **Config**: MC_hunt_scenario7.cfg (isolated: iso/iso_scenario7_MC-10b.cfg)
- **Counterexample**: 5 states, `spec/output/MC_hunt_MC-10b.out`

### Trace Summary
A blocking call is interrupted and a signum-less restart record is set (`MarkInterruptedBySignal`; `restart[t]=TRUE`, `intrSig[t]=s_a`). At delivery, the lowest pending caught signal `s_b ≠ s_a` is delivered and *its* SA_RESTART flag decides whether the call restarts: `restartMisattributed = TRUE`.

### Root Cause
`try_deliver_signal` (`process/manager/signal.rs:206-316`) consumes the restart record via `take_restart()` (`:220`), which carries only the interrupted call's number/args — **no signal number** (`KcallRestart`, `thread/state.rs`). It selects the lowest deliverable caught signal (`:240-254`) and applies restart based on that signal's `sa_flags & SA_RESTART` (`:280-283`), regardless of whether it is the signal that actually interrupted the call. So a call interrupted by a non-SA_RESTART signal can be transparently restarted (or vice versa) when a different signal is delivered first.

### Affected Code
- `process/manager/signal.rs:220`: signum-less `take_restart`.
- `process/manager/signal.rs:240-254,280-283`: restart decision uses the delivered signal's flags.
- `thread/state.rs` (`KcallRestart`): record lacks the interrupting signal number.

### Recommendation
Record the interrupting signal number in `KcallRestart` and apply SA_RESTART only when the delivered signal equals the interrupting one (matching Linux semantics).

### Repair (Phase 3 — RR-003, INVARIANT, CONSUMED — property removed)
Phase-4 confirmation judged this an **invariant artifact**, not a real bug. The violated
property (restart attributed to a separately-tracked "interrupting signal" `intrSig`
distinct from the delivered one) is promised by neither POSIX/Linux nor the implementation:
`try_deliver_signal` selects the **lowest-numbered deliverable caught** signal
(`signal.rs:240-254`) and applies SA_RESTART from **that delivered** signal's flags
(`:280-283`), exactly as Linux `get_signal`/`handle_signal` does; the signum-less
`KcallRestart` record (`thread/state.rs:57-62`) carries no signal number to attribute
against. Because the delivered-signal SA_RESTART behavior holds by construction, there is
no falsifiable non-vacuous oracle, so `RestartAttribution`/`MCRestartAttribution` were
**removed** rather than replaced with a vacuous predicate: unwired from
`MC_hunt_scenario7.cfg`, definitions deleted from `base.tla`/`MC.tla`, and the
`restartMisattributed` oracle assignment dropped from `DeliverSignal` (the
`restart`/`intrSig`/`MarkInterruptedBySignal` machinery is retained inert only because the
`MarkInterruptedBySignal` trace event and the `restartMisattributed` trace field require
the declarations for trace validation). MC-10a (SavedMaskRestored) still violates in
scenario7 (`iso/iso_scenario7_MC-10a.cfg`). This property is now marked not-applicable in
`brief-coverage.md`.

### Repair (Phase 3 — RR-007, INVARIANT, CONSUMED — re-confirmed removal; no further change)
Phase-4 re-confirmation re-raised this same artifact (RR-007, seeded from RR-003/RR-006).
Re-audited against the implementation: `KcallRestart` is signum-less (`thread/state.rs:57-62`)
and `try_deliver_signal` applies SA_RESTART from the DELIVERED lowest-numbered deliverable
caught signal's `sa_flags` (`signal.rs:220,240-254,280-283`) — POSIX/Linux ERESTARTSYS — so
there is no "interrupting signal" to attribute against. RR-007's suggested delivered-signal
oracle ("restart iff the delivered caught signal has SA_RESTART and a record is present")
holds by construction in `DeliverSignal`, i.e. it would be a tautological/vacuous oracle that
no modeled transition can ever falsify — forbidden as fake coverage — so removal (not vacuous
replacement) remains the correct terminal outcome. Removing the retained inert
`intrSig`/`restartMisattributed`/`MarkInterruptedBySignal` declarations stays UNSOUND: the
trace corpus contains a `MarkInterruptedBySignal` event (`traces/signal_disposition.ndjson`)
and a `restartMisattributed` field in every record (63 across 9 traces), which Trace.tla
reads. No further spec change. Re-validation: all 9 traces PASS; isolated MC-10b config
(`iso/iso_scenario7_MC-10b.cfg`) BFS is clean (1740 distinct states, depth 9, no error);
`MC_hunt_scenario7.cfg` shows only the separate, out-of-scope MC-10a `MCSavedMaskRestored`
violation and **no** `RestartAttribution` violation (that invariant no longer exists).

---

## Not Reproduced

| Scenario | Config | Result |
|----------|--------|--------|
| — | — | All 7 scenarios / 11 target invariants reproduced their bug. |

The only non-reproduction was a **spurious** counterexample that was corrected as a spec-fidelity fix, not a real bug (below).

## Spec fixes during hunting

- **`HarvestZombieProc` (Case B fidelity gap).** Before the fix, TLC reproduced SyncSlotConservation (Bug 7) via a process that acquired a mutex, exited, and was reaped, leaving `mutexInMap = TRUE`. Ground truth: `harvest_zombies` (`process/manager/mod.rs:3430`) takes the `Box<ProcessState>` returned by `pop_zombie_process` (`:2441-2449`) and drops it at end of scope, freeing the process's entire `mutexes` `BTreeMap`. The spec did not model that, so it flagged a leak that cannot occur. Fix: `HarvestZombieProc` now clears `mutexInMap`/`mutexExtraRef` for the harvested process's mutexes. After the fix the spurious path is gone and Bug 7 reproduces via the genuine `cond_wait` interrupted-relock path (same root cause as Bug 6). Re-validation: all 9 traces pass; `MC.cfg` structural BFS passes exhaustively (2,910,732 distinct states, depth 26, no error).
- **`Trace.tla` `TraceDone`** (trace-harness only, recorded in `changelog.md`): added a terminal stuttering step so the trace-consumed accepting state does not deadlock under the validator's default deadlock detection. Does not affect the model-checked base/MC specs.
