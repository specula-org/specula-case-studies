# Trace coverage

The real corpus validates 52 distinct action names among 61 wrappers. This denominator counts model boundaries, not Temporal product coverage.

Full state equality, exact state domain, provenance, TraceMatched and the final endpoint are enforced. Every state comes from implementation observations or explicitly documented observer bookkeeping.

## Remaining unobserved interfaces

- `DiscardClosedWorkflowTimer`: Core endpoints keep the Workflow open.
- `DiscardObsoleteActivityTask`: The real corpus did not enter the producer-side obsolete-return path.
- `ExecuteWorkflowRunTimeoutTask`: WorkflowExpiration=0 in the core.
- `ExpireRecordActivityTaskStarted`: Immediate lost-response recovery and live-child retry ran; actual child-deadline expiry did not.
- `HandleCommandCancelAndCompleteWorkflow`: Same-command Workflow closure remains a separate contract.
- `HandleCommandCancelBufferedActivity`: The corpus exercises rejected close and cancellation outcomes, not this command-batch branch.
- `HandleCommandCompleteWorkflow`: Core endpoints finish after WFT consumption with an open Workflow.
- `LoseAddActivityTaskResponse`: The controlled loss is History-start response or timeout acknowledgement, not this AddTask response boundary.
- `RejectPersistenceWrite`: Definitely skipped writes use Timeout injection; a separate definite non-timeout rejection was not injected.

These are explicit unobserved branches, not passing trace coverage. The configured scenario hunts explore additional schedules within their recorded bounds. No synthetic control is counted as a real execution.
