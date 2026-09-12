# CR-4 Investigation

Finding: CR-4, "An old owner can finish effects after durable ownership changes"
Source: Code Review
Repository: temporalio/temporal
Revision checked: 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025

## Step 1: Code Audit

Relevant sites in the clean `HEAD` source:

- `service/history/queues/executable.go:273`: `Executable.Execute` only checks the in-memory executable state before invoking the executor.
- `service/history/queues/executable.go:402`: the executor is called with no direct shard-ownership recheck at the executable layer.
- `service/history/queues/executable.go:742`: `Ack` marks only the local executable state.
- `service/history/queues/tracker.go:85`: `shrink` removes acked executables from the slice and returns the new minimum pending task key.
- `service/history/queues/slice.go:320`: `shrinkRange` advances the slice range to the min pending task or iterator position.
- `service/history/queues/queue_base.go:295`: `checkpoint` shrinks slices and prepares reader scopes.
- `service/history/queues/queue_base.go:340`: checkpoint explicitly range-completes task rows before persisting queue state.
- `service/history/queues/queue_base.go:373`: `rangeCompleteTasks` calls `ExecutionManager.RangeCompleteHistoryTasks`.
- `service/history/queues/queue_base.go:397`: `updateQueueState` persists queue state via `ShardContext.SetQueueState`.
- `common/persistence/sql/execution_tasks.go:17`: `AddHistoryTasks` is RangeID-fenced through `txExecuteShardLocked`.
- `common/persistence/sql/execution_tasks.go:66`: `RangeCompleteHistoryTasks` has no request RangeID.
- `common/persistence/sql/execution_tasks.go:361`: SQL transfer range completion deletes by `shard_id` and `task_id` range only.
- `common/persistence/sql/sqlplugin/postgresql/execution.go:626` and `common/persistence/sql/sqlplugin/sqlite/execution.go:624`: the concrete range delete statement is `DELETE FROM transfer_tasks WHERE shard_id = ? AND task_id >= ? AND task_id < ?` or PostgreSQL equivalent, with no RangeID predicate.
- `common/persistence/sql/shard.go:82`: `UpdateShard` locks the shard row and checks `PreviousRangeID`.
- `common/persistence/sql/shard.go:152`: `readLockShard` returns `ShardOwnershipLostError` if the stored range does not match the request range.
- `service/history/shard/context_impl.go:376`: `SetQueueState` calls `updateShardInfo`.
- `service/history/shard/context_impl.go:1228`: `updateShardInfo` requires acquired state, snapshots shard info, then persists through `UpdateShard` with the previous RangeID.
- `service/history/shard/context_impl.go:1512`: `handleWriteErrorLocked` treats `ShardOwnershipLostError` as a stop signal.
- `service/history/api/consistency_checker.go:201`: History APIs compare request vector clocks and unload the shard on a future clock.

Call chain and reachability:

- Normal workflow transactions publish transfer tasks through `ContextImpl.AddTasks` / workflow mutation paths, which use `request.RangeID = s.getRangeIDLocked()` and SQL's shard lock. These writes are ownership-fenced.
- Immediate queue readers load rows through `immediateQueue.paginationFnProvider` -> `ShardContext.GetHistoryTasks` -> `ExecutionManager.GetHistoryTasks`. A reader can hold already-loaded executables while durable shard ownership later changes.
- Executables call the transfer executor. For activity/workflow transfer tasks, the executor validates mutable state and then releases the workflow lock before calling Matching. Matching later calls `RecordActivityTaskStarted` / `RecordWorkflowTaskStarted`, whose History-side implementation performs clock and mutable-state checks and drops duplicate/stale starts (`ErrActivityTaskNotFound`, `TaskAlreadyStarted`, `ObsoleteMatchingTask`).
- Checkpoint completion removes only locally acked executables. It then deletes the corresponding durable task-row prefix before trying to persist the queue state. If another owner already advanced the shard RangeID, the queue-state update is rejected, but the prior range delete is not RangeID-fenced.

Concrete trigger scenario to test:

1. Owner A owns shard `S` at RangeID `1` and loads transfer task id `10`.
2. Owner B acquires shard `S` and advances the durable shard RangeID to `2`.
3. Owner A's already-loaded executable completes successfully and is locally acked.
4. Owner A runs checkpoint: it range-deletes `[1, 11)` from transfer tasks, then attempts `SetQueueState`.
5. The expected fence is that owner A cannot persist queue state at RangeID `1`. The open question is whether the unfenced delete can remove a row that the new owner still needs.

