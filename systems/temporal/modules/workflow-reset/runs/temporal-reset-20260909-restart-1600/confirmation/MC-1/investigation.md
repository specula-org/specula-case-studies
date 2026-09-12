# MC-1 Investigation

## Scope

- Source revision checked: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.
- Source worktree: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-1/worktree`.
- Worktree state: dirty with existing reset/scanner test hooks and analysis tests. I treated those as existing harness material and did not revert them.
- Source: model-checking finding with an actual counterexample supplied by the caller. I did not read spec files, `bug-report.md`, other findings, or shared repair queues.

## Step 1: Code Audit

Relevant code paths:

- `service/worker/scanner/history/scavenger.go:52-54` documents that the history scanner deletes only branches older than `historyDataMinAge`; `common/dynamicconfig/constants.go:3549-3552` sets `worker.historyScannerDataMinAge` to `60*24*time.Hour` by default.
- `service/worker/scanner/history/scavenger.go:210-217` skips a branch only when `now - minAge` is before the branch fork time. With `minAge=0`, a branch becomes eligible almost immediately after creation.
- `service/worker/scanner/history/scavenger.go:257-272` calls `DescribeMutableState` for the branch's namespace/workflow/run and treats `NotFound` or `NamespaceNotFound` as garbage.
- `service/worker/scanner/history/scavenger.go:278-282` calls `DeleteHistoryBranch` for a branch whose mutable state lookup returned not found.
- `common/persistence/sql/execution.go:61-86` for `CreateWorkflowExecution`, `common/persistence/sql/execution.go:344-373` for `UpdateWorkflowExecution`, and `common/persistence/sql/execution.go:469-500` for `ConflictResolveWorkflowExecution` append history nodes before the mutable-state/current-execution metadata transaction.
- `service/history/ndc/workflow_resetter.go:388-428` handles reset with missing current execution using two writes: first update the base run by bypassing current, then create the reset run as brand new current.
- `service/history/api/create_workflow_util.go:135-153` creates the workflow lease/context around the new mutable state, tying the new run ID to the mutable-state persistence path.

Reachability:

- Start path: a public `StartWorkflowExecution` reaches `CreateWorkflowExecution`; SQL appends candidate history before the execution row/current row transaction.
- Reset path: a public `ResetWorkflowExecution` reaches the resetter. In the missing-current case introduced by PR #10926, the resetter performs a base update and then creates the new reset run as current; the create path also appends history before metadata.
- Scanner path: the worker history scanner is enabled by default, receives `HistoryScannerDataMinAge`, lists all history branches, filters on `ForkTime`, describes mutable state, and deletes the branch on `NotFound`.
- Trigger scenario: configure `worker.historyScannerDataMinAge` shorter than the SQL history-to-metadata publication interval; issue Start or Reset; after SQL appends the branch but before metadata publishes the execution, the scanner scans that branch, sees `DescribeMutableState` return `NotFound`, and deletes the branch. The original API still acknowledges a run whose metadata points to missing or truncated history.

Safeguards seen:

- The default 60-day minimum age prevents ordinary/default scanner passes from considering a fresh branch.
- The scanner's `DescribeMutableState` guard protects existing mutable states, but it does not distinguish "not yet published" from "deleted execution" during the SQL publication window.
- No post-delete revalidation or history restore path was found on the scanner path.

## Step 2: Developer-Knowledge Search

Issue/PR evidence checked:

- `gh search issues --repo temporalio/temporal --state open 'historyScannerDataMinAge DeleteHistoryBranch DescribeMutableState'` returned `[]`.
- `gh search issues --repo temporalio/temporal --state closed 'historyScannerDataMinAge DeleteHistoryBranch DescribeMutableState'` returned `[]`.
- `gh search prs --repo temporalio/temporal --state open 'history scanner DeleteHistoryBranch NotFound'` returned `[]`.
- `gh search prs --repo temporalio/temporal --state closed 'history scanner DeleteHistoryBranch NotFound'` returned `[]`.
- Broader open/closed searches for `scavenger history branch delete mutable state` returned `[]`.

Related but not same-mechanism items:

- Issue #10690 (`https://github.com/temporalio/temporal/issues/10690`) reports Reset by explicit older run returning `workflow not found` when current execution is absent. It does not report scanner deletion during SQL history-before-metadata publication.
- PR #10926 (`https://github.com/temporalio/temporal/pull/10926`) fixes #10690 and documents the missing-current reset path: no current row, create reset as new current, and skip current termination. Its code comment states the base link and new current run cannot be committed atomically and that base is written first for retry safety. It does not mention the history scanner.
- PR #3310 (`https://github.com/temporalio/temporal/pull/3310`) changed the default history scavenger min age to 60 days to keep prior behavior. This is a default configuration safeguard, not a report of the short-age publication-window defect.
- PR #3588 (`https://github.com/temporalio/temporal/pull/3588`) fixed a history scavenger delete-mutable-state bug by checking workflow state and adding deletion logging. It is scanner-related but does not describe fresh branch deletion before execution metadata publication.

