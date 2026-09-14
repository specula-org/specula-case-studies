# Confirmation Report — nvflare-fedavg

## Final Result

Reproduced bugs: 2 = 2 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 2
Dropped: 1
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 5
Dispositions: 5 total = 2 reproduced + 0 env-limited + 0 masked + 2 false-positive + 0 needs-more-info + 1 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | CR-1 | DROPPED | no |
| 3 | CR-2 | REPRODUCED | yes |
| 4 | CR-4 | FALSE POSITIVE | no |
| 5 | CR-5 | FALSE POSITIVE | no |

## Entry 1: Rejected contributions retain aggregation values or statistics after consumer failure

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: nvflare/app_common/workflows/fedavg.py:310

## Description
FedAvg can retain partially aggregated parameter state from a contribution that is later published as rejected. In the reproduced path, `_aggr_helper.add()` stores one parameter key before a later lazy tensor materialization failure; `BaseModelController._process_result()` catches the callback exception and emits `AGGREGATION_ACCEPTED=False`, but the later round aggregation still updates and saves the global model with the retained parameter.

## Trigger scenario
A one-round FedAvg task registers `_aggregate_one_result` as the normal result callback. A client result contains multiple params, including a real `LazyTensorDict` / `_LazyRef`; the first key is accumulated, the second key fails in `_LazyRef.materialize()` via `safe_open()`. The callback exits before `_received_count += 1`, but `FedAvg.run()` still calls `_get_aggregated_result()`, `update_model()`, and `save_model()`.

## Developer intent
The nearest upstream matches were PRs for stats/metrics/disk-offload features, not this rollback defect: https://github.com/NVIDIA/NVFlare/pull/4907, https://github.com/NVIDIA/NVFlare/pull/4784, https://github.com/NVIDIA/NVFlare/pull/4221. Local git history and tests show intent that `AGGREGATION_ACCEPTED` reflect the definitive callback outcome, but no test or code path rolls back partial helper state after a callback exception.

## Reproduction result
Repro written and executed:
`/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/repro/test_bugMC-1_lazy_partial_aggregation.py`

Command:
```bash
timeout 5m python -m pytest -q -s /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/repro/test_bugMC-1_lazy_partial_aggregation.py
```

