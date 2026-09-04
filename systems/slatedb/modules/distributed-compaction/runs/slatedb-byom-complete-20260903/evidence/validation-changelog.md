# Validation Changelog

## BYOM Initialization

- Reused the adopted base, MC, Trace, instrumentation, harness, and five supplied trace artifacts at source commit `cc69461d902560bb5f4407a506f32cd154ede79d`.
- Verified `Trace.cfg` enables `TraceMatched` and `Trace.tla` validates the complete captured post-state. The supplied traces are used without rerunning the harness.

## Round 1 - Trace Validation

- [pass] All five supplied traces matched with full post-state validation; no spec or harness changes were required.

## Round 1 - Model Checking

- [infra] The first background launch exited before TLC startup because the launcher and inner runner targeted the same log path; its sparse output is retained but excluded. The counted foreground retry used a distinct captured log and completed the full budget.
- [pass] `MC.cfg` completed its 30-minute budget without a violation: 488,527,833 states generated, 131,939,406 distinct states, diameter 20. No spec or invariant changes were required.

## Bug Hunting - Fidelity Repairs

- [fix-spec] `PollAndClaim`: repeated one-job model steps let one worker exceed a single poll's fixed claim-batch capacity before dispatch updated `localExecuting`. Added same-worker durable pending claims to the capacity guard, matching `compaction_worker.rs:304-381` (Case B; initial Family 1 and Family 5 counterexamples).
- [fix-inv] `TimedOutOrFailedJobsDoNotLivelock`: removed the property from `MC_hunt_family3.cfg`; the counterexample was a valid stuttering suffix, while neither the implementation nor `MCSpec` supplies the fairness/eventual-success premise required by the oracle (Case A). Family 3 safety invariants remain enabled.
- [infra] Parallel Family 2, Family 3-safety, and Family 4 BFS attempts were incomplete after simultaneous OpenJDK crashes in `PerfLongVariant::sample`; partial logs are retained and are not counted as hunting results.

## Round 2 - Trace Validation

- [pass] All five supplied traces still matched after the `PollAndClaim` capacity-fidelity repair; no regression or harness change was required.

## Round 2 - Model Checking

- [pass] `MC.cfg` completed its 30-minute budget after the fidelity repair without a violation: 462,099,944 states generated, 121,149,670 distinct states, diameter 21. No further spec or invariant changes were required.

## Bug Hunting

- [bug] `ExternalSubmit` / `MaybeValidateSubmittedSchedule`: one locally proposed job and one external non-L0 job with the same source and destination both reached `Scheduled`; external insertion bypasses `add_compaction`, while canonical validation does not repeat cross-job conflict checks. `NoConflictingActiveCompactions` failed in 7 states under the supplied Family 1 action bounds (`MC_hunt_family1_conflicts.cfg`).
- [bug] `ExternalSubmit` / `PollAndClaim`: a locally scheduled job and a disjoint external job were both promoted and claimed by different workers, producing two durable `Running` jobs with `MaxConcurrent = 1`. `BoundedRunningClaims` failed in 9 states (`MC_hunt_family1.cfg`).
- [bug] `MaybeScheduleCompactions` / `PollAndClaim`: two scheduler ticks each observed zero `Running` jobs while the first job was still `Submitted`, then different workers claimed both. `BoundedRunningClaims` failed in 8 states (`MC_hunt_family5.cfg`).
- [pass] `MC_hunt_family2.cfg`: no violation within 30 minutes; 424,850,331 states generated, 85,525,537 distinct states, diameter 28.
- [pass] `MC_hunt_family3.cfg`: no safety violation within 30 minutes; 479,646,415 states generated, 75,501,353 distinct states, diameter 95.
- [pass] `MC_hunt_family3_safety.cfg`: no violation within 30 minutes; 488,117,289 states generated, 77,188,119 distinct states, diameter 99.
- [pass] `MC_hunt_family4.cfg`: no violation within 30 minutes; 416,238,618 states generated, 81,414,035 distinct states, diameter 38.
- [coverage] No simulation follow-up was required: every violation-free BFS finished above diameter 25; violating configs terminated with concrete counterexamples.
- [coverage] The supplementary conflict config preserved the supplied Family 1 action bounds. Its final full-bound counterexample is `output/MC_hunt_family1_conflicts_fullbounds_bfs.out`; an earlier isolation run is retained only as superseded audit output.

## Result

Converged in 2 rounds. Bug hunting: 3 bugs found.
