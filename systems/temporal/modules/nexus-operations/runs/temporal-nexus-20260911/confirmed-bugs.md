# Confirmation Report — temporal-nexus

## Final Result

Reproduced bugs: 3 = 3 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 1
Dropped: 1
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 5
Dispositions: 5 total = 3 reproduced + 0 env-limited + 0 masked + 1 false-positive + 0 needs-more-info + 1 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | CR-1 | REPRODUCED | yes |
| 2 | CR-2 | REPRODUCED | yes |
| 3 | CR-3 | DROPPED | no |
| 4 | CR-4 | REPRODUCED | yes |
| 5 | CR-5 | FALSE POSITIVE | no |

## Entry 1: Remote acceptance and local knowledge can advance independently

- **Finding ID**: CR-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/hsm/nexusoperations/completion.go:218

## Description
Confirmed at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Temporal reuses the scheduled Nexus operation `RequestId` across start retries, but once a later retry persists `OperationToken=token-2`, the HSM completion handler still accepts a callback carrying stale `operationToken=token-1` as long as the `RequestId` matches. The terminal `NEXUS_OPERATION_COMPLETED` event then records the stale callback result.

## Trigger scenario
Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**.
2. The HSM-level repro’s precondition maps to a real call sequence: workflow schedules Nexus operation, executor sends StartOperation with `RequestID`, endpoint accepts async `token-1`, the accepted response is lost before local save, retry sends the same `RequestID`, endpoint accepts async `token-2`, then the first async operation sends its normal callback with `token-1`.
3. Real consumer/caller: SDK workflow event handler `go.temporal.io/sdk@v1.48.0/internal/internal_event_handlers.go:2055-2087` reads the completed event result and invokes `state.completedCallback(result, err)`.
4. The bad state is **permanent**: the stale-token completion records a terminal success event and no downstream sync/loopback/resend path rewrites the result.

## Developer intent
The Nexus SDK documents `RequestID` as usable by handlers for deduplication, and Temporal’s workflow-backed Nexus helpers explicitly note that start requests may be retried. Duplicate remote start effects still depend on endpoint idempotency, but Temporal locally knows the persisted async operation token after the retry and should not accept a conflicting stale-token callback for the same request ID.

## Reproduction result
Wrote and executed:
`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/repro/test_bugCR-1_lost_start_response.sh`

```text
CR-1 repro source revision: 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
CR-1 repro command: timeout 10m go test -count=1 -run TestCR1LostAcceptedStartResponseAcceptsStaleDuplicateCompletion ./service/history/hsm/nexusoperations -v
=== RUN   TestCR1LostAcceptedStartResponseAcceptsStaleDuplicateCompletion
    cr1_lost_start_response_test.go:57: endpoint accepted StartOperation request_id=d6d09770-7524-4a43-87bb-497b16b58e62 operation_token=token-1
    cr1_lost_start_response_test.go:154: Temporal treated the accepted first response as lost and moved to BACKING_OFF request_id=d6d09770-7524-4a43-87bb-497b16b58e62
    cr1_lost_start_response_test.go:57: endpoint accepted StartOperation request_id=d6d09770-7524-4a43-87bb-497b16b58e62 operation_token=token-2
    cr1_lost_start_response_test.go:180: retry persisted local STARTED with request_id=d6d09770-7524-4a43-87bb-497b16b58e62 operation_token=token-2
    cr1_lost_start_response_test.go:200: control rejected mismatched completion request_id=wrong-d6d09770-7524-4a43-87bb-497b16b58e62 operation_token=token-1
    cr1_lost_start_response_test.go:221: completion accepted request_id=d6d09770-7524-4a43-87bb-497b16b58e62 callback_operation_token=token-1 while persisted_operation_token=token-2 result=completed-by-token-1
--- PASS: TestCR1LostAcceptedStartResponseAcceptsStaleDuplicateCompletion (0.01s)
PASS
ok  	go.temporal.io/server/service/history/hsm/nexusoperations	0.034s
```

## Recommendation
When an operation is already started and `operation.OperationToken` is non-empty, reject or ignore completions whose callback `operationToken` does not match the persisted token. Preserve the current callback-before-start behavior by only using the callback token to fabricate `NEXUS_OPERATION_STARTED` when no local token has been persisted yet. Add a regression test for lost accepted start response, retry with same `RequestId`, and late stale-token completion.

---

## Entry 2: Deferred cancellation can omit an independently required timer

