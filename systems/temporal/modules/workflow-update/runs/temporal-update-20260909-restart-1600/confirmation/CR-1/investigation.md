# CR-1 Investigation

## Revision

- Temporal source revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.
- Source classification: Code Review.

## Novelty search

Checked upstream issues and recently merged/closed PRs for this specific mechanism:

- `Workflow Update registry cleared update result`
- `UpdateWorkflowExecution ExecuteAndTimeout`
- `Workflow Update lost response`
- `Workflow Update after commit before response`
- `Workflow Update persistence write caller result`
- `Workflow Update registry cleared`
- `UpdateWorkflowExecution lost response ExecuteAndTimeout`

No exact upstream report or recently merged fix was found for stale per-host `HistoryEvent` cache returning an `UpdateCompleted` event for a different update ID after noncommitted completion and same event-ID reuse. Adjacent but non-identical context checked: temporalio/temporal#10478, #10775, #11254, #5349, #5784, and #6308.

## Code evidence

- `common/persistence/sql/execution.go:335-372` appends history nodes before the execution-state and task transaction.
- `common/persistence/cassandra/execution_store.go:110-125` follows the same high-level ordering: append history nodes, then update mutable state and tasks.
- `service/history/api/respondworkflowtaskcompleted/api.go:250-263` creates an effect buffer and defers cancellation on handler error.
- `service/history/api/respondworkflowtaskcompleted/api.go:688-733` cancels effects on persistence error and applies effects only after a successful persistence call.
- `common/effect/buffer.go:8-55` makes apply and cancel separate in-memory callback phases.
- `service/history/workflow/update/store.go:24-29` states that event-store writes may return before the data is durable and callbacks must run after commit or rollback.
- `service/history/workflow/mutable_state_impl.go:1544-1588` loads durable update completion metadata for the requested update ID, then retrieves a cached history event by namespace/workflow/run/event ID/version and checks only that the event type is `WorkflowExecutionUpdateCompleted`.
- `service/history/workflow/mutable_state_impl.go:2086-2102` writes workflow events into the host event cache with an event key that excludes update ID.
- `service/history/events/cache.go:111-125` and `service/history/events/cache.go:149-160` return and store events by that event key.
- `service/history/workflow/update/registry.go:463-488` delegates completed update lookup to `store.GetUpdateOutcome`.
- `service/history/api/pollupdate/api.go:45-64` is the real public consumer: `PollWorkflowExecutionUpdate` calls the update registry lookup and then waits for or returns the found update outcome.
- `tests/testcore/onebox.go:241-244` prevents exercising the necessary multi-history-host divergence in the local functional harness because each service must have exactly one node.

## Reproduction

Added and executed:

- `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/repro/test_bugCR-1_update_commit_recovery.sh`
- `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/confirmation/CR-1/worktree/service/history/workflow/cr1_stale_update_cache_test.go`
- `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/confirmation/CR-1/worktree/cr1repro/cr1_repro_test.go`

Executed command:

```sh
cd /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/repro
./test_bugCR-1_update_commit_recovery.sh
```

The wrapper exited 0 and preserved full logs in `cr1_state_cache.log` and `cr1_public_controls.log`.

Compact output:

```text
FULL_LOG=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/repro/cr1_state_cache.log
=== RUN   TestBugCR1GetUpdateOutcomeAcceptsCachedEventForDifferentUpdateID
    cr1_stale_update_cache_test.go:112: STALE_CACHE_RESULT requested_update_id=cr1-update-b cached_event_update_id=cr1-update-a observed=stale-result-from-cr1-update-a
    cr1_stale_update_cache_test.go:117: STATE_INJECTION_NOTE: this is not a public end-to-end trigger; it is the exact stale per-host cache state required after a noncommitted completion on one host and a same-event-id commit on another host
--- PASS: TestBugCR1GetUpdateOutcomeAcceptsCachedEventForDifferentUpdateID (0.00s)
PASS
ok  	go.temporal.io/server/service/history/workflow	0.028s
FULL_LOG=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/repro/cr1_public_controls.log
=== RUN   TestBugCR1CommittedUpdateSurvivesLostCallerReceipt
    cr1_repro_test.go:56: CALLER_RECEIPT_LOST update_id=TestBugCR1CommittedUpdateSurvivesLostCallerReceipt_update_id error=*serviceerror.Unavailable:CR-1: committed Update response lost after handler returned success
    cr1_repro_test.go:61: RECOVERY_AFTER_LOST_RECEIPT update_id=TestBugCR1CommittedUpdateSurvivesLostCallerReceipt_update_id stage=Completed outcome=success:{payloads:{metadata:{key:"encoding" value:"json/plain"} data:"\"success-result-of-TestBugCR1CommittedUpdateSurvivesLostCallerReceipt_update_id\""}}
--- PASS: TestBugCR1CommittedUpdateSurvivesLostCallerReceipt (0.10s)
=== RUN   TestBugCR1OneHostNoncommittedCompletionDoesNotLeakToNextUpdate
    cr1_repro_test.go:104: FIRST_CALLER_CANCELLED update_id=TestBugCR1OneHostNoncommittedCompletionDoesNotLeakToNextUpdate_update_id_1 error=*serviceerror.Canceled:context canceled
    cr1_repro_test.go:79: NONCOMMITTING_STORE_FAULT next_event_id=10 range_id=1 update_infos=map[TestBugCR1OneHostNoncommittedCompletionDoesNotLeakToNextUpdate_update_id_1:completion:{event_id:9 event_batch_id:7} last_update_versioned_transition:{transition_count:4}]
    cr1_repro_test.go:112: FIRST_COMPLETION_ROLLED_BACK update_id=TestBugCR1OneHostNoncommittedCompletionDoesNotLeakToNextUpdate_update_id_1 error=*serviceerror.ResourceExhausted:CR-1: completion event reached cache before execution mutation was submitted
    cr1_repro_test.go:126: READBACK_AFTER_ROLLBACK update_id=TestBugCR1OneHostNoncommittedCompletionDoesNotLeakToNextUpdate_update_id_1 update_info_present=false next_event_id=5
    cr1_repro_test.go:140: SECOND_UPDATE_COMMITTED update_id=TestBugCR1OneHostNoncommittedCompletionDoesNotLeakToNextUpdate_update_id_2 outcome=success:{payloads:{metadata:{key:"encoding" value:"json/plain"} data:"\"success-result-of-TestBugCR1OneHostNoncommittedCompletionDoesNotLeakToNextUpdate_update_id_2\""}}
    cr1_repro_test.go:145: SAME_HOST_RECOVERY_MASK update_id=TestBugCR1OneHostNoncommittedCompletionDoesNotLeakToNextUpdate_update_id_2 observed=success-result-of-TestBugCR1OneHostNoncommittedCompletionDoesNotLeakToNextUpdate_update_id_2 note=the later successful completion overwrote the host-level event-cache slot before readback
--- PASS: TestBugCR1OneHostNoncommittedCompletionDoesNotLeakToNextUpdate (0.12s)
PASS
ok  	go.temporal.io/server/cr1repro	0.260s
```

## Assessment

The investigation confirms the architectural premise that the persistence call result, effect publication, and caller receipt are different events. A committed update can lose the original caller response, but public polling recovers the durable result. A completion event can also reach the event cache before the execution mutation is submitted, and the failed write rolls back the durable update state.

The state-level test confirms a concrete missing guard: `GetUpdateOutcome` can return a cached `WorkflowExecutionUpdateCompleted` event for a different update ID when durable `UpdateInfo` for update B points at an event key whose per-host cache still contains update A. That is not a public end-to-end reproduction because the injected stale cache precondition was not reached through the local public API harness.

The public one-host functional reproduction did not expose a wrong outcome. In that environment, the later successful completion overwrites the same host-level event-cache slot before public readback. The plausible production trigger requires history-host/cache divergence: one host observes and caches a noncommitted completion for update A, another host commits update B using the reused event ID, and the first host later serves `PollWorkflowExecutionUpdate` for B from its stale cache. The local `testcore` onebox harness blocks that final public trigger because it supports only one host per service.

## Verdict

ENV_LIMITED
