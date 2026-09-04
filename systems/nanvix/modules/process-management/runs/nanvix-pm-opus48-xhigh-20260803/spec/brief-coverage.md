# Brief Coverage Audit — Nanvix Process Management

Self-audit mapping modeling-brief **§2 Scenarios**, **§5 Proposed Invariants**, and
**§6.1 Model-Checkable Findings** onto the base spec, the `MC.tla` wiring, and the
per-scenario hunt cfgs. The "enabled in cfg" columns were filled by reading the actual
`MC_hunt_*.cfg` files and running each one (results reproduced at the bottom).

Scope note: the target is **Category B (concurrent/runtime)** but the kernel is
**single-core with interrupts disabled**, so a whole kernel call runs atomically and
events are totally ordered. Concurrency is therefore modelled as an *interleaving of
atomic kernel-call actions* on shared PM state (`base.tla`), not as sub-operation
overlap. Reaping/wakeup/delivery actions run in kernel context (no running thread),
so TLC orders them freely — that free ordering is what exposes the burial-vs-drain and
signal-timing findings.

---

## 1. Scenarios (brief §2)

| Scenario | Mechanism | Hunt cfg(s) | Result |
|---|---|---|---|
| 1 — Location & State-Machine Integrity | exactly-one-location, total `Box` moves, no run after zombie/stop, one-quantum self-stop window | `MC_hunt_scenario1.cfg` | HOLDS (structural backbone) |
| 2 — Zombie Reaping & ID/Slot Accounting | reap-exactly-once, `live_count` per burial, two divergent reap paths, join/exec admission | `MC_hunt_scenario2_mc1` (MC1), `_mc2` (MC2), `_mc9` (MC9), `_live` (liveness) | 3 VIOLATE + 1 HOLDS |
| 3 — Mutex/Condvar Ownership & Termination Liveness | lock released only at harvest; dying owner strands waiters; destroy-with-waiter; reacquire | `MC_hunt_scenario3_mc3` (MC3/MC10), `_destroy`, `_cond`, `_live` (liveness) | 2 VIOLATE + 2 HOLDS |
| 4 — Signal Delivery, Masking & sigsuspend/sigreturn | default-action ignores mask; wakeup scans only suspended; sigaction ignores pending; single `saved_blocked`; zombie in lookup | `MC_hunt_scenario4_mc4/mc5/mc6/mc7/mc8`, `_live` (liveness) | 6 VIOLATE |
| 5 — Creation/Fork/Exec/Address-Space Rollback | two-phase reserve/commit restores every ID + `live_count` | `MC_hunt_scenario5.cfg` (MC9 covered under Scenario 2) | HOLDS (ID accounting clean) |

Every §2 Scenario has ≥1 hunt cfg. No mergers were needed; each finding gets its own cfg
so its witness trace is isolated.

---

## 2. Invariants (brief §5)

| Invariant | Type | Defined (base.tla) | Wired (MC.tla) | Enabled in hunt cfg | Result |
|---|---|---|---|---|---|
| ExactlyOneLocation | Safety | `ExactlyOneLocation` | via `MCNext` core | scenario1, 2_mc1/mc2/mc9, 3_mc3/cond, 4_mc5/mc8, 5 | HOLDS |
| NestedStateConsistent | Safety | `NestedStateConsistent` | core | scenario1, 3_cond | HOLDS |
| NoRunAfterZombie | Safety | `NoRunAfterZombie` | core | scenario1, 2_mc1/mc2/mc9, 3_mc3/cond, 4_mc5, 5 | HOLDS |
| NoStoppedDispatch | Safety | `NoStoppedDispatch` | core+stop | scenario1 | HOLDS |
| ReapedExactlyOnce | Safety | `ReapedExactlyOnce` | core | scenario1 | HOLDS |
| LiveCountAccurate | Safety | `LiveCountAccurate` | reap paths | **scenario2_mc1** | **VIOLATED** (MC1) |
| NoUnreapableZombie | Liveness | `NoUnreapableZombie` (detached/buried scope) | fair reap | scenario2_live | HOLDS |
| JoinGetsStatus | Liveness→safety-witness | `JoinGetsStatus` | join paths | **scenario2_mc2** | **VIOLATED** (MC2) |
| ExecAdmission | Safety | `ExecAdmission` | execR | **scenario2_mc9** | **VIOLATED** (MC9) |
| MutexReleasedOnDeath | Liveness→safety-witness | `MutexReleasedOnDeath` | reap+lock | **scenario3_mc3** | ~~VIOLATED (MC3/MC10)~~ → **HOLDS** after Round 2 fix; real defect is liveness (`MutexProgress`, scenario3_live) — see correction note in §3 |
| NoDestroyWithWaiter | Safety | `NoDestroyWithWaiter` | putmutex/putcond | **scenario3_destroy** (VIOLATED), scenario3_cond (holds) | **VIOLATED** |
| CondWaitReacquires | Safety | `CondWaitReacquires` | cond path | scenario3_cond | HOLDS (mainline; skip is test-only T1) |
| MaskedSignalDeferred | Safety | `MaskedSignalDeferred` | kill | **scenario4_mc4** | **VIOLATED** (MC4) |
| SignalEventuallyDelivered | Liveness | `SignalEventuallyDelivered` | fair async | **scenario4_live** | **VIOLATED** (MC5/MC7) |
| SigsuspendMaskRestored | Safety | `SigsuspendMaskRestored` | susp/sigret | **scenario4_mc6** | **VIOLATED** (MC6) |
| NoSignalToZombie | Safety | `NoSignalToZombie` | kill+zombie | **scenario4_mc8** | **VIOLATED** (MC8) |
| RollbackComplete | Safety | `RollbackComplete` | create/fork/exec | scenario5 | HOLDS |

