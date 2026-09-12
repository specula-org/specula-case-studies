# CR-4 Investigation

Finding: History outcomes and replacement before original acknowledgement

Source revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.

Worktree note: the checkout already contains Specula instrumentation changes; this investigation preserved them and used the requested confirmation worktree.

## Step 1: Code Audit

Cited sites:

- `service/matching/pri_task_reader.go:114-160`: `completeTask` handles `taskResponse` from a backlog task. Transient/context errors put the same in-memory task back into the matcher. Other errors call `respoolTaskAfterError`; only after that returns nil does the reader lock, record backlog age, ack the original task id, possibly GC, and update cached ack/backlog stats.
- `service/matching/pri_backlog_manager.go:362-390`: `respoolTaskAfterError` rewrites the same logical `TaskInfo` with a higher task id. If the rewrite fails after retry, it logs persistent-store failure, sets `skipFinalUpdate`, unloads the physical queue, and returns an error to `completeTask`, which skips acking the original record.
- `service/matching/matching_engine.go:808-889`: workflow polling calls `recordWorkflowTaskStarted`; accepted responses finish the queue record and return the poll response. `TaskAlreadyStarted`, `ObsoleteDispatchBuildId`, and `ObsoleteMatchingTask` are treated as invalid/obsolete drops. Resource-exhausted and default errors keep polling after completing the task with an error.
- `service/matching/matching_engine.go:1037-1132`: activity polling is analogous, with an additional `ActivityStartDuringTransition` drop branch whose comment states History will schedule another task once the transition ends.
- `service/matching/matching_engine.go:3484-3565` and `:3568-3611`: each outer `recordWorkflowTaskStarted` / `recordActivityTaskStarted` call creates a fresh `RequestId` before invoking History.
- `service/history/api/recordworkflowtaskstarted/api.go:98-111`: if a workflow task is already started with the same request id, History returns the started response idempotently; with a different request id, it returns `TaskAlreadyStarted` and comments that Matching may drop the task.
- `service/history/api/recordactivitytaskstarted/api.go:150-170`: activities have the same same-request idempotence and different-request `TaskAlreadyStarted` behavior.
- `client/history/retryable_client_gen.go:674-686` and `:704-716`: the retryable History client retries the same request object, preserving `RequestId`.
- `common/resource/fx.go:328-333`: production resource wiring wraps the raw History client with `history.NewRetryableClient`.
- `service/history/timer_queue_active_task_executor.go:440-455` and `:1015-1029`: a started workflow task that times out with `START_TO_CLOSE` records a workflow-task timeout and schedules a new workflow task.

Call chain:

`matchingservice.PollWorkflowTaskQueue` / `PollActivityTaskQueue` -> `pollTask` -> backlog task dispatch -> `recordWorkflowTaskStarted` / `recordActivityTaskStarted` -> History `Record*TaskStarted` -> `internalTask.finish` -> `priTaskReader.completeTask` -> retry-in-matcher, replacement spool, ack, GC, or unload.

Reachability:

The branch is reachable through normal Matching service polling after `AddWorkflowTask` / `AddActivityTask` spools a task. The confirmation harness exercises this using the real Matching engine, the priority backlog path (`useNewMatcher=true`, `enableFairness=false`), and a SQLite task store. It controls only History/store outcomes to force timing/fault cases.

Constructed CR-4 trigger scenarios:

1. History start response is lost after History accepted the start. The non-retryable raw-client version returns a transient error to Matching after History has accepted the task. Matching re-adds the same task to the matcher; the next outer attempt has a fresh request id, and History returns `TaskAlreadyStarted`.
2. History rejects a start with a non-transient error requiring replacement. Matching writes the same logical work back to persistence under a new task id, then acknowledges the original. The replacement is later delivered.
3. The replacement write commits but returns an error. Matching retries the replacement and may create a duplicate replacement record. Later dispatch of the duplicate reaches History, which returns `TaskAlreadyStarted`, so the duplicate is dropped.
4. If replacement write fails without a known commit, `respoolTaskAfterError` unloads the physical queue before `completeTask` acks the original; `skipFinalUpdate` prevents a misleading final metadata write while the store is failing.

Safeguards encountered:

