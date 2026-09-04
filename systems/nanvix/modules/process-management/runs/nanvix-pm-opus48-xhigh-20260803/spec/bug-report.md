# Bug Report — Nanvix Process Management

## Summary

- Scenarios tested: 5 (lifecycle/accounting, join/exec admission, mutex/condvar
  destroy + liveness, signals, rollback), driven by 16 hunt configs plus the base
  structural model and 11 replayed traces.
- Bugs found: 7 confirmed real implementation defects (Bugs 2–8 below). Four earlier
  candidates (former Bugs 1, 9, 10, 11 = findings MC-1/9/10/11) were re-judged by the
  confirmation phase as **spec over-approximations** (SPEC_REPAIR) and repaired in the
  confirmation back-edge round; their invariants now hold. See *Repaired Spec Artifacts*
  below and `changelog.md` (Round 3).
- Configs run: `MC.cfg` (structural), `MC_hunt_scenario1.cfg`,
  `MC_hunt_scenario2_{mc1,mc2,mc9,live}.cfg`,
  `MC_hunt_scenario3_{mc3,destroy,cond,live}.cfg`,
  `MC_hunt_scenario4_{mc4,mc5,mc6,mc7,mc8,live}.cfg`, `MC_hunt_scenario5.cfg`.
- Convergence: the base spec + 11 traces converged with zero changes in Round 1.
  During bug hunting a spec-fidelity gap in the *mutex release/wake* model was found
  and fixed (Round 2 / 2b in `changelog.md`); this removed one false-positive safety
  counterexample and a spurious self-deadlock lasso without disturbing any real
  finding. In Round 3 (confirmation back-edge) four findings were reclassified as spec
  artifacts and repaired (five `base.tla` guards); the seven bugs below reproduce
  against the corrected, trace-faithful spec.

All line numbers refer to `source/src/kernel/src/pm/`. Ground truth is the Rust
implementation and its real call graph.

---

## Bug 2: A waiting joiner can receive `ThreadNotFound` instead of the exit status

- **Scenario**: 2 (join lifecycle)
- **Severity**: High
- **Invariant violated**: `JoinGetsStatus`
- **Config**: `MC_hunt_scenario2_mc2.cfg`
- **Counterexample**: 9 states, `spec/output/MC_hunt_scenario2_mc2_final.out`

### Trace Summary

Thread `A` calls join on target `T`. `T` is still running, so `A` blocks as a joiner.
`T` exits and becomes a joinable zombie. Before `A` is resumed with `T`'s status, a
second reap path consumes/relocates `T`'s zombie record. When `A` is finally scheduled,
the lookup for `T` fails and `A` is handed a `ThreadNotFound`-class error rather than
`T`'s retained exit status — the status is lost and the join reports a spurious failure.

### Root Cause

`try_join_thread` (`process/state/running.rs:541-621`) and `join_thread`
(`process/manager/unsafe.rs:742-768`) do not atomically bind the woken joiner to the
zombie's retained status. A concurrent reap/harvest of the same target between the
joiner blocking and resuming removes the record the resumed joiner re-looks-up, so the
resume path resolves the target as missing instead of consuming the status that join is
contractually required to deliver.

### Affected Code

- `process/state/running.rs:541-621`: `try_join_thread` block/resume path.
- `process/manager/unsafe.rs:742-768`: `join_thread` reap/status handoff.

### Recommendation

Capture the target's exit status into the joiner at the moment the joiner is enqueued
(or hand ownership of the zombie record to the joiner), so a resumed joiner never
re-resolves the target and can never observe `ThreadNotFound` for a thread it was
already waiting on.

---

## Bug 3: A mutex owned by a never-joined zombie is held forever (blocks all waiters, incl. condvar reacquire)

- **Scenario**: 3 (mutex/condvar liveness) — covers modeling-brief MC3 **and** MC10
- **Severity**: High
- **Property violated**: `MutexProgress` (liveness)
- **Config**: `MC_hunt_scenario3_live.cfg`
- **Counterexample**: 6-state lasso, `spec/output/MC_hunt_scenario3_live_final.out`

