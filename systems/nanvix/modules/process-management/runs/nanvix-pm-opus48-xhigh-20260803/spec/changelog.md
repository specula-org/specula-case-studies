# Spec Validation Changelog — Nanvix Process Management

Records every modification made during the trace-validation ↔ model-checking loop,
grouped by round. See validation-workflow guide for format.

## Round 1 - Trace Validation
- All 12 traces (11 scenarios + trace.ndjson) pass unmodified. No spec changes needed.
  Note: `Trace.tla` hardcodes `JsonFile == "../traces/trace.ndjson"`, so validation must
  copy each scenario onto `trace.ndjson` before running TLC (the MCP `trace_file` param is
  ignored by this spec). Verified with a negative control (corrupted post-state → TraceMatched
  violated) to rule out false positives.

## Round 1 - Model Checking
- MC.cfg (structural invariants: TypeOK, ExactlyOneLocation, NestedStateConsistent,
  NoRunAfterZombie, NoStoppedDispatch, ReapedExactlyOnce) — exhaustive BFS, 657,628 distinct
  states, depth 33, "No error has been found". No spec or invariant changes.
  Note: run with `-deadlock` (detection off). The model has legitimate quiescent terminal
  states (full cleanup: last thread reaped, process buried, tlive=plive=0), which are by-design
  ends, not safety bugs. Genuine stuck-waiter concerns are checked as liveness properties
  (MutexProgress, NoUnreapableZombie, SignalEventuallyDelivered) under MCSpecFair in the hunt
  cfgs, not via deadlock. This is a run-config choice, not a spec modification.

## Result
Converged in 1 round (trace validation + model checking both pass, zero spec modifications).
The spec is trusted. Proceeding to Bug Hunting.

## Round 2 - Bug Hunting (Case B spec-fidelity fix)
During bug hunting, the `scenario3_mc3` counterexample (safety invariant
`MutexReleasedOnDeath`: a *reaped* thread must not still own a mutex) was traced to a
**spec-vs-code mismatch (Case B)**, not a real bug:

- The spec modeled several reap actions as leaving `mu` UNCHANGED when a thread that
  still owned a mutex was reaped, producing a "reaped thread owns mutex" state
  (`JoinThread`, `JoinResume`, `DetachThread` reap branches; `ReapDeferredUnsafe`
  buried early-return; `CreateThread`/`Fork` healing reap of the deferred set).
- Ground truth: every reap path funnels through `harvest_zombie_thread`
  (`process/manager/unsafe.rs:657`, `:758`, `:809`) / `reap_deferred_zombie_threads`
  (`mod.rs:3337`), all of which call `ZombieThread::harvest()`
  (`thread/zombie.rs:110-112`). `harvest()` consumes the `ZombieThread`, dropping its
  `ThreadState` whose `locked_mutexes: BTreeMap<_, MutexGuard>`
  (`thread/state.rs:83`) is dropped, so `MutexGuard::drop` releases the lock. For the
  MC1 unsafe buried path, the guard is dropped at `unsafe.rs:657` **before** the
  early-return at `:668`; only `on_thread_reaped` (`:708`) is skipped. So on reap the
  mutex IS released; only `live_count` can leak.

**Fix:** made all reap actions release the reaped thread's owned mutex and wake the
next waiter via the existing `ReleaseOwnedBy`/`WokenByRelease` helpers (hoisted above
their first use), while preserving the `tlive` leak on the `ReapDeferredUnsafe` buried
branch (MC1). Kill/terminate still retains the guard until harvest (`base.tla` TermSet
comment) — that is faithful and is the real MC3/MC10 mechanism.

**Re-validation after fix (all with `-deadlock`):**
- Trace validation: all 11 scenario traces still PASS.
- MC.cfg (structural): exhaustive, "No error has been found".
- `scenario2_mc1` LiveCountAccurate: still VIOLATE (MC1 preserved).
- `scenario3_mc3` MutexReleasedOnDeath: now **HOLDS** (false positive removed).
- `scenario3_live` MutexProgress: still VIOLATE — the *real* MC3/MC10 bug is the
  liveness one (a mutex held by an unreaped zombie is never released for a joinable
  thread that is never joined; `lock(None)` reacquire blocks forever).