- Retryable History client preserves a `Record*TaskStartedRequest` object and request id across internal RPC retries.
- History accepts same-request duplicate starts idempotently and rejects different-request duplicate starts as `TaskAlreadyStarted`.
- Replacement write success occurs before original ack.
- Replacement write failure path returns before original ack and unloads the queue with `skipFinalUpdate=true`.
- Workflow task start-to-close timeout schedules a new workflow task when a started task never reaches a worker.

## Step 2: Developer Knowledge Search

Issue/PR tracker searches run against `temporalio/temporal` on 2026-09-11:

- Exact-string searches for `respoolTaskAfterError`, `RecordWorkflowTaskStarted RequestId TaskAlreadyStarted matching`, `Persistent store operation failure StopTaskQueue matching`, and `History should've scheduled another task ObsoleteMatchingTask` returned no issue/PR hits.
- Broader searches for `matching task queue lost task History started`, `task rewrite matching history`, `skipFinalUpdate matching`, and `CompleteTasksLessThan respool matching` returned no issue/PR hits.
- `gh issue list --repo temporalio/temporal --state all --search "matching task queue History TaskAlreadyStarted"` found open issue `#10320`, "Workflow task hang on cold start + matching service rejects retries with 'task already started'". A maintainer comment says the reported delete-namespace symptom is unlikely to be in Matching, so this is related symptom evidence but not the exact CR-4 mechanism.
- `gh issue view 11733 --repo temporalio/temporal` found open issue `#11733`, "Task start can remain undelivered after an ambiguous History timeout". Its body reports that Matching creates a short child context for `RecordWorkflowTaskStarted` / `RecordActivityTaskStarted`; History can commit the start while Matching observes the child-context deadline; a later selection creates a different `RequestId`, History returns `TaskAlreadyStarted`, Matching drops the delivery, and no worker receives the committed start response.
- `gh pr view 11734 --repo temporalio/temporal` found open PR `#11734`, "Retry ambiguous task starts for active worker polls". Its body says it keeps one `RecordWorkflowTaskStarted` or `RecordActivityTaskStarted` request and request id across attempt-local deadlines while the original worker poll remains active. The PR is still open and unmerged, so the public fix status is unfixed.

Git history / blame:

- `git log --all --grep='respool|re-spool|rewrite|TaskAlreadyStarted|RecordWorkflowTaskStarted|skipFinalUpdate|lost task|task queue' --regexp-ignore-case` covered local commit history and recently merged/closed PRs reachable in this checkout. It showed nearby Matching/History changes, including `83b35dc3b Fix read and ack levels moving backwards in priTaskReader (#11570)`, `3fd45b561 Fix bypass reader in priority backlog manager (#9841)`, and `a78e7448c Advance ack level when queue is drained (#9731)`, but none were the same already-merged fix as `#11734`.
- `git blame -L 114,140 service/matching/pri_task_reader.go` shows the replacement/error handling in `completeTask` came from `62102334a Priority-enabled TaskMatcher (#7196)` and `6e57e17da Implement reader bypass in matching (#7413)`, with only current uncommitted Specula probes around it.
- `git blame -L 362,390 service/matching/pri_backlog_manager.go` shows `respoolTaskAfterError` came from `6e57e17da Implement reader bypass in matching (#7413)`, with comments explicitly preserving the old record by unloading before ack on replacement-write failure.

Existing tests:

- `service/matching/matching_engine_test.go:779-898` asserts individual History error branches drop with the expected `tasks_dropped` reasons.
- `service/matching/specula_scenarios_test.go:422-488` exercises replacement, uncertain replacement, and replacement fencing under the priority backlog with a real SQLite task store plus controlled History/store outcomes.
- `service/matching/specula_scenarios_test.go:570-669` exercises History response loss and retryable History RPC behavior.
- PR `#11734` adds tests specifically for retrying `RecordWorkflowTaskStarted` and `RecordActivityTaskStarted` across attempt deadlines with the same request id.

## Step 3: Known Status / Precedent

This finding is code-review sourced and duplicates an already-filed public Temporal issue for the same mechanism and same sites: `https://github.com/temporalio/temporal/issues/11733`. The accompanying fix PR is `https://github.com/temporalio/temporal/pull/11734`, state `OPEN`, `mergedAt: null`, so the fix status is `unfixed`.

Status: DROPPED (code-review x known, cite: https://github.com/temporalio/temporal/issues/11733)
