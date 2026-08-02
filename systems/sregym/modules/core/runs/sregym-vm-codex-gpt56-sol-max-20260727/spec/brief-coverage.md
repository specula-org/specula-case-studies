# Modeling Brief Coverage Audit

This audit was completed against the generated `base.tla`, `MC.tla`, and the
four actual `MC_hunt_scenario*.cfg` files. The modeling brief is the sole source
of required coverage.

## Brief §2 scenarios

| Brief scenario | Targeting hunt config | Reachability setup | Target checks enabled |
|---|---|---|---|
| 1. Evaluation and teardown have no common completion fence | `MC_hunt_scenario1.cfg` | One accepted submission; `MaxTimeoutLimit = 1` and `MaxExitLimit = 1`; evaluation completion and cleanup remain unbounded reactive steps | `DoneIsTerminal`, `NoEvaluationDuringTeardown`, `NoOverlappingRuns`, `FaultBeforeDiagnosis`, plus `ReferenceStageOrder` |
| 2. Submission acknowledgments are not correlated to run or stage | `MC_hunt_scenario2.cfg` | Two sends, one duplicate, and two retries; receipt, acceptance, grading, and acknowledgment are separate actions | `OneAcceptedPerStage`, `SubmissionOriginMatches`, plus `ReferenceStageOrder` |
| 3. Crash/restart trusts an unversioned, possibly partial baseline | `MC_hunt_scenario3.cfg` | Two run starts; one observation failure, mutation, crash, cluster replacement, and timeout; load/reconcile steps remain unbounded | `BaselineMatchesCluster`, `PreexistingResourcesPreserved`, `CleanupDeletesOnlyRunOwned`, plus `ReferenceStageOrder` |
| 4. Stop noise does not establish oracle quiescence | `MC_hunt_scenario4.cfg` | Two run starts and submissions; one noise apply, join timeout, mitigation, and pod restart; apply completion and Khaos reattachment remain unbounded | `NoOverlappingRuns`, `FaultBeforeDiagnosis`, `NoiseQuiescentAtEvaluation`, `OraclePassImpliesMitigated`, plus `ReferenceStageOrder` |

There is one hunt config per scenario; no scenarios are merged.

## Brief §5 proposed invariants

`MC.tla` extends `base.tla`, so the named base invariants below are directly
wired into the MC module and selectable from every MC config.

| Brief invariant | Type | Defined in | Enabled in actual hunt cfg(s) | Audit status |
|---|---|---|---|---|
| `ReferenceStageOrder` | Safety | `base.tla` | Scenarios 1, 2, 3, 4 | Covered |
| `OneAcceptedPerStage` | Safety | `base.tla` | Scenario 2 | Covered |
| `SubmissionOriginMatches` | Safety | `base.tla` | Scenario 2 | Covered |
| `DoneIsTerminal` | Safety | `base.tla` | Scenario 1 | Covered |
| `NoEvaluationDuringTeardown` | Safety | `base.tla` | Scenario 1 | Covered |
| `NoOverlappingRuns` | Safety | `base.tla` | Scenarios 1 and 4 | Covered |
| `FaultBeforeDiagnosis` | Safety | `base.tla` | Scenarios 1 and 4 | Covered |
| `BaselineMatchesCluster` | Safety | `base.tla` | Scenario 3 | Covered |
| `PreexistingResourcesPreserved` | Safety | `base.tla` | Scenario 3 | Covered |
| `CleanupDeletesOnlyRunOwned` | Safety | `base.tla` | Scenario 3 | Covered |
| `NoiseQuiescentAtEvaluation` | Safety | `base.tla` | Scenario 4 | Covered |
| `OraclePassImpliesMitigated` | Safety | `base.tla` | Scenario 4 | Covered |
| `AcceptedSubmissionTerminates` | Liveness | `base.tla` | Not enabled in a safety hunt cfg | Defined as a leads-to property. It requires the brief's fair, terminating external-call assumption, so it is intentionally not used as an unconditional hunt property. |
| `TeardownEventuallyCompletes` | Liveness | `base.tla` | Not enabled in a safety hunt cfg | Defined as a leads-to property. It requires successful cleanup effects and fairness, so it is intentionally not used as an unconditional hunt property. |

Every Safety invariant in brief §5 is enabled in at least one actual hunt
configuration. The two conditional liveness properties are outside the
mandatory safety-coverage check but remain defined for assumption-bearing runs.

## Brief §6.1 model-checkable findings

| Finding | Modeled trigger and enabling bounds | Expected violated invariant(s) | Targeting cfg |
|---|---|---|---|
| MC-1 | `ConductorSubmitAccept` creates an in-flight executor; `AgentTimeout` or `AgentExitWaitTimeout` requests driver cleanup; both callers can pass `FinishProblemCheck` before `BeginCleanup`; evaluator completion remains reactive | `DoneIsTerminal`, `NoEvaluationDuringTeardown`, `NoOverlappingRuns` | `MC_hunt_scenario1.cfg` |
| MC-2 | `DelayOrDuplicate` retains an origin-tagged shadow envelope while the implementation projects away its tags; `ReceiveSubmission`, `RetrySubmission`, and `ConductorSubmitAccept` interpret it against mutable current stage; `Acknowledge` is generic | `OneAcceptedPerStage`, `SubmissionOriginMatches`; conditional `AcceptedSubmissionTerminates` is defined separately | `MC_hunt_scenario2.cfg` |
| MC-3 | `ObserveBaseline(..., FALSE)` records an empty field as a completed capture; `Crash`, `ReplaceCluster`, `Restart`, and `LoadBaselineState` reuse the fixed cache; `ReconcileDelete` uses current-minus-baseline and `ReconcileRestore` cannot recreate missing identities | `BaselineMatchesCluster`, `PreexistingResourcesPreserved`, `CleanupDeletesOnlyRunOwned` | `MC_hunt_scenario3.cfg` |
| MC-4 | `BeginNoiseApply` can remain blocked through `NoiseManagerJoinTimeout`; recorded cleanup and force-removal can finish before `CompleteNoiseApply`; independently, `RestartPod` creates a healthy window before reactive `ReattachFault` | `NoiseQuiescentAtEvaluation`, `OraclePassImpliesMitigated`, `NoOverlappingRuns` | `MC_hunt_scenario4.cfg` |

## Mechanical checks performed

- `MC.cfg` contains standard/reference and structural invariants; every
  scenario invariant is present only as a commented convergence candidate.
- Each hunt config uses tight, scenario-specific nonzero bounds and keeps
  unrelated fault counters at zero.
- TLC randomized reachability runs produced targeted counterexamples for:
  `NoEvaluationDuringTeardown` (Scenario 1), `SubmissionOriginMatches`
  (Scenario 2), `BaselineMatchesCluster` (Scenario 3), and
  `FaultBeforeDiagnosis` through the pod-restart window (Scenario 4).
- `MC.tla` and all configs parse and evaluate with the generated base model.