- **Finding ID**: CR-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/hsm/nexusoperations/statemachine.go:384

## Description

Confirmed. `TransitionStarted` sets `StartedTime`, detects an existing cancellation child, and returns the nested cancellation transition before appending the parent operation’s `StartToCloseTimeoutTask`. Normal HSM task generation persists only the returned transition tasks, so the operation can remain `STARTED` with cancellation `SUCCEEDED` but with zero persisted HSM timer groups.

## Trigger scenario

A public workflow starts a Nexus operation with `StartToCloseTimeout=4s`. The external Nexus start handler is held open long enough for the workflow to request cancellation first. When the handler is released, the operation records `STARTED`, delivers the deferred cancel request, receives cancel acknowledgment, and then remains running past its start-to-close deadline.

## Developer intent

Cancellation acknowledgment is not operation completion: `service/history/hsm/nexusoperations/executors.go:947` explicitly notes that after cancel delivery the operation may still complete normally or by callback. The independent start-to-close timer is therefore still required. Existing upstream work covers nearby cases, including temporalio/temporal#6483 and temporalio/temporal#9153, but issue/PR searches did not find this exact deferred-cancel plus start-to-close timer omission mechanism.

## Reproduction result

Repro written and executed:

`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/repro/test_bugCR-2_deferred_cancel_start_to_close.sh`

Command:

```bash
timeout 11m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/repro/test_bugCR-2_deferred_cancel_start_to_close.sh
```

Key captured output:

```text
=== RUN   TestBugCR2DeferredCancellationOmitsStartToCloseTimer
    cr2_deferred_cancel_start_to_close_repro_test.go:106: event_order_before_start=NexusOperationScheduled(5), NexusOperationCancelRequested(next), NexusOperationStarted(blocked)
    cr2_deferred_cancel_start_to_close_repro_test.go:152: state_after_cancel_ack=STARTED cancellation=SUCCEEDED persisted_hsm_timer_groups=0 timer_types=[]
    cr2_deferred_cancel_start_to_close_repro_test.go:158: past_deadline_without_refresh=5s timeout_event_present=false workflow_status=Running
    cr2_deferred_cancel_start_to_close_repro_test.go:177: after_explicit_refresh_timeout_event_present=true timeout_type=StartToClose
--- PASS: TestBugCR2DeferredCancellationOmitsStartToCloseTimer (6.11s)
PASS
ok  	go.temporal.io/server/tests	6.157s
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes**. This used Level 1 timing assistance only: public workflow APIs plus a real Nexus handler delayed the start response. No state injection or source patch was used.
2. Level 2/3 precondition: not applicable.
3. Real consumer/caller observing wrong outcome: `service/history/workflow/task_generator.go:297` consumes the transition output and persists no state-machine timer; later timer processing at `service/history/timer_queue_task_executor_base.go:308` has no persisted timer group to execute. The public `DescribeWorkflowExecution` observation remained `Running` past the deadline.
4. Permanent or masked? Ordinary execution did not resolve it during the elapsed deadline window. Explicit admin `RefreshWorkflowTasks` later regenerated the missing `StateMachineTimer` and caused the timeout, so refresh is a repair/masking path, not an automatic safeguard.

## Recommendation

Combine the parent and child transition outputs in `TransitionStarted`: when a deferred cancellation child exists, still append the operation’s `startToCloseTimeoutTask()` before returning. Add a regression test for cancel-before-started plus start-to-close timeout that asserts the timer is persisted and the timeout fires without requiring `RefreshWorkflowTasks`.

---

## Entry 3: Live terminal transition and reconstruction reclaim different capacity

- **Finding ID**: CR-3
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/temporalio/temporal/pull/7128; fix-status: unfixed)
- **Location**: service/history/hsm/nexusoperations/executors.go:657

## Description
The live Nexus timeout executor records `NEXUS_OPERATION_TIMED_OUT` and transitions the operation to `TimedOut`, but does not delete the HSM operation node. Scheduling later counts physical HSM collection size, while Describe filters terminal nodes from pending output, so a timed-out operation can consume capacity while user-visible pending operations is zero.

This exact terminal-node cleanup defect was already publicly reported in Temporal PR #6984/#7128: terminal Nexus operation nodes could linger and cause premature workflow task failures. The current pinned target still reproduces the live timeout residual, so the known fix status for this target is `unfixed`.

## Trigger scenario
1. Schedule one Nexus operation.
2. Let the normal HSM timeout executor process its schedule-to-close timeout.
3. The operation reaches `TimedOut`, but its HSM node remains.
4. With `MaxConcurrentOperations=1`, schedule a second Nexus operation.
5. The second schedule fails with `PendingNexusOperationsLimitExceeded`.
6. Describe reads the same HSM tree but returns zero pending Nexus operations.

## Developer intent
Upstream PR #7128 says terminal Nexus operation nodes should be removed after completed/failed/canceled/timed-out states to avoid confusion, wasted resources, and premature workflow task failures. Later PR #7177 adjusted deletion for state-based replication. Current code applies deletion on terminal event replay/application, but the live timeout executor path still only transitions and records the event.

## Reproduction result
Reproducer written and executed:

`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/repro/test_bugCR-3_nexus_timeout_capacity.sh`

Command:

```bash
timeout 12m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/repro/test_bugCR-3_nexus_timeout_capacity.sh
```

Output:

```text
[CR-3] running live timeout capacity repro
=== RUN   TestCR3LiveTimeoutNodeConsumesPendingCapacity
CR3_CAPACITY_EVIDENCE after_live_timeout_state=TimedOut physical_count=1 second_schedule_cause=PendingNexusOperationsLimitExceeded message="workflow has reached the pending nexus operation limit of 1 for this namespace"
--- PASS: TestCR3LiveTimeoutNodeConsumesPendingCapacity (0.00s)
PASS
ok  	go.temporal.io/server/service/history/hsm/nexusoperations/workflow	0.030s
[CR-3] running describe visibility repro
=== RUN   TestCR3DescribeHidesTimedOutNodeRetainedByLiveTimeout
CR3_DESCRIBE_EVIDENCE retained_state=TimedOut physical_count=1 describe_pending=0
--- PASS: TestCR3DescribeHidesTimedOutNodeRetainedByLiveTimeout (0.00s)
PASS
ok  	go.temporal.io/server/service/history/api/describeworkflow	0.029s
```

## Recommendation
Make live terminal timeout cleanup consistent with terminal event replay: delete the Nexus operation node when the live timeout transition is durably committed, or change admission accounting to count only non-terminal operation nodes. Add a regression test that schedules at limit one, times out the operation through the live executor, verifies Describe pending count, and then schedules another operation.

---

## Entry 4: Deadline selection, queued work and stale references interact

- **Finding ID**: CR-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `service/history/hsm/nexusoperations/workflow/commands.go:205`

## Description
`MaxOperationScheduleToCloseTimeout` promises to cap Nexus operations that specify no schedule-to-close timeout, but `HandleScheduleCommand` only caps when `opTimeout > maxTimeout`. With no workflow run timeout and omitted `ScheduleToCloseTimeout`, `opTimeout == 0`, so the cap is bypassed and no schedule-to-close timer is generated.

## Trigger scenario
Set `component.nexusoperations.limit.scheduleToCloseTimeout=1m`; schedule a Nexus operation from a workflow with no workflow run timeout and omit `ScheduleToCloseTimeout`. The scheduled event persists `0s`, and `Operation.RegenerateTasks` returns only `nexusoperations.Invocation`, not `nexusoperations.Timeout`.

## Developer intent
`config.go:109-111` says commands with no schedule-to-close timeout should be capped. PR #6147 introduced the limit for operational flexibility. Searches of upstream issues and recently merged/closed PRs found no existing report/fix for this exact omitted-timeout bypass.

## Reproduction result
Test written and executed: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/repro/test_bugCR-4_schedule_to_close_limit.sh`

Command:
```bash
timeout 12m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/repro/test_bugCR-4_schedule_to_close_limit.sh
```

Output:
```text
BUG_TRIGGERED: omitted schedule-to-close persisted as 0s despite max 1m0s
BUG_TRIGGERED: regenerated task types are [nexusoperations.Invocation], so no nexusoperations.Timeout timer will enforce the configured max
PASS
ok  	go.temporal.io/server/service/history/hsm/nexusoperations/workflow	0.031s
```

Checklist:
1. Level 0/1 alone triggered it: yes, Level 0 normal `ScheduleNexusOperation` command handling; no failpoints, state injection, or source patch.
2. Level 2/3 used: no.
3. Real consumer/caller observing wrong outcome: HSM task regeneration at `service/history/hsm/nexusoperations/statemachine.go:172`; the timer executor at `executors.go:625` never receives a schedule-to-close timeout task.
4. Bad state permanence/mask: no downstream mechanism enforces the configured max when workflow run timeout is absent. A workflow run timeout masks this only when configured.

