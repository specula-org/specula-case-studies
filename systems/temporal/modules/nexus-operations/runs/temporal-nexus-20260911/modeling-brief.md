# Modeling Brief: temporal-nexus

## 1. System Overview

- **System:** Temporal, Go; pinned `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; approximately 3,541 lines in operation commands/config/state/tasks/executors/completion/events, excluding tests and shared HSM/persistence.
- **Category A (Distributed / Message-Passing):** independent outbound RPC, callbacks, timer queues and conditional persistence cross a workflow lock; crash faults, no BFT.
- **Algorithm:** Nexus operation commit/recovery for one Workflow Run in one cluster; HSM `service/history/hsm/nexusoperations`, stable endpoint binding. No canonical consensus reference is imposed.
- **Routing:** CHASM workflow-operation flag=false, rollout=0; tests explicitly disable CHASM. Worker targets use `temporal://system`; controlled external endpoints use configured HTTP callback URL. See commands dispatch `workflow_task_completed_handler.go:347-369`, `chasm/lib/nexusoperation/config.go:38-65`, operation `executors.go:126-143`.
- **Backend/evidence:** real SQL/SQLite transactions, test `mode=memory, cache=shared`; database readback and shard close/reload, **not process/power-loss persistence testing**. Transition history=true; request timeout=10s/minimum=1.5s; outbound reader enabled; cancel-ACK events=true. Exact per-probe overrides are in the analysis report.
- **Concurrency:** locked read → unlocked remote call → locked revalidation/write; History append precedes atomic mutable-state/buffered-event/task transaction; notification and response receipt follow separately (`executors.go:364-449`, `sql/execution.go:334-357`).
- **Phase result:** three source-discovered behaviors reproduced through real handlers/SQLite; no TLC run, formal discovery or trace validation yet. This is the Code Analysis handoff.

Source shorthand: bare operation files refer to `service/history/hsm/nexusoperations/` (commands under `workflow/`); `sql/` means `common/persistence/sql/`; workflow/shard/API/environment paths are under `service/history/`.

## 2. Scenarios

### Scenario 1: Remote acceptance and local knowledge can advance independently

