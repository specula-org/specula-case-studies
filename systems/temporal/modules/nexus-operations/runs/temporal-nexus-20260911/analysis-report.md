# Analysis Report: Temporal Nexus Operation Commit and Recovery

## Result and evidence boundary

At Temporal `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`, this Code Analysis phase found and independently reproduced three current behaviors:

| ID | Observable result | Discovery / confirmation | Impact |
|---|---|---|---|
| B1 | Cancel intent committed before async Started causes the configured start-to-close timer to be omitted. Ordinary shard close/reload preserves the omission; explicit task refresh repairs it. | Source-review discovery; real endpoint ordering, handlers, SQLite DB readback and refresh control | Operation can remain pending beyond its configured STC, indefinitely if neither another timeout nor terminal callback resolves it |
| B2 | Normal operation timeout retains a terminal HSM node; Describe hides it, but next scheduling command counts it against the pending-operation limit. | Source-review discovery; real timeout, limit1 rejection, raw DB readback after shard close; sync-success control | After enough timeouts, an otherwise open workflow cannot schedule another Nexus operation |
| B3 | Omitted schedule-to-close duration with no workflow run limit bypasses the configured maximum; explicit long duration is capped. | Source-review discovery; command through SDK/server, real endpoint acceptance, SQLite readback after shard close | Configured operation-duration maximum is not applied to the omitted-duration case |

These are **three source-review discoveries with local functional confirmation**, not three proven globally novel reports. Relevant upstream discussions and targeted searches were refreshed on 2026-09-11; no exact existing report for these three mechanisms was established by those searches. Known related fixes are attributed below. There is **no TLC execution, formal counterexample, MC-first discovery, MC reconfirmation, or trace-validation result in this phase**. Model generation, complete trace instrumentation, persistence fault schedules and bounded exploration are the next-phase handoff in [modeling-brief.md](modeling-brief.md).

The probes use the actual Temporal SQL persistence stack and **SQLite `mode=memory, cache=shared`**, not a fake HSM environment. They establish committed database state across workflow-cache/shard lifecycle, while the database remains alive in the test process. They do **not** establish filesystem durability after process exit/power loss, PostgreSQL/MySQL/Cassandra behavior, or uncertain-write recovery. The controlled remote endpoint establishes acceptance/response/cancel ordering, not a production endpoint's idempotency or cancellation implementation.

## Methodology, revision and coverage

Applied the explicitly supplied skill `/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/Specula/skills/code_analysis/SKILL.md`, its complete `guide.md`, shared deep-analysis, distributed-analysis, bug-archaeology and modeling-brief-format references, plus its full example. Classified **Category A** before archaeology: RPCs, timers, storage and recovery interleave across workflow lock boundaries; no Byzantine threat model. Per skill, three parallel subagents handled issue verification and then complete major-file analyses, while the parent audited commands/configuration/persistence and executed checks. No production source edits or GitHub writes were made.

Source root: `/home/ubuntu/temporal-investigation-20260909/parallel-20260911/source-nexus`. Git HEAD equals the requested full SHA, repository is not shallow, origin is `https://github.com/temporalio/temporal.git`, and initial/final worktrees are clean. Go is `go1.27.0 linux/amd64`, matching go.mod. Current source, not historical memory or an upstream PR branch, determines every reported implementation behavior.

For source citations, bare operation filenames (`commands.go`, `statemachine.go`, `executors.go`, `completion.go`, `events.go`, `tasks.go`, `config.go`) mean `service/history/hsm/nexusoperations/`, with commands under `workflow/`. Shared HSM, frontend, workflow and persistence files are otherwise named by repository-relative path. All line references describe the pin.

### Phase 1: structural coverage and configuration

Full core reads include commands358 + config210 + state machine682 + tasks365 + executors1284 + completion283 + events359 = **3,541 physical source lines**, excluding tests, metrics/fx/doc and shared infrastructure. Additional full reads include HSM tree821/tasks81/sm66/executor69, state-machine environment415, outbound executor172, logical timer grouping124, frontend completion HTTP handler691, callback token127, complete Nexus completion HTTP protocol client/server, and architecture documentation. Full relevant read/commit/reload/refresh/history-visible-prefix functions in the larger workflow/persistence files were traced. Detailed file-read inventories and tests consulted are in [executor audit](analysis-evidence/deep-executors.md), [state/recovery audit](analysis-evidence/deep-recovery.md), and [completion audit](analysis-evidence/archaeology-completion/deep-completion.md). This does not claim full reading of unrelated 8,000-line mutable-state or every persistence subsystem.