Safeguards / contracts found:

- Shard metadata writes are RangeID-fenced by `UpdateShard`.
- A stale History API request with a future vector clock causes unload through `clockConsistencyCheck`.
- Matching delivery is at-least-once: duplicate/stale activity and workflow tasks are rejected or dropped by History start APIs.
- Queue row deletion follows a local `Ack`; for the transfer executor, ack is only reached after `Execute` / `HandleErr` returns nil.

## Step 2: Developer Knowledge Search

Source comments and tests:

- `queue_base.go:340-342` states that range completion must happen before state update because updating state first and then failing deletion can leave tasks never deleted.
- `recordactivitytaskstarted/api.go:131-136` documents that a missing activity info after start is considered a duplicate and safe to drop.
- `recordworkflowtaskstarted/api.go:69-74` and `:98-111` document missing/already-started workflow tasks as safe to drop.
- Existing `queue_base_test.go` asserts the checkpoint order: `RangeCompleteHistoryTasks` then `UpdateShard`.
- Existing `queue_immediate_test.go:75` verifies a shard-ownership-lost read invalidates the shard.

Git history:

- `git log --all --grep='RangeComplete|ownership|queue state|QueueState|transfer task|history queue|RangeID|stale'` found adjacent but non-duplicate changes. Notably PR #7101 (`72fa968c5`, "Handle shard ownership lost when reading history tasks") says task processing could get stuck on ownership-lost reads and that other execution-manager usages still needed audit. This is adjacent developer awareness, not a filed report of stale owner range deletion after a newer RangeID.
- `git blame` on `queue_base.go:340-351` points the "delete before state" comment to PR #4946/comment edits and the range-completion logic to older queue checkpoint work. No commit message found reporting CR-4's exact stale-owner mechanism.

Issue / PR tracker novelty search:

- `gh search issues --repo temporalio/temporal "old owner durable ownership RangeID queue" --limit 20`: no results.
- `gh search issues --repo temporalio/temporal "RangeCompleteHistoryTasks RangeID" --limit 20`: no results.
- `gh search prs --repo temporalio/temporal "RangeCompleteHistoryTasks RangeID" --limit 20`: no results.
- `gh search prs --repo temporalio/temporal "queue ownership stale transfer task" --limit 20`: no results.
- `gh search issues --repo temporalio/temporal "range delete transfer task ownership" --limit 20`: no results.
- `gh search issues --repo temporalio/temporal "stale owner transfer task queue state" --limit 20`: no results.
- `gh search prs --repo temporalio/temporal "range delete transfer task ownership" --limit 20`: no results.
- `gh search prs --repo temporalio/temporal "stale owner transfer task queue state" --limit 20`: no results.
- Recent closed/merged sweep since 2026-09-01:
  - `gh search prs --repo temporalio/temporal --merged --updated ">=2026-09-01" "RangeCompleteHistoryTasks" --limit 20`: no results.
  - `gh search prs --repo temporalio/temporal --merged --updated ">=2026-09-01" "queue state RangeID" --limit 20`: no results.
  - `gh search prs --repo temporalio/temporal --merged --updated ">=2026-09-01" "history queue ownership" --limit 20`: no results.
  - `gh search prs --repo temporalio/temporal --state closed --updated ">=2026-09-01" "transfer task queue state ownership" --limit 20`: no results.
  - `gh search issues --repo temporalio/temporal --state closed --updated ">=2026-09-01" "history queue ownership" --limit 20`: no results.

Known status:

- No public issue/PR found that reports the exact same stale-owner range-delete / queue-state boundary mechanism. Proceed to Phase 2; do not drop as a duplicate.

## Step 3: Phase 2 Question

Phase 2 will execute a self-contained repro attempt that:

- exercises Level 0 and Level 1 as documentation-only attempts because forcing a shard steal in the full server at the exact post-load/pre-checkpoint window was not available through a stable public API in this checkout;
- performs a Level 2 state-injection reproduction using a clean detached worktree and a package-level Go test;
- uses the real queue checkpoint code for ordering and the real SQL persistence code for task range deletion / shard RangeID fencing;
- observes whether owner A's stale checkpoint can delete transfer task rows after owner B advances RangeID, and whether the new owner can still read the row.
