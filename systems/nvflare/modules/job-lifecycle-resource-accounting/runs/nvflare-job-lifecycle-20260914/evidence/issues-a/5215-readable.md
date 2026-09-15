# 5215: Fix concurrent job lifecycle accounting using explicit event job IDs

{'state': 'CLOSED', 'createdAt': '2026-08-26T18:06:01Z', 'updatedAt': '2026-08-26T22:33:58Z', 'closedAt': '2026-08-26T22:33:58Z'}

## Body
## Description

`DefaultJobScheduler` currently identifies `JOB_STARTED`, `JOB_COMPLETED`, and `JOB_ABORTED` events using the sticky `CURRENT_JOB_ID` value from `FLContext`.

Job launch and completion processing can run concurrently. Because sticky context properties are shared across derived contexts, another job can replace `CURRENT_JOB_ID` before a lifecycle handler reads it. The event can then be attributed to the wrong job.

## Impact

Incorrect event attribution corrupts `scheduled_jobs` accounting. A completed job can remain counted as active, or another job can be removed instead. Once stale entries reach `max_jobs`, the scheduler can reject valid admissions even when execution capacity is available. This can collapse concurrency to serial execution or leave jobs waiting indefinitely.

This is an accounting correctness bug; reduced throughput is one observable consequence.

## Expected behavior

Every lifecycle event must update scheduler accounting for the job that actually generated that event, independent of subsequent changes to sticky context state.

## Proposed fix

- Publish the originating job ID as non-sticky lifecycle event data from `JobRunner`.
- Prefer that explicit event job ID in `DefaultJobScheduler`.
- Retain `CURRENT_JOB_ID` as a compatibility fallback for existing event publishers.
- Cover concurrent sticky-context mutation and lifecycle publication with focused regression tests.

## Acceptance criteria

- Start, completion, abort, and launch-failure events carry the originating job ID.
- Scheduler accounting uses the explicit event ID when sticky context contains a different job ID.
- Existing lifecycle publishers without explicit event data remain compatible.
- Concurrent multi-job runs do not retain stale scheduled-job entries or collapse admission because of misattributed lifecycle events.


## timeline-comments 5430089679 by pcnudde; https://github.com/NVIDIA/NVFlare/issues/5215#issuecomment-5430089679; ; 
Review of #5216 found the same lifecycle-identity race in more consumers; the PR scope was expanded:

- `_save_workspace` derived the job ID from sticky `CURRENT_JOB_ID` in the completion path, so a concurrent job could get its live workspace archived by another job's completion. It now receives the job ID explicitly.
- Job-ID extraction was moved to a shared helper `nvflare.apis.utils.job_utils.get_event_job_id` (prefer explicit event data, fall back to `CURRENT_JOB_ID`); `EdgeTaskDispatcher` was migrated to it as well.
- Added regression coverage for explicit-ID workspace archival, the real delivery chain (`JobRunner` -> `fire_event_with_data` -> event dispatch -> `DefaultJobScheduler`), and ETD event-data preference.

Not addressed in #5216, candidate follow-up:

- Root cause: the server parent writes `CURRENT_JOB_ID` as a sticky prop (`job_scheduler.py:187`, `job_runner.py:467/654/792/827`), so the shared sticker is clobbered for every reader outside the now-fixed lifecycle consumers. The fix is converting all five writes to non-sticky (the client parent and the SJ processes already do this), but it changes behavior for external components that read `CURRENT_JOB_ID` from server-parent contexts on single-job systems, and all five must convert together or the set_prop mask-consistency check silently refuses later non-sticky writes. Needs its own concurrency soak validation.
- `JobMetricsCollector` still tags and pairs job lifecycle metrics without the explicit event job ID, so concurrent jobs cross-attribute durations.
