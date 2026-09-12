# CR-3 Investigation

## Scope

- Source repo: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/confirmation/CR-3/worktree`
- Revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`
- Finding source: Code Review. No model-checking counterexample was provided for this finding.
- Boundary respected: did not read spec files, `bug-report.md`, `confirmed-bugs.md`, other finding dirs, or the shared repair-request queue.

## Step 1: Code Audit

Relevant pinned source:

- `service/history/queues/queue_base.go:295`: `checkpoint()` first shrinks reader slices, then computes `newExclusiveDeletionHighWatermark` from `nonReadableScope.Range.InclusiveMin` and the first scope of each reader.
- `service/history/queues/queue_base.go:340`: inline intent says range-complete must happen before queue-state update; otherwise an updated state plus failed deletion/reload could leave tasks undeleted.
- `service/history/queues/queue_base.go:351-360`: `checkpoint()` calls `rangeCompleteTasks(old, new)`, returns immediately on error, advances only the in-memory `exclusiveDeletionHighWatermark` on success, then calls `updateQueueState`.
- `service/history/queues/queue_base.go:373-395`: `rangeCompleteTasks()` calls `ExecutionManager.RangeCompleteHistoryTasks` for the shard/category/range.
- `service/history/queues/queue_base.go:397-417`: `updateQueueState()` converts reader scopes plus `nonReadableScope.Range.InclusiveMin` to persistence and calls `ShardContext.SetQueueState`.
- `service/history/shard/context_impl.go:376-385`: `SetQueueState()` updates `s.shardInfo.QueueStates[category]` via `updateShardInfo`.
- `service/history/shard/context_impl.go:1228-1250`: `updateShardInfo()` mutates in-memory shard info before the min-interval/min-task batching check; if too early and too few tasks completed, it returns nil without persisting.
- `service/history/shard/context_impl.go:1252-1299`: when persistence is attempted, `UpdateShard` is issued after copying the updated shard info. On error, timing counters are reverted and `handleWriteErrorLocked` is used.
- `service/history/queues/queue_base.go:119-133` and `:178-192`: on queue construction/reload, durable queue state is converted back into reader scopes, `nonReadableScope` starts at the durable exclusive reader high watermark, and `exclusiveDeletionHighWatermark` is lowered to the minimum first reader-scope start. A lagging durable queue state therefore widens the reload read/delete range rather than advancing past it.
- `common/persistence/sql/execution_tasks.go:305-345`: SQL transfer-task reads select rows in `[InclusiveMinTaskID, ExclusiveMaxTaskID)`.
- `common/persistence/sql/execution_tasks.go:361-373`: SQL transfer-task range completion deletes rows in `[InclusiveMinTaskID, ExclusiveMaxTaskID)`.

Reachable call chain:

- Normal history queue processing reaches `immediateQueue.processEventLoop()` (`queue_immediate.go:132-159`) through checkpoint timer, new-task notification/poll, or alert handling.
- The checkpoint path is also reachable from `queueBase.handleAlert()` (`queue_base.go:433-444`).
- Task publication and reading use normal persistence APIs: `ContextImpl.GetHistoryTasks()` (`context_impl.go:526-535`) delegates to the execution manager; transfer-task SQL persistence reads/deletes the same durable table.

Constructed trigger schedules:

- Healthy control: completed task 1, unfinished task 2; checkpoint range-completes `[1,2)`, persists durable high watermark 2, reload reads task 2 from `[2,3)`.
- Lost delete reply: range-complete `[1,2)` is executed by the store but returns `TimeoutError` through fault injection; checkpoint returns before queue-state update, durable high watermark remains 1, reload reads task 2 from `[1,3)`.
- Batched state lag: a prior shard update primes `lastUpdated`; checkpoint range-completes `[1,2)`, mutates local queue state to high watermark 2, but `updateShardInfo` takes the too-early batching branch and durable high watermark remains 1. Reload reads task 2 from `[1,3)`.
- Queue-state persistence failure after delete: range-complete `[1,2)` succeeds, then `UpdateShard` returns an injected timeout from the queue-state update path. The in-memory deletion watermark advances to 2, durable high watermark remains 1, and reload reads task 2 from `[1,3)`.

Safeguards / compensation recorded:

- Delete-before-state ordering prevents durable queue-state advancement when delete definitely fails.
- Lost-reply/timeout after a committed delete leaves durable queue state behind, not ahead.
- Reload derives the deletion watermark from durable queue state and reader scope minima, so the next owner retries a prefix delete from the older boundary.
- SQL range deletion is idempotent for already-deleted rows and does not delete the unfinished row at the exclusive max boundary.

## Step 2: Developer-Knowledge Search

Comments / intent:

- `queue_base.go:340-342` explicitly records the intended safety condition: range-complete before state update prevents a reload state where tasks are never deleted.
- `context_impl.go:1245-1249` documents batching: when `ShardUpdateMinTasksCompleted` is 0, persistence depends on elapsed time; too-early updates return nil.

Blame / commits:

- `cb2139cefb6cda5e1a0a44dae70a0c644f8d6459` edited the queue checkpoint comments in PR `#4946` ("Edit comments").
- `9c0e74647a0a9555c30d8677d2f127c0878b1abb` / PR `#5399` introduced task-count/time-based shard-info update batching. Commit message says shard info updates can be costly and this persists only after enough completed tasks or time has passed.
- `b87fb75035314187a69f6bee44aeafe8b6213774` / PR `#8416` improved multi-cursor actions, including moving task groups so reload behavior is better isolated.
- Recent local git history since 2026-08-01 on the implicated files showed observability and adjacent task changes (`#11695`, `#11411`, etc.) but no same-mechanism fix for delete/state divergence.

Existing tests:

- Upstream `queue_base_test.go` verifies checkpoint ordering for pending/no-pending task cases and asserts `RangeCompleteHistoryTasks` before `UpdateShard` in several queue states.
- The reproduction below adds a focused SQLite-backed recovery test for the split operations.

## Step 3: Known Status / Precedent

Prior-report search performed:

- `gh search issues --repo temporalio/temporal 'RangeCompleteHistoryTasks queue state checkpoint' --state open/closed`: `[]`.
- `gh search issues --repo temporalio/temporal '"Must range-complete task first"' --state open/closed`: `[]`.
- `gh search prs --repo temporalio/temporal 'RangeCompleteHistoryTasks queue state checkpoint' --state open/closed`: `[]`.
- `gh search prs --repo temporalio/temporal '"Must range-complete task first"' --state open/closed`: `[]`.
- Broader `queue state range complete delete checkpoint` issue/PR searches returned `[]`.
- Later broader GitHub API searches hit a rate limit, but the exact-site issue and PR searches above completed.
- Local `git log --all --grep` for `queue state`, `RangeCompleteHistoryTasks`, `range complete`, `checkpoint`, `delete.*task`, and `shard update` found related implementation/history PRs but no already-filed same-mechanism bug report.

Known-status result:

- No public issue/PR/CVE/advisory or local git-history evidence was found reporting this exact mechanism at this site.
- Novelty for dispatcher header: `NEW`.