### Trace Summary

Thread `t1` acquires mutex `mx1`, then exits **without being detached** — becoming a
*joinable* zombie whose process `p1` is still alive. Per the POSIX retention contract,
a joinable zombie of a live process is retained until an explicit `pthread_join`; it is
never auto-reaped. No join ever occurs. Thread `t2` then calls lock on `mx1`, finds it
owned by `t1`, and blocks (`sleeping`, `bk=mutex`). The lasso stutters forever: `mx1`
stays `ow=t1`, `t2` is parked indefinitely. `MutexProgress` (every thread parked on a
mutex eventually stops being parked) is violated.

The mutex guard is only released when the zombie's `ThreadState` is dropped at
*harvest* time. Since a joinable-never-joined zombie is never harvested, the guard —
and therefore the lock — is held for the lifetime of the process. Any subsequent
`Mutex::lock` waiter blocks forever. **MC10** is the condition-variable instantiation
of the same defect: `wait_cond` reacquires the mutex via `lock(None)`
(`sync/wait_cond.rs:127`), so a condvar waiter attempting to reacquire a lock held by
such a zombie also blocks forever.

### Root Cause

The `MutexGuard` lives inside `ThreadState.locked_mutexes: BTreeMap<_, MutexGuard>`
(`thread/state.rs:83`). It is released only when the `ThreadState` is dropped, which
happens exclusively in `harvest_zombie_thread` (`process/manager/unsafe.rs:657`). Thread
exit/kill do **not** release owned mutexes; they only move the thread to zombie. A
joinable thread is harvested only on `pthread_join`, so if the owner dies holding a
mutex and is never joined, `unlock_unchecked` is never reached and the lock is orphaned.
Condvar reacquire (`sync/wait_cond.rs:127`) inherits the same starvation.

### Affected Code

- `thread/state.rs:83`: `locked_mutexes` holds the guards that gate release on drop.
- `process/manager/unsafe.rs:657`: the only site that drops `ThreadState` (releases guards).
- `sync/wait_cond.rs:127`: condvar reacquire via `lock(None)` inherits the block (MC10).

### Recommendation

Release a dying thread's owned mutexes (and wake their waiters) at thread-exit/kill
time rather than deferring to harvest, or force-harvest owned-mutex zombies. Holding a
kernel mutex hostage to an application `pthread_join` lets one thread's failure to be
joined permanently deadlock unrelated threads (including condvar users).

---

## Bug 4: A masked default-action signal is acted upon while masked

- **Scenario**: 4 (signal masking)
- **Severity**: High
- **Invariant violated**: `MaskedSignalDeferred`
- **Config**: `MC_hunt_scenario4_mc4.cfg`
- **Counterexample**: 3 states, `spec/output/MC_hunt_scenario4_mc4_final.out`

### Trace Summary

A signal whose disposition is the **default action** is delivered to a process/thread
in which that signal number is currently **masked** (blocked). The default action is
taken immediately instead of being deferred until the mask is cleared. The witness
`g.maskedActed` is set: an action fired for a signal that every eligible thread had
blocked.

### Root Cause

The signal-dispatch path (`process/manager/mod.rs:858-875`) consults the mask only on
the caught/handler branch; for the default-action branch it proceeds without checking
whether the signal is blocked in the target thread(s). POSIX requires the mask to defer
*all* deliverable signals (default actions included, except the un-blockable ones), not
just handler dispatch.

### Affected Code

- `process/manager/mod.rs:858-875`: default-action dispatch bypasses the block-mask check.

### Recommendation

Apply the block-mask test uniformly before acting, for both the handler and
default-action branches; leave the signal pending while it is masked in all eligible
threads.

---

## Bug 5: A caught signal is undeliverable — a sleeping thread in a runnable process is never interrupted

