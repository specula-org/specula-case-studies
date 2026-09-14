# MC-1 Investigation

## Scope

- Source checkout: `/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/confirmation/MC-1/worktree`
- Source SHA: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`
- Worktree note: source files are already dirty with Specula `_st` hooks. I did not edit source files.
- Finding source: MC counterexample supplied by dispatcher.

## Step 1: Code Audit

- `FedAvg.run()` resets built-in aggregation state at `nvflare/app_common/workflows/fedavg.py:202`, sends a non-blocking model task with callback `self._aggregate_one_result` at `fedavg.py:220`, waits for no standing tasks at `fedavg.py:229`, then consumes `_get_aggregated_result()` at `fedavg.py:239` and applies it via `update_model()` at `fedavg.py:244`.
- `BaseModelController._process_result()` converts an accepted shareable to `FLModel`, calls the task callback, catches callback exceptions, leaves `accepted=False`, and publishes `AppConstants.AGGREGATION_ACCEPTED` at `nvflare/app_common/workflows/base_model_controller.py:267-301`. The exception path does not roll back callback-side mutations.
- `FedAvg._aggregate_one_result()` updates `_site_metric_weights` before aggregation at `nvflare/app_common/workflows/fedavg.py:302-307`, calls `_aggr_helper.add()` at `fedavg.py:309-315`, and increments `_received_count` only after all parameter and metric processing succeeds at `fedavg.py:344`.
- `WeightedAggregationHelper.add()` mutates `key_contribution_counts`, `total`, and `counts` per key as it iterates. Lazy values are materialized per key at `nvflare/app_common/aggregators/weighted_aggregation_helper.py:170-179`; history is appended only after the whole loop at `weighted_aggregation_helper.py:223-229`.
- `_LazyRef.materialize()` performs real file-backed tensor loading through `safe_open()` at `nvflare/app_opt/pt/lazy_tensor_dict.py:77-80`.
- `FedAvg._get_aggregated_result()` reads aggregation stats from the helper, stores them in `fl_ctx`, gets aggregated params from the helper, and returns an `FLModel` whose `nr_aggregated` is `_received_count` at `nvflare/app_common/workflows/fedavg.py:361-380`.

Reachable trigger scenario:

1. A normal one-round FedAvg broadcast installs `_aggregate_one_result` as the result callback.
2. A client result reaches `Task.result_received_cb` as an `FLModel` shareable with multiple parameter keys.
3. In tensor disk offload mode, parameter values can be `_LazyRef` objects; the built-in helper intentionally materializes them one key at a time.
4. One earlier key is accumulated into `_aggr_helper.total`; a later lazy key fails during `safe_open()` / `materialize()`.
5. `_aggregate_one_result()` exits before `_received_count += 1`.
6. `_process_result()` catches the callback exception and publishes `AGGREGATION_ACCEPTED=False`.
7. `FedAvg.run()` later consumes `_get_aggregated_result()` and updates/saves a global model containing the earlier accumulated key from a rejected result.

Safeguards encountered:

- The acceptance event is corrected to `False` on callback failure.
- `_received_count` remains `0`.
- No rollback of `_aggr_helper.total`, `_aggr_helper.counts`, `_site_metric_weights`, or partial key statistics was found.
- No downstream guard in `_get_aggregated_result()`, `update_model()`, or `save_model()` rejects non-empty params when `nr_aggregated == 0`.

## Step 2: Developer-Knowledge Search

Local history / blame:

- `b1b06ad45` / PR #4907 ("Add comprehensive job statistics reporting") introduced aggregation stats and made `AGGREGATION_ACCEPTED` describe the callback/conversion outcome, but did not add rollback for callback-side partial mutation. Commit message says it reports "participation, failures, final status, aggregation key matching" and publishes aggregation statistics.
- `4371d41b2` / PR #4784 ("Add recipe metrics artifacts writer") records official aggregated metrics and per-site provenance, but does not address callback failure rollback.
- `51aeaced8` / PR #4221 ("Tensor Disk Offload for PyTorch in FedAvg and Swarm") introduced lazy tensor handling and cleanup.
- `git blame` shows `_aggregate_one_result()` callback aggregation predates the acceptance-stat work; no blame/comment says partial parameter aggregation should survive a rejected callback.

Issue/PR tracker search:

- GitHub issue/PR search queries run:
  - `repo:NVIDIA/NVFlare FedAvg AGGREGATION_ACCEPTED callback failure`
  - `repo:NVIDIA/NVFlare FedAvg rejected contribution aggregation callback`
  - `repo:NVIDIA/NVFlare weighted aggregation lazy tensor materialize failure`
  - `repo:NVIDIA/NVFlare "AGGREGATION_ACCEPTED" "FedAvg"`
  - `repo:NVIDIA/NVFlare "Unsuccessful callback" "FedAvg"`
- Matches reviewed: PR #4907, PR #4784, PR #4317, PR #4221, PR #4215.
- None reported this exact same mechanism: FedAvg built-in aggregation retaining partially accumulated parameter/helper state after the callback fails and `AGGREGATION_ACCEPTED=False` is published.

Comments/docs/tests:

- Nearby comments state that callbacks may return `False` for deliberate skip and that `AGGREGATION_ACCEPTED` should reflect the definitive outcome.
- Existing tests cover publishing `False` for conversion failure and callback skip, lazy payload compatibility, metric filtering, and aggregation stats, but I found no test asserting rollback/consistency after an exception thrown mid-aggregation.

## Step 3: Known Status / Precedent

- Known-status search covered upstream issues and recently merged/closed PRs through GitHub API plus local git log on the affected files.
- No same-mechanism same-site issue/PR/CVE/advisory was found.
- Novelty evidence supports `NEW`; this is not the code-review known pre-filter, and the finding is MC-sourced.

## Reproduction Artifact

- Repro file: `/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/repro/test_bugMC-1_lazy_partial_aggregation.py`
- Escalation level: Level 2 state injection. The test drives `FedAvg.run()` and `send_model()` with a fake communicator that delivers a result through the real registered task callback. The injected state is an actual `LazyTensorDict` / `_LazyRef` whose file-backed materialization fails, matching the disk-offload lazy-ref interface consumed by `WeightedAggregationHelper.add()`.
