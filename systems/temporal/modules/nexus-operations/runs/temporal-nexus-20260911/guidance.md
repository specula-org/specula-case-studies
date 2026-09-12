# Temporal: Nexus Operation Commit and Recovery

## Goal

Investigate Temporal's Nexus operation lifecycle in depth, execute the modeling and verification work, and establish what formal exploration contributes beyond source review and existing tests.
Pursue concrete questions with sustained effort. Work through difficult failure paths within your assigned phase, preserve evidence across handoffs, and finish feasible checks within the allocated resources.

## Scope and boundary

- Investigate `temporalio/temporal` at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; record the revision, persistence backend, and relevant configuration.
- Focus on a Nexus operation belonging to one Workflow Run in one cluster, using the implementation in `service/history/hsm/nexusoperations`: start, retry/backoff, asynchronous completion, cancellation, timeout, durable transitions, and recovery.
- Confirm routing and feature settings before building the harness. Keep standalone CHASM Nexus operations, migration, Reset/Continue-As-New identity, multi-cluster replication, and endpoint administration outside the primary model. Follow their interfaces only when needed to establish reachability or compensation.

## Prioritized questions

1. If completion arrives before a start response or before local start-state persistence, or overlaps timeout/cancellation, do duplicate and late callbacks converge on the contractually valid terminal result? Which identities distinguish operations and attempts across synchronous and asynchronous starts?
2. If the remote endpoint accepts a start but its response is lost, or the subsequent local persistence fails, does retry/reload preserve the request identity and any operation token needed to reconnect with the accepted operation? What guarantees depend on the remote endpoint's idempotency contract?
3. If cancellation is requested while an operation is scheduled, backing off, starting, or already started, then completion or timeout intervenes, does the durable request retain a valid execution path or become legitimately subsumed by terminal completion? How does acknowledgment of a cancel request differ from an operation finishing as canceled?
4. After retries, deadline changes, cache loss, or shard reacquisition, can delayed tasks or stale HSM references act on a newer attempt or revive terminal state? Does reconstruction regenerate every still-required invocation, backoff, timeout, and cancellation task under the implementation's eligibility rules?
5. When an HSM transition, Workflow History or buffered event, task publication, and caller-visible outcome cross persistence and notification boundaries, can an uncertain write or workflow closure leave their durable outcomes inconsistent? What is recoverable after reload, and when is deleting terminal state allowed?

## Interactions and assumptions

- Follow Workflow commands through Nexus state transitions, outbound task execution and endpoint responses, completion handling, history/mutable-state persistence, task regeneration, and actual subsequent observations.
- Establish real backend atomicity and conditional-write guarantees; separate an external endpoint's effect from Temporal's local commit and from response receipt. Do not interpret every persistence error as proof of noncommit.
- Check every identity field and reference validation on real call paths. Distinguish a duplicate delivery permitted by the protocol from an inconsistent durable outcome; do not demand exactly-once external effects without the corresponding endpoint contract.
- State the endpoint, timer, scheduler, and recovery assumptions needed for progress. Do not turn a remote refusal, legitimate terminal timeout, or documented cancellation semantics into a stronger completion guarantee.

## Phase 1: investigation and handoff

- These questions are a coverage floor. Investigate adjacent source-derived questions within this boundary and retain concrete code-review observations even if they do not fit the eventual model.
- Read complete relevant success, failure, and recovery paths, including callback entry points and HSM access validation. For each promising observation, establish reachability, examine compensation, check existing tests/history, and hand off a precise executable question with source evidence.
- Refresh relevant upstream discussions before claiming novelty. Do not stop at an architecture summary or combine assumptions from the legacy HSM and CHASM implementations.

## Model, harness, and verification phases

- Derive contracts and abstractions from this implementation. Concentrate on the coupled start/completion/cancellation/recovery questions above; model the failure boundaries that decide whether local and remote work remain reconcilable.
- Validate complete implementation traces of the modeled state, including independent evidence for endpoint outcomes, HSM/attempt identity, local persistence, pending tasks, and post-reload observations. Record observation provenance and endpoint completeness; use negative controls to test that incorrect observations are rejected.
- Reuse meaningful Nexus functional tests, then execute focused callback and persistence fault schedules where evidence is missing. Workflow History alone may omit an outbound attempt; repair missing observations or model/trace mismatches by investigating their cause.
- Complete meaningful bounded exploration containing the critical failure interactions. If a search grows too large, diagnose the cause, execute justified narrower checks, and explain their composition limits. Preserve unfinished searches as INCOMPLETE; do not repeatedly relaunch the same oversized search or discard a concrete lead because it is outside a completed baseline.

## Confirmation and final evidence

- Independently validate concrete code-review observations even when model checking is incomplete or not their discovery method. Follow them through real handlers and relevant persistence, including readback/reconstruction whenever the conclusion depends on durability or recovery.
- Show the injected fault and callback ordering actually occurred, retain exact commands and outputs, and include a healthy control. A controlled endpoint may establish protocol ordering; an in-memory HSM alone does not establish durable recovery. State the limits of test hooks and mocked neighbors.
- For each priority question and observation, report checked paths, evidence, result, and remaining gap. Separate source-review discovery, model-checking discovery/reconfirmation, reproduced behavior, masked outcomes, known behavior, and INCOMPLETE coverage. Evidence may support correct behavior; do not assume an adverse outcome is required.

## Source entry points

- `service/history/hsm/nexusoperations/workflow/commands.go:35` (`HandleScheduleCommand`) and `:244` (`HandleCancelCommand`); `service/history/hsm/nexusoperations/statemachine.go:172` and `:543` (operation and cancellation `RegenerateTasks`).
- `service/history/hsm/nexusoperations/{executors.go,completion.go,tasks.go,events.go}`, including operation transitions and cancellation transitions in `statemachine.go`.
- `service/history/hsm/tree.go`, `service/history/hsm/tasks.go`, the History callback handlers, workflow persistence, and the actual HSM task/reference validation callers.
- Reuse `tests/nexus_api_test.go`, related Nexus functional tests, `tests/testcore/test_env.go`, and `common/persistence/faultinjection/fault.go` (`ExecuteAndTimeout`); read `docs/architecture/nexus.md` alongside the pinned implementation.