- **Scenario**: 4 (signal delivery / liveness)
- **Severity**: High
- **Invariant violated**: `NoUndeliverableCaught` (also `SignalEventuallyDelivered`, `scenario4_live`)
- **Config**: `MC_hunt_scenario4_mc5.cfg`
- **Counterexample**: 7 states, `spec/output/MC_hunt_scenario4_mc5_final.out`

### Trace Summary

A process `p1` is runnable (not suspended). A caught (handler) signal `s` is pending on
`p1`. Every running/ready thread of `p1` has `s` masked, and the only thread with `s`
unmasked is `sleeping`. The dispatcher never interrupts that sleeping thread, so the
pending handler signal is never taken — the process stays with `s` pending forever
(`SignalEventuallyDelivered` also fails on the fair run).

### Root Cause

Signal targeting (`process/manager/mod.rs:1009-1018`) and the runnable-process delivery
path (`process/state/runnable.rs:54-95`) only select among running/ready threads and do
not wake a sleeping thread that is the sole unmasked recipient. Because the process is
not suspended, no other mechanism forces the sleeping thread to be interrupted, so a
caught signal whose only valid target is asleep is stranded.

### Affected Code

- `process/manager/mod.rs:1009-1018`: recipient selection ignores sleeping unmasked threads.
- `process/state/runnable.rs:54-95`: runnable delivery does not interrupt a sleeping recipient.

### Recommendation

When the only thread with the signal unmasked is sleeping, interrupt/wake it (deliver an
`EINTR`-style wakeup) so the caught handler can run, mirroring how signal delivery
interrupts interruptible sleeps.

---

## Bug 6: Nested signal delivery during `sigsuspend` corrupts the saved mask

- **Scenario**: 4 (sigsuspend/sigreturn)
- **Severity**: High
- **Invariant violated**: `SigsuspendMaskRestored`
- **Config**: `MC_hunt_scenario4_mc6.cfg`
- **Counterexample**: 9 states, `spec/output/MC_hunt_scenario4_mc6_final.out`

### Trace Summary

A thread calls `sigsuspend`, installing a temporary mask and saving the pre-suspend
mask. A signal is delivered and its handler runs (a nested frame). During/after that
nested delivery the *saved* pre-suspend mask is overwritten, so when the frame returns
the thread's blocked set does **not** match the mask it had before `sigsuspend`. The
witness `g.maskRestoreBad` is set.

### Root Cause

`sigsuspend` and the frame save/restore logic (`process/manager/mod.rs:734`) store the
pre-suspend mask in a location that the nested delivery path (`sync/signal.rs:607-610`)
also writes, so a signal taken while suspended clobbers the value that sigreturn must
restore. The restore therefore reinstates the wrong (temporary or nested) mask.

### Affected Code

- `process/manager/mod.rs:734`: `sigsuspend` saved-mask handling.
- `sync/signal.rs:607-610`: nested delivery overwrites the saved mask.

### Recommendation

Save the pre-suspend mask per signal frame (stack it with the frame) so nested delivery
cannot overwrite it; restore exactly that value on sigreturn.

---

## Bug 7: `sigaction` to `SIG_DFL`/`SIG_IGN` strands an already-pending signal

- **Scenario**: 4 (disposition change)
- **Severity**: Medium
- **Invariant violated**: `NoStrandedProcPending` (also `SignalEventuallyDelivered`, `scenario4_live`)
- **Config**: `MC_hunt_scenario4_mc7.cfg`
- **Counterexample**: 4 states, `spec/output/MC_hunt_scenario4_mc7_final.out`

### Trace Summary

A signal `s` is posted to a process as **process-pending** while `s`'s disposition is a
handler. `sigaction` then changes `s`'s disposition to default/ignore. The already-queued
process-pending `s` is neither dropped (for ignore) nor converted to the new default
behavior; it remains pending with a non-handler disposition, so it can never be
dispatched as a handler and is never drained. The final state has `s` in `pr[p1].pd`
with `dp[s] != handler`.

### Root Cause

`sigaction` (`process/manager/mod.rs:603-611`) and the disposition update in
`sync/signal.rs:248-252` change the disposition table without reconciling the existing
process-pending set: a pending signal that becomes `SIG_IGN` should be discarded, and one
that becomes `SIG_DFL` should follow the default action. Neither happens, so the pending
entry is stranded.

