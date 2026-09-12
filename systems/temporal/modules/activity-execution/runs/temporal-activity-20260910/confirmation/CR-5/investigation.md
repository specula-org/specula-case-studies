# CR-5 Investigation

Finding: Independent observations must cover the entire execution.

Source revision checked: 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025.
Source kind: code review; no MC counterexample was provided for this finding.

## Step 1: Code audit

- `tests/testcore/history_task_recorder.go:83` calls the delegate `UpdateWorkflowExecution` first, then records mutation tasks only when `err == nil` at lines 87-111. `tests/testcore/history_task_recorder.go:116` has the same success-only behavior for `CreateWorkflowExecution` at lines 120-130. The public reader `GetAllTasks` returns only the in-memory `r.tasks` map at `tests/testcore/history_task_recorder.go:173`.
- The recorder comment at `tests/testcore/history_task_recorder.go:17` says it records all task writes, but the implementation drops task batches for any delegate error, including ambiguous errors where persistence may have committed.
- `common/persistence/faultinjection/fault.go:42` defines `ExecuteAndTimeout`; the nearby comment says the caller receives a timeout although the operation reached persistence and executed successfully. `fault.inject` executes `op()` first when `execOp` is true, then returns the configured error at `common/persistence/faultinjection/fault.go:65-71`.
- The modified worktree adds a single-shot Specula fault path in `common/persistence/faultinjection/execution_store_gen.go:253-282`. For `ExecuteAndTimeout`, it calls `f.inject`, tracks `delegateExecuted`, emits `PersistenceResponseTimeout`, and returns the timeout error.
- The public Activity path is reachable through normal Workflow/Activity RPCs: frontend `RespondActivityTaskCompleted` calls history at `service/frontend/workflow_handler.go:1682`; history dispatches to `respondactivitytaskcompleted.Invoke` at `service/history/history_engine.go:644`; that handler mutates workflow state inside `api.GetAndUpdateWorkflowWithNew` at `service/history/api/respondactivitytaskcompleted/api.go:51-72`; persistence then updates the execution.
- The activity trace harness exercises this path with `StartWorkflowExecution`, `PollWorkflowTaskQueue`, `RespondWorkflowTaskCompleted`, `PollActivityTaskQueue`, and `RespondActivityTaskCompleted` in `tests/specula_activity_trace_test.go:120-290`.
- There are observation safeguards in the modified worktree: `common/persistence/sql/execution.go:329-335` emits an independent SQL read transaction on `GetWorkflowExecution`; `common/persistence/sql/execution.go:363-389` emits transaction snapshots and `commitConfirmed`; `tests/specula_activity_trace_test.go:282-338` performs forced admin readbacks, public history readback, endpoint completion checks, and writes `FinishTrace` with `modelTraceComplete: false`.

Concrete trigger scenario:

1. Start a workflow through the frontend test service.
2. Complete the first workflow task with a `ScheduleActivityTask` command.
3. Poll and start the activity through Matching/History.
4. Arm the single-shot `ExecuteAndTimeout` fault before the worker calls `RespondActivityTaskCompleted`.
5. Persistence commits the activity-completion mutation and generated tasks, but the caller receives a timeout.
6. A task-recorder consumer that reads only `HistoryTaskRecorder.GetAllTasks` can observe no recorded tasks for the committed mutation because the recorder only records on nil errors. The current Specula trace harness also has independent SQL/admin/public readbacks and incomplete-trace flags that can prevent this lossy recorder view from being mistaken for a complete execution proof.

## Step 2: Developer knowledge search

- Upstream commit `961069b99cb27ecb7fbdda6c41d85d0b4249750e` / PR #5869 introduced `ExecuteAndTimeout` as a deliberate test fault. Its commit message says it emulates the case where the client got a timeout, but the operation reached persistence and succeeded. This is intent evidence for the ambiguous-success fault primitive, not a filed bug report for the recorder/trace coverage issue.
- `git blame` shows the success-only recorder behavior around `UpdateWorkflowExecution` came from the task recorder implementation lineage now in `tests/testcore/history_task_recorder.go:83-113`; no nearby comment says ambiguous committed errors should be excluded.
- Existing tests consume the recorder through `GetRecordedTasksByCategoryFiltered`, for example `tests/timeskipping_test.go:976-989`, `tests/timeskipping_test.go:1315-1322`, and `tests/timeskipping_propagation_test.go:782-790`. Those are real test consumers, but they do not cover `ExecuteAndTimeout` plus recorder semantics.
- Issue/PR searches run:
  - `gh search issues "HistoryTaskRecorder UpdateWorkflowExecution ExecuteAndTimeout" --repo temporalio/temporal --state open --include-prs --limit 20`
  - `gh search issues "HistoryTaskRecorder UpdateWorkflowExecution ExecuteAndTimeout" --repo temporalio/temporal --state closed --include-prs --limit 20`
  - `gh search issues "ExecuteAndTimeout activity persistence timeout" --repo temporalio/temporal --state open --include-prs --limit 20`
  - `gh search issues "ExecuteAndTimeout activity persistence timeout" --repo temporalio/temporal --state closed --include-prs --limit 20`
  - `gh search prs "HistoryTaskRecorder UpdateWorkflowExecution" --repo temporalio/temporal --state open --limit 20`
  - `gh search prs "HistoryTaskRecorder UpdateWorkflowExecution" --repo temporalio/temporal --state closed --limit 20`
