# CR-4 Investigation

## Code Audit

- Source revision checked: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.
- The checkout has local reset tracing instrumentation in `service/history/api/resetworkflow/api.go`, `service/history/ndc/workflow_resetter.go`, and `service/history/workflow/mutable_state_impl.go`. The relevant reset/update logic is unchanged from `HEAD`; the diff adds trace calls only.
- Public entry point: `service/history/api/resetworkflow/api.go:29` `Invoke` handles `ResetWorkflowExecution`, loads the base run and current run, computes the reset branch point, and calls `ndc.NewWorkflowResetter(...).ResetWorkflow(...)`.
- Reset construction: `service/history/ndc/workflow_resetter.go:109` updates the base run with the reset run ID, creates a reset mutable state, and schedules a workflow task before persisting the base/current/reset mutations.
- Continue-As-New traversal: `service/history/ndc/workflow_resetter.go:732` first reapplies the base branch suffix from `baseRebuildLastEventID+1` through `baseNextEventID`, then follows each `WorkflowExecutionContinuedAsNew` event to surviving successor runs. The traversal is also used when a current run is present and when the current execution is missing.
- Update reapply: `service/history/ndc/workflow_resetter.go:927` calls `reapplyEvents` with `targetBranchUpdateRegistry == nil`, `runIdForDeduplication == ""`, and `isReset == true`. The reset path therefore does not consult the Update registry and does not mark per-source-run dedupe resources.
- Update admission conversion: `service/history/ndc/workflow_resetter.go:1003` reapplies `WorkflowExecutionUpdateAdmitted`; `service/history/ndc/workflow_resetter.go:1021` reapplies `WorkflowExecutionUpdateAccepted` with an accepted request by converting it into `AddWorkflowExecutionUpdateAdmittedEvent`.
- Collision site: `service/history/workflow/mutable_state_impl.go:5725` applies admitted Update events into `executionInfo.UpdateInfos`; `service/history/workflow/mutable_state_impl.go:5745` returns `Internal` if the Update ID already exists.
- Scope evidence: the Go SDK documents `UpdateWorkflowOptions.UpdateID` as unique within `Namespace+WorkflowID+RunID`, and `RunID` can target a specific run. This makes the same Update ID valid in separate Continue-As-New runs.

## Reachable Trigger Scenario

1. Start a workflow that sets an Update handler and waits for a signal before continuing as new.
2. Send public SDK Update `U` to run A by explicit RunID and wait until it completes, creating Update events in run A.
3. Signal run A so it continues as new to run B.
4. Send public SDK Update `U` again, with the same Update ID, to run B by explicit RunID and wait until it completes. This is valid because Update IDs are scoped by RunID.
5. Signal run B so it continues as new to run C.
6. Call public `ResetWorkflowExecution` against run A at its first completed workflow task, before run A's Update event. Reset replays run A's suffix and then run B's history into a single reset run.
7. The second reapplied Update ID collides in the reset run's single `UpdateInfos` map and the public reset call fails.

No failpoints, direct database edits, private function calls, or source patches are required for this trigger.

## Developer Knowledge Search

- Issue search covered open and closed `temporalio/temporal` issues for `reset reapply update id continue as new collision`, `"Update ID" "reset" "ContinueAsNew"`, `"Update ID" "already present"`, `workflow reset update reapply`, `reset workflow update admitted`, and `"workflow reset" "Update" "reapply"`; no issue reported this exact reset reapply collision.
- PR search covered open and closed/merged PRs for `reset reapply update id continue as new`, `workflow reset update reapply`, and `"Update ID" "reset"`; no PR reported or fixed this exact reset reapply collision.
- Related but not duplicate: GitHub issue https://github.com/temporalio/temporal/issues/6375 reports Update retry behavior across Continue-As-New, but not Workflow Reset reapplying separate runs into one reset run.
- Related but not duplicate: GitHub PR https://github.com/temporalio/temporal/pull/6513 fixed completed-Update checks during reapply for a different path; it does not report this CAN traversal/reset collision.
- Related reachability context: GitHub PR https://github.com/temporalio/temporal/pull/10926 added reset-by-explicit-runID behavior when current execution is missing and documents that reset reapplies through surviving Continue-As-New chains.
- Local `git log`/`git blame` show the reset reapply comment at `service/history/ndc/workflow_resetter.go:933` assumes conflicting Update IDs are impossible because the workflow was consistent before reset. The SDK scope evidence above contradicts that assumption across different runs.

## Known Status

No upstream issue, recently merged/closed PR, CVE, advisory, or git-history entry found for this exact mechanism at the reset reapply site. Novelty: NEW.

## Reproduction Plan

- Level 0: execute `repro/test_bugCR-4_can_update_collision.sh`. It runs a Go functional test using public SDK/frontend APIs only.
- Level 1-3 are unnecessary if Level 0 triggers the public reset failure.
