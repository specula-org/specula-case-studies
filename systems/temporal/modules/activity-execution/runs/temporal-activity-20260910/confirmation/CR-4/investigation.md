# CR-4 Investigation

Finding: Cancellation and terminal outcomes leave a Workflow Task obligation

Source checkout: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-4/worktree`

Revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`

## Step 1: Code Audit

Relevant public entry points:

- `service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:680` handles `RequestCancelActivityTask` commands from a completed workflow task. It calls `AddActivityTaskCancelRequestedEvent` and sets `CancelRequested` if the activity is still pending. If the activity has not started, it immediately records `ActivityTaskCanceled` and marks `activityNotStartedCancelled` so a follow-up workflow task is requested.
- `service/history/api/respondactivitytaskcompleted/api.go:23` is the history API path for worker activity completion. It checks the workflow is running, validates the activity token with `IsActivityTaskNotFoundForToken`, records `ActivityTaskCompleted`, deletes `ActivityInfo`, and returns `UpdateWorkflowAction{CreateWorkflowTask:true}`.
- `service/history/api/respondactivitytaskfailed/api.go:24` is the history API path for worker activity failure. It calls `RetryActivity`; if the retry state is not `IN_PROGRESS`, it records `ActivityTaskFailed`, deletes `ActivityInfo`, and requests a workflow task. If retry remains in progress, it only updates activity state and retry tasks.
- `service/history/api/respondactivitytaskcanceled/api.go:23` is the history API path for cancellation acknowledgement. It rejects the acknowledgement if `ai.CancelRequested` is false, otherwise records `ActivityTaskCanceled`, deletes `ActivityInfo`, and requests a workflow task.
- `service/history/api/recordactivitytaskheartbeat/api.go:19` records heartbeat progress without creating a workflow task and returns `CancelRequested`, `ActivityPaused`, and `ActivityReset` to the worker.
- `service/history/timer_queue_active_task_executor.go:205` processes activity timeout timer tasks. Terminal timeout records `ActivityTaskTimedOut` and sets `shouldScheduleWorkflowTask=true`; retryable timeout updates the activity and creates retry work instead.
- `service/history/api/update_workflow_util.go:80` coalesces workflow-task creation: when an action requests `CreateWorkflowTask`, it calls `AddWorkflowTaskScheduledEvent` only if `!mutableState.HasPendingWorkflowTask()` and the workflow is not paused.
- `service/history/workflow/workflow_task_state_machine.go:1196` defines `HasPendingWorkflowTask` as a non-empty `WorkflowTaskScheduledEventId`; this includes both scheduled and already-started workflow tasks.
- `service/history/workflow/mutable_state_impl.go:7622-7640` persists updated/deleted activity infos, buffered events, and generated tasks in the same workflow mutation.

Observed safeguards and coalescing mechanisms:

- Terminal activity events delete the pending activity via `ApplyActivityTaskCompletedEvent`, `ApplyActivityTaskFailedEvent`, `ApplyActivityTaskTimedOutEvent`, or `ApplyActivityTaskCanceledEvent`.
- When no workflow task exists, `UpdateWorkflowWithNew` creates a normal workflow task for the terminal activity event.
- When a workflow task already exists, `UpdateWorkflowWithNew` intentionally coalesces instead of creating another one. If the existing workflow task was already started, the terminal event is buffered, persisted as `NewBufferedEvents`, and `RespondWorkflowTaskCompleted` later sees `hasBufferedEventsOrMessages` and schedules the next normal workflow task.
- `workflow_task_state_machine.go:330-334` flushes buffered events when scheduling the next workflow task, so the next worker-visible task includes the terminal activity result.
- `workflow_task_state_machine.go:1324-1327` deletes the old workflow task before applying a workflow-task completion; this is what lets the follow-up workflow task be scheduled once buffered events exist.

Concrete trigger scenario for reproduction:

1. Start a normal workflow execution through the frontend API.
2. Poll and complete the first workflow task with a `ScheduleActivityTask` command.
3. Poll the activity task so it is started and has a normal task token.
4. Send a workflow signal, poll/complete the resulting workflow task with `RequestCancelActivityTask`, and verify an activity heartbeat reports `CancelRequested=true`.
5. Send another signal and poll, but hold, the resulting workflow task. This creates a real started workflow task that cannot yet observe a later activity terminal event.
6. Resolve the cancel-requested activity through a terminal path: completion, failure, cancellation acknowledgement, or start-to-close timeout.
7. Complete the held workflow task with no commands. The expected safeguard is that buffered terminal activity work causes a follow-up workflow task, which the worker can poll and use to close the workflow.

