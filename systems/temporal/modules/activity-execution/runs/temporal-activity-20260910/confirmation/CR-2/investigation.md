# CR-2 Investigation

## Source Identity

- Source: Code Review
- Worktree: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-2/worktree`
- Revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`
- Worktree note: the checkout has local Specula/instrumentation edits, including local edits to `service/history/timer_queue_active_task_executor.go` and `service/history/workflow/mutable_state_impl.go`; no source edits were made for this confirmation.

## Step 1: Code Audit

### Cited Code

- `service/history/workflow/timer_sequence.go:118-164`: `CreateNextActivityTimer` sorts all current logical activity deadlines, chooses the earliest one, returns without creating a task if that deadline's `TimerCreated` bit is already set, otherwise sets the corresponding `TimerTaskStatus` bit and enqueues one `ActivityTimeoutTask`.
- `service/history/timer_queue_active_task_executor.go:231-280`: active timeout execution reloads current mutable state, gets current timer sequence, and scans all currently expired logical activity deadlines at `referenceTime`, not merely the physical task's declared timeout type.
- `service/history/timer_queue_active_task_executor.go:299-321`: `processSingleActivityTimeoutTask` skips stale attempts (`timerSequenceID.Attempt < ai.Attempt`), then calls `mutableState.RetryActivity` on the current `ActivityInfo`.
- `service/history/workflow/activity.go:34-41` and `service/history/workflow/activity.go:67-73`: retry updates move the attempt/scheduled time, clear started state, and clear only per-attempt timer bits (`StartToClose`, `ScheduleToStart`, `Heartbeat`) while deliberately preserving `ScheduleToClose`.
- `service/history/workflow/mutable_state_impl.go:447-480`: reload from DB rebuilds the in-memory heartbeat timer watermark map; if persisted `TimerTaskStatus` has the heartbeat bit, `pendingActivityTimerHeartbeats[eventID]` is set to a year-2000 sentinel.
- `service/history/workflow/mutable_state_impl.go:2111-2128`: heartbeat recording updates `LastHeartbeatUpdateTime`, stores heartbeat details, and marks activity sync, but does not directly clear the heartbeat-created bit.
- `service/history/workflow/mutable_state_impl.go:2208-2225`: `UpdateActivityTaskStatusWithTimerHeartbeat` is the shared status/watermark updater.
- `service/history/workflow/task_generator.go:728-730` and `service/history/workflow/task_refresher.go:389-434`: normal transaction close and task refresh both call `CreateNextActivityTimer` after relevant mutable-state updates.

### Call Chain and Reachability

- Activity scheduling/start/heartbeat/retry/timeout paths are reachable through normal worker-facing APIs:
  - `recordactivitytaskstarted.Invoke` records an activity start through `MutableState.AddActivityTaskStartedEvent`.
  - `recordactivitytaskheartbeat.Invoke` updates progress through `MutableState.UpdateActivityProgress`.
  - active timer execution reaches `executeActivityTimeoutTask`, then `processSingleActivityTimeoutTask`, then `MutableState.RetryActivity`.
  - retry updates call `updateActivityInfoForRetries`, then generate retry tasks.
- The code uses a shared physical timer cue model: one pending physical `ActivityTimeoutTask` is enough to wake the executor, which then recomputes and scans current logical deadlines.

### Safeguards Observed

- The active executor compares deadlines using `mutableState.ToRealTime(timerSequenceID.Timestamp)` during expiry checks, so virtual-time/time-skipping state is applied to recomputed logical deadlines.
- A heartbeat physical task has a dedup branch: if the queued heartbeat task has reached or passed the stored heartbeat visibility watermark, the executor clears only `TimerTaskStatusCreatedHeartbeat`, allowing `CreateNextActivityTimer` to generate the next valid heartbeat timer.
- Retry clears per-attempt timer bits on the activity itself before retry-task generation, so stale start-to-close, schedule-to-start, and heartbeat tasks from the previous attempt are not considered current obligations.
- `processSingleActivityTimeoutTask` rechecks the current attempt and returns no update for older attempts.
- The active executor scans every currently expired logical activity timer, so a physical task for one timer type can service another expired logical timeout if it is now earliest/current.
- Current tests include focused coverage for deadline-mask preservation, retry deadline changes, heartbeat-progress coalescing, and active heartbeat dedup under reload/time-skipping.

