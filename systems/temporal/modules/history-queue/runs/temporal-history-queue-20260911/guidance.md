# Temporal: History Queue Checkpoint and Recovery

## Goal

Investigate Temporal's durable History task processing in depth, execute the modeling and verification work, and establish what formal exploration contributes beyond source review and existing tests.
Pursue concrete questions with sustained effort. Work through difficult failure paths within your assigned phase, preserve evidence across handoffs, and finish feasible checks within the allocated resources.

## Scope and boundary

- Investigate `temporalio/temporal` at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; record the revision, persistence backend, and relevant configuration.
- Focus on one cluster and one History shard's immediate Transfer queue: durable task publication, readers and slices, execution/retry, checkpointing, range deletion, and ownership recovery. Use ordinary Workflow/Activity dispatch to establish real executor outcomes.
- Follow adjacent callers and callees needed to establish eligibility, compensation, or an externally visible consequence. Treat downstream Matching acceptance/retry as an explicit interface contract; keep Matching's backlog internals, timer scheduling, replication, visibility, archival, and CHASM migration outside the primary model.

## Prioritized questions

1. When a workflow transaction publishes tasks, can an uncertain commit, delayed writer, missing notification, or ownership reload put required work behind a read boundary without a recovery path? How do task allocation, pending writes, and the exclusive high watermark interact?
2. When execution completes out of order or tasks retry while slices split, merge, shrink, or move between readers, do scope boundaries and predicates preserve every unfinished obligation through checkpoint and reload? Can a task fall into a gap or become eligible only in an abandoned reader?
3. When range deletion and queue-state persistence occur separately, what happens if either fails, its reply is lost, or ownership changes between them? Can checkpoint recovery skip unfinished work, or leave completed rows permanently unreachable for cleanup? Establish when a lagging durable checkpoint is intentional and safe.
4. When an old reader or executor finishes after shard ownership changes, which writes and side effects are fenced, and which depend on idempotency or retry? Can late completion or checkpoint publication invalidate the new owner's recovery boundary?
5. When an executor's downstream effect succeeds but its response is lost, or error handling acknowledges, retries, safely drops, or transfers a task to a DLQ, is the original obligation satisfied or recoverable under the actual contract? Under eventual recovery and finite transient failures, can eligible work remain stranded?

## Interactions and assumptions

- Follow task creation in the workflow transaction through persistence reads, reader/slice bookkeeping, the concrete Transfer executor, acknowledgment, checkpoint persistence, deletion, and reconstruction from durable state.
- Establish actual transaction, conditional-write, range, and ownership guarantees for the selected backend. Do not split an atomic mutation or treat every timeout as a definite noncommit.
- Read both sides of every handoff and the compensating paths. Distinguish stale tasks whose workflow obligation is already satisfied from tasks still required for progress; establish durable DLQ acceptance before treating transfer there as completion.
- State the downstream delivery/idempotency contract and all progress assumptions. Ordinary duplicate task delivery is permitted; a downstream acknowledgment and completed workflow execution are different observations.

## Phase 1: investigation and handoff

- These questions are a coverage floor. Investigate adjacent source-derived questions within this boundary and retain concrete code-review observations even if they do not fit the eventual model.
- Read complete relevant success, failure, and reload paths. For each promising observation, establish reachability, examine compensation, check existing tests/history, and hand off a precise executable question with source evidence.
- Refresh relevant upstream discussions before claiming novelty. Do not stop at an architecture summary or infer a failure from a helper's name or an isolated field assignment.

## Model, harness, and verification phases

- Derive the model's contracts and abstractions from the implementation. Concentrate on the coupled failure/recovery questions above; preserve the physical boundaries that decide whether work is durable or recoverable.
- Validate complete implementation traces of the modeled state, including independent evidence for persistence outcomes, reader/slice state, executor results, and post-reload boundaries. Record observation provenance and endpoint completeness; use negative controls to test that incorrect observations are rejected.
- Reuse real queue and functional tests, then execute focused fault schedules where evidence is missing. Repair instrumentation or model/trace mismatches by investigating their cause; a passing happy path does not complete the investigation.
- Complete meaningful bounded exploration containing the critical failure interactions. If a search grows too large, diagnose the cause, execute justified narrower checks, and explain their composition limits. Preserve unfinished searches as INCOMPLETE; do not repeatedly relaunch the same oversized search or discard a concrete lead because it is outside a completed baseline.

## Confirmation and final evidence

- Independently validate concrete code-review observations even when model checking is incomplete or not their discovery method. Follow them through real handlers and relevant persistence, including readback/reconstruction whenever the conclusion depends on recovery or deletion.
- Show the injected fault actually occurred, retain exact commands and outputs, and include a healthy control. State where mocks, controlled scheduling, or test hooks limit the conclusion; distinguish logical inaccessibility, delayed recovery, and physical row deletion.
- For each priority question and observation, report checked paths, evidence, result, and remaining gap. Separate source-review discovery, model-checking discovery/reconfirmation, reproduced behavior, masked outcomes, known behavior, and INCOMPLETE coverage. Evidence may support correct behavior; do not assume an adverse outcome is required.

## Source entry points

- `service/history/queues/queue_base.go:295` (`checkpoint`), `:373` (`rangeCompleteTasks`), `:397` (`updateQueueState`); `queue_immediate.go`, `reader.go`, `slice.go`, `scope.go`, and `action_*.go` in the same directory.
- `service/history/queues/executable.go:584` (`HandleErr`), `:742` (`Ack`), and its execution, DLQ, retry, and rescheduling paths; `service/history/transfer_queue_active_task_executor.go` and `transfer_queue_task_executor_base.go`.
- `service/history/shard/context_impl.go:351` (read watermark), `:376` (`SetQueueState`), `:2030` (`acquireShard`), plus shard task-key allocation and the implicated persistence implementation.
- Reuse queue reader/slice/executable tests, `tests/testcore/test_env.go`, and `common/persistence/faultinjection/fault.go` (`ExecuteAndTimeout`); establish durable recovery using a real store rather than only a memory fake.
