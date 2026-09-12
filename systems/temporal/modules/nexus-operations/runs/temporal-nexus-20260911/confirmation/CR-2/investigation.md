# CR-2 Investigation

## Scope

- Source repo: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/confirmation/CR-2/worktree`
- Revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`
- Worktree note: checkout is dirty with existing Specula instrumentation; no existing changes were reverted.
- Source: Code Review; no model-checking counterexample was provided for CR-2.

## Code Audit

### Cited code

- `service/history/hsm/nexusoperations/statemachine.go:159-168`: `startToCloseTimeoutTask` returns a `StartToCloseTimeoutTask` when both `StartedTime` and `StartToCloseTimeout` are set.
- `service/history/hsm/nexusoperations/statemachine.go:172-181`: `Operation.RegenerateTasks` appends `o.startToCloseTimeoutTask()`, so a refresh/reload path can rediscover the missing task from persistent operation state.
- `service/history/hsm/nexusoperations/statemachine.go:367-400`: `TransitionStarted` records the attempt, operation token, and `StartedTime`. If a cancellation child already exists, lines 383-389 return through `hsm.MachineTransition(child, ...)` before lines 392-400 append `op.startToCloseTimeoutTask()`.
- `service/history/hsm/nexusoperations/statemachine.go:423-449`: `Operation.Cancel` creates the cancellation child. If the operation is not yet `STARTED`, lines 439-442 return no tasks, leaving the child in `UNSPECIFIED` until the operation later starts.
- `service/history/hsm/nexusoperations/executors.go:481-506`: async `StartOperation` responses call `saveStartedResult`, which applies `TransitionStarted`.
- `service/history/hsm/nexusoperations/executors.go:947-967`: successful cancel request transmission transitions only the cancellation child to `SUCCEEDED`; the operation is explicitly not canceled by the acknowledgement.

### Task publication path

- `service/history/hsm/tree.go:586-637`: `MachineTransition` appends one `TransitionOperation` with exactly the transition output returned by the transition function.
- `service/history/workflow/task_generator.go:297-334`: normal close-transaction task generation iterates the operation log and converts only `transitionOp.Output.Tasks` into durable tasks; it then schedules the next state-machine timer if any timer group was tracked.
- `service/history/workflow/task_generator.go:942-1000`: timer HSM tasks are tracked in `ExecutionInfo.StateMachineTimers` via `TrackStateMachineTimer`; immediate destination tasks become outbound tasks.
- `service/history/workflow/state_machine_timers.go:16-35`: a `StateMachineTimerTask` is emitted only when a timer group exists.
- `service/history/timer_queue_active_task_executor.go:861-889` and `service/history/timer_queue_task_executor_base.go:290-350`: the active timer queue processes persisted `StateMachineTimers`; if no group is persisted, no start-to-close timeout handler runs.
- `service/history/hsm/nexusoperations/executors.go:658-697`: the start-to-close timeout handler records a `NEXUS_OPERATION_TIMED_OUT` event through `executeStartToCloseTimeoutTask`/`executeOperationTimeout`.

### Reachability and trigger scenario

Reachable through public workflow operations:

1. A workflow task completes with `ScheduleNexusOperationCommandAttributes` containing `StartToCloseTimeout`.
2. Before the endpoint's `StartOperation` handler returns an async started response, another workflow task completes with `RequestCancelNexusOperationCommandAttributes` for the scheduled event.
3. `Operation.Cancel` creates the child cancellation machine while the operation is still scheduled, so no cancellation task is emitted yet.
4. The endpoint then returns async started. `TransitionStarted` sets `StartedTime` and detects the existing cancellation child.
5. The nested child transition emits `CancelationTask`, but the parent returns before appending `StartToCloseTimeoutTask`.
6. The cancel request is acknowledged. Per executor comment, this does not finish the operation, so the operation remains started and depends on callbacks or timeouts for terminal resolution.

Safeguards/compensation:

- `Operation.RegenerateTasks` would recreate the `StartToCloseTimeoutTask` if a task refresh path runs after the operation is in `STARTED`.
- `RefreshWorkflowTasks` is an explicit admin/history refresh path (`service/history/handler.go:1698-1723`, `service/history/workflow/context.go:1387-1406`, `service/history/workflow/task_refresher.go:55-84`), not part of the ordinary async-start/cancel close transaction.
- Terminal operation events delete the state machine and would make missing timeout irrelevant if the endpoint completes. The repro uses an endpoint that acknowledges cancellation but never completes the operation, which is valid because cancel acknowledgement is not operation cancellation.

## Developer Knowledge Search

### Local code/comments/tests

- Existing `TestTransitionStartedEmitsStartToCloseTimeout` covers `TransitionStarted` without a pending cancellation and expects one `StartToCloseTimeout` task.
- Existing `TestCancelationBeforeStarted` covers cancel-before-started and async started, but asserts only that the cancellation task is emitted; it does not set or assert `StartToCloseTimeout`.
- Existing `TestProcessStartToCloseTimeoutTask` verifies the timer handler produces a `NEXUS_OPERATION_TIMED_OUT` event when a `StartToCloseTimeoutTask` exists.
- The cancellation executor comment states: "The operation is not yet canceled and may ignore our request, the outcome will be known via the completion callback."

### Git history and PR/issue search

Commands/results:

- `gh search issues StartToCloseTimeout nexusoperations --repo temporalio/temporal --limit 20 ...` returned `[]`.
- `gh search issues Nexus start-to-close cancel --repo temporalio/temporal --limit 20 ...` returned `[]`.
- `gh search prs StartToCloseTimeout Nexus --repo temporalio/temporal --limit 30 ...` returned nearby merged PRs including `https://github.com/temporalio/temporal/pull/10014` (Standalone Nexus timeouts), `#10602`, `#9278`, and `#9786`, none describing in-workflow HSM cancellation-before-started missing timer publication.
- `gh search prs cancelation StartToCloseTimeout --repo temporalio/temporal --limit 30 ...` returned `[]`.
- `gh search prs StateMachineTimers Nexus cancel --repo temporalio/temporal --limit 30 ...` returned `[]`.
- `gh search prs "cancel before started" Nexus --repo temporalio/temporal --limit 30 ...` returned related prior work:
  - `https://github.com/temporalio/temporal/pull/6483` "Fix operation cancel just before started" (merged 2024-09-05), whose body says it fixed failure to deliver the cancel request if canceled just before started.
  - `https://github.com/temporalio/temporal/pull/6429` "Fix replication of nexus operations that are canceled before started" (merged 2024-08-22), a replication-specific prior fix.
  - `https://github.com/temporalio/temporal/pull/5801` operation cancellation executors.
- `git blame` shows the cancellation-before-started nested transition came from PR #6483 (`98b873b43a`), while start-to-close timeout task generation was added later by PR #9153 (`f911e1e7a`, `https://github.com/temporalio/temporal/pull/9153`).

Known-status conclusion: no public issue/PR found that reports the exact combined mechanism at this site: in-workflow legacy HSM Nexus operation, cancellation requested before async started, parent `StartToCloseTimeoutTask` omitted while cancellation acknowledgement leaves the operation running.

## Reproduction Plan

Use a Level 1 timing-assisted public workflow-service test:

1. Publicly start a workflow and complete a workflow task with `ScheduleNexusOperation` plus a short workflow timer to force another workflow task.
2. Keep the external Nexus `StartOperation` handler blocked.
3. Complete the next workflow task with `RequestCancelNexusOperation`.
4. Release the start handler so it returns async started.
5. Observe the real cancel request sent and acknowledged.
6. Inspect database mutable state via Admin `DescribeMutableState`.
7. Wait past the start-to-close deadline and verify the operation remains pending and no timeout event appears.
8. Call explicit Admin `RefreshWorkflowTasks` as a mask/repair check and verify the timeout then appears.
