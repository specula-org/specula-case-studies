# CR-5 Investigation

## Code Audit

- Revision checked: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; the worktree is dirty with existing reset tracing/investigation changes, but the reproduction added for CR-5 uses Temporal public APIs plus the built-in persistence fault injector.
- Source: Code Review. There is no model-checking counterexample attached to this finding.
- `service/history/api/resetworkflow/api.go:92-103` resolves the current run and tolerates `NotFound` only when the request names an explicit base run ID. This is the public missing-current reset entry point introduced for reset-by-run-ID.
- `service/history/ndc/workflow_resetter.go:133-165` writes `ResetRunId` into the base mutable state and, when `currentWorkflow == nil`, uses the missing-current reapply path instead of terminating a current run.
- `service/history/ndc/workflow_resetter.go:388-431` persists the missing-current reset in two writes: first `UpdateWorkflowExecution(...BypassCurrent...)` for the base run, then `CreateWorkflowExecution(...BrandNew...)` for the reset run. This creates an internal staged interval where the base row names a reset run that has not been created yet.
- `service/history/ndc/workflow_resetter.go:525-539` forks a reset history branch before rebuilding the reset mutable state; `common/persistence/history_manager.go:131-212` later protects branch ranges by scanning every branch in the history tree and not only by checking workflow executions.
- `service/history/shard/context_impl.go:944-1143` deletion runs in stages. Public closed-workflow deletion and retention deletion enqueue a delete task, then delete current pointer, mutable state, and finally the history branch. The code comment says stage 4 is last because deleting history while mutable state is still accessible would be inconsistent.
- `service/history/api/recordchildworkflowcompleted/api.go:39-60` follows a closed parent run's `ResetRunId` and mutates the request to the new parent run. `service/history/api/recordchildworkflowcompleted/api.go:101-166` records the child completion only after loading the target mutable state and finding the pending child info.
- `service/history/handler.go:1272-1298` exposes `RecordChildExecutionCompleted` as the history service handler, and `service/history/transfer_queue_active_task_executor.go:452-474` is the real close-task consumer. That caller treats `NotFound` and `NamespaceNotFound` from `RecordChildExecutionCompleted` as "parent gone" and returns nil.

## Reachability

The staged state is reachable with supported operations:

1. Start a parent workflow that starts a child with `ParentClosePolicy=ABANDON` and waits for the child result.
2. Wait until the parent has recorded `ChildWorkflowExecutionStarted` and completed the follow-up workflow task; use that workflow task as the reset point.
3. Terminate the parent so the child remains running and the base run survives with pending child info.
4. Start and complete a replacement run with the same workflow ID, then delete that replacement run, leaving no current execution while the terminated base run still exists.
5. Reset the terminated base run by explicit Run ID. In the missing-current branch, the base `ResetRunId` write precedes the reset run creation.

The consumer path is also reachable: when the child completes, its close task calls `RecordChildExecutionCompleted` for the parent. If it could complete while the reset create write is still paused, it would either record into the reset run or return `NotFound` after following the staged `ResetRunId`.

## Safeguards Checked

- Workflow leases are acquired by reset before persistence and released only when the public reset handler returns. This may serialize both deletion and child-completion consumers that need the base run.
- The missing-current reset path forks the history branch before the base mutable-state update, so branch-reference deletion can observe the reset branch metadata even before the reset execution row exists.
- The current code also has child-completion recovery logic in `service/history/transfer_queue_active_task_executor.go:1555-1637`, but that recovery is for a later pending-parent/start-child path. The reproduction captures `child_workflow_completion_recovery_attempts` to determine whether this recovery masks the CR-5 path.

## Developer Knowledge and Known Status

- GitHub issue search for `"RecordChildExecutionCompleted" "ResetRunId"` in `temporalio/temporal` returned zero results.
- GitHub issue/PR search for `"allowResetWithPendingChildren"` returned adjacent PRs, including `https://github.com/temporalio/temporal/pull/7346`, which made the feature default-on and stated that reset with a child was tested, and `https://github.com/temporalio/temporal/pull/7326`, which fixed a parent-close-policy bug in reset-with-pending-children. These do not report the staged missing-current reset link mechanism.
- GitHub issue/PR search for `"DeleteHistoryBranch" reset` found old PR `https://github.com/temporalio/temporal/pull/1590`, a different reference-counting cleanup fix.
- GitHub issue search for `"missing current" "ResetWorkflowExecution"` found `https://github.com/temporalio/temporal/issues/10690`, the missing-current reset bug fixed by `https://github.com/temporalio/temporal/pull/10926`; that is the enabling path, not this deletion/child-completion consumer claim.
- GitHub issue/PR search for `"child completion" "reset" "NotFound"` found `https://github.com/temporalio/temporal/pull/11868`, a related merged recovery fix for lost child completion after late parent replication. It is adjacent and at the same broad caller, but it does not report the single-cluster incomplete reset candidate path.
- Local `git log --grep` over the affected paths found `44de00573` (`#10926`), `acda19865` (`#7368`), `878ca4725` (`#6867`), and `d61a45474` (`#2323`) as relevant history. None is an exact prior report of CR-5's staged missing-current reset candidate mechanism.

