# Confirmation Report — temporal-activity

## Final Result

Reproduced bugs: 0 = 0 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 3
Dropped: 1
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 5
Dispositions: 5 total = 0 reproduced + 0 env-limited + 1 masked + 3 false-positive + 0 needs-more-info + 1 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | CR-1 | FALSE POSITIVE | no |
| 2 | CR-2 | DROPPED | no |
| 3 | CR-3 | FALSE POSITIVE | no |
| 4 | CR-4 | FALSE POSITIVE | no |
| 5 | CR-5 | MASKED | no |

## Entry 1: Attempt identity across dispatch and delayed worker replies

- **Finding ID**: CR-1
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/api/activity_util.go:58

## Description
CR-1 did not reproduce as a live Temporal Server bug. The suspected delayed old-attempt worker replies are rejected by the normal History token validation path: `IsActivityTaskNotFoundForToken` rejects mismatched attempts before completion/failure/heartbeat can mutate the current activity state.

## Trigger scenario
A normal Workflow Activity was scheduled with retries. Attempt 1 was polled and failed retryably, attempt 2 was delivered, then the old attempt-1 token was reused for heartbeat, failure, and completion.

## Developer intent
Upstream history shows this area is intentionally guarded: prior fixes added previous-attempt completion rejection, start-version validation, and activity-task stamp validation. I searched upstream issues and merged/closed PRs for this exact current ordinary Workflow Activity retry/delayed-reply mechanism and found related fixed/standalone cases, but no exact current-source report for CR-1.

## Reproduction result
Command:
```text
timeout 4m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/repro/test_bugCR-1_stale_attempt_replies.sh
```

Output excerpt:
```text
Running: go test -count=1 -tags test_dep ./tests -run TestCR1WorkflowActivityStaleAttemptRepliesAreRejected -timeout 2m -v
=== RUN   TestCR1WorkflowActivityStaleAttemptRepliesAreRejected
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

## Recommendation
Do not report CR-1 as a bug. Keep the repro as a regression check for ordinary Workflow Activity stale-attempt replies; no repair request is warranted for this code-review finding.

---

## Entry 2: Shared timer cues conserve current deadline obligations

- **Finding ID**: CR-2
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/temporalio/temporal/pull/11565; fix-status: fixed)
- **Location**: service/history/workflow/timer_sequence.go:118

## Description
CR-2 duplicates an already merged Temporal report/fix around `TimerTaskStatus`, `CreateNextActivityTimer`, and activity timeout tasks as shared wake-up cues. PR #11565 explicitly documents that `ActivityTimeoutTask` re-derives current logical deadlines at execution time and that duplicate physical timer tasks are dropped with no correctness impact.

## Trigger scenario
A retryable Activity has one pending physical timeout task; heartbeat progress, retry, reload, or duplicate delivery changes the logical deadline set before that task executes. The executor reloads mutable state, recomputes current activity timers, clears/recreates heartbeat timer status when needed, and scans all expired logical deadlines.

## Developer intent
Developer evidence is explicit in merged PR #11565 and #11811: pending timeout tasks are treated as wake-ups, not one-task-per-deadline obligations. PR #11811 also documents heartbeat coalescing: recording a heartbeat keeps an earlier wake-up, which re-evaluates the latest heartbeat deadline when it fires.

## Reproduction result
Executed: `.specula-output/repro/test_bugCR-2_shared_timer_cues.sh`

```text
CR-2 shared timer cues reproduction/known-status check
source sha: 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
dirty files relevant to CR-2:
 M service/history/timer_queue_active_task_executor.go
 M service/history/workflow/mutable_state_impl.go

+ go test ./service/history/workflow -run ^TestMutableStateSuite$ -testify.m ^TestNextActivityTimerTaskMask_...$ -count=1 -v
--- PASS: TestMutableStateSuite (0.01s)
PASS
ok  	go.temporal.io/server/service/history/workflow	0.037s

