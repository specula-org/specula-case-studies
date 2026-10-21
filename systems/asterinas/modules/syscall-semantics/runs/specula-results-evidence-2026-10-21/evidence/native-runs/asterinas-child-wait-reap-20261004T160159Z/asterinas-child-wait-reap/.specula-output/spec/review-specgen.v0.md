# Spec Generation Review: asterinas-child-wait-reap

Reviewed on 2026-10-05 by Codex as the independent spec-generation reviewer. The source is clean at `0c60537098f4c2949ad2d382aaf499de72263d76`. The review covers the eight requested inputs and checks the five hunt configurations and `brief-coverage.md` for actual property coverage.

All 14 artifact hashes and 22 source hashes in [generation-manifest.json](generation-manifest.json) matched the reviewed files. That manifest's SHA-256 is `9cc2876192321d48309c64c20ab1965983853a28ad548bb5f1eb0cc711cf809a`. The modeling brief's SHA-256 is `617152b69d965ae31c904d458561ffe9d2842ba959a4d9bf328fa00e7d45c93f`.

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All five scenarios have corresponding state, actions, and hunt configurations. The model includes repeated observations, retained output after removal, both wake channels, publication, and API-specific results. WR-SQ and WR-CF remain separate controls as requested. |
| Action Design | 5/5 | The 41 actions follow implementation functions and preserve the important selection/removal/output, registration/recheck, queue-pop/wake, and park-check/dequeue boundaries. Cleanup and scheduler projections have explicit assumptions. |
| Source Annotations | 5/5 | Action-sized logic blocks and trace dispatch/post-state arms cite source locations. Targeted reads at the pinned revision support the claim, lifetime, notification, atomic-ordering, and scheduler references. |
| Invariant Coverage | 3/5 | All brief safety obligations are defined and enabled in a hunt. However, `TypeOK` fails to evaluate on a completed call, and the general blocking-completion obligation is enabled only for initial consuming calls. See R1 and R3. |
| MC Spec Structure | 5/5 | Client admissions and optional spurious returns are bounded, as the brief permits. Reactive steps remain enabled. Safety configurations use symmetry, the temporal configuration does not, and the full state retains budgets. Omitting a queue-size constraint avoids discarding reactive schedules. |
| Trace Spec Design | 3/5 | Every event calls its base action and validates an exact post-state record. There are no silent actions, and completion checks cover notifier/call cleanup. The universal completion property can nevertheless reject a valid overlapping trace. See R2. |
| Instrumentation Mapping | 5/5 | Independently checked equality of the 41 base-action names, event names, dispatch arms, post-state arms, and mapping rows. Hooks specify source boundaries, generation identities, atomic return values, protected snapshots, and API output fields. |
| Logical Correctness | 2/5 | The ownership and publication logic agrees with the inspected source, but an executed TLC check aborts at an ordinary successful return. The trace acceptance quantifier also needs correction. These prevent acceptance of the suite. |

## Overall: 33/40

Independent validation included source comparison, hash verification, action/mapping and configuration audits, a successful [SANY check of Trace.tla](output/review-specgen/trace-sany.log), and one bounded TLC run of the unchanged `MC.tla` with `MC_hunt_3_wakeup.cfg`. The TLC allocation was one worker, 1 GiB heap, 512 MiB off-heap, and a one-minute limit. It exited with code 76 after 11 seconds because of R1, after generating 8,374 states and finding 3,827 distinct states. It did not complete safety or liveness verification. No implementation traces or guest/Linux controls were executed, and no specification or configuration was edited.

## Issues Found

- **R1 — High: `TypeOK` aborts on a normal completed syscall.** In `base.tla:407`, `c.ret \in {"pending", -10, 0, ChildPid}` mixes a string sentinel with integers. `NewCall` initializes the sentinel at line 51, and `SysWaitReturn` changes it to an integer at lines 271–277. In the executed wakeup configuration, state 17 has T1 at `pc = "return"` with `ret = "pending"`. State 18 completes the successful wait4 with `ret = 41`, where evaluating `TypeOK` aborts. The exact diagnostic is:

  ```text
  Error: Evaluating invariant TypeOK failed.
  Attempted to check equality of string "pending" with non-string:
  41
  ```

  Every shipped configuration enables `TypeOK`, so this affects the reference, MC, hunt, and trace checks. This is a specification evaluation error, not a violated kernel contract. Use a TLC-compatible return representation, such as a numeric sentinel outside the fixture's possible results or a suitable model value, and review all pending/completed uses together. Preserve the normal numeric return checks. Evidence is in the [TLC log](output/review-specgen/wakeup-tlc.log), [process result](output/review-specgen/wakeup-result.json), and [18-state trace](output/review-specgen/MC_TTrace_1791178960.tla). The TLC log's SHA-256 is `cfcdc73b0f346e5a2ff1468c56f50db739839640e98b50406b638101cfb896a3`.

- **R2 — Medium: trace acceptance requires every speculative ordering to finish.** `Trace.tla:142–146,514–526` explores overlapping events nondeterministically, then `Trace.cfg:8` requires `TraceMatched` universally. Weak fairness cannot rescue a prefix where `TraceAdvance` has become disabled. A valid trace can therefore fail because one speculative ordering gets stuck, even when another ordering consumes every event.

  A static witness uses two pending `TryWaitChildrenLock` events with intervals T1 `[10,20]` and T2 `[11,100]`. Both are initially viable. The actual execution lets T1 acquire, execute its protected steps, and unlock before T2 acquires. T2 can have started its acquisition interval before being descheduled or waiting for the lock. If replay instead chooses T2's acquisition first, T1's acquisition is disabled by `childrenOwner = T2`. T2's next event, starting after 100, is blocked by T1's still-pending event, which ended at 20. With no other pending actor event, the replay can stutter forever and violate `TraceMatched`. The correct T1-first replay remains available. The source mutex permits the actual ordering (`ostd/src/sync/mutex.rs:35–36,62–69`).

  `instrumentation-spec.md:132` correctly acknowledges this limitation, so a failing branch must not be reported as a kernel mismatch. However, the delivered checker has no executable criterion for accepting the alternative complete match. Provide a completion-reachability search that accepts a fully validated witness and distinguishes exhausted no-match searches from inconclusive runs. Keep the base-action, post-state, and final-state checks. This finding is a static trace-design result, not an executed trace replay.

- **R3 — Medium: the general blocking-completion property omits observers and later invocations.** The brief at `modeling-brief.md:150` requires every eligible outstanding blocking call to finish after exit under the stated progress assumptions. `MCBlockingWaitCompletes` is enabled only by `MC_hunt_3_wakeup.cfg:9–13`. That configuration selects `Hunt = "wake"`, which excludes WNOWAIT in `MC.tla:17` and admits only the first call on each thread at line 26. The observation and publication hunts permit blocking WNOWAIT calls but enable no temporal properties. Consequently, the per-generation property at `MC.tla:75–79` does not provide configured liveness coverage for blocking observers or later generations.

  Retain the restricted two-consumer fixture for `MCCompetingConsumersComplete`, and add a fair configuration for the general completion obligation with blocking WNOWAIT and repeated invocations admitted. Alternatively, provide a reviewed argument showing why the excluded behaviors follow from the checked fixture. Definition of the property alone does not establish this coverage. This is a configuration-coverage finding, not an observed nonterminating kernel execution.

## Verdict: NEEDS_IMPROVEMENT

R1 blocks executable verification. Resolve the trace acceptance and completion-coverage gaps before treating the suite as complete. The source-faithful action decomposition and instrumentation mapping can be retained.
