# Confirmation Report — temporal-history-queue

## Final Result

Reproduced bugs: 1 = 1 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 2
Dropped: 1
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 5
Dispositions: 5 total = 1 reproduced + 0 env-limited + 1 masked + 2 false-positive + 0 needs-more-info + 1 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | CR-1 | FALSE POSITIVE | no |
| 2 | CR-2 | REPRODUCED | yes |
| 3 | CR-3 | FALSE POSITIVE | no |
| 4 | CR-4 | MASKED | no |
| 5 | CR-5 | DROPPED | no |

## Entry 1: Uncertain publication versus read eligibility

- **Finding ID**: CR-1
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/shard/task_key_manager.go:88

## Description
CR-1 claimed that an uncertain or delayed workflow/task publication could later insert required transfer work below a queue read boundary that had already advanced. I did not confirm that mechanism. The pending-key tracker holds the read watermark at the earliest uncertain key, RangeID renewal drains/clears only after the new shard RangeID is persisted, and the SQLite interleaving that would be needed for “old transaction inserts after new RangeID” is rejected by SQLite snapshot/write semantics.

## Trigger scenario
Attempted schedule: old owner allocates transfer task key under RangeID 1; write becomes uncertain or delayed; queue/new owner advances read eligibility via shard reacquire; old write later attempts to publish below the advanced boundary. Level 0 and Level 1 did not trigger harm. Level 2 directly tested the old SQLite transaction versus fresh RangeID interleaving.

## Developer intent
Original commits #4952/#5008 introduced the tracker specifically so uncertain persistence outcomes remain pending. The code comments at `task_request_tracker.go:73-85` state that pending keys are removed only for definitive success or definitive non-commit. GitHub issue/PR searches for this exact mechanism returned no known report, including `taskRequestTracker`, `pendingTaskKeys`, `GetQueueExclusiveHighReadWatermark`, and history-queue high-watermark terms: https://api.github.com/search/issues?q=repo:temporalio/temporal+taskRequestTracker+OR+pendingTaskKeys+OR+GetQueueExclusiveHighReadWatermark+state:all

## Reproduction result
Executed:

```text
timeout 20m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/repro/test_bugCR-1_publication_read_boundary.sh
```

Selected real output:

```text
CR-1 reproduction attempt: uncertain publication versus read eligibility
source_revision=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025

Level 0: ordinary shard task-key guard tests
--- PASS: TestTaskKeyManagerSuite/TestSetAndTrackTaskKeys (0.00s)
--- PASS: TestTaskRequestTrackerSuite/TestRequestCompletion (0.00s)
PASS

Level 1: existing SQLite fault-injection publication evidence, if present
publication_persistence_evidence_test.go:92: injected fault: fault injection error at AddHistoryTasks with 1.00 rate: persistence.TimeoutError
publication_persistence_evidence_test.go:107: late writer fenced: Failed to lock shard. Previous range ID: 1; new range ID: 2
publication_persistence_evidence_test.go:117: late checkpoint fenced: Failed to update shard. Previous range ID: 1; new range ID: 2
publication_persistence_evidence_test.go:137: ... recovered task IDs=[8,9]; late ID=10 absent; RangeID=2; allocator high=16
PASS

Level 2: direct SQLite interleaving for old read transaction versus fresh RangeID
old_tx_read_range=1
new_owner_committed_range=2 after_reading_range=1
old_tx_late_insert_error=*sqlite.Error: database is locked (517)
final_range=2 transfer_rows=0 min_task_valid=false min_task=0
late_publication_below_renewed_range=false
sqlite_snapshot_or_range_fence_blocked_old_writer=true

Level 2b: queue cursor/reload recovery probe, if present
queue_base_recovery_sqlite_test.go:323: fault=true batch=100 submitted=100 cursor_nil=true surviving_row=502 memory_delete=502 repeated_checkpoint_poll_notify=3 persistence_reads=1
queue_base_recovery_sqlite_test.go:361: managers_reconstructed=true independent_connection_read=true durable_reader=1 durable_min=502 reload_submitted=101 later_task=502 post_ack_checkpoint_rows=0
PASS

Level 2c: transfer executor and Matching acceptance/reload probe, if present
hq_scenarios_test.go:355: CR-1 real_executor=true injected_checkpoint_before_cursor_advance=true matching_acceptances=2 eligible_workflow=hq-cursor_stall-3 retained_row=1048598 durable_reader1_scope=true cursor_nil=true poll_checkpoint_notify_rounds=3
hq_scenarios_test.go:399: CR-1 fresh_acquire=true real_executor_after_reload=true matching_acceptances=3
PASS

Level 3: no source patch applied
A source patch that permits an old transaction to commit after a newer RangeID would alter SQLite/persistence semantics rather than widen a real timing window.

CR-1 result: publication-below-read-boundary trigger not reproduced; safeguards blocked or recovered the tested schedules.
```

