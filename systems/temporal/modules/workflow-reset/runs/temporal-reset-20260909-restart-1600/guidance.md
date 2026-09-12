# Temporal: Reset Persistence and Retry Identity

## Goal

Investigate Workflow Reset's persistence, retry identity, and recovery behavior in depth, and execute the relevant modeling and testing work to establish execution outcomes and recoverability.
Apply sustained effort to the complete failure and recovery paths, and produce evidence that can withstand maintainer scrutiny.
Pursue both formal verification and code review within your assigned phase and preserve the evidence across handoffs. Follow identity and error-handling behavior through to public-API observations with the same care as complex crash interleavings.

## Scope and boundary

- Investigate `temporalio/temporal` at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; record the actual revision and relevant configuration before drawing conclusions.
- Focus on single-cluster Reset by an explicit base Run ID, especially when a newer current run was deleted while older runs survive, and on ordinary Reset paths needed to compare retry behavior.
- Follow Continue-As-New chains, public deletion, concurrent starts/resets, and event reapplication only where they determine the Reset outcome. Keep multi-cluster replication, general Activity retry, CHASM migration, and queue fairness outside the primary scope.
- Treat this as an independent investigation. Reuse relevant infrastructure and evidence, but establish Reset's own contracts and persistence boundaries.

## Prioritized questions

1. If a failure or process loss occurs after persisting the base-to-reset link but before creating the new current run, or either write returns an uncertain outcome, can retry/reload leave an unrecoverable execution, return success for an unavailable or incorrect Run, or silently lose required work? Follow the public retry path and the final durable/client-visible outcome.
2. Does the Reset request ID retain the identity needed for retry deduplication from the API through new-run construction and persistence? Trace its relationship to the original workflow-start request ID, callback identity, `CreateRequestId`, and any request-ID maps. Can replaying the exact same request, both with and without response loss, unexpectedly reset again or terminate the run created by its first successful execution? Establish the promised deduplication scope and distinguish a retry from a separately requested administrative reset.
3. If a competing Start or Reset creates or changes the current execution after the missing-current decision, can the original operation commit a stale link, overwrite an unrelated run, or produce an outcome incompatible with the permitted ordering of those requests? Inspect leases, current-record conditions, error propagation, and retry; establish which termination and replacement behaviors are intentionally allowed.
4. When Reset traverses a surviving Continue-As-New chain or rebuilds history after a partial failure, can an eligible Signal/Update be omitted, reapplied from an inappropriate run, or duplicated beyond the requested reset semantics? Follow branch identity, request identities, reapply options, and final history, accounting for intentional reexecution.
5. When deletion intersects a failed or retried Reset, can cleanup remove history still required by a reachable execution or prevent recovery of an acknowledged operation? Reach the relevant state through supported APIs and verify deletion conditions and recovery/cleanup paths before interpreting intermediate records.

## Interactions that must be followed

- Trace `resetworkflow.Invoke` through base/current lease acquisition, request-ID deduplication, reset-run construction, event reapplication, `persistToDB`, cache release, and response construction.
- Compare the missing-current persistence path with paths where base and current are equal or distinct. Trace identifiers and conditions through every transaction wrapper into the selected database backend and back into retry lookup.
- Follow consumers of the persisted reset link and current pointer, including completion lookups and deletion where relevant. Separate an internal intermediate record from a result the public API has acknowledged.

## Caller, environment, and fault assumptions

- The missing-current path deliberately uses separate writes. Its temporary base link need not point to an already-created run; establish the required observable and recovery contract before interpreting intermediate state.
- Reset may intentionally terminate a current run and replay earlier work. Establish API identity, conflict, and reapplication semantics before labeling repeated business execution or current-pointer movement incorrect.
- Preserve each backend's actual transactions, conditional writes, and ownership checks. Distinguish definite rejection, committed-but-response-lost, and delayed uncertain completion; verify stored outcomes after failure.
- Create missing-current states through legitimate run creation/Continue-As-New/deletion scenarios. If direct database editing is used for diagnosis, separately demonstrate that a supported path reaches the relevant state.
- Progress claims require eventual healthy persistence and the retries required by the operation. Record retention, explicit deletion, and worker-availability conditions that materially affect any recoverability claim.

## Investigation and evidence requirements

Apply these requirements in the responsible pipeline phase and preserve the evidence across handoffs.

- Address every priority question, then investigate adjacent questions grounded in the code. Follow identifier assignments and reads end to end; comments, helper names, and existing dedup checks do not establish that the intended value reaches them.
- Verify concrete code-review observations even if they are simple or outside the eventual model. Check full caller/callee paths and compensating mechanisms, then establish their behavior through execution and evidence; a local helper alone does not establish end-to-end behavior.
- Reuse existing Reset and history-cleanup functional tests, adding focused request replay and fault schedules. Check exact request/response IDs, execution status, reset links, current execution, history, and post-recovery behavior.
- Validate a code-grounded model against relevant real execution traces. Treat required behavior as a contract to test, and preserve intended intermediate states; do not assume recovery succeeds or encode the desired outcome as a precondition.
- Verify observed behavior through public handlers and the relevant durable backend. Verify the injected failure actually occurred and examine readback/restart behavior; provide reproducible commands, outputs, and meaningful controls. State any mock-only or test-hook limitations.
- Continue through recovery to establish the final observable outcome. If exploration stalls, identify and address the concrete modeling, harness, or execution problem within the allocated resources; an unfinished search remains INCOMPLETE.
- For each question and code-review observation, report the actual path checked, evidence, result, and unresolved gap. Distinguish model-checking results, code-review observations, test results, documented behavior, and incomplete work; report unexpected outcomes faithfully.
- Check current upstream discussions and relevant changes when interpreting results. Complete feasible verification work and identify exact remaining blockers without presupposing a result.

## Source entry points and known context

- `service/history/api/resetworkflow/api.go`: `Invoke`, request-ID deduplication, and `shouldTolerateMissingCurrentExecution`; `service/history/ndc/workflow_resetter.go`: `ResetWorkflow`, `prepareResetWorkflow`, `persistToDB`, and reapplication paths.
- `service/history/workflow/transaction_impl.go`, `common/persistence/sql/execution.go`, `common/persistence/cassandra/mutable_state_store.go`, and `service/history/shard/context_impl.go`: transaction conditions, error handling, and staged deletion.
- Reuse `tests/reset_workflow_test.go` (including `TestResetWorkflowByRunID_CurrentExecutionMissing`), `tests/workflow_reset_test.go`, `tests/history_node_cleanup_test.go`, and the testcore/persistence fault injectors; follow the target's test instructions.
- [#10926](https://github.com/temporalio/temporal/pull/10926) introduced missing-current Reset handling and documents its deliberate write ordering; examine how that behavior interacts with the current code. [#10673](https://github.com/temporalio/temporal/pull/10673) is related replication context.
- Relevant contract context includes [#6375](https://github.com/temporalio/temporal/issues/6375) (Update retry across Continue-As-New), [#6952](https://github.com/temporalio/temporal/issues/6952) (Activity retry expiration after Reset), and [#6513](https://github.com/temporalio/temporal/pull/6513) (completed-Update reapplication).