### Trigger Scenario Considered

The natural trigger considered was:

1. A workflow schedules and starts a retryable activity with heartbeat and other timeouts.
2. Temporal creates only the earliest activity timeout task and marks the relevant `TimerTaskStatus` bit.
3. Heartbeats, retries, duplicate physical timer delivery, or reload from persistence move the current logical deadline set while an older physical task remains in the queue.
4. The older physical task fires; the executor must recompute current logical deadlines and either process all due obligations or clear/recreate the moved heartbeat cue.

The audited code and tests show this scenario is intentionally handled by recomputing current deadlines at execution time plus selective timer-bit invalidation/recreation.

## Step 2: Developer-Knowledge Search

### Git History / Merged PRs

- `f667755b7bdf52057b169514299739bf4797a6fe` / PR #11565, "Recreate only the activity timers whose deadline actually moved", merged 2026-08-18: explicitly reports the `TimerTaskStatus`/deadline mechanism at this site. It states that `CreateNextActivityTimer` creates only the earliest timer and that `ActivityTimeoutTask` is a wake-up; `processSingleActivityTimeoutTask` re-derives the current sequence and fires whatever expired. It also states duplicate tasks are dropped at execution and have no correctness impact, only a timer-queue hotspot. URL: https://github.com/temporalio/temporal/pull/11565
- `5ed21eb39b8b46031666c59afc51ea3f87ad8fd0` / PR #11811, "Preserve pending heartbeat timeout task during replication", merged 2026-08-28: documents the active-path heartbeat-coalescing contract: recording a heartbeat keeps the earlier pending wake-up, which re-evaluates the latest heartbeat deadline when it fires. URL: https://github.com/temporalio/temporal/pull/11811
- `abeeabd4a4c0122117999916b28caed4fca76e73` / PR #11666, "Fix activity timeout regeneration after unpause", merged 2026-08-20: documents a distinct paused/unpaused activity case where dropped timeout tasks could leave timeout ineffective, and says stale queued tasks become no-ops through existing validation. URL: https://github.com/temporalio/temporal/pull/11666

### Issue / PR Tracker Search

Ran GitHub searches against `temporalio/temporal` for `CreateNextActivityTimer`, `TimerTaskStatus`, activity timers, heartbeat timeout, schedule-to-close retry timer, and deadline/no-correctness-impact terms. These did not reveal a separate open or closed issue beyond the merged PRs above.

### Comments / Tests

- Code comments near `executeActivityTimeoutTask` document the heartbeat dedup watermark and duplicate persisted heartbeat task scenario.
- `service/history/workflow/mutable_state_impl_test.go` includes `TestNextActivityTimerTaskMask_*` cases for retry, legacy schedule-to-close anchor, unchanged attempts, changed heartbeat deadlines, heartbeat progress, and disappeared timers.
- `service/history/timer_queue_active_task_executor_test.go` includes `TestProcessActivityTimeout_Heartbeat_DedupUnderSkip`, asserting the active executor updates mutable state instead of short-circuiting when reload/time-skipping would otherwise make the heartbeat dedup gate ambiguous.

## Step 3: Known Status / Precedent

CR-2 is code-review sourced and overlaps an already merged upstream report/fix at the same timer-status/deadline site. PR #11565 is the primary known match for the shared physical timer cue / recomputed logical deadline mechanism; PR #11811 is the primary heartbeat-progress coalescing precedent. The mechanism is therefore not a new unreported bug in the current target revision.
