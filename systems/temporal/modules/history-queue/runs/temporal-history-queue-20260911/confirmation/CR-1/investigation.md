# CR-1 Investigation

Finding: code-review CR-1, "Uncertain publication versus read eligibility".
Target revision: temporalio/temporal `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025` (`Make Nexus callback source header opt-in (#11965)`, 2026-09-08).
Backend under test: SQLite with WAL/full synchronous where the local history-queue probes use SQLite.

## Step 1: Code audit

- `service/history/shard/task_key_manager.go:45-53` assigns task keys and then tracks the minimum assigned key per category before the persistence request leaves the shard lock.
- `service/history/shard/task_request_tracker.go:69-82` removes a pending key only for definite success or definite non-commit errors. Generic/unavailable timeout-style errors remain pending because `persistence.OperationPossiblySucceeded` returns true by default (`common/persistence/error_type.go:5-21`).
- `service/history/shard/task_key_manager.go:88-118` computes the queue's exclusive read watermark as `min(minPendingTaskKey, nextTaskKey)`. If an uncertain transfer-task write is pending, the immediate queue should not advance its read boundary past that key.
- `service/history/shard/context_impl.go:576-655` and `:860-873` use `setAndTrackTaskKeys` for workflow mutations and direct task additions, set the request RangeID under the shard lock, execute persistence outside the lock, then call the returned completion function and `handleWriteError`.
- `service/history/shard/context_impl.go:1540-1548` treats an unknown persistence error as an uncertain result and transitions the shard to lost/reacquire. The comment states the intended contract: after successful reacquire, reads either see the uncertain write or know that it failed.
- `service/history/shard/context_impl.go:1169-1215` drains in-flight task requests before updating shard RangeID and clears pending task keys after the new RangeID is persisted.
- `common/persistence/sql/execution.go:40-58` wraps execution mutations in a SQL transaction after reading/checking the shard RangeID. `common/persistence/sql/common.go:52-80` either rolls back on function error or commits before returning success.
- `common/persistence/sql/shard.go:176-201` checks the persisted shard RangeID before execution writes. For MySQL/Postgres this uses row locks (`FOR UPDATE` / share locks); SQLite maps read/write locks to a `SELECT range_id` (`common/persistence/sql/sqlplugin/sqlite/shard.go:22-24,71-96`), so a direct SQLite interleaving probe is needed.
- `service/history/queues/queue_base.go:264-303` moves the readable frontier only from `GetQueueExclusiveHighReadWatermark`; `:305-384` checkpoint shrinks reader scopes, deletes completed durable rows up to the minimum surviving scope/read boundary, and persists queue state after deletion. `:396-418` range-deletes history tasks; `:420-439` persists queue state.
- `service/history/queues/reader.go:436-506` loads tasks only from reader slices and calls completion when no slice remains. `service/history/queues/slice.go:321-340` shrinks a scope to the minimum of pending in-memory task and remaining iterator range.

Reachability: ordinary workflow updates and activity/workflow task scheduling reach `UpdateWorkflowExecution` and therefore the task key tracker. The hazardous schedule requires an old SQLite transaction to read RangeID 1, the queue/new owner to advance RangeID/read eligibility, and that old transaction to later insert transfer tasks below the advanced read boundary.

Safeguards to test:
- pending task key keeps read watermark at the uncertain key while the request is unresolved/ambiguous;
- RangeID reacquire drains in-flight requests before clearing pending keys;
- stale post-renew writes should be fenced by RangeID checks or by the SQL backend refusing a read-transaction-to-write upgrade after a newer committed writer;
- if a nearby reader/cursor schedule leaves a durable row temporarily retained, a fresh shard owner should reconstruct from durable queue state and process it.

## Step 2: Developer knowledge

- Original task request tracker commit: `04eaab42dfe2bc23d77e7dc3039432d0cf9c27de` / PR #4952, "No shard lock on I/O: task request tracker". The added code comments say a task key is not pending only when persistence gives a definitive result and that a random error means the task may still be inserted in the future.
- Original task key manager commit: `df4705d6488485ae12e27f4cb1c719b62c980304` / PR #5008, "No shard lock on I/O: task key manager". The code couples generation/tracking and makes read watermark the min of pending and next task key.
- Nearby later PR #11695 / commit `fc530c118478e81ac1a416a2e7a992d7bceca9db` adds observability for multicursor queue-state resolution loss and explicitly says it is metrics-only, not a behavior fix for this mechanism.
- Nearby later PR #11253 / commit `c23064d3d5cfbe9928807b584b208ed688bb2dab` fixes a pending task action race by cloning `TaskStats`; it is about reading slice statistics outside the reader lock, not late transfer-task publication below a read boundary.

Existing tests:
- `service/history/shard/task_request_tracker_test.go:66-94` asserts that a generic random error keeps the minimum transfer key pending.
- `service/history/shard/task_key_manager_test.go:60-100` asserts pending keys bound the high read watermark until completion, and `:103-133` asserts a range update clears pending requests.
- Local probe `service/history/shard/publication_persistence_evidence_test.go:29-149` exercises SQLite `ExecuteAndTimeout`, stale old-RangeID writes, late stale checkpoint update, independent readback, and range delete behavior.
- Local probe `service/history/queues/queue_base_recovery_sqlite_test.go:32-166` exercises checkpoint/delete/reload behavior; `:168-360` includes a reader-cursor schedule that can retain an unfinished row and then recover it after reconstructing from durable queue state.

## Step 3: Known-status / precedent

Searches performed:
- GitHub API search: `repo:temporalio/temporal taskRequestTracker OR pendingTaskKeys OR GetQueueExclusiveHighReadWatermark state:all` returned `total_count: 0`.
- GitHub API search: `repo:temporalio/temporal "task key manager" "RangeID" state:all` returned `total_count: 0`.
- GitHub API search: `repo:temporalio/temporal "queue-state" "resolution loss" state:all` returned `total_count: 0`.
- GitHub API search: `repo:temporalio/temporal "history queue" "high watermark" state:all` returned `total_count: 0`.
- Local `git log --all --grep` found adjacent read-level/queue-state fixes (#11253, #11570, #11695), but none reports this exact late-publication-below-read-boundary mechanism at the shard/task key manager site.

Known-status evidence: no existing issue/PR/CVE found for this exact CR-1 mechanism, so the code-review known pre-filter does not apply. Proceed to Phase 2.
