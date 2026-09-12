# Temporal: Activity Attempts, Timers, and Durable Recovery

## Goal

Build a reusable, implementation-grounded formal model of ordinary Workflow Activity execution, and establish its fidelity through complete real execution traces and meaningful bounded verification.
Apply sustained effort to the difficult transition, observation, and recovery boundaries. Within each assigned phase, resolve feasible modeling and harness problems, preserve evidence for the next phase, and measure success by the validated behavior and explicit coverage achieved.

## Scope and boundary

- Target `temporalio/temporal` at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; record the actual revision, backend, and relevant feature settings.
- Focus on ordinary Activities belonging to a Workflow Run in a single cluster: scheduling/start, attempt identity, completion/failure, retry, timeout, heartbeat, cancellation, persistence, and recovery.
- Establish and validate the ordinary lifecycle before extending the same investigation to pause/unpause, ResetActivity, or ByID operations. Record each extension's distinct contract and validation status.
- Exclude standalone CHASM Activities, ResetWorkflow/Continue-As-New interactions, multi-cluster replication, worker-version routing policies, and Matching queue internals. Follow their interfaces only as needed to establish the Activity contract.

## Prioritized questions

1. When an earlier attempt's completion, failure, heartbeat, or cancellation acknowledgement arrives after a retry has begun, how does the server determine whether it still applies? Can permitted message ordering change the wrong attempt or produce incompatible terminal observations? Follow the complete token/start validation and response paths.
2. When timeout processing overlaps a heartbeat, retry backoff, task delivery, or completion, does the Activity retain the retry or termination path required by its policy and deadlines? Distinguish ScheduleToStart, StartToClose, ScheduleToClose, and Heartbeat semantics, including duplicate or delayed timer execution.
3. When a write is rejected, commits with a lost response, or is followed by cache/shard loss, do subsequent retry and readback agree with the acknowledged Activity outcome and the work required to resume its Workflow? Establish which state and generated tasks commit together and which observations occur later.
4. When cancellation competes with completion or timeout, which outcomes are permitted, and does that decision survive recovery consistently? Follow cancellation while scheduled, while running, and while waiting for retry; establish how the request becomes visible to the worker.

## Interactions that must be followed

- Follow worker-facing start/result/heartbeat APIs through token checks, ActivityInfo mutation, retry decisions, timer/task generation, execution persistence, response delivery, and the resulting Workflow Task obligation.
- Follow retry dispatch through lease release, Matching, and History's task-start validation. Preserve checks at both sides of that handoff and distinguish task delivery from a durably accepted start.
- Relate in-memory ActivityInfo, persisted Mutable State, logical History events, and pending timer/retry work across reload. Explain any shared persistence or identity contract that could later be reused by other Temporal models.

## Caller, environment, and fault assumptions

- Activity execution may repeat external side effects. Cancellation is a request, and pausing a running Activity can permit it to finish; establish the selected API's actual completion contract.
- Retry-policy starts can persist in Mutable State before a corresponding Started event appears in History. History alone is insufficient to establish the intermediate execution state.
- Preserve backend transactions and ownership conditions. Separate definitely uncommitted writes from uncertain outcomes and establish the actual durable result independently of the returned error.
- Use the configured attempt/stamp/version behavior, including `system.enableActivityRetryStampIncrement`; distinguish ordinary token operations from ByID and administrative operations.
- State the time-advance, worker, queue, storage-recovery, and retry-policy conditions required for progress. Deliberately paused work and asynchronous timer delay have different obligations from eligible work with a healthy environment.

## Evidence and completion requirements

- Address every priority question and explore adjacent implementation-derived questions within this boundary. Complete a calibrated core before enlarging the scope.
- Reuse real Activity functional tests and persistence paths. Capture the modeled state from independent implementation observations, including ActivityInfo and durable task/transaction outcomes; establish an unambiguous ordering for relevant concurrent observations.
- Validate complete healthy and failure/recovery scenarios, with controls that demonstrate rejection of inconsistent attempt identity or durable state. Diagnose missing observations and model disagreements; do not fill missing implementation state from a desired model successor or count a passing prefix as a complete trace.
- Preserve commands, source/configuration identity, traces, readbacks, and verification results. Distinguish cache reload, shard reacquisition, process restart, and database restart according to what actually ran.
- Complete a meaningful bounded baseline, then investigate additional schedules within the allocated resources. Report bounds, assumptions, completed checks, observed outcomes, and exact remaining gaps; retain `INCOMPLETE` for unfinished work.

## Source entry points

- `service/history/api/activity_util.go:IsActivityTaskNotFoundForToken`; `service/history/api/recordactivitytaskstarted/api.go`; `service/history/api/respondactivitytaskcompleted/api.go`; `service/history/api/respondactivitytaskfailed/api.go`; `service/history/api/respondactivitytaskcanceled/api.go`; `service/history/api/recordactivitytaskheartbeat/api.go`.
- `service/history/workflow/mutable_state_impl.go:RetryActivity` and `AddActivityTaskStartedEvent`; `service/history/workflow/task_generator.go`; `service/history/workflow/timer_sequence.go`.
- `service/history/timer_queue_active_task_executor.go:executeActivityTimeoutTask` and `executeActivityRetryTimerTask`; `service/history/transfer_queue_active_task_executor.go:processActivityTask`; `service/history/workflow/context.go` and the implicated persistence implementation.
- `tests/activity_test.go`, `tests/testcore/test_env.go`, and `common/persistence/faultinjection/fault.go`; for validated-core extensions, `service/history/workflow/activity.go`, `tests/activity_api_pause_test.go`, and `tests/activity_api_reset_test.go`.

## User-requested continuation — 2026-09-11

Continue the existing validation session and retained artifacts. The requested modeling work remains unfinished; actively implement the missing work instead of ending with another inventory of the same gaps.
- Read the existing validation review and handoff, then implement the independent state projector and missing observation boundaries. First obtain a complete real healthy replay; then extend to the retained failure/recovery scenarios and negative controls. Repair the physical timer/logical deadline, invocation/append, and durable acquisition/local readiness distinctions identified in the review.
- Preserve independent implementation evidence, complete-state comparisons, and the original scope. Never fabricate missing state from model successors or weaken the checks to obtain a pass. If one implementation approach stalls, diagnose it and try another concrete approach within the existing resources.
- Reuse prior analysis, source reading, builds, and valid tests. Recollect or rerun only what changed or what is needed to close an identified gap; keep progress updates short.
- Continue into meaningful bounded model checking after full trace calibration. If a search is too large, use justified decomposition or a documented additional time budget while retaining the original incomplete result and explicit coverage limits. Do not repeat an unchanged timed-out search without addressing its cause.
- Report an external blocker if one actually prevents further work. The current missing projector and known model disagreements are implementation work to pursue, not sufficient reasons to stop this continuation.
