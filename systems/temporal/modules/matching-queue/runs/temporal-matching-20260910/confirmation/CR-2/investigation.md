# CR-2 Investigation

## Scope

- Finding: CR-2, "Read snapshots, bypass, and proof of an empty interval"
- Source classification for confirmation output: Code Review. There is no supplied model-checker counterexample.
- Source revision inspected: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.
- Worktree note: requested worktree is dirty with Specula instrumentation/tests; investigation preserved that state and used the pinned HEAD plus the visible instrumentation only as observation hooks.
- Selected default queue mode at this revision: `matching.useNewMatcher` defaults true and `matching.enableFairness` defaults false (`common/dynamicconfig/constants.go:1600` and `common/dynamicconfig/constants.go:1606`), selecting the priority backlog path in `service/matching/physical_task_queue_manager.go:233`.

## Code Audit

- Public reachability:
  - Workflow tasks enter matching through `matchingEngineImpl.AddWorkflowTask` (`service/matching/matching_engine.go:586`), which builds a durable `TaskInfo` and calls `pm.AddTask` (`service/matching/matching_engine.go:639`).
  - Activity tasks enter through `matchingEngineImpl.AddActivityTask` (`service/matching/matching_engine.go:646`) and also call `pm.AddTask` (`service/matching/matching_engine.go:690`).
  - If sync match does not complete, `taskQueuePartitionManagerImpl.AddTask` calls `spoolQueue.SpoolTask` (`service/matching/task_queue_partition_manager.go:660`), which reaches the priority backlog manager when new matcher is enabled (`service/matching/physical_task_queue_manager.go:233`).
  - Workers observe the backlog through `PollWorkflowTaskQueue` and `PollActivityTaskQueue`, both of which call `pollTask` (`service/matching/matching_engine.go:738`, `service/matching/matching_engine.go:1017`, `service/matching/matching_engine.go:3049`).
- Writer/read bypass:
  - `priTaskWriter.appendTasks` persists tasks with `db.CreateTasks` and then calls `signalReaders` (`service/matching/pri_task_writer.go:131`).
  - `taskQueueDB.CreateTasks` records per-subqueue `maxReadLevelBefore` and `maxReadLevelAfter`, persists all tasks, then sets `db.subqueues[sq].maxReadLevel` even when task IDs are skipped/rejected (`service/matching/db.go:545`, `service/matching/db.go:587`).
  - `priBacklogManagerImpl.signalReaders` forwards each subqueue response to `priTaskReader.signalNewTasks` (`service/matching/pri_backlog_manager.go:257`).
  - `signalNewTasks` takes the direct bypass path only when `tr.readLevel == resp.maxReadLevelBefore`, there is memory room, and no task is already outstanding; on success it advances `readLevel` to `maxReadLevelAfter` and records the tasks in memory (`service/matching/pri_task_reader.go:399`).
- Read/gap processing:
  - `getTaskBatch` snapshots `tr.readLevel` before storage I/O, obtains `maxReadLevel`, scans bounded ranges with `db.GetTasks`, and returns immediately if any tasks are present (`service/matching/pri_task_reader.go:225`).
  - If the page contains no tasks, it advances its local `readLevel` to `upper` and eventually returns an empty batch with `readLevel` and `isReadBatchDone` (`service/matching/pri_task_reader.go:247`).
  - The caller treats an empty batch as a gap: `getTasksPump` calls `setReadLevelAfterGap(batch.readLevel)` and reschedules only when `!batch.isReadBatchDone` (`service/matching/pri_task_reader.go:197`).
  - `setReadLevelAfterGap` rejects stale gap results that would move read level backward after bypass already advanced it (`service/matching/pri_task_reader.go:508`), and if `ackLevel == readLevel` it also advances `ackLevel` to the gap upper bound and persists backlog stats (`service/matching/pri_task_reader.go:523`).
- Duplicate/already-acked safeguards:
  - `processTaskBatch` advances `readLevel` to each returned task ID and filters expired tasks (`service/matching/pri_task_reader.go:261`).
  - It filters tasks at or below the current `ackLevel`, explicitly covering tasks direct-added by `signalNewTasks` and acked before the in-flight persistence read is processed (`service/matching/pri_task_reader.go:273`).
  - It filters tasks already present in `outstandingTasks` (`service/matching/pri_task_reader.go:286`).
  - `ackTaskLocked` advances contiguous acknowledgements and, when drained, advances `ackLevel` to `readLevel` (`service/matching/pri_task_reader.go:474`).
