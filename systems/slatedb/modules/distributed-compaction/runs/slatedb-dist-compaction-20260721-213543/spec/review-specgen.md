# Spec Generation Review: slatedb-dist-compaction

## Scores
| Criterion | Score | Notes |
|-----------|-------|-------|
| Bug Family Coverage | 3/5 | All five families appear in `base.tla`, but Family 4 is reduced mostly to refresh/version bookkeeping and the drain-specific branch is dead under the shipped defaults because `DefaultJobKind` makes every job `TieredKind` (`spec/base.tla:107-108`, `spec/MC.cfg:41-49`). |
| Action Design | 4/5 | The submit/validate/claim/execute/publish flow is split well and mostly follows implementation boundaries. The main gap is `MaybeValidateSubmittedDrain`, which collapses checkpoint, manifest, and `.compactions` completion into one step instead of preserving Family 2 crash windows (`spec/base.tla:625-654`). |
| Source Annotations | 2/5 | Action headers usually cite source ranges, but helper operators and invariants do not, and the instrumentation table names files without line numbers. This does not meet the “every logic block cites file:line” bar (`spec/base.tla:265-367`, `spec/base.tla:1090-1212`, `spec/instrumentation-spec.md:88-114`). |
| Invariant Coverage | 3/5 | The expected invariants are present by name, but some are too weak for the targeted bug families. `FencedWriterCannotOverwriteFreshState` is only `EpochAlignment /\\ ViewVersionsMonotone`, and `OnlyCurrentOwnerPublishes` does not encode claim-generation or stale same-worker publish safety (`spec/base.tla:1179-1184`, `spec/base.tla:1203-1205`). |
| MC Spec Structure | 2/5 | `MC.tla` has symmetry, a view, and a constraint, but `MC.cfg` comments out all of the bug-family safety invariants, so the shipped model is not actually checking the main findings. The bounded actions also include normal clocks/GC/checkpoint refresh, not only fault injection (`spec/MC.cfg:61-85`, `spec/MC.tla:58-81`). |
| Trace Spec Design | 3/5 | Visible-event replay is strong because every logged action validates the full captured post-state. The main weakness is the replay `VIEW`, which hides checkpoint/version/epoch/buffered-context fields that affect enabledness and can merge distinct trace states (`spec/Trace.tla:140-172`, `spec/Trace.tla:471-474`, `spec/Trace.cfg:52`). |
| Instrumentation Mapping | 2/5 | The mapping is not 1:1. `AdvanceCoordinatorClock`, `AdvanceWorkerClock`, and `ExpireCheckpoint` are modeled actions but are absent from the action table, and `MaybeValidateSubmittedDrain` is explicitly “reserved” rather than implemented (`spec/instrumentation-spec.md:88-119`). |
| Logical Correctness | 2/5 | TLC successfully parsed `MC.tla`/`base.tla` and began state exploration, so there is no immediate syntax or semantic failure. However, several properties are weak or misleading: the Family 4 fence invariant is near-tautological, the drain crash window is missing, and `TimedOutOrFailedJobsDoNotLivelock` is not supported by fairness in `BaseSpec` and is disabled in `MC.cfg` (`spec/base.tla:625-654`, `spec/base.tla:1203-1205`, `spec/base.tla:1218-1221`, `spec/MC.cfg:84-85`). |

## Overall: 21/40

## Issues Found
- `MC.cfg` disables the primary bug-family safety checks by commenting out `NoConflictingActiveCompactions`, `BoundedRunningClaims`, `SinglePublishPerCompaction`, `OnlyCurrentOwnerPublishes`, `ManifestReferencesExistingFiles`, `NoPrematureReclaim`, and `RecoverySafeTerminalRelation`. The generated MC model therefore does not check the main review targets out of the box (`spec/MC.cfg:75-85`).
- Family 4 is under-modeled. `FencedWriterCannotOverwriteFreshState` does not express overwrite prevention or post-merge repair; it only restates epoch/version monotonicity (`spec/base.tla:1203-1205`).
- The drain path is effectively untested in the shipped models. `DefaultJobKind` assigns every job `TieredKind`, so `MaybeValidateSubmittedDrain` is unreachable under the provided configs, and the instrumentation note says the corresponding event is not emitted yet (`spec/base.tla:107-108`, `spec/base.tla:625-654`, `spec/MC.cfg:41-49`, `spec/instrumentation-spec.md:98`, `spec/instrumentation-spec.md:118`).
- `MaybeValidateSubmittedDrain` also skips the Family 2 durability split by updating checkpoint, manifest, and durable compaction state in one action, so crash/recovery interleavings are missing for that branch (`spec/base.tla:625-654`).
- Trace replay uses `VIEW TraceView`, but that view omits checkpoint state, versions/epochs, `compactionsExists`, `bufferedCtx`, and `outputTs`. Because those fields participate in action guards and validation, TLC can merge distinct replay states (`spec/Trace.tla:140-172`, `spec/Trace.tla:471-474`, `spec/Trace.cfg:52`).
- Source annotations are incomplete. The main helper logic and invariant blocks have no source citations, and the instrumentation table does not provide exact code lines (`spec/base.tla:265-367`, `spec/base.tla:1090-1212`, `spec/instrumentation-spec.md:88-114`).
- `OnlyCurrentOwnerPublishes` is weaker than the brief’s MC3 target. It constrains current `Compacted` states but does not represent claim generation or stale same-worker execution after reclaim (`spec/base.tla:1179-1184`, `modeling-brief.md:214-215`).
- `TimedOutOrFailedJobsDoNotLivelock` is not currently actionable: `BaseSpec` has no fairness, and the property is commented out in `MC.cfg` (`spec/base.tla:1218-1221`, `spec/MC.cfg:84-85`).

## Verdict: NEEDS_IMPROVEMENT