- All other hunts unchanged (MC2, MC9, destroy, MC4–MC8, scenario4_live VIOLATE;
  scenario1, scenario2_live, scenario3_cond, scenario5 HOLD).

## Round 2b - Mutex wake-protocol fidelity correction
Inspecting the (still-violating) `scenario3_live` MutexProgress lasso after the Case B
fix exposed a **second, pre-existing fidelity gap** in the mutex-wake model that produced
a *spurious* self-deadlock counterexample (masking the genuine one):

- The `ReleaseOwnedBy` helper (used by `HarvestZombies`/`ReapDeferredSafe` since the
  original spec, and by the new reap paths) handed the lock **directly** to the head
  waiter (`ow := Head(q)`) and woke it to `ready` while leaving its `bk="mutex"` marker
  set. Ground truth `unsafe { unlock_unchecked }` (`sync/mutex.rs:78-81`) instead
  `locked.store(false)` (**owner cleared to NULL**) then `notify_first()` wakes ONE
  waiter, which **re-competes** via `try_lock` in `Mutex::lock`'s loop (`mutex.rs:174-186`).
  Ownership is never handed directly.
- With direct hand-off, a woken thread kept `bk="mutex"` and could run `LockResume`
  seeing *itself* as owner (`ow≠NULL`) → took the "still held: re-block" branch →
  re-parked on a mutex it already owned → permanent **self-deadlock (spec artifact)**.
  A second route reached the same artifact when the woken thread re-acquired via
  `LockAcquire` (which did not clear the stale `bk="mutex"`) and then `LockResume`
  re-blocked it.

**Fix (two edits, both pure fidelity to `unlock_unchecked`):**
1. `ReleaseOwnedBy` now mirrors the ordinary `Unlock` action: it sets `ow := NULL`, pops
   the head from the wait queue, and `WokenByRelease` wakes that head to `ready` to
   **re-compete** (its `LockResume` then sees `ow=NULL` and acquires cleanly).
2. `LockAcquire`/`LockBlock` (the *fresh*-lock actions) now require `th[t].bk = "none"`,
   so a mid-wait waiter (`bk="mutex"`) resumes **only** via `LockResume`. `bk="mutex"`
   is thus a faithful "in the `lock()` wait loop" marker.

