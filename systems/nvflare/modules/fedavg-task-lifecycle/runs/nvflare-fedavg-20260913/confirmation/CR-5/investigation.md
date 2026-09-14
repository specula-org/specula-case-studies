# CR-5 Investigation

Finding: Configured progress and distinct completion meanings.
Source kind: code review / no counterexample supplied.
Checkout: `53ba7ee567468ea7971dad4faccef13c6cb35dc2` (`2.10.0dev0-21-g53ba7ee56-dirty`). The worktree already contains local Specula tracing edits; they were preserved.

## Step 1: Code Audit

Relevant locations:

- `nvflare/apis/impl/bcast_manager.py:42-89`: `BcastTaskManager.check_task_exit()` counts `ClientTask.result_received_time`, not aggregation acceptance. `min_responses == 0` means wait for all targets; otherwise, once the configured number of responses is received and the grace period has elapsed, it returns `TaskCompletionStatus.OK`.
- `nvflare/app_common/workflows/fedavg.py:218-234`: default FedAvg calls non-blocking `send_model()` without passing `min_responses` or `timeout`, then waits while `get_num_standing_tasks()` is nonzero. Through `BaseModelController.broadcast_model()`, omitted `min_responses` becomes `0`, meaning all selected targets must respond.
- `nvflare/app_common/workflows/fedavg.py:277-346`: FedAvg's in-time aggregation callback skips empty results and returns `False`; non-empty accepted results increment `_received_count`.
- `nvflare/app_common/workflows/base_model_controller.py:111-197`: `broadcast_model()` documents `timeout=0` as no task timeout and maps omitted `min_responses` to the broadcast-manager all-targets sentinel.
- `nvflare/app_common/workflows/base_model_controller.py:255-305`: `_process_result()` calls `_accept_train_result()`, converts to `FLModel`, invokes the consumer callback, and only then publishes `AppConstants.AGGREGATION_ACCEPTED`. Conversion failure, callback exception, or callback return `False` leaves `AGGREGATION_ACCEPTED=False`. It then clears the retained training result and `client_task.result`.
- `nvflare/app_common/utils/error_handling_utils.py:18-61`: error policy is three-mode: `True` always ignores bad result errors, `False` always panics, and `None` ignores only while `min_responses` remains reachable.
- `nvflare/apis/impl/wf_comm_server.py:422-533`: `process_submission()` reaches live tasks via `process_task_request()`/client submission, rejects client mismatch, drops duplicate live submissions, calls the result callback, and then sets `client_task.result_received_time`.
- `nvflare/apis/impl/wf_comm_server.py:1090-1188`: the monitor chooses terminal tasks by explicit completion status, broadcast-manager exit rule, task timeout, or dead-client handling; removal remembers completed client task ids and runs `task_done_cb`.
- `nvflare/apis/impl/wf_comm_server.py:1190-1222`: `_get_task_dead_clients()` only returns a dead-client terminal condition when all still-waited targets are disconnected after the lead time.

Reachability:

The path is reachable through normal controller APIs: FedAvg.run -> ModelController.send_model -> BaseModelController.broadcast_model -> WFCommServer.broadcast -> client `process_task_request()` -> client `process_submission()` -> BaseModelController._process_result() -> FedAvg._aggregate_one_result() -> WFCommServer.check_tasks()/monitor.

Constructed trigger scenario:

1. FedAvg selects two clients and sends a non-blocking broadcast training task with default `min_responses=None`, which maps to all selected targets.
2. One client submits an empty but otherwise OK FLModel result. The communicator records the result receipt after `_process_result()`. FedAvg's callback rejects the contribution (`False`) and no accepted aggregation count is incremented.
3. The second selected client submits a valid result. The communicator now has two received results, so the broadcast task can complete with status `OK` because all selected clients responded.
4. Consumers that observe aggregation acceptance should see only the second contribution as accepted; consumers that observe task lifecycle should see the task complete because all selected clients responded.

Safeguards / distinct consumers observed:

