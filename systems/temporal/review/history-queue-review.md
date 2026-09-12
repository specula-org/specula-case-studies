# Independent review: Temporal history queue CR-4

Verdict: **FALSE POSITIVE**. The stale-owner checkpoint can delete a transfer-task row before the queue-state write is rejected by the shard RangeID fence, but the repro and source path only reach that delete after the old owner's local ACK boundary has already advanced. In the production transfer executor path I did not find a legal way for that ACK to happen before Matching has either accepted the task by sync match, persisted it to Matching backlog, or History/Matching has classified the task as an intentional duplicate/obsolete/no-op. The unfenced range delete is therefore an intentional idempotent cleanup of already completed history queue rows, not a proven masked data-loss defect.

## Scope and source state

Reviewed source pin: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025` in the isolated clone at `work/temporal-review`.

Official upstream check:

- `git ls-remote https://github.com/temporalio/temporal.git refs/heads/main` returned `9ab3a9f770da20df7d94bcc0030f28eec7b0b947` (same as the provided latest observed main). See `logs/upstream-main-ls-remote.txt` and `logs/origin-main-local.txt`.
- Exact GitHub issue/PR searches under `temporalio/temporal` for `RangeCompleteHistoryTasks RangeID`, `stale owner transfer task queue state`, `range delete transfer task ownership`, and `ShardOwnershipLost RangeCompleteHistoryTasks` returned no hits. See `logs/github-search-exact.txt`.
- Relevant diff from the reviewed pin to current `origin/main` does not change the CR-4 mechanism. The diff touches `service/history/queues/executable.go` only for failed-attempt logging and Matching tests/scale-manager code; it does not change `queue_base.go`, `RangeCompleteHistoryTasksRequest`, SQL transfer range delete, shard RangeID fencing, transfer executor AddTask calls, or History Record*TaskStarted duplicate/obsolete handling. See `logs/current-main-relevant-diff.patch`.

## What the original repro proves

I reran the original CR-4 script against the isolated clean clone:

```bash
PATH=/usr/local/go/bin:$PATH \
SOURCE_REPO=/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/history-masked/work/temporal-review \
SOURCE_SHA=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025 \
GOTOOLCHAIN=go1.27.0 GOMAXPROCS=8 GOFLAGS='-p=4' \
timeout 10m bash /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/repro/test_bugCR-4_stale_owner_checkpoint.sh
```

Result: exit `0`; Go test passed in `go.temporal.io/server/service/history/queues` after `1.124s`. The relevant observations were:

- `LEVEL0_ATTEMPT public-api-normal-ops result=not-triggered`
- `LEVEL1_ATTEMPT timing-test-hook result=not-triggered`
- `LEVEL2_ATTEMPT state-injection result=running injected_precondition=durable-rangeid-2-with-old-owner-local-rangeid-1-and-local-ack-boundary-advanced-to-task-2`
- `QUEUE_OBSERVATION range_delete_called ... request_has_range_id=false`
- `QUEUE_OBSERVATION stale_state_update ... error=*persistence.ShardOwnershipLostError`
- `SQL_OBSERVATION transfer_rows_after_old_checkpoint=0 ... durable_rangeid=2 durable_watermark=1 old_owner_memory_delete_watermark=2`

See `logs/original-repro-rerun.log`. The repro establishes the implementation interleaving: an old owner can perform an unfenced row delete and then fail the queue-state update. It does not establish consumer harm, because its injected precondition is already “old owner local ACK boundary advanced.”

## Source facts

The checkpoint path deletes before the queue-state write by design. `service/history/queues/queue_base.go:295-361` computes the new deletion watermark from readers after `ShrinkSlices()`, comments that it “must range-complete task first,” calls `rangeCompleteTasks()` at `queue_base.go:351`, updates the in-memory deletion watermark at `queue_base.go:357`, and then calls `updateQueueState()` at `queue_base.go:360`.