+ go test ./service/history -run ^TestTimerQueueActiveTaskExecutorSuite$ -testify.m ^TestProcessActivityTimeout_Heartbeat_DedupUnderSkip$ -count=1 -v
--- PASS: TestTimerQueueActiveTaskExecutorSuite (0.01s)
    --- PASS: TestTimerQueueActiveTaskExecutorSuite/TestProcessActivityTimeout_Heartbeat_DedupUnderSkip (0.01s)
PASS
ok  	go.temporal.io/server/service/history	0.037s

CR-2 result: targeted tests passed; no live uncovered timeout/retry obligation was reproduced.
```

Investigation notes written to: `.specula-output/confirmation/CR-2/investigation.md`.

## Recommendation
Do not report CR-2 as a new bug. Treat it as a known, already fixed code-review duplicate of PR #11565’s activity timer status/deadline mechanism, with heartbeat coalescing further covered by PR #11811.

---

## Entry 3: Persistence result, API result, and recovery can disagree temporarily

- **Finding ID**: CR-3
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/shard/context_impl.go:1540

## Description

CR-3 is a false positive as a bug claim. The temporary disagreement is real: `UpdateWorkflowExecution` can commit Activity completion while the worker-facing completion call receives `DeadlineExceeded`. But Temporal explicitly treats that class of error as possibly succeeded, clears/reloads mutable state, reacquires shard ownership, preserves task visibility, rejects the duplicate completion, and delivers exactly one `ActivityTaskCompleted` to the workflow worker.

## Trigger scenario

A workflow schedules an Activity, a worker polls the Activity task, and the worker calls `RespondActivityTaskCompleted`. The persistence hook executes `UpdateWorkflowExecution` successfully and then returns a timeout, modeling a committed storage attempt with a lost response.

## Developer intent

No exact upstream issue/closed PR reported this Activity-completion mechanism as a current bug. Related PRs show intended handling instead: #5869 added `ExecuteAndTimeout`, and #2334 notifies tasks when a workflow update may have succeeded; current comments at `service/history/shard/context_impl.go:1540-1546` state the read-after-reacquire guarantee.

## Reproduction result

Wrote and executed:

```text
timeout 20m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/repro/test_bugCR-3_commit_response_timeout.sh
```

Output:

```text
Level 0: public workflow/activity path without injected persistence fault
--- PASS: TestSpeculaActivityTrace (0.35s)
    --- PASS: TestSpeculaActivityTrace/healthy_buffered_reload (0.35s)
PASS
ok  	go.temporal.io/server/tests	0.443s

Level 1: public activity completion with system persistence fault ExecuteAndTimeout
--- PASS: TestSpeculaActivityTrace (0.80s)
    --- PASS: TestSpeculaActivityTrace/write_commit_response_timeout (0.80s)
PASS
ok  	go.temporal.io/server/tests	0.840s

seq=68 event=ApplyWorkflowMutationTx commitConfirmed=true activityInfos=0 bufferedEvents=2 tasks=6
seq=69 event=PersistenceResponseTimeout kind=ExecuteAndTimeout error=*persistence.TimeoutError
seq=70 event=LoseShardContext kind=ownership-uncertain-reacquisition-request error=*persistence.TimeoutError
seq=78 event=DeliverActivityResponse kind=Completed error=*serviceerror.DeadlineExceeded
seq=84 event=ReadWorkflowExecution label=after-injected-write activityInfos=0 bufferedEvents=2
seq=88 event=DeliverActivityResponse kind=Completed error=*serviceerror.NotFound
seq=134 event=FinishTrace terminalEvents=1 endpointComplete=true

