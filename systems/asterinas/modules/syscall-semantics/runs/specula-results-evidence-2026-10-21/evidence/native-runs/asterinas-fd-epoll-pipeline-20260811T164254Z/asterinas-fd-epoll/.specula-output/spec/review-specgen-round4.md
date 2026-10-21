# Spec Generation Review: asterinas-fd-epoll

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All six brief scenarios have dedicated variables, source-backed actions, invariants/properties, and focused MC configs. |
| Action Design | 3/5 | Most actions use implementation names and expose important semantic boundaries. Signal enqueue/notify and terminal readiness still collapse or conflate distinct production steps. |
| Source Annotations | 4/5 | All 71 production action blocks and all 36 invariant/property blocks contain pinned `kernel/...rs:line` citations. Several subordinate Trace validation branches rely on the separate instrumentation table instead of carrying their own citation. |
| Invariant Coverage | 4/5 | Every brief section-5 property is defined, wrapped, and enabled in at least one focused config. Some oracles are construction-only or fail to observe the state named by the brief. |
| MC Spec Structure | 4/5 | Introduction/request actions are counter-bounded; deterministic completion actions are reactive and unbounded. Symmetry, view, and a state constraint are present. The neutral config explores only five FD actions and enables three scenario invariants despite its “core/structural only” description. |
| Trace Spec Design | 3/5 | The Category B timebox ordering, direct base-action dispatch, exact callback selection, and post-state checks are substantial. There are no silent actions. Completion and several action-specific post-state checks are incomplete. |
| Instrumentation Mapping | 5/5 | The 71 unique `Trace.MatchEvent` names, 71 instrumentation rows, 71 `MC.ActionNames`, and 71 base actions match exactly; every row supplies a production location and trigger boundary. |
| Logical Correctness | 3/5 | SANY and the exercised TLC configs succeed as intended, but the terminal-readiness abstraction, truncated-trace acceptance, and construction-tautological oracles leave material blind spots. |

## Overall: 31/40

## Issues Found

- **Scenario 5 does not evaluate live readiness at terminal selection.** `WaiterReadinessWake` sets `visibleReady` when a selected Waker callback runs (`base.tla:2149-2176`), and timeout/signal returns merely copy that historical flag into `terminalReady` (`base.tla:2226-2254`). The invariant then checks only `terminalReady` (`base.tla:2882-2889`). A reachable ordering can execute `TimerfdExpired`, `TimerfdNotify`, timeout, and timeout return before `WaiterReadinessWake`; `sourceReady[TimerOFD]` is true, but `terminalReady` remains false and the oracle is vacuous. Conversely, readiness may be consumed after a wake while `visibleReady` remains true. This does not implement the brief's “ready at the terminal scan” condition. Add a source-backed terminal scan/snapshot and make the oracle compare the chosen result with that live snapshot.

- **Signal queue mutation and notification are incorrectly atomic.** Both `SigQueuesEnqueueThread` and `SigQueuesEnqueueProcess` update pending state and select callbacks/Wakers in one action (`base.tla:1915-2004`). The implementation mutates under `queues.lock()`, explicitly drops that guard, and only then calls `signalfd_pollee.notify` (`kernel/core/src/process/signal/sig_queues.rs:38-45`). Registration, mask changes, and other threads can interleave at that boundary. Split enqueue from notification and carry a pending-notify obligation, as the timerfd/eventfd paths already do.

- **Trace completion accepts truncated non-callback operations.** Once all JSON events are consumed, `TraceNext` can only stutter (`Trace.tla:613-616`), while `TraceMatched` requires only event consumption and synchronous-callback quiescence (`Trace.tla:623-641`). A trace can end after `FcntlSetFlCapture`, `SaveAndSetSigMask`, an epoll control capture, or another intermediate step and still match. In particular, ending after `SaveAndSetSigMask` leaves `savedMask` set and `waitState = "mask_set"`; `TemporaryMaskRestored` remains vacuous because no transition reaches `"returned"`. Require quiescent operation PCs and discharged restore/cleanup obligations at trace completion, or emit and validate an explicit end-state event.

- **Post-state validation omits fields changed by some base actions.** For example, `EntryPollDeadFile` clears `interestIdentity`, `registered`, `entryEnabled`, and `pollerBindings` as well as `interest` and `delivery` (`base.tla:1358-1378`). Its Trace branch checks only delivery, interest membership, and OFD liveness (`Trace.tla:325-328`), and the instrumentation row requests the same subset. Capture and validate every key modified field. Similar gaps exist for readiness epochs and epoll wake/epoch updates.

- **Several named oracles are not independent bug detectors.** `SlotMapsOneOFD` repeats the function typing already enforced by `TypeOK` and adds an empty-slot flag condition (`base.tla:2680-2685`). `TemporaryMaskRestored` can hold only because the sole modeled transition to `"returned"` performs the restore (`base.tla:2281-2289,2891-2897`). `AcyclicEpollGraph` is preserved by guards that exclude every cycle-producing insertion (`base.tla:2299-2308,2666-2674`). Add mutation-sensitive controls or explicit obligation/error branches where these properties are intended to provide independent coverage.

- **Validation rerun:** SANY parsed `base.tla`, `MC.tla`, and `Trace.tla` with exit 0. `MC.cfg` completed with 288 generated / 156 distinct states at depth 7. `Trace.cfg` completed with 33 / 32 states at depth 32. The wrong-actor, omitted-callback, and early-owner-release fixtures each failed `TraceMatched` as intended. `MC_hunt_s5_arbitration.cfg` reproduced the intended `MCVisibleReadyWinsTerminalRace` violation at depth 7.

## Verdict: NEEDS_IMPROVEMENT
