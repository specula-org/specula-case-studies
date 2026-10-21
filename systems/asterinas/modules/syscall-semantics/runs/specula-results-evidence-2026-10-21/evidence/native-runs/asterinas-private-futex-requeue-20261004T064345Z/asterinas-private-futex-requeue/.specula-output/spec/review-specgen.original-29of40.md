# Spec Generation Review: asterinas-private-futex-requeue

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All four scenarios have extensions and targeting configurations. The suite includes F00–F10, separate quota controls, the moved-owner check, and the later live-migration consequence. |
| Action Design | 3/5 | Actions follow implementation functions and separate registration, notification, transfer, cleanup, and closure. Timer sampling and scheduler return behavior have the fidelity gaps described below. |
| Source Annotations | 4/5 | Source aliases resolve to the pinned implementation, and action blocks generally cite the relevant ranges. The parking abstraction cites the caller but omits the scheduler contract that permits spurious returns. |
| Invariant Coverage | 5/5 | All eight brief safety obligations are enabled across the hunt configurations. Quota findings are isolated from ownership findings, and a separate configuration enables completion properties with explicit fairness. |
| MC Spec Structure | 5/5 | Budgets bound client admission, stores, and recoverable faults. Reactive completion remains unbounded. Controller symmetry, a budget-preserving view, finite capacity, and a separate liveness configuration are present. |
| Trace Spec Design | 3/5 | Every wrapper calls its base action and checks a mandatory post-state record. There are no silent kernel actions. However, clock samples are not bound to their consumers, and valid spurious park returns cannot be replayed. |
| Instrumentation Mapping | 3/5 | All 52 primitive actions have corresponding wrappers and mapping rows. The timer mapping loses the association between a read and its consumer, and the scheduler mapping cannot encode every allowed return from parking. |
| Logical Correctness | 1/5 | SANY and configuration parsing pass, but mixed string, integer, and tuple representations cause TLC evaluation errors. The suite needs these errors fixed before exploration or replay can assess its properties. |

## Overall: 29/40

The review checked the seven requested spec/config/mapping files against the modeling brief and source commit `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. It also inspected `brief-coverage.md` and all 15 hunt configurations. The reviewed artifacts match their hashes in `generation-manifest.json`.

Fresh checks passed SANY parsing and semantic analysis for all three modules, parsing of all 18 configurations, resolution of their configured operator names, and the 52-action mapping audit. Isolated value-operation probes against the installed `tla2tools.jar` reproduced the evaluation errors in issue 1. These checks did not run state-space exploration, implementation-trace replay, kernel execution, confirmation, or classification. Issues 2 and 3 are static source-to-spec findings.

## Issues Found

- **[P1] Replace incompatible sentinel and payload representations before running TLC.** `base.cfg:12` and `MC.cfg:12` mix `"never"` with numeric durations. `base.tla:139` compares a duration with `0`, while `MC.tla:76` compares it with `"never"`. Either direction can compare incompatible TLC value types. The same problem affects ownership and optional IDs: `No` is the string `"none"` (`base.tla:29`), lock owners are tuples (`base.tla:30–33`), and active call/temporary item IDs are integers. Lock guards compare tuple owners with `No` (`base.tla:91,281,285`), owner domains mix strings and tuples (`base.tla:427,444`), and `Owners` compares an idle call's string-valued `temp` with a numeric generation (`base.tla:472–473`). This affects both MC and Trace, including core invariant evaluation.

  Direct probes produced `Attempted to check equality of integer 0 with non-integer: "never"` and `Attempted to check equality of the function <<"wait", 1>> with the value: "none"`. Normalizing the corresponding heterogeneous sets also failed. Parsing does not evaluate these comparisons. Use consistently typed/tagged representations for durations, owners, and optional IDs, and update the NDJSON normalization and post-state schema to match. Validate initialization and reachable transitions after that change.

- **[P2] Preserve each timer operation's sampled time instead of substituting the latest global sample.** `TimerSetTimeout`, `PauseTimeoutRemain`, and `TimerCollect` use the current `s.now` (`base.tla:145–148,169–172,193–197`). In the implementation, deadline calculation uses a local read at `kernel/core/src/time/core/timer.rs:67–68`, `remain` uses its own local read at `106–109`, and an entire collection loop uses the single `current_time` captured at `206–215`. Trace records these reads as separate `ClockAdvance(t)` events without a generation, consumer, or collection-batch identity (`Trace.tla:90,503–506`; `instrumentation-spec.md:209–217`). Another stream can advance `s.now` before the dependent action, so the action need not use the clock value that its implementation invocation actually read.

  For example, a collection invocation samples time 1 and collects a timer whose deadline is 1. Another CPU then records time 2. The model now permits the first invocation's next `TimerCollect` to collect a timer whose deadline is 2 without another collector clock-read event. The source loop must stop at that timer because its saved `current_time` is still 1. Mandatory post-state equality does not detect this because it checks only the resulting callback/timer state. Preserve sampled times in operation or batch locals, bind each trace read to its consumer, and use those snapshots for deadline and expiry decisions. Keep global clock advancement separate from consumption of an earlier read.

- **[P2] Represent permitted spurious returns from `park_current` in trace replay.** `WaiterPark` moves an unnotified waiter to `"sleep"` (`base.tla:155–158`). Only the modeled timer or futex unpark actions move that generation back to `"wait"` (`base.tla:219–222,307–310`). However, `ostd/src/task/scheduler/mod.rs:441–444` explicitly permits `park_current` to return because of a spurious wake. `Waker::do_wait` handles this by repeating its atomic swap and parking loop (`ostd/src/sync/wait.rs:272–275`), without requiring an accepted notification on that Waker.

  A valid trace can therefore contain a park decision with a false flag followed by another `WakerDoWait` swap returning false, with no intervening accepted futex or timer wake for this generation. Its second swap cannot match `WakerDoWait`'s `pc="wait"` guard (`base.tla:151–154`). The mapping requires these swaps to be recorded (`instrumentation-spec.md:111–112`), and `TraceNext` provides no silent transition that could account for the scheduler return (`Trace.tla:563–571`). Represent the scheduler return explicitly, or define a trace normalization that validates and collapses these retry iterations. Keep accepted-notification and completion observers tied to actual Waker operations.

## Verdict: NEEDS_IMPROVEMENT
