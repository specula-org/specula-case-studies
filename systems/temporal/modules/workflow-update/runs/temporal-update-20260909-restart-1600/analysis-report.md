# Temporal Update commit and recovery: Code Analysis audit

## Result and assurance boundary

This report analyzes production revision **`0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`**. It records five test-backed review observations: four through public APIs/SQLite, one through the real timer queue/executor with mocked persistence. There are no maintainer-confirmed new bugs and **zero model-checking discoveries**. The completed ordinary commit/recovery tests returned consistent durable results. The result-cache question and full public confirmation of the timer observation remain open.

The primary deliverable is [modeling-brief.md](modeling-brief.md). This is the Code Analysis phase: reconnaissance, bug archaeology, deep analysis/verification, and Scenario-based handoff. No TLA+ specification, TLC exploration, proof, or implementation-trace validation is reported as executed. The Go logs and observation records are implementation evidence, not validated TLA+ traces.

| Observation | Concrete user impact | Evidence status |
|---|---|---|
| CR-1: stale completion clears a sticky replacement | A valid replacement completion also gets NotFound, causing additional replay/work. Same-ID retry still obtains the correct result. | Public Frontend/History/Matching/SQLite control and recovery reproduced. |
| CR-2: Sent callbacks suppress automatic rejection | An Update ignored by a worker is repeatedly redelivered instead of receiving the normal UnprocessedUpdate rejection; caller retries remain ADMITTED. | Four ignored WFTs and three retries observed; shard clear plus retry without callbacks restores rejection. No permanent missing-task claim. |
| CR-3: accepted handler failure labeled rejected | The response link labels a durably accepted/completed failure as `Update rejected`. The outcome itself is correct. | Public API and History corroborated; metadata-level impact. |
| CR-5: forced-termination failure published before write | Original caller sees a terminal closing failure while the failed termination leaves durable RUNNING/Accepted; after explicitly restoring a runtime limit, the same Update returns business success. | Exact fault, raw SQLite readback, healthy control and configuration-assisted recovery reproduced. Contract adjudication remains necessary. |
| CR-6: canceled old timeout affects replacement-normal WFT | The real executor issues a timeout for the replacement roughly one second before its deadline, discarding its started-task state. | Real queue/FIFO/executor and race-tested control; persistence mocked, no public Update caller or committed backend outcome asserted. |

These identifiers distinguish observations from the unresolved CR-4 report audit and TV-2/MC-4 cache question. They are not a claim of five novel, accepted upstream defects. No external issue, PR, comment, or message was published.

## 1. Revision, environment, and methodology

