# Confirmation Report — temporal-reset

## Final Result

Reproduced bugs: 3 = 3 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 3
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 6
Dispositions: 6 total = 3 reproduced + 0 env-limited + 0 masked + 3 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | CR-2 | FALSE POSITIVE | no |
| 4 | CR-3 | FALSE POSITIVE | no |
| 5 | CR-4 | REPRODUCED | yes |
| 6 | CR-5 | FALSE POSITIVE | no |

## Entry 1: A short scanner age can remove history before execution publication

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: service/worker/scanner/history/scavenger.go:210

## Description
With `worker.historyScannerDataMinAge` set shorter than the SQL history-to-execution-metadata publication window, the history scanner can treat a just-created branch as garbage. The scanner sees `DescribeMutableState` return `NotFound` before metadata is published, deletes the branch, and the API can still acknowledge the Start/Reset run. The default 60-day age prevents this in default config.

## Trigger scenario
Public `StartWorkflowExecution` or `ResetWorkflowExecution` appends history in `common/persistence/sql/execution.go` before writing execution metadata. During that gap, the history scanner path at `service/worker/scanner/history/scavenger.go:257` observes no mutable state and deletes the branch at `service/worker/scanner/history/scavenger.go:279`.

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**. The deterministic repro used existing Level 3 test instrumentation to hit the SQL `before-metadata` window.
2. Reachable sequence: public Start/Reset -> SQL `AppendHistoryNodes` -> before metadata transaction -> scanner scans fresh branch with minAge=0 -> `DescribeMutableState` returns `NotFound` -> `DeleteHistoryBranch` -> API acknowledges run.
3. Real consumer: public `GetWorkflowExecutionHistory` via `service/frontend/workflow_handler.go:961` observes missing/incomplete history.
4. The corrupted history is permanent for the acknowledged run. Start retry returns the same run without restoring history; Reset retry creates a different run, not repairing the first acknowledged run.

## Developer intent
Issue #10690 and PR #10926 intentionally added missing-current reset support, but they do not report scanner cleanup during the SQL publication window. PR #3310 set the default scanner age to 60 days; PR #3588 fixed a different scanner deletion bug. Open/closed issue and PR searches for this exact mechanism returned no match.

Sources: https://github.com/temporalio/temporal/issues/10690, https://github.com/temporalio/temporal/pull/10926, https://github.com/temporalio/temporal/pull/3310, https://github.com/temporalio/temporal/pull/3588

## Reproduction result
Wrote and executed:
`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/repro/test_bugMC-1_scanner_age.sh`

Actual output:
```text
CASE mode=start age=0 go_test_rc=1 log=.../start-0.log
    reset_scanner_validation_test.go:163: SCANNER_OBSERVATION mode=start minAge=0s branchAge=2.24683ms eligible=true acknowledged=01a088e9-437c-7bad-825c-cfd042855213 persistedNext=3 historyEvents=0 historyError=Workflow execution history not found.
    reset_scanner_validation_test.go:179: SCANNER_RECOVERY startRetry=run_id:"01a088e9-437c-7bad-825c-cfd042855213" ... error=<nil>
EVIDENCE: short age deleted/invalidated history for acknowledged start run: historyEvents=0 expected=2 historyError=Workflow execution history not found.
CASE mode=reset age=0 go_test_rc=1 log=.../reset-0.log
    reset_scanner_validation_test.go:163: SCANNER_OBSERVATION mode=reset minAge=0s branchAge=4.262693ms eligible=true acknowledged=a11a7081-fe25-4e6e-a82f-a4dd0435c858 persistedNext=6 historyEvents=3 historyError=<nil>
    reset_scanner_validation_test.go:160: SCANNER_EXPECTED_ASSERTIONS count=1
    reset_scanner_validation_test.go:173: SCANNER_RECOVERY resetRetry=run_id:"85fabd06-dc15-47e8-b92d-e40987f6c2c3" error=<nil>
EVIDENCE: short age deleted/invalidated history for acknowledged reset run: historyEvents=3 expected=5 historyError=<nil>
CASE mode=start age=60d go_test_rc=1 log=.../start-60d.log
    reset_scanner_validation_test.go:163: SCANNER_OBSERVATION mode=start minAge=1440h0m0s branchAge=4.567032ms eligible=false acknowledged=01a088e9-44e2-74d0-8911-664231c5624b persistedNext=3 historyEvents=2 historyError=<nil>
CONTROL: default age preserved acknowledged start run history: historyEvents=2 expected=2
CASE mode=reset age=60d go_test_rc=1 log=.../reset-60d.log
    reset_scanner_validation_test.go:163: SCANNER_OBSERVATION mode=reset minAge=1440h0m0s branchAge=3.559075ms eligible=false acknowledged=0f8cd6a0-0476-4902-9c05-8c4c9009c0ac persistedNext=6 historyEvents=5 historyError=<nil>
CONTROL: default age preserved acknowledged reset run history: historyEvents=5 expected=5
REPRO_RESULT PASS: MC-1 scanner-age sensitivity reproduced with public Start/Reset handlers and controlled by 60-day minimum age
```

