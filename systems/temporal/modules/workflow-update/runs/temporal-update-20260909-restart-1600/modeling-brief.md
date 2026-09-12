# Modeling Brief: Temporal Update Commit and Recovery

## 1. System Overview

- **System:** `temporalio/temporal`, Go; pinned production revision `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; 11,413 physical lines across the 12 requested core files, excluding tests and additional callees.
- **Category A (Distributed / Message-Passing):** Frontend, History, Matching, workers, persistence, and timers interleave despite a per-Workflow lease; this is crash/recovery analysis, not BFT or a weak-memory model.
- **Algorithm:** durable Workflow execution through History events, execution metadata, internal tasks, worker replay, and message-based Updates; no single consensus paper specifies the Update API contract.
- **Implementation choices:** ordinary admission and speculative WFTs can be volatile; rejection need not persist; acceptance/completion use durable event references; effects publish futures after commit or a legitimate persistence skip (`docs/architecture/workflow-update.md`; `respondworkflowtaskcompleted/api.go:676-726`).
- **Concurrency:** state/registry methods require the Workflow lease; `WaitLifecycleStage` uses thread-safe futures outside it; direct Matching dispatch releases the lease to permit task-start reentry (`update/update.go:155-253`; `updateworkflow/api.go:251-265`).
- **Boundary:** one cluster, namespace, Workflow Run; normal/transient/speculative WFTs, failures, timers, cache replacement, duplicate Updates, final closure. Exclude cross-run Reset/Continue-As-New, replication, CHASM migration, and queue fairness.
- **Evidence status:** five test-backed review observations: four through public APIs/SQLite, one through the real timer queue/executor with mocked persistence. Zero maintainer-confirmed new bugs and zero MC discoveries. No TLA+ model or trace-validation run is claimed by this Code Analysis handoff; see [analysis-report.md](analysis-report.md).

## 2. Scenarios

### Scenario 1: A write result, published effect, and caller receipt are different events

**Mechanism:** a durable mutation can commit even when its caller receives an error, while an appended physical History batch can exist without a committed execution mutation.

**Evidence:**
- Historical context only: [#5349](https://github.com/temporalio/temporal/pull/5349) moved effect publication immediately after commit; [#5784](https://github.com/temporalio/temporal/pull/5784) coupled registry and Workflow-context clearing. Preserve both repairs.
- Code: SQL appends History before its execution transaction (`common/persistence/sql/execution.go:338-357`); Cassandra appends before its conditional batch (`common/persistence/cassandra/execution_store.go:110-125`); uncertain execution errors force shard reacquisition (`service/history/shard/context_impl.go:1477-1557`).
- Code: `service/history/api/respondworkflowtaskcompleted/api.go:676-726` separates write failure/cancellation from immediate successful publication; later response assembly can still fail at `:750` onward.
- Tests: eight public-API cases cover normal/speculative WFTs with healthy writes, `Timeout`, `ExecuteAndTimeout`, and lost Update responses; direct SQLite readback and shard reload recover one accepted/completed result. Backend file reopen separately tests committed metadata and tasks versus uncommitted History tails. [Evidence](analysis-evidence/tests/commit-recovery-v2.log).
- Open known mechanism, new path to investigate: [#11660](https://github.com/temporalio/temporal/pull/11660) concerns cached uncommitted events surviving shard replacement. Update completion also populates that cache before commit (`mutable_state_impl.go:5899`); outcome lookup checks event type but not the event's Update ID (`:1544-1589`). Wrong-Update successful-result exposure is source-supported but **not reproduced**.

**Affected code paths:** `Updater.Invoke/ApplyRequest/OnSuccess`, WFT completion, `ContextImpl.UpdateWorkflowExecutionWithNew`, SQL/Cassandra execution stores, shard write handling/acquisition, `Registry.Find`, `GetUpdateOutcome`, PollUpdate.

**Suggested modeling approach:**
- Variables: physical History batches, committed boundary/UpdateInfo, record version, shard range, write outcome, effects, registry generation, per-host event cache, per-call observed stage/outcome.
- Actions: append History; atomic conditional execution/task commit; return write result; publish or cancel effects; assemble/send/lose response; clear/reload cache; resubmit or poll.
- Granularity: split these real boundaries, but keep each backend execution metadata/task transaction atomic. Error reporting is independent of whether the operation committed; do not permit every error class to mean either outcome.
- For the cache question, use two History hosts in the same cluster: cache event creation before commit, retain host cache across shard replacement, and distinguish host restart/TTL eviction. Use its actual five-field key; do not assume an outcome lookup always rereads persistence.

**Priority:** High.
**Rationale:** highest consequence if a successful Update result conflicts with durable recovery; existing one-Update fault tests leave the two-Update, delayed-waiter, and later-handler-error combinations unexplored.

### Scenario 2: Old work is fenced by identity, but error cleanup can affect current work

**Mechanism:** a stale completion or timer refers to an earlier speculative task while error cleanup operates on the current cached Workflow context.

**Evidence:**
- Historical context only: [#6308](https://github.com/temporalio/temporal/pull/6308), [#6394](https://github.com/temporalio/temporal/pull/6394), and [#4354](https://github.com/temporalio/temporal/pull/4354) repaired timeout lifetime, stale-state classification, and History batch boundaries.
- Code: completion validates ScheduledEventID, StartedEventID, StartedTime, Attempt, and Version (`service/history/api/respondworkflowtaskcompleted/api.go:189-231`); the deferred sticky cleanup at `:174-186` still runs on early identity rejection.
- Timer guard differs: `service/history/timer_queue_active_task_executor.go:408-433` checks timer-object identity only when the **current** WFT is speculative; otherwise it checks version/attempt after scheduled ID/stamp. **CR-6:** a real queue/executor control reproduces a canceled, already-submitted old timer timing out a replacement-normal task about one second early; persistence is mocked and full public Update confirmation remains open. Do not invent an unconditional pointer or StartedTime guard. [Evidence](analysis-evidence/state/timer/report.md).
- Tests: an old completion is rejected, then the legitimate sticky replacement also receives NotFound; a normal-queue control completes. Same-ID retry reaches another worker task and returns the correct result. This is **CR-1**, an extra invalidation/replay observation, not permanent loss. [Evidence](analysis-evidence/identity/sticky-stale-functional.log).

**Affected code paths:** completion lease release, `clearStickyTaskQueue`, task-start validation, `ContextImpl.Clear`, speculative timer removal, timer executor validation, retried admission.

**Suggested modeling approach:**
- Variables: task identity tuple, cache/registry generation, current timer identity, sticky routing, in-flight old completion, retry request identity.
- Actions: dispatch/start, replace cache, receive stale completion, execute actual deferred cleanup, fire/cancel the particular timer, retry/recover.
- Granularity: task identity validation and its subsequent cleanup are distinct observations; lease-protected state mutations remain serialized. Represent timer-object identity and scheduler-submission/cancellation state, applying pointer validation only on the actual speculative branch.

**Priority:** High.
**Rationale:** the reproduced side effect gives concrete implementation grounding; the open modeling question is recovery after compositions of delayed work and dispatch failure, not reproducing a historical missing identity guard.

### Scenario 3: Mixed Update outcomes and final Workflow closure share an effect batch

**Mechanism:** acceptance, completion, rejection, and closure can coexist in one WFT, while clients observe independently completed futures.

**Evidence:**
- Historical context only: `acbabeac7f27588975f4ab82f5addd126aabc380` repaired same-WFT acceptance/closure ordering; `e2f3b5fc6d969b6ef7875bfd24099da8d8387f77` publishes completion before acceptance for combined transitions. These are existing behavior, not hunt targets.
- Code: `common/effect/buffer.go:29-53` applies FIFO and cancels LIFO; provisional states and future publication are guarded in `service/history/workflow/update/update.go:259-320,626-788`; final close abort follows effect application (`respondworkflowtaskcompleted/api.go:726-747`).
- Contract: rejected Updates may disappear; accepted-but-unfinished Updates may return a Workflow-closing failure (`update/abort_reason.go:44-119`; `update/registry.go:124-141`).
- Tests: existing mixed-Update/close cases pass. Accepted handler failure has a correct durable outcome but a response link labeled `Update rejected` (**CR-3**); this metadata error is not contradictory successful execution.
- Limit exception (**CR-5**): a failed forced-termination write leaves durable RUNNING/Accepted state after the original caller receives a COMPLETED closing failure; restoring the runtime History limit and retrying produces business success for that same Update. The healthy termination control persists closure. This is observed failure-then-success with configuration-assisted recovery, not two conflicting business-success payloads. [Evidence](analysis-evidence/tests/force-termination-v1.log).

**Affected code paths:** protocol-command/message ordering, Update accept/respond/reject/abort, effect buffer, normal final completion/termination/timeout, PollUpdate reconstruction, unlocked waiters.

**Suggested modeling approach:**
- Variables: two Updates with provisional/committed stages, terminal outcome origin, ordered pending effects, accepted/outcome futures, Workflow running/closed state, client wait stage.
- Actions: worker message/command processing, conditional commit, each ordered effect publication, waiter observation, final close and reload.
- Granularity: allow waiter interleaving between effect callbacks; preserve actual outcome-before-acceptance publication in combined transitions and real allowed command order.

**Priority:** High.
**Rationale:** two independently waiting Updates composed with commit uncertainty and closure remain a useful systematic search beyond individual unit transitions and scripted functional schedules.

### Scenario 4: Volatile deduplication must retain a delivery or retry path

**Mechanism:** direct speculative dispatch, its in-memory timer, and cached deduplication have different lifetimes; callback attachment additionally changes how unprocessed Updates are rejected.

**Evidence:**
- Historical context only: [#5784](https://github.com/temporalio/temporal/pull/5784) fixed registry retention after task loss. [#10775](https://github.com/temporalio/temporal/issues/10775) is an unconfirmed routing/observability report, not established lost delivery.
- Code: direct Matching errors are deliberately swallowed, with speculative schedule-to-start fallback (`service/history/api/updateworkflow/api.go:256-263,317-362`; `docs/architecture/speculative-workflow-task.md:65-89`).
- Code/test: callbacks buffered while Sent make automatic `reject` fail; `Registry.RejectUnprocessed` discards that error. `HasOutgoingMessages(true)` nevertheless schedules a successor and task start resends the Update. Four ignored deliveries were observed; shard clear plus same-ID retry without callbacks restores ordinary rejection (**CR-2**). Capable-worker recovery is source-supported, not executed. [Evidence](analysis-evidence/state/callback-unprocessed-functional.log).
- Existing stale-task, lost-registry, same-ID deduplication, sticky-worker-unavailable, and schedule-to-start-timeout tests pass; these do not prove every dispatch/replacement composition.
- A new real Matching RPC-fault fixture injected two Unavailable responses for speculative event 5; the timeout generated normal event 7, which reached the worker and completed once. Original caller and same-ID retry recovered successfully. [Evidence](analysis-evidence/tests/dispatch-failure-v1.log).

**Affected code paths:** admission/deduplication, direct AddWorkflowTask, matching/start, speculative timeout conversion, resend, AttachCallbacks, RejectUnprocessed, WFT successor selection.

**Suggested modeling approach:**
- Variables: Update ID, volatile request state, dispatch result, queued/started task, eligible timer, active client retry, worker capability; keep callback presence as a small optional discriminator only when needed.
- Actions: dispatch failure or lost response, timeout-to-normal conversion, duplicate admission, resend, cache loss, client retry.
- Granularity: release the lease before Matching; preserve timer installation before dispatch and the distinction between resubmission and result polling.

**Priority:** High for delivery/recovery; Medium for the callback rejection observation.
**Rationale:** progress depends on explicit timers and API-required retries. CR-2 has additional work and delayed rejection, but the initially suspected permanently absent task was refuted.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Durable versus volatile Update/WFT state | Scenarios 1, 4 | Separate committed UpdateInfo/events from registry objects, speculative state, and futures. |
| Real persistence outcomes and shard fence | Scenario 1 | Distinguish known noncommit, uncertain no-commit, commit-with-error, and success; fence subsequent writes during reacquisition. |
| Identity and cleanup across generations | Scenarios 2, 4 | Exact task tuple, timer identity, current cache generation, delayed completion and actual cleanup action. |
| Event-cache versus committed result lookup | Scenario 1 / MC-4 | Preserve precommit cache insertion and host lifetime; test a same-type stale Update completion after ownership changes. |
| Two Updates and ordered effects | Scenarios 1, 3 | Model valid mixed messages/close and waiter observations; preserve current guards. |
| Conditional progress | Scenarios 2, 4 | Eventual service/worker recovery, eligible timer/task processing, finite disruptions, and client resubmission until acceptance. |

Start with two Update IDs, two outcome values, a bounded number of task/cache generations, and one outstanding write. Increase only a bound implicated by a trace or unresolved schedule. This is a suggested configuration, not a completed coverage claim.

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Cross-run Reset/Continue-As-New, replication, CHASM migration, queue fairness | Explicit user boundary; [#6375](https://github.com/temporalio/temporal/issues/6375) is existing cross-run context, not a single-run counterexample. |
| Arbitrary partial execution/task transaction commits | Unsupported by the inspected SQL transaction and Cassandra conditional-batch contracts. Separate physical History append instead. |
| Durable ordinary admission or permanent rejected-result lookup | Stronger than the current API; resubmission before acceptance is part of recovery. |
| Reverting fixed effects, identity, or timer defenses | Reproducing old fixes contributes no new system finding; retain them faithfully. |
| Link labeling, Go map races, callback HTTP delivery internals | CR-3 and known cache-size races are code/test work; callback transport would enlarge this slice without answering its main questions. |
| Assuming every terminal failure requires a persisted Workflow close | `ContextImpl.forceTerminateWorkflow:1571-1583` deliberately aborts before persistence under limits; CR-5 demonstrates the exception and later changed outcome. Preserve this behavior if limits enter the model; obtain contract adjudication rather than suppressing it with an assumed durable-close guard. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Persistence/receipt separation | `historyTail`, `durableUpdates`, `recordVersion`, `writeResult`, `observations` | Distinguish physical append, logical commit, and client evidence. | 1 |
| Volatile generations | `registryGeneration`, `updates`, `wft`, `timer`, `oldMessages` | Preserve identity and actual replacement/cleanup effects. | 2, 4 |
| Ordered effects/futures | `effects`, `rollbackEffects`, `acceptedFuture`, `outcomeFuture`, `workflowClosed` | Capture mixed transitions and unlocked observations. | 1, 3 |
| Recovery scheduling | `rangeID`, `acquiring`, `dispatch`, `retries`, `workerAvailable` | Fence uncertain writes and preserve eventual delivery. | 1, 2, 4 |
| Host event-cache lookup | `eventCache`, `ownerHost`, `cachedEventUpdateID` | Preserve stale same-type event candidates independently of the durable completion pointer. | 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| AcceptedReceiptHasDurableAcceptance | Safety | A reported successful ACCEPTED stage is backed by that Run's committed acceptance/completion metadata. A preacceptance rejection reported as COMPLETED is a separate outcome kind. | 1, 3; MC-1 |
| SuccessfulOutcomeMatchesCommittedResult | Safety | A business-success payload observed for a Run/Update ID agrees with its committed completion, including after retry and reload. | 1, 3; MC-1, MC-4 |
| SuccessfulOutcomesAgree | Safety | Two successful replies for one Run/Update ID never contain conflicting results. Rejection/closure failures are not silently equated with business success. | 1, 3; MC-1, MC-3 |
| CurrentTaskOwnsAcceptedCompletion | Safety | An applied worker completion satisfies every identity guard for its current task; distinguish rejection-triggered cleanup from applying stale commands. | 2; MC-2 |
| CommittedResultRemainsQueryable | Liveness | Before retention/deletion, eventual recovery and polling obtain a committed completion; backend transient failures may delay it. | 1, 3; MC-1 |
| RetriedEligibleUpdateMakesProgress | Liveness | In a running Workflow, finite disruptions plus eligible task/timer processing, a capable worker, and required client retries eventually produce acceptance or a legitimate terminal outcome. | 2, 4; MC-2 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Forward-looking question | Expected violation if defective | Scenario |
|---|---|---|---|
| MC-1 | Can two Updates sharing a WFT, an uncertain write, cache replacement, and independently delayed waiters produce a successful reply inconsistent with the recovered committed result? The executed one-Update controls did not. | SuccessfulOutcomeMatchesCommittedResult / SuccessfulOutcomesAgree | 1, 3 |
| MC-2 | With an old completion/timeout in flight, direct-dispatch failure, and a same-ID retry admitted into a replacement registry, can all eligible recovery work disappear after finite faults? CR-1 alone recovers. | RetriedEligibleUpdateMakesProgress | 2, 4 |
| MC-3 | Across permitted mixed accept/complete/reject/final-close batches and uncertain persistence, can separate callers observe incompatible successful outcomes or an acceptance unsupported by committed state? Preserve current effect ordering and closure semantics. | AcceptedReceiptHasDurableAcceptance / SuccessfulOutcomesAgree | 1, 3 |
| MC-4 | Can a host cache an uncommitted completion for Update A, lose ownership, then reacquire after another host commits Update B at the reused event ID/version, and return A's payload when B is queried? Establish every ownership/cache-lifetime step; #11660 already reports the cache mechanism for another consumer. | SuccessfulOutcomeMatchesCommittedResult | 1 |

These are unresolved composition questions, not established bugs or requests to recreate closed issues. Spec generation must reject unreachable schedules and investigate implementation/trace disagreements before changing properties.

### 6.2 Test-Verifiable

| ID | Description/status | Next verification |
|---|---|---|
| CR-1 | Reproduced: stale completion clears a live sticky replacement; normal control and same-ID recovery succeed. | Phase 4 audit production frequency/impact and independent novelty; fixture `tests/update_analysis_identity_test.go`. |
| CR-2 | Reproduced: Sent callback buffer bypasses automatic rejection and generates repeated WFT delivery; shard clear and same-ID retry without callbacks restores rejection. | Audit callback semantics and overlap with open #11254; compatible-worker recovery remains source-supported. Fixture `tests/update_analysis_state_test.go`. |
| CR-5 | Reproduced: forced termination publishes a terminal closing failure despite failed persistence and durable RUNNING/Accepted state; after explicit runtime-limit restoration, the same Update completes successfully. | Phase 4 contract/novelty audit; preserve the deliberate precommit-abort comment and the exact configuration-assisted recovery assumption. Fixture `TestAnalysisUpdateForceTerminationReadback` has healthy control and raw readback. |
| CR-6 | Component-reproduced: a canceled old speculative timer already in execution prematurely times out a replacement converted to normal; speculative control rejects it. | Preserve real queue/submission, generation-clock checks and conversion; reproduce public Update/worker consequences and real persistence. Current backend is mocked; no durable loss or client outcome asserted. |
| TV-2 | Update lookup's event-type-only check reaches the known stale-cache mechanism (#11660); actual wrong-result schedule unexecuted. | Use MC-4 to derive a reachable schedule, then reproduce through two History hosts, real fenced persistence and public result lookup; fabricated cache insertion alone cannot confirm the production trigger. |

### 6.3 Code-Review-Only

| ID | Description/status | Suggested action |
|---|---|---|
| CR-3 | Reproduced accepted handler failure is labeled `Update rejected` in response-link metadata; durable acceptance/completion and failure payload remain correct. | Audit link semantics alongside open #11925; no safety MC hunt. |
| CR-4 | #10478 speculative skip ownership claim and #10775 direct-dispatch build-ID/logging differences lack demonstrated current result loss. | Preserve the exact compensating guards and unresolved assumptions in Phase 4 review; do not classify reports/TODOs as confirmed bugs. |

## 7. Reference Pointers

- [Detailed analysis and coverage](analysis-report.md); [state/effects audit](analysis-evidence/state/report.md); [identity/dispatch audit](analysis-evidence/identity/report.md); [persistence audit](analysis-evidence/persistence/report.md).
- Public pipeline: `service/frontend/workflow_handler.go:5476-5626`; `service/history/api/updateworkflow/api.go`; `service/history/api/respondworkflowtaskcompleted/{api.go,workflow_task_completed_handler.go}`; `service/history/api/pollupdate/api.go`.
- State/recovery: `service/history/workflow/update/{update.go,registry.go,abort_reason.go,store.go}`; `service/history/workflow/{context.go,workflow_task_state_machine.go,mutable_state_impl.go}`; `common/effect/buffer.go`.
- Persistence: `common/persistence/sql/execution.go`; `common/persistence/cassandra/{execution_store.go,mutable_state_store.go}`; `service/history/shard/context_impl.go`; `common/persistence/faultinjection/fault.go:42-47,61-72`.
- Pinned implementation documentation: `docs/architecture/{workflow-update.md,speculative-workflow-task.md,effect-package.md,message-protocol.md}`. [Public Update contract](https://docs.temporal.io/encyclopedia/workflow-message-passing).
- Raw refreshed discussions and scoped commit patches are preserved under `analysis-evidence/`; historical fixes remain reference context. Test fixtures are additional files only; production implementation was not modified.
