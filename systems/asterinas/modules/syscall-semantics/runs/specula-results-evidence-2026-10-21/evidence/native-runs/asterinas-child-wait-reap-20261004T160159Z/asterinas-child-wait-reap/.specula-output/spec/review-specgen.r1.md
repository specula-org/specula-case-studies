# Spec Generation Review: asterinas-child-wait-reap

Reviewed on 2026-10-05 by Codex. This review covers the eight requested inputs, all six scenario hunt configurations, `TraceSearch.cfg`, and the accompanying coverage and revision evidence. The source is clean at commit `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`.

All 43 artifact hashes and 22 source hashes in [generation-manifest.json](generation-manifest.json) match the reviewed files. The manifest's SHA-256 is `a86b2cbbc5b01faf25d673f299a865f1d76e554924337c7a926686af8b4730db`. The modeling brief's SHA-256 is `617152b69d965ae31c904d458561ffe9d2842ba959a4d9bf328fa00e7d45c93f`. The previous review is preserved in [review-specgen.v0.md](review-specgen.v0.md).

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All five scenarios have corresponding state, actions, and targeting configurations. Four admissions allow two observations, consumption, and a fresh post-reap call. WR-SQ and WR-CF remain separate controls, as the brief requires. |
| Action Design | 5/5 | The 41 actions follow implementation functions and preserve selection/removal/output, registration/recheck, queue-pop/wake, and park-check/dequeue boundaries. Retained generations, duplicate queue entries, both notification channels, and delayed unpark are represented. Cleanup and scheduler projections state their assumptions. |
| Source Annotations | 5/5 | Implementation action blocks and trace dispatch/post-state arms cite source locations. Targeted source reads support the ownership, lifetime, notification, publication, and scheduler mechanisms. R4 concerns the specified capture boundary, rather than a missing source citation. |
| Invariant Coverage | 5/5 | Every brief safety obligation is enabled in a hunt. The new general fair configuration enables per-generation blocking completion for WNOWAIT and repeated calls. The restricted fixture retains competing-consumer completion. Configured coverage does not establish an exhaustive liveness pass. |
| MC Spec Structure | 5/5 | Only environmental admissions and optional spurious returns receive budgets. The brief explicitly permits finite client activity. Reactive transitions remain uncapped. Safety configurations use symmetry and temporal configurations omit it. The full state retains budgets, and omitting a queue constraint avoids pruning valid retries. |
| Trace Spec Design | 5/5 | Every event invokes its full base action and checks exact arguments and post-state. There are no silent actions. `TraceSearch.cfg` supplies existential completion with final-state checks, while `Trace.cfg` is documented as a stricter diagnostic. R4 identifies a mismatch in the producer's prescribed hook. |
| Instrumentation Mapping | 4/5 | The 41 action names, event names, dispatch arms, post-state arms, and mapping rows agree, including every mapped post-field set. However, the true branch of `ParkCurrentCheck` requires a different capture boundary from the documented one. See R4. |
| Logical Correctness | 5/5 | The numeric pending-return marker fixes the previous TLC evaluation error. The enabled invariants and temporal formulas have no additional identified tautology, impossible guard, or operator typo. The source-supported sequentially consistent projection is explicitly limited and does not claim weak-memory verification. |

## Overall: 39/40

Fresh checks in this review passed SANY parsing and semantic analysis for `base.tla`, `MC.tla`, and `Trace.tla`. TLC's `ModelConfig.parse` accepted all ten configurations without starting a model checker. An independent static audit confirmed one-to-one correspondence for all 41 actions, exact post-field correspondence, and actual property enablement. No specification, configuration, instrumentation, or kernel source was changed.

The existing revision evidence was checked against current input hashes and the recorded log hashes. The publication hunt completed with 1,005,898 distinct states and depth 77. The other six MC runs were time-limited. In particular, the general blocking and restricted wakeup checks did not finish, so neither supplies an exhaustive liveness result. The two positive synthetic witnesses each contain 28 states, complete actor cursors, final cleanup, and numeric returns 41 and -10. The corrupted synthetic input exhausted its search without a complete match. These are inspected prior runs, not new TLC executions by this reviewer. See [generation-checks/results.json](generation-checks/results.json) and [generation-checks/results.md](generation-checks/results.md).

The prior findings are resolved at the specification/configuration level:

- **R1 is resolved.** `base.tla:19,47-54,398-410` uses numeric `PendingRet = -9999`, outside the possible ABI results. The retained completed-call witnesses and publication run use this exact base hash without the old type-evaluation failure.
- **R2 is resolved.** `Trace.tla:534-537` and `TraceSearch.cfg:6-14` search for a complete matching interleaving while retaining the existing safety and final-state checks. `instrumentation-spec.md:134-146` distinguishes acceptance, exhausted rejection, and inconclusive execution. The unchanged universal `Trace.cfg` can still reject a valid overlapping trace and is explicitly not the acceptance criterion.
- **R3 is resolved as a coverage gap.** `MC_hunt_3_blocking.cfg:6-17` selects four admissions, all request types, and `MCBlockingWaitCompletes` under `MCFairSpec`. `MC_hunt_3_wakeup.cfg` retains the narrower two-consumer obligation. The recorded time limits remain incomplete verification results.

## Issues Found

- **R4 — Medium: the documented park-check hook captures a different lock state from the event's required post-state.** [instrumentation-spec.md](instrumentation-spec.md), line 90, places `ParkCurrentCheck` after the `has_unparked` Acquire load while the local runqueue lock is held. Line 44 defines `rqHeld` as ownership of that park critical section and requires concrete lock-boundary evidence. However, [base.tla](base.tla), lines 204-207, sets `rqHeld' = ~token`. When the observed token is true, its post-state is `pc = "token"` and `rqHeld = FALSE`. [Trace.tla](Trace.tla), lines 261-265 and 378, requires that exact record.

  This branch is reachable when `WakerConsumeToken` reads false, the child publishes and performs `WakerWakeUp`, and the waiter then executes `ParkCurrentCheck`. In the implementation, the successful `has_unparked()` check occurs inside the locked callback at [ostd/src/task/scheduler/mod.rs](../../source/ostd/src/task/scheduler/mod.rs), lines 453-456. [ClassScheduler::mut_local_rq_with](../../source/kernel/core/src/sched/sched_class/mod.rs), lines 255-258, retains the guard until the callback returns. At the prescribed after-load hook, the waiter therefore still owns the lock. Capturing that concrete state yields `observedToken = TRUE, rqHeld = TRUE`, which cannot satisfy the trace wrapper. Reporting `FALSE` at that same point would contradict the documented field meaning.

  Specify capture timing separately for the two branches. The false branch must retain the existing check/dequeue interleaving window. For the true branch, the represented operation must include the corresponding runqueue-lock release before its post-state and interval endpoint are recorded, or the model must represent that release separately. Also make explicit that `ParkCurrentResume` is emitted only for the dequeued path: the current true branch advances directly to the token loop. Preserve the actual atomic-load result and the exact post-state checks.

  This is a static source-to-instrumentation mismatch, not an observed kernel defect or an executed trace failure. Neither retained positive synthetic fixture contains `ParkCurrentCheck`, `ParkCurrentDequeue`, or `ParkCurrentResume`, so those fixtures do not exercise this boundary.

## Verdict: NEEDS_IMPROVEMENT

Resolve R4 before using the instrumentation handoff for acceptance traces. The previous three findings are closed, and no additional defect was identified in the base protocol or MC formulas. Full liveness verification, implementation trace collection, Linux/Asterinas runtime controls, WR-SQ, and WR-CF remain unproven or not run as recorded above.