The range-complete request has no shard RangeID field. `common/persistence/data_interfaces.go:450-458` defines `RangeCompleteHistoryTasksRequest` with only `ShardID`, `TaskCategory`, and min/max task keys. `service/history/queues/queue_base.go:385-390` sends only those fields. For SQL transfer tasks, `common/persistence/sql/execution_tasks.go:361-372` calls `RangeDeleteFromTransferTasks` with `ShardID`, `InclusiveMinTaskID`, and `ExclusiveMaxTaskID` only.

The queue-state write is RangeID fenced. `service/history/queues/queue_base.go:408-414` writes through `shard.SetQueueState`. `service/history/shard/context_impl.go:376-385` routes `SetQueueState` through `updateShardInfo`, and `context_impl.go:1277-1291` builds `UpdateShardRequest{PreviousRangeID: s.shardInfo.GetRangeId()}` before calling the shard manager. SQL `UpdateShard` locks and compares `PreviousRangeID`: `common/persistence/sql/shard.go:82-94` calls `lockShard`, and `shard.go:132-142` returns `ShardOwnershipLostError` on range mismatch.

ACK is local and only follows successful/accepted task processing. Common schedulers call `task.Ack()` only after `task.HandleErr(task.Execute())` returns nil: `common/tasks/runnable_scheduler.go:27-37`, `common/tasks/fifo_scheduler.go:190-214`, `common/tasks/execution_queue_scheduler.go:253-277`, and `common/tasks/sequential_scheduler.go:316-344`. The history executable returns the transfer executor error from `service/history/queues/executable.go:402-417`; `HandleErr` returns nil for invalid/safe-to-drop classes, retries ordinary expected errors, and only then allows the scheduler ACK path (`executable.go:584-681`). `Ack()` itself only marks the in-memory task state acked at `executable.go:742-750`. The queue shrink logic uses that acked state: `service/history/queues/tracker.go:85-91`.

The transfer executor does not ACK before Matching acceptance. For activity tasks, `service/history/transfer_queue_active_task_executor.go:234-287` validates mutable state, releases the workflow lock, and returns `pushActivity(...)`. For workflow tasks, `transfer_queue_active_task_executor.go:289-373` validates mutable state, releases the workflow lock because Matching will call back to History, and returns `pushWorkflowTask(...)`. Those push methods call Matching and return any error: `service/history/transfer_queue_task_executor_base.go:95-128` for `AddActivityTask`, and `transfer_queue_task_executor_base.go:147-182` for `AddWorkflowTask`.

Matching AddTask returns success only after sync match succeeds or backlog persistence succeeds. `service/matching/matching_engine.go:586-643` builds workflow `TaskInfo` and returns `pm.AddTask`; `matching_engine.go:645-694` does the same for activity tasks. `service/matching/task_queue_partition_manager.go:615-639` returns from sync match only when `syncMatched && !shouldBacklogSyncMatchTaskOnError(err)`. If sync match is unavailable and the request is not forwarded, it calls `spoolQueue.SpoolTask` at `task_queue_partition_manager.go:653-673`. `service/matching/backlog_manager.go:164-170` returns the task writer append result, and `service/matching/task_writer.go:85-121` waits for the append response; `task_writer.go:140-150` writes through `db.CreateTasks`, which reaches persistence at `service/matching/db.go:519-573`.

The downstream duplicate/obsolete handling is explicit. Workflow `RecordWorkflowTaskStarted` treats missing/completed tasks as safe drops (`service/history/api/recordworkflowtaskstarted/api.go:69-75`), duplicate started tasks as OK to drop (`api.go:98-112`), sticky queue mismatches as obsolete with a newer task expected (`api.go:140-148`), and some deployment-transition cases as obsolete (`api.go:195-201`). Activity `RecordActivityTaskStarted` treats missing/completed activities as OK to drop (`service/history/api/recordactivitytaskstarted/api.go:131-137`), duplicate starts as OK to drop (`api.go:150-170`), stamp mismatches as obsolete (`api.go:178-183`), and activity starts during transition as safe to drop/reschedule (`api.go:198-201`, `api.go:230-247`). The service error comment for `ObsoleteMatchingTask` says Matching can safely drop it because History has already scheduled new Matching tasks on the right queue/deployment (`common/serviceerror/obsolete_matching_task.go:12-20`); `ActivityStartDuringTransition` similarly says History will reschedule after transition (`common/serviceerror/activity_start_during_transition.go:10-13`).