- Source: `/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/source-update`; the initial working tree was clean, HEAD matched the requested SHA, and `git rev-parse --is-shallow-repository` returned false.
- Output root: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output`.
- Tools: Go `go1.27.0 linux/amd64`; repository `go.mod:3` requests Go 1.27.0. Functional runs use `test_dep,disable_grpc_modules`, SQLite, `GOMAXPROCS=8`, package parallelism 4 and test parallelism 4. Unit race tests are identified separately.
- The required skill was `/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/Specula/skills/code_analysis/SKILL.md`; its complete guide, shared deep-analysis, distributed-analysis, archaeology, modeling-brief format and example were read. Repository `AGENTS.md` supplied test/lint conventions. Category A was recorded before deep analysis; a BFT or weak-memory overlay does not apply.
- Skill-required parallel work used three independent agents for state/effects, identity/dispatch, and persistence. Issue discussions and source/commit review were parallelized; parent cross-checks traced their shared caller paths and added public persistence-fault schedules.
- Earlier investigation notes were used only to locate scope and history context. All findings and execution counts here come from this session's source, refreshed upstream records, and local outputs.

The initial functional build hit `disk quota exceeded` on the small `/tmp` filesystem before executing tests. A task-specific `GOTMPDIR=/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/build-tmp` on the workspace filesystem resolved it. No shared files or caches were deleted. The initial failure remains in `analysis-evidence/tests/functional-baseline.jsonl`.

### Configuration relevant to interpretation

| Setting or fixture choice | Pinned value / exercised choice | Meaning |
|---|---|---|
| Frontend Update and wait-for-ACCEPTED gates | Both default true (`common/dynamicconfig/constants.go:1165-1175`) | Public ADMITTED wait requests are still rejected by `service/frontend/workflow_handler.go:5555-5556`. |
| History soft long-poll interval | Default 20 seconds (`constants.go:1864-1867`) | A lower reached stage on soft timeout is not the requested stage being falsely acknowledged. |
| Size-based Workflow cache limit | Default false (`constants.go:1869-1875`) | Known #10549 map-race work requires its distinct enabled configuration. |
| Host event cache | Default true, TTL 1 hour (`constants.go:1954-1963`; `shard/context_impl.go:2258-2267`) | A shard-context reload can retain a host cache entry; a process restart has a different lifetime. |
| WFT failure stamp increment | Default false (`constants.go:2773-2777`) | Preserve the actual flag/field checks; do not borrow open #11716's unconditional behavior. |
| Speculative schedule-to-start timeout on a normal queue | 5 seconds (`service/history/tasks/workflow_task_timer.go:15-18`) | Real timeout conversion is part of progress, including when direct dispatch fails. |
| Public commit/recovery fixtures | Dedicated one-shard SQLite clusters; explicit Run IDs; faults only on the selected execution-write ordinal | Seeds 351 (normal, second write) and 1070 (speculative, third write) give one selected fault and healthy subsequent writes. |
| Callback fixture | EnableChasm, EnableCHASMCallbacks, EnableWorkflowUpdateCallbacks; permitted local callback URL; 2-second WFT timeout and short soft waits | Enables the existing public callback attachment path. No callback HTTP-delivery or CHASM migration guarantee is tested. |
| Forced-termination fixture | Runtime History-count limit set after the second WFT starts; one failed TERMINATED mutation; recovery explicitly restores the limit | Failure-then-success depends on this supported configuration recovery. It is not evidence of progress under an unchanged exhausted limit. |

### Source-read and architecture coverage

The 12 requested core files were read in full by their assigned agents: Update API (362 lines), WFT completion API (1,184), completion handler (1,634), Update state machine (851), registry (509), abort matrix (130), Workflow context (1,670), WFT state machine (1,611), effect buffer (55), SQL execution store (762), Cassandra execution store (165), shard context (2,480): **11,413 physical lines**. This is a source-size count, not product/function coverage.

Additional complete state/store/future files and relevant complete methods in frontend, task start, Matching, timer queues, transaction helpers, event cache, PollUpdate and MutableState were followed. The larger adjacent files were not all independently reread by every agent. Exact per-agent full-file/method coverage is in [state/report.md](analysis-evidence/state/report.md), [identity/report.md](analysis-evidence/identity/report.md), and [persistence/report.md](analysis-evidence/persistence/report.md).

| Boundary | Implementation path | Atomicity / observable consequence |
|---|---|---|
| Public request validation | `service/frontend/workflow_handler.go:5476-5579` | Validate namespace, Workflow identity, Update ID/input/wait policy/callbacks. Empty Update IDs are generated; reuse an explicit ID for a retry. |
| Workflow lease and admission | `service/history/api/updateworkflow/api.go:77-247`; `service/history/api/update_workflow_util.go:67-125` | Deduplication and mutation are serialized. Ordinary admission is volatile and can use immediate effects. |
| Direct speculative dispatch | `updateworkflow/api.go:251-265,317-343` | Release the Workflow lease before Matching; matching can call History task start. Timer fallback handles dispatch failure. |
| Worker task identity / messages | `api/recordworkflowtaskstarted/api.go`; `api/respondworkflowtaskcompleted/api.go:189-231` | WFT identity is richer than event ID. Worker acceptance/response messages carry the Update identity and original request needed for normal-WFT resurrection. |
| Provisional Update transitions | `workflow/update/update.go:607-816`; `workflow/update/store.go:24-29` | Adding a History event to the mutable builder is not a database commit or caller receipt. |
| History append | `common/persistence/sql/execution.go:338-357`; `common/persistence/cassandra/execution_store.go:110-125` | Physical batches can be written before the execution mutation is committed. |
| Execution metadata and internal tasks | SQL transaction and Cassandra conditional batch; detailed persistence audit | Keep backend mutation/task commit atomic, including shard/execution conditions. A failed condition can leave an uncommitted physical History tail. |
| Effects and response | `respondworkflowtaskcompleted/api.go:676-780`; `common/effect/buffer.go:29-53` | Apply immediately after successful persistence/legitimate skip; cancel on failure. Client receipt and later response assembly are separate. |
| Clear/recovery | `workflow/context.go:174-185`; `workflow/update/registry.go:368-372` | Clear speculative timer, MutableState and registry together; old waiters retain old futures and receive appropriate retry/stage behavior. |
| Result lookup | `service/history/api/pollupdate/api.go:26-82`; `workflow/update/registry.go:458-485`; `workflow/mutable_state_impl.go:1544-1589` | Read durable Update identity under a lease, release before waiting; completion payload resolves through the event cache/store. |

The correct abstraction is a distributed durable-state/message protocol, not a new consensus algorithm. The pinned architecture docs are the reference for the Update-specific state machine; [Temporal's public message-passing documentation](https://docs.temporal.io/encyclopedia/workflow-message-passing) corroborates synchronous tracked Update outcomes. Implementation source takes precedence over stale comments or older diagrams.

## 2. Bug archaeology and source provenance

Git mining used case-insensitive full-message keywords `fix|bug|race|panic|deadlock|correctness|crash|corrupt|leak|inconsistent|wrong`. Current paths and historical paths were examined without date sampling. Keyword matches include hotfix templates, generated-code migrations, refactors, diagnostics and features; they are not a count of unique bugs. The full scoped patch corpus and per-SHA classification/root cause/severity are preserved in the three commit ledgers and the aggregate `analysis-evidence/commit-coverage.json`.

**454 distinct keyword-matched commits were reviewed/classified; 212 distinct SHAs are classified as bug fixes in at least one reviewed core path.** The overlapping subtask sets contain 65 state/effect entries (20 bug-fix classifications), 202 identity/handler entries (82), and 259 persistence/context entries (125). The aggregate deduplicates by full SHA; these are historical commits, including pre-Update/pre-Temporal ancestry, not 212 distinct Update bugs. Classification can differ by the part of a multi-component commit under review.

The machine-readable [commit coverage manifest](analysis-evidence/commit-coverage.json) contains every SHA and its provenance, root-cause/exclusion and qualitative historical severity. An unfiltered rename-history pass was used to avoid losing renames through `git log --follow --grep` filtering. Whole-repository patches were archived where needed; complete review concerns all relevant core semantic hunks and significant contextual bug-fix patches, not unrelated generated protobuf output or all Temporal commits. Five broad persistence feature/serialization ancestry patches were explicitly excluded after message/hunk-map triage; the ledgers identify them rather than counting them as deep bug-fix audits.

### Upstream collection and discussion verification

- Twelve issue searches with state `all`, multiple keywords and both bug/potential-bug label searches collected **279 distinct issue records**. Every search returned fewer than its 1,000-record requested limit; raw search responses and exact queries are in `analysis-evidence/github/search-manifest.json`.
- A fresh all-open-PR enumeration returned **370 PRs**. All titles were screened; **208** title/body keyword matches had body, file list, comments/reviews and head metadata collected for scope review. The 162 nonmatches were also screened and eight additional relevant tooling, persistence, observability or Update-test records were read in full.
- This is a scoped review of the Update investigation, not deep review of 370 unrelated PRs. Visibility, authentication, SDK examples, scheduler migration, replication, standalone activities and fairness work were excluded by component/behavior. All core-touching candidates and direct semantic neighbors were checked against this scope; detailed discussions were read for the records used as behavioral evidence.
- **60 distinct discussions (30 issues and 30 PRs)** were deeply read: all bodies and comments, plus PR reviews and inline comments, including empty discussions. The 30 initially assigned records were read concurrently in three batches; parent/identity followups added 30. Combined searches, open PR enumeration and explicit references collected **656 unique records**. Automated reviews were not treated as maintainer approval.
- Normalized discussion classifications: **20 confirmed historical/reported bug records, 5 design defects/limitations, 14 uncertain, 1 disputed explanation, 1 version/user mismatch, 2 false premises/explanations excluded, and 17 excluded feature/performance/adjacent proposals**. These are record classifications, not distinct defects. The two explicit false-premise exclusions are #9118's persistence-loss explanation and #6872's claimed absence of an Update-count limit. [Deduplicated audit](analysis-evidence/github/discussion-audit.md), [machine-readable manifest](analysis-evidence/github/discussion-coverage.json).
- Collection, deep reading, historical classification, local reproduction, and current upstream confirmation are distinct counts. Individual classifications are in the linked agent issue audits and the parent table below; the aggregate discussion manifest records deduplicated totals.

Important historical mechanisms, with no reverted-fix targets:

| Reference | Established mechanism / current disposition |
|---|---|
| [#5349](https://github.com/temporalio/temporal/pull/5349) | A later handler error formerly canceled effects after a successful write; immediate Apply is present in the pin. |
| [#5784](https://github.com/temporalio/temporal/pull/5784) | Keeping registry dedup after MutableState/task loss could suppress retry scheduling; full context/registry clear is present. |
| [#6308](https://github.com/temporalio/temporal/pull/6308) | Speculative timeout lifetime and context-clear handling; use actual timer category/object semantics. |
| [#6394](https://github.com/temporalio/temporal/pull/6394) | Speculative disappearance differs from stale persisted MutableState. |
| [#4354](https://github.com/temporalio/temporal/pull/4354) | Speculative failure creates additional History events, affecting batch identity. |
| [#10578](https://github.com/temporalio/temporal/pull/10578) | Failed persistence changed caller-owned HistorySize before retry; impact was incorrect accounting, not demonstrated lost History. |
| `acbabeac7f27588975f4ab82f5addd126aabc380` / `e2f3b5fc6d969b6ef7875bfd24099da8d8387f77` | Same-WFT acceptance, completion and closure need ordered future publication. Preserve the repaired ordering in the model. |

### Current reports, exclusions, and novelty checks

| Record(s) | Discussion-derived classification | Handling in this investigation |
|---|---|---|
| [#10478](https://github.com/temporalio/temporal/issues/10478) | Uncertain ownership/skip claim; author discussion and TODO are not maintainer confirmation | Source-read skip and all downstream guards; no current user-visible unsupported result demonstrated. CR-4 remains review work. |
| [#10775](https://github.com/temporalio/temporal/issues/10775), [#11155](https://github.com/temporalio/temporal/pull/11155) | Unconfirmed build-ID impact; open PR changes logging only | Direct-failure recovery must be tested; missing logging is not a lost-task proof. |
| [#11254](https://github.com/temporalio/temporal/pull/11254) | Open author-reproduced callback attachment bug; automated reviews only | Known Admitted-state duplicate problem. CR-2 is Sent/automatic rejection and needs independent novelty adjudication. |
| [#11925](https://github.com/temporalio/temporal/pull/11925) | Open repeated-Update link repair; maintainer says link should identify acceptance | Its current diff leaves accepted-failure-as-rejection logic unchanged. CR-3 is adjacent and limited to metadata. |
| [#11660](https://github.com/temporalio/temporal/pull/11660) | Open stale host-event-cache mechanism with another consumer's panic reproducer | Update outcome lookup shares the cache and has only an event-type check; TV-2/MC-4 investigate a different consequence without claiming a new reproduced trigger. |
| [#10549](https://github.com/temporalio/temporal/pull/10549), [#11453](https://github.com/temporalio/temporal/pull/11453) | Existing cache-size race/accounting reports and proposed repairs | Keep enabled size-cache configuration explicit; no new race discovery or reason to model arbitrary concurrent map mutation. |
| [#11733](https://github.com/temporalio/temporal/issues/11733), [#11734](https://github.com/temporalio/temporal/pull/11734) | Reported ambiguous task-start response and retry identity problem, open proposal | Timeout-delayed redelivery is not permanently lost work. Existing reported mechanism, not new MC discovery. |
| [#10320](https://github.com/temporalio/temporal/issues/10320) | Claimed permanent matching deadlock disputed in discussion; additional logs requested | Exclude the asserted causal explanation as established evidence; do not erase the unresolved reported symptom. |
| [#9118](https://github.com/temporalio/temporal/issues/9118) | Claimed crash durability gap explicitly rejected by maintainer; resolved after timeout configuration changed | Exclude the proposed persistence-loss mechanism from confirmed bugs. |
| [#6375](https://github.com/temporalio/temporal/issues/6375) | Reproduced/discussed cross-run Update redelivery limitation | Outside this single-run model. Never impose run-chain deduplication here. |
| [#4979](https://github.com/temporalio/temporal/issues/4979) | Requested durable ADMITTED wait support | Feature request, not evidence that ordinary admission already promises durability. |
| [#6512](https://github.com/temporalio/temporal/issues/6512) | Measured Update latency growth | Performance evidence, not a safety or permanently missing-result finding. |
| [#7741](https://github.com/temporalio/temporal/issues/7741) | Maintainer-acknowledged premature-end-of-stream WFT failure; repair was reverted | Known recoverable replay/observability problem; no novel durability claim. |
| [#10050](https://github.com/temporalio/temporal/pull/10050) | Proposed CQL idempotence flags; reviewer notes no configured retry policy | Do not invent driver retries absent in the pinned configuration. |
| [#11713](https://github.com/temporalio/temporal/pull/11713), [#11714](https://github.com/temporalio/temporal/pull/11714), [#11174](https://github.com/temporalio/temporal/pull/11174) | Performance proposals retaining existing transaction/fence semantics | No arbitrary independent commit of execution fields/tasks. Open code is not substituted for the pin. |
| [#10841](https://github.com/temporalio/temporal/issues/10841) | Orphan current-execution pointer symptom; cause not established | Cross-run/orphan repair is outside scope; ordinary crash is not assumed to create it. |
| [#9332](https://github.com/temporalio/temporal/pull/9332), [#9257](https://github.com/temporalio/temporal/pull/9257), [#9077](https://github.com/temporalio/temporal/pull/9077) | Activity-history visibility, timeout metadata, and log-message proposals | No change to the in-scope Update completion contract established; not MC targets. |
| [#11716](https://github.com/temporalio/temporal/pull/11716), [#11804](https://github.com/temporalio/temporal/pull/11804) | Retry-gate cleanup and lazy timer decoding | Reference configuration/performance proposals; do not import their behavior into the model. |
| [#11507](https://github.com/temporalio/temporal/pull/11507), [#11506](https://github.com/temporalio/temporal/pull/11506) | SQLite/initialization factory lifetime work | Backend readback fixture assurance is stated at the actual close/reopen boundary, not claimed as process restart. |
| [#11961](https://github.com/temporalio/temporal/pull/11961), [#11921](https://github.com/temporalio/temporal/pull/11921), [#11840](https://github.com/temporalio/temporal/pull/11840), [#11940](https://github.com/temporalio/temporal/pull/11940) | Fault tooling, Update/Nexus tests, termination metrics, and HTTP error-detail repair | Context for test seams, neighboring coverage and observability; no novel in-scope bug counted. |
| [#10238](https://github.com/temporalio/temporal/pull/10238), [#9267](https://github.com/temporalio/temporal/pull/9267) | Reviewer challenges unaccounted non-BUSY error-to-spool behavior in the first; recommends replacing obsolete cancellation API in the second | Do not adopt an open proposal's claimed dispatch guarantees without its unresolved review qualifications. |
| [#10548](https://github.com/temporalio/temporal/issues/10548), [#11711](https://github.com/temporalio/temporal/issues/11711), [#11710](https://github.com/temporalio/temporal/issues/11710), [#3134](https://github.com/temporalio/temporal/issues/3134), [#6323](https://github.com/temporalio/temporal/issues/6323), [#6352](https://github.com/temporalio/temporal/issues/6352), [#6872](https://github.com/temporalio/temporal/issues/6872) | Additional actual-issue audit: known cache race, SQL optimizations, old shard-acquisition coupling, transport leak, resolved version mismatch, and a false missing-limit premise | Full per-item source applicability, discussion and exclusion are in [the final issue batch](analysis-evidence/identity/issues-final-batch/report.md). |

Every listed record has preserved full discussion evidence, even when the conclusion is exclusion. The other assigned historical issues (#4142, #4143, #4018, #5174, #6085, #6614, #11600, #4641, #5063, #435, #3545, #3135, #2306) are classified individually in the agent audits. Historical confirmed-bug counts use the skill's reproduction-or-acknowledgment criterion and therefore include author-reproduced reports; they are not equivalent to maintainer-confirmed current bugs.

## 3. Priority-question audit

### Q1: write uncertainty, effect cancellation, cache loss and caller receipt

The public pipeline was followed through frontend validation, Workflow lease, registry admission/deduplication, normal/speculative scheduling, Matching task start, worker protocol processing, persistence, effects, response, and subsequent PollUpdate/same-ID lookup. SQL and Cassandra both append History before the conditional execution/task mutation. Their atomicity boundaries must remain intact; a physical append is not committed Update acceptance. See the detailed [persistence audit](analysis-evidence/persistence/report.md).

`common/persistence/faultinjection/fault.go:42-47,61-72` makes `ExecuteAndTimeout` invoke the real backend and return the injected Timeout only if the backend succeeded. Ordinary `Timeout` skips the backend operation. Runtime `FaultInjection.Injector` is pre-operation only (`faultinjection/store_fault_generator.go:41-48`); returning Timeout there cannot prove a committed operation. The public fixture uses the configured ExecuteAndTimeout path, not a mock claiming commit.

At the selected normal/speculative completion write, the actual WFT completion call returns the fault marker. Direct SQLite readback finds no Update completion in the pre-operation Timeout case, but a completion pointer in ExecuteAndTimeout. The original Update caller, subsequent shard clear, PollUpdate and explicit same-ID retry converge to the same success. Exactly one UpdateAccepted and one UpdateCompleted remain in logical History. A normal WFT whose completion did not commit recovered after its roughly 10-second task timeout; the speculative case recovered through volatile re-admission. [Raw evidence](analysis-evidence/tests/commit-recovery-v2.log).

Effects apply at `respondworkflowtaskcompleted/api.go:726` before later speculative follow-up construction and response assembly; a deferred Cancel then has no rollback work. This is the fixed behavior of #5349, not a rediscovered defect. Cache clear aborts old registry objects and allows fresh lookup by durable Update ID. Already accepted old waiters can return ACCEPTED rather than an invented completion; caller polling remains necessary (`update/update.go:173-239`).

**Result:** executed ordinary schedules show neither unsupported business success, lost committed outcome nor conflicting business-success payloads. This is bounded test evidence. Two-Update effect/waiter compositions, some postcommit handler errors, and the host-event-cache outcome question remain for MC-1/MC-4 and trace-grounded reproduction.

### Q2: delayed old completions/timeouts versus replacement work

Completion checks ScheduledEventID, StartedEventID, StartedTime, Attempt and Version. Early stale-token rejection avoids clearing the entire lease as a generic error, but the deferred sticky cleanup still acts on the current speculative task. CR-1's normal control completes the replacement; sticky mode first rejects the old token and then also rejects the current replacement. Another normal-queue dispatch completes the original Update. [Final focused evidence](analysis-evidence/identity/focused-final.log).

The timer executor is a separate path. Its scheduled-ID/stamp checks precede a branch: current speculative WFTs require the particular timer object, whereas current normal WFTs use version and attempt (`timer_queue_active_task_executor.go:408-433`). Do not add the completion-token StartedTime check or unconditional timer-pointer equality to that normal branch in a model.

**CR-6 component evidence:** the new test lets an old speculative START_TO_CLOSE timer enter the real FIFO/executable path, pauses immediately before the real executor, clears/reloads the Workflow context, and starts a replacement with reused scheduled/started IDs but a later start time. A signal converts the replacement to normal through the real Workflow-context persistence flow, with a mocked execution manager. The canceled old timer passes actual shard-clock/generation/version/attempt/stamp checks and issues a timeout event for the replacement about 999ms before its deadline. The replacement-left-speculative control rejects the old timer and remains started. The same test also passes with `-race`. This establishes the mutation issued by the real queue/executor, not an actual database commit or public Update response. [Detailed evidence and remaining integration schedule](analysis-evidence/state/timer/report.md).

**Result:** CR-1 is concrete extra invalidation/replay, with recovery demonstrated. CR-6 establishes early timeout at the real queue/executor layer; full public-handler/backend confirmation remains unexecuted. Models must preserve identity checks, conditional timer validation and side effects after rejection.

### Q3: mixed outcomes, closure and waiting

The Update state machine separates provisional acceptance/completion/abort from futures visible outside the Workflow lease. Commit callbacks run FIFO; rollback callbacks run LIFO. Same-WFT accept+complete and accept+close use an intermediate state so outcome publication precedes acceptance publication. Complete-then-close preserves the Update result; post-close rejection is allowed without adding a History event. Closed-registry reconstruction turns durable acceptance without completion into the documented terminal closing failure. The full permitted-combination table and source anchors are in [state/report.md](analysis-evidence/state/report.md).

CR-3 is a distinct presentation mismatch: an accepted handler failure is durably recorded correctly, yet `Updater.OnSuccess` treats any failed outcome as a rejection when constructing its link (`updateworkflow/api.go:278-295`). The test asserts both durable events and the returned link; it does not conflate handler failure with preacceptance rejection.

CR-5 follows an exceptional limit path, not ordinary workflow closure. `ContextImpl.forceTerminateWorkflow:1571-1583` explicitly aborts Updates before clearing/reloading/persisting termination, with a comment assuming the workflow cannot progress under a serious limit. The targeted fixture persists acceptance, starts another WFT, lowers the supported runtime History-count limit to make its completion trigger forced termination, and injects Timeout only into the TERMINATED mutation. The old caller receives COMPLETED with a closing failure while raw storage remains RUNNING/Accepted. After **explicitly restoring the limit**, the same completion succeeds and PollUpdate returns business success. A healthy termination control stores TERMINATED. [Evidence](analysis-evidence/tests/force-termination-v1.log).

**Result:** ordinary close/effect combinations pass their existing tests; CR-5 proves a failure-then-success observation under configuration-assisted recovery. Do not claim two business-success payloads conflict, that an unchanged exhausted limit permits progress, or that the developer's deliberate behavior has already been ruled a bug. Conversely, do not hide this observed exception by assuming a durable-close guard absent from code. Contract and novelty review belong in Phase 4.

### Q4: direct dispatch, fallback, deduplication and request lifetime

The speculative WFT's in-memory schedule-to-start timeout exists even on a normal task queue. Direct Matching dispatch runs after lease release; its failure is intentionally swallowed while timeout conversion creates a normal WFT and durable transfer task. Cache loss removes both volatile registry identity and task/timer state, allowing API retry to recreate the request. Existing functional tests cover lost admission, closed-shard lookup, duplicate IDs, sticky-worker unavailability and timeout conversion.

The existing `TestSpeculativeWorkflowTask_ScheduleToStartTimeoutOnNormalTaskQueue` sleeps until timeout and explicitly says it does not shut Matching down (`tests/update_workflow_test.go:2767-2778`). It proves timeout behavior, not occurrence of a dispatch RPC fault. The new `TestAnalysisSpeculativeDispatchFailureRecovery` injects Unavailable into actual AddWorkflowTask calls for speculative scheduled event 5. **Two faults fired**, then timeout conversion produced normal scheduled event 7, which reached the worker. The original caller and explicit same-ID retry received the same result; History contains one WFT timeout and one Update completion. The test passed in 5.12 seconds. [Evidence](analysis-evidence/tests/dispatch-failure-v1.log).

CR-2 follows callback attachment through the public API into a Sent Update. A duplicate request buffers callbacks; automatic RejectUnprocessed reaches a pending-buffer error that the registry discards. The current handler still finds outgoing Sent work and schedules a normal successor. Four successful WFT completions that ignore the Update grow History to event 17; three retries stay ADMITTED. Shard close/reload and retry **without callbacks** restore the ordinary rejection. Compatible-worker processing is source-supported but was not the executed recovery. [Evidence](analysis-evidence/state/callback-unprocessed-functional.log).

**Result:** missing automatic rejection and repeated work are demonstrated. The initial claim that this path had no successor task was falsified and explicitly excluded. Direct-failure/cache-replacement compositions and scheduler-held old timers are separate open questions; progress requires available capable workers, timer/task processing, finite disruption and appropriate API retries.

## 4. Executed tests and preserved failures

| Verification | Result and meaningful coverage | Artifact |
|---|---|---|
| Existing WorkflowUpdateSuite | PASS: 80 named Go test nodes, including nested subtests, no skips; 8.136 seconds test runtime. Includes some cross-run existing controls but does not expand the model scope. | `analysis-evidence/tests/functional-baseline-retry.jsonl` and command manifest |
| Final combined functional run | PASS: 100 named test nodes / 86 leaf tests, no skips; 25.513 seconds test runtime. Baseline plus all public analysis fixtures, including both identity tests and dispatch fault. | `analysis-evidence/tests/functional-final.jsonl`, `functional-final-command.json` |
| Public normal/speculative write/receipt matrix | PASS, eight cases; exact injected fault markers, raw persistence readback, shard reload, client outcome and one logical acceptance/completion. | `analysis-evidence/tests/commit-recovery-v2.log` |
| Actual speculative dispatch RPC fault | PASS; two injected Unavailable responses, timeout-to-normal scheduling, worker processing and same-ID result recovery; also included in final combined run. | `analysis-evidence/tests/dispatch-failure-v1.log` |
| Exceptional forced termination | PASS, two cases; healthy control and failed termination followed by explicit runtime-limit recovery. | `analysis-evidence/tests/force-termination-v1.log` |
| Sticky stale-completion and failed-outcome link fixtures | PASS; normal control, stale/current rejection, final caller recovery and metadata assertions. | `analysis-evidence/identity/focused-final.log` |
| Submitted old timer versus replacement-normal task | PASS, two controls and a race-detector run. Real queue/FIFO/executor issues early timeout; backend mocked. | `analysis-evidence/state/timer/{queue-executor-v3,queue-executor-race}.log` |
| Callback automatic rejection | PASS, healthy and callback cases; four re-deliveries, retries, shard-clear recovery. | `analysis-evidence/state/callback-unprocessed-functional.log` |
| Update/effect package tests and race detector | PASS, including state/rollback matrix and focused registry probe. | `analysis-evidence/state/unit-tests.log`, `unit-race-tests.log` |
| Handler packages | PASS for Update, task-start and completion packages. | `analysis-evidence/identity/unit-handlers.log` |
| Shard/persistence unit and existing SQLite suites | PASS; exact package selection and runtime in persistence audit. | `analysis-evidence/persistence/{unit-tests,shard-tests,sqlite-tests}.log` |
| Real file-backed backend write/readback | PASS, healthy/Timeout/ExecuteAndTimeout/StaleRangeID. Atomic execution/task behavior and logical History bound checked after factory close/reopen. | `analysis-evidence/persistence/write-outcome-readback.log` |
| Required changed-package lint and custom vet | PASS on all four changed packages after correcting fixture lint findings; `make lint-code-fast GOLANGCI_LINT_BASE_REV=HEAD GOLANGCI_LINT_FIX=false`, zero issues. | `analysis-evidence/tests/lint-v3.log` |

Test-node counts are obtained from `go test -json` named `pass` records; leaf tests exclude names that are parents of another test. These are test-selection counts, **not** source coverage, model-action coverage, successful production executions, or TLC states. Final source fixture hashes and any followup test results are in `analysis-evidence/artifact-manifest.json`.

The new fixtures are separate files only:

- `tests/update_analysis_commit_test.go` — public write uncertainty, caller response loss, exceptional termination and direct-dispatch fault schedules.
- `tests/update_analysis_identity_test.go` — stale sticky replacement and accepted-failure response link.
- `tests/update_analysis_state_test.go` — callback/automatic-rejection schedule.
- `service/history/workflow/update/update_analysis_state_test.go` — focused registry control.
- `service/history/update_analysis_timer_test.go` — real queue/executor stale-timeout control with mocked persistence.
- `common/persistence/tests/update_analysis_persistence_test.go` — real SQLite write-result/readback contract.

No production source was altered, no upstream branch was checked out, and no commit was made. Fixtures, commands, logs and their unsuccessful predecessors are preserved so results can be reviewed independently.

Recorded unsuccessful attempts are not hidden: the initial `/tmp` quota failure; omission of `ArchetypeID` in the first raw-readback fixture (the actual behaviors ran but its testlogger correctly failed the test); callback probe's disproved no-successor expectation and waiter/dedicated-cluster setup corrections; and four first-pass lint findings in new fixtures. Corrected final tests pass. None of these setup failures is reported as a Temporal bug.

Representative reproducible commands, from the source repository:

```sh
GOMAXPROCS=8 GOTMPDIR=/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/build-tmp CGO_ENABLED=0 \
  go test -tags test_dep,disable_grpc_modules -p 4 -parallel 4 -count=1 -timeout 5m \
  ./tests -run '^TestWorkflowUpdateSuite$|^TestAnalysis' -args -persistenceType=sql -persistenceDriver=sqlite
