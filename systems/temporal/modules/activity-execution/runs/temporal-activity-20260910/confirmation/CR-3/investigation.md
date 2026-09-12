# CR-3 Investigation

## Identity

- Finding: CR-3, "Persistence result, API result, and recovery can disagree temporarily"
- Source: Code Review. No model-checking counterexample was supplied for this finding.
- Source repo: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-3/worktree`
- Source revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`
- Worktree note: the checkout contains local Specula instrumentation; source-code facts below were checked against `git show HEAD:<path>` at the pinned revision.

## Step 1: Code Audit

Relevant code facts:

- `service/history/api/respondactivitytaskcompleted/api.go:50-131` is reachable from the real worker-facing `RespondActivityTaskCompleted` path. It loads a workflow lease, validates the pending `ActivityInfo`, calls `AddActivityTaskCompletedEvent`, and requests a workflow task.
- `service/history/workflow/mutable_state_impl.go:4593-4637` adds `ActivityTaskCompleted` and deletes the pending activity from mutable state. `service/history/workflow/mutable_state_impl.go:7616-7624` carries activity-info upserts/deletes into the persistence mutation.
- `service/history/api/update_workflow_util.go:62-118` persists the action via `UpdateWorkflowExecutionAsActive`; when a workflow task is needed, it schedules one before the persistence call.
- `service/history/workflow/context.go:408-497` reloads mutable state from persistence when the cached context has been cleared. `service/history/workflow/cache/cache.go:385-389` clears/releases the cached context on any returned error.
- `common/persistence/execution_manager.go:247-277` delegates serialized `UpdateWorkflowExecution` to the persistence store. It only trims history on condition failures; other errors are returned.
- `common/persistence/sql/execution.go:334-357` appends history nodes before calling `txExecuteShardLocked` for mutable-state updates.
- `common/persistence/sql/execution_util.go:23-120` writes the execution row, generated tasks, ActivityInfos, timer infos, buffered events, and other maps inside the same SQL transaction. `common/persistence/sql/execution_util.go:629-695` locks/checks the execution row condition.
- `common/persistence/sql/shard.go:152-176` read-locks the shard row and verifies the caller's RangeID.
- `common/persistence/faultinjection/fault.go:42-47` defines `ExecuteAndTimeout`: run the operation, then return a persistence timeout. `common/persistence/faultinjection/execution_store_gen.go:250-257` wraps `UpdateWorkflowExecution` with that injector.
- `common/persistence/error_type.go:5-22` treats timeout-like unknown errors as possibly succeeded.
- `service/history/workflow/transaction_impl.go:184-207` notifies execution tasks when `OperationPossiblySucceeded(err)` is true, even when it then returns the error.
- `service/history/shard/task_request_tracker.go:69-88` keeps task keys pending for possibly-succeeded write errors.
- `service/history/shard/context_impl.go:1501-1549` treats definite failures separately and, for unknown write results, requests shard loss/reacquisition so later reads can determine the write outcome.
- `service/history/handler.go:2281-2301` converts persistence `TimeoutError` to public `DeadlineExceeded`.

Reachable trigger scenario:

1. A workflow schedules an Activity through normal workflow-task completion.
2. A worker polls and receives a real Activity task token.
3. The worker calls `RespondActivityTaskCompleted` with that token.
4. The execution store executes and commits `UpdateWorkflowExecution`, deleting the pending ActivityInfo, buffering/delivering the Activity completion event, and creating the required workflow-task work, but the persistence wrapper returns a timeout to the caller.
5. History returns `DeadlineExceeded` to the worker, treats the write as possibly committed, clears the cached mutable state, requests shard reacquisition, and later reloads state from persistence.
6. A duplicate completion attempt with the same token goes through the public API again and is rejected if the committed state removed the Activity.
7. The workflow worker polls the next workflow task and should see exactly one `ActivityTaskCompleted` event.

Safeguards recorded for Phase 2:

