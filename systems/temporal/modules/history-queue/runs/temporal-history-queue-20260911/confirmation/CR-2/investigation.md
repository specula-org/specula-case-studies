# CR-2 Investigation

Finding: Logical scope survives but the live reader cursor disappears

Source revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.

Worktree note: the checkout was dirty before this confirmation. Existing local instrumentation caused plain `go test ./service/history/queues` to fail with `service/history/queues/queue_hooks.go:57:55: undefined: hqScope`; `-tags test_dep` includes the matching local test helper and was used for reproduction. No source logic was changed.

## Step 1: Code Audit

Relevant sites:

- `service/history/queues/reader.go:359-377`: `ReaderImpl.ShrinkSlices` walks every slice, calls `slice.ShrinkScope()`, removes slices whose scope is empty, updates slice count, and returns. Unlike `SplitSlices`, `MergeSlices`, `AppendSlices`, `ClearSlices`, and `CompactSlices`, it does not call `resetNextReadSliceLocked`.
- `service/history/queues/reader.go:463-505`: `loadAndSubmitTasks` reads from `r.nextReadSlice.Value.(Slice)`. If `MoreTasks()` is false, it advances with `r.nextReadSlice.Next()`. A removed `container/list.Element` is detached, so `Next()` returns nil even when the reader's current list still has later elements.
- `service/history/queues/reader.go:508-523`: `resetNextReadSliceLocked` would repair this by scanning the current list for the first slice with `MoreTasks()`.
- `service/history/queues/slice.go:308-337`: `ShrinkScope` moves the range min to the minimum pending executable key or iterator key. When the only pending executable has been ACKed and the iterator has reached the slice exclusive max, the scope becomes empty.
- `service/history/queues/slice.go:366-415`: `SelectTasks` can return exactly `batchSize` executables while the iterator object remains in `s.iterators`; `MoreTasks()` is therefore still true until a later read removes the exhausted iterator.
- `service/history/queues/queue_base.go:305-326`: the normal checkpoint path calls `ShrinkSlices` for each reader, then runs checkpoint actions. If no action mutates the affected reader, no cursor reset occurs.
- `service/history/queues/queue_base.go:420-434`: checkpoint persists logical reader scopes with `SetQueueState`; this preserves the surviving later scope but not the live cursor.
- `service/history/queues/queue_base.go:470-473`: queue alert handling can call `Notify`, but notify only schedules another read; it does not reset a nil or detached cursor.
- `service/history/queues/queue_immediate.go:148-156`: immediate queues normally interleave new-range processing and checkpointing in the event loop.

Reachable trigger:

1. A reader has two ordered readable slices.
2. The first slice is read with a batch size equal to the number of tasks returned from that first slice. `SelectTasks` returns the task and `MoreTasks()` remains true because the iterator is still present.
3. The task is submitted to the scheduler and ACKed before the next reader read.
4. Checkpoint calls `ShrinkSlices`; the first slice shrinks to an empty scope and is removed from the list.
5. The live cursor still points to the removed list element.
6. A later read probes the removed, empty slice, then advances via the detached element's `Next()` to nil. The second list slice still has `MoreTasks() == true`, but it is no longer reached by the live reader.

Safeguards checked:

- `Notify()` did not repair the cursor in the repro.
- Repeated `processNewRange`, checkpoint, notify, and load did not repair the durable SQLite repro when no new readable range was appended.
- Reconstruction from persisted queue state repairs the cursor because new readers initialize `nextReadSlice` from the first reconstructed slice.
- A later new range append/merge or another action that calls `resetNextReadSliceLocked` can mask the stall; that is not guaranteed and did not fire in the reproduced no-new-range path.

Observed consumer/consequence:

- The immediate real consumer is the queue scheduler at `service/history/queues/reader.go:545-547` (`scheduler.TrySubmit`). In the bad path it observes no executable for the surviving second slice, so downstream transfer execution is not invoked for that durable task until reconstruction or another cursor-resetting mutation occurs.

