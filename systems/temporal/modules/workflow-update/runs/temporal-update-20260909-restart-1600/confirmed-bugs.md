# Confirmation Report — temporal-update

## Final Result

Reproduced bugs: 2 = 2 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 1
False positives: 0
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 4
Dispositions: 4 total = 2 reproduced + 1 env-limited + 1 masked + 0 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | CR-1 | ENV_LIMITED | no |
| 2 | CR-2 | MASKED | no |
| 3 | CR-3 | REPRODUCED | yes |
| 4 | CR-4 | REPRODUCED | yes |

## Entry 1: A write result, published effect, and caller receipt are different events

- **Finding ID**: CR-1
- **Status**: ENV_LIMITED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/workflow/mutable_state_impl.go:1581

## Description
`GetUpdateOutcome` reads durable `UpdateInfo` for the requested Update ID, but then fetches a `WorkflowExecutionUpdateCompleted` event from the host event cache by namespace/workflow/run/event ID/version only. It does not verify that the cached event’s `Meta.UpdateId` matches the requested Update ID.

The investigation confirmed the architectural premise: history append, execution mutation commit, effect publication, and caller receipt are separate events. I did not reproduce a wrong public outcome through the local public API harness.

## Trigger scenario
The reachable concern is a multi-history-host/cache-divergence sequence: host A caches a completion event for Update A during a write that does not commit the execution mutation; host B later commits Update B at the reused event ID; host A then serves `PollWorkflowExecutionUpdate` for B using its stale cache entry. The local `testcore` onebox harness requires one node per service, so that final multi-host public trigger could not be exercised here.

## Developer intent
Temporal’s own Update/effect documentation expects Update effects to publish only after successful persistence, and rollback/cancel effects after failed persistence. Public callers should observe the durable Update outcome, not an event-cache artifact for a different Update ID.

## Reproduction result
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

## Recommendation
Add an Update-ID validation step after loading a cached `WorkflowExecutionUpdateCompleted` event in `getUpdateOutcomeEvent`. If the event’s `Meta.UpdateId` differs from the requested Update ID, ignore/evict the cache entry and reload from persistence or return an internal consistency error. A multi-history-host integration test is still needed to confirm whether the stale-cache precondition is reachable through production service routing.

---

## Entry 2: Old work is fenced by identity, but error cleanup can affect current work

- **Finding ID**: CR-2
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/api/respondworkflowtaskcompleted/api.go:175

## Description
A stale speculative WFT completion is correctly rejected by task identity checks, but the deferred error path still treats the currently cached speculative WFT as failed work and clears stickiness. That cleanup can affect the replacement WFT. The related timer path also has a guard gap: old speculative timer identity is checked only while the current WFT is still speculative.

## Trigger scenario
A sticky worker polls an Update speculative WFT, the shard/cache is closed, the Update is readmitted and delivered as a replacement sticky speculative WFT, then the old completion arrives first. The old completion returns `NotFound`; the cleanup clears current stickiness; the replacement sticky completion also returns `NotFound`; then the Update is readmitted on the normal queue and completes.

## Developer intent
PR #6295 intentionally added sticky cleanup on speculative WFT completion errors as a workaround. I found no filed same-mechanism report in GitHub issue/PR searches, including recently closed/merged PRs. Checked adjacent but non-duplicate reports: #10478, #10775, #11254.

## Reproduction result
Executed: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/repro/test_bugCR-2_stale_cleanup_masked.sh`

```text
REPO_HEAD=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
REPRO_LEVELS=level1-public-api-with-admin-cache-loss;level2-reachable-timer-precondition
RUN completion: timeout 10m go test -tags=test_dep ./tests -run TestWorkflowUpdateSuite/TestAnalysisStaleCompletionReplacementSticky -count=1 -v
    update_analysis_identity_test.go:91: CONTROL: stale completion rejected; live normal replacement completed
    update_analysis_identity_test.go:95: RECOVERY: original Update caller received the expected successful result
    update_analysis_identity_test.go:83: OBSERVED: stale completion rejected; live sticky replacement completion also rejected
    update_analysis_identity_test.go:95: RECOVERY: original Update caller received the expected successful result
PASS
ok  	go.temporal.io/server/tests	0.276s
RUN timer: timeout 10m go test -tags=test_dep ./service/history -run TestAnalysisTimerReplacement -count=1 -v
    update_analysis_timer_test.go:156: OLD_EXECUTOR_RESULT error=<nil>
    update_analysis_timer_test.go:173: PREMATURE_TIMEOUT_EVENT event_id=7 scheduled=5 started=6 wall_now=2026-09-09 20:16:58.614795209 +0000 UTC m=+2.023128639 replacement_deadline=2026-09-09 20:16:59.613839703 +0000 UTC
    update_analysis_timer_test.go:181: AFTER_OLD_TIMER normal=true pending_attempt=1 pending_started=0
