Finding: CR-2
Source head: 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
Source: Code Review

Scope
- Investigated the missing-current Reset path only.
- Did not read spec files, bug-report.md, confirmed-bugs.md, other findings, or shared repair-request queues.

Code path
- service/history/api/resetworkflow/api.go:61 enters the public ResetWorkflowExecution handler through resetworkflow.Invoke.
- service/history/api/resetworkflow/api.go:72-100 acquires the explicit base workflow lease and calls GetCurrentWorkflowRunID.
- service/history/api/resetworkflow/api.go:235-248 deliberately tolerates a missing current only when the caller supplied an explicit base run ID.
- service/history/api/resetworkflow/api.go:108-112 leaves currentWorkflowLease nil when the current row is missing.
- service/history/api/resetworkflow/api.go:136-148 performs retry deduplication only when a current workflow lease exists.
- service/history/api/resetworkflow/api.go:150-217 constructs a new reset run ID and calls ndc.WorkflowResetter.ResetWorkflow.
- service/history/ndc/workflow_resetter.go:133-148 sets base UpdateResetRunID(resetRunID) before persistence.
- service/history/ndc/workflow_resetter.go:388-395 documents that, with a missing current, base mutable state and new current execution cannot be committed atomically and base is written first.
- service/history/ndc/workflow_resetter.go:396-430 implements the split write: UpdateWorkflowExecution using UpdateWorkflowModeBypassCurrent, then CreateWorkflowExecution using CreateWorkflowModeBrandNew.
- common/persistence/sql/execution.go:61-120 and 365-395 show SQL create/update history-first then metadata writes and the BypassCurrent current-row assertion.
- common/persistence/cassandra/mutable_state_store.go:383-403 and 885-903 show the analogous Cassandra create/update behavior and missing-current tolerance.
- service/history/shard/context_impl.go:539-679 wraps create/update persistence with shard ownership and write error handling.

Reachability and consumers
- tests/reset_workflow_test.go:1033-1160 already reaches the missing-current state through public workflow start/continue-as-new/delete APIs, then resets by explicit older run ID and checks the reset run becomes current.
- service/history/api/describeworkflow/api.go:144-150 exposes WorkflowExtendedInfo.ResetRunId through the public DescribeWorkflowExecution response.
- service/history/api/recordchildworkflowcompleted/api.go:101-105 may redirect a child completion through ResetRunId when the parent completed by reset.
- service/history/transfer_queue_active_task_executor.go:477-486 and service/history/ndc/workflow_state_replicator.go:591-599 also consume ResetRunId in guarded paths.

Developer intent
- Git history shows #10926 introduced the missing-current Reset behavior for issue #10690, including the documented split write and the statement that base-first ordering makes retries safe.
- The intended contract is that Reset by explicit base run ID should succeed when the current execution row is missing.

Prior-report search
- Searched upstream issues and PRs with gh for:
  - "missing current reset"
  - "UpdateWorkflowModeBypassCurrent CreateWorkflowModeBrandNew"
  - "ResetRunId missing current"
  - "workflow reset current deleted"
  - "workflow not found reset runId"
  - "CreateWorkflowModeBrandNew reset"
  - "UpdateWorkflowModeBypassCurrent reset"
- Reviewed relevant git history for reset/current-execution changes:
  - #10690 reports Reset failing when the current execution is deleted.
  - #10926 fixes Reset-by-explicit-run-ID with missing current and documents the split write.
  - #11257 and #11052 cover replication-side missing-current reconstruction and zombie/orphan application, not this Reset API split-write retry mechanism.
- No issue or recently merged/closed PR was found that reports the CR-2 mechanism: a missing-current Reset leaving an incomplete durable base link across retry.

Phase-1 result
- No prefilter drop: the same mechanism appears new.
- The split intermediate state is real by code review and test instrumentation, so Phase 2 reproduction was required to decide whether it becomes a real public failure, a masked intermediate, or a false-positive candidate.