Known-status result: no existing issue, PR, CVE, advisory, or checked local history entry reports this exact mechanism at these sites.

## Reproduction

Reproduction test: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/repro/test_bugCR-5_reset_staged_child_completion.sh`

Command executed:

```bash
timeout 10m go test -tags test_dep ./tests -run '^TestCR5ResetStagedChildCompletionAndDeletion$' -count=1 -timeout=8m -v
```

Key output from `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-5/repro-output.txt`:

```text
=== RUN   TestCR5ResetStagedChildCompletionAndDeletion
=== RUN   TestCR5ResetStagedChildCompletionAndDeletion/level0_public_reset_after_current_deleted
reset_cr5_confirmation_test.go:53: CR5_SETUP base=01a08902-d153-7601-a643-f9edb89b017c child=01a08902-d177-7e15-8106-33a6225afb45 replacement=01a08902-d1c4-748b-9d8c-1825d873f60a resetPoint=9 current=missing
reset_cr5_confirmation_test.go:62: CR5_DELETE_BASE_OK base=01a08902-d153-7601-a643-f9edb89b017c reset=2c66984e-0f39-42a0-a991-474ba3d9a3ce resetHistoryBefore=17 resetHistoryAfter=17
reset_cr5_confirmation_test.go:64: CR5_LEVEL0_OK base=01a08902-d153-7601-a643-f9edb89b017c replacement_deleted=01a08902-d1c4-748b-9d8c-1825d873f60a reset=2c66984e-0f39-42a0-a991-474ba3d9a3ce child=01a08902-d177-7e15-8106-33a6225afb45 resetPoint=9
=== RUN   TestCR5ResetStagedChildCompletionAndDeletion/level1_create_gate_does_not_lose_child_completion
reset_cr5_confirmation_test.go:106: CR5_SETUP base=01a08902-e22e-7daa-b0e1-08dad9caa365 child=01a08902-e251-7e7a-8207-d5ad11c775b5 replacement=01a08902-e29c-7bae-9162-944a4f1adc30 resetPoint=9 current=missing
reset_cr5_confirmation_test.go:122: CR5_GAP_OBSERVED base=01a08902-e22e-7daa-b0e1-08dad9caa365 candidate=8d5faf79-49a3-417a-8a8f-7e8d9bf83f4a current=missing candidate_state=missing
reset_cr5_confirmation_test.go:137: CR5_CHILD_COMPLETION_SERIALIZED child completion did not finish while reset create gate was held; err=*serviceerror.DeadlineExceeded
reset_cr5_confirmation_test.go:145: CR5_GATE_HELD reset still blocked after the staged gap was observed
reset_cr5_confirmation_test.go:168: CR5_DELETE_BASE_OK base=01a08902-e22e-7daa-b0e1-08dad9caa365 reset=8d5faf79-49a3-417a-8a8f-7e8d9bf83f4a resetHistoryBefore=17 resetHistoryAfter=17
reset_cr5_confirmation_test.go:170: CR5_LEVEL1_OK base=01a08902-e22e-7daa-b0e1-08dad9caa365 replacement_deleted=01a08902-e29c-7bae-9162-944a4f1adc30 staged_reset=8d5faf79-49a3-417a-8a8f-7e8d9bf83f4a child=01a08902-e251-7e7a-8207-d5ad11c775b5 resetPoint=9 recoveryAttempts=0
--- PASS: TestCR5ResetStagedChildCompletionAndDeletion (14.83s)
    --- PASS: TestCR5ResetStagedChildCompletionAndDeletion/level0_public_reset_after_current_deleted (4.32s)
    --- PASS: TestCR5ResetStagedChildCompletionAndDeletion/level1_create_gate_does_not_lose_child_completion (10.51s)
PASS
ok  	go.temporal.io/server/tests	14.873s
```

## Reproduction Assessment

- Level 0 public API control did not lose child completion and did not delete reset history after deleting the base run.
- Level 1 timing hook exposed the internal staged state: the base run's `ResetRunId` pointed at a candidate reset run while the current row and candidate mutable state were missing.
- The real child-completion consumer did not observe a wrong outcome during that staged state. Public child completion did not finish while reset creation was gated, and after the gate was released the reset run completed with the child completion event recorded.
- `child_workflow_completion_recovery_attempts` stayed at zero, so the observed pass is not a downstream recovery masking a lost child-completion notification.
- Deleting the base run after reset completion left the reset run history readable with the same event count before and after deletion.

Verdict: FALSE POSITIVE.