## Step 2: Developer Knowledge Search

Local history:

- `git log --all --grep='ShrinkSlices|nextReadSlice|cursor|stale cursor|queue-state resolution loss|multi-cursor|reader.*stuck|MoreTasks'` found adjacent queue work but no commit fixing or reporting this exact stale `nextReadSlice` after `ShrinkSlices` removal.
- PR #11554 (`https://github.com/temporalio/temporal/pull/11554`) changes reader-stuck metrics: "Only count reader reads that left tasks behind as stuck attempts." It does not reset `nextReadSlice` or change `ShrinkSlices`.
- PR #11695 (`https://github.com/temporalio/temporal/pull/11695`) explicitly says "These are only metrics changes - no behavior changes" while adding multicursor queue-state observability. It is adjacent evidence of developer concern about queue-state resolution loss, not a filed report or fix for this cursor defect.
- Recent merged PR search since 2026-09-08 for queue/history-queue terms found #11997 (`history/queues: log the attempt that failed, not the next one`) and unrelated callback/scaler PRs; no exact cursor/shrink fix.

Issue/PR tracker search:

- `gh search issues --repo temporalio/temporal "nextReadSlice ShrinkSlices"`: no results.
- `gh search issues --repo temporalio/temporal "\"nextReadSlice\""`: no results.
- `gh search issues --repo temporalio/temporal "\"ShrinkSlices\""`: no results.
- `gh search issues --repo temporalio/temporal "\"queue-state resolution loss\""`: no results.
- `gh search issues --repo temporalio/temporal "\"multi-cursor\" \"reader\" \"stuck\""`: no results.
- `gh search prs --repo temporalio/temporal "nextReadSlice OR ShrinkSlices OR MoreTasks" --merged`: no results.
- `gh search prs --repo temporalio/temporal "history queue reader stuck" --merged`: no results.
- `gh search prs --repo temporalio/temporal "queue-state resolution loss" --merged`: PR #11695 only; metrics-only, not this defect.

## Step 3: Known Status

No existing issue, PR, CVE, advisory, or local git history entry was found that reports the same mechanism at the same site. This code-review-sourced finding is not a known duplicate.

Novelty: NEW.

## Phase 2 Reproduction Notes

Required repro file:

`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/repro/test_bugCR-2_reader_cursor_stall.sh`

Command executed:

`timeout 12m bash /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/repro/test_bugCR-2_reader_cursor_stall.sh`

Required repro output:

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
    --- PASS: TestBugCR2ReaderCursorStall/healthy_read_before_checkpoint_shrink (0.00s)
    --- PASS: TestBugCR2ReaderCursorStall/checkpoint_shrink_orphans_live_reader_cursor (0.00s)
PASS
ok  	go.temporal.io/server/service/history/queues	0.027s
```

Supporting durable SQLite probe command:

`timeout 15m go test -tags test_dep ./service/history/queues -run 'TestQueueBaseSuite/TestCheckpointSQLiteReaderCursor' -count=1 -v`

Supporting durable output summary:

```text
healthy_control=true batch=100 submitted=101 later_task=502 persistence_reads=2
fault=true batch=100 submitted=100 cursor_nil=true surviving_row=502 memory_delete=502 repeated_checkpoint_poll_notify=3 persistence_reads=1
independent_sql_connection_rows=1 task_id=502 wal_checkpoint_busy=0
managers_reconstructed=true independent_connection_read=true durable_reader=1 durable_min=502 reload_submitted=101 later_task=502 post_ack_checkpoint_rows=0
PASS
ok  	go.temporal.io/server/service/history/queues	1.079s
```

Escalation:

- Level 0: triggered through normal queue reader and checkpoint operations in package tests. No failpoint, timing assist, source patch, or impossible state injection was used. The required script includes a healthy control and the bad checkpoint ordering.
- Level 1-3: not needed because Level 0 triggered the live harm.

