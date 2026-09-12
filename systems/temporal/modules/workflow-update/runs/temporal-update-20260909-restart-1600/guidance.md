# Temporal: Update Commit and Recovery

## Goal

Investigate Temporal's Workflow Update commit and recovery paths in depth, execute the relevant modeling and testing work, and establish what formal modeling contributes beyond code review and existing tests.
Pursue this investigation with sustained effort and produce evidence that can withstand maintainer scrutiny.
Within your assigned phase, work through difficult error paths and resolve promising leads within the allocated resources; hand off concrete evidence and actionable unresolved questions to subsequent phases.

## Scope and boundary

- Investigate `temporalio/temporal` at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; record the actual revision and relevant configuration before drawing conclusions.
- Focus on one cluster and the lifecycle of Updates within a Workflow Run: normal and speculative Workflow Tasks (WFTs), persistence outcomes, effect publication, cache replacement, duplicate requests, and final workflow closure.
- Follow adjacent code when needed to establish a trigger, compensation, or user-visible consequence. Keep cross-run Reset/Continue-As-New, replication, CHASM migration, and queue fairness outside this run's primary scope.

## Prioritized questions

1. When persistence fails, succeeds with a lost response, or commits before a later handler error, can cache clearing or effect cancellation cause a caller to observe unsupported success, lose access to a committed Update result, or receive conflicting successful outcomes after retry? Establish the acceptance/completion contract and follow the operation through recovery and caller receipt.
2. When a speculative WFT or Update registry is replaced while an old completion response or timeout remains in flight, can that old work affect a replacement task, suppress delivery of the retried Update, or leave callers without a recovery path? Check every identity field and downstream validation used by the actual handlers.
3. When acceptance, completion, rejection, and workflow closure occur in different permitted combinations, including within one WFT, can effect ordering and concurrent waiting expose an outcome inconsistent with the durable stage or the documented close behavior? Distinguish legitimate rejection/abort from loss or contradictory success.
4. When direct speculative dispatch fails, times out, or races cache replacement, do fallback scheduling and same-ID client retry preserve a path to the contractually required result? Could in-memory deduplication remember a request after the work needed to handle it has disappeared?

## Interactions that must be followed

- Trace the public Update request through admission/deduplication, WFT scheduling, Matching, worker protocol messages, persistence, after-commit/rollback effects, and the actual response or subsequent result lookup.
- Read the complete relevant callers and callees across success, failure, retry, and cache-reload paths. Compare normal, speculative, and legitimate persistence-skipping paths.
- Reconcile workflow leases with unlocked client waiters, registry object lifetime with durable Update identity, and database return values with the actual stored outcome.

## Caller, environment, and fault assumptions

- Establish API semantics from documentation and current code. Ordinary admission may be volatile; rejection may leave no durable event; accepted-but-unfinished Updates may fail when the workflow closes. Do not silently strengthen these contracts.
- Preserve real backend transaction and conditional-write guarantees. Check the separate History append and execution-state/task commit boundaries; interpret an uncommitted physical history tail using those guarantees.
- Exercise process/cache loss, delayed or duplicate requests, and uncertain write outcomes that can occur on supported paths. Establish which errors prove noncommit and which require readback or shard reacquisition.
- Progress claims require eventual service recovery, available workers, processing of eligible timers/tasks, and any client retries required by the API. Distinguish timeout-delayed recovery from a permanently lost path.

## Investigation and evidence requirements

Apply these requirements in the responsible pipeline phase and preserve the evidence across handoffs.

- These questions are a coverage floor. Investigate adjacent code-derived questions after addressing them, and verify concrete code-review observations even when model checking is not the appropriate tool.
- Do not stop at an architecture summary or passing happy-path tests. For each behavior under investigation, identify the reachable conditions, examine all compensating mechanisms, and establish what happens through execution and evidence.
- Reuse meaningful functional tests; add focused fault schedules where coverage is missing. Validate implementation traces that expose persistence outcomes, cache transitions, effect publication, and caller observations; Workflow History alone does not expose every relevant transition.
- Ground the model in the implementation. Treat expected behavior as something to test; never assume the desired result or weaken a property merely to eliminate a counterexample. Investigate model/trace disagreement before concluding either implementation failure or safety.
- Verify observed behavior through real handlers and the relevant persistence implementation, using restart/readback where the conclusion depends on durability. Show that the fault actually occurred, preserve commands and outputs, and include a healthy control when useful. State the assurance limits of mocks and test hooks.
- If broad exploration stalls, identify the cause and make a focused, justified adjustment while preserving the behavior under investigation. Do not repeatedly launch the same oversized search or call an unfinished search a pass.
- For each priority question and code-review observation, record the checked paths, evidence, result, and remaining gap. Distinguish model-checking results, code-review observations, test results, documented behavior, and INCOMPLETE coverage; report unexpected outcomes faithfully and state concrete user impact.
- Refresh relevant upstream issue/PR discussions when interpreting results. Finish all feasible verification work; document exact blockers and unexecuted checks rather than replacing missing evidence with confidence.

## Source entry points and known context

- `service/history/api/updateworkflow/api.go`: `Updater.ApplyRequest` and `Updater.OnSuccess`; `service/history/api/respondworkflowtaskcompleted/api.go` and `workflow_task_completed_handler.go`.
- `service/history/workflow/update/{update.go,registry.go,abort_reason.go}`, `service/history/workflow/context.go`, `service/history/workflow/workflow_task_state_machine.go`, and `common/effect/buffer.go`.
- `common/persistence/sql/execution.go`, `common/persistence/cassandra/execution_store.go`, and `service/history/shard/context_impl.go`: follow the implicated backend and uncertain-write handling.
- Reuse `tests/update_workflow_test.go`, `tests/testcore/test_env.go`, and `common/persistence/faultinjection/fault.go` (including `ExecuteAndTimeout`); follow the target's test instructions.
- Historical changes [#5349](https://github.com/temporalio/temporal/pull/5349), [#5784](https://github.com/temporalio/temporal/pull/5784), and [#6308](https://github.com/temporalio/temporal/pull/6308) provide context for these mechanisms. Check existing discussions [#10478](https://github.com/temporalio/temporal/issues/10478), [#10775](https://github.com/temporalio/temporal/issues/10775), and [#11254](https://github.com/temporalio/temporal/pull/11254) against the pinned implementation when interpreting results.