{"scenario":"write_commit_response_timeout","sourceRevision":"0c010ce5fe8c0180aa7573c72fe8fc87c6df7025","terminal":"ActivityTaskCompleted","endpointComplete":true}
RESULT: temporary API/persistence disagreement observed; no consumer-visible wrong Activity outcome reproduced.
```

## Recommendation

Do not file CR-3 as a Temporal bug. Keep the regression coverage around ambiguous committed writes: committed completion must reload with no pending `ActivityInfo`, duplicate completion must return `NotFound`, and the workflow worker must receive exactly one terminal Activity event.

---

## Entry 4: Cancellation and terminal outcomes leave a Workflow Task obligation

- **Finding ID**: CR-4
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/api/update_workflow_util.go:80

## Description
CR-4 is not confirmed. The cited coalescing path intentionally skips creating a duplicate workflow task when one is already pending, but terminal activity events are buffered and then flushed into a follow-up workflow task after the held task completes.

## Trigger scenario
Level 0 public API sequence: start workflow, schedule and start an activity, request activity cancellation via `RequestCancelActivityTask`, verify heartbeat returns `CancelRequested=true`, signal and hold a started workflow task, then resolve the activity by completion, failure, cancellation acknowledgement, or start-to-close timeout while that workflow task is outstanding.

## Developer intent
`UpdateWorkflowWithNew` only schedules a workflow task when `!mutableState.HasPendingWorkflowTask()`. The intended companion behavior is buffered-event flushing in `workflow_task_state_machine.go:330-334`; existing activity tests also assert cancel-requested failure/timeout terminal behavior with `RETRY_STATE_CANCEL_REQUESTED`.

## Reproduction result
Repro test written and executed: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/repro/test_bugCR-4_workflow_task_obligation.sh`

Command:
```bash
timeout 12m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/repro/test_bugCR-4_workflow_task_obligation.sh
```

Output:
```text
CR4: post-terminal workflow task delivered kind=complete terminalEventID=16 followingWorkflowTaskScheduledID=17
CR4: workflow closed after consuming terminal outcome kind=complete
CR4: post-terminal workflow task delivered kind=fail terminalEventID=16 followingWorkflowTaskScheduledID=17
CR4: workflow closed after consuming terminal outcome kind=fail
CR4: post-terminal workflow task delivered kind=cancel terminalEventID=16 followingWorkflowTaskScheduledID=17
CR4: workflow closed after consuming terminal outcome kind=cancel
CR4: post-terminal workflow task delivered kind=timeout terminalEventID=16 followingWorkflowTaskScheduledID=17
CR4: workflow closed after consuming terminal outcome kind=timeout
--- PASS: TestBugCR4WorkflowTaskObligation (1.85s)
    --- PASS: TestBugCR4WorkflowTaskObligation/Level0CancelThenCompletion (0.12s)
    --- PASS: TestBugCR4WorkflowTaskObligation/Level0CancelThenFailure (0.07s)
    --- PASS: TestBugCR4WorkflowTaskObligation/Level0CancelThenCancelAck (0.08s)
    --- PASS: TestBugCR4WorkflowTaskObligation/Level0CancelThenStartToCloseTimeout (1.57s)
PASS
ok  	go.temporal.io/server/tests	1.892s
raw_log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-4/repro_bugCR-4_workflow_task_obligation.raw.log
```

## Recommendation
Do not file CR-4 as a bug. Keep the repro as regression coverage for the buffered terminal-event workflow-task coalescing path.

---

## Entry 5: Independent observations must cover the entire execution

- **Finding ID**: CR-5
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: tests/testcore/history_task_recorder.go:83

## Description

CR-5 is a real recorder/observation anomaly, but its live consequence is currently masked. `HistoryTaskRecorder.UpdateWorkflowExecution` records tasks only when the delegate returns `nil`, while Temporal’s `ExecuteAndTimeout` fault explicitly models a persistence operation that committed but returned timeout.

A recorder-only consumer can therefore miss tasks for a committed mutation. The current Specula Activity trace harness does not accept that lossy view as complete evidence: it emits independent readbacks and keeps `modelTraceComplete=false`.

## Trigger scenario

Level 0 healthy public Activity execution completed normally. Level 1 used the retained Temporal test-cluster path to exercise projection behavior and the `ExecuteAndTimeout` commit-response-timeout path. Level 2 isolated the recorder edge under that reachable committed-timeout precondition.