### Affected Code

- `process/manager/mod.rs:603-611`: `sigaction` does not reconcile pending signals.
- `sync/signal.rs:248-252`: disposition change leaves the pending set untouched.

### Recommendation

On a disposition change, reconcile the pending set: discard now-ignored pending signals
and re-evaluate now-default ones, matching POSIX `sigaction` semantics.

---

## Bug 8: `kill` posts a caught signal onto a zombie process

- **Scenario**: 4 (kill vs. lifecycle)
- **Severity**: Medium
- **Invariant violated**: `NoSignalToZombie`
- **Config**: `MC_hunt_scenario4_mc8.cfg`
- **Counterexample**: 6 states, `spec/output/MC_hunt_scenario4_mc8_final.out`

### Trace Summary

A process `p1` becomes a zombie (terminated, awaiting wait/reap). A `kill` targeting
`p1` still resolves it as a valid target and posts a caught signal into its pending set.
The witness `g.sigToZombie` is set: a handler signal now sits in a process that can never
run a handler, wasting the pending slot and misrepresenting deliverability.

### Root Cause

The target lookup used by kill (`process/manager/mod.rs:2833-2852`) returns zombie
processes, and the post path (`process/manager/mod.rs:850-857`) enqueues the signal
without rejecting a non-runnable/zombie target. POSIX allows signal *sending* to a
zombie to succeed but the signal must not be queued for handler delivery on a process
that will never execute again.

### Affected Code

- `process/manager/mod.rs:2833-2852`: target lookup includes zombies.
- `process/manager/mod.rs:850-857`: post path does not reject zombie targets.

### Recommendation

Reject (or no-op) handler-signal posting to a zombie/terminated process; only permit the
bookkeeping POSIX requires (e.g., permission checks) without enqueuing an undeliverable
pending signal.

---

## Repaired Spec Artifacts (confirmation back-edge — Round 3)

The confirmation phase re-judged four earlier candidates as **spec over-approximations**
(target `SPEC_REPAIR`), each recorded as a repair request under
`spec/repair-requests/`. The cited implementation guards were added to `base.tla`; after
the repair each invariant **HOLDS** in its hunt config, and all 11 replayed traces still
pass the soundness gate. These are **not** implementation bugs — the code is correct and
the model was too permissive.

