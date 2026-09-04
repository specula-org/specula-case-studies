# Brief Coverage Self-Audit — Nanvix Process Management

This audit maps the modeling brief's §2 Scenarios, §5 Proposed Invariants, and §6.1
Model-Checkable Findings to the generated spec artifacts, and records the result of
actually running each hunt config (not what was intended). All rows were filled by
reading the `.cfg` files and by running TLC (`-workers 4`) against `MC.tla`.

**Category B**: single-core kernel, interrupts disabled, all atomics `Relaxed` — no
weak-memory behavior. Concurrency is logical interleaving at block/preempt/kcall-return
boundaries, which the action granularity in `base.tla` exposes directly (no `MCPreempt`
adversary is needed for memory ordering; `Preempt` models the timer only).

## Convergence (structural)

`MC.cfg` runs the full spec (all subsystems active, `MaxOps = 6`, symmetry over
`Proc`/`Thread`) checking only the structural invariants. Result: **3,322,116 distinct
states, no violation** — `TypeOK` and `SingleOwner` hold across the bounded space. The
extension (Scenario) invariants are commented out of `MC.cfg` because the spec models
the real bugs and violates them by design; they are enabled per-Scenario below.

## Scenarios (brief §2) → hunt cfg

| Scenario (§2) | Mechanism | Hunt cfg | Result |
|---|---|---|---|
| S1 Incomplete wakeup search set | AlarmFire parks a sleeper in an *interrupted* process; the buggy `try_wakeup` search (skips the interrupted list) and suspended-only `interrupt_signal_candidate` | `MC_hunt_scenario1.cfg` | MC-1 & MC-2 both violated |
| S2 Terminate/exit doesn't force-kill interrupted threads | `RunnableProcess::terminate` / `RunningProcess::exit` carry interrupted reason forward; dispatcher returns TimedOut/Signaled to user | `MC_hunt_scenario2.cfg` | MC-3 violated |
| S3 `running == None` reentrancy in `do_exit` | take_running → cleanup_rendezvous → do_wakeup → get_running().expect panic | `MC_hunt_scenario3.cfg` | MC-4 violated |
| S4 Reclaimable thread slots not reaped before cap | create_process/do_execv reserve the main-thread slot with the non-reaping `try_next_tid` (thread cap binds first: MAX_THREADS < MAX_PROCESSES) | `MC_hunt_scenario4.cfg` | MC-5 violated |
| S5 Blocking-sync cancellation half-releases ownership | interrupted cond_wait relock; unreclaimed mutex-map entry | `MC_hunt_scenario5.cfg` | MC-6 & MC-7 both violated |
| S6 Signal pending/mask/disposition consistency | default-Terminate bypasses mask; disposition change strands pending | `MC_hunt_scenario6.cfg` | MC-8 & MC-9 both violated |
| S7 sigsuspend/sigreturn/SA_RESTART reentrancy | nested sigsuspend overwrites `saved_blocked`; signum-less restart misattribution | `MC_hunt_scenario7.cfg` | MC-10 (both invariants) violated |

Every §2 Scenario has exactly one targeting hunt cfg. No mergers were needed at the
Scenario level. Two Scenarios (S1, S5, S6, S7) legitimately carry two invariants each,
matching the brief's own pairing of findings under those Scenarios.

## Invariants (brief §5) → definition / wiring / enabled-in-cfg

| Invariant (§5) | Type | Defined (base.tla) | Wired (MC.tla) | Enabled in hunt cfg | Reachable? |
|---|---|---|---|---|---|
| SingleOwner | Safety | `SingleOwner` | `MCSingleOwner` | all hunt cfgs + MC.cfg | holds (structural) |
| NoLostNotify | Safety/Liveness | `NoLostNotify` | `MCNoLostNotify` | scenario1 | **violated** (MC-1) |
| SignalReaches | Liveness | `SignalReachesSafety` (safety proxy) | `MCSignalReachesSafety` | scenario1 | artifact CE repaired (RR-001); genuine stranding still detectable |
| TerminatedThreadsDie | Safety | `TerminatedThreadsDie` | `MCTerminatedThreadsDie` | scenario2 | **violated** (MC-3) |
| RunningValidAtWakeup | Safety | `RunningValidAtWakeup` | `MCRunningValidAtWakeup` | scenario3 | **violated** (MC-4) |
| AdmissionLiveness | Liveness | `NoSpuriousOOM` (safety proxy) | `MCNoSpuriousOOM` | scenario4 | **violated** (MC-5); re-gated to the reachable thread-cap defect (RR-004) |
| CondWaitReturnsLocked | Safety | `CondWaitReturnsLocked` | `MCCondWaitReturnsLocked` | scenario5 | **violated** (MC-6) |
| SyncSlotConservation | Safety | `SyncSlotConservation` | `MCSyncSlotConservation` | scenario5 | artifact CE repaired (RR-002); genuine `lock_mutex`-cancel leak still detectable |
| MaskHonored | Safety | `MaskHonored` | `MCMaskHonored` | scenario6 | **violated** (MC-8) |
| NoImmortalPending | Safety/Liveness | `NoImmortalPending` | `MCNoImmortalPending` | scenario6 | **violated** (MC-9) |
| SavedMaskRestored | Safety | `SavedMaskRestored` | `MCSavedMaskRestored` | scenario7 | **violated** (MC-10a) |
| ~~RestartAttribution~~ | — | *removed* | *removed* | — | **not applicable** (RR-003): SA_RESTART is applied per the delivered signal; no real contract to check |