## Reachability challenge

Can an old executor legally advance local ACK before the downstream obligation is durable/accepted? **I find no supported production path.** The scheduler ACK happens after the executor returns nil or after `HandleErr` classifies the result as intentionally invalid/safe-to-drop. The normal `ActivityTask`/`WorkflowTask` transfer path returns the result of Matching `Add*Task`. Matching returns nil only after a successful sync match or successful backlog spool. Ordinary AddTask errors propagate back and lead to NACK/retry, not ACK.

Can ownership move mid-checkpoint? **Yes.** The repro proves the interleaving, and the source supports it: row deletion is not RangeID fenced while `SetQueueState` is RangeID fenced. The old owner can therefore delete rows and then be rejected on the shard update.

Does deleting an already ACKed row violate a contract? **No evidence found.** The queue row is the source for retrying uncompleted work. Once the transfer executor has successfully handed the obligation to Matching, persisted it in Matching backlog, or learned from History that the task is obsolete/duplicate/safe to drop, deleting the history transfer row is the expected queue completion action. If a later worker-poll / `Record*TaskStarted` path drops a task incorrectly, that would be a separate Matching/History duplicate/obsolete-classification defect, not caused by CR-4's stale-owner range delete.

## Why MASKED is not met

The original MASKED label needs both a real defect and a proven current mask. The current evidence only shows a mask-like fence on queue-state progress after an unfenced cleanup delete. It does not show a real defect hidden behind that fence, because the deleted row is already locally ACKed and the production ACK path is gated by Matching acceptance/backlog persistence or explicit safe-drop semantics.

The correct downgrade is **FALSE POSITIVE**, not NEEDS MORE INFO. The uncertain part in the original report was whether old-owner local ACK could outrun downstream durability/acceptance. The source path answers that for the transfer tasks under review: normal errors prevent ACK; success means Matching accepted or persisted; duplicate/obsolete cases are intentionally safe to drop.

## Axes

- Real-world: the stale checkpoint interleaving is real, but the harmful state is not reachable through the production transfer executor path shown here. The repro is Level-2 state injection and starts after local ACK.
- Severity: none as a bug. At most, this is a hardening/invariant concern around an intentionally unfenced cleanup operation.
- Confidence: medium-high. I reran the provided repro, traced the queue/checkpoint/persistence path, traced transfer executor to Matching AddTask, and traced Matching/History duplicate handling. I did not produce a Level-0 public API reproduction because the existing repro already reports Level 0/1 not triggered and the source path explains why.
- Maintainer-fix likelihood: low as a correctness bug. A maintainer might accept a defensive RangeID fence on range delete if cheap, but the current delete-before-state ordering is explicitly documented in code and looks intentional for completed tasks.

## Logs produced

- `logs/git-clone.log`
- `logs/git-fetch-origin.log`
- `logs/source-head.txt`
- `logs/upstream-main-ls-remote.txt`
- `logs/origin-main-local.txt`
- `logs/github-search-exact.txt`
- `logs/original-repro-rerun.log`
- `logs/original-repro-rerun.exit`
- `logs/queue-persistence-snippets.txt`
- `logs/executable-path-snippets.txt`
- `logs/common-scheduler-ack-snippets.txt`
- `logs/transfer-executor-snippets.txt`
- `logs/matching-addtask-snippets.txt`
- `logs/matching-snippets.txt`
- `logs/history-record-start-snippets.txt`
- `logs/current-main-relevant-diff.patch`