- Those tracker searches returned no existing report or merged/closed PR for this exact recorder/observation-coverage mechanism.
- Local git history searches for `ExecuteAndTimeout`, `HistoryTaskRecorder`, `TaskRecorder`, `modelTraceComplete`, and related activity retry wording found related implementation history and tests, but no exact duplicate bug report for CR-5.

## Step 3: Known status / precedent

No upstream issue, closed/merged PR, CVE/advisory, or local git-history precedent was found that reports this exact defect mechanism at this site. The finding is not dropped in Phase 1 and proceeds to Phase 2 with `Novelty: NEW`.

## 2026-09-11 continuation refresh

Current source head rechecked in the requested worktree: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. The checkout has existing local Specula instrumentation/support changes; I treated them as retained worktree state and did not revert them.

Source/code audit refresh:

- `tests/testcore/history_task_recorder.go:83-113` still delegates `UpdateWorkflowExecution` first and records mutation/snapshot tasks only under `err == nil`.
- `tests/testcore/history_task_recorder.go:116-134` still applies the same success-only rule for `CreateWorkflowExecution`.
- `tests/testcore/history_task_recorder.go:137-168` stores only flattened task objects plus metadata in memory; it does not retain an attempted-write/error/uncertain-commit record.
- `common/persistence/faultinjection/fault.go:42-47` still defines `ExecuteAndTimeout` as "operation actually reached persistence and was executed successfully" while returning a timeout; `fault.inject` at `common/persistence/faultinjection/fault.go:65-71` implements that order by calling `op()` first and then returning `f.err`.
- `service/history/workflow/activity.go:121-131` intentionally exposes `NextAttemptScheduleTime` and derives `CurrentRetryInterval` only while a scheduled retry is still in future backoff. The public/functional parity test documents that once the retry is due, these fields alone do not prove the task reached Matching; a subsequent poll is the independent delivery observation (`tests/activity_parity_test.go:390-405`).

Developer knowledge / known-status refresh:

- `gh search issues --repo temporalio/temporal "\"HistoryTaskRecorder\" observation completeness" --limit 20` returned `[]`.
- `gh search issues --repo temporalio/temporal "\"ExecuteAndTimeout\" \"UpdateWorkflowExecution\"" --limit 20` returned `[]`.
- `gh search prs --repo temporalio/temporal "\"HistoryTaskRecorder\"" --limit 20` returned `[]`.
- `gh search prs --repo temporalio/temporal "\"ExecuteAndTimeout\"" --limit 20` found PR #5869 and closed PR #11269. PR #5869 is the intentional fault primitive; PR #11269 discusses preserving YAML `ExecuteAndTimeout` semantics while adding programmable fault injection. Neither reports the recorder/trace-observation completeness mechanism as a defect.
- `gh search prs --repo temporalio/temporal "\"current_retry_interval\"" --limit 20` found PRs #11150, #11182, and #11203 about public retry-interval projection. PR #11203 explicitly says the previous post-dispatch projection was considered a bug and intentionally changed. This is same-site developer intent for the projection contract, but not an exact report of CR-5's recorder/independent-observation mechanism.

Reproduction plan:

- Level 0: run the retained Specula healthy Activity public-RPC trace subtest without fault injection and inspect `FinishTrace`.
- Level 1: run projection checks and the retained `ExecuteAndTimeout` Activity trace subtest through the Temporal test cluster, then parse the trace for `PersistenceResponseTimeout`, post-fault readback, and `FinishTrace`.
- Level 2: create a temporary `tests/testcore` Go test during the repro script to isolate the recorder behavior under the reachable committed-timeout precondition established by Level 1.
- Level 3: not used unless the earlier levels fail; source patching would manufacture the observation symptom rather than prove a production caller consequence.