PASS
ok  	go.temporal.io/server/service/history	2.033s
```

Full logs are under `confirmation/CR-2/repro-output/`. The bad intermediate behavior is real, but the public Update caller’s final outcome is recovered by readmission/retry and normal-queue delivery, so this is masked rather than a reproduced live bug.

## Recommendation
Gate the speculative-WFT sticky cleanup so it only runs for an error on the same WFT instance/token that failed, not after pre-identity stale rejection. For timers, keep old speculative timeout identity fenced even after a replacement WFT is converted to normal.

---

## Entry 3: Mixed Update outcomes and final Workflow closure share an effect batch

- **Finding ID**: CR-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/api/updateworkflow/api.go:298

## Description

Confirmed. At `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`, `Updater.OnSuccess` classifies any `COMPLETED` update with a failure outcome as rejected, returning a workflow link with reason `Update rejected` at `service/history/api/updateworkflow/api.go:298-309`. That ignores whether the update was actually accepted and completed with a handler failure, even though the local comment says accepted/completed updates should link to the accepted event.

A second reproduced path shows the same mixed-effect area can publish a terminal update failure to the original caller while the failed close write leaves durable state `RUNNING` and the update still accepted but not completed. After recovery, the same update ID can then complete successfully.

## Trigger scenario

Level 0: three normal public Update requests are admitted before one Workflow Task. The worker responds in one WFT with one successful accepted/completed update, one accepted/completed update whose handler result is failure, one rejected update, and a workflow close command. Durable history contains accepted/completed events for the handler-failure update, but the public response link says `Update rejected`.

Level 1: public `UpdateWorkflowExecution`, `PollWorkflowTaskQueue`, and `RespondWorkflowTaskCompleted` calls, plus Temporal’s persistence fault hook, force a transaction-size termination fallback and make that termination write return timeout. The original update caller sees workflow-completed failure while readback shows durable `RUNNING`; after clearing the runtime limit, the same completion succeeds and polling the same update ID returns success.

## Developer intent

The code comment at `service/history/api/updateworkflow/api.go:293-296` states rejected updates use a workflow link because they write no history event, while accepted/completed updates should use a WorkflowEvent link. Existing Nexus update handling tests encode that contract at `tests/nexus_workflow_update_test.go:114-123`.

Prior-report search covered upstream issues and recently merged/closed PRs for this mechanism, including `Update rejected`/`Link`, `WorkflowExecutionUpdateAccepted` + `WorkflowExecutionUpdateCompleted` + `Update rejected`, `response link` + `workflow update`, and `UpdateWorkflowExecutionResponse` + `Link`. Related items #6630, #9614, #10478, #10775, and #11254 do not report this exact defect.

## Reproduction result

Repro written and executed:

```text
/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/repro/test_bugCR-3_mixed_outcomes.sh
```

Real output:

```text
CR3_REPRO_COMMAND: timeout 10m env TMPDIR=/home/ubuntu/tmp GOTMPDIR=/home/ubuntu/tmp go test -tags=test_dep ./tests -run '^(TestCR3MixedUpdateBatchResponseLink|TestCR3FailedCloseWriteConflictingOutcome)$' -count=1 -v
CR3_REPRO_EXIT: 0
CR3_REPRO_LOG: /home/ubuntu/tmp/cr3-repro-logs/test_bugCR-3_mixed_outcomes.log
    cr3_repro_external_test.go:115: CR3_REPRO_LEVEL0 mixed_batch success_stage=Completed success_link_workflow_event=true accepted_failure_stage=Completed accepted_failure_message="accepted handler failed" accepted_failure_link_workflow_event=false accepted_failure_link_workflow_reason="Update rejected" rejected_stage=Completed rejected_link_reason="Update rejected" accepted_event_count=2 completed_event_count=2 workflow_closed=true
--- PASS: TestCR3MixedUpdateBatchResponseLink (0.12s)
    cr3_repro_external_test.go:222: CR3_REPRO_LEVEL1 failed_close_write first_caller_stage=Completed first_caller_failure="Workflow Update failed because the Workflow completed before the Update completed." durable_status_after_failed_close=Running durable_update_acceptance=true durable_update_completion=false termination_write_injected=true worker_error="cr3: termination write did not execute"
    cr3_repro_external_test.go:250: CR3_REPRO_LEVEL1_AFTER_RECOVERY same_update_id="TestCR3FailedCloseWriteConflictingOutcome_update_id" poll_stage=Completed poll_success="success-result-of-TestCR3FailedCloseWriteConflictingOutcome_update_id"