Reachability assessment: the trigger uses normal frontend and worker APIs (`StartWorkflowExecution`, `PollWorkflowTaskQueue`, `RespondWorkflowTaskCompleted`, `PollActivityTaskQueue`, `RecordActivityTaskHeartbeat`, and worker terminal APIs). No direct mutable-state calls or fabricated preconditions are required.

## Step 2: Developer-Knowledge Search

Code comments relevant to intent:

- `service/history/api/update_workflow_util.go:81`: "Create a transfer task to schedule a workflow task only if the workflow is not paused and there is no pending workflow task."
- `service/history/workflow/workflow_task_state_machine.go:327-334`: when new events exist while scheduling a workflow task, buffered events are flushed before creating the workflow task so event IDs are valid.
- `service/history/workflow/mutable_state_impl.go:4753-4756`: activity cancel request code explicitly tolerates the case where activity started/completed events were buffered and `ActivityInfo` has already been removed.
- `service/history/workflow/mutable_state_impl.go:4884-4887`: an activity may not be heartbeating but can still call heartbeat to observe cancellation.
- `service/history/workflow/mutable_state_impl.go:6892-6893`: retry computation gives `CancelRequested` precedence by returning `RETRY_STATE_CANCEL_REQUESTED`.

Existing tests:

- `tests/activity_parity_test.go:790-796` asserts `CancelRequestedBeforeFailure` reaches terminal `FAILED` with `RETRY_STATE_CANCEL_REQUESTED`.
- `tests/activity_parity_test.go:850-868` asserts cancel-requested start-to-close and schedule-to-close timeout paths reach terminal `TIMED_OUT` with `RETRY_STATE_CANCEL_REQUESTED`.
- `tests/activity_standalone_test.go:3616-3664` verifies an activity in `CANCEL_REQUESTED` can still time out through start-to-close and reports `RETRY_STATE_CANCEL_REQUESTED`.

Blame / recent history:

- `git blame -L 79,89 service/history/api/update_workflow_util.go` shows the pending-WFT coalescing guard existed since 2022 and its current comment was added in commit `7b15d6c2f5` on 2025-12-15.
- `git blame -L 6888,6895 service/history/workflow/mutable_state_impl.go` shows the `CancelRequested` retry-state precedence in `RetryActivity` came from commit `24a39ce1d2` on 2024-06-17.
- `git blame -L 99,140 service/history/api/respondactivitytaskcompleted/api.go` shows the completion path's terminal event plus `CreateWorkflowTask:true` shape is longstanding, with later changes around force-complete metrics and worker-control fields.
- `git log --since=2026-08-01 -- <affected files>` found recent changes such as PR `#11789` buffered-event coverage and activity timer maintenance PRs, but no commit message reporting a lost workflow-task obligation for activity cancellation and terminal results.

## Step 3: Known Status / Precedent

Tracker searches refreshed on 2026-09-11:

- `gh search issues --repo temporalio/temporal '"CancelRequested" "WorkflowTask"' --limit 20 --json number,title,state,url,closedAt,updatedAt` returned `[]`.
- `gh search prs --repo temporalio/temporal '"CancelRequested" "WorkflowTask"' --limit 20 --json number,title,state,url,closedAt,updatedAt,isDraft` returned `[]`.
- `gh search issues --repo temporalio/temporal '"ActivityTaskCompleted" "WorkflowTaskScheduled"' --limit 20 --json number,title,state,url,closedAt,updatedAt` returned `[]`.
- `gh search prs --repo temporalio/temporal '"ActivityTaskCompleted" "WorkflowTaskScheduled"' --limit 20 --json number,title,state,url,closedAt,updatedAt,isDraft` returned `[]`.
- `gh search issues --repo temporalio/temporal '"activity" "pending workflow task" "cancel"' --limit 20 --json number,title,state,url,closedAt,updatedAt` returned `[]`.
- `gh search prs --repo temporalio/temporal '"activity" "pending workflow task" "cancel"' --limit 20 --json number,title,state,url,closedAt,updatedAt,isDraft` returned `[]`.
- `gh search issues --repo temporalio/temporal '"ActivityTaskTimedOut" "WorkflowTask"' --limit 20 --json number,title,state,url,closedAt,updatedAt` returned `[]`.
- `gh search prs --repo temporalio/temporal '"ActivityTaskTimedOut" "WorkflowTask"' --limit 20 --json number,title,state,url,closedAt,updatedAt,isDraft` returned `[]`.
- A broader GitHub API search for `"ActivityTaskCompleted" "WorkflowTaskScheduled"` returned several unrelated hits, including PR `#11789` ("Add exhaustive natural XDC buffered event coverage"), which covers buffered event reachability but does not report this CR-4 mechanism as a defect.

Known-status evidence: no existing upstream issue or PR found that reports this exact mechanism at this site.
