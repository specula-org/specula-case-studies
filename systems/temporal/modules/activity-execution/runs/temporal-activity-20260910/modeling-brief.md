# Modeling Brief: temporal-activity

## 1. System Overview

- **System**: Temporal Server, Go; ordinary Workflow Activity durable execution; 18,490 lines across the 13 declared core files, including shared Workflow machinery.
- **Revision**: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`, clean checkout at `/home/ubuntu/temporal-investigation-20260909/parallel-20260910/source-activity`; evidence in `analysis-evidence/source-identity.json`.
- **Category A (Distributed / Message-Passing)**: worker RPCs, Matching handoff, durable storage, independently scheduled timers and shard ownership determine the relevant interleavings; no BFT threat model.
- One Workflow lease serializes local mutations; persistence separately enforces shard RangeID and execution record version (`workflow/context.go:143-164`; `common/persistence/sql/execution_util.go:629-695`). Paths beginning `workflow/`, `api/`, or an executor filename below are relative to `service/history/`.
- Retry-policy starts are durable ActivityInfo changes with transient Started IDs; History can omit intermediate attempts (`workflow/mutable_state_impl.go:4502-4565`). Neither History nor task delivery alone identifies accepted execution.
- **Executed baseline**: Go 1.27.0/amd64, SQLite temporary files/WAL/`synchronous=normal`, 14 functional test methods passed, including two ByID/token controls; no recovery injection, complete trace validation, or TLC execution (`analysis-report.md`, §4).
- **Feature identity**: pinned defaults retry-stamp increment **false**, worker-control cancellation **false**, eager Activity execution **true**; ordinary model starts with explicit non-eager requests, no routing/time-skipping/admin features (`common/dynamicconfig/constants.go:203-243`). Test defaults and per-test request choices are recorded separately.
- This is the Code Analysis handoff. Formal fidelity, failure/recovery traces, and bounded verification remain **INCOMPLETE**, assigned to subsequent phases.

## 2. Scenarios

### Scenario 1: Attempt identity across dispatch and delayed worker replies

**Mechanism**: producer checks precede lease release and asynchronous delivery; recipient validation and response reconstruction determine what a worker can legitimately act on.
**Evidence**:
- Historical: commit `9002e943b069` unified eager/ordinary StartedClock assignment; [issue #1897](https://github.com/temporalio/temporal/issues/1897) establishes that duplicate completion need not return success; [open PR #11734](https://github.com/temporalio/temporal/pull/11734) addresses ambiguous-start response recovery and missing duplicate-start fields.
- Code analysis: retry dispatch checks stamp/attempt/start under lease, releases before Matching, sends stamp but no attempt (`timer_queue_active_task_executor.go:553-636`); History rechecks current start/request ID and stamp (`api/recordactivitytaskstarted/api.go:118-184`).
- Token result/heartbeat checks require current started Activity and exact attempt for nonempty scheduled ID, then prefer mutually nonzero StartVersion, otherwise legacy Version (`api/activity_util.go:58-80`). Ordinary Activity tokens contain no started timestamp and no Activity retry stamp (`common/tasktoken/token.go:33-60`).
**Affected code paths**: transfer `processActivityTask`; retry timer executor; Matching `recordActivityTaskStarted`; History start/completed/failed/canceled/heartbeat APIs.
**Suggested modeling approach**:
- Variables: Activity scheduled identity, attempt, started marker, request ID, version/startVersion/stamp; queued dispatch copies; pending worker messages; accepted start versus delivered response.
- Actions: validate/copy dispatch under lease, release/send, History accept-or-deduplicate start and commit, deliver poll response, validate each worker reply separately.
- Granularity: split the handoff and commit/response; keep in-lease mutation indivisible. Preserve absent-version compatibility. Never invent receiver Attempt, StartedTime, or not-before-ScheduledTime guards.
**Priority**: High. **Rationale**: addresses priority question 1 and both sides of retry handoff. Default-false stamp behavior is historical configuration context, not a new bug hunt recreating its gated fix.

### Scenario 2: Shared timer cues conserve current deadline obligations

**Mechanism**: one physical timeout cue services the earliest of many logical deadlines; heartbeat and retry change the deadlines while duplicate cues remain pending.
**Evidence**:
- Historical: `fc70bd97f500` introduced FirstScheduledTime for the global deadline; `3491846fe3cc` corrected per-attempt timer-bit clearing; `11e54a1b9ae6` restored the heartbeat cue needed for regeneration. These fixed bugs are context only.
- Code analysis: one earliest cue is created (`workflow/timer_sequence.go:118-164`); execution recomputes all current deadlines and may mutate several Activities in one transaction (`timer_queue_active_task_executor.go:230-280`). It does not check the cue's Activity stamp; snapshot entries overtaken by retry are skipped (`299-305`).
- ScheduleToClose's created bit survives retry (`workflow/timer_sequence.go:34-41`; `workflow/activity.go:72-89`). Heartbeat watermark is volatile and reconstructed as year 2000 on DB load (`workflow/mutable_state_impl.go:471-481`).
**Affected code paths**: timeout executor; `RetryActivity`; `CreateNextActivityTimer`; heartbeat updates; close-transaction timer generation.
**Suggested modeling approach**:
- Variables: initial/attempt scheduling times, started/heartbeat times, four configured durations, retry expiration/policy, timer mask, volatile heartbeat watermark, physical cues with task IDs/fire times.
- Actions: receive heartbeat, process a cue against a snapshot of sorted current deadlines, retry/terminate, regenerate earliest cue, commit or reload, later acknowledge/delete old cue.
- Granularity: all expired logical entries processed by one cue share the Workflow transaction. Keep cue execution and task acknowledgement separate; allow duplicate and delayed cues.
**Priority**: High. **Rationale**: addresses priority question 2 and recovery of timer work; a per-Activity one-timer abstraction would miss the implementation's shared coverage mechanism.

### Scenario 3: Persistence result, API result, and recovery can disagree temporarily

**Mechanism**: History append precedes an atomic execution/task transaction, and a committed write can lose its response while cache and ownership are being recovered.
**Evidence**:
- Historical: `673d5636b491` rejects dirty cache release; [open PR #11660](https://github.com/temporalio/temporal/pull/11660) describes precommit event-cache entries surviving shard recreation. Neither implies SQL splits the Activity/task commit.
- Code analysis: History append then SQL transaction (`common/persistence/sql/execution.go:334-357`); execution row, generated tasks, ActivityInfo and buffered events share it (`execution_util.go:23-190`). RangeID and record-version conditions fence stale writers (`sql/shard.go:152-176`; `execution_util.go:629-695`).
- Uncertain writes trigger shard reacquisition before reliable readback (`shard/context_impl.go:1501-1549`); task notifications can occur on possibly successful errors (`workflow/transaction_impl.go:184-214`); cache reload reconstructs from DB (`workflow/context.go:408-497`).
**Affected code paths**: `ContextImpl` update/load; transaction implementation; shard update/reacquire; execution manager; selected SQL store and task store.
**Suggested modeling approach**:
- Variables: tentative versus durable Activity/WFT/buffer state, appended History batches versus committed prefix, DB record version, shard epoch, durable tasks, request response state and independent notification state.
- Actions: prepare, append History, atomically commit execution+tasks with conditions or abort; lose response; clear cache; fence/reacquire; reload/readback; deliver notification/response separately.
- Granularity: no adversarial split inside the SQL transaction. An error is not an oracle for commit: internal storage retries can surface a condition failure after an earlier attempt committed. Track backend attempts separately from the logical request. Old task deletion is best effort after commit (`common/persistence/execution_manager.go:247-309`).
**Priority**: High. **Rationale**: directly answers priority question 3 and supplies a reusable storage/identity contract for other Temporal models.

### Scenario 4: Cancellation and terminal outcomes leave a Workflow Task obligation

**Mechanism**: cancellation request, worker observation, terminal resolution, and Workflow consumption are distinct; terminal events can be buffered behind an in-flight WFT.
**Evidence**:
- Historical: [issue #5316](https://github.com/temporalio/temporal/issues/5316) was a heartbeat/cancellation contract misunderstanding; `ed47a167a262` fixed a cancellation/WFT-close interaction. [Issue #4781](https://github.com/temporalio/temporal/issues/4781) explicitly accepts separate heartbeat and timer-side state transitions.
- Code analysis: scheduled/backoff cancellation immediately records cancellation; running cancellation requests worker action (`api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:680-762`). Completion does not reject solely because CancelRequested is set (`api/respondactivitytaskcompleted/api.go:74-126`).
- Terminal APIs request a WFT; the shared updater coalesces with existing WFT work (`api/update_workflow_util.go:73-103`). Retryable failure only updates Activity state. Durable buffered events must remain representable (`workflow/mutable_state_impl.go:7621-7647`).
**Affected code paths**: WFT cancel command; completion/failure/canceled/heartbeat APIs; terminal timeout; event buffering and WFT scheduling/completion.
**Suggested modeling approach**:
- Variables: CancelRequested, worker cancellation observation, terminal outcome, pending/started WFT, buffered terminal events, consumed terminal result.
- Actions: request cancel while scheduled/running/backoff; worker heartbeat/acknowledgement; competing terminal transitions; buffer/flush event; schedule or reuse WFT; consume result and commit.
- Granularity: request plus immediate scheduled cancellation share the WFT mutation; worker observation is later. Coalesce WFT obligations rather than demanding a fresh WFT task for every terminal response. Same-transaction command-generated cancellation can be suppressed on Workflow close; it must not erase a previously acknowledged worker result.
**Priority**: High. **Rationale**: priority question 4 plus the required post-recovery Workflow progress; cancellation need not win over completion or timeout.

### Scenario 5: Independent observations must cover the entire execution

**Mechanism**: convenient public/recorder projections omit intermediate state or uncertain commits, making a passing trace prefix an unreliable fidelity claim.
**Evidence**:
- Historical: [issue #1468](https://github.com/temporalio/temporal/issues/1468) concerns intentionally delayed Started History even at maximumAttempts=1; `c6fb6b833159` stopped fabricating heartbeat timestamps at start.
- Code analysis: recorder writes only on nil delegate error and flattens task categories (`tests/testcore/history_task_recorder.go:83-168`); `ExecuteAndTimeout` executes before returning error (`common/persistence/faultinjection/fault.go:42-71`). Public retry timing fields derive from time, not observed Matching acceptance (`workflow/activity.go:125-149`).
**Affected code paths**: ActivityInfo snapshots; persistence/fault wrappers; task recorder; DescribeMutableState; public poll/result APIs and final WFT history.
**Suggested modeling approach**:
- Variables: explicit observation/request/transaction IDs and terminal trace status, separate from implementation state.
- Actions: observe immutable in-lease state, record actual storage outcome below injected errors or fenced readback, correlate queue/start/response, and close the trace only after terminal result/WFT accounting.
- Granularity: preserve causal order across observation layers; unknown fields remain missing and fail completeness, never filled from a desired successor. Use `SkipForceReload=false` for DescribeMutableState, record reload/possible flush writes, and tag volatile watermark separately from durable state.
**Priority**: High for fidelity. **Rationale**: a usable reusable model requires independent complete traces, not just agreement with a lossy History projection.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Ordinary scheduled/running/backoff/terminal lifecycle | Scenarios 1, 2, 4 | Real token guards, current ActivityInfo, four timers, cancellation and WFT responsibility |
| Non-eager Matching handoff and arbitrary delayed replies | Scenario 1 | Separate sender lease, queue transport, accepted start and delivered response; permit duplicates |
| SQL execution/task atomicity and uncertain outcomes | Scenario 3 | Two durable stages, ownership+revision conditions, commit-before-response-loss and fenced reload |
| Shared timer coverage and volatile reconstruction | Scenario 2 | Earliest physical cue, current sorted logical deadlines, persistent mask/volatile watermark |
| Complete implementation observations | Scenario 5 | Immutable transaction payload plus independent storage/ActivityInfo/task observations; final endpoint checks |

Start with one Workflow, one Activity, two attempts/workers, two ownership epochs, at most two copies of each outstanding cue/message, one injected write/response fault, finite millisecond time representatives and finite retry limits. Then add a second Activity to exercise shared timer ordering, both stamp settings, and a concurrent started WFT; retain all completed bounds and state counts. These are proposed bounds, not executed verification results.
Progress requires advancing time, eventual queue/timer service, polling workers, WFT completion, restored storage/ownership, and an eventually stable fault-free suffix. Unlimited failing retries do not imply eventual success; DLQ-parked work, deliberate pause and permanent storage failure require different obligations. Keep payloads/aggregate state below limits: Frontend can convert oversized completion into nonretryable failure while returning success (`service/frontend/workflow_handler.go:1682-1706`).

### 3.2 Do Not Model (with rationale)

| What | Why / current status |
|---|---|
| External exactly-once effects | Activity execution can repeat; server terminal uniqueness is scoped to scheduled identity, not external side effects |
| CHASM standalone Activities, ResetWorkflow/CAN, replication, worker routing and Matching internals | Explicit scope exclusions; follow only interfaces needed for ordinary contract |
| Pause/unpause and ResetActivity initially | Distinct semantics, no complete core trace calibration yet; source contracts recorded in report. Reset during running can reset Attempt and invalidate an older attempt token; do not assume universal graceful completion |
| ByID in the ordinary token transition | Force completion may synthesize Started while backoff/scheduled; the existing two functional controls passed, but extension formal fidelity is unvalidated |
| Metrics, retry arithmetic overflow, cache sizing races and local comparator/error-return mistakes | Unit/race tests or code review; no invented protocol faults or guard removals |
| Power-loss durability of SQLite NORMAL, database restart, clock skew/time skipping | Not exercised; selected logical-time/storage assumptions must be stated, with separate future experiments |

## 4. Proposed Extensions

| Extension beyond an abstract durable Activity state machine | Variables | Purpose | Scenario |
|---|---|---|---|
| Attempt-aware asynchronous handoff | `attempt`, `requestID`, `stamp`, `startVersion`, `messages` | Distinguish queued copies, accepted start and worker observations | 1 |
| Shared timeout cue scheduler | `deadlines`, `timerMask`, `cues`, `heartbeatWatermark` | Recompute current deadlines and conserve work over retry/reload | 2 |
| Explicit durable execution transaction | `cache`, `db`, `historyAppends`, `dbVersion`, `rangeID`, `responses` | Preserve atomicity while representing uncertain responses | 3 |
| Workflow result-consumption state | `cancelRequested`, `terminal`, `buffered`, `wft`, `consumed` | Represent cancellation races and durable WFT responsibility | 4 |
| Observation schema and endpoint | `observationSeq`, `transactionID`, `traceComplete` | Check independent full traces, including failure readbacks | 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| TypeOK / SingleTerminalOutcome | Safety | Well-formed lifecycle; at most one durable terminal outcome for one scheduled Activity identity | Standard; 1, 4 |
| StaleTokenDoesNotMutateCurrentAttempt | Safety | Ordinary old-attempt completion/failure/heartbeat/canceled acknowledgement changes no current Activity outcome | 1 |
| AcknowledgedOutcomeSurvivesFencedReload | Safety | Under bounded valid payloads, a successful external result acknowledgement has the committed outcome; an unknown response requires independent readback, and a known commit with lost response remains committed | 3; MC-1 |
| TimerAndRetryWorkCovered | Safety | Nonterminal eligible work retains a physical/in-flight covering cue, queued/started work with applicable deadlines, or covering Workflow expiration; no false one-task-per-deadline requirement | 2; MC-2 |
| TerminalResultHasWorkflowResponsibility | Safety | While Workflow is open, terminal information persists in History or durable buffer AND unconsumed information has pending/started WFT responsibility; closure cannot erase a prior acknowledged worker result | 3, 4; MC-1 |
| EligibleWorkEventuallyResolves | Liveness | Under stated fairness, stable recovery and finite policy/deadline, Activity resolves and live Workflow can consume it | 2, 3, 4 |
| CompleteTraceUsesIndependentEvidence | Fidelity | All required state/outcome fields and terminal endpoint are implementation-observed; missing observations produce INCOMPLETE | 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

These are unresolved current-code interaction questions, not confirmed bugs or replays of fixed historical defects. Keep all existing guards and transactions.

| ID | Description | Expected invariant violation if a defect exists | Scenario |
|---|---|---|---|
| MC-1 | Can an uncertain terminal commit composed with an already-started WFT, buffered terminal event, delayed competing reply and fenced reload lose or contradict the Workflow's responsibility to consume the result? | AcknowledgedOutcomeSurvivesFencedReload; TerminalResultHasWorkflowResponsibility | 3, 4 |
| MC-2 | Can a cue scanning two Activities, heartbeat deadline extension, one retry and reload of the volatile watermark leave current timer/retry work uncovered after the execution transaction commits? | TimerAndRetryWorkCovered; conditional progress | 2, 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-1 | Recorder/Describe projections do not establish uncertain durable outcomes or complete causal ordering | Real `Timeout` versus `ExecuteAndTimeout`, immutable in-lease snapshots, task-store readback after fencing, negative controls for wrong attempt/durable state; then consume terminal WFT |
| TV-2 | Same-request duplicate-start response omits progress/metadata fields; known open #11734 | Lost start response followed by same-ID retry, compare full response and worker heartbeat details; absent versions skip compatibility guards, not automatic rejection |
| TV-3 | Administrative reset/unpause and ByID completion have distinct attempt/terminal contracts | After core fidelity, test running attempt >1 reset, reset flags, pause completion, and ByID/backoff with independent reloads; formal extension status remains unvalidated |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | Timeout helper discards RetryActivity error (`timer_queue_active_task_executor.go:310-313`), but concrete ordinary retry generation returns nil | Audit error contract; no established reachable ordinary trigger, and no fake storage fault inside task generation |
| CR-2 | Timer comparator returns true for equal keys (`workflow/timer_sequence.go:508-509`) | Review strict ordering; normal generated entries are unique, no demonstrated lifecycle impact |
| CR-3 | With retry stamp increment disabled, receiver lacks attempt/not-before check on old dispatch copies | Review/document configured backoff contract; historical rollout mechanism of #8607/#8536, not new MC discovery |
| CR-4 | Known open retry-policy update omission (#11214) and precommit cache lifetime (#11660) | Retain for later code audit/targeted tests; avoid claiming new findings from open proposals |
| CR-5 | Timeout invalid-state logging dereferences absent ActivityInfo (`workflow/mutable_state_impl.go:4702-4709`) | Review helper error path; ordinary caller already fetched the entry under the same lease, so no reachable missing-entry trigger established |

## 7. Reference Pointers

- [Detailed audit and coverage](analysis-report.md); `analysis-evidence/` contains per-commit ledgers/patches, full issue/PR discussions, read ledgers, commands, source/configuration hashes and functional logs.
- Detailed source contracts: [API/dispatch](analysis-evidence/deep-apis-dispatch.md), [timers](analysis-evidence/deep-timers.md), [Mutable State](analysis-evidence/deep-mutable-state.md), [persistence/observation](analysis-evidence/deep-persistence-observation.md).
- Reference contract: [Activity execution](https://docs.temporal.io/activity-execution), [failure detection](https://docs.temporal.io/encyclopedia/detecting-activity-failures); these are live documents, while the pinned implementation controls this model.
- Historical/context-only: [#8607](https://github.com/temporalio/temporal/pull/8607), [#8536](https://github.com/temporalio/temporal/pull/8536), [#3667](https://github.com/temporalio/temporal/issues/3667), [#5914](https://github.com/temporalio/temporal/issues/5914). No removed check, pre-fix timer mask, or reverted historical behavior is a proposed adversary.