## Recommendation
Do not report CR-1 as a live bug. Keep or upstream a focused regression test for SQLite old-transaction/new-RangeID fencing and the queue reload recovery case, because those tests capture the subtle guarantee better than source review alone.

---

## Entry 2: Logical scope survives but the live reader cursor disappears

- **Finding ID**: CR-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `service/history/queues/reader.go:359`

## Description
`ReaderImpl.ShrinkSlices()` removes empty slice list elements but does not repair `nextReadSlice`. If the cursor points at the slice that checkpoint shrink removes, the next read advances from a detached `container/list.Element` to nil, while later live slices still contain readable work.

## Trigger scenario
A reader loads a full batch from slice A, leaving `MoreTasks()` true because the iterator object still exists. The submitted task is ACKed, then checkpoint shrink removes slice A before the next read. Slice B remains in the reader and has work, but the live cursor is detached, so `Notify()` and later reads do not submit slice B’s task.

## Developer intent
Searched upstream issues/PRs and recent merged/closed PRs for `nextReadSlice`, `ShrinkSlices`, `MoreTasks`, queue reader stuck, and queue-state resolution loss. No exact report/fix found. Adjacent PRs were not duplicates: #11554 changes stuck-reader metrics, and #11695 is metrics/observability only.

## Reproduction result
Repro file executed:
`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/repro/test_bugCR-2_reader_cursor_stall.sh`

Command:
```text
timeout 12m bash .../.specula-output/repro/test_bugCR-2_reader_cursor_stall.sh
```

Output:
```text
source_head=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
preflight=plain go test currently requires -tags test_dep because existing local instrumentation references hqScope from a test_dep file
=== RUN   TestBugCR2ReaderCursorStall
=== RUN   TestBugCR2ReaderCursorStall/healthy_read_before_checkpoint_shrink
    bugcr2_cursor_stall_repro_test.go:85: healthy_control submitted=[1 3] persistence_reads=2
=== RUN   TestBugCR2ReaderCursorStall/checkpoint_shrink_orphans_live_reader_cursor
    bugcr2_cursor_stall_repro_test.go:96: bug_triggered submitted=[1] persistence_reads=1 remaining_scopes=[{{{1970-01-01 00:00:00 +0000 UTC 3} {1970-01-01 00:00:00 +0000 UTC 4}} 0x523a6c0}] cursor_nil=true notify_repaired=false
    bugcr2_cursor_stall_repro_test.go:101: reconstruction_repaired submitted=[1 3] persistence_reads=2
--- PASS: TestBugCR2ReaderCursorStall (0.00s)
PASS
ok  	go.temporal.io/server/service/history/queues	0.027s
```

Checklist:
1. Level 0/1 alone? **yes**. Normal reader load, ACK, checkpoint shrink, notify/read; no timing assist, failpoint, source patch, or impossible state injection.
2. Level 2/3? **not applicable**.
3. Real consumer: `service/history/queues/reader.go:545-547`, `scheduler.TrySubmit`; it never receives the second executable in the bad path.
4. Permanence/masking: not physical data loss; reconstruction repairs it. But during the live ownership path, repeated notify/checkpoint/poll did not repair it, so the transfer task is stranded until reload or another cursor-resetting mutation.

## Recommendation
Call `resetNextReadSliceLocked()` after `ShrinkSlices()` removes any slice, or specifically when the removed element is `nextReadSlice`. Add a regression test covering full-batch read, ACK, checkpoint shrink, surviving later slice, and `Notify()`.

---

## Entry 3: Deletion receipt, volatile checkpoint, and durable checkpoint diverge

- **Finding ID**: CR-3
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `service/history/queues/queue_base.go:340`

## Description
CR-3 does not reproduce as a live bug. The delete-before-state-update ordering is intentional: when deletion succeeds but the queue-state update is lost, batched, or fails, recovery reloads from an older durable checkpoint and re-reads/re-deletes from the older boundary. The unfinished row remains reachable, and prefix deletion is idempotent.

## Trigger scenario
Tested four schedules against SQLite persistence and the real `queueBase.checkpoint`/`SetQueueState` path: healthy checkpoint, committed delete with lost timeout reply, batched local-only queue-state update, and `UpdateShard` failure after committed delete.

## Developer intent
`queue_base.go:340-342` explicitly says range completion must happen before queue-state persistence to avoid the opposite unsafe state. PR `#5399` introduced shard-info batching to reduce DB update load, so a lagging durable queue state is expected behavior.

