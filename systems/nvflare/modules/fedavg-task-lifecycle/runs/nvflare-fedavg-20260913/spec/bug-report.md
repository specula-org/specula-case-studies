# Bug Report — nvflare-fedavg

## Summary

- Source: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`, current Recipe FedAvg with the built-in aggregator.
- Scenarios tested: 5; all 11 supplied hunt configs plus one supplemental parameter-value oracle. Full run-by-run coverage: [model-checking-coverage.md](output/model-checking-coverage.md).
- Bugs found: **1 functional contribution/accounting defect**, with three model counterexamples of the same root cause. Four abnormal-termination counterexamples were classified Case A because the proposed unified no-partial-round guarantee was not established.
- Trace conformance: **24/24 implementation traces pass**, 2,044 events and all 80 action names; complete post-state comparison and `TraceMatched`. [Replay receipts](output/trace-round1/summary.json).
- Standard checking: one round of budgeted convergence, no behavior changes. `MC.cfg` ran its full 30-minute budget without invariant violations; last logged coverage was 1,334,981,180 generated / **292,238,651 distinct** states, depth **86**, with 24,216,269 queued. These are periodic lower bounds, not exhaustive completion. [Receipt](output/MC_round1_bfs_retry.receipt.json).
- **Execution status:** all required runs observed and recorded. 7 finite hunts completed cleanly; 2 runs used their full budgets without a reported violation. See the separate temporal evidence boundary below.

References use pristine pinned-source line numbers before the existing harness insertions. Typical bounds are two selected clients, two rounds, two ordered nonexcluded FULL parameter keys, a symbolic scalar metric and positive unit weights. Timeout and response grace are zero. Optional failure/filter/offload and dead-client policies are explicit cfg variants. No production source fix was applied in validation.

## Bug 1: Rejected contributions retain aggregation values or statistics after consumer failure

- **ID:** MC-1
- **Scenario:** S3 — consumer failure after partial aggregation mutation
- **Severity:** Medium
- **Invariant violated:** `CommittedAcceptanceConsistency`; supplemental `CommittedValuesAccepted`
- **Config:** `MC_hunt_s3_metric_failure.cfg`, `MC_hunt_s3_partial_parameters.cfg`, `MC_hunt_s3_parameter_values.cfg`
- **Counterexamples:** [81-state metric-preparation failure](output/hunt-bfs/MC_hunt_s3_metric_failure/tlc.out), [77-state parameter-statistics failure](output/hunt-bfs/MC_hunt_s3_partial_parameters/tlc.out), [79-state parameter-value retention](output/hunt-revised-bfs/MC_hunt_s3_parameter_values/tlc.out). Each directory contains exact input snapshots, JSON counterexample, run receipt and installed-tool state analyses.

### Trace Summary

1. **Metric failure:** c2's contribution completes, is counted and accepted (states 43–55). c1 then updates both parameter keys and parameter history (63–67), but metric preparation raises at 68. Acceptance is published false at 69; receipt still follows. The broadcast retires OK after both receipts. At state 81, GLOBAL_MODEL contains both clients' parameter values, although only c2 is accepted and `nr_aggregated=1`.
2. **Parameter value retention:** c1 succeeds. c2 updates key 1 at state 64, then fails while materializing key 2 at 66. c2 is rejected at 67 and receives a receipt at 69. At state 79, the exposed model's key 1 includes rejected c2, while key 2 includes only c1; callback count remains 1.
3. **Earlier accounting window:** the original 77-state parameter hunt fails before c2 changes any parameter value. It nevertheless increments key 1's contribution statistics. Final helper history lists only accepted c1, but key 1's count is 2. Public aggregation statistics therefore classify a key as partially matched even though the only accepted contributor supplied both keys. This shortest trace is **statistics-only**, not evidence of retained rejected parameter values.

The model counterexamples stop at global-model update, before save. The existing Phase 2.5 `partial_param_allocation`, `metric_preparation_failure` and `metric_value_failure` traces separately show the related ordinary allocation-failure behavior through actual FOBS file persistence, with controlled client orders. Those implementation traces now replay against the unchanged base specification; they are not claimed to replay the identical TLC schedule.

### Root Cause

`BaseModelController._process_result` explicitly reports the definitive consumer outcome: exceptions leave `accepted=False` and are caught before acceptance publication. It clears result references but does not undo prior consumer mutations (`base_model_controller.py:263-294`).

FedAvg updates parameters before processing metrics and before incrementing `_received_count` (`fedavg.py:299-330`). The helper changes per-key statistics before materialization, then values/counts, and appends history only after the entire key loop (`weighted_aggregation_helper.py:162-224`). These updates are serialized by locks but are not transactional. A later ordinary exception can therefore leave a rejected contribution's earlier effects in the helper. Final aggregation exposes those retained values and independently reports the successful callback count (`fedavg.py:223-259,346-365`).

This is **Case C**: the current consumer-first acceptance behavior is modeled faithfully; no existing duplicate/history guard is removed, and no cancellation or malicious input is needed. The consequence is inconsistent contributor membership across parameter keys or between model values and contribution statistics. Numeric convergence, natural failure frequency and upstream acceptance of this finding are not established.

### Affected Code

- `nvflare/app_common/workflows/base_model_controller.py:263`: definitive acceptance and exception handling without rollback.
- `nvflare/app_common/workflows/fedavg.py:299`: parameter mutation precedes later consumer work/count.
- `nvflare/app_common/workflows/fedavg.py:346`: retained helper state becomes final aggregate and metadata.
- `nvflare/app_common/aggregators/weighted_aggregation_helper.py:162`: incremental stats/value/history updates.
- `nvflare/app_opt/pt/lazy_tensor_dict.py:77`: supported per-key materialization failure interface.

### Recommendation

Make acceptance and all parameter/metric/statistic effects agree across the whole consumer operation. Stage a contribution's work and commit it atomically, or treat a post-mutation consumer failure as a failed round and prevent exposing/saving its contaminated aggregate. Changing the acceptance event alone is insufficient; it already follows the consumer's actual return/error outcome.

Keep regression controls for success, empty skip, pre-consumer conversion rejection, failure after one parameter, and failure after parameter completion. The current local harness uses benign scalar payloads and explicit one-shot ordinary allocation errors. **Actual streamed PyTorch with active Cell and tensor disk offload is untested**; the parameter offload path is source/model evidence, with allocation-failure runtime evidence for the related mutation window.

## Not Reproduced

The unconditional `AbnormalTerminationVisible` oracle is **not applicable** to the four original affected cfgs: `AllowPartialCompletion` is a proposed specification policy, not an actual NVFlare setting. Source APIs distinguish task cancellation/ERROR/CLIENT_DEAD from job abort. The observed partial-save paths are retained in [counterexample-classification.md](output/counterexample-classification.md); they remain contract questions, not confirmed implementation defects or claims that every application desires this behavior. All original outputs and invariant definitions are preserved. Only cfg wiring changed, with actual callback/round/receipt/contribution constraints retained; no transition, bound or fault budget was restricted.

<!-- COVERAGE_TABLE_START -->
| Scenario/config | Run | Distinct states found | Depth | Result |
|---|---|---:|---:|---|
| [MC_hunt_s1_protected_input.cfg](output/hunt-bfs/MC_hunt_s1_protected_input/tlc.out) | hunt-bfs | 848,281 | 189 | Finite state space complete; no violation of enabled assertions |
| [MC_hunt_s2_identity_history.cfg](output/hunt-bfs/MC_hunt_s2_identity_history/tlc.out) | hunt-bfs | 6,957,871 | 199 | Finite state space complete; no violation of enabled assertions |
| [MC_hunt_s3_conversion_control.cfg](output/hunt-bfs/MC_hunt_s3_conversion_control/tlc.out) | hunt-bfs | 28,462,829 | 109 | 30-minute budget; no reported violation; incomplete search (periodic count) |
| [MC_hunt_s4_cancel_overlap.cfg](output/hunt-bfs/MC_hunt_s4_cancel_overlap/tlc.out) | hunt-bfs | 20,845 | 55 | Oracle violation classified Case A; unsupported policy not applicable |
| [MC_hunt_s4_filter_retirement.cfg](output/hunt-bfs/MC_hunt_s4_filter_retirement/tlc.out) | hunt-bfs | 20,380 | 63 | Oracle violation classified Case A; unsupported policy not applicable |
| [MC_hunt_s4_prepare_error.cfg](output/hunt-bfs/MC_hunt_s4_prepare_error/tlc.out) | hunt-bfs | 18,656 | 61 | Oracle violation classified Case A; unsupported policy not applicable |
| [MC_hunt_s5_dead_policy.cfg](output/hunt-bfs/MC_hunt_s5_dead_policy/tlc.out) | hunt-bfs | 640,723 | 61 | Oracle violation classified Case A; unsupported policy not applicable |
| [MC_hunt_s5_progress.cfg](output/hunt-bfs/MC_hunt_s5_progress/tlc.out) | hunt-bfs | 3,459,013 | 36 | 30-minute budget; no reported violation; incomplete search (periodic count) |
| [MC_hunt_s5_resilient.cfg](output/hunt-bfs/MC_hunt_s5_resilient/tlc.out) | hunt-bfs | 2,010,803 | 189 | Finite state space complete; no violation of enabled assertions |
| [MC_hunt_s4_cancel_overlap.cfg](output/hunt-revised-bfs/MC_hunt_s4_cancel_overlap/tlc.out) | hunt-revised-bfs | 1,216,029 | 190 | Finite state space complete; no violation of enabled assertions |
| [MC_hunt_s4_filter_retirement.cfg](output/hunt-revised-bfs/MC_hunt_s4_filter_retirement/tlc.out) | hunt-revised-bfs | 338,221 | 189 | Finite state space complete; no violation of enabled assertions |
| [MC_hunt_s4_prepare_error.cfg](output/hunt-revised-bfs/MC_hunt_s4_prepare_error/tlc.out) | hunt-revised-bfs | 252,925 | 189 | Finite state space complete; no violation of enabled assertions |
| [MC_hunt_s5_dead_policy.cfg](output/hunt-revised-bfs/MC_hunt_s5_dead_policy/tlc.out) | hunt-revised-bfs | 6,690,779 | 198 | Finite state space complete; no violation of enabled assertions |

Completed temporal graph passes: 12,194 distinct states. The subsequent pass over 3,844,441 distinct states had not finished at the 30-minute budget; no full liveness verdict is claimed.

Every no-violation BFS reached depth greater than 25; no simulation follow-up was required by the workflow depth rule.
<!-- COVERAGE_TABLE_END -->

## Priority Questions and Coverage Gaps

| Priority | Result and boundary |
|---|---|
| 1. Consistent broadcast input | Staggered real retrievals retain the scheduled model version; protected-input BFS completed its finite state space with no violation. Successful custom mutating filters and backend ownership internals are outside this model. |
| 2. Retry and late results | Live receipt, retained history and evicted unknown-result paths preserve consumer/round association in the model and local traces. Identity/history BFS completed. Capacity-1 eviction is an explicit abstraction; actual history capacity 10000 is not exhaustively exercised. |
| 3. Receipt vs acceptance/effects | Receipt and definitive acceptance remain distinct. MC-1 exposes retained rejected effects. Conversion/skip and explicit resilient controls are separate from consumer mutation failure; default result-code errors trigger the modeled dynamic abort policy. |
| 4. Cancellation and round isolation | Direct cancellation may allow an admitted callback to finish. Monitor removal and old callback serialization are retained. Three revised S4 finite checks completed without violation of the remaining lifecycle/contribution assertions. No unified no-save-after-cancel contract is assumed. |
| 5. Progress and outcomes | A permanently missing live response is expected waiting. Permitted dead-client task retirement and job-policy panic are distinct. Progress checking assumes a fairly scheduled live monitor and terminating callbacks; the 30-minute run did not complete full temporal/state-space checking; see the exact temporal boundary above. |

Transport is an explicit interface: publication, decoded delivery, submission dispatch and ACK are separate; ACK does not promise consumer acceptance or completion of every lazy tensor. Actual Cell/multiprocess RPC, streamed/offloaded delivery, unconstrained scheduling, native partial-arithmetic failure, aggregate/save failures, HA and durable recovery remain untested. The 649-passed/2-skipped upstream test receipt is retained from Phase 2.5, not a suite rerun by this validation phase.

## Specification Changes

No base/Trace transition or instrumentation change was needed. Four cfgs removed an unestablished whole-round outcome oracle after separate Case A analyses and enabled existing source-backed lifecycle/contribution checks. `MC.tla` gained only a diagnostic conjunct for the additional parameter-value hunt. The original full consistency invariant remains intact. See [changelog.md](changelog.md), [brief-coverage.md](brief-coverage.md), and [current cfg audit](checks/enabled-invariants.json).