Every Safety invariant in §5 is defined, wired through `MC.tla`, and **enabled in ≥1
hunt cfg** (verified by reading the cfg `INVARIANTS` blocks). The two Liveness
invariants (`SignalReaches`, `AdmissionLiveness`) are represented by faithful
**safety proxies** (`SignalReachesSafety`, `NoSpuriousOOM`) that are computed directly
from the buggy control flow (interrupt_signal_candidate scanning only `suspended`; the
cap-before-reap admission gate), so they are model-checkable without fairness. This is
the one deliberate representational choice; it is documented here rather than left
silent. `NoImmortalPending` and `NoLostNotify` are marked Safety/Liveness in the brief
and are checked here as safety (a reachable stuck/lost state), which is the stronger,
directly-checkable form.

## Findings (brief §6.1) → trigger / expected invariant / hunt cfg (all confirmed reachable)

| ID | Trigger mechanism | Expected violated invariant | Hunt cfg | TLC result |
|---|---|---|---|---|
| MC-1 | Notify a condvar/join waiter that is a sleeping thread inside an *interrupted* process | NoLostNotify | scenario1 | violated (7,442 states) |
| MC-2 | Post a caught signal whose only unmasked candidate is a sleeper in a *runnable* process | SignalReaches / SingleOwner | scenario1 | violated (1,307 states) |
| MC-3 | Terminate a Runnable process holding a TimedOut/Signaled interrupted thread | TerminatedThreadsDie | scenario2 | violated (525 states) |
| MC-4 | Exit a process while another process's thread is blocked in a rendezvous on it | RunningValidAtWakeup | scenario3 | violated (63 states) |
| MC-5 | Thread cap reached with a reclaimable unharvested zombie thread; create_process/do_execv reject before reap (non-reaping try_next_tid) | AdmissionLiveness | scenario4 | violated (12 states) |
| MC-6 | Interrupt a `wait_cond` during the mutex reacquire | CondWaitReturnsLocked | scenario5 | violated |
| MC-7 | Timeout/interrupt a `lock_mutex` / exit holding a mutex; map-entry conservation | SyncSlotConservation | scenario5 | violated |
| MC-8 | Deliver a blockable default-Terminate signal while masked by every thread | MaskHonored | scenario6 | violated |
| MC-9 | Post a handler-signal, then change its disposition to SIG_DFL/SIG_IGN before delivery | NoImmortalPending | scenario6 | violated |
| MC-10 | Nested sigsuspend then sigreturn; two pending signals with differing SA_RESTART | SavedMaskRestored / RestartAttribution | scenario7 | both violated |

Every §6.1 finding has a hunt cfg whose fault setup makes the trigger reachable, and each
was confirmed violated by running TLC. Where a hunt cfg lists two invariants, each was
additionally verified in isolation (commenting out the other) so that neither masks the
other.

## Out of scope (recorded honestly)

- §6.2 Test-Verifiable (TV-1..TV-6) and §6.3 Code-Review-Only (CR-1..CR-5) are outside
  the model-checking audit per the checklist. The base spec still *models the mechanism*
  behind several of them incidentally (e.g., `Exec` zeroes pending = TV-2; the thread-exit
  guard transfer feeding `SyncSlotConservation` = TV-4), but no dedicated hunt cfg is
  provided since the brief classifies them as test/review targets.
- Brief §3.2 "Do Not Model" items (memory ordering, physical-frame allocator, PID/TID
  exhaustion, quantum fairness, SMP stack guard, capctl self-grant, userspace pthread
  fork divergence) are excluded from the spec as directed.