## Recommendation
Do not let the scanner delete branches for executions that may still be in the SQL history-before-metadata publication window. Add a creation-age floor that cannot be configured below a safe bound, or make the scanner verify publication/absence with a second durable check before `DeleteHistoryBranch`.

---

## Entry 2: Identical Reset requests can create another run instead of returning the first result

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `service/history/api/resetworkflow/api.go:124`

## Description

MC-2 is confirmed. Temporal deduplicates Reset retries by comparing the public Reset `request_id` with the current run’s `CreateRequestId`, but reset-run construction intentionally persists the original workflow-start request ID instead. The identical Reset request therefore misses deduplication and creates a second reset run.

I checked upstream issues, merged/closed PRs, `origin/main`, and recent git history for this exact Reset retry identity mechanism. I found related intent in PRs [#9479](https://github.com/temporalio/temporal/pull/9479) and [#10926](https://github.com/temporalio/temporal/pull/10926), but no existing report or fix for identical Reset request replay creating another run.

## Trigger scenario

1. Start a workflow.
2. Call public `ResetWorkflowExecution` with request ID `R`.
3. First Reset succeeds and creates reset run `A`.
4. Immediately call the same public Reset request again, or simulate client response loss and retry the identical request.
5. Temporal creates reset run `B`, makes `B` current, and terminates `A` instead of returning `A`.

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 0 triggered the immediate replay path through the public frontend client; Level 1 only added response-loss timing help for the recovery variant.
2. Level 2/3 injection or source patch used? **no**.
3. Real observer: the public `ResetWorkflowExecution` caller observes the wrong `RunId` in `ResetWorkflowExecutionResponse` (`service/history/handler.go:1130`, API response `go.temporal.io/api/workflowservice/v1/request_response.pb.go:4755`).
4. Masking/recovery: **permanent for the operation**. The first reset run is durably terminated, the second run is current, and the base reset link points to the second run. I found no downstream sync, resend, loopback, or caller guard that restores identity.

## Developer intent

The public API marks Reset `request_id` as the deduplication key. The current code checks:

`current.CreateRequestId == request.GetRequestId()`

But reset construction intentionally uses the original workflow-start request ID so scheduler callback completion can still match buffered starts. That intent is from PR [#9479](https://github.com/temporalio/temporal/pull/9479). PR [#10926](https://github.com/temporalio/temporal/pull/10926) added missing-current Reset handling, but did not address this retry identity split.

## Reproduction result

Executed:

```bash
/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/repro/test_bugMC-2_reset_retry_identity.sh > /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-2/repro-output.log 2>&1
```

Key captured output:

```text
MC2_REPO_HEAD=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
mode=same-running reset_request_id=fbad8951-9889-4398-b04a-8832abac57fd original_start_id=1ccd7514-5284-4132-bbcb-2adcf22184a7 first=398db287-6760-4476-9a35-53e4aaffcf7c second=f0a1584e-101a-4449-8ff7-7682384bffa4 current=f0a1584e-101a-4449-8ff7-7682384bffa4
expected: "398db287-6760-4476-9a35-53e4aaffcf7c"
actual  : "f0a1584e-101a-4449-8ff7-7682384bffa4"
Messages: identical immediately repeated Reset must return the original reset run
response_loss=verified observed_error=analysis: successful Reset response discarded
mode=same-running reset_request_id=7e73a5df-e3dc-4d2e-ac20-da57051c75bd original_start_id=b7dd174a-1c8b-404a-b22b-23a5e77fc15d first=e2a5b670-817f-436a-b744-50acad5c1d21 second=5311fe45-c449-4950-a5b6-470ea09c4080 current=5311fe45-c449-4950-a5b6-470ea09c4080
first_after ... status:WORKFLOW_EXECUTION_STATUS_TERMINATED
second_after ... status:WORKFLOW_EXECUTION_STATUS_RUNNING
MC2_TEST_BINARY_EXIT=1
BUG_MC2_REPRODUCED: identical Reset request was executed through FrontendClient twice; both response-received and response-lost paths produced a second run instead of returning the first reset run.
```

The wrapper exited successfully after detecting the expected failing assertion. A direct compile attempt hit local disk quota limits, so the reproduction used the existing compatible Temporal test binary and printed its SHA-256 plus the checked repository SHA.

## Recommendation

Preserve the callback behavior from PR #9479, but persist and consult a Reset-specific request identity for deduplication. A fix should make identical Reset retries return the first reset run while still allowing distinct administrative Reset requests to create new runs. Add regression coverage for immediate replay, response-loss retry, missing-current retry, and the scheduler callback cases that motivated the original start-request identity.

---

## Entry 3: Missing-current Reset split persistence can leave incomplete durable state across retry

- **Finding ID**: CR-2
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/ndc/workflow_resetter.go:396

## Description

CR-2’s intermediate state is real: in the missing-current Reset path, Temporal writes the base execution’s `ResetRunId` via `UpdateWorkflowModeBypassCurrent` before creating the candidate reset run with `CreateWorkflowModeBrandNew`.

The asserted bug did not reproduce across retry. The durable split state was observed after an injected create rejection, but a healthy retry after shard reload overwrote the stale base link, created the new reset run as current, and completed it. I found no upstream issue or merged/closed PR reporting this exact split-persistence-across-retry mechanism.

## Trigger scenario

The reachable setup used normal public operations: start two executions for the same workflow ID, delete the current run through `DeleteWorkflowExecution`, wait until `GetCurrentExecution` reports missing current, then call public `ResetWorkflowExecution` against the older base run.

The faulted reproduction injected failure only at the reset candidate create call. It verified the precondition immediately before retry: `baseLink == candidate`, while the candidate execution was absent. Then it retried the same public reset request after shard reload.

## Developer intent

PR #10926 intentionally introduced missing-current Reset support and documents the base-first split write because the base mutable state and new current execution cannot be atomically committed when the current row is missing. The intended recovery contract is retry, not atomic all-or-nothing persistence for this path.

## Reproduction result

Executed: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/repro/test_bugCR-2_missing_current_retry.sh`

```text
source_head=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
run=level0_missing_current_public_reset
status=0 log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-2/repro-logs/level0_missing_current_public_reset.log
--- PASS: TestResetWorkflowTestSuite/TestResetWorkflowByRunID_CurrentExecutionMissing (6.61s)
PASS
ok  	go.temporal.io/server/tests	6.652s

run=level2_missing_current_create_rejected_then_retry
status=0 log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-2/repro-logs/level2_missing_current_create_rejected_then_retry.log
scenario=create-rejected checkpoint=base-written ... candidate=b30cf1c7-fb52-41aa-8d52-49132d9ae849 baseLink=b30cf1c7-fb52-41aa-8d52-49132d9ae849
scenario=create-rejected firstResponse=<nil> firstError=reset analysis: create not submitted attempts=1
scenario=create-rejected checkpoint=recovered reset=5f96e204-3084-4a1d-8c2b-df62400f67c7 current=5f96e204-3084-4a1d-8c2b-df62400f67c7 baseLink=5f96e204-3084-4a1d-8c2b-df62400f67c7 completedStatus=Completed
scenario=create-rejected checkpoint=base-deleted-reset-readable reset=5f96e204-3084-4a1d-8c2b-df62400f67c7 events=8
scenario=competing-start checkpoint=start-committed ...
scenario=competing-start checkpoint=recovered reset=69d74465-3300-44a5-9365-4c4f164fbcb7 current=69d74465-3300-44a5-9365-4c4f164fbcb7 baseLink=69d74465-3300-44a5-9365-4c4f164fbcb7 completedStatus=Completed
PASS
ok  	go.temporal.io/server/tests	12.179s
conclusion=missing_current_split_state_recovered_after_retry
```

## Recommendation

Do not confirm CR-2 as a bug. Keep the recovery regression test if this path remains under scrutiny, but the claimed incomplete durable state across retry is refuted by the executed retry/reload evidence.

---

## Entry 4: A stale missing-current decision can race a competing current operation

- **Finding ID**: CR-3
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/ndc/workflow_resetter.go:390

## Description
The competing-current race is reachable, but the claimed bad outcome is not. When Reset decides current is missing, writes the base reset link, and a competing Start commits before the reset run create, SQL persistence rejects the stale `CreateWorkflowModeBrandNew` create via the current-row condition. The handler converts that to retryable `Unavailable`; the normal retry re-resolves the competing Start as current and performs the ordinary Reset behavior: terminate current, create reset run as current.

That ordering is consistent with overlapping Start and Reset operations. I did not find evidence of a blind overwrite, unavailable acknowledged run, or permanent corrupt state.

## Trigger scenario
1. Start a workflow, keep an older explicit base Run ID.
2. Reach a missing-current state through normal APIs by deleting the current run while the older run remains addressable.
3. Issue `ResetWorkflowExecution` by explicit base Run ID.
4. Use timing assistance to pause after base-link persistence.
5. Issue a competing `StartWorkflowExecution`; it commits as current.
6. Release Reset; the stale create conflicts, retries, then resets the competing current run.

## Developer intent
PR #10926 / commit `44de0057368a4f5c6bb2e36f7b5c8edf16301ff8` intentionally introduced the missing-current path and documents the non-atomic base-link/new-current write order. Its stated goal was fixing #10690, where reset by older explicit Run ID failed after current deletion.

I searched upstream issues plus open/closed and recently merged PRs for this exact competing Start/Reset mechanism. I found no exact prior report; #10690/#10926 are related but cover the older missing-current failure, not this race.

## Reproduction result
Wrote and executed:
`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/repro/test_bugCR-3_competing_start.sh`

Command:
```text
timeout 6m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/repro/test_bugCR-3_competing_start.sh
```

Key output:
```text
CR-3 competing-start reset reproduction
git_head=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
git_dirty_count=19
underlying_test_rc=1
underlying_log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-3/repro-logs/test_bugCR-3_competing_start-20260910T012735Z-3996971.log
raw_trace=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-3/repro-logs/raw-20260910T012735Z-3996971/competing-start.jsonl
578:    reset_trace_test.go:248: scenario=competing-start start=e9dbda18-7967-4c0b-9603-023568129373 reset=228c6578-1fc9-4c2d-b649-a08c06a6384e first=1f82587b-b7cd-4304-a10b-203b8e03df20 final=1f82587b-b7cd-4304-a10b-203b8e03df20 faults=1 finalStatus=Completed
584:                         unable to open database file (14)
trace summary:
start_response_runs=01a088ed-6837-7bc2-a0c8-21bc2ee2e563,01a088ed-7cfe-72c2-b18e-70f397295b81
reset_response_runs=1f82587b-b7cd-4304-a10b-203b8e03df20
ordered_replacement competitor_run=01a088ed-7cfe-72c2-b18e-70f397295b81 competitor_status=TERMINATED(5) reset_run=1f82587b-b7cd-4304-a10b-203b8e03df20 reset_status=RUNNING(1)
healthy_completion reset_run=1f82587b-b7cd-4304-a10b-203b8e03df20 final_status=COMPLETED(2) faults=1 history_events=8
CR3_REPRO_OBSERVED: competing Start committed during missing-current Reset gap; Reset returned success; competing run was terminated; reset run completed.
```

The wrapper exited `0` after validating the raw trace. The underlying Temporal trace test exits `1` because its recorder closes after the sqlite test DB is dropped; the CR-3 evidence was already emitted and validated.

## Recommendation
Do not treat CR-3 as a confirmed bug. The race schedule should be kept as a regression test for the intended conflict-and-retry behavior, and the trace-recorder close error should be cleaned up separately, but no semantic repair request is warranted for this code-review finding.

---

## Entry 5: Reset reapplication can combine Continue-As-New histories with colliding Update IDs

- **Finding ID**: CR-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/history/ndc/workflow_resetter.go:927

## Description
Reset reapply walks a Continue-As-New chain and merges eligible events from multiple source runs into one reset run. Update IDs are valid per `Namespace+WorkflowID+RunID`, but reset inserts them into one reset run `UpdateInfos` map; when two source runs use the same Update ID, the second reapply fails at `service/history/workflow/mutable_state_impl.go:5745`.

## Trigger scenario
Public API sequence: start workflow run A, complete Update `bug-cr4-shared-update-id` on run A, signal A to Continue-As-New to run B, complete another public Update with the same ID on run B, signal B to Continue-As-New to run C, then call public `ResetWorkflowExecution` on run A at event 4. Reset traverses A then B and returns `Internal`.

## Developer intent
The reset path explicitly assumes conflicting Update IDs are impossible during reset reapply (`workflow_resetter.go:933`). SDK docs contradict that across runs: Update ID uniqueness is scoped to Namespace + WorkflowID + RunID. Upstream search found related but not duplicate reports: #6375, #6513, and #10926 do not report this reset reapply collision.

## Reproduction result
Checklist:
1. Level 0 alone triggered it: **yes**.
2. Level 2/3 injection: **N/A**. No state injection or source patch was used.
3. Real consumer/caller: public `ResetWorkflowExecution`, accepted by `service/frontend/workflow_handler.go:2418` and forwarded at `:2456`, observes `serviceerror.Internal`.
4. Masking: **not masked**. The reset API returns the error; no downstream sync/loopback/resend resolves it.

Command:
```bash
timeout 12m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/repro/test_bugCR-4_can_update_collision.sh
```

Key output from `confirmation/CR-4/repro-output.log`:
```text
head=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
test=TestBugCR4ResetReapplyCollidingUpdateIDsAcrossCAN
=== RUN   TestBugCR4ResetReapplyCollidingUpdateIDsAcrossCAN
service failures {"operation": "ResetWorkflowExecution", "grpc_code": "Internal", "error": "Update ID bug-cr4-shared-update-id is already present in mutable state"}
BUG_TRIGGERED CR-4: reset from runA=01a088f5-718b-7d1e-9b01-d7a7fd5c6227 at event=4 traversed runB=849807c3-5b4c-4393-914d-d553b7e158e4 and current runC=6f95d6dc-8579-410f-b681-0ff1ddce36e0; public ResetWorkflowExecution failed with *serviceerror.Internal: Update ID bug-cr4-shared-update-id is already present in mutable state
--- PASS: TestBugCR4ResetReapplyCollidingUpdateIDsAcrossCAN (0.88s)
PASS
ok  	go.temporal.io/server/tests	0.916s
```

Repro artifacts written:
`repro/test_bugCR-4_can_update_collision.sh`, `confirmation/CR-4/investigation.md`, `confirmation/CR-4/repro-output.log`.

## Recommendation
Make reset reapply preserve source-run identity when considering Update collisions, or skip/dedupe already-reapplied Updates by `(sourceRunID, eventID/version)` while still respecting the reset run’s own Update ID map. Add a regression test for same Update ID across CAN source runs.

---

## Entry 6: Staged deletion and child-completion consumers can follow incomplete Reset state

- **Finding ID**: CR-5
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `service/history/ndc/workflow_resetter.go:403`

## Description
CR-5 did not confirm as a bug. The missing-current reset path can create an internal staged interval where the base run has `ResetRunId` set while the candidate reset run is not yet created, but the tested public child-completion and deletion consumers did not observe a wrong outcome.

## Trigger scenario
Used supported APIs: start parent with abandoned child, terminate parent, start and delete replacement current run, reset the terminated base by explicit Run ID, then complete the child. Level 1 additionally paused `CreateWorkflowExecution` after the base reset link was durable.

## Developer intent
The two-write missing-current path is deliberate retry behavior. Child completion goes through the history consumer at `service/history/transfer_queue_active_task_executor.go:452`, and branch cleanup uses history-tree references in `common/persistence/history_manager.go:131`.

## Reproduction result
Executed: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/repro/test_bugCR-5_reset_staged_child_completion.sh`

Key output:

```text
CR5_LEVEL0_OK ... reset=2c66984e-0f39-42a0-a991-474ba3d9a3ce child=01a08902-d177-7e15-8106-33a6225afb45 resetPoint=9
CR5_GAP_OBSERVED ... candidate=8d5faf79-49a3-417a-8a8f-7e8d9bf83f4a current=missing candidate_state=missing
CR5_CHILD_COMPLETION_SERIALIZED child completion did not finish while reset create gate was held; err=*serviceerror.DeadlineExceeded
CR5_LEVEL1_OK ... staged_reset=8d5faf79-49a3-417a-8a8f-7e8d9bf83f4a child=01a08902-e251-7e7a-8207-d5ad11c775b5 resetPoint=9 recoveryAttempts=0
--- PASS: TestCR5ResetStagedChildCompletionAndDeletion (14.83s)
PASS
ok  	go.temporal.io/server/tests	14.873s
```

Checklist: Level 0/1 did not trigger a wrong outcome; no Level 2/3 was used. The real caller checked was `service/history/transfer_queue_active_task_executor.go:452`, and no wrong outcome was observed. The staged state was not permanent; after release, the reset run completed and base deletion preserved reset history.

## Recommendation
Do not report CR-5 as a confirmed Temporal bug. I wrote the repro test and investigation notes, but no repair request is appropriate for this Code Review false positive.

---