**Re-validation after 2b (all with `-deadlock`):**
- Trace validation: all 11 scenario traces still PASS.
- MC.cfg (structural): exhaustive, 583,952 distinct states, "No error has been found".
- `scenario2_mc1` LiveCountAccurate: still VIOLATE (MC1 preserved, 7-state trace).
- `scenario3_mc3` MutexReleasedOnDeath: HOLDS.
- `scenario3_live` MutexProgress: still VIOLATE — now via the **genuine** 6-state lasso
  (t1 locks mx1, exits as a JOINABLE zombie of a still-alive process → never auto-reaped
  per the POSIX retention contract → mutex held forever; t2's `LockBlock` parks forever).
  The self-deadlock artifact is gone.
- All other hunts unchanged (MC2, MC9, destroy, MC4–MC8, scenario4_live VIOLATE;
  scenario1, scenario2_live, scenario3_cond, scenario5 HOLD).

## Result (after Round 2)
Spec is faithful and trusted. The Case B fix eliminated one false-positive safety
counterexample; the 2b wake-protocol correction removed a spurious self-deadlock lasso so
the surviving `MutexProgress` counterexample is the genuine held-until-harvest bug.
MC3/MC10 is correctly re-attributed to the `MutexProgress` liveness property. All
confirmed findings are Case C implementation bugs — see `bug-report.md`.

## Round 3 - Confirmation back-edge repair (RR-001..RR-004)

The confirmation phase re-judged four findings as **spec over-approximations**
(`SPEC_REPAIR`) and handed them back as repair requests. Each cited action was tightened
in `base.tla` to match the Rust implementation (ground truth); no invariant was weakened.

**Spec edits (`base.tla`), five guards:**
1. **RR-001 / MC-1 — `ExitThread` deferral.** Defer a detached zombie only while a *live*
   sibling remains: `deferred' = IF th[t].det /\ othersLive # {} THEN deferred \cup {t}
   ELSE deferred` (mirrors `is_detached && has_other_threads`, running.rs:377). With no
   live sibling the detached zombie is folded into the ZombieProcess and reaped by
   `HarvestZombies`.
2. **RR-001 / MC-1 — `ReapDeferredUnsafe`.** Added precondition `pr[th[t].pr].st #
   "buried"` (reap runs before burial while the owner is findable, mod.rs:2851) and made
   it **always** `tlive' = tlive - 1` (on_thread_reaped, unsafe.rs:708). The buried-owner
   early return (unsafe.rs:668) is unreachable, so the leak branch is removed.
3. **RR-002 / MC-9 — `ExecRefuse`.** Guard changed to `tlive - Cardinality(deferred) >=
   MaxThreads` (models the execv entry-point `reap_deferred`, unsafe.rs:361); witness made
   latching (`execRefused' = @ \/ (deferred # {})`).
4. **RR-003 / MC-10 — `PutMutex`.** Destroy only when `mu[m].ow = NULL /\ mu[m].q = <<>>`
   (model analogue of `reference_count() <= 2` + `take_mutex_guard`, state/mod.rs:651).
5. **RR-004 / MC-11 — `PutCond`.** Destroy only when `co[c].q = <<>>` (analogue of
   `reference_count() <= 1`, state/mod.rs:712). `destroyWaiter` witnesses retained on both
   `Put*` as regression detectors.

**Trace correction (soundness gate consequence).** `defer_unsafe.ndjson` encoded the
unreachable leak ordering (`ReapDeferredUnsafe` on an already-buried `p1`). It was
corrected to the faithful reap-before-bury ordering (reap `t2` and decrement while `p1` is
still alive/findable, then bury `p1` after all threads are reaped; final `tlive = 0`). The
harness generator `harness/src/tla_world.rs` (`scenario_defer_unsafe`,
`reap_deferred_unsafe`) was updated to reproduce it.

**Re-validation (all with `-deadlock`):**
- Trace validation: all 11 scenario traces PASS (soundness gate held).
- Syntax (SANY) valid; VAV analysis clean (0 issues).
- Full MC conformance pass over all 16 hunt cfgs:
  - `scenario2_mc1` `LiveCountAccurate` — now **HOLDS** (was VIOLATE; MC-1 repaired).
  - `scenario2_mc9` `ExecAdmission` — now **HOLDS** (was VIOLATE; MC-9 repaired).
  - `scenario3_destroy` `NoDestroyWithWaiter` — now **HOLDS** (was VIOLATE; MC-10/MC-11
    repaired).
  - Unchanged VIOLATE (genuine bugs): `scenario2_mc2` (JoinGetsStatus),
    `scenario3_live` (MutexProgress), `scenario4_{mc4,mc5,mc6,mc7,mc8}`,
    `scenario4_live` (SignalEventuallyDelivered).
  - Unchanged HOLD: `scenario1`, `scenario2_live`, `scenario3_cond`, `scenario3_mc3`,
    `scenario5`.
  Outputs saved under `output/*_repaired.out`. The post-repair violating set is exactly the
  pre-repair set minus the four repaired findings — no regression, no new artifact, no
  real bug masked.

**Result.** `findings.json` now lists the seven current violations (MC-2..MC-8). RR-001..
RR-004 are `CONSUMED`. `confirmed-bugs.md` was not touched (orchestrator-owned).