## Reproduction result
Repro written and executed: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/repro/test_bugCR-3_checkpoint_recovery.sh`

Command:
```bash
timeout 15m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/repro/test_bugCR-3_checkpoint_recovery.sh
```

Key real output:
```text
source_sha=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
=== RUN   TestQueueBaseSuite/TestBugCR3CheckpointRecoveryEvidence/healthy
CR3 schedule=healthy delete_calls=1 delete_errors=0 checkpoint_shard_updates=1 checkpoint_shard_update_errors=0 total_shard_updates=1 total_shard_update_errors=0 memory_delete=2 durable_reload_high=2 independent_remaining_rows=1 independent_min_task=2 recovered_read_task=2 retry_delete_preserved_unfinished=true
=== RUN   TestQueueBaseSuite/TestBugCR3CheckpointRecoveryEvidence/delete_execute_and_timeout
CR3 schedule=delete_execute_and_timeout delete_calls=1 delete_errors=1 checkpoint_shard_updates=0 checkpoint_shard_update_errors=0 total_shard_updates=0 total_shard_update_errors=0 memory_delete=1 durable_reload_high=1 independent_remaining_rows=1 independent_min_task=2 recovered_read_task=2 retry_delete_preserved_unfinished=true
=== RUN   TestQueueBaseSuite/TestBugCR3CheckpointRecoveryEvidence/batched_state_lags
CR3 schedule=batched_state_lags delete_calls=1 delete_errors=0 checkpoint_shard_updates=1 checkpoint_shard_update_errors=0 total_shard_updates=1 total_shard_update_errors=0 memory_delete=2 durable_reload_high=1 independent_remaining_rows=1 independent_min_task=2 recovered_read_task=2 retry_delete_preserved_unfinished=true
=== RUN   TestQueueBaseSuite/TestBugCR3CheckpointRecoveryEvidence/update_shard_error_after_delete
CR3 schedule=update_shard_error_after_delete delete_calls=1 delete_errors=0 checkpoint_shard_updates=1 checkpoint_shard_update_errors=1 total_shard_updates=2 total_shard_update_errors=2 memory_delete=2 durable_reload_high=1 independent_remaining_rows=1 independent_min_task=2 recovered_read_task=2 retry_delete_preserved_unfinished=true
--- PASS: TestQueueBaseSuite (1.35s)
PASS
ok  	go.temporal.io/server/service/history/queues	1.376s
```

## Recommendation
No repair needed for CR-3 as stated. Keep the delete-before-state ordering and add/retain a recovery regression test like the generated repro to document the intended lagging-checkpoint behavior.

---

## Entry 4: An old owner can finish effects after durable ownership changes

- **Finding ID**: CR-4
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/queues/queue_base.go:351

## Description

CR-4 is confirmed only as a stale-owner side effect, not as an externally observed correctness bug. `queueBase.checkpoint()` range-deletes completed task rows before persisting queue state (`service/history/queues/queue_base.go:351`, then `:360`). The SQL transfer-task range delete has no `RangeID` fence (`common/persistence/sql/execution_tasks.go:361`), while shard-state updates are fenced by `PreviousRangeID` (`common/persistence/sql/shard.go:82`, `:137`).

The repro showed an old owner can delete the transfer row after another owner durably advances the shard to `RangeID=2`; the old owner’s subsequent queue-state update is rejected with `ShardOwnershipLostError`. I did not reproduce a real caller observing a wrong workflow/activity outcome, because this checkpoint deletion path is reached after the old owner’s local ack boundary has advanced.

## Trigger scenario

1. Owner A owns shard 44 at `RangeID=1` and has a transfer task row.
2. Owner B durably acquires the shard at `RangeID=2`.
3. Owner A’s local queue state advances its completed/acked boundary to task 2.
4. Owner A checkpoints.
5. The range delete removes `[1,2)` without a `RangeID`; the following queue-state write fails due ownership fencing.

## Developer intent

The checkpoint code intentionally deletes first; the comment at `service/history/queues/queue_base.go:340` says persisting state first can leave completed tasks never deleted if deletion later fails. Transfer execution also has downstream guards: stale/duplicate activity starts are dropped in `recordactivitytaskstarted/api.go:131`, `:150`, and workflow-task duplicates/obsolete starts are dropped in `recordworkflowtaskstarted/api.go:69`, `:76`, `:98`.

## Reproduction result

Repro written and executed:

`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/repro/test_bugCR-4_stale_owner_checkpoint.sh`

Output:

```text
CR4_REPRO source_sha=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
LEVEL0_ATTEMPT public-api-normal-ops result=not-triggered reason=no deterministic public API knob exposes the post-ack/pre-checkpoint stale-owner window
LEVEL1_ATTEMPT timing-test-hook result=not-triggered reason=available queue hooks do not force durable shard acquisition between old-owner completion and checkpoint without state control
CR4_REPRO clean_worktree=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
LEVEL2_ATTEMPT state-injection result=running injected_precondition=durable-rangeid-2-with-old-owner-local-rangeid-1-and-local-ack-boundary-advanced-to-task-2
=== RUN   TestQueueBaseSuite/TestCR4StaleOwnerCheckpointDeletesBeforeOwnershipFence
OWNERSHIP_OBSERVATION durable_owner_rangeid=2 previous_owner_rangeid=1 transfer_rows_before=1
QUEUE_OBSERVATION range_delete_called shard=44 min=1 max=2 request_has_range_id=false
QUEUE_OBSERVATION stale_state_update previousRangeID=1 requestedRangeID=1 error=*persistence.ShardOwnershipLostError
SQL_OBSERVATION transfer_rows_after_old_checkpoint=0 physical_rows_after_old_checkpoint=0 durable_rangeid=2 durable_watermark=1 old_owner_memory_delete_watermark=2
MASK_OBSERVATION old_owner_row_delete_is_unfenced=true stale_queue_state_update_is_fenced=true deletion_precondition=old_owner_advanced_local_ack_boundary
--- PASS: TestQueueBaseSuite (0.35s)
PASS
ok  	go.temporal.io/server/service/history/queues	0.377s
```

## Recommendation

Do not mark this as `REPRODUCED` without a real executor path where the old owner can ack before the downstream obligation is durable or idempotently recoverable. If Temporal wants strict ownership isolation for cleanup too, add `RangeID` fencing to `RangeCompleteHistoryTasks` or recheck shard ownership immediately before range deletion; otherwise document that stale cleanup after local ack is tolerated and relies on executor/downstream idempotency.

---

## Entry 5: ACK discharges a transport obligation under a specific downstream contract

- **Finding ID**: CR-5
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/temporalio/temporal/pull/10759; fix-status: unfixed)
- **Location**: service/matching/matching_engine.go:812

## Description
The reviewed mechanism is real: History ACKs the transfer task once Matching accepts/spools it, while a later Matching poll can drop the backlog task if `RecordWorkflowTaskStarted` or `RecordActivityTaskStarted` returns `Internal`/`DataLoss`. This exact backlog/spooled Matching drop mechanism was already reported upstream in PR #10468 and re-landed as PR #10759 as `tasks_dropped` observability, so this code-review finding is not novel.

## Trigger scenario
A History transfer task calls Matching `AddWorkflowTask`/`AddActivityTask`; no worker sync-matches immediately, so the task is spooled. Later, a worker polls, Matching calls History `Record*TaskStarted`, History returns `Internal` or `DataLoss`, and Matching calls `task.finish` with a drop reason instead of an error, so the backlog completion path treats the entry as complete.

## Developer intent
Upstream PR #10759 states that `tasks_dropped` fires when Matching throws away backlog/spooled tasks, including non-retryable `Record(Workflow|Activity)TaskStarted` failures, and excludes sync-match tasks because those errors return to the `AddTask` caller. That is same mechanism, same site, already public; the PR is instrumentation-only, not a behavioral fix.

## Reproduction result
Repro written and executed:
`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/repro/test_bugCR-5_matching_drop.sh`

Real output excerpt:
```text
repo_rev=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
command=timeout 10m go test ./service/matching -run 'TestMatchingEngine_Classic_Suite/TestPoll(Activity|Workflow)TaskQueues_(InternalError|DataLossError)$' -count=1 -v
=== RUN   TestMatchingEngine_Classic_Suite/TestPollActivityTaskQueues_DataLossError
... error dropping task due to non-nonretryable errors ... "error": "DataLoss Error", "error-type": "serviceerror.DataLoss" ... service/matching/matching_engine.go:954
=== RUN   TestMatchingEngine_Classic_Suite/TestPollActivityTaskQueues_InternalError
... error dropping task due to non-nonretryable errors ... "error": "Internal error", "error-type": "serviceerror.Internal" ... service/matching/matching_engine.go:954
=== RUN   TestMatchingEngine_Classic_Suite/TestPollWorkflowTaskQueues_DataLossError
... error dropping task due to non-nonretryable errors ... "error": "DataLoss error", "error-type": "serviceerror.DataLoss" ... service/matching/matching_engine.go:954
=== RUN   TestMatchingEngine_Classic_Suite/TestPollWorkflowTaskQueues_InternalError
... error dropping task due to non-nonretryable errors ... "error": "internal error", "error-type": "serviceerror.Internal" ... service/matching/matching_engine.go:954
--- PASS: TestMatchingEngine_Classic_Suite (0.41s)
PASS
ok  	go.temporal.io/server/service/matching	0.442s
```

## Recommendation
Do not file as a new Specula bug. If the behavior is to be changed, the existing known issue area is Matching backlog drop handling for non-retryable `Record*TaskStarted` failures: rewrite/retry, explicitly reschedule through History, or document the timeout/DLQ contract beyond the current metric.

---