GOMAXPROCS=8 GOTMPDIR=/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/build-tmp \
  go test -tags test_dep -race ./service/history/workflow/update ./common/effect -count=1
GOMAXPROCS=8 GOTMPDIR=/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/build-tmp \
  make lint-code-fast GOLANGCI_LINT_BASE_REV=HEAD GOLANGCI_LINT_FIX=false
```

## 5. False positives, compensations, and contract limits

1. **Volatile admission is not committed acceptance.** Public ADMITTED wait support is absent; an ADMITTED soft-timeout reply requires retry. Cache loss before acceptance is not by itself lost committed data (`frontend/workflow_handler.go:5555`; `update/update.go:231-253`).
2. **Rejection is not durable completion.** It can be returned as a completed lifecycle outcome and later be NotFound or be retried. Do not require permanent rejection deduplication or classify retry acceptance as contradictory business success (`docs/architecture/workflow-update.md`; `registry.go:458-485`).
3. **Accepted-but-unfinished closing failure is allowed.** Ordinary final Workflow close can synthesize that failure on registry reconstruction without a separate UpdateCompleted event (`registry.go:207-223`). CR-5 is specifically the failed forced-close/recovery exception.
4. **A physical History tail is not a committed Workflow mutation.** The stale-range backend control leaves two physical events but only one in the logically bounded history, with no committed update/task (`write-outcome-readback.log`). Do not report it as split SQL/Cassandra transaction corruption.
5. **A Timeout does not prove noncommit.** ExecuteAndTimeout directly demonstrates this. Known condition failures and uncertain write results require different model actions; reacquisition/fencing cannot be omitted.
6. **Old completion rejection does not prove all cleanup is harmless.** CR-1 demonstrates current sticky replacement invalidation, while also demonstrating recovery. Reject the overclaim of permanent Update loss.
7. **Callback rejection failure does not imply no remaining delivery task.** `HasOutgoingMessages(true)` and nonheartbeat resend are compensations. Preserve the repeated-work finding while excluding the disproved stranded-task claim.
8. **No arbitrary worker-message order.** Acceptance/completion must pass real protocol IDs, allowed states and command-order checks. Invalid worker messages are not proof of a safety violation unless their actual accepted handler consequences violate the API.
9. **Current reports are not all confirmed.** #10478/#10775 remain uncertain; #10320's causal claim is disputed; #9118's proposed durability mechanism was rejected; #11254 has author reproduction and automated reviews, not maintainer acceptance.
10. **Retries and retention matter.** Progress assumes eventual service recovery, eligible timers/tasks, capable workers and required client retries; result queryability is bounded by Workflow retention/deletion. Cross-run retries and replication remain excluded.

## 6. What formal modeling can add, and exact remaining work

Code review plus focused execution produced the five observations above, at their stated verification layers, and established ordinary write/receipt/fallback controls. These are **CR/test contributions**, not formal discoveries. Existing tests already exercise many difficult Update schedules; merely reproducing #5349/#5784/#6308 or rerunning these fixtures in TLA+ would not establish a new contribution.

The actionable formal contribution is systematic composition with an explicit implementation abstraction: two Update IDs, normal/speculative task generations, a real atomic persistence boundary, distinct write-return/effect/caller stages, conditional timer guards, host event-cache lifetime and actual API retries. MC-1 through MC-4 in the brief identify unresolved successful-result and progress questions. In particular, the cache hypothesis has an externally meaningful potential consequence beyond the already reported activity consumer: a same-type stale UpdateCompleted event can pass the type-only check and yield a different Update's payload. A reachable two-host schedule and real public-API reproduction are still required; no fabricated cache insertion alone will confirm it.

| Remaining work | Status / exact gap | Handoff |
|---|---|---|
| Formal spec, TLC and trace validation | NOT EXECUTED in Code Analysis; no state-space completeness or invariant-pass claim | Spec Generation and subsequent validation phases |
| Two-Update write/effect/waiter compositions | One-Update write-fault controls executed; full combinations not enumerated | MC-1/MC-3 |
| Event-cache wrong-Update payload | Complete source call chain and #11660 overlap checked; two-host ownership/write/requery schedule unexecuted | MC-4 then real backend/public-handler reproduction |
| Scheduler-held old timeout versus normal replacement | Real queue/executor control issues premature timeout; public Update/worker outcome and real backend commit not exercised | CR-6 full integration confirmation; preserve behavior in MC-2 compositions |
| CR-1/2/3/5/6 severity, novelty and intended contract | Local controls exist at the recorded layers; maintainer confirmation absent | Phase 4 audit with exact fixtures and upstream discussion context |
| Production database/server restart coverage | SQLite factory reopen and shard reload executed; full process-kill recovery and live PostgreSQL/MySQL/Cassandra deployment acceptance not executed | Backend-specific confirmation if a durable claim depends on it |
| Callback capability restoration and inline successor mode | Source-supported compatible-worker recovery; tested recovery used cache clear and a retry without callbacks; ReturnNewWorkflowTask=false exercised | Targeted trace/reproduction extension if relevant to a finding |

### Required implementation observations for trace validation

Workflow History alone does not expose the relevant state transitions. Reuse the meaningful existing fixtures and record, with stable request/task/generation identifiers:

- Persistence attempt, backend operation actually executed or skipped, backend return, RangeID/record version, readback UpdateInfo and logical History boundary; distinguish the wrapper's returned error from actual stored state.
- Registry creation/clear/abort, cache owner/generation, volatile Update state, durable Update ID and event pointer; do not treat old and replacement objects as one mutable object.
- Event-cache Put/Get hit/miss with its actual key, cached event type/Update ID/payload and owning host; retain precommit insertion and shard-reload survival.
- Effect registration/order, Apply versus Cancel, future publication and the actual client observation. A History event alone is not proof that a waiter observed it.
- WFT ScheduledID/StartedID/StartedTime/Attempt/Version/Stamp, speculative/normal conversion, timer identity, timer scheduling/submission/cancellation/execution, and downstream validation branch.
- Matching dispatch outcome, fallback transfer-task creation, worker-delivered messages, retry request identity/wait policy, public response or PollUpdate outcome.

Validate these traces against an implementation-faithful spec before interpreting an MC counterexample. Keep FIFO commit/LIFO rollback, conditional-write guarantees, existing identity defenses, allowed rejection/closure behavior and explicit recovery assumptions. If a broad exploration is incomplete, report the remaining queue/states and isolate the implicated combination; do not call it a pass or change the property solely to erase a counterexample.