| Finding | Was | Invariant | Config | Spec fix (`base.tla`) | Post-repair |
|---|---|---|---|---|---|
| MC-1 (RR-001) | Bug 1 | `LiveCountAccurate` | `MC_hunt_scenario2_mc1.cfg` | `ExitThread` defers a detached zombie only while a *live* sibling remains (`has_other_threads`, running.rs:377); `ReapDeferredUnsafe` guarded on a non-buried (findable) owner and always decrements (unsafe.rs:708) — the buried-owner early return (unsafe.rs:668) is unreachable | HOLDS — `spec/output/MC_hunt_scenario2_mc1_repaired.out` |
| MC-9 (RR-002) | Bug 9 | `ExecAdmission` | `MC_hunt_scenario2_mc9.cfg` | `ExecRefuse` guarded by `tlive - |deferred| >= MaxThreads` (execv drains deferred zombies at entry, unsafe.rs:361 → on_thread_reaped) so a refusal with reclaimable slots is unreachable | HOLDS — `spec/output/MC_hunt_scenario2_mc9_repaired.out` |
| MC-10 (RR-003) | Bug 10 | `NoDestroyWithWaiter` | `MC_hunt_scenario3_destroy.cfg` | `PutMutex` destroys only when `ow = NULL /\ q = <<>>` — the model analogue of `reference_count() <= 2` (owner's guard already dropped by `take_mutex_guard`; a blocked waiter holds an extra `Arc`), state/mod.rs:651, mod.rs:2616-2637 | HOLDS — `spec/output/MC_hunt_scenario3_destroy_repaired.out` |
| MC-11 (RR-004) | Bug 11 | `NoDestroyWithWaiter` | `MC_hunt_scenario3_destroy.cfg` | `PutCond` destroys only when `q = <<>>` — the analogue of `reference_count() <= 1` (a queued waiter keeps a live `Condvar` clone), state/mod.rs:712, condvar.rs:232-257 | HOLDS — `spec/output/MC_hunt_scenario3_destroy_repaired.out` |

Each guard preserves its invariant as a falsifiable oracle: a genuinely occupied
object destroyed, or a real leaked/over-counted slot, still trips the witness. The
`defer_unsafe` trace was corrected to the faithful reap-before-bury ordering (no leak),
matching the repaired `ReapDeferredUnsafe`. Full detail per request lives in the
consumed `RR-00{1,2,3,4}.md`.

## Not Reproduced

These configs were run and produced **no** violation on the corrected, trace-faithful
spec. They are recorded as non-findings (guarantees that hold in the model).

| Scenario | Config | Invariant / Property | States Explored | Result |
|----------|--------|----------------------|-----------------|--------|
| 1 (structural sanity) | `MC_hunt_scenario1.cfg` | structural invariants | full | No violation |
| 2 (auto-reclaim) | `MC_hunt_scenario2_live.cfg` | `NoUnreapableZombie` | 138 distinct | No violation — detached zombies are always reaped; joinable retention is by design |
| 3 (mutex safety) | `MC_hunt_scenario3_mc3.cfg` | `MutexReleasedOnDeath` | 348 distinct | No violation — see spec-fidelity note; a reaped thread never still owns a mutex |
| 3 (condvar reacquire) | `MC_hunt_scenario3_cond.cfg` | `CondWaitReacquires` | full | No violation — modelled `wait_cond` paths reacquire the mutex on return |
| 5 (rollback) | `MC_hunt_scenario5.cfg` | `RollbackComplete` | 48 distinct | No violation — modelled failed create/fork/exec restore reserved ids and live counts |
| base | `MC.cfg` | 6 structural invariants | 583,952 distinct | No violation |

## Spec Fixes During Hunting (Case B)

While hunting, the `MutexReleasedOnDeath` **safety** counterexample
(`scenario3_mc3`) was diagnosed as a **spec-fidelity gap, not a bug**, and the mutex
release/wake model was corrected (details in `changelog.md`, Rounds 2 and 2b):

1. **Reap releases the guard.** Every reap path funnels through `harvest_zombie_thread`
   → `ZombieThread::harvest()`, which drops the `ThreadState` and thus releases its
   `MutexGuard`s (`unsafe.rs:657`, `thread/zombie.rs:110-112`, `thread/state.rs:83`).
   The spec had modelled six reap actions as leaving the mutex owned by the reaped
   thread; they now release it. Result: `MutexReleasedOnDeath` HOLDS (the safety
   counterexample was a false positive).
2. **Wake protocol matches `unlock_unchecked`.** `unlock_unchecked`
   (`sync/mutex.rs:78-81`) clears ownership (`locked.store(false)`) and `notify_first`
   wakes one waiter that **re-competes** via `try_lock` (`mutex.rs:174-186`). The
   `ReleaseOwnedBy` helper now sets `ow := NULL` (instead of handing ownership directly)
   and the fresh-lock actions require `bk = "none"`, so a woken waiter resumes only via
   `LockResume`. This removed a spurious self-deadlock lasso, leaving the **genuine**
   held-until-harvest `MutexProgress` counterexample (Bug 3).

Net effect on findings (Case B, Round 2): **none removed and none added** — Bug 3
(MC3/MC10 liveness) is correctly re-attributed from the (artifactual)
`MutexReleasedOnDeath` safety invariant to the `MutexProgress` liveness property, which
reproduces the real defect. (The Round 2 Case-B fix is distinct from the Round 3
confirmation back-edge repairs above: the former `MC-1` live-count leak was **later**
re-judged a spec artifact and repaired in Round 3 — see *Repaired Spec Artifacts*.)