Two extra safety **witnesses** were added on top of §5 to give the two signal liveness
findings a concrete bad-state (safety) trap that TLC can exhibit without fairness:

| Extra invariant | Backs finding | Enabled in | Result |
|---|---|---|---|
| `NoUndeliverableCaught` | MC5 (stranded caught signal, sleeping recipient) | scenario4_mc5 | **VIOLATED** |
| `NoStrandedProcPending` | MC7 (pending stranded after disposition change) | scenario4_mc7 | **VIOLATED** |

**Every Safety invariant in §5 is defined, wired through `MCNext`, and enabled in ≥1
hunt cfg** (the column that most often breaks). The three intentionally-clean invariants
(`RollbackComplete`, `CondWaitReacquires`, and structural `NoStoppedDispatch`) are each
enabled in a hunt that exercises their mechanism and confirmed to HOLD — they are not
vacuous-by-omission.

### Liveness / safety framing note

`JoinGetsStatus`, `MutexReleasedOnDeath`, `NoUnreapableZombie` and
`SignalEventuallyDelivered` are §5-typed *Liveness*. Because the kernel is atomic per
call, each has a reachable **bad snapshot** that a plain state invariant can trap:
- `JoinGetsStatus` / `MutexReleasedOnDeath` are checked as state invariants (a resumed
  joiner tagged `joinLost`; a mutex still owned by a fully-`reaped` thread) — the concrete
  wrong state is directly observable, so a safety hunt gives a finite witness trace.
- `NoUnreapableZombie`, `MutexProgress`, `SignalEventuallyDelivered` are additionally
  checked as true `<>`/`~>` temporal properties under `MCSpecFair`
  (`scenario2_live`, `scenario3_live`, `scenario4_live`) to catch the pure never-progresses
  shape.

---

## 3. Findings (brief §6.1)

| ID | Trigger mechanism (as modelled) | Expected invariant | Hunt cfg | Result |
|----|---|---|---|---|
| MC1 | detached zombie deferred; process buried by `HarvestZombies`; `ReapDeferredUnsafe` on a buried process skips `on_thread_reaped` → `tlive` leaks | LiveCountAccurate / ReapedExactlyOnce | scenario2_mc1 | **VIOLATED** |
| MC2 | joiner parks on t2; t2 exits (zombie, wakes joiner); a third thread detaches/reaps t2 before `JoinResume` → joiner tagged `joinLost` | JoinGetsStatus | scenario2_mc2 | **VIOLATED** |
| MC3 | owner of `mx1` exits detached; unsafe deferred reap after burial drops the guard-owner without releasing → mutex owned by a reaped thread | MutexReleasedOnDeath | scenario3_mc3 | **VIOLATED** |
| MC10 | same reacquire/hold-until-harvest path; covered by the same owner-reaped bad state and by `MutexProgress` liveness | MutexReleasedOnDeath | scenario3_mc3 + scenario3_live | **VIOLATED** |
| MC4 | `Sigprocmask({15})` on the only thread, then `Kill(p1,15)` default-term path skips the mask check → `maskedActed` | MaskedSignalDeferred | scenario4_mc4 | **VIOLATED** |
| MC5 | caught signal to a runnable process whose only unmasked recipient is a **sleeping** thread; wakeup scans only suspended procs → signal stranded in `pd` | SignalEventuallyDelivered / NoUndeliverableCaught | scenario4_mc5 (safety) + scenario4_live (liveness) | **VIOLATED** |
| MC6 | nested async delivery during `Sigsuspend` consumes the single `saved_blocked`; outer `Sigreturn` restores the frame mask instead → wrong `blocked` | SigsuspendMaskRestored | scenario4_mc6 | **VIOLATED** |
| MC7 | `Sigaction` retargets a pending caught signal to default/ignore without clearing `pd` → stranded forever | SignalEventuallyDelivered / NoStrandedProcPending | scenario4_mc7 (safety) + scenario4_live (liveness) | **VIOLATED** |
| MC8 | `Fork` p2/t2; install handler on p2; t2 exits → p2 zombie; `Kill(p2,1)` handler branch posts into a zombie `pd` → `sigToZombie` | NoSignalToZombie / ExactlyOneLocation | scenario4_mc8 | **VIOLATED** |
| MC9 | `MaxThreads=2`; t1 + detached t2 (tlive=2); t2 exits → deferred; `ExecRefuse` refuses a net-zero exec while a reclaimable deferred slot exists | ExecAdmission | scenario2_mc9 | **VIOLATED** |