## Developer intent

PR #5869 intentionally added `ExecuteAndTimeout` to model “operation executed, caller got timeout”: https://github.com/temporalio/temporal/pull/5869. PR #11203 intentionally changed public retry interval projection behavior: https://github.com/temporalio/temporal/pull/11203.

Issue/PR searches for the exact CR-5 recorder/observation-completeness mechanism returned no duplicate report; `Novelty: NEW`.

## Reproduction result

Command:

```bash
timeout 20m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/repro/test_bugCR-5_trace_coverage.sh
```

Output:

```text
CR5 repro start
source_head=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
dirty_entries=34
LEVEL0_go_test=PASS log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-5/repro-output/current-20260911T061002Z-541027/logs/level0.healthy.go-test.log
LEVEL0_finish={"seq":125,"event":"FinishTrace","complete":false,"modelTraceComplete":false,"endpoint":true,"terminalCount":1,"finalAI":0,"buffered":0}
LEVEL0_result=healthy public activity execution completed; no committed-timeout fault occurred
LEVEL1_projection_unit_go_test=PASS log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-5/repro-output/current-20260911T061002Z-541027/logs/level1.projection-unit.go-test.log
LEVEL1_projection_public_go_test=PASS log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-5/repro-output/current-20260911T061002Z-541027/logs/level1.projection-public.go-test.log
LEVEL1_commit_timeout_go_test=PASS log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-5/repro-output/current-20260911T061002Z-541027/logs/level1.commit-timeout.go-test.log
LEVEL1_persistence_timeout={"seq":69,"event":"PersistenceResponseTimeout","kind":"ExecuteAndTimeout","delegateExecuted":true,"error":{"message":"fault injection error at UpdateWorkflowExecution with 1.00 rate: persistence.TimeoutError","type":"*persistence.TimeoutError"},"dbRecordVersion":7,"complete":false}
LEVEL1_activity_responses={"seq":78,"event":"DeliverActivityResponse","kind":"Completed","error":{"message":"fault injection error at UpdateWorkflowExecution with 1.00 rate: persistence.TimeoutError","type":"*serviceerror.DeadlineExceeded"},"complete":false};{"seq":88,"event":"DeliverActivityResponse","kind":"Completed","error":{"message":"invalid activityID or activity already timed out or invoking workflow is completed","type":"*serviceerror.NotFound"},"complete":false}
LEVEL1_after_fault_readback={"seq":79,"event":"ReadWorkflowExecution","activityInfos":0,"dbActivityInfos":0,"buffered":0,"complete":false}
LEVEL1_finish={"seq":132,"event":"FinishTrace","complete":false,"modelTraceComplete":false,"endpoint":true,"terminalCount":1,"finalAI":0,"buffered":0}
LEVEL1_evidence_complete_values=[null,false]
LEVEL2_recorder_go_test=PASS log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-5/repro-output/current-20260911T061002Z-541027/logs/level2.recorder.go-test.log
    cr5_history_task_recorder_EiDR0W_test.go:54: CR5_RECORDER_GAP reachable_precondition=ExecuteAndTimeout request_transfer_tasks=1 delegate_error=*persistence.TimeoutError recorder_transfer_tasks=0
LEVEL3_result=not_attempted; source patch would manufacture a symptom because Level1 reached the fault path and Level2 isolated the recorder-only observation gap
CR5_mask=Specula activity trace emits independent SQL/admin/public readbacks and every trace event carries evidence.complete=false; FinishTrace.modelTraceComplete=false, so the lossy recorder view is not accepted as a complete proof
CR5 repro end
```

## Recommendation

Do not treat `HistoryTaskRecorder` alone as complete task evidence under ambiguous persistence faults. Either record attempted writes with returned-error/uncertain-commit metadata, or reconcile recorder output against durable SQL/admin/public readbacks before accepting trace completeness.

---
