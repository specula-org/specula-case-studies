# MC-2 Investigation

## Code Audit

- Target revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025` in the source worktree. The worktree already had local resettrace/analysis changes before this confirmation run; the cited semantic code below is unchanged on `HEAD` and also still present on refreshed `origin/main` (`706e0b4372fb7339a3a50b5663857061f037867d`).
- MC source: `spec/output/validation-20260909/hunts-sim-01/MC_hunt_scenario1_2_replay_sql.out` reports `Error: Invariant ImmediateRetryIdentity is violated.` Its trace has first reset success followed by response loss and `MCRetryResetWorkflowExecution`, then a second reset commit.
- Public path: `service/history/handler.go:1130` exposes `ResetWorkflowExecution`; it calls the history engine at `service/history/handler.go:1147`. `service/history/history_engine.go:909` delegates to `resetworkflow.Invoke`.
- Public request contract: `go.temporal.io/api@v1.63.5/workflowservice/v1/request_response.pb.go:4631` defines `ResetWorkflowExecutionRequest`; `:4642` says `RequestId` is used to de-dupe reset requests. `:4755` defines the response and `:4757` exposes the caller-observed `RunId`.
- Dedup check: `service/history/api/resetworkflow/api.go:124-133` checks only the current run's `ExecutionState.CreateRequestId` against the public reset `RequestId`; on match it returns the current run id without creating another run.
- New reset-run identity: `service/history/ndc/workflow_resetter.go:230-247` deliberately passes `startRequestID`, not the reset request id, into `prepareResetWorkflow`. `service/history/ndc/state_rebuilder.go:402-410` finds that id from the base run's `WORKFLOW_EXECUTION_STARTED` request-id entry, falling back to `CreateRequestId`.
- Persistence effect: `service/history/workflow/mutable_state_impl.go:2597-2611` makes a `WORKFLOW_EXECUTION_STARTED` request id become the new run's `CreateRequestId`. Therefore the reset-created run persists the original start request id as `CreateRequestId`, while the later dedup check compares it with the reset request id.
- Trigger scenario: through normal Frontend API calls, start a workflow, leave it running, reset it by explicit run id using request id `R`, then immediately submit the identical reset request `R` again. The first reset-created run is current and running, but its `CreateRequestId` is the original start request id, so `Invoke` does not dedupe and creates a second reset run. A response-loss variant is the same sequence except the first successful handler response is converted to `Unavailable`; the client retries `R` and receives a different run id.
- Safeguards checked: current-run lookup and lease acquisition still occur; they do not compare against a reset-specific request-id map. Shard reload does not repair the state because both reset runs have been durably written and the first is durably terminated by the second reset.

## Developer Knowledge Search

- `git blame` attributes the current-run dedup comparison at `service/history/api/resetworkflow/api.go:138-139` to PR `#10926`; the original reset dedup comment predates that change.
- `git blame` attributes `workflow_resetter.go:230-237` and `state_rebuilder.go:402-410` to PR `#9479`.
- PR `#9479` (`https://github.com/temporalio/temporal/pull/9479`) states that reset should use the original start request id so CHASM scheduler callbacks can match the originating `BufferedStart`; it describes a scheduler callback bug, not identical Reset request retry identity.
- PR `#10926` (`https://github.com/temporalio/temporal/pull/10926`) introduced the missing-current reset path and documents using `CreateWorkflowModeBrandNew` after deleting current. It does not describe retrying the same Reset request after a successful reset.
- Refreshed `origin/main` still contains the same mismatch: `resetworkflow/api.go` compares current `CreateRequestId` with reset `RequestId`, while `workflow_resetter.go` still chooses `findStartRequestID(base...)`.

## Known Status / Precedent

- Issue search run: `gh issue list --repo temporalio/temporal --state all --search 'ResetWorkflowExecution RequestId CreateRequestId reset duplicate retry'` returned `[]`.
- Issue/PR search run: `gh search issues --repo temporalio/temporal 'ResetWorkflowExecution RequestId CreateRequestId'` returned `[]`; `gh search prs --repo temporalio/temporal 'ResetWorkflowExecution RequestId CreateRequestId'` returned `[]`.
- Phrase search run: `gh search issues --repo temporalio/temporal '"Duplicated reset request" "reset workflow"'` returned `[]`; `gh search prs --repo temporalio/temporal '"findStartRequestID" OR "original start request ID"'` returned `[]`.
- Additional search for `"reset" "same request id"` returned one unrelated issue, `https://github.com/temporalio/temporal/issues/8901`, about replay-on-retry for completed activities, not Reset request deduplication.
- Local git history search after fetch showed reset/current and callback-request-id PRs, including `#9479` and `#10926`, but no commit or PR reporting that identical `ResetWorkflowExecution` requests create another run instead of returning the first reset result.
- Known-status conclusion for this mechanism at this site: `NEW`.
