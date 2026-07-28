# CR-3 Investigation

Date checked: Tuesday, July 21, 2026.

## Step 1: Code audit

### Relevant code

- `slatedb/src/compactor.rs:790-851`
  - `reclaim_stale_workers()` resets stale `Running` compactions to `Scheduled` and clears `worker`.
- `slatedb/src/compaction_worker.rs:314-458`
  - `poll_and_claim()` treats a reclaimed `Scheduled` entry that this worker still tracks in `job_progress` as a duplicate local execution, calls `stop_compaction_job()`, and returns without re-dispatching in the same poll.
- `slatedb/src/compaction_worker.rs:480-490`
  - `record_progress()` accepts progress only if `job_progress` still contains the compaction id.
- `slatedb/src/compaction_worker.rs:687-769`
  - `write_compacted()` fences only on `worker_id` equality, not on a per-claim generation.
- `slatedb/src/compaction_worker.rs:780-787`
  - `stop_compaction_job()` asks the executor to stop and immediately removes the compaction from `job_progress`.
- `slatedb/src/compaction_worker.rs:827-842`
  - `handle_finished()` removes `job_progress` first, then processes the completion.
- `slatedb/src/compactor_executor.rs:886-956`
  - `TokioCompactionExecutorInner::start_compaction_job()` registers active jobs in `tasks` by compaction id and sends `WorkerMessage::CompactionJobFinished` only from the task-cleanup closure if the task still removes itself from `tasks`.
  - `TokioCompactionExecutorInner::stop_compaction_job()` removes the task from `tasks` before aborting it.

### Call chain

Normal reclaim/re-claim path:

1. Coordinator tick calls `reclaim_stale_workers()` from `CompactorEventHandler::handle_ticker()` (`slatedb/src/compactor.rs:773-851`).
2. Worker poll tick calls `poll_and_claim()` (`slatedb/src/compaction_worker.rs:314`).
3. If the worker still has local bookkeeping for the reclaimed compaction id, `poll_and_claim()` stops the local job and clears `job_progress` instead of re-dispatching immediately (`slatedb/src/compaction_worker.rs:338-365`).
4. A later poll may re-claim the same durable compaction id and dispatch a new executor job (`slatedb/src/compaction_worker.rs:381-458`).
5. Executor progress/completion reaches the worker only through `WorkerMessage::CompactionJobProgress` / `WorkerMessage::CompactionJobFinished` (`slatedb/src/compaction_worker.rs:91-106`, `slatedb/src/compactor_executor.rs:903-920`).

### Reachability

The durable reclaim and later same-worker re-claim are reachable through normal protocol steps:

1. Worker claims compaction `A`.
2. Coordinator times out the worker heartbeat and reclaims `A` back to `Scheduled`.
3. The same worker sees `A` as `Scheduled` while it still tracks the old local execution, so `poll_and_claim()` stops the local executor task and clears `job_progress`.
4. On a later poll, the same worker can re-claim `A`.

The disputed step is later stale completion from the old attempt after step 4. In the current code, the only producer of `CompactionJobFinished` is the executor cleanup callback in `TokioCompactionExecutorInner::start_compaction_job()` (`slatedb/src/compactor_executor.rs:899-920`). That callback sends completion only if it successfully removes the task from `tasks`. But `stop_compaction_job()` removes the task from `tasks` before aborting it (`slatedb/src/compactor_executor.rs:942-956`), so a stopped attempt's cleanup closure sees `removed == false` and returns without sending completion.

### Safeguards observed

- Worker-side duplicate suppression on reclaim:
  - `poll_and_claim()` stops the old local execution and does not re-dispatch the same compaction in that poll (`slatedb/src/compaction_worker.rs:338-365`).
- Worker-side lost-ownership stop:
  - `heartbeat_owned_jobs()` stops jobs that are missing or owned by another worker (`slatedb/src/compaction_worker.rs:573-673`).
- Executor-side completion suppression:
  - `stop_compaction_job()` removes the task from `tasks` before aborting it, and the completion callback sends `CompactionJobFinished` only if it removed the task itself (`slatedb/src/compactor_executor.rs:899-956`).
- Existing executor test covering that safeguard:
  - `should_stop_single_compaction_job_without_stopping_executor()` asserts that a stopped job never reports completion and a later job on the same destination succeeds (`slatedb/src/compactor_executor.rs:2461-2585`).

### Trigger scenario

Concrete scenario to evaluate in reproduction:

1. Start compaction attempt `A1`.
2. Reclaim `A` to `Scheduled`.
3. Let the worker stop `A1` through `poll_and_claim()`.
4. Re-claim `A` as `A2`.
5. Check whether `A1` can still deliver `CompactionJobFinished` after step 4 and clear `A2` from `job_progress`.
6. If step 5 is impossible, the claimed stale-finish consequence cannot occur from the real runtime path.

## Step 2: Developer-knowledge search

### Issue tracker / PRs

- Issue `#1850`, opened June 26, 2026:
  - <https://github.com/slatedb/slatedb/issues/1850>
  - Reports the earlier same-worker reclaim bug where the worker could dispatch a duplicate local execution and panic in `compactor_executor.rs` because the destination was already active.
- PR `#1856`, merged June 28, 2026:
  - <https://github.com/slatedb/slatedb/pull/1856>
  - Introduced the worker-side "stop the local job if it is reclaimed" behavior that now lives in `poll_and_claim()` / `stop_compaction_job()`.
- PR `#1884`, merged July 7, 2026:
  - <https://github.com/slatedb/slatedb/pull/1884>
  - Moved worker progress publication to heartbeat-only buffering and left `record_progress()` keyed by compaction id in `job_progress`.

These reports are directly adjacent, but they describe:

- duplicate dispatch / panic before the worker stop path existed (`#1850` / `#1856`), and
- progress-publication refactoring (`#1884`),

not a post-`#1856` stale completion from a stopped attempt after the same worker re-claims the compaction.

### Git history / blame

- Commit `da14c593` (`Stop executing compaction job if it's no longer owned`, merged June 28, 2026):
  - added the duplicate-stop logic and `stop_compaction_job()` in `slatedb/src/compaction_worker.rs`.
- Commit `35162cc3` (`collapse active_jobs into job_progress`, merged June 29, 2026):
  - made `job_progress` the sole local active-job bookkeeping in `CompactionWorkerHandler`.
- Commit `64c7b30b` (`Remove useless last_hb_ms from CompactionWorker`, merged July 2, 2026):
  - preserved the stop-and-clear pattern.
- Commit `297b6a17` (`Disable CompactorWorker .compaction writes on SST progress`, merged July 7, 2026):
  - kept progress buffering keyed only by compaction id.

Blame on the exact lines shows:

- `poll_and_claim()` duplicate-stop branch was added by `da14c593` / adjusted by `35162cc3`.
- `stop_compaction_job()` removing `job_progress` immediately comes from `da14c593`.
- `handle_finished()` removing `job_progress` before processing completion predates the reclaim fix.
- `record_progress()`'s current `job_progress` gate was introduced by `297b6a17`.

### Comments / docs / tests

- `slatedb/src/compaction_worker.rs:343-344` explicitly states the worker should only re-claim on a later poll after local bookkeeping has been cleared.
- `slatedb/src/compactor_executor.rs:903-911` documents the intended fence:
  - if the task was already removed, do not send a completion message.
- Existing tests cover:
  - worker stopping a reclaimed active job on poll (`test_worker_stops_rescheduled_job_already_active_locally_on_poll`);
  - worker stopping a lost-ownership job on heartbeat (`test_worker_stops_active_job_when_heartbeat_loses_ownership`);
  - executor suppression of completion after cancellation (`should_stop_single_compaction_job_without_stopping_executor`).

I did not find an existing test asserting the exact code-review claim that a stopped old attempt can still emit `CompactionJobFinished` after the same worker has re-claimed the same compaction id.

## Step 3: Known-status / precedent

### Prior-report search performed

Searched:

- Upstream issue tracker / PRs for reclaim, heartbeat, duplicate dispatch, and progress publication:
  - `#1850`, `#1856`, `#1884`
- Local git history / blame for:
  - `slatedb/src/compaction_worker.rs`
  - `slatedb/src/compactor.rs`
  - `slatedb/src/compactor_executor.rs`

### Result

I found prior public reports for:

- the earlier duplicate-dispatch panic before the worker stop path (`#1850` / `#1856`), and
- the later progress-publication refactor (`#1884`).

I did not find an existing issue or PR that reports this exact post-`#1856` mechanism:

- old attempt is stopped on reclaim,
- same worker later re-claims the same compaction id,
- the stopped old attempt still emits `CompactionJobFinished`,
- that stale finish clears the new attempt's local capacity bookkeeping.

Known-status conclusion for Phase 2: `Novelty: NEW`.