- `BaseModelController._process_result()` publishes `AGGREGATION_ACCEPTED` after final consumer decision, not merely after receipt.
- `JobStatsReporter._handle_contribution_accept()` records accepted and rejected clients separately (`nvflare/app_common/widgets/job_stats_reporter.py:1033-1058`).
- `JobStatsReporter._handle_after_aggregation()` treats final aggregation stats as authoritative and replaces provisional acceptance when an accepted count is published (`nvflare/app_common/widgets/job_stats_reporter.py:1006-1031`).
- `JobStatsReporter._round_participants()` and `_round_participation_count()` prefer aggregation accepted counts, then acceptance events, then OK completed task fallback only for workflows that do not publish acceptance signals (`nvflare/app_common/widgets/job_stats_reporter.py:1201-1233`).

## Step 2: Developer-Knowledge Search

Local docs and tests:

- `docs/programming_guide/controllers/model_controller.rst:133-143` states that model communication completes once `min_responses` have been received or timeout happens, and that asynchronous `send_model()` tasks stand until `min_responses` are received or timeout passes.
- `docs/programming_guide/controllers/controllers.rst:65-69` describes result callback/receipt marking and task completion causes, including all results received and the broadcast minimal-response exit rule.
- `docs/release_notes/flare_230.rst:203-226` documents the `wait_time_after_min_received` behavior change: when all responses are received, no extra wait is required.
- `tests/unit_test/apis/impl/controller_test.py:1648-1691` asserts `min_responses=0` broadcast exits only after all client tasks respond.
- `tests/unit_test/apis/impl/controller_test.py:1170-1221` asserts duplicate submissions for a live/completed task are not counted twice.
- `tests/unit_test/app_common/workflow/fedavg_test.py:942-960` asserts empty FedAvg results are skipped and do not increment `_received_count`.
- `tests/unit_test/app_common/utils/error_handling_utils_test.py:21-132` asserts strict/resilient/dynamic result-error policy, including the all-must-succeed default when `min_responses == num_targets`.
- `tests/unit_test/app_common/widgets/job_stats_reporter_test.py:833-860` asserts a custom aggregator's accepted contribution count is used instead of promoting every OK-completed task to an accepted contribution.
- `tests/unit_test/app_common/widgets/job_stats_reporter_test.py:861-885` asserts a zero aggregation count overrides completed tasks and provisional acceptance.

Git history and intent:

- `deec52aa4` / PR #4084 added dynamic `ignore_result_error` handling: default `None`, strict `False`, resilient `True`, shared utility, and controller tracking for current targets/minimum responses.
- `3d236fc22` / PR #4772 "Drop duplicate task submissions after cleanup" records completed client task ids and drops only exact duplicates while retaining the unknown-task path for mismatches.
- `b1b06ad45` / PR #4907 "Add comprehensive job statistics reporting" says reports include participation, failures, final status, and aggregation consistency. It also includes tests that keep accepted contribution counts separate from OK-completed task fallback.
- `d758f0787` / PR #2733 fixed the broadcast `min_responses=0` all-targets sentinel.
- `924593206` / PR #4384 preserves callback-context `CURRENT_ROUND` attributes without changing aggregation math or task acceptance behavior.

Issue / PR search:

GitHub issue/PR API searches run on 2026-09-13:

- `repo:NVIDIA/NVFlare BcastTaskManager accepted min_responses`: 0 results.
- `repo:NVIDIA/NVFlare AGGREGATION_ACCEPTED BcastTaskManager`: 0 results.
- `repo:NVIDIA/NVFlare result_received_time accepted contribution`: 0 results.
- `repo:NVIDIA/NVFlare "Configured progress" "distinct completion"`: 0 results.
- `repo:NVIDIA/NVFlare "task is standing" "min_responses" "accepted"`: 0 results.
- `repo:NVIDIA/NVFlare "Drop duplicate task submissions after cleanup"`: 1 result, PR #4772, which addresses exact duplicate submissions after cleanup, not the CR-5 progress/acceptance distinction.

Known-status record:

No existing issue, PR, CVE, advisory, or cited prior dataset entry was found that reports this exact mechanism at the same sites as a bug. Proceed to Phase 2 because the code-review x known pre-filter does not apply.