- Cache clear on returned error: `service/history/workflow/cache/cache.go:385-389`.
- Shard reacquisition on uncertain write result: `service/history/shard/context_impl.go:1540-1548`.
- Task notification on possibly-succeeded write: `service/history/workflow/transaction_impl.go:201-204`.
- Pending task-key retention for possibly-succeeded writes: `service/history/shard/task_request_tracker.go:73-87`.
- Duplicate-token rejection through pending ActivityInfo/start/attempt checks: `service/history/api/respondactivitytaskcompleted/api.go:74-87` and `service/history/api/activity_util.go:58-80`.

## Step 2: Developer-Knowledge Search

Issue/PR search commands run against `temporalio/temporal`:

- `gh search issues --repo temporalio/temporal '"ExecuteAndTimeout"' --include-prs --state open --limit 20`
- `gh search issues --repo temporalio/temporal '"ExecuteAndTimeout"' --include-prs --state closed --limit 20`
- `gh search issues --repo temporalio/temporal '"OperationPossiblySucceeded"' --include-prs --state open --limit 20`
- `gh search issues --repo temporalio/temporal '"OperationPossiblySucceeded"' --include-prs --state closed --limit 20`
- `gh search issues --repo temporalio/temporal '"persistence timeout" "Activity"' --include-prs --state open --limit 30`
- `gh search issues --repo temporalio/temporal '"persistence timeout" "Activity"' --include-prs --state closed --limit 30`
- `gh search issues --repo temporalio/temporal '"UpdateWorkflowExecution" "TimeoutError"' --include-prs --state open --limit 30`
- `gh search issues --repo temporalio/temporal '"UpdateWorkflowExecution" "TimeoutError"' --include-prs --state closed --limit 30`
- `gh search issues --repo temporalio/temporal '"RespondActivityTaskCompleted" "persistence"' --include-prs --state open --limit 30`
- `gh search issues --repo temporalio/temporal '"RespondActivityTaskCompleted" "persistence"' --include-prs --state closed --limit 30`

Search results found related infrastructure PRs, but no existing Temporal issue/PR reporting this exact Activity completion mechanism as a defect:

- `https://github.com/temporalio/temporal/pull/5869`, "Fault Injection: execute operation while still returning an error to the caller", added `ExecuteAndTimeout` to emulate a client receiving timeout after persistence executed successfully.
- `https://github.com/temporalio/temporal/pull/2334`, "Notify new tasks when workflow is potentially updated", states that if persistence may have succeeded, History notifies new tasks; even without notification, the queue processor reloads tasks periodically and the workflow experiences delay rather than task loss.
- `https://github.com/temporalio/temporal/pull/11269`, "Programmable persistence fault injection", was closed and did not report this Activity completion behavior as a bug.

Local git history / comments:

- Commit `7b26d8484d6bbfe7661adeeaa1a00355fa2f3951`, "History Cache invalidation on persistence timeout (#110)", records the historical intent: after a timeout while updating workflow execution, RangeID/cache handling must guarantee that a later read either sees the write or knows it failed.
- Commit `05f584cc5766cb987a39237477e40f8de403e8b0`, "Notify new tasks when workflow is potentially updated (#2334)", adds task notification on possibly-succeeded workflow writes and unit coverage.
- Current comments at `service/history/shard/context_impl.go:1540-1546` explicitly describe uncertain write errors and read-after-reacquire semantics.

Existing tests / harness:

- The local instrumented tree has `tests/specula_activity_trace_test.go:43-69`; subtest `write_commit_response_timeout` uses mode `ExecuteAndTimeout`.
- `tests/specula_activity_trace_test.go:278-298` arms the persistence fault before public Activity completion, requires the first completion to error, checks committed modes leave no `ActivityInfos`, and checks duplicate completion returns `NotFound`.
- `tests/specula_activity_trace_test.go:323-350` waits through real queue processors, requires no pending Activities, polls the workflow task, and requires exactly one terminal Activity event.

## Step 3: Known Status / Precedent

No public Temporal issue/PR search result reported the same mechanism at the same site: public Activity completion reaches a committed `UpdateWorkflowExecution`, the worker-facing call receives `DeadlineExceeded`, recovery/reload observes the committed state, duplicate completion is rejected, and the workflow worker receives the terminal event.

Related historical work documents the intended safeguard path for uncertain workflow-write results, so it is developer-intent evidence rather than a duplicate CR-3 bug report. Novelty is recorded as `NEW`.