## Recommendation
Change the max-cap condition to treat omitted schedule-to-close as cap-worthy when `maxTimeout > 0`, then add a regression test for omitted timeout with no workflow run timeout.

---

## Entry 5: Buffered history, uncertain commit and notification must agree after reload

- **Finding ID**: CR-5
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/hsm/nexusoperations/workflow/commands.go:268

## Description
CR-5 does not reproduce as a durable inconsistency. The committed-but-timeout completion path reloads to a coherent state: buffered `NexusOperationCompleted` is present, the terminal HSM operation is deleted, and a later real cancel command is accepted and ordered before the buffered completion.

The key guard is `HasAnyBufferedEvent(...)` in `commands.go:268`, with the replay-preserving cancel event behavior at `commands.go:302`.

## Trigger scenario
I added and executed:

`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/repro/test_bugCR-5_buffered_completion_execute_timeout_reload.sh`

The test uses normal frontend/history APIs plus the existing persistence fault hook: schedule async Nexus operation, hold the workflow task, send completion callback, inject `ExecuteAndTimeout` on the buffered completion `UpdateWorkflowExecution`, close/reload shard, then complete the held workflow task with `RequestCancelNexusOperation`.

## Developer intent
The implementation intentionally allows cancel after a just-buffered terminal Nexus event so SDK replay still sees the cancel-request command before buffered completion flush. Existing nearby unit/functional coverage also targets this intent; the new repro adds the missing uncertain-commit and shard-reload boundary.

## Reproduction result
```text
=== RUN   TestNexusWorkflowTestSuiteHSM
=== RUN   TestNexusWorkflowTestSuiteHSM/TestBugCR5BufferedCompletionExecuteTimeoutReloadThenCancel
    bug_cr5_test.go:95: CR5 workflow started: workflowID=8e70e31b-a630-4590-87e3-86b214ffee48 runID=01a0920e-2afa-7c2c-b7bf-7dae1e71b6df
    bug_cr5_test.go:199: CR5 polled workflow task schedule: historyEvents=3
    bug_cr5_test.go:220: CR5 RespondWorkflowTaskCompleted(schedule) succeeded with 1 command(s)
    bug_cr5_test.go:83: CR5 external endpoint accepted start: service=service operation=operation requestID=5878e67b-faf5-4cf6-ae2a-982d0b561914
    bug_cr5_test.go:119: CR5 operation scheduled and started: scheduledEventID=5 startedEventID=6
    bug_cr5_test.go:199: CR5 polled workflow task hold-started-event: historyEvents=8
    bug_cr5_test.go:64: CR5 injected ExecuteAndTimeout on buffered Nexus completion: dbRecordVersion=7 rangeID=1 bufferedEvents=1 deleteChasmNodes=0
    bug_cr5_test.go:134: CR5 callback caller observed expected uncertain error: *nexus.HandlerError: handler error (UPSTREAM_TIMEOUT): request timeout
    bug_cr5_test.go:261: CR5 DescribeMutableState(after-callback-execute-timeout-and-shard-close): dbBuffered=1 dbHSMOperations=0
    bug_cr5_test.go:141: CR5 reload readback after uncertain commit: bufferedEvents=-123:NexusOperationCompleted hsmOperationCount=0
    bug_cr5_test.go:220: CR5 RespondWorkflowTaskCompleted(cancel-after-reload) succeeded with 1 command(s)
    bug_cr5_test.go:261: CR5 DescribeMutableState(after-cancel-command-flush): dbBuffered=0 dbHSMOperations=0
    bug_cr5_test.go:171: CR5 final history converged: cancelRequestedEventID=10 completedEventID=11 pendingNexusOperations=0 nexusEvents=5:NexusOperationScheduled -> 6:NexusOperationStarted -> 10:NexusOperationCancelRequested -> 11:NexusOperationCompleted
--- PASS: TestNexusWorkflowTestSuiteHSM (0.00s)
PASS
ok  	go.temporal.io/server/tests	0.165s
```

## Recommendation
Do not report CR-5 as a bug. The suspicious boundary is handled by existing buffered-event and shard-reload logic. Keeping the focused repro as regression coverage would be reasonable.

---
