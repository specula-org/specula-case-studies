# Spec Generation Review: asterinas-child-wait-reap

Reviewed on 2026-10-06 against Asterinas commit `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. The source worktree is clean, and all 22 source hashes in the generation manifest match. All eight requested inputs were reviewed and remained unchanged during this review. The six scenario hunt configurations, `TraceSearch.cfg`, coverage audit, and retained validation evidence were also inspected because the main configurations delegate checks to them.

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All five brief scenarios have corresponding state, actions, and enabled hunt checks. Four admissions in the observation and general blocking configurations preserve two observations, consumption, and a fresh invocation. WR-SQ and WR-CF remain separate controls as the brief requires. See `brief-coverage.md:9-37` and the actual `MC_hunt_*.cfg` declarations. |
| Action Design | 5/5 | The 41 actions follow implementation functions and preserve the important boundaries: protected selection/removal, later output, registration/recheck, signal notification, queue pop/wake, and park check/dequeue/unpark. Divergent outcomes have distinct actions or explicit branches. See `base.tla:78-363`. |
| Source Annotations | 5/5 | All implementation action blocks have source references, and trace dispatch/post-state arms repeat their locations. Targeted inspection confirmed those references against the pinned source. History variables, fixture assumptions, and projected cleanup/scheduler internals are explained separately. |
| Invariant Coverage | 5/5 | Every safety obligation in brief §5 is defined and enabled in at least one hunt. General blocking completion covers WNOWAIT and later generations. The competing-consumer property is enabled in its restricted two-consumer fixture, which makes its antecedent reachable. See `base.tla:427-503`, `MC.tla:75-84`, and both Scenario 3 configurations. |
| MC Spec Structure | 5/5 | Counters bound client admissions and optional spurious scheduler returns. Reactive scanning, cleanup, notification, and completion remain uncapped. Safety configurations use thread symmetry, while temporal configurations omit it. Keeping the complete state, including budgets, and omitting queue constraints avoids hiding enabledness or dropping reactive schedules. No additional VIEW or message-buffer constraint is needed for this fixture. See `MC.tla:23-71`. |
| Trace Spec Design | 5/5 | Per-actor cursors and interval ordering preserve concurrent choices. There are no silent actions. Every event invokes its full base action and checks exact arguments and post-state. `TraceEndOK` checks completed calls and notification. Existential acceptance uses `TraceSearch.cfg`; `Trace.cfg` is explicitly documented as a stricter universal diagnostic. See `Trace.tla:130-170,378-537` and `instrumentation-spec.md:139-151`. |
| Instrumentation Mapping | 5/5 | An independent assembly check confirms identical sets of 41 actions, event names, argument schemas, dispatch arms, post-state arms, and mapping rows. Required post fields also agree. The corrected park timing now matches the source: a false check ends under the runqueue guard, a true check ends after its release, and resume is emitted only after dequeue. See `instrumentation-spec.md:90-92,124-135`. |
| Logical Correctness | 5/5 | No actionable tautology, impossible guard, missing state update, or temporal-property typo was found. Numeric pending returns fit `TypeOK`. Invocation history preserves late observations and completion obligations. The publication/output rules match the normal-exit source paths. Finite MC temporal properties use guarded invocation lookups and explicit progress assumptions. All three modules pass fresh SANY semantic checks. |

## Overall: 40/40

Checks executed during this review were SANY parsing and semantic analysis of all three modules, TLC `ModelConfig.parse` for all ten configurations, action/field/coverage consistency checks, source-hash verification, and inspection of the retained witnesses. No new TLC exploration, kernel build, guest execution, or implementation trace collection was performed.

The park projection was checked against `ostd/src/task/scheduler/mod.rs:453-485,575-584`, `kernel/core/src/sched/sched_class/mod.rs:223-259,410-414`, and `ostd/src/sync/wait.rs:262-281`. The true branch can combine the saved token observation with lock release because this waiter does not change the token between them. The false branch keeps the check/dequeue window open to a wake-token swap, while unpark completion waits for the runqueue lock. The revised capture instructions preserve that distinction.

Retained results were checked against their logs and current input hashes. The publication hunt exhausted 1,005,898 distinct states at depth 77. The other six MC searches remain time-limited, including both liveness configurations. Four accepted synthetic inputs have complete witnesses with 28, 28, 55, and 57 states. The corrupted input exhausted its search without a complete match. The universal overlap diagnostic still violates `TraceMatched`, consistently with the documented speculative-ordering limitation. Acceptance must follow `TraceSearch.cfg` and the witness rules in `instrumentation-spec.md:141-151`.

These results establish review and checker evidence within the declared fixture. They do not complete the outstanding liveness checks or establish kernel runtime behavior. The memory-order projection assumes the cited synchronization bridges, and nested-lock progress remains an explicit assumption. Weak-memory proof, Linux controls, implementation traces, WR-SQ, and WR-CF remain outside this review's executed validation.

## Issues Found

- No actionable correctness or completeness defects were found in the current generated suite. The previously documented park capture mismatch is resolved by the current branch-specific instructions and source mapping.

## Verdict: PASS

The generated suite satisfies the review checklist within the modeling brief's scope. This verdict accepts the spec-generation design and instrumentation contract. The time-limited model checks and unexecuted runtime controls retain their existing verification status.
