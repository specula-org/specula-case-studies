# CR-3 Investigation

## Source And Revision

- Finding source: code review.
- Source repository: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-3/worktree`.
- Revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.
- Local tree note: the worktree has Specula tracing instrumentation already present; the CR-3 implementation logic in the cited matching files is unchanged except for `speculaProbe` calls.

## Code Audit

- `service/matching/pri_task_reader.go:114-160`: backlog task completion updates the reader after the task has either been successfully handed to History/worker or classified as a non-retryable/drop case. Transient errors re-add the task to the matcher and return before acknowledging; other errors are re-spooled before acknowledging, and failed re-spool unloads without acknowledging.
- `service/matching/pri_task_reader.go:474-505`: `ackTaskLocked` advances the in-memory prefix by removing contiguous completed entries. If the reader is drained, it can set `ackLevel = readLevel`, including over a final task-id gap.
- `service/matching/pri_task_reader.go:550-610`: `maybeGCLocked` snapshots `tr.ackLevel` and asynchronously calls `doGCAt`, which invokes `db.CompleteTasksLessThan(ctx, ackLevel+1, ...)`.
- `service/matching/db.go:345-378`: `updateAckLevelAndBacklogStats` updates the cached DB metadata and marks `lastChange`, but does not synchronously persist the metadata blob.
- `service/matching/db.go:303-324`: `SyncState` persists cached metadata only when changed or when the TTL guard requires it; otherwise it verifies the stored range ID.
- `service/matching/db.go:754-779`, `common/persistence/sql/task_v1.go:160-188`, and `common/persistence/cassandra/matching_task_store_v1.go:197-220`: `CompleteTasksLessThan` deletes task rows below the supplied bound; the delete is not fenced by the persisted metadata ack value.
- `service/matching/pri_backlog_manager.go:126-147`: `Stop` refreshes cached ack from readers and calls `SyncState`, but skips final update after ownership-conflict paths (`signalIfFatal` sets `skipFinalUpdate` at `service/matching/pri_backlog_manager.go:108-118`).
- `service/matching/physical_task_queue_manager.go:317-335`: physical queue stop calls backlog stop before canceling the task-queue context.

Reachability:

- Public add path: `matchingEngineImpl.AddWorkflowTask` spools through the selected priority backlog manager with `matching.useNewMatcher=true` and fairness disabled.
- Public poll path: `matchingEngineImpl.PollWorkflowTaskQueue` polls the queue, calls `recordWorkflowTaskStarted` (`service/matching/matching_engine.go:808`, `service/matching/matching_engine.go:3484-3533`), then calls `task.finish` on success (`service/matching/matching_engine.go:887`), which reaches `priTaskReader.completeTask`.
- Ownership replacement is a normal matching-service lifecycle event: a new manager acquires the queue by `RenewLease`; the old owner sees `ConditionFailedError`, sets `skipFinalUpdate`, and unloads.

Constructed trigger scenario:

1. Owner 1 accepts two workflow tasks via `AddWorkflowTask`.
2. Workers poll the tasks via `PollWorkflowTaskQueue`; History accepts both `RecordWorkflowTaskStarted` calls and both poll responses reach workers.
3. Owner 1 advances its in-memory reader ack to 2 and launches GC.
4. Before Owner 1 persists the updated metadata ack, Owner 2 takes over the task queue range.
5. Owner 1's already-launched GC deletes task rows `< 3`; Owner 1's delayed metadata sync then fails the range condition and unloads without a final metadata update.
6. Owner 2 reads the same range from the old persisted ack. The deleted rows are absent, so it gap-scans and advances ack; the work was already accepted by History and delivered to workers.

Safeguards / semantic boundaries encountered:

- A backlog task is not acknowledged on transient start errors; it is returned to the matcher.
- A non-transient start error is either treated as an intentional drop (`Internal`, `DataLoss`, `NotFound`, duplicate/obsolete) or triggers re-spooling before the original is acknowledged.
- Once `RecordWorkflowTaskStarted` succeeds for a workflow task and the poll response reaches the worker, the matching backlog row is no longer required for delivery of that task.
- Owner replacement fences metadata writes by range ID; the stale owner's metadata update fails rather than overwriting the new owner.

## Developer Knowledge

- `git blame` on `ackTaskLocked` shows the drained-queue ack jump was introduced by `a78e7448c0` / PR #9731. The PR explains that when the task-id range ends in a gap, the reader can move ack higher once the queue is empty and use that to reset backlog count divergence.
- `git blame` on `SyncState` and local history show PR #9739 intentionally skipped most task-queue metadata writes on append as an optimization, with the stated risk limited to approximate backlog count values during partition move.
- PR #10018 changed the no-write `SyncState` branch to verify range ID because skipped metadata writes also served ownership-loss detection.
- PR #8007 fixed priority backlog manager unload to sync ack from the reader.
- PR #11570, merged 2026-08-15, is related but not the same reported mechanism: it fixes read/write bypass races where `priTaskReader` read/ack levels could move backwards and includes tests for stale gap results and already-acked rereads. It does not report old-owner GC deleting below a stale persisted metadata ack after takeover.

## Known Status / Precedent

Prior-report search performed before marking novelty:

- GitHub open and closed issue/PR search with PRs included for `priTaskReader ack metadata GC CompleteTasksLessThan`: no results.
- GitHub open and closed issue/PR search with PRs included for `"CompleteTasksLessThan" "AckLevel" matching`: no results.
- GitHub closed issue/PR search with PRs included for `"task queue" "ack level" "priTaskReader"`: no results.
- GitHub closed issue/PR search with PRs included for `"task queue" "metadata" "ownership" "matching"`: no exact mechanism result.
- Local git history since 2026-07-01 for the cited matching files found #11570 and other matching changes, but no commit or PR reporting stale persisted ack plus old-owner cleanup as a defect.

Known-status conclusion for the exact CR-3 mechanism: no existing issue/PR/CVE/advisory found that reports this exact defect at this site. Novelty field should be `NEW`, while the verdict still depends on reproduction and consequence.