Developer intent recorded:

- The reset missing-current behavior is intentional and public-API reachable.
- The scanner is designed to delete history branches when mutable state does not exist.
- The 60-day default appears to be a deliberate operational guard against too-young history cleanup, but the code accepts shorter dynamic config values.

## Step 3: Known Status

No public upstream issue/PR found that reports the same mechanism at the same site: a short history scanner minimum age causing the scanner to delete a branch during SQL history-before-execution-metadata publication for an acknowledged Start/Reset run. Novelty is `NEW`.

## Phase 2 Reproduction Summary

Build/artifact preflight:

- Fresh `go test ./tests -run '^TestWorkflowResetSuite/TestValidationScannerAge$'` failed during compilation with `disk quota exceeded` while writing Go work/cache artifacts.
- I found and reused `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/harness/build/reset-trace.test`.
- `go version -m` shows the binary is `go.temporal.io/server/tests.test` built with `go1.27.0`.
- `-test.list '.'` includes `TestWorkflowResetTestSuite`; `strings` confirms `TestValidationScannerAge`, `RESET_SCANNER_MODE`, `before-metadata`, and `SCANNER_OBSERVATION`.

Escalation:

- Level 0 pure black-box/default control: with default 60-day age, Start and Reset did not trigger branch deletion; history was complete.
- Level 1 timing-only without source hook was not sufficient to deterministically place the scanner in the sub-millisecond SQL append-before-metadata interval in this harness.
- Level 2 state injection was not used.
- Level 3 existing local test instrumentation was used to expose the SQL `before-metadata` window and a single-branch scanner invocation while preserving the real Start/Reset frontend handlers, real SQL persistence, real `DescribeMutableState`, real scanner filter/delete logic, shard reload, and public `GetWorkflowExecutionHistory` readback.

Required repro:

- Wrote `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/repro/test_bugMC-1_scanner_age.sh`.
- Executed it with `timeout 30m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/repro/test_bugMC-1_scanner_age.sh`.
- Script exit code: `0`.

Observed output:

```text
COMMAND: timeout 10m env RESET_SCANNER_MODE=start RESET_SCANNER_AGE=0 RESET_SCANNER_OUTPUT=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-1/repro-logs/script-20260910T012303Z /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/harness/build/reset-trace.test -test.run '^TestWorkflowResetTestSuite/TestValidationScannerAge$' -test.v -test.count=1
CASE mode=start age=0 go_test_rc=1 log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-1/repro-logs/script-20260910T012303Z/start-0.log
    reset_scanner_validation_test.go:163: SCANNER_OBSERVATION mode=start minAge=0s branchAge=2.24683ms eligible=true acknowledged=01a088e9-437c-7bad-825c-cfd042855213 persistedNext=3 historyEvents=0 historyError=Workflow execution history not found.
    reset_scanner_validation_test.go:179: SCANNER_RECOVERY startRetry=run_id:"01a088e9-437c-7bad-825c-cfd042855213"  first_execution_run_id:"01a088e9-437c-7bad-825c-cfd042855213"  started:true  status:WORKFLOW_EXECUTION_STATUS_RUNNING  link:{workflow_event:{namespace:"TestWorkflowResetTestSuite-TestValidationScannerAge-a421db00-a9c0-40a5-90df-11052c8fb125"  workflow_id:"TestWorkflowResetTestSuite/TestValidationScannerAge_workflow_id"  run_id:"01a088e9-437c-7bad-825c-cfd042855213"  event_ref:{event_id:1  event_type:EVENT_TYPE_WORKFLOW_EXECUTION_STARTED}}} error=<nil>
EVIDENCE: short age deleted/invalidated history for acknowledged start run: historyEvents=0 expected=2 historyError=Workflow execution history not found.
COMMAND: timeout 10m env RESET_SCANNER_MODE=reset RESET_SCANNER_AGE=0 RESET_SCANNER_OUTPUT=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-1/repro-logs/script-20260910T012303Z /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/harness/build/reset-trace.test -test.run '^TestWorkflowResetTestSuite/TestValidationScannerAge$' -test.v -test.count=1
CASE mode=reset age=0 go_test_rc=1 log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-1/repro-logs/script-20260910T012303Z/reset-0.log
    reset_scanner_validation_test.go:163: SCANNER_OBSERVATION mode=reset minAge=0s branchAge=4.262693ms eligible=true acknowledged=a11a7081-fe25-4e6e-a82f-a4dd0435c858 persistedNext=6 historyEvents=3 historyError=<nil>
    reset_scanner_validation_test.go:160: SCANNER_EXPECTED_ASSERTIONS count=1
    reset_scanner_validation_test.go:173: SCANNER_RECOVERY resetRetry=run_id:"85fabd06-dc15-47e8-b92d-e40987f6c2c3" error=<nil>
    reset_scanner_validation_test.go:60: SCANNER_WORKER_COMPLETE run=85fabd06-dc15-47e8-b92d-e40987f6c2c3 status=Completed
EVIDENCE: short age deleted/invalidated history for acknowledged reset run: historyEvents=3 expected=5 historyError=<nil>
COMMAND: timeout 10m env RESET_SCANNER_MODE=start RESET_SCANNER_AGE=60d RESET_SCANNER_OUTPUT=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-1/repro-logs/script-20260910T012303Z /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/harness/build/reset-trace.test -test.run '^TestWorkflowResetTestSuite/TestValidationScannerAge$' -test.v -test.count=1
CASE mode=start age=60d go_test_rc=1 log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-1/repro-logs/script-20260910T012303Z/start-60d.log
    reset_scanner_validation_test.go:163: SCANNER_OBSERVATION mode=start minAge=1440h0m0s branchAge=4.567032ms eligible=false acknowledged=01a088e9-44e2-74d0-8911-664231c5624b persistedNext=3 historyEvents=2 historyError=<nil>
    reset_scanner_validation_test.go:60: SCANNER_WORKER_COMPLETE run=01a088e9-44e2-74d0-8911-664231c5624b status=Completed
CONTROL: default age preserved acknowledged start run history: historyEvents=2 expected=2
COMMAND: timeout 10m env RESET_SCANNER_MODE=reset RESET_SCANNER_AGE=60d RESET_SCANNER_OUTPUT=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-1/repro-logs/script-20260910T012303Z /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/harness/build/reset-trace.test -test.run '^TestWorkflowResetTestSuite/TestValidationScannerAge$' -test.v -test.count=1
CASE mode=reset age=60d go_test_rc=1 log=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-1/repro-logs/script-20260910T012303Z/reset-60d.log
    reset_scanner_validation_test.go:163: SCANNER_OBSERVATION mode=reset minAge=1440h0m0s branchAge=3.559075ms eligible=false acknowledged=0f8cd6a0-0476-4902-9c05-8c4c9009c0ac persistedNext=6 historyEvents=5 historyError=<nil>
    reset_scanner_validation_test.go:60: SCANNER_WORKER_COMPLETE run=0f8cd6a0-0476-4902-9c05-8c4c9009c0ac status=Completed
CONTROL: default age preserved acknowledged reset run history: historyEvents=5 expected=5
REPRO_RESULT PASS: MC-1 scanner-age sensitivity reproduced with public Start/Reset handlers and controlled by 60-day minimum age
```

Note: the underlying Go test process reports `go_test_rc=1` because the existing resettrace recorder accumulates sqlite cleanup errors when closing; the wrapper does not treat that as the reproduction signal. It validates the public API observations and short-age/default-age differential directly.
