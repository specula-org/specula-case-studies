# CR-1 Investigation

## Source Identity

- Source checkout: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-1/worktree`
- Revision checked: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`
- Worktree note: checkout already contains unrelated Specula tracing/instrumentation modifications; no source logic was changed for this investigation. The repro script creates and removes one temporary Go test file during execution.

## Code Audit

### Retry Dispatch

- `service/history/timer_queue_active_task_executor.go:551-668` handles `ActivityRetryTimerTask`.
- The executor loads mutable state under the workflow lease, then verifies that the pending `ActivityInfo` exists (`573-579`), the retry task stamp matches and the activity is not paused (`581-585`), the retry task attempt is not older than current state and the activity is not already started (`587-599`), the task version is valid (`600-603`), the workflow is running (`605-608`), and workflow activity rules still allow the dispatch (`610-620`).
- The lease is released before the Matching `AddActivityTask` call (`631-648`). That creates the handoff window CR-1 is concerned about.
- The Matching request carries scheduled event id, schedule-to-start timeout, version directive, stamp, and priority (`635-648`), but not the retry-attempt number. The start attempt returned to a worker is therefore reconstructed by History at poll/start time.

### Task Generation And Attempt Mutation

- `service/history/workflow/task_generator.go:552-567` generates ordinary activity transfer tasks with `activityInfo.Stamp`.
- `service/history/workflow/task_generator.go:572-581` generates retry timer tasks with the current `EventID`, `Attempt`, and `Stamp`.
- `service/history/workflow/mutable_state_impl.go:6881-6978` implements `RetryActivity`. It refuses retry when no policy is set or cancellation is pending (`6889-6893`), computes the retry backoff, then calls `updateActivityInfoForRetries` and generates a retry timer task.
- `service/history/workflow/mutable_state_impl.go:7005-7021` delegates retry mutation to `UpdateActivityInfoForRetries`.
- `service/history/workflow/activity.go:48-57` clears per-attempt started fields (`StartedEventId`, `StartVersion`, `RequestId`, `StartedTime`, `StartedClock`) when leaving a started attempt.
- `service/history/workflow/activity.go:59-90` sets the next attempt, current version, scheduled time, last failure, clears per-attempt start state, and increments `Stamp` only when `EnableActivityRetryStampIncrement` is enabled and the attempt increases.
- `common/dynamicconfig/constants.go:239-243` shows `system.enableActivityRetryStampIncrement` defaults to `false` in this checkout.

### Start Reconstruction

- Worker polling enters through `service/frontend/workflow_handler.go:1333-1438`. The frontend calls Matching and returns the Matching poll response and task token to the worker.
- Matching receives an activity task and calls History before returning it to a worker: `service/matching/matching_engine.go:1017-1038`.
- Matching treats History `NotFound` and `TaskAlreadyStarted` as stale/invalid task drops, not worker-visible starts: `service/matching/matching_engine.go:1048-1062`.
- `service/matching/matching_engine.go:3565-3618` constructs `RecordActivityTaskStartedRequest` with workflow execution, scheduled event id, request id, poll request, stamp, version directive, and component ref. It sends that to History and only later builds a worker response.
- `service/history/api/recordactivitytaskstarted/api.go:51-97` runs the start under `GetAndUpdateWorkflowWithNew`.
- `service/history/api/recordactivitytaskstarted/api.go:135-151` rejects missing/completed activities. `165-185` returns idempotently for the same `RequestId` but rejects a different request if the activity already started. `193-199` rejects stale stamp tasks.
- `service/matching/matching_engine.go:3412-3450` creates the worker task token after History accepts the start. It uses History's returned `Attempt`, `Version`, and `StartVersion`.
- `common/tasktoken/token.go:33-60` confirms the task token carries scheduled event id, activity id/type, attempt, clock, version, start version, component ref, and activity attempt stamp.

### Worker Reply Validation

- Public worker replies enter through frontend:
  - heartbeat: `service/frontend/workflow_handler.go:1441-1456` documents that the task token from `PollActivityTaskQueue` is required.
  - completion: `service/frontend/workflow_handler.go:1635-1706` forwards token completion to History.
  - failure: `service/frontend/workflow_handler.go:1840-1932` forwards token failure to History.
- History reply handlers deserialize the token, resolve run id when necessary, load/update mutable state under the workflow lease, fetch the current `ActivityInfo`, and call the common token guard:
  - completion: `service/history/api/respondactivitytaskcompleted/api.go:23-167`, especially `79-100`.
  - failure: `service/history/api/respondactivitytaskfailed/api.go:24-166`, especially `80-99`.
  - cancellation: `service/history/api/respondactivitytaskcanceled/api.go:23-149`, especially `78-102`.
  - heartbeat: `service/history/api/recordactivitytaskheartbeat/api.go:19-117`, especially `70-90`.
- `service/history/api/activity_util.go:58-80` is the central guard. It returns not-found if the token refers to a normal by-token activity reply and the activity is not started (`63-66`), if the token has a scheduled event id and `token.Attempt != ai.Attempt` (`68-70`), if both start versions are set and differ (`71-73`), or if the legacy token version check fails (`74-78`).

### Trigger Scenario

Concrete reachable sequence:

1. Start a workflow and schedule an ordinary Workflow Activity with a retry policy.
2. Worker polls attempt 1 and receives a public activity task token.
3. Worker responds with retryable failure for attempt 1.
4. History mutates pending `ActivityInfo` to attempt 2 and clears per-attempt started state; the retry timer later dispatches attempt 2 to Matching.
5. Worker polls attempt 2, causing Matching to call History `RecordActivityTaskStarted`, and receives a fresh attempt-2 token.
6. A delayed/duplicate attempt-1 worker heartbeat, failure, or completion arrives after attempt 2 has started.

Safeguards observed:

- Old retry timer tasks are ignored if their attempt is older than current state or the activity already has a started event.
- Matching does not create the worker token until History has accepted `RecordActivityTaskStarted`.
- Worker replies are checked against current `ActivityInfo` under the workflow lease, and stale attempt tokens are rejected before mutation.
- A cancellation acknowledgement after retry is not a normal retry handoff sequence: if `ai.CancelRequested` is true, `RetryActivity` returns `RETRY_STATE_CANCEL_REQUESTED` instead of scheduling the retry.

## Developer Knowledge Search

Issue tracker and PR/history searches were run against `temporalio/temporal` using queries covering activity attempts, task tokens, stale tokens, retry stamps, `StartVersion`, and recently merged/closed PRs.

Relevant historical evidence:

- Git commit `dee4c74e30f9a0456d5d33050450a8d61fb94577` says: "Disallow activity completion from previous attempts" and explains that activity completion dedupe had allowed a previous attempt to complete while the server had retried with a larger attempt. This is an older completion-only predecessor to the current guard.
- PR `https://github.com/temporalio/temporal/pull/8342` ("use activity start event version to verify SDK's activity update request", merged 2025-09-23) added `StartVersion` to the activity task-token validation path because `ai.Version` can change after failover.
- PR `https://github.com/temporalio/temporal/pull/8536` ("Validate activity task stamps before reuse", merged 2025-11-04) added activity task stamp validation before task reuse and covered it with tests.
- PR `https://github.com/temporalio/temporal/pull/8607` ("Gate activity retry stamp behind feature flag", merged 2025-11-10) explains the stamp increment is feature-gated for rolling-upgrade compatibility.
- PR `https://github.com/temporalio/temporal/pull/10135` ("Fix standalone activity by-ID APIs returning NotFound after retry", merged 2026-04-30) is standalone-activity/by-ID specific and outside the ordinary Workflow Activity target scope.
- PR `https://github.com/temporalio/temporal/pull/11097` ("fix task token invalidation after resetting an activity", merged 2026-07-17) is also standalone-activity reset-specific and outside the ordinary Workflow Activity target scope. It confirms developers use monotonic token generations where visible attempt counters can rewind.
- Existing tests include `service/history/api/activity_util_test.go:39-50`, asserting attempt-mismatch rejection, and `tests/activity_standalone_test.go:1303-1368`, asserting stale retry-attempt token rejection for a public activity path.

Known-status search result:

- No upstream issue or recently merged/closed PR was found that reports the exact CR-1 current-source mechanism as an unfixed ordinary Workflow Activity bug spanning retry dispatch plus delayed worker replies at the cited modern code sites.
- The older fixed completion bug and related start-version/stamp changes are evidence that this area is intentionally guarded, not a duplicate report of a current CR-1 defect across the listed paths.

## Phase 2 Reproduction Record

- Repro artifact: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/repro/test_bugCR-1_stale_attempt_replies.sh`
- Command: `timeout 4m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/repro/test_bugCR-1_stale_attempt_replies.sh`
- Captured output: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-1/repro-output.log`
- Run result: exit code 0.

Filtered signal lines:

```text
Running: go test -count=1 -tags test_dep ./tests -run TestCR1WorkflowActivityStaleAttemptRepliesAreRejected -timeout 2m -v
=== RUN   TestCR1WorkflowActivityStaleAttemptRepliesAreRejected
    cr1_stale_attempt_replies_test.go:46: started workflow runID=01a08f0c-d38e-781c-8b90-71d48c247ac7
    cr1_stale_attempt_replies_test.go:83: scheduled retryable workflow activity
    cr1_stale_attempt_replies_test.go:89: polled attempt=1 tokenLen=190
    cr1_stale_attempt_replies_test.go:106: failed attempt 1 retryably
    cr1_stale_attempt_replies_test.go:112: polled retry attempt=2 tokenLen=190
    cr1_stale_attempt_replies_test.go:114: heartbeat with stale attempt-1 token rejected as NotFound: invalid activityID or activity already timed out or invoking workflow is completed
    cr1_stale_attempt_replies_test.go:123: duplicate failure with stale attempt-1 token rejected as NotFound: invalid activityID or activity already timed out or invoking workflow is completed
    cr1_stale_attempt_replies_test.go:137: completion with stale attempt-1 token rejected as NotFound: invalid activityID or activity already timed out or invoking workflow is completed
    cr1_stale_attempt_replies_test.go:158: pending activity after stale replies: activityID=cr1-activity attempt=2
    cr1_stale_attempt_replies_test.go:169: completed attempt 2 successfully
    cr1_stale_attempt_replies_test.go:193: workflow completed after valid attempt-2 completion
--- PASS: TestCR1WorkflowActivityStaleAttemptRepliesAreRejected (1.14s)
PASS
ok  	go.temporal.io/server/tests	1.186s
```
