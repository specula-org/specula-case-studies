# CR-1 Investigation

## Scope

Finding: CR-1, "Acceptance, uncertain persistence, and fresh ownership".

Source revision checked: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025` in `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-1/worktree`.

Source: Code Review. No model-checking counterexample was supplied for this finding.

## Step 1: Code Audit

Relevant code:

- `service/matching/pri_task_writer.go:68-100`: `appendTask` submits a `writeTaskRequest` to the writer channel and then races the writer response against `tqCtx.Done()`. The shutdown branch returns `errShutdown` to the caller.
- `service/matching/pri_task_writer.go:112-146` and `179-186`: the writer allocates a task ID, calls `db.CreateTasks`, signals readers only after a nil store error, and then publishes the writer result back to the waiter.
- `service/matching/db.go:178-210`: takeover reads persisted queue metadata, increments `RangeID`, and then sets each subqueue `maxReadLevel` to just before the fresh owner's new task-ID block because tasks may have been written by the prior owner.
- `service/matching/db.go:529-610`: `CreateTasks` prepares durable task rows, increments approximate backlog count, calls the task store, advances the local max-read level after the store returns, and only rolls the counter back when `writeDefinitelyFailed(err)` says the write definitely did not reach storage.
- `service/matching/db.go:690-710`: developer comment says errors such as `Unavailable` may or may not have reached the database; only condition failure and persistence/concurrent rate-limit rejection are treated as definitely uncommitted.
- `common/persistence/sql/task_v1.go:44-99`: SQL V1 `CreateTasks` inserts task rows and locks/checks the task queue range in one transaction.
- `common/persistence/sql/task_queues.go:86-128`: SQL `UpdateTaskQueue` locks the current task queue row by previous range and updates the new range/metadata in the same transaction.
- `service/matching/pri_task_reader.go:399-431`: direct read-bypass from a successful write only happens when the reader is at the previous max-read level; otherwise the reader is signaled to reload from persistence.
- `service/matching/pri_task_reader.go:474-505`: completion advances ack monotonically over acknowledged outstanding tasks and, when drained, advances ack to read level.
- `service/matching/matching_engine.go:808-887`: a polled workflow task calls History `RecordWorkflowTaskStarted`; `TaskAlreadyStarted`, obsolete, not-found, and other non-live outcomes finish/drop the backlog task instead of returning another worker task.
- `service/history/api/recordworkflowtaskstarted/api.go:69-111`: History rejects missing, obsolete, or already-started workflow tasks; if the same request already started the task it returns the started response, and a different request gets `TaskAlreadyStarted`.

Call chain:

`matchingEngineImpl.AddWorkflowTask` creates a `TaskInfo` and calls `taskQueuePartitionManagerImpl.AddTask`; when sync match is unavailable, `AddTask` falls back to `physicalTaskQueueManagerImpl.SpoolTask`, then `priBacklogManagerImpl.SpoolTask`, `priTaskWriter.appendTask`, `priTaskWriter.appendTasks`, and `taskQueueDB.CreateTasks`. Pollers later reach `matchingEngineImpl.PollWorkflowTaskQueue`, the priority matcher, `recordWorkflowTaskStarted`, and `priTaskReader.completeTask`.

Reachability:

The base path is reachable through normal Matching Add/Poll APIs under the target configuration: `matching.useNewMatcher` defaults true and `matching.enableFairness` defaults false at `common/dynamicconfig/constants.go:1600-1610`. Store-response loss and queue unload/reload are normal distributed failure classes. The controlled tests use a real file-backed SQLite task store plus Matching's normal Add/Poll paths; the store wrapper injects response loss after the real store commit, not a fabricated task row.

Safeguards observed:

- RangeID fencing rejects stale-owner writes after a fresh owner has taken over.
- Fresh-owner takeover widens the read ceiling to include the old owner's prior allocation range.
- Committed rows are replayable by the fresh reader even when the old local reader notification was skipped or the caller saw shutdown.
- The caller-side retry can create duplicate durable rows for the same workflow task identity, but History's `TaskAlreadyStarted` path and Matching's drop-on-duplicate handling prevent a second worker-visible start.

Concrete trigger candidate:

1. A workflow task falls through sync match and is spooled to the priority backlog.
2. `CreateTasks` commits, but the response is lost, or the queue unloads before the Add caller observes the writer response.
3. The Add caller retries or the old owner stops/loses ownership.
4. A fresh owner takes over the task queue and polls the backlog.
5. The suspected defect would be that the still-eligible accepted task is no longer represented by a durable row, delivery, replay, or valid retry.

## Step 2: Developer-Knowledge Search

Issue/PR search actually run:

- Web search for Temporal issues/PRs with `matching CreateTasks Unavailable task queue maxReadLevel owner reload`, `priTaskWriter appendTask shutdown CreateTasks task queue ownership`, `useNewMatcher CreateTasks owner reload task queue`, and `"pri_task_writer" "CreateTasks"` found no exact upstream issue or PR.
- `gh search prs --repo temporalio/temporal 'matching task queue CreateTasks owner reload' --state closed/open`: no results.
- `gh search prs --repo temporalio/temporal 'priTaskWriter appendTask shutdown' --state closed`: no results.
- `gh search prs --repo temporalio/temporal 'priority backlog bypass reader ack level' --state closed`: no exact result.
- `gh search issues --repo temporalio/temporal 'matching task queue lost task CreateTasks' --state closed/open`: no results.
- `gh search issues --repo temporalio/temporal 'priority backlog owner reload task queue' --state open`: no results.
- `gh search issues --repo temporalio/temporal 'task queue lost task matching' --state closed`: no results.

Related but not exact duplicate PRs:

- https://github.com/temporalio/temporal/pull/10848, "Use buffered channel in task writers", fixed a harmless goroutine leak where a writer could block after shutdown. It does not report task loss, fresh-owner replay failure, or uncertain committed writes.
- https://github.com/temporalio/temporal/pull/11570, "Fix read and ack levels moving backwards in priTaskReader", fixes bypass/read overlap causing read/ack regression. It is related queue-conservation work, but not the same committed-response-loss plus owner-takeover mechanism.
- https://github.com/temporalio/temporal/pull/9841, "Fix bypass reader in priority backlog manager", fixes bypass-reader logic and notes `CreateTasks+signalNewTasks` is subtle. It is not an existing report of this candidate.

Git history/comments:

- `git log --oneline -- service/matching/pri_task_writer.go service/matching/db.go service/matching/pri_task_reader.go service/matching/pri_backlog_manager.go common/persistence/sql/task_queues.go common/persistence/sql/task_v1.go` shows related backlog changes including #9841, #10848, #11046, #11047, and #11570, but no commit message describing this exact defect.
- `git blame` attributes the priority writer append path to the new matcher work and PR #10848's buffered channel change. The inserted Specula probes are local uncommitted instrumentation only.
- Developer intent in comments is conservative around uncertain store errors (`db.go:690-710`) and explicit around takeover replay bounds (`db.go:205-210`).

Existing tests/scenarios:

- `service/matching/specula_scenarios_test.go:401-420` exercises a committed-but-lost `CreateTasks` response, retry/lost caller receipt, delivery, duplicate History start rejection, GC, stop, reload, and pump.
- `service/matching/specula_scenarios_test.go:471-487` exercises owner replacement while an old-owner write is at the store gate; the old owner is fenced, and the fresh owner later polls the task.
- `service/matching/specula_scenarios_test.go:610-628` exercises append shutdown after owner replacement before writer publish.
- `service/matching/specula_scenarios_test.go:629-646` exercises insertion after stop, reload, and poll delivery.

## Step 3: Known Status

Novelty search result: NEW. I found adjacent backlog/bypass/shutdown PRs and current tests for the mechanism, but no issue, PR, CVE, advisory, or public upstream report that describes the same mechanism at the same site as a filed defect: committed or uncertain priority-backlog append, caller uncertainty, and fresh owner takeover causing loss of an accepted still-eligible task.