- Persistence backend observations:
  - SQL v1 `GetTasks` uses actual selected rows; it only sets `NextPageToken` when `len(rows) == PageSize` and the token is based on the last returned task ID (`common/persistence/sql/task_v1.go:102` and `common/persistence/sql/task_v1.go:144`). An empty SQL page therefore does not carry a nonterminal token.
  - Cassandra v1 `GetTasks` does copy `iter.PageState()` to `response.NextPageToken` independently of how many decoded tasks were appended (`common/persistence/cassandra/matching_task_store_v1.go:154` and `common/persistence/cassandra/matching_task_store_v1.go:187`).
  - The Cassandra task schema at this revision has no CQL `static` columns in `tasks`; `range_id`, `task_queue`, and `task_queue_encoding` are ordinary columns on rows keyed by `(type, task_id)` (`schema/cassandra/temporal/schema.cql:83`). Task reads constrain `type = rowTypeTaskInSubqueue(request.Subqueue)` (`common/persistence/cassandra/matching_task_store_v1.go:146`), while task-queue metadata uses `rowTypeTaskQueue` and `taskQueueTaskID` (`common/persistence/cassandra/matching_task_store_v1.go:96` and `common/persistence/cassandra/matching_task_store.go:25`). This is evidence against the comment's "static column record returned" branch being reachable from the current schema, but it does not by itself prove every Cassandra/Scylla paging edge.

## Trigger Hypothesis

A real harmful trigger would require the priority reader to receive a storage response for `(readLevel, upper]` with `len(response.Tasks) == 0` even though the backend has an eligible, unexpired task in that interval and will expose it through a continuation token. `getTaskBatch` ignores the token, the pump treats the page as an empty gap, and if no outstanding tasks remain (`ackLevel == readLevel`) `setReadLevelAfterGap` can advance both read and ack to `upper`. The worker-facing consequence would be `PollWorkflowTaskQueue`/`PollActivityTaskQueue` returning no work while durable eligible work remains below the advanced read/ack frontier.

The ordinary read/write bypass race without a nonterminal empty page has explicit safeguards after PR #11570: stale gaps are ignored, already-acked rows are filtered, and duplicate outstanding rows are filtered.

## Developer Knowledge / Known Status Search

- Local git history for `service/matching/pri_task_reader.go`, `service/matching/db.go`, and Cassandra matching task store shows related fixes:
  - `3fd45b561e8ee7de7a5c175416bc54c9da26c118` / PR #9841 "Fix bypass reader in priority backlog manager" says bypass should skip a `GetTasks` call when the queue tail is already in memory; it does not describe empty nonterminal persistence pages. URL: https://github.com/temporalio/temporal/pull/9841
  - `2a10a6d1b` / PR #11047 "Fix reset backlog count after gap" covers backlog count reset after gap, not skipped rows. URL: https://github.com/temporalio/temporal/pull/11047
  - `83b35dc3bac4ea05296154e0b50055026d200150` / PR #11570 "Fix read and ack levels moving backwards in priTaskReader" says it fixed read/write races where bypass races with a persistence read, including stale `setReadLevelAfterGap` and already-acked reads; it does not mention `NextPageToken` or empty Cassandra pages. URL: https://github.com/temporalio/temporal/pull/11570
  - PR #11917 cherry-picks #11570 to release/v1.32.x. URL: https://github.com/temporalio/temporal/pull/11917
- GitHub issue/PR search:
  - `gh search issues --repo temporalio/temporal "priTaskReader NextPageToken" --state open --include-prs` and closed variant: no results.
  - `gh search issues --repo temporalio/temporal "setReadLevelAfterGap" --state open/closed --include-prs`: found PR #11570 and #11047 only.
  - `gh search issues --repo temporalio/temporal "Cassandra matching task GetTasks empty page" --state open/closed --include-prs`: no results.
  - `gh search issues --repo temporalio/temporal "matching task pagination" --state open/closed --include-prs`: no results.
  - `gh search issues --repo temporalio/temporal "ignored NextPageToken" --state open/closed --include-prs`: no results.
  - `gh search issues --repo temporalio/temporal "static column record returned" --state open/closed --include-prs`: no results.
- Web search against `github.com/temporalio/temporal` for matching priority `GetTasks` / `NextPageToken` / Cassandra empty page did not find a same-site filed report.

Known-status evidence: no existing issue/PR/CVE/advisory found that reports this exact empty-nonterminal-page mechanism at the priority matching reader. Related read/bypass races are known/fixed in #11570, but not this mechanism.

## Reproduction Plan Inputs

- Level 0: run a normal add-then-poll workflow task through the priority matching path with the in-memory Temporal test task manager; expected result is one task returned and no skip.
- Level 1: run a targeted in-package schedule that uses a real `subqueueCreateTasksResponse` from `db.CreateTasks`, applies it through `priTaskReader.signalNewTasks`, then applies a stale gap to `setReadLevelAfterGap`; expected result is that bypassed tasks stay delivered and the stale gap is ignored.
- Level 2: inject a `TaskManager.GetTasks` response containing `Tasks: nil` plus a non-empty `NextPageToken` while the backing store contains an eligible task in the requested interval. This is a diagnostic for the code path, not a real reproduction unless a real selected backend can produce that response.
- SQLite probe: run a real SQLite task-store paging test with `PageSize=1`; expected result is every nonterminal page has one decoded task and the final page has no token.
- Cassandra preflight/probe: if Cassandra is reachable on the configured test port, run a targeted Cassandra task pagination test checking whether a nonterminal page can have zero decoded tasks. If Cassandra is not reachable, record that environment limit and fall back to schema/source evidence for reachability.