--- PASS: TestCR3FailedCloseWriteConflictingOutcome (0.07s)
PASS
ok  	go.temporal.io/server/tests	0.229s
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? yes.
2. Level 2/3 used? no.
3. Real consumer/caller: the public `WorkflowService.UpdateWorkflowExecution` caller receives the wrong response via `service/frontend/workflow_handler.go:5476-5509`; later `PollWorkflowExecutionUpdate` can observe the conflicting same-update success via `service/history/api/pollupdate/api.go:69-81`.
4. Permanent or masked: the wrong response link is already returned and `PollWorkflowExecutionUpdate` does not carry a replacement link. The failed-close durable state can later recover, but recovery does not mask the already-delivered caller failure plus later same-update success.

## Recommendation

Fix response-link selection to distinguish real rejection from accepted/completed failure, using acceptance/event state rather than failure outcome alone. For the close fallback, do not publish terminal close-abort update results unless the close write commits, or perform readback/retry handling before completing update waiters. Add regressions for mixed accepted failure/rejection/close batches and failed termination write after transaction-size fallback.

---

## Entry 4: Volatile deduplication must retain a delivery or retry path

- **Finding ID**: CR-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/workflow/update/registry.go:311

## Description
CR-4 is confirmed at revision `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.

A duplicate `UpdateWorkflowExecution` request with completion callbacks can attach to an existing volatile `stateSent` update and return without creating a new workflow task (`service/history/api/updateworkflow/api.go:173-182`). While in `stateSent`, callbacks are buffered in memory (`service/history/workflow/update/update.go:416-438`). If the worker then completes the workflow task without processing the update message, `RejectUnprocessed` calls `reject()`, but `reject()` refuses to run when `pendingCallbacks` is non-empty (`service/history/workflow/update/update.go:751-757`). `RejectUnprocessed` then drops that error and returns nil (`service/history/workflow/update/registry.go:311-313`), leaving the update sent but non-terminal.

Novelty: I searched upstream open/closed issues, recently merged PRs, and affected-file git history. No exact prior report or landed fix was found for this mechanism. Adjacent items `#10478`, `#10775`, `#11254`, and `#9614` cover different mechanisms.

## Trigger scenario
1. Start a workflow and complete its initial workflow task.
2. Call public `UpdateWorkflowExecution` with wait stage `ACCEPTED`.
3. Poll a workflow task and receive the update protocol message, putting the update in `stateSent`.
4. Send a same-update-ID duplicate `UpdateWorkflowExecution` with a completion callback; it attaches `pendingCallbacks`.
5. Complete the held workflow task without protocol messages, matching the old-SDK / buggy-worker path handled by `rejectUnprocessedUpdates`.
6. The caller receives `ADMITTED` with no outcome; same-ID retries keep returning `ADMITTED` while the registry remains in memory.

## Developer intent
`docs/architecture/workflow-update.md:252-292` says `RejectUnprocessed()` is an expected path for resolving update waiters as rejected. `workflow_task_completed_handler.go:257-275` also states that after unprocessed rejection there must be no sent updates. The implementation violates that intent when buffered callback state prevents rejection and the error is discarded.

## Reproduction result
Wrote and executed:

`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/repro/test_bugCR-4_volatile_dedup_callbacks_test.go`

Command:

```bash
REPRO=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/repro
export GOTMPDIR="$REPRO/tmp"
export GOCACHE="$REPRO/gocache"
timeout 12m go test -tags=test_dep -run 'TestBugCR4' -count=1 -v
```

Captured output:

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

Checklist:
1. Did Level 0 or Level 1 alone trigger it? yes. Level 1: public frontend APIs plus timing/config gates only.
2. Level 2/3 used? no; N/A.
3. Real consumer/caller: public `UpdateWorkflowExecution` caller via `service/frontend/workflow_handler.go:5476` and `service/history/api/updateworkflow/api.go:286-290`.
4. Permanent or masked? Not self-healing under the normal unprocessed-update path; it persisted across repeated public redelivery and same-ID retry cycles. Manual shard/cache clear later resolved it, so cache loss is a recovery escape hatch, not an automatic mask.

## Recommendation
Make `RejectUnprocessed` handle `stateSent` updates with buffered duplicate callbacks by clearing or terminally failing callback state before rejection, and do not silently discard `reject()` errors. Add a regression covering duplicate callback attachment followed by an unprocessed workflow-task completion.

---