All ten §6.1 findings have a hunt cfg whose fault setup makes the trigger reachable, and
every one produces the predicted violation with a finite witness trace.

> **Post-validation correction (Round 2 / 2b — see `changelog.md`, `bug-report.md`).**
> The MC3/MC10 rows above reflect the *pre-fix* expectation that the **safety** invariant
> `MutexReleasedOnDeath` would be violated. During bug hunting that counterexample was
> shown to be a **spec-fidelity artifact**, not a code bug: every reap path drops the
> `ThreadState` and thereby releases the owned `MutexGuard` (`unsafe.rs:657`,
> `thread/zombie.rs:110`), so a *reaped* thread never still owns a mutex. After the
> mutex release/wake model was corrected, **`scenario3_mc3` HOLDS** (`MutexReleasedOnDeath`
> is a false positive). The real MC3/MC10 defect is a **liveness** bug — a mutex owned by a
> *joinable, never-joined* zombie is released only at harvest, so it is held forever and
> waiters (including condvar reacquire) block forever. It reproduces as a `MutexProgress`
> temporal violation in **`scenario3_live`** and is reported as **Bug 3** in
> `bug-report.md` (finding `MC-3`). The state counts in §4 below are the original pre-fix
> figures; the authoritative post-fix results are in `changelog.md`.

---

## 4. Validation results (reproduce)

Run from `spec/`:
`java -XX:+UseParallelGC -cp <tla2tools.jar>:<CommunityModules-deps.jar> tlc2.TLC -deadlock -config <cfg> MC.tla`
(the three `*_live` cfgs use `SPECIFICATION MCSpecFair`; all use `CONSTRAINT StateBound`).

| Hunt cfg | Expectation | Outcome | distinct states |
|---|---|---|---|
| MC.cfg (structural gate) | converge, no violation | No error | 657,628 |
| MC_hunt_scenario1 | HOLDS | No error | 24,168 |
| MC_hunt_scenario2_mc1 | VIOLATE LiveCountAccurate | Violated | 57 |
| MC_hunt_scenario2_mc2 | VIOLATE JoinGetsStatus | Violated | 826 |
| MC_hunt_scenario2_mc9 | VIOLATE ExecAdmission | Violated | 37 |
| MC_hunt_scenario2_live | HOLDS NoUnreapableZombie | No error | 138 |
| MC_hunt_scenario3_mc3 | VIOLATE MutexReleasedOnDeath | ~~Violated~~ → **HOLDS** (false positive; corrected Round 2, real defect is liveness — see scenario3_live) | 348 |
| MC_hunt_scenario3_destroy | VIOLATE NoDestroyWithWaiter | Violated | 19 |
| MC_hunt_scenario3_cond | HOLDS CondWaitReacquires | No error | 1,314 |
| MC_hunt_scenario3_live | VIOLATE MutexProgress | Violated | 535 |
| MC_hunt_scenario4_mc4 | VIOLATE MaskedSignalDeferred | Violated | 4 |
| MC_hunt_scenario4_mc5 | VIOLATE NoUndeliverableCaught | Violated | 186 |
| MC_hunt_scenario4_mc6 | VIOLATE SigsuspendMaskRestored | Violated | 130 |
| MC_hunt_scenario4_mc7 | VIOLATE NoStrandedProcPending | Violated | 6 |
| MC_hunt_scenario4_mc8 | VIOLATE NoSignalToZombie | Violated | 109 |
| MC_hunt_scenario4_live | VIOLATE SignalEventuallyDelivered | Violated | 84 |
| MC_hunt_scenario5 | HOLDS RollbackComplete | No error | 48 |

---

## 5. Out-of-scope items (brief §6.2 / §6.3, honestly noted)

Not model-checked here — the brief itself routes these to tests, and the faithful model
follows the mainline path where they do not manifest:

- **T1** `wait_cond` skips reacquire on `get/put_cond` failure — the model always
  reacquires (mainline); `CondWaitReacquires` therefore HOLDS. The skip needs
  `COND_OPEN_MAX` exhaustion, a test concern. Ghost `condNoReacq` is present but never
  set (documented in `base.tla`).
- **T2** missing `SigRestorer` drops an async caught signal — a userland-ABI concern
  below the PM state machine.
- **T3 / T4** fork parent-CoW and `mmap` batch rollback — physical-memory /
  address-space allocator internals, explicitly out of scope for PM per the task, and
  `RollbackComplete` (accounting-level) HOLDS.
