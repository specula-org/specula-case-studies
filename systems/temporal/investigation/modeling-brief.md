# Temporal Update modeling brief

## 1. System overview

- Source: temporalio/temporal, fixed main revision 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025, inspected 2026-09-09.
- Category A: Distributed / Message-Passing. The selected subject is a durable execution state machine with RPCs, database writes, retries and cache loss.
- Scope: one cluster, one namespace, one Workflow Run, Workflow Update lifecycle and normal/speculative Workflow Tasks (WFTs).
- This is a target-selection handoff, not a completed bug-finding phase. No new defect, TLA+ counterexample or passing verification is claimed.
- The core Update files are state.go (59 physical lines), update.go (851), registry.go (509); integration extends into larger WFT handlers and persistence code.
- User workflow code runs in an SDK Worker. Represent its permitted protocol messages as environment actions; do not translate arbitrary workflow programs.
- A workflow lease serializes most server mutations. Client waiters can observe futures without that lease. Persistence and Matching calls introduce additional boundaries.
- Full assessment: [Chinese investigation](temporal-specula-investigation.zh-CN.md). Detailed source mapping: [workflow-modeling.md](workflow-modeling.md).

## 2. Scenarios

### Scenario 1: Durable completion and caller observation

**Mechanism:** provisional Update state, committed history/state, after-commit effects and client responses have different publication boundaries.
**Current paths:** Update.onAcceptanceMsg, Update.onResponseMsg, effect.Buffer, respondworkflowtaskcompleted handler.
**Evidence:** [current acceptance effects](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/service/history/workflow/update/update.go#L643), [completion effects](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/service/history/workflow/update/update.go#L771), [effects application](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/service/history/api/respondworkflowtaskcompleted/api.go#L725).
**Historical context:** merged [#5349](https://github.com/temporalio/temporal/pull/5349) repaired effect rollback after an already successful write.
**Question:** do currently supported combinations of worker messages and write outcomes preserve the relationship between successful caller observations and durable results?
**State:** durable UpdateInfo/events, provisional registry state, effect queue, accepted/outcome futures, caller observations, pending database operation.
**Actions:** process worker messages; append candidate history; conditionally commit state/tasks; report write outcome; apply/cancel effects; observe response.
**Granularity:** keep real database transactions atomic, but separate durable commit, callback publication and caller receipt. Preserve lock boundaries; only eligible waiters may observe between callbacks.
**Priority:** High. This is the first model's central contract.

### Scenario 2: Cache replacement and speculative task identity

**Mechanism:** a speculative WFT and its registry may disappear while requests, responses and timers from an older generation remain in flight.
**Current paths:** updateworkflow.Updater, ContextImpl.Clear, NewRegistry, WFT token validation, speculative timeout handling.
**Evidence:** [Context.Clear](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/service/history/workflow/context.go#L174), [registry reconstruction](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/service/history/workflow/update/registry.go#L168), [WFT token checks](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/service/history/api/respondworkflowtaskcompleted/api.go#L203).
**Historical context:** merged [#5784](https://github.com/temporalio/temporal/pull/5784) coupled context/registry lifecycle; [#6308](https://github.com/temporalio/temporal/pull/6308) corrected speculative timeout lifetime.
**Question:** after a cache replacement and a same-ID retry, can an obsolete task or waiter affect the wrong current task or suppress the required recovery path?
**State:** logical Update identity, registry generation, WFT identity/type/attempt/start timestamp/version, speculative timeout, durable normal task.
**Actions:** cache clear/reload; client retry; dispatch; receive late completion; fire old/current timeout.
**Granularity:** retain identity fields that currently reject stale tokens. Do not collapse all task identities to scheduledEventID.
**Priority:** High. Compose with Scenario 1 after the normal path is trace validated.

### Scenario 3: Completion, rejection and workflow closure

**Mechanism:** acceptance/completion may occur in one WFT or across several; workflow closure can abort outstanding Updates.
**Current paths:** WaitLifecycleStage, abort matrix, WFT command/message ordering and close handling.
**Evidence:** [wait logic](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/service/history/workflow/update/update.go#L156), [abort reasons](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/service/history/workflow/update/abort_reason.go), [close handling](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/service/history/api/respondworkflowtaskcompleted/api.go#L724).
**Question:** for currently permitted ordered combinations, do duplicate clients receive outcomes consistent with the durable stage and the specific close/rejection contract?
**State:** workflow running/closed, ordered worker messages, accepted/outcome futures and durable accepted/completed state.
**Actions:** accept; reject; complete; close; observe; retry.
**Granularity:** preserve ordered processing within one WFT and after-commit callback order.
**Priority:** High, but initially omit Continue-As-New and reset so identity remains within one Run.

## 3. Modeling recommendations

### 3.1 Model

- One Run with two Update IDs, two callers and a small number of WFT attempts as an initial finite search configuration.
- Distinguish ordinary volatile admission from admission reconstructed from durable reset/reapply events. The latter can be excluded initially with an explicit scope condition.
- Distinguish durable logical Update identity from a replaceable registry object and its futures.
- Model successful write, definite pre-commit rejection, and uncertain outcome with possible committed state or delayed completion.
- Keep History append separate from the state/task transaction where current backend code does so.
- Include persistence record conditions and relevant RangeID behavior if uncertain writes require reacquisition. Do not add unrestricted unfenced late writes.
- Allow only contract-permitted worker message orderings, supplemented by stale responses that real handlers can receive.
- Express API observations separately from internal future readiness and from persistence completion.

### 3.2 Do not model initially

- Multi-cluster replication, failover conflict resolution, membership protocols or database consensus: too much unrelated state.
- Continue-As-New, Reset, deletion, callback migration or CHASM: independently valuable second-stage slices with different identity contracts.
- Activity external side effects: exactly-once business effects are not the selected Server guarantee.
- Priority/fairness queue internals: represent dispatch availability and retry only at the interface needed by the Update model.
- Payload serialization, metrics and memory allocation: retain abstract identifiers/results unless a concrete question depends on these details.
- Unbounded time, histories, requests or failure sequences: use declared finite bounds and never turn a bounded result into a full proof.

## 4. Proposed extensions

There is no checked-in reference model supplied for this study. These are required elements beyond an idealized single-step Update state machine.

| Extension | Suggested state | Purpose |
| --- | --- | --- |
| Durable versus volatile state | durableUpdates, registryGeneration, volatileUpdates | Separate recovery truth from object lifetime |
| Provisional effects | pendingEffects, provisionalStage, futureStates | Connect commit/rollback to observer publication |
| WFT identity | tokenGeneration, attempt, startedIdentity, taskType | Preserve actual stale-response guards |
| Persistence outcome | pendingWrite, durableVersion, reportedOutcome | Represent definite failure and ambiguous completion |
| External observations | clientRequestID, observedStage, observedOutcome | State properties in terms of real caller behavior |
| Recovery | cachePresent, normalTask, speculativeTimer | Check reload/retry and task liveness |

## 5. Proposed properties

| Property | Kind | Contract and guard |
| --- | --- | --- |
| AcceptedObservationIsDurable | Safety | Successful ACCEPTED observation has durable acceptance for that Run/Update ID; rejection is separate |
| SuccessfulOutcomeAgreement | Safety | Observed successful completion agrees with durable outcome and nonconflicting retry results within the same Run/retention scope |
| NoPrematureSuccess | Safety | A definitely uncommitted transition does not publish successful acceptance/completion |
| OldTaskIsolation | Safety | A stale WFT response/timeout cannot mutate a replacement task or unrelated Update |
| CommitSurvivesVolatileLoss | Safety | Cache replacement and a post-commit error cannot erase committed acceptance/completion |
| PermittedCompletionProgress | Liveness | With eventual healthy persistence/Matching, valid Worker responses, needed client retries, advancing timers and finite cache churn, pending work resolves according to its contract |

Do not require ordinary admission to survive a crash without resubmission.
Do not require persisted rejection or successful re-query of a rejected Update.
Do not equate ACCEPTED with guaranteed business success; workflow close can legally abort an accepted but unfinished Update.
Do not require a completed lifecycle response for rejection to have an acceptance event.
Do not require every physical history node to belong to the committed logical history.
Do not split state/task insertion inside a real SQL transaction.
Do not claim progress with permanently absent Workers, perpetual DB failures or an indefinitely paused operation.
If later adding Reset, allow intentional reexecution; if adding Continue-As-New, establish the actual cross-run dedup contract first.

## 6. Findings pending verification

### 6.1 Model-checkable

No evidence-backed new suspected defect has been established. Scenarios 1–3 are forward-looking coverage questions, not bug IDs.
A future candidate must have a current-code execution path and an externally meaningful violated contract before it becomes a defect claim.
Do not create a hunt whose only purpose is reverting or rediscovering a historical fix.

### 6.2 Test-verifiable

- Validate model observations against real API/TaskPoller executions and persisted state.
- Reuse [cache-loss functional tests](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/tests/update_workflow_test.go#L3294) and [stale-token tests](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/tests/update_workflow_test.go#L3973).
- Use [namespace-scoped request/response faults](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/tests/testcore/test_env.go#L465) for definite request failure and lost response after a handler executes.
- Use [persistence ExecuteAndTimeout](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/common/persistence/faultinjection/fault.go#L42) for executed-write/timeout behavior.
- A response fault is not automatically a process crash at an internal boundary. Add a narrow hook only when needed to reproduce a specific schedule.
- Confirm backend-sensitive behavior on the implicated production persistence implementation, not solely an in-memory store or SQLite path.
- Observe IDs, generation, persistence result, effect apply/cancel and caller response; History alone omits critical failed/transient transitions.
- Tests for this source require the test_dep build tag. No test command was run during this assessment.

### 6.3 Code-review-only and exclusions

- [#10478](https://github.com/temporalio/temporal/issues/10478) and [#10775](https://github.com/temporalio/temporal/issues/10775): existing unconfirmed reports; no new finding credited.
- [#11254](https://github.com/temporalio/temporal/pull/11254): known open Nexus Update callback proposal; exclude its reported scenario from novelty.
- [#6375](https://github.com/temporalio/temporal/issues/6375): known cross-Continue-As-New retry/identity behavior; establish contract before extending the model.
- [#6513](https://github.com/temporalio/temporal/pull/6513): already-fixed completed-update reapplication deduplication.
- [#11570](https://github.com/temporalio/temporal/pull/11570): explicit prior TLA+ use for queue correctness. No model file in this checkout does not establish absence of formal work.

## 7. Reference pointers and acceptance criteria

- [History evidence and coverage](history-evidence.md); [workflow path mapping](workflow-modeling.md); [queue/HSM alternatives](queue-hsm-testing.md).
- [SQL commit boundary](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/common/persistence/sql/execution.go#L334), [state/task transaction](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/common/persistence/sql/execution_util.go#L23), [uncertain shard write handling](https://github.com/temporalio/temporal/blob/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025/service/history/shard/context_impl.go#L1501).
- Acceptance requires trace/model correspondence, completed finite searches or explicitly recorded INCOMPLETE status, and real-handler reproduction for any claimed implementation defect.
- Report MC discovery, code-review discovery, known bug reproduction, false positive and incomplete coverage separately.
- A reproducible new semantic defect is strong evidence; a faithful reusable model without a defect is a different, valid outcome. Neither is guaranteed by this brief.