| Setting / boundary | Verified value and source |
|---|---|
| HSM versus CHASM | HSM suite explicitly passes false for EnableChasm, EnableCHASMCallbacks and EnableChasmWorkflowOperations, rollout0 (`tests/nexus_workflow_test.go:71-92`); command fallback `workflow_task_completed_handler.go:347-369`; default flags `chasm/lib/nexusoperation/config.go:38-65` |
| Standalone/system endpoint | Excluded; probes use a Workflow Run and external test endpoint, not `__temporal_system` |
| Callback route | External callback URL set to actual test frontend HTTP listener by `tests/testcore/onebox.go:454-463`; worker-target URL is `temporal://system` in current executor routing. Pinned architecture doc includes older mandatory-template prose, so live route code takes precedence |
| Persistence | `-persistenceType=sql -persistenceDriver=sqlite`; `common/persistence/persistence-tests/setup.go:128-140` supplies memory/shared; emitted cluster configs in probe logs confirm it |
| Transition/reference controls | history.enableTransitionHistory=true (`tests/testcore/dynamic_config_overrides.go:70`); history.enableUpdateWorkflowModeIgnoreCurrent default=true (`common/dynamicconfig/constants.go:1911-1920`) |
| Timeout and retry defaults | request timeout10s, minimum1.5s; retry initial1s/max1h; max S2C0 meaning no configured cap; operation max-concurrency30 (`nexusoperations/config.go:15-43,106-131`) |
| Queue and cancellation observation | outboundTaskBatchSize default100, not disabled (`common/dynamicconfig/constants.go:2329-2332`); RecordCancelRequestCompletionEvents=true (`config.go:147-151`) |
| Probe overrides | B1 STC3s, S2C/S2S/run timeout absent; B2 max concurrent1, S2C3s; B3 configured max S2C3s, requested0 vs60s, no run timeout |
| Probe isolation | Dedicated test clusters for every shard-close probe; controlled local HTTP endpoints (`common/nexus/nexustest/server.go:21-35`); GOMAXPROCS4, Go build parallelism4, test parallelism1 for focused probes |

### Phase 2: archaeology census

The denominator is the declared **operation/HSM/callback caller core history**, not all Temporal commits. Searched all refs with the required fix/bug/race/panic/deadlock/correctness/crash/corrupt/leak/inconsistent/wrong keywords, then screened **all** core commit subjects/bodies to catch fixes without those words. Followed historical `components/nexusoperations` and `plugins/nexusoperations` locations; the latter added no unique commits. Corrected the initial nonexistent frontend path to `service/frontend/nexus_completion_http_handler.go` and added actual `service/history/statemachine_environment.go` history before finalizing.

| Census | Count / interpretation |
|---|---|
| Initial keyword candidates | 108, all classified with full scoped implementation hunks reviewed |
| Non-keyword core commits | 91, every metadata/file list screened; significant/mixed/fix production diffs reviewed and classified individually |
| Actual callback/environment path delta | 24 additional unique commits, every scoped diff reviewed |
| Total core commits analyzed/classified | **223/223**; all 223 ancestors of the pin; no sampling of the bug-fix candidates |
| Explicit bug-bearing classifications | **82 commit records**: start27, completion27, recovery28; includes historical, diagnostics and adjacent fixes; not 82 unique bugs and not 82 current Nexus bugs |
| Other classifications | 141 feature/refactor/design/hardening/revert/scope records, with rationale; some design changes address limitations without claiming a specific bug |
| Issues collected | 25 distinct issue objects from six searches (`nexus`, cancellation, callback, persistence, HSM, Nexus bug-label); all25 bodies and all comments deeply read |
| Issue classifications | 8 confirmed/source-supported historical or known reports;4 uncertain;11 feature/design/support requests;1 user configuration error;1 environment-dependent test issue |
| Full issue/PR discussions | **45** =25 issues+20 PRs; every referenced discussion's entire body, issue comments, reviews and inline review comments read; no comment-pagination truncation |
| Confirmed/source-supported discussions | 23/45 discussion items, including duplicate issue/PR descriptions of the same mechanism; never a unique-bug count |
| Explicit non-bug issue search exclusions | 13/25 =11 feature/design/support +1 configuration +1 environment/test issue. Four uncertain reports remain uncertain, not debunked. Out-of-scope confirmed bugs are excluded separately |
| Live open PR scope screen | 387 open PR metadata records;76 title/label bug-intent candidates had complete changed-file lists fetched; all relevant lifecycle/callback/persistence candidates deep-reviewed or explicitly excluded by scope |

The skill's 30+ issue depth target was addressed by exhausting all25 collected issue threads and reading20 relevant PR threads, rather than padding the issue-only count with unrelated reports. There were 45 complete discussions, **not 45 issue objects**. No claim of a complete global GitHub search or full review of every unrelated open Temporal patch is made.

Raw search results: [issue queries](analysis-evidence/issue-searches.json), [all core commits](analysis-evidence/all-core-commits.txt), [24-path delta](analysis-evidence/callback-environment-extra-commits.txt), [open PRs](analysis-evidence/open-prs.json), [76 scope screens](analysis-evidence/open-bug-pr-screen.json), [targeted novelty searches](analysis-evidence/lead-novelty-searches.json). Every significant commit has a row with root cause, component, severity and pin/ancestor status in these complete ledgers:

| Reviewer slice | Keyword / non-keyword / path delta | Detailed ledgers |
|---|---|---|
| Start/executors | 36 /31 /8 =75 | [initial](analysis-evidence/archaeology-start/report.md), [supplement](analysis-evidence/archaeology-start/supplement/report.md), [caller delta](analysis-evidence/archaeology-start/callback-environment/report.md) |
| Completion/events | 36 /30 /8 =74 | [initial](analysis-evidence/archaeology-completion/archaeology-report.md), [supplement](analysis-evidence/archaeology-completion/supplement/supplement-report.md), [caller delta](analysis-evidence/archaeology-completion/callback-environment-addendum/addendum-report.md) |
| State/tasks/recovery | 36 /30 /8 =74 | [initial](analysis-evidence/archaeology-recovery/report.md), [supplement](analysis-evidence/archaeology-recovery/supplement/report.md), [caller delta](analysis-evidence/archaeology-recovery/callback-environment/report.md) |

Full repository-wide migration patches were saved, but only relevant production hunks and affected tests were manually audited; generated protobuf/mock/dependency and unrelated subsystem churn is not disguised as deep source coverage. `*.core.diff`, `scoped-*`, production diffs and manifests document the reviewed scope. This is particularly relevant to large Go/gomock/package-renaming commits.

### Root's remaining ten issue threads and three open PRs

The first fifteen issue threads and initial fifteen PR threads are classified individually in the ledgers above. Start reviewer additionally deeply read #7171 and #10787. The root read these remaining13 threads in full, with raw bodies/comments/reviews/diffs under `analysis-evidence/root-discussions/<number>/`:

| Thread | Classification / conclusion after full discussion |
|---|---|
| [#680](https://github.com/temporalio/temporal/issues/680) | Feature: waiting for external workflow; maintainer recommends loosely linked Nexus WorkflowRunOperation; no lifecycle defect established |
| [#1460](https://github.com/temporalio/temporal/issues/1460) | Worker/task-queue query feature; per-process Nexus endpoint mentioned, outside lifecycle |
| [#4467](https://github.com/temporalio/temporal/issues/4467) | User configuration: CASSANDRA_PORT contains Kubernetes URL instead of integer; maintainer gives explicit port workaround; Nexus keyword is a username |
| [#5324](https://github.com/temporalio/temporal/issues/5324) | Cross-namespace support question; maintainer points to Nexus proposal, no bug |
| [#6760](https://github.com/temporalio/temporal/issues/6760) | Backlog observability enhancement for sync-match queries/Nexus; maintainer discussion confirms accounting scope, not lost operation durability |
| [#8269](https://github.com/temporalio/temporal/issues/8269) | Diagnostic log-volume improvement, closed; not lifecycle safety/progress |
| [#8294](https://github.com/temporalio/temporal/issues/8294) | Test depends on DNS; maintainer identifies local resolution failure. Unit-test fragility, not Nexus operation bug |
| [#8608](https://github.com/temporalio/temporal/issues/8608) | Feature: Describe workflow input/output; accidental closure explicitly reversed |
| [#8652](https://github.com/temporalio/temporal/issues/8652) | Backend compatibility/support discussion; contributors identify separate Cassandra/Scylla fixes, but no basis to equate SQLite confirmation with those backends |
| [#9056](https://github.com/temporalio/temporal/issues/9056) | Search-attribute normalization enhancement, not primary operation lifecycle |
| [#11713](https://github.com/temporalio/temporal/pull/11713) | Open SQL optimization: avoids unchanged current-execution updates while retaining row validation; no proposed removal of atomicity guard; no reviews/inline comments |
| [#10549](https://github.com/temporalio/temporal/pull/10549) | Open known cache-size concurrency defect under optional cacheSizeBasedLimit; author repro and maintainer discussion read. Concurrent Update-map sizing is outside bounded Nexus protocol model; no local race reproduction claimed |
| [#11186](https://github.com/temporalio/temporal/pull/11186) | Open known pending-request gauge defects; maintainer confirms idle decrement and Nexus metric-series issue; prefers shared Start/Cancel enforcement bucket. All three inline comments and review read; metrics not durable progress oracle |

Relevant open #11944 (timeout grammar), #11764 (failure-size enforcement), #11312 (canceled failure preservation), #11254/#11921 (Nexus Workflow Update callbacks), and #11967 (passive replication test instrumentation) received full discussion review. Update, standalone, migration, scheduler, auth-policy and multi-cluster patches were not silently adopted into this HSM model. #10716's final comment challenges the claimed external error leak; #10436's reporter corrected the initial TODO-based causal theory; #6931 reviewers explicitly reject a supposed state/token race because the fields change atomically. These corrections are retained as false-positive exclusions, not ignored.

## Phase 3: implementation contracts and atomicity audit

### Identity and state map

| Identity / state | Actual role / source |
|---|---|
| Namespace + WorkflowID + RunID | Routes to one workflow/shard; the primary model pins run and cluster (`handler.go:2137-2184`) |
| ScheduledEventId / node path | Operation node key is decimal scheduled event ID (`events.go:23-29,327-355`) |
| RequestId | UUID generated at schedule, stored in scheduled History and HSM, reused on retries and callback token (`commands.go:53,221-241`; `executors.go:202-218,264`) |
| OperationToken | Remote async operation handle; stored with Started and used for cancellation. May be absent before async response or in synchronous operations; callback identity also uses request/HSM ref, not token alone |
| Operation/cancellation Attempt | Operation Attempt increments on retryable failure or async Started, not on each send or terminal outcome; cancellation Attempt increments on its recorded outcomes. Task payload carries diagnostic attempt. Nexus validators do not compare it for equality (`statemachine.go:91-95,537-540`; `tasks.go:98-103,179-184`) |
| Initial versioned transition | HSM incarnation validation, plus transition-history staleness check; fallback uses initial failover version (`statemachine_environment.go:223-324`) |
| Physical task ID / generation watermark | Queue clock and explicit refresh generation guard; distinct from operation Attempt (`ndc_task_util.go:209-255`) |
| Cancellation state | UNSPECIFIED pending intent until parent starts; Scheduled/BackingOff perform delivery; Succeeded means ACK, Failed means delivery failure, neither means parent operation Canceled (`statemachine.go:423-449,543-674`) |

Custom user Nexus headers can overwrite generated request ID or stored cancellation token on the wire: pinned SDK options explicitly permits SDK-header overwrite, and Temporal only enforces its finite blacklist (`config.go:78-103`, `commands.go:163-180`, `common/nexus/nexusrpc/client.go:273-284`, `handle.go:30-33`). The primary model assumes no protocol-identity header override and traces must verify wire identities independently. This is a policy/boundary observation, not an asserted SDK defect.

### Transaction and recovery boundaries

1. **Workflow command/transition:** AddHistoryEvent and in-memory HSM changes occur under workflow lock. HSM `MachineTransition` counters/data rollback is local; whole-write errors propagate through `Environment.Access` and workflow/cache clearing (`hsm/tree.go:585-634`, `statemachine_environment.go:363-410`, `workflow/context.go:888-902`, `workflow/cache/cache.go:364-405`). Do not treat nested child/history mutations as independently committed.
2. **Outbound operation:** locked argument load, unlocked endpoint call, locked result revalidation/commit (`executors.go:364-480,823-923`). A remote accepted operation can exist while local state remains Scheduled/BackingOff; retry uses stable RequestId, but one external effect requires endpoint dedup/reconnect retention. Synchronous response needs no async handle.
3. **History append:** `common/persistence/sql/execution.go:334-348` appends History before mutable-state transaction. The existence of a raw history row alone is not logical commit. Public History reads obtain mutable-state next-event/version bounds (`service/history/api/getworkflowexecutionhistory/api.go:231-288,413-442`).
4. **SQL commit:** shard RangeID checked within `txExecuteShardLocked` (`sql/execution.go:39-57`); execution NextEventId condition or DBRecordVersion checked (`sql/execution_util.go:629-664`); execution blob/HSM/logical timers, physical tasks and buffered-event changes all occur in the same SQL transaction (`:23-82,155-175`). `sql/common.go:52-80` rolls back function errors and reports commit errors as Unavailable. Do not split these into arbitrary independent durable actions.
5. **Unknown write result:** errors outside the definite-noncommit classes initiate shard reacquisition; new RangeID makes later readback decisive (`shard/context_impl.go:1491-1548`). Task-key completion receives the persistence error before this handling (`:597-655`). `OperationPossiblySucceeded` permits task notification on uncertain results (`common/persistence/error_type.go:5-23`, `workflow/transaction_impl.go:201-213,608-625`). Notification is a wakeup, not successful caller completion.
6. **Local observation:** History/WFT scheduling and callback response follow persistence acknowledgment. Endpoint response receipt is independent. Callback success/terminal metrics generally require Access returning nil, but timeout metrics emit before outer commit (`executors.go:626-639`, `completion.go:195-198,249-255`); neither absence nor count of metrics proves commit/noncommit.
7. **Ordinary reload:** `workflow/context.go:408-498` loads DB record; `mutable_state_impl.go:530-573,662-672` restores existing HSM/logical timer state. It does not invoke all RegenerateTasks. Shard reacquisition/cache eviction is not full History rebuild.
8. **Explicit task refresh:** `workflow/context.go:1382-1405` invokes TaskRefresher; `task_refresher.go:64-72,652-733` advances generation, reconstructs timers, derives and validates eligible tasks, then persists. It repairs B1 in the actual API probe, but does not itself delete B2's terminal node. Event replay has distinct Apply semantics.

SQLite itself uses SELECT-based lock methods without `FOR UPDATE` (`sql/sqlplugin/sqlite/execution.go:28-32`), with its transaction/connection serialization. The inspected common SQL guard/transaction boundary is real, but this phase does not claim to verify backend-specific isolation for other plugins.

### Task eligibility and completion/cancellation compensation

| Durable operation/cancel state | Required eligible tasks when configured |
|---|---|
| Scheduled | Invocation + S2C + S2S |
| BackingOff | Backoff + S2C + S2S |
| Started | S2C + STC; S2S is stale |
| Terminal/deleted | No eligible operation task; raw regenerated timers are filtered by Validate |
| Cancel child UNSPECIFIED | No delivery yet; durable intent waits for Started |
| Cancel child Scheduled / BackingOff | Cancellation outbound / cancellation backoff respectively, subject to parent/Workflow checks |
| Cancel child Succeeded / Failed | No further cancellation task; operation may remain Started |

Sources: `statemachine.go:128-181,543-563`; all task validators in `tasks.go`; generation filtering `workflow/task_generator.go:942-1009`. Logical timer groups are persisted and grouped by deadline; a physical StateMachineTimerTask loads current logical groups, skips stale/deleted/completed refs, removes processed groups and schedules the next wakeup within the enclosing transaction (`workflow/state_machine_timers.go:18-40`, `timer_queue_task_executor_base.go:291-348`). A late physical timer is not an independently replayed old attempt state.

Callback can fabricate Started while Scheduled/BackingOff, then apply terminal result and node deletion in the **same write Access** (`completion.go:126-163,199-237`). Request mismatch is checked by event lookup as well as explicit completion check, so fabrication preceding the explicit comparison is compensated (`events.go:347-355`). Do not manufacture a partial persisted start by splitting the callback transaction. Callback after terminal deletion returns NotFound; duplicate HTTP200 is not the contract.

A buffered terminal event can have already removed the node before the workflow processes its in-flight task. Cancel command checks buffered completion, still records CancelRequested for replay, and tolerates missing-node Apply (`commands.go:259-323`). Deletion compacts away subtree transition tasks (`hsm/tree.go:729-743,785-817`), legitimately subsuming cancellation. Workflow closure disables Nexus tasks/callbacks via CheckRunning even though generic HSM storage can update closed workflows. Neither remote cancel ACK nor workflow closure obliges the remote endpoint to emit a canceled outcome.

Callback acceptance does not check current wall-clock deadline. Timer and callback commits race under the lock; a callback may win even after nominal deadline if timer has not committed. Use terminal-result uniqueness and fair eligible timeout processing, not a stronger hard real-time cutoff.

## Source findings and independent probes

All probe logic is preserved as a Go overlay over the unmodified pinned functional-test file: [fixture](analysis-evidence/nexus_workflow_probe_test.go), [overlay mapping](analysis-evidence/max-timeout-overlay.json), [compact patch](analysis-evidence/probes.patch), [exact commands/results](analysis-evidence/verification-summary.md). Assertions intentionally characterize the observed behavior; PASS means the adverse observation and control were both verified, not that Temporal meets the violated requirement.

### B1: pre-start cancellation omits STC publication

- **Reachability:** schedule an async operation with STC3s and no S2C/run timeout; keep endpoint Start response blocked; real workflow commits cancel request; release async response; endpoint ACKs cancel without sending terminal callback. This is protocol-valid cancellation behavior.
- **Exact cause:** `TransitionStarted` stores token/StartedTime, then `statemachine.go:383-389` returns the child transition instead of reaching parent STC emission398. The generated dirty-task pass consumes outputs, not state-derived required-task inventory (`workflow/task_generator.go:297-335`).
- **Observed final probe:** cancel11 < Started12 < cancel-ACK16. Past deadline, raw SQLite HSM state is Started, configured STC3s, **zero persisted timer groups**, while state-derived RegenerateTasks produces one task. The same DB facts hold after CloseShard. Explicit RefreshWorkflowTasks then yields NexusOperationTimedOut. Final test PASS in5.14s; [log](analysis-evidence/cancel-retention-probes.jsonl).
- **Healthy control:** same endpoint and STC without pre-start cancel reaches StartToClose timeout normally. A later S2C timeout or prompt callback would mask B1; neither was enabled in adverse run. Explicit refresh is demonstrated compensation, ordinary reload is not.
- **Existing-test gap:** `TestCancelationBeforeStarted` has no STC and expects empty parent output; `TestTransitionStartedEmitsStartToCloseTimeout` has no cancel child; functional cancel-before-start test1958-2025 verifies cancel delivery then terminates. Combining these conditions adds evidence absent from either baseline.
- **Classification:** current timeout/progress bug, analyst severity Medium; no assertion of remote data loss, guaranteed infinite runtime observation, or MC-first discovery. Broader backoff, post-start cancel, callback and uncertain-write composition remains pending.

### B2: terminal timeout node consumes pending capacity

- **Reachability:** max concurrent operations1; first operation accepted async and never callbacks; ordinary S2C3s timeout; workflow catches timeout and schedules a second synchronous operation.
- **Exact cause:** `recordOperationTimeout` adds event then directly TransitionTimedOut (`executors.go:645-676`), which emits no cleanup (`statemachine.go:409-420`). Event replay's `TimedOutEventDefinition.Apply` deletes (`events.go:262-272`), but live AddHistoryEvent only updates History/cache/type list (`mutable_state_impl.go:1381-1387`), and transaction close uses type list only for WFT scheduling (`:7928-7954`). No compensating live delete was found.
- **Observed:** actual first endpoint acceptance recorded; NexusOperationTimedOut committed; next WFT fails PendingNexusOperationsLimitExceeded. Describe pending list is empty; raw DB after CloseShard retains one TimedOut node. Final test PASS in3.19s; [log](analysis-evidence/cancel-retention-probes.jsonl).
- **Healthy control:** limit1 permits two sequential sync completions and raw DB has no remaining operation nodes. This isolates capacity reclamation from the legitimacy of the timeout itself.
- **Recovery:** ordinary DB load preserves the retained node. Explicit task refresh filters terminal timers but does not delete it; a History event rebuild would use a different deletion path. Rebuild remediation was source-analyzed, not executed.
- **Historical value:** #7171's full discussion/diff repairs corresponding completed/failed/canceled live paths; timeout remains a current unaudited site. No reverting of that fix was involved. Minimum-request suppression also reaches recordOperationTimeout, but the probe uses ordinary timer execution rather than unusual timeout settings.
- **Classification:** current admission/progress bug, analyst severity Medium. Default30 would require sufficient repeated timeouts; this phase executes the minimal limit1 manifestation, not a30-timeout stress run.

### B3: omitted timeout bypasses configured maximum

- **Reachability:** no WorkflowRunTimeout; max operation S2C3s; schedule with omitted S2C, no secondary timeout. Endpoint returns async token and remains running.
- **Exact cause:** `commands.go:194-204` handles zero only when run timeout is positive, then applies configured max only if `opTimeout > maxTimeout`. Zero therefore bypasses positive max. `config.go:106-111` documents that absent as well as excessive duration should be capped; pinned SDK NexusOperationOptions also documents defaulting to server maximum. Creation/regeneration emits no S2C task for zero (`statemachine.go:140-181`).
- **Observed:** explicit60s control commits3s and times out. Omitted case remains Started past that duration, ScheduleToCloseTimeout0 in public History/Describe and raw DB after CloseShard; token/request identity retained; zero derived tasks. Individual B3 test PASS in3.10s inside [durable-probes log](analysis-evidence/durable-probes.jsonl).
- **Control/failure accounting:** that log's aggregate suite exit is1 because the separate B1 probe initially used a contiguous-History matcher across intervening WFT events. B3 itself passed. Initial B3-only attempt used a shared test cluster and was stopped by the test environment's CloseShard guard; it is preserved in [initial log](analysis-evidence/max-timeout-probe-initial-shared-cluster.jsonl). The dedicated-cluster correction then established reload evidence. These are harness errors, not additional Temporal findings.
- **Classification:** direct configuration-enforcement defect, analyst severity Medium. Keep Test-Verifiable, not an MC target; nil/explicit-zero/run-limit variant matrix remains a bounded follow-up.

### Remaining code-review and test-verifiable observations

Every source-derived observation is retained even when unsuitable for the model. These have source/caller/compensation review but **no independent runtime confirmation in this phase**, unless expressly marked known upstream.

| ID | Observation and exact source | Compensation / current status / next verification |
|---|---|---|
| TV1 | Optional completion StartTime omitted by HTTP client/server stays Go zero; HSM frontend converts it to nonnil timestamp329; fabricator overwrites EventTime at completion.go159-160 | CHASM checks IsZero367-368. Early terminal deletion subsumes operation timers; no spurious timeout demonstrated. Existing early-completion functional test supplies real timestamp. Test supplied/omitted time through HTTP before response and DB/History readback; likely year0001 History/negative latency issue |
| TV2 | Cancel request chooses minimum STC/S2C budget, but always labels S2C when configured (`executors.go:715-749`) | Only child request-failure diagnostic is implicated; own operation timer still has correct type. Test both deadlines; no MC target |
| CR1 | HSM canceled-failure coercion reconstructs failure without Source/EncodedAttributes (`completion.go:90-101`) | Known open [#11312](https://github.com/temporalio/temporal/pull/11312), full review read. Do not claim CHASM's canceled/failed confusion applies to HSM, which repairs canceled marker |
| CR2 | Failure/cancel callback skips success-payload namespace size check (`service/frontend/nexus_completion_http_handler.go:214-229`) | Transport MaxBytesReader remains; known open [#11764](https://github.com/temporalio/temporal/pull/11764). Need actual lower namespace-limit scenario and SDK error preservation; not novel/MC |
| CR3 | Callback token/nested failure JSON decoding can produce nil pointer; nested HSM initial-reference presence is not fully checked (`common/nexus/callback_token.go:72-91,118-124`; `common/nexus/failure.go:211-219`) | Generated valid tokens populate fields; request-level recovery/host containment limits require confirmation. No malformed-input probe, no process-crash or durable-corruption claim. Retain as parsing/validation review |
| CR4 | Bare Nexus failure without metadata/details can remain without FailureInfo (`common/nexus/failure.go:193-275`) | Canceled path has explicit coercion; failed SDK behavior not locally reproduced. Keep separate from known metadata-loss fact |
| CR5 | Caller-provided reserved identity headers overwrite generated wire fields | SDK documents overwrite. Require protocol-conforming inputs for primary model, observe actual wire IDs; Temporal-level policy review rather than asserted SDK bug |
| CR6 | Timeout metrics can emit before commit; successful result metrics require nil return | Best-effort metrics, no commit oracle; not durable inconsistency. Historical metrics PRs are not model targets |
| CR7 | Request-timeout formatting in Matching (`service/matching/matching_engine.go:2823,2825`) | Known [issue #11569](https://github.com/temporalio/temporal/issues/11569), open Draft [#11944](https://github.com/temporalio/temporal/pull/11944); do not claim novelty or general dispatch-after-deadline failure from formatting alone |
| CR8 | Optional cache-size limit may read Update registry after workflow unlock; pending-request gauges can lag | Known #10549/#11186; separate Go concurrency/metrics scope. No Nexus protocol defect inferred |

### Explicitly rejected or bounded suspicions

- A cancel ACK without operation Canceled is permitted: child request succeeded and operation result differ.
- Duplicate callback NotFound after terminal deletion is permitted; only durable outcome immutability is required.
- Callback fabricating Started before explicit RequestId comparison is compensated by event request-ID check and enclosing write rollback/cache clear.
- Serialized Attempt is not a stale-task fence; current-state eligible duplicate sends may repeat, requiring endpoint idempotency assumptions.
- Raw RegenerateTasks producing timers for a terminal node is filtered by generation-time Validate; it does not revive the operation.
- Raw History append and task notification on uncertain return do not independently prove a committed operation outcome.
- Missing outcome metric does not prove a missing commit; pre-commit metrics do not prove success.
- An operation after workflow closure is not guaranteed further progress; CheckRunning rejects it. B2 instead concerns a still-open workflow.
- Endpoint deletion/recreation name fallback, Reset current-run retry, CHASM migration and XDC validation limitations are outside primary scope.
- Existing unit fakeEnv calls a node accessor directly; passing those tests is not persistence/reference-validation evidence.

## Execution record and remaining verification work

| Executed check | Result | What the denominator means / limitation |
|---|---|---|
| HSM operation/workflow unit packages, `-tags test_dep -count=1` | PASS,153 named test/subtest pass records across2 packages | Includes nested tests; not153 unique scenarios or implementation coverage |
| Selected HSM workflow functional tests, SQLite | PASS,9 selected test methods +1 suite record,10.361s | Sync completion, async completion/early completion, HTTP pre-handler failure, prestart cancel delivery, S2C/S2S/STC, callback after caller closure |
| Nexus API Start/Cancel outcome methods with Temporal failures, SQLite | PASS,28 named test/subtest/suite records,2.205s | Protocol/API outcome matrix; does not independently validate outbound commit/recovery |
| B3 max-timeout characterization | Individual PASS3.10s | Real DB reload; enclosing two-probe run failed only due initial B1 History matcher; disclosed above |
| B1/B2 corrected characterization | Both PASS5.14s/3.19s; package PASS8.373s | Actual controlled ordering, raw DB readback after shard close, explicit B1 refresh control, B2 next-command failure |
| TLC / trace validation / persistence faults | **NOT RUN in Code Analysis** | No state/action coverage, no MC contribution measured yet, no ExecuteAndTimeout result |

Exact commands, status extraction and important observation records are in [verification-summary.md](analysis-evidence/verification-summary.md); raw JSONL logs retain cluster config and test output. All checks used `-tags test_dep`. Test-only overlay was gofmt'd; no production patch was made, so no production lint/change CI verdict is implied.

### Priority-question handoff matrix

| User question | Checked paths / evidence | Current result | Remaining executable question |
|---|---|---|---|
| Q1 early/late/duplicate completion, timeout/cancel overlap, identities | Commands→unlocked start→History callback→HSM Access→event deletion; early/duplicate functional tests; B1 ordering | Positive current callback safeguards; B1 exposes separate cancel/STC publication hole | Accepted response loss plus callback before local commit; both write outcomes; buffered WFT and timer/callback winner combinations |
| Q2 accepted start with lost response/noncommitted save; reconnect identity | Persistent RequestId through all start loads/sends and callbacks; remote token written with Started; error/retry classification and SQL uncertainty | Source-supported stable identity under no user override; remote one-effect guarantee conditional on endpoint mapping | Pre-handler failure test is **not** accepted-response-loss evidence. Inject post-handler response loss; record endpoint acceptance/dedup/token and readback after uncertain local write |
| Q3 deferred cancellation, ACK vs canceled, terminal subsumption | All operation/cancel states, child transitions, cancellation executors, event trigger flags, B1 | ACK semantics correct; B1 missing STC reproduced; terminal callback can legitimately subsume child | Prestart backoff variant, post-start-cancel control, retryable/nonretryable cancel errors combined with commit uncertainty and completion |
| Q4 delayed tasks, deadlines, cache/shard recovery, regeneration | Complete tasks/ref callers, generation watermark, logical timer executor, load vs refresh; B1/B3 DB evidence | B1 persists through ordinary reload; explicit refresh repaired it in the probe; B3's absent duration persists; task Attempt not fence | Delayed eligible retry sends with same identity; STC/S2C ordering and refreshed watermark; real queued-task inventory/negative controls |
| Q5 HSM/History/buffer/tasks/publication/uncertain write/closure/deletion | SQL transaction/conditional guards, possible-commit error and reacquisition, visible History bounds, buffered cancel compensation, B2, caller-closed functional test | B2 live timeout/reload diverges from deletion-on-replay; source establishes safe atomic grouping to preserve in model | ExecuteAndTimeout versus definite noncommit at start/callback/cancel/timeout; post-reacquisition observations; in-flight WFT buffered history consistency |

### Concrete next-phase observation and fault plan

1. **Retain B1/B2 schedules and healthy controls** as reproducible source-discovery evidence. Derive transition and task actions from current code, not fixes or an idealized state machine. A model that unconditionally regenerates tasks on reload or deletes every terminal node will hide the two findings.
2. **Record endpoint evidence independently:** each received start/cancel RequestId/token, acceptance mapping, response construction/drop, completion callback send/result. Record whether every endpoint handler response was observed. HSM Attempt/History alone omits real outbound sends.
3. **Record local commit evidence:** intended mutation, store operation/request identity, definitely failed vs may-commit result, actual DB readback/version/RangeID after reacquisition, logical timer groups and physical outbound/timer records, HSM/cancel state, committed/buffered history and caller response.
4. **Use deterministic hooks:** `TestEnv.InjectHTTPResponseFault` (`tests/testcore/test_env.go:522-536`) for accepted-start response loss; pre-handler hook separately; `WithPersistenceFaultInjection` plus request-targeted store injector for UpdateWorkflowExecution. `faultinjection/fault.go:42-47,61-71` ExecuteAndTimeout first requires underlying store success then returns Timeout; definite Timeout injection skips underlying write. Retain firing counters and exact request match; no matching fault means an invalid experiment, not successful coverage.
5. **Read back after cache/shard repair:** `CloseShard` requires dedicated test cluster (`test_env.go:693-704`). Ordinary reload, explicit RefreshWorkflowTasks and History rebuild must have distinct trace actions. A fake HSM environment cannot establish these facts.
6. **Negative trace controls:** alter request identity, delete an independently observed persisted logical timer from the trace, falsely label a known noncommit as committed, or omit a recorded accepted endpoint attempt. Trace validation must reject mismatches or mark observation incompleteness explicitly; no silent state filling from expected model. The authentic B1 trace with no published timer must remain valid implementation evidence, then violate RequiredTimerPublished; trace validity and invariant satisfaction are distinct.
7. **Bounded exploration:** one operation, two send attempts/two callbacks, one cancel, three deadline enablement choices, one reload/refresh; separate two-sequential-operation capacity1 run. Then justified compositions with uncertain writes/WFT buffering. Track all state variables in the temporal envelope. Diagnose growth, narrow deliberately, preserve unfinished work as INCOMPLETE; independent checks do not prove full cross-product.

The formal contribution remains an executable question: whether exploration finds additional failure interactions or confirms/refutes these source-derived mechanisms under an implementation-validated abstraction. Current source review plus focused tests already adds three observations beyond the selected upstream tests. Replaying them in TLC later is reconfirmation; neither an incomplete search nor passing baseline tests establish system correctness.
