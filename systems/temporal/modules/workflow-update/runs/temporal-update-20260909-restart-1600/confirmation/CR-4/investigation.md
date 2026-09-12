# CR-4 Investigation

## Scope

- Source: Code Review
- Finding: CR-4, volatile deduplication must retain a delivery or retry path
- Repository: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/confirmation/CR-4/worktree`
- Checked revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`
- Reproduction test: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/repro/test_bugCR-4_volatile_dedup_callbacks_test.go`
- Reproduction output: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/repro/test_bugCR-4_volatile_dedup_callbacks.out`

## Source Evidence

- `service/history/api/updateworkflow/api.go:163` finds or creates the volatile Update object by update ID; `api.go:166` admits the request; `api.go:173` attaches callbacks.
- `service/history/api/updateworkflow/api.go:177-182` returns after attaching callbacks without creating a new workflow task. This is valid only if the existing delivery path remains able to reach a terminal outcome.
- `service/history/workflow/update/update.go:416-438` buffers duplicate completion callbacks in memory while the update is in `stateSent`.
- `service/history/workflow/update/update.go:425-426` states the intended recovery assumption: if the Update struct is lost, registry-clear abort should prompt retry.
- `service/history/workflow/update/update.go:751-757` makes `reject()` return an internal error if pending `AttachCallbacks` callbacks still exist.
- `service/history/workflow/update/registry.go:298-319` implements `RejectUnprocessed`. At `registry.go:311-313`, an error from `upd.reject(unprocessedUpdateFailure, effects)` is swallowed by returning nil.
- `service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:257-275` calls `RejectUnprocessed` when a non-heartbeat workflow task completes without processing sent update messages and documents the postcondition that no sent updates should remain.
- `service/history/workflow/update/registry.go:330-360` can resend already-sent updates on later workflow tasks, so the stuck state is redelivered rather than terminally rejected.

## Developer Intent

The architecture document says unaccepted updates remain in memory until accepted, but `RejectUnprocessed()` is one of the paths expected to resolve accepted/completed waiters as rejected:

- `docs/architecture/workflow-update.md:31-49`: rejected updates leave no durable history event; the update request remains in memory until the first accepted event.
- `docs/architecture/workflow-update.md:252-270` and `271-292`: `RejectUnprocessed()` should resolve waiters as rejected for both accepted-stage and completed-stage callers.
- `docs/architecture/workflow-update.md:307-318`: a returned `ADMITTED` stage means the client should retry; registry clear returns retryable unavailable semantics.

The source-level implementation breaks that intent when duplicate callback attachment has buffered `pendingCallbacks` in `stateSent`: the worker's unprocessed completion reaches `RejectUnprocessed`, `reject()` refuses to run, the error is discarded, no warning IDs are produced, and the update remains in `stateSent`.

## Novelty Search

Searched upstream issues and pull requests, including open/closed issue search terms:

- `pendingCallbacks RejectUnprocessed`
- `UnprocessedUpdate completion callbacks`
- `workflow update completion callbacks ADMITTED`
- `callback RejectUnprocessed`

Also reviewed recent merged PR search results for callback/update terms and affected-file git history. No upstream issue or recently merged/closed PR was found for this exact mechanism: `stateSent` duplicate callback buffering prevents `RejectUnprocessed` from delivering `UnprocessedUpdate` and leaves same-ID retries at `ADMITTED`.

Adjacent but different records:

- temporalio/temporal#10478: speculative WFT shard ownership may cause incorrect update rejections.
- temporalio/temporal#10775: direct matching speculative WFT path lacks behavior present in transfer queue.
- temporalio/temporal#11254: open PR for duplicate callbacks in `stateAdmitted`, not this `stateSent` `RejectUnprocessed` path.
- temporalio/temporal#9614: merged callback support introduced workflow update completion callbacks and notes speculative update risk.

Raw novelty evidence is saved in `novelty-search.md`.

## Reproduction

Level: Level 1. The repro uses Temporal's public frontend APIs and normal test cluster operations, with timing/configuration assistance only:

- public `StartWorkflowExecution`
- public `PollWorkflowTaskQueue`
- public `UpdateWorkflowExecution`
- public `RespondWorkflowTaskCompleted`
- public `PollWorkflowExecutionUpdate`
- `HistoryLongPollExpirationInterval=300ms` to make ADMITTED soft timeouts fast
- callback feature gates and callback allowed-address config

The test does not patch source, inject unreachable state, or mock an impossible peer message. It simulates an old or buggy worker by completing a workflow task without protocol messages after receiving an update message, which is exactly the path handled by `rejectUnprocessedUpdates`.

Command executed:

```bash
REPRO=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/repro
export GOTMPDIR="$REPRO/tmp"
export GOCACHE="$REPRO/gocache"
timeout 12m go test -tags=test_dep -run 'TestBugCR4' -count=1 -v
```

Result: passed. The bug test shows the original caller and same-ID retries repeatedly receive `ADMITTED` with no outcome after the worker completed the task without processing the update. The healthy control, without duplicate callback attachment, receives a terminal `Completed` response with `UnprocessedUpdate`.

Key output:

```text
LEVEL1_SENT update_id=TestBugCR4VolatileDedupCallbackPreventsUnprocessedTerminal_update_id message_id=TestBugCR4VolatileDedupCallbackPreventsUnprocessedTerminal_update_id/request event_id=5
LEVEL1_DUPLICATE_CALLBACK stage=Admitted outcome=<nil>
BUG_TRIGGERED original caller saw stage=Admitted outcome=<nil> after worker completed without processing the update
REDELIVERY_1 update_id=TestBugCR4VolatileDedupCallbackPreventsUnprocessedTerminal_update_id message_id=TestBugCR4VolatileDedupCallbackPreventsUnprocessedTerminal_update_id/request event_id=8
STILL_STUCK_1 same-ID retry stage=Admitted outcome=<nil>
REDELIVERY_2 update_id=TestBugCR4VolatileDedupCallbackPreventsUnprocessedTerminal_update_id message_id=TestBugCR4VolatileDedupCallbackPreventsUnprocessedTerminal_update_id/request event_id=11
STILL_STUCK_2 same-ID retry stage=Admitted outcome=<nil>
MANUAL_CACHE_CLEAR_RECOVERY stage=Completed failure_type=UnprocessedUpdate
CONTROL_OK stage=Completed failure_type=UnprocessedUpdate
PASS
ok  	temporal-cr4-repro	1.158s
```

## Conclusion

CR-4 is reproduced. The real public API caller observes a non-terminal `ADMITTED` response after an unprocessed workflow-task completion that should have rejected the sent update. Same-ID public retries do not repair the state while the volatile registry remains in memory; the system keeps redelivering the sent update. Manual shard/cache clear aborts the volatile registry and allows a retry to reach the expected `UnprocessedUpdate`, so cache loss is a recovery mechanism, not the primary trigger.