**Mechanism:** remote acceptance, response receipt, callback arrival and local conditional commit are separate events, so response loss/retry must reconcile one operation identity.
**Evidence:**
- Historical: [#11820](https://github.com/temporalio/temporal/pull/11820) fixes wrapped-error retry classification; [#6918](https://github.com/temporalio/temporal/pull/6918) repairs callback/task validation. Fixed references only.
- Code: `executors.go:202-218,264,364-449,452-480`; `completion.go:126-163,199-247`; `events.go:327-355`. RequestId is operation identity; operation Attempt increments on retryable failure or async Started, not every send or terminal result.
- Existing SQLite tests passed for early completion, ordinary duplicate completion and pre-handler HTTP failure. Accepted-start response loss plus uncertain local write is **not yet executed**.
**Affected code paths:** schedule command; loadOperationArgs; StartOperation; saveResult/saveStartedResult; History CompleteNexusOperation; CompletionHandler.Handle.
**Suggested modeling approach:**
- Variables: durable `requestId, token, opState, attempt`; endpoint `acceptedByRequestId, remoteOutcome`; in-flight requests/responses/callbacks and caller observations.
- Actions: send/remote accept/receive/save; lose response; callback before or after save; retry with same request identity; synchronous result vs asynchronous token; duplicate/late delivery.
- Granularity: keep callback-fabricated Started plus terminal event/deletion in **one local transaction**; split remote acceptance from that transaction. Do not fence callback by outbound attempt number.
**Priority:** High. **Rationale:** priority questions 1–2; formal exploration can add composition evidence beyond existing single-fault tests.

### Scenario 2: Deferred cancellation can omit an independently required timer

**Mechanism:** a nested cancellation transition returns before the parent emits its start-to-close timer, while cancellation acknowledgment leaves the operation running.
**Evidence:**
- Historical: [#6483](https://github.com/temporalio/temporal/pull/6483) and [#6931](https://github.com/temporalio/temporal/pull/6931) establish deferred cancellation intent and reject premature local cancellation; fixed context, not targets.
- Code: `statemachine.go:364-400,423-449` stores Started/token/time, then returns at384-389 for an existing child, skipping398. RegenerateTasks at172-181 includes the missing timer; ordinary load does not regenerate it.
- **B1 reproduced:** cancel event11 → Started12 → cancel-ACK16; positive STC=3s, zero persisted HSM timer groups past deadline and after shard close; explicit RefreshWorkflowTasks causes timeout. No-prestart-cancel control times out normally. See `analysis-evidence/cancel-retention-probes.jsonl`.
**Affected code paths:** Cancel; TransitionStarted; cancellation execution/ACK; dirty task generation; logical timer groups; ordinary load; explicit task refresh.
**Suggested modeling approach:**
- Variables: cancellation child absent/UNSPECIFIED/SCHEDULED/BACKING_OFF/SUCCEEDED/FAILED; independently stored logical timer set; STC deadline; live vs persisted transition output.
- Actions: commit cancel before/during start; commit async start; cancel ACK/refusal/retry; terminal callback; timer fire; reload; explicit refresh.
- Granularity: parent and child state changes commit atomically, but generated task set must match the actual early-return branch. ACK must not imply operation CANCELED.
**Priority:** High. **Rationale:** current externally visible timeout defect; formal work should map when callback/S2C masks it and when recovery does or does not repair it.

### Scenario 3: Live terminal transition and reconstruction reclaim different capacity

**Mechanism:** live timeout records a terminal result without deleting its HSM node; admission counts physical nodes while Describe hides terminal nodes.
**Evidence:**
- Historical: [#7171](https://github.com/temporalio/temporal/pull/7171) repairs live success/failure/canceled deletion; full discussion/diff leaves the timeout site separate. This scenario examines that surviving current site.
- Code: `executors.go:614-676` directly applies TransitionTimedOut; `events.go:262-272` deletes on event application; `commands.go:184-191` counts collection size; Describe `api/describeworkflow/api.go:706-722` filters terminals.
- **B2 reproduced:** real async start → ordinary S2C timeout → next schedule rejected with PendingNexusOperationsLimitExceeded at limit1; raw database retains TimedOut node after shard close while Describe reports zero pending. Two sequential sync operations succeed in the control.
**Affected code paths:** all operation timeout executors; below-minimum start timeout; TimedOutEventDefinition; collection admission; Describe; reload/refresh/rebuild.
**Suggested modeling approach:**
- Variables: node existence separate from terminal history; pending-operation count separate from retained-node count; two sequential operation IDs and capacity=1 in the focused configuration.
- Actions: live timeout vs success/failure/cancel deletion; schedule another operation; ordinary reload; explicit task refresh; optional history rebuild in a separately justified configuration.
- Granularity: node deletion and terminal event belong to the same local commit when deletion is actually performed. Do not silently add deletion to the timeout executor abstraction.
**Priority:** High. **Rationale:** current functional impact even when the first operation reaches the correct terminal result; reconstruction equivalence is a useful formal question.

### Scenario 4: Deadline selection, queued work and stale references interact

**Mechanism:** operation deadlines, request budgets, physical wakeups and current-state validation have different roles; delayed work may legally execute during a later eligible retry.
**Evidence:**
- Historical: [#9153](https://github.com/temporalio/temporal/pull/9153) adds caller timeouts; [#6988](https://github.com/temporalio/temporal/pull/6988) adds task Attempt for observability, not an equality fence.
- Code: `executors.go:223-249,287-289,715-749`; `tasks.go:50-66,98-103,143-148,179-184,224-229,261-283,315-333`; `statemachine_environment.go:223-324`; task generation watermark `ndc_task_util.go:235-255`.
- **B3 reproduced, test-verifiable:** omitted S2C plus no run timeout bypasses configured max3s (`commands.go:194-204` vs `config.go:106-111`); DB retains zero duration after reload. Explicit60s control is capped to3s and times out. Preserve this as a direct policy bug, not an MC hunt.
**Affected code paths:** schedule timeout normalization; start/cancel request budgeting; backoff and operation timers; reference validation; queue wakeups; task refresh.
**Suggested modeling approach:**
- Variables: positive/absent S2C/S2S/STC deadlines; current logical timer groups; physical tasks/watermark; initial HSM identity; durable attempt and next-backoff time.
- Actions: delayed task consumption after reschedule; eligible timeout vs callback; epoch/watermark advance; queued cancellation after terminal completion; deadline-enabled configurations.
- Granularity: current persisted timer groups decide what a physical timer wakeup executes. Nexus validators check state and identity, **not serialized Attempt equality**.
**Priority:** High. **Rationale:** questions 3–4 require interactions with Scenarios1–2; unit arithmetic/formatting issues stay outside MC.

### Scenario 5: Buffered history, uncertain commit and notification must agree after reload

**Mechanism:** history storage, logical commit and caller-visible notification have distinct boundaries; terminal completion can precede a workflow's knowledge of it.
**Evidence:**
- Historical: [issue #8175](https://github.com/temporalio/temporal/issues/8175) documents missing WFT notification on cancel ACK; [#10626](https://github.com/temporalio/temporal/pull/10626) repairs history event-load batch identity. Both fixed reference context.
- Code: `commands.go:259-323` accepts cancellation against buffered completion; `sql/execution.go:334-357`, `sql/execution_util.go:23-82,155-175,629-664`; `workflow/transaction_impl.go:184-213`; `shard/context_impl.go:1501-1548`.
- Source establishes possible-commit errors and shard reacquisition; current probes establish ordinary DB reload only. **ExecuteAndTimeout and definite-noncommit callback schedules remain pending.**
**Affected code paths:** HSM Access; workflow close-transaction; History append; SQL mutable-state/task/buffer transaction; RangeID reacquisition; cache release; WFT scheduling/consumption.
**Suggested modeling approach:**
- Variables: persisted vs volatile snapshot; append-only raw history vs committed visible prefix/buffer; DBRecordVersion/RangeID; workflow open/closed; pending WFT and notification; response knowledge.
- Actions: definitely-failed write, committed-success, committed-but-error; discard cache; reacquire shard/readback; buffered completion/cancel command order; workflow closure before a late response.
- Granularity: History append can precede commit; HSM state/logical timers/queue tasks/buffer changes commit atomically. Notification may occur on a possibly successful write and is not a commit oracle.
**Priority:** High. **Rationale:** questions 1,4,5; a faithful model must preserve backend atomicity and distinguish ordinary load, task refresh and history rebuild.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Coupled start/callback/cancel/timer lifecycle | Scenarios1–2,4 | One operation, two bounded sends, one cancel child; sync/async starts and three independent deadlines |
| Actual task publication and regeneration | B1/Scenarios2,4 | Persist emitted logical tasks; Reload copies them; Refresh derives and filters them |
| Terminal existence and capacity | B2/Scenario3 | Separate state/node existence; two sequential operations only in capacity configuration |
| Atomic commit with uncertain receipt | Scenarios1,5 | Three write outcomes, independent response loss; preserve transaction grouping |
| Operation/HSM/physical-task identity | Scenarios1,4 | Stable request ID, initial transition identity, task generation and state eligibility; no invented attempt fence |
| Buffered WFT/closure interaction | Scenario5 | At most one in-flight WFT; terminal buffer ordered after command events; closed run disables Nexus transitions |

Start with one operation, at most two accepted/send attempts, two callback deliveries, one cancel request, one cache loss and one explicit refresh; abstract time by deadline ordering. Use a separate two-operation/capacity1 configuration for B2, then compose with uncertain writes. Record bounds, completed state counts and unfinished searches as INCOMPLETE; do not equate separate checks with the full cross-product.
Progress requires fair eligible timer/outbound scheduling, eventual persistence availability/reacquisition, finite failure/churn, and an open workflow. Reconnection without duplicate external work additionally requires endpoint idempotency and retention for the stable request ID. Remote refusal and timeout are permitted; cancel ACK does not require eventual canceled outcome.

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Standalone CHASM/System Nexus, migration, Reset/CAN, XDC, endpoint administration | Explicit target boundary; only inspect interface guards needed for current HSM reachability |
| SQL statements as independently committing HSM/task/buffer writes | Contradicts actual backend transaction; split History append only |
| Reverts of closed historical fixes | Known answers; historical citations constrain semantics and remain reference context |
| B3 timeout-cap conditional, failure metadata/size, optional timestamp, parser guards, metrics/formatting | Direct Go/API tests or code review; preserve every candidate below and in report |
| Exact-once external effects, success for every duplicate callback, hard deadline linearization | Not supplied by Nexus/HSM contract; terminal-first commit, valid late rejection and endpoint assumptions apply |
| Corrupt DB, adversarial endpoint identities, user protocol-header overrides, time skipping/pause | No justified primary adversary; keep explicit fixed-input assumptions and separate CR observations |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Remote/local knowledge | acceptedByRequestId, remoteOutcome, messages, requestId, token | Separate effect, receipt and commit | 1 |
| Cancellation and emitted timers | cancelState, deadlines, transitionOutput, durableTimers | Expose missing publication and terminal subsumption | 2,4 |
| Retained-node capacity | nodeExists, terminalHistory, capacity, nextOperation | Distinguish completion from reclaimed admission capacity | 3 |
| Recovery identity | incarnation, taskGeneration, physicalTasks, attempt | Preserve actual eligibility after reload/refresh | 1,4 |
| Commit and observations | volatile, durable, rawHistory, visibleEnd, buffered, writeOutcome, WFT, observations | Atomic local commit with uncertain knowledge | 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| TypeOK / TerminalOutcomeUnique | Safety | Valid state domains; at most one committed terminal result per scheduled operation | All |
| StableReconnectIdentity | Safety | Every protocol-conforming retry carries durable operation request ID; accepted endpoint mapping remains reconcilable under its stated contract | 1 |
| RequiredTimerPublished | Safety | Committed running Started with enabled STC has eligible logical timer unless terminal transition subsumes it | 2, B1 |
| TerminalCapacityReclaimed | Safety | In an open workflow, a terminal operation does not consume the limit documented for pending operations | 3, B2 |
| CommittedObservation | Safety | Observed accepted completion maps to committed terminal history or committed terminal buffer; stale responses cannot replace it | 1,5 |
| NoTerminalRevival | Safety | Late task/callback cannot revive or replace terminal operation; permitted later retry sends retain operation identity | 1,4 |
| CancelIntentAccountedFor | Safety | Durable cancel remains waiting for start, eligible/retrying, resolved ACK/failure, or subsumed by operation/run terminal state | 2,5 |
| EligibleProgress | Liveness | Under stated fairness/health, required published work progresses or permitted terminal result wins; no demand for remote canceled outcome | 2–5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Forward-looking executable question | Expected violation if adverse | Scenario |
|---|---|---|---|
| MC1 | Across early callbacks, accepted-start response loss and both uncertain-write outcomes, can local/remote knowledge cease to be reconcilable despite endpoint dedup? | StableReconnectIdentity / CommittedObservation | 1,5 |
| MC2 | Which cancellation/backoff/start/commit/reload combinations omit a required timer; which terminal events or refreshes mask/repair the observed B1? | RequiredTimerPublished / EligibleProgress | 2,4 |
| MC3 | Can terminal cleanup/admission differ across live timeout, uncertain commit, reload and reconstruction for sequential operations, extending observed B2? | TerminalCapacityReclaimed | 3,5 |
| MC4 | Can delayed tasks after state cycles/refresh and buffered cancellation/completion alter a newer committed result or strand valid work? | NoTerminalRevival / CancelIntentAccountedFor | 1,2,4,5 |

MC2/MC3 begin with source/runtime findings, so replaying those schedules is MC **reconfirmation**, not MC-first discovery. Only additional checker-generated behaviors with independent implementation confirmation add new discovery counts.

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| B3 | Configured maximum S2C ignores omitted duration/no run limit; already reproduced | Retained overlay + explicit-duration control; broaden nil/zero/run-timeout matrix |
| TV1 | Callback omits optional StartTime before start response → fabricated year0001 event | Real completion HTTP handler, supplied-time and already-started controls, History/DB readback |
| TV2 | Cancel minimum-budget diagnostic names S2C when STC selected minimum | Both deadlines configured; inspect child failure against independently measured deadline |
| TV3 | Persistence and endpoint observations not yet complete | ExecuteAndTimeout vs definite noncommit, accepted-response loss, exact fault counters and post-reacquisition readback |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | Known HSM cancellation coercion drops Source/EncodedAttributes; open #11312 | Preserve upstream status; audit field/SDK effect; no novelty claim |
| CR2 | Known failure/cancel payload-size asymmetry; open #11764 | Keep transport vs namespace limits distinct; HSM repairs canceled marker |
| CR3 | Callback-token/nested failure decoder nil guards and nested HSM reference validation | Retain source observations; handler-contained impact and recovery remain untested |
| CR4 | User headers may override request ID/token; SDK explicitly permits overwrite | Document primary assumption; independently observe wire identities; Temporal policy review |
| CR5 | Bare failure may lack FailureInfo; cancellation diagnostics/optional-time conversion | Preserve exact conversion paths for human/API review; do not infer CHASM failure behavior |
| CR6 | Known request-timeout grammar (#11569/#11944), pending gauge (#11186), pre/post-commit metrics | Track known changes; never use metrics or History alone as complete endpoint/commit evidence |

## 7. Reference Pointers

- [Full analysis and prioritized-question matrix](analysis-report.md); [reproduction fixture](analysis-evidence/nexus_workflow_probe_test.go); [overlay](analysis-evidence/max-timeout-overlay.json); [commands and evidence summary](analysis-evidence/verification-summary.md).
- [Executor audit](analysis-evidence/deep-executors.md), [state/task/recovery audit](analysis-evidence/deep-recovery.md), [completion/entry audit](analysis-evidence/archaeology-completion/deep-completion.md); complete archaeology ledgers linked from analysis report.
- Reference contracts: pinned `docs/architecture/nexus.md`; pinned SDK `github.com/nexus-rpc/sdk-go@v0.7.0/nexus/options.go,operation.go`; refreshed [Nexus HTTP specification](https://github.com/nexus-rpc/api/blob/main/SPEC.md) and [Temporal Go Nexus proposal](https://github.com/temporalio/proposals/blob/master/nexus/sdk-go.md). Compare newer external text to pinned implementation, not CHASM semantics.
- Trace handoff: correlate endpoint acceptance/response/callback log, actual wire identity, HSM/cancel state and attempt, DB write outcome/readback, logical and physical pending tasks, WFT/buffered history, then post-reload observations. Track observation provenance/completeness; negative controls must reject forged identity, deletion of an independently observed persisted timer from the trace, and false commit observations. The authentic B1 trace with no published timer must remain valid implementation evidence and violate RequiredTimerPublished; trace acceptance and property satisfaction are separate. No trace-validation result exists in this phase.
