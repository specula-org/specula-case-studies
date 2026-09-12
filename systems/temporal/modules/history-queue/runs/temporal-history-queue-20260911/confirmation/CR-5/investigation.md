# CR-5 Investigation

## Scope

- Source revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.
- Finding source: code review, no model-checking counterexample.
- Persistence/backend used by the executed repro: existing `service/matching` unit harness with in-memory test task manager and mocked History client.
- Note: cited `service/history/tasks/task.go:373` is stale for this revision; `service/history/tasks/task.go` ends at line 57. The matching task finish site is `service/matching/task.go:373`.

## Code Audit

- History transfer execution for workflow/activity tasks loads mutable state, releases the workflow lock, and calls Matching through `pushActivity` / `pushWorkflowTask`.
  - `service/history/transfer_queue_active_task_executor.go:235-289`: activity task eligibility and `pushActivity`.
  - `service/history/transfer_queue_active_task_executor.go:291-376`: workflow task eligibility and `pushWorkflowTask`.
  - `service/history/transfer_queue_task_executor_base.go:96-154`: `AddActivityTask`.
  - `service/history/transfer_queue_task_executor_base.go:156-216`: `AddWorkflowTask`.
- Queue runnable semantics are `Execute` -> `HandleErr` -> `Ack` on nil error.
  - `common/tasks/runnable_scheduler.go:27-37`.
  - `service/history/queues/executable.go:591-699`: non-nil executor errors retry/drop/DLQ; nil means completion.
  - `service/history/queues/executable.go:760-785`: `Ack` marks task acked.
- Matching `AddWorkflowTask` and `AddActivityTask` accept tasks through ordinary Matching APIs, either sync-matching or spooling to the task queue backlog.
  - `service/matching/matching_engine.go:586-643`.
  - `service/matching/matching_engine.go:645-694`.
- Sync-match `Record*TaskStarted` errors are returned to the `AddTask` caller unless they are BUSY_WORKFLOW, so History can avoid ACK and retry.
  - `service/matching/task_queue_partition_manager.go:615-645`.
  - `service/matching/task_queue_partition_manager.go:707-715`.
  - `service/matching/pri_matcher.go:390-412`.
- Backlog/spooled tasks behave differently. On worker poll, Matching calls History `Record*TaskStarted`; for `Internal` or `DataLoss`, Matching logs a non-retryable drop and calls `task.finish` with only a drop reason, not an error.
  - `service/matching/matching_engine.go:808-887`: workflow poll path, `Internal`/`DataLoss` drop.
  - `service/matching/matching_engine.go:1035-1125`: activity poll path, `Internal`/`DataLoss` drop.
  - `service/matching/task.go:370-377`: `finish` carries the drop reason.
  - `service/matching/task_reader.go:126-129`: backlog completion records the drop and calls `completeTask`.
  - `service/matching/backlog_manager.go:226-270`: `err == nil` means the backlog entry is completed/deleted; only non-nil errors are rewritten at the back of the queue.
- Downstream timers partially mask permanent loss:
  - normal workflow tasks on normal queues use `WorkflowRunTimeout` as the matching expiry, not an immediate retry; sticky/speculative workflow tasks can get schedule-to-start timers (`service/history/workflow/mutable_state_impl.go:1474-1500`, `service/history/timer_queue_active_task_executor.go:457-477`).
  - activity schedule-to-start timeout eventually records an activity timeout and deletes pending activity info unless retry remains in progress (`service/history/timer_queue_active_task_executor.go:300-379`, `service/history/workflow/mutable_state_impl.go:4689-4739`). That is a later workflow-visible timeout, not a retry of the dropped Matching backlog item.

## Developer-Knowledge Search

- Git history found the directly relevant upstream PR chain:
  - `fb5d4255a` / PR #10468: "Add tasks_dropped observability metric to the matching service".
  - `76e1aea6b` / PR #10667: reverted #10468 because of metric label-set issues.
  - `8bf02dfb6` / PR #10759: re-landed the metric.
- GitHub API search queries covered open/closed issues and PRs for:
  - `repo:temporalio/temporal "RecordWorkflowTaskStarted" "drop"`
  - `repo:temporalio/temporal "RecordActivityTaskStarted" "drop"`
  - `repo:temporalio/temporal "tasks_dropped" "internal_error"`
  - `repo:temporalio/temporal "AddWorkflowTask" "RecordWorkflowTaskStarted"`
  - `repo:temporalio/temporal "transfer task" "matching" "ack"`
- PR #10759 states that `tasks_dropped` fires whenever Matching throws away a backlog/spooled task, including a `Record(Workflow|Activity)TaskStarted` call failing non-retryably; sync-match tasks are excluded, and `ResourceExhausted`/`NamespaceHandover` are propagated to callers. It also says the metric gives a view of task queues "bleeding tasks". URL: https://github.com/temporalio/temporal/pull/10759
- PR #10468, the earlier version, is even more explicit: `internal_error` / `data_loss` correspond to `Record(Workflow|Activity)TaskStarted` failing with a genuine server error; sync-match failures are returned to `AddTask`; counting only backlog/spooled drops reflects "genuine backlog loss". URL: https://github.com/temporalio/temporal/pull/10468

## Known Status

- This is code-review sourced and the exact Matching backlog/spooled drop mechanism at the same site was already reported upstream in PR #10468 and re-landed in PR #10759.
- Novelty: `KNOWN (cite: https://github.com/temporalio/temporal/pull/10759; fix-status: unfixed)`.
- The upstream change is instrumentation only; it did not repair the drop behavior.

## Reproduction

- Repro script: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/repro/test_bugCR-5_matching_drop.sh`.
- Command: `timeout 10m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/repro/test_bugCR-5_matching_drop.sh`.
- Escalation: Level 1. The test uses ordinary Matching `Add*Task` and `Poll*TaskQueue` paths with a mocked History client returning admissible `Internal`/`DataLoss` errors from `Record*TaskStarted`.
- Result: test passed, confirming the current code intentionally drops backlog/spooled Matching tasks on those History responses and returns empty poll responses. Since novelty is already known, the decision-table verdict is `DROPPED`.
