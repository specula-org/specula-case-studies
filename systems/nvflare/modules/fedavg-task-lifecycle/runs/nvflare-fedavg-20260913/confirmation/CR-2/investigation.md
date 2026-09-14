# CR-2 Investigation

## Code Audit

Source under test:

- Worktree: `/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/nvflare-fedavg/.specula-output/confirmation/CR-2/worktree`
- Git HEAD: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`
- Dirty state observed before edits: local Specula tracing changes in several NVFlare files, including `wf_comm_server.py`, `base_model_controller.py`, `fedavg.py`, and `client_runner.py`. These add `_specula_trace` hooks and do not change the CR-2 submission/receipt branch semantics inspected here.

Relevant implementation:

- `nvflare/apis/impl/wf_comm_server.py:46` defines `_COMPLETED_CLIENT_TASK_CACHE_SIZE = 10000`.
- `nvflare/apis/impl/wf_comm_server.py:405-420` records completed client-task IDs only when `result_received_time` is set, keeps client and task-name identity, moves hits to the LRU end, and evicts oldest entries when the bounded map exceeds the cache size.
- `nvflare/apis/impl/wf_comm_server.py:422-533` processes submissions under `_controller_lock`. It first looks up the active `ClientTask`; if none exists, it consults the completed-task map. Exact completed duplicates, matching task ID, client name, and task name, are dropped. Other missing-task submissions fire the unknown-task events and call `controller.process_result_of_unknown_task(...)`.
- On the known active path, `wf_comm_server.py:487-507` rejects wrong-client submissions, mismatched task names, terminal tasks, and already received client results before callback processing. It sets `client_task.result`, runs manager/callback handling, then stamps `client_task.result_received_time` at `wf_comm_server.py:532`.
- `wf_comm_server.py:1132-1142` removes completed tasks from the active map and remembers completed client tasks before popping them from `_client_task_map`.
- `nvflare/private/fed/server/server_commands.py:232-243` routes a submitted client update to `server_runner.process_submission(...)` using task name and task ID from the incoming `Shareable`.
- `nvflare/private/fed/server/server_command_agent.py:89-100` returns a transport-level OK reply if command processing returns a non-None value; it does not encode FedAvg aggregation acceptance in that transport reply.
- `nvflare/private/fed/client/client_runner.py:227-238` sets task name and task ID headers on normal task replies, and `client_runner.py:594-644` retries sending a task result until task-check/send succeeds or the task is gone.
- `nvflare/app_common/workflows/base_model_controller.py:255-307` is the known-result path. It sets `self.fl_ctx` to the submission context, publishes contribution-accept events, converts the raw `Shareable`, calls the task callback such as FedAvg aggregation, publishes `AGGREGATION_ACCEPTED`, and then clears `TRAINING_RESULT` and `client_task.result` in a `finally` block.
- `nvflare/app_common/workflows/base_model_controller.py:310-319` is the unknown train-result path. It calls `_accept_train_result(..., is_unknown_task=True)` and logs that the result was sent to the aggregator when the preliminary result error policy accepts it, but it does not run the known task callback and does not clear `TRAINING_RESULT`.
- `nvflare/app_common/workflows/base_model_controller.py:337-378` assigns `self.fl_ctx = fl_ctx`; for OK results it stores the raw `Shareable` under `AppConstants.TRAINING_RESULT` and returns `True`.
- `nvflare/app_common/workflows/fedavg.py:220-225` sends FedAvg train tasks with `callback=self._aggregate_one_result`, and `fedavg.py:277-341` performs the per-result aggregation callback.
- Real event consumers include `nvflare/app_common/widgets/metrics_artifact_writer.py:174-190`, which reads `AGGREGATION_ACCEPTED` and `TRAINING_RESULT` during contribution-accept events, and `nvflare/app_common/widgets/job_stats_reporter.py:1033-1048`, which records accepted/rejected clients from contribution-accept events.

Reachable trigger scenario:

1. A normal FedAvg-style controller schedules a train task for a client.
2. The client pulls the task, executes it, and submits an OK result with the assigned task ID and task name.
3. The task monitor/check path removes the completed task from `_client_task_map` and records the completed client-task ID in the bounded completed map.
4. More than 10,000 later completed client tasks are recorded, evicting the first completed task ID from `_completed_client_task_map`.
5. The first client retries or replays the old task result after that eviction. The submission still uses the normal submission entry point and still carries the original task ID and task name, but the server can no longer find the task ID in either the active map or completed-task map.
6. The server dispatches the result as an unknown train task. The unknown path calls `_accept_train_result`, which sets `controller.fl_ctx` to the submission context and leaves the raw `TRAINING_RESULT` there, but it does not invoke the FedAvg aggregation callback or contribution-accept events.

Safeguards found:

- Active known submissions reject wrong-client task IDs, task-name mismatches, terminal tasks, and duplicate live results.
- Completed-task deduplication drops exact late duplicates only while their completed-task IDs remain in the bounded cache.
- The unknown path skips the task callback and contribution-accept event window, so FedAvg aggregation and normal metrics/job-stats contribution consumers do not count the evicted duplicate.
- The known-result path clears `TRAINING_RESULT` in a `finally` block; the unknown-result path does not.

## Developer Knowledge Search

Issue/PR search and local git history were checked on September 13, 2026:

- GitHub search for `process_result_of_unknown_task`, `unknown task`, `completed_client_task`, `duplicate result`, `BaseModelController unknown task`, and `TRAINING_RESULT unknown task` in `NVIDIA/NVFlare` issues/PRs.
- Local `git log --grep` for unknown task, completed task, duplicate result, task result, and `process_result_of_unknown_task`.
- Local `git blame` around `wf_comm_server.py:405-420`, `wf_comm_server.py:422-533`, and `base_model_controller.py:310-319`.

Relevant upstream records:

- PR https://github.com/NVIDIA/NVFlare/pull/4772, merged June 8, 2026 as `3d236fc2235fde2f917402c71dc86bf579efb460`, is titled "Drop duplicate task submissions after cleanup". It added the bounded completed-task map and tests for late duplicates after cleanup. The PR explicitly keeps mismatched completed submissions on the unknown-task path.
- PR https://github.com/NVIDIA/NVFlare/pull/4597, merged May 14, 2026, fixed wrong-client result submissions and live duplicate result handling.
- PR https://github.com/NVIDIA/NVFlare/pull/4520, merged May 6, 2026, fixed retained `TRAINING_RESULT` after normal known-result contribution-accept events by clearing it in `_process_result`.
- Issue https://github.com/NVIDIA/NVFlare/issues/323 includes an old ScatterAndGather log line about an unknown train task being sent to an aggregator, but the reported failure is an encrypted model save/pickle error in ScatterAndGather, outside the current FedAvg scope.

Developer intent evidence:

- The known active path and PR #4597 show intent to reject wrong-client task IDs and duplicate live results.
- PR #4772 shows intent to drop exact late duplicates after cleanup while the completed-task ID is retained, and to keep non-duplicates on the unknown-task path.
- PR #4520 shows intent that raw `TRAINING_RESULT` should be scoped to the contribution-accept event window and cleared after normal known-result processing to avoid retaining a client update.
- No issue or PR found that reports the exact CR-2 residual path: an exact old duplicate evicted from the bounded completed-task cache reaches `BaseModelController.process_result_of_unknown_task` and remains retained in `controller.fl_ctx` without the normal callback/event/clear path.

## Known Status

Novelty assessment: NEW for the residual evicted-completed-task unknown-result retention path.

Related known fixes exist, but they do not report this exact mechanism:

- PR #4772 reports and fixes late duplicate task submissions after cleanup only while the completed-task ID remains in the bounded completed-task cache.
- PR #4520 reports retained `TRAINING_RESULT` after the normal known-task accept event window, not the unknown-task branch reached after completed-cache eviction.

Because the exact residual mechanism was not found in the upstream issue/PR search, the code-review known pre-filter does not apply. Proceeded to Phase 2 reproduction.
