# CR-3 Investigation Notes

Source revision checked: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.

## Code Path

- `RespondWorkflowTaskCompleted` constructs one `effect.Buffer` for a completed Workflow Task, handles update protocol messages, handles workflow close commands, persists mutable state, and then either cancels or applies the full effect batch.
- `effect.Buffer.Cancel` drops after-commit effects and runs rollback callbacks in reverse order; `effect.Buffer.Apply` drops rollback callbacks and runs after-commit effects in append order.
- Accepted, completed, rejected, and workflow-close effects can therefore be registered in the same WFT and become visible to waiting update callers only after persistence returns.
- `Updater.OnSuccess` builds the public `UpdateWorkflowExecutionResponse`. Its link-selection branch treats every `COMPLETED` response with a failure outcome as a rejected update and returns a workflow link with reason `Update rejected`. That is correct for a real rejection, but not for an accepted update whose handler failed after writing accepted/completed events.
- The transaction-size close fallback terminates the workflow and then persists a second mutable-state write. If that close write fails, the handler returns before `updateRegistry.Abort(...)`, but the close-abort rollback effect has already completed accepted update waiters with a workflow-completed failure.

## Prior Report Search

Searched upstream issues and recently merged/closed PRs for the exact mechanisms:

- `Update rejected` + `Link`
- `WorkflowExecutionUpdateAccepted` + `WorkflowExecutionUpdateCompleted` + `Update rejected`
- `AcceptedUpdateCompletedWorkflow`
- `response link` + `workflow update`
- `GetLink` + `UpdateWorkflowExecution`
- `UpdateWorkflowExecutionResponse` + `Link`

No existing issue/PR reported this accepted-handler-failure response-link misclassification or the failed-close-write caller/durable-state divergence.

Related but not the same:

- temporalio/temporal#6630 documents/fixes the intended accepted-update close behavior: accepted updates should receive a completion failure when the workflow closes before the update completes.
- temporalio/temporal#9614 introduced workflow-update callback/link support.
- temporalio/temporal#10478, #10775, and #11254 cover different update dispatch/deduplication problems.

Novelty status: NEW for this mechanism.

## Reproduction

Wrote and executed `repro/test_bugCR-3_mixed_outcomes.sh`.

The wrapper creates temporary Go tests under `tests/cr3_repro_external_test.go`, runs:

```bash
timeout 10m env TMPDIR=/home/ubuntu/tmp GOTMPDIR=/home/ubuntu/tmp go test -tags=test_dep ./tests -run '^(TestCR3MixedUpdateBatchResponseLink|TestCR3FailedCloseWriteConflictingOutcome)$' -count=1 -v
```

Observed exit status: 0.

Evidence:

- Level 0 mixed WFT: one WFT persisted successful update completion, accepted handler failure completion, rejection, and workflow close. The accepted handler failure had accepted/completed history events but the public update response returned a workflow link with reason `Update rejected`.
- Level 1 failed close write: after a supported runtime history limit forced close fallback and the injected persistence timeout prevented the termination write, the original update caller observed a completed workflow-closed failure while durable readback still showed `RUNNING` and the update accepted but not completed. After restoring the runtime limit, the same WFT completion persisted the update success, so a later poll of the same update ID observed success.

Decision: REPRODUCED.