Output:
```text
accepted_flags=[False]
aggregation_stats={'accepted_contributions': 0, 'contributors': [], 'keys_aggregated': 1, 'keys_seen': 1, 'fully_matched_keys': 0, 'partially_matched_keys': 1, 'skipped_keys': 0, 'round': 0}
aggregated_result_params={'survived': 10.0}
aggregated_result_meta={'nr_aggregated': 0, 'current_round': 0, 'metrics_aggregation_info': {'metric_source': 'client_reported_flmodel_metrics', 'aggregation': {'method': 'weighted_average', 'weight_key': 'effective_fedavg_metric_weight', 'metric_policy': 'finite_numeric_metrics_only_per_key_denominator', 'weight_formula': 'aggregation_weight * NUM_STEPS_CURRENT_ROUND'}, 'site_weights': [{'name': 'site-1', 'weight': 1.0, 'weight_key': 'effective_fedavg_metric_weight'}]}}
saved_model_params={'survived': 10.0}
.
1 passed in 1.01s
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 injected precondition: normal `FedAvg.run()` -> `send_model()` -> `Task.result_received_cb`; injected state is an actual NVFlare `_LazyRef` from `LazyTensorDict` whose file-backed materialization fails, matching the admissible disk-offload lazy-ref step.
3. Real consumer/caller: `FedAvg.run()` consumes `_get_aggregated_result()` at `nvflare/app_common/workflows/fedavg.py:239`, then `BaseFedAvg.update_model()` at `nvflare/app_common/workflows/base_fedavg.py:302` and `save_model()` at `nvflare/app_common/workflows/fedavg.py:266`.
4. Permanent or masked? **Permanent for the round output**: the bad aggregate is applied and saved; no downstream guard masks `params != {}` when `nr_aggregated == 0`.

## Recommendation
Make FedAvg contribution handling transactional: stage parameter, metric, site-weight, and stats mutations locally, then commit them only after all materialization and metric processing succeeds. Alternatively, add rollback on callback exception before publishing rejection and before `_get_aggregated_result()` can consume helper state.

---

## Entry 2: Protected broadcast input and outbound ownership boundaries

- **Finding ID**: CR-1
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/NVIDIA/NVFlare/pull/4129; fix-status: fixed)
- **Location**: nvflare/apis/impl/wf_comm_server.py:310

## Description
CR-1 is the same WFCommServer broadcast ownership/data-corruption mechanism already reported and fixed upstream in PR #4129. Current source creates one protected broadcast snapshot after `before_task_sent_cb`, then applies per-client headers to `make_copy(task_data)`, so the candidate symptom does not reproduce on this pinned tree.

## Trigger scenario
Normal Level 0 path: schedule a broadcast task for two clients, let client 1 retrieve it, mutate the original `task.data`, then let client 2 retrieve it. Pre-fix behavior could let client 2 observe mutated shared data or shared header state; current behavior preserves the broadcast snapshot and distinct per-client headers.

## Developer intent
Upstream PR #4129 explicitly describes the same mechanism and fix: `_broadcast_data = deepcopy(task.data)` once per broadcast, then per-client `make_copy()` before setting task headers. Local git history/blame confirms the cited lines came from `7d8a7df7a Fix potential data corrupt (#4129)`.

## Reproduction result
Test written and executed:
`/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/repro/test_bugCR-1_broadcast_ownership.py`

Command:
```bash
timeout 3m env PYTHONPATH=/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/confirmation/CR-1/worktree python /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/repro/test_bugCR-1_broadcast_ownership.py
```

Output:
```text
CR-1 probe result: known symptom did NOT reproduce on this source.
first_payload={'round': 0, 'weights': [1, 2, 3]}
mutated_original={'round': 99, 'weights': [1, 2, 3, 99]}
second_payload={'round': 0, 'weights': [1, 2, 3]}
first_task_id=914687e9-0269-4154-b75c-26f31f025f64
second_task_id=db89275e-cbfc-4597-9ed3-78af558697ff
broadcast_snapshot_present= True
```

## Recommendation
Drop this CR-1 candidate as a duplicate known fixed code-review finding. Do not file a new bug for this mechanism against the current pinned source.

---

## Entry 3: Task identity, retry receipt, and finite completed history

- **Finding ID**: CR-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `nvflare/app_common/workflows/base_model_controller.py:310`

## Description
CR-2 is reproduced for the residual path where a completed task ID ages out of the bounded `_completed_client_task_map`. A late duplicate result for that old task is then treated as an unknown train result; it skips FedAvg’s aggregation callback and contribution-accept event path, but `_accept_train_result()` still leaves the raw result reachable via the long-lived controller `fl_ctx`.

## Trigger scenario
A client completes a normal train task, the server records the completed task ID, then more than 10,000 later completed tasks evict that receipt. When the same client resubmits the original result with the original task ID/name, `WFCommServer.process_submission()` cannot find it in either active or completed history and dispatches it to `BaseModelController.process_result_of_unknown_task()`.

## Developer intent
Related upstream fixes exist but do not cover this exact residual path: PR #4772 fixed late duplicates while retained in the completed-task cache, and PR #4520 fixed normal-path retained `TRAINING_RESULT`. I found no upstream issue/PR reporting the evicted-completed-task unknown-result retention path.

## Reproduction result
Test written and executed:
`/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/repro/test_bugCR-2_task_identity_history.py`

Command:
```bash
timeout 5m python /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/repro/test_bugCR-2_task_identity_history.py
```

Output:
```text
level=0
cache_size=10000
completed_tasks_driven=10001
callback_count_before_late=10001
first_task_id_in_active=False
first_task_id_in_completed=False
callback_count_after_late=10001
after_contribution_accept_delta=0
late_ctx_training_result_is_old_result=True
controller_fl_ctx_is_late_ctx=True
controller_fl_ctx_training_result_is_old_result=True
payload_live_after_finalize_and_gc=True
BUG REPRODUCED: evicted completed-task duplicate reaches the unknown train-result path; it skips FedAvg aggregation but remains reachable via controller.fl_ctx TRAINING_RESULT.
```

Checklist:
1. Level 0 alone triggered it: yes.
2. Level 2/3 precondition: not used.
3. Real consumer/caller: `BaseModelController._accept_train_result()` (`nvflare/app_common/workflows/base_model_controller.py:337`) stores into controller state, and later controller events use `self.fl_ctx` via `FLComponentWrapper.event()` (`nvflare/app_common/utils/fl_component_wrapper.py:200`). The test also proves the stale payload remains live after finalize + GC.
4. Permanence/mask: aggregation harm is masked by skipped callback/events, but stale raw-result retention is not resolved by finalize and remains reachable until later controller context replacement.

## Recommendation
Handle unknown train results like rejected/late task results: avoid setting `TRAINING_RESULT` for unknown tasks, or clear it in a `finally` block in `process_result_of_unknown_task()`. Also make the log distinguish “accepted by error policy” from “sent to aggregator.”

---

## Entry 4: Abnormal task retirement versus ordinary round commit

- **Finding ID**: CR-4
- **Status**: FALSE POSITIVE
- **Source**: Code Review

Production event dispatch catches an ordinary `FLComponent` handler exception during `BEFORE_TRAIN_TASK`. The task remains assignable, and a valid contribution is accepted and saved. The claimed empty-model failure does not occur on this path.

---

## Entry 5: Configured progress and distinct completion meanings

- **Finding ID**: CR-5
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `nvflare/apis/impl/bcast_manager.py:42`

## Description
CR-5 does not reproduce as a live bug. The current code intentionally lets `BcastTaskManager` retire a broadcast task based on received responses, while `BaseModelController`/FedAvg separately publishes whether each contribution was actually accepted and aggregated.

## Trigger scenario
I triggered the claimed mismatch through the normal FedAvg path: two selected clients received the same `train` task; `site-1` submitted an OK but empty FLModel result; `site-2` submitted a valid model result. The task completed after both responses, but only `site-2` was counted as an accepted contribution.

## Developer intent
Docs state task completion is based on received `min_responses` or timeout, and async `send_model()` remains standing until that condition is met. Current tests and commits separately cover `min_responses=0`, duplicate submissions, dynamic error handling, and job stats not promoting OK-completed tasks to accepted contributions. GitHub issue/PR searches for this exact mechanism found no prior bug report; PR #4772 is related to duplicate submission cleanup, not this progress/acceptance distinction.

## Reproduction result
Command:
```bash
timeout 5m python /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/repro/test_bugCR-5_progress_completion.py
```

Output:
```text
CR-5 reproduction attempt
source_head=53ba7ee567468ea7971dad4faccef13c6cb35dc2
LEVEL 0: normal FedAvg controller API plus normal server assignment/submission boundary
[identity=server, run=cr5_job, peer=site-1, peer_run=cr5_job, peer_rc=OK, task_name=train, task_id=c0f0ffa3-514c-4e8c-9885-4459c75d65af]: Empty result from client site-1, skipping.
task_completion_status=ok
completed_task_record_sample=site-1:train
standing_after_empty_result=1
standing_after_all_responses=0
aggregation_acceptance_events=[('site-1', False), ('site-2', True)]
fedavg_accepted_count=1
aggregation_stats={"accepted_contributions": 1, "contributors": ["site-2"]}
job_stats_round={"accepted_client_names": ["site-2"], "accepted_clients": 1, "missing_client_count": 1, "reason": "1 task error(s); rounds with missing/rejected contributions: [0]", "status": "PARTIAL"}
LEVEL 1: not used; Level 0 reached the claimed receipt-vs-acceptance state without timing help.
LEVEL 2: not used; no injected pre-condition was needed or justified.
LEVEL 3: not used; no source modification was needed or justified.
RESULT: no live wrong outcome; task completion and accepted aggregation remain distinct.
```

## Recommendation
No code fix for CR-5. Preserve the existing distinction in future specs/tests: task completion may mean “configured responses received,” while accepted contribution must come from `AGGREGATION_ACCEPTED`/aggregation stats.

---
