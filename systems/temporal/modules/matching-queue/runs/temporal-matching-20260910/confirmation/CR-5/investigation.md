# CR-5 investigation

Finding: CR-5, "Fairness eviction during unlocked replacement"

Source: Code Review. No model-checking counterexample/config was supplied for this finding.

Target revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025` in the supplied worktree. The worktree was already dirty before this confirmation run with Specula tracing/diagnostic files and matching/persistence instrumentation.

## Step 1: Code audit

Relevant sites:

- `service/matching/fair_task_reader.go:153-182`: `completeTask` takes `tr.lock`, verifies `outstandingTasks` contains the completed task and that the entry is a live task, handles nil-error completions under the lock, then unlocks before non-transient replacement I/O.
- `service/matching/fair_task_reader.go:201-209`: for other errors, `completeTask` calls `tr.backlogMgr.respoolTaskAfterError(task.event.Data)` with the reader lock dropped; after successful re-spool it reacquires the lock and calls `completeTaskLocked(task)` without rechecking that the task is still tracked.
- `service/matching/fair_task_reader.go:212-219`: `completeTaskLocked` replaces the task's fair level with an ack marker, decrements `loadedTasks`, advances the ack level, and possibly starts another read.
- `service/matching/fair_task_reader.go:511-527`: `mergeTasksLocked` trims overflow from the level-ordered outstanding set. If a live task is chopped, it decrements `loadedTasks` and calls `task.setEvicted()`. If an ack is chopped, it stores that level in `evictedAcks`.
- `service/matching/fair_task_reader.go:607-635`: `advanceAckLevelLocked` is disabled while writer/newly-written-task pinning is active; otherwise it pops leading ack markers and persists the new fair ack level via `db.updateFairAckLevel`.
- `service/matching/fair_task_writer.go:214-222`: the writer pins fair ack levels, writes the batch through `CreateFairTasks`, calls `wroteNewTasks` before unpinning, then unpins in a defer.
- `service/matching/db.go:613-688`: `CreateFairTasks` persists V2 fair tasks with `(TaskPass, TaskId)` ordering and advances per-subqueue `FairMaxReadLevel`.
- `service/matching/db.go:731-748`: `GetFairTasks` reads from an inclusive fair level and uses limit ordering by pass/task id.
- `service/matching/db.go:781-810`: `CompleteFairTasksLessThan` deletes tasks below an exclusive fair level.

Call chain / reachability:

- Public matching APIs `AddWorkflowTask` and `AddActivityTask` build `persistencespb.TaskInfo` and call `pm.AddTask` (`service/matching/matching_engine.go:586-643`, `645-694`).
- With `matching.useNewMatcher=true` and fairness enabled for a fairness-capable partition, `fairBacklogManagerImpl.SpoolTask` persists through the fair writer (`service/matching/fair_backlog_manager.go:236-240`).
- The fair reader loads persisted backlog rows and gives them to the physical matcher through `addTaskToMatcher` (`service/matching/fair_task_reader.go:285-315`, `320-337`).
- Polling workers receive matched backlog tasks through `PollWorkflowTaskQueue` / `PollActivityTaskQueue`. If `RecordWorkflowTaskStarted` or `RecordActivityTaskStarted` returns a retryable/non-drop error such as namespace-level `ResourceExhausted`, matching calls `task.finish(taskFinishResult{err: err})` (`service/matching/matching_engine.go:808-875`; analogous activity path at `matching_engine.go:1037-1120`). That invokes the backlog completion callback (`service/matching/task.go:388-400`), reaching `fairTaskReader.completeTask`.

Constructed trigger scenario:

1. Fairness reader has accepted and loaded tasks `A`, `B`, `C`, where `B` and `C` are still eligible backlog records.
2. A poller takes `C`; History rejects start with non-BUSY namespace `ResourceExhausted`. The matching engine calls `task.finish(...err...)`. `fairTaskReader.completeTask` verifies `C` is in `outstandingTasks`, drops `tr.lock`, and enters `respoolTaskAfterError`.
3. While `C` is paused in the unlocked replacement window, fresh tasks with lower fair levels are accepted and written. `mergeTasksLocked` trims the standing backlog to `GetTasksBatchSize`, evicting first `C` and then `B` as live tasks.
4. `B` later finishes with an error after eviction; because `B` is no longer in `outstandingTasks`, `completeTask` returns without acking it.
5. The replacement write for `C` succeeds. The old `C` completion resumes and calls `completeTaskLocked(C)` without rechecking membership, inserting an ack for the old `C` level after `B` has vanished from the in-memory outstanding set.
6. Completing the remaining lower-level tasks lets `advanceAckLevelLocked` advance/persist the fair ack level to old `C`, crossing `B`. A restart-style fair read from persisted ack+1 does not return `B`, although `B` remains an eligible row in the store.

Safeguards found:

- Missing completions normally do not ack; the code comments say they will be re-read and then treated as duplicate by History (`fair_task_reader.go:158-164`).
- Ack markers evicted during trimming are cached in `evictedAcks` (`fair_task_reader.go:48-52`, `524-526`), and re-read tasks with a cached ack are inserted pre-acked rather than delivered (`fair_task_reader.go:465-469`).
- The above safeguards do not cover the audited replacement path because the old `C` completion inserts an ack only after the live `C` entry was evicted; `B` was evicted as a live task, not an ack, so no `evictedAcks` entry exists for `B`.

## Step 2: Developer-knowledge search

Code comments near `completeTask` explicitly acknowledge a race where a completed task may be missing from `outstandingTasks`; the intended handling is to not ack it and eventually read it again as a duplicate (`service/matching/fair_task_reader.go:158-164`).

Developer history found several related but not identical fixes:

- PR #8093, "Fix race with evicted fair task", merged 2025-07-24, describes a rare race where a fair-reader in-memory task is evicted before it is added to the matcher. This is adjacent eviction handling, not the non-transient History-error replacement path after membership was already checked.
- PR #9234, "Add evicted ack cache to fairTaskReader", merged 2026-02-06, adds a cache for evicted acks to avoid reprocessing tasks.
- PR #10851, "Fix evicted ack cache handling", merged 2026-06-26, treats tasks matching evicted acks like expired tasks so ack level can move past them.
- PR #10814/#10835, "Detect and mitigate stuck fair task reader on write path", merged 2026-06-24/25, describe production stuck fair readers with root cause still under investigation. The described state is no loaded tasks plus no read in progress; it does not report old replacement completions crossing an evicted live task.
- PR #11048, "Fix read level update in fair task reader", merged 2026-07-24, fixes a write/read race involving already-acked tasks and read-level collapse; it is adjacent to ack eviction but not the same replacement/respool completion mechanism.
- PR #11580, open as of this run, suppresses a `fair reader stuck` assertion during unload after lost ownership; not the same mechanism.

Tests found:

- `service/matching/backlog_manager_test.go:1245-1334` tests a write/read race where a completed write is re-merged, preserving read level and avoiding stuck fair reader state. It does not exercise non-transient start failure, `respoolTaskAfterError`, or completion after eviction.
- `service/matching/specula_fair_diagnostic_test.go` in the supplied dirty worktree is a Specula diagnostic for a late fair completion against SQLite V2 persistence. It uses existing tracing hooks and controlled matcher/History interfaces.

## Step 3: Known-status / precedent

Searches performed:

- GitHub issues, open and closed: `fairTaskReader respool`, `evicted fair task ack`, `respoolTaskAfterError`, `completeTaskLocked fairTaskReader`.
- GitHub PRs, open and closed/merged: `fairTaskReader respool`, `evicted fair task ack`, `loadedTasks went negative`, `TaskCompletedMissing fair`, `fair reader stuck`, `respoolTaskAfterError`, `completeTaskLocked fairTaskReader`.
- Local git history for `service/matching/fair_task_reader.go`, `fair_task_writer.go`, `fair_backlog_manager.go`, and `db.go`, including post-2026-09-01 changes and grep for `fair.*respool`, `evict.*replacement`, and `completeTaskLocked`.

Result: no issue, merged/closed PR, CVE/advisory, or visible tracker entry found that reports this exact same mechanism at this same site: non-transient History-start failure, unlocked fair replacement/re-spool, intervening merge trimming of live tasks, and later ack crossing an evicted eligible task. The finding proceeds to Phase 2 as novelty `NEW`.
