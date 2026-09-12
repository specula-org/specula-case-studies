# CR-2 Investigation

## Scope

- Source revision checked: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.
- Finding source: code review.
- Main location: `service/history/api/respondworkflowtaskcompleted/api.go:175`.
- Timer-related location: `service/history/timer_queue_active_task_executor.go:409`.

## Code Audit

`RespondWorkflowTaskCompleted` captures `currentWorkflowTask` before validating the task token identity. Its deferred cleanup then runs whenever `retError != nil`, `currentWorkflowTask != nil`, the captured task is speculative, and sticky state is set (`service/history/api/respondworkflowtaskcompleted/api.go:168-202`). The identity guard below it rejects mismatched task tokens by `StartedEventID`, `StartedTime`, attempt, and version, and intentionally sets `releaseLeaseWithError = false` before returning `NotFound` (`service/history/api/respondworkflowtaskcompleted/api.go:204-214`). The cleanup is therefore not gated on whether the error happened before or after identity validation. It calls `clearStickyTaskQueue`, which clears the workflow context, reloads mutable state, clears sticky task queue, and persists that update (`service/history/api/respondworkflowtaskcompleted/api.go:1176-1186`).

The public caller path is the application worker's `RespondWorkflowTaskCompleted` API (`service/frontend/workflow_handler.go:1211-1255`). The test worker path receives the returned error through `tests/testcore/taskpoller.go:266-296`.

The timer executor first locates a workflow task by event ID and checks stamp (`service/history/timer_queue_active_task_executor.go:409-418`). It only checks the in-memory speculative timer object identity while the current workflow task is still speculative (`service/history/timer_queue_active_task_executor.go:421-427`). If a replacement speculative task is converted to normal before the stale in-flight in-memory timer resumes, the normal branch checks version and attempt but not the old in-memory timer pointer (`service/history/timer_queue_active_task_executor.go:429-438`). Temporal's in-memory timer queue documentation says `CheckSpeculativeWorkflowTaskTimeoutTask` is the protection that makes old speculative timeout tasks ignored after mutable state loses and recreates a speculative WFT (`docs/architecture/in-memory-queue.md:12-19`), but that protection no longer applies after conversion to normal.

## Reachable Scenario

Completion path:

1. A worker completes the first normal WFT with sticky attributes, setting a sticky task queue.
2. An Update request admits a speculative WFT on the sticky queue and a worker polls it.
3. The shard/workflow cache is closed/replaced while the old worker still has the task token.
4. The Update request is retried/admitted again and a replacement speculative sticky WFT is polled. It has the same scheduled/started event IDs but a different started time.
5. The old worker responds first. Identity validation rejects it with `NotFound`, but the deferred speculative-WFT error cleanup clears stickiness on the current cached workflow.
6. The replacement worker responds with its still-current token and is also rejected. The Update is then admitted again and delivered on the normal queue, where completion succeeds.

Timer path:

1. A speculative WFT start-to-close timeout task enters execution in the in-memory queue.
2. The workflow context is cleared and the old in-memory timeout task is canceled after it has already entered execution.
3. A replacement speculative WFT is created with the same scheduled/started IDs, attempt, version, and stamp but a newer started time.
4. An event converts the replacement WFT to normal before the old timeout executor resumes.
5. The old timer resumes, takes the normal-WFT branch, and records a timeout for the replacement before its own start-to-close deadline.

## Developer Knowledge / Prior Reports

Local blame shows the completion cleanup was introduced by commit `3b0fae7f1e3a283f15787593f4e35dbc33e8b7a8`, PR #6295, "Clear sticky task queue on speculative WFT error." Its commit message explains the intent: when a speculative WFT completion returns an error, the worker clears its cache, so the server clears stickiness to force the next WFT to the normal queue. The message also calls this a workaround and notes future work around `GetWorkflowExecutionHistory`.

Local history also shows PR #9325, "Include transient and speculative WFT events in GetWorkflowExecutionHistoryResponse," later changed the history-fetch behavior that PR #6295's comment references. The cleanup still exists at current upstream `main` as of the live `gh api` check.

Live GitHub issue/PR searches found no already-filed same-site defect for stale completion or stale speculative timers affecting a replacement WFT. Searches included exact terms around `clear stickiness`, `ClearStickyTaskQueue`, `RespondWorkflowTaskCompleted`, `Workflow task not found`, `StartedTime`, sticky Update WFTs, and `CheckSpeculativeWorkflowTaskTimeoutTask`. The target-brief issues checked were not duplicates: #10478 is missing shard-ownership validation during speculative WFT processing, #10775 is `addWorkflowTaskToMatching` matching/build-ID handling, and #11254 is duplicate Nexus Update callback attachment.

Known status: `NEW`.

## Safeguards / Masks

The completion-path functional test proves the live worker-level anomaly, but it also proves a downstream recovery path: after the stale completion causes the live sticky replacement completion to be rejected, the same Update is admitted again, delivered on the normal queue, completed, and the original Update caller receives the expected successful result.

The timer-path focused test proves the speculative-timer object guard masks the stale timer while the replacement remains speculative. It also proves the guard is lost after conversion to normal and the old in-flight timer can create a premature timeout event. The test does not establish a permanent user-visible lost Update; the available completion-path evidence shows Update retry/readmission and normal-queue delivery can recover the caller-visible outcome.
