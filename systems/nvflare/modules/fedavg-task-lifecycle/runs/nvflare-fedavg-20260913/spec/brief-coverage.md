# Brief coverage after validation

Pinned source: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Phase 3 supersedes the original generation audit, preserved in `output/generation-audit/`. Current cfg wiring is audited by `checks/audit_cfgs.py` and listed in `checks/enabled-invariants.json`. Execution coverage belongs to `bug-report.md` and run receipts, not this mapping.

## Every modeling-brief scenario

| Scenario | Configs | Contract and evidence boundary |
|---|---|---|
| S1 Protected input | `MC_hunt_s1_protected_input.cfg` | Protected snapshot, per-client identity/version and committed-round provenance; no arbitrary shared-payload mutation. |
| S2 Retry/history | `MC_hunt_s2_identity_history.cfg` | At most one consumer, receipt after decision, no later-round contamination; one lost ACK and ordinary retry, explicitly reduced history capacity 1. |
| S3 Consumer failure | `MC_hunt_s3_partial_parameters.cfg`, `MC_hunt_s3_metric_failure.cfg` | Full acceptance/aggregate consistency. Both produced Case C counterexamples for one nontransactional contribution/accounting mechanism. Parameter CE is statistics-only at the earliest failure; metric CE retains rejected parameter values. |
| S3 Value retention diagnostic | `MC_hunt_s3_parameter_values.cfg` | Additional value-only conjunct isolates the later parameter failure window. Same original parameter cfg bounds and actions; the full-consistency original remains enabled and preserved. |
| S3 Conversion/skip control | `MC_hunt_s3_conversion_control.cfg` | No post-mutation fault; empty parameters and present/absent/empty metrics. Conversion rejection must leave no contribution effects. |
| S4 Task termination | `MC_hunt_s4_cancel_overlap.cfg`, `MC_hunt_s4_filter_retirement.cfg`, `MC_hunt_s4_prepare_error.cfg` | Original no-partial-round oracle produced Case A violations. Current cfgs check callback/round/caller-lock isolation, receipt/decision, accepted contribution consistency and save provenance. Cancellation does not revoke accepted work; no product no-save-after-task-termination policy is assumed. |
| S5 Dead policy | `MC_hunt_s5_dead_policy.cfg` | Three clients, selected c1/c2, min_sites=1, no required sites. Configured CLIENT_DEAD retirement is separate from job panic. Same lifecycle/accepted-provenance checks after a Case A correction. |
| S5 Progress | `MC_hunt_s5_progress.cfg` | `MCLiveSpec` and `EligibleTaskEventuallyDrains`; fair live monitor, terminating callbacks, fixed time grid. No fairness forces a missing client result. No symmetry or VIEW. |
| S5 Resilient control | `MC_hunt_s5_resilient.cfg` | Explicit tolerant error mode; receipt and accepted-contribution accounting remain distinct. |

## Every brief safety assertion

| Assertion | Current treatment |
|---|---|
| `TypeOK` | Enabled in every hunt cfg. Standard `MC.cfg` uses `MCTypeOK`. |
| `CommittedRoundProvenance` | Enabled in every hunt cfg and standard MC. |
| `CommittedAcceptanceConsistency` | Enabled in original S3 partial/metric/conversion cfgs, S5 resilient, and all four revised S4/S5-death cfgs. Source-backed definitive acceptance and helper accounting; remains fully falsifiable. |
| `AbnormalTerminationVisible` | **Not applicable as an unconditional product oracle** in all four original affected cfgs. Original counterexamples remain in `output/hunt-bfs/`. `AllowPartialCompletion` is a specification-side proposed policy, not a discovered NVFlare setting. Neither a TRUE replacement nor an always-false antecedent is counted as coverage. Definition retained for historical artifacts; removed only from cfg wiring. |

See `output/counterexample-classification.md` for independent source analysis of direct cancellation, filter failure, before-send error and permitted client death. The four observed partial-save paths remain explicit contract/behavior evidence, not silently discarded or declared universally desirable. A stricter no-partial-round product guarantee remains unestablished; this run therefore does not promote the brief's MC-2 question to a confirmed implementation defect.

## Brief model-checkable candidates

- **MC-1:** source/MC evidence of retained parameter values or statistics after consumer rejection. Metric-preparation allocation and lazy parameter materialization are separate configurations. Existing implementation harness executes conventional scalar allocation-failure variants and actual FOBS saves; streamed PyTorch/lazy-disk delivery is untested.
- **MC-2:** abnormal task retirement followed by ordinary save is reachable and trace-conformant. The claimed prohibition is not a current established unified workflow policy. Case A correction changes no transition, bound or fault budget; remaining contribution/round/receipt checks continue to exercise these paths.

## Priority coverage and limits

All 24 existing implementation traces pass complete post-state replay with `TraceMatched`. They cover all 80 action names, controlled actual runner/communicator/helper locks, active-callback cancellation, staggered retrieval, live/retired/evicted retries, conversion and consumer failures, task preparation/filter errors, configured dead-client progress, default dynamic panic, resilient rejection and full round handoff. Action-name coverage does not imply branch/schedule exhaustiveness.

Default FedAvg waits for all selected receipts, timeout 0 and no response grace. No ScatterAndGather policy is imported. Selected cohort and key order are fixed; uniform FULL values, two symbolic parameter keys and positive unit weights abstract arithmetic. Most traces use real history limit 10000; eviction trace and S2 model explicitly use capacity 1. Death time abstraction uses 30-second ticks, lead one tick and grace two ticks, not every real-time schedule.

Payload publication, decoded delivery, result dispatch, ACK loss and lazy per-key materialization are distinct interfaces. Actual Cell/multiprocess RPC, streamed/offloaded payload paths, unconstrained schedules, native partial-arithmetic failure, aggregate-build/save failures, convergence, GPU numerics, HA and durable recovery remain outside executed coverage. Ordinary successful save is an observed file/callback operation, not a durability theorem. Existing TV and CR entries remain outside Phase 3 model findings.
