# temporal-activity: Code Analysis audit

Source revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.
Repository: `/home/ubuntu/temporal-investigation-20260909/parallel-20260910/source-activity`.
Analysis date: 2026-09-10 UTC. Source paths below are relative to that repository.
Primary handoff: [modeling-brief.md](modeling-brief.md).

**Result:** implementation-grounded Code Analysis completed; no new ordinary-Activity protocol bug confirmed. Both existing Activity functional suites passed, with **14 leaf test methods**. Complete state/transaction traces, recovery validation and TLA+ bounded verification were not performed in this assigned phase and remain **INCOMPLETE**. Source-supported questions and known open proposals are not counted as discoveries.

## 0. Methodology, category, and evidence identity

The explicitly invoked skill was `/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/Specula/skills/code_analysis/SKILL.md`. Read its complete `guide.md`, shared deep-analysis reference, Category A distributed-analysis reference, bug-archaeology reference, modeling-brief format and the supplied hashicorp-raft example. The target is **Category A (Distributed / Message-Passing)**: a local Workflow lock does not make worker RPC delivery, timer/transfer execution, persistence and ownership changes atomic. Category B lock-free/memory-ordering methodology and the BFT overlay do not apply.

The user authorized all four Code Analysis phases and the two local deliverables. Three parallel reviewers verified issue batches and commit batches, then performed full core-source reads. The primary reviewer followed persistence and observations and ran existing functional tests. A fourth subagent independently audited the handoff while synthesis continued. At most three child agents ran simultaneously, matching the available concurrency slots. No source code was modified and no GitHub comments, issues, PRs or other external writes were made.

The source checkout was clean and exactly pinned; its repository is not shallow. `analysis-evidence/source-identity.json` records initial identity and core line counts; `input-hashes.json` fingerprints source/configuration inputs. History and discussion evidence were fetched live, not accepted from prior investigation conclusions. Prior memory supplied only general Temporal modeling/claim boundaries, subsequently rechecked against source.

### Evidence inventory

| Artifact | Contents |
|---|---|
| `analysis-evidence/commands-methodology.txt` | Search, ancestry, discussion, source-reading and runtime command methods |
| `source-identity.json`, `input-hashes.json`, `runtime-environment.json` | Revision, checkout status, core scale, test input hashes and safe environment-path whitelist |
| `core-files.txt`, `commits-all-core.tsv`, `commits-follow.tsv`, `commits-inventory.tsv` | Declared core and reproducible keyword/rename-following candidate universe |
| `commits/`, `commits-review-{0,1,2}.tsv`, corresponding `.md` files | Archived patches; every SHA's scope, mechanism/exclusion, component, historical severity and ancestry |
| `issues-collected.json`, search JSON files, `issues/` | Multi-query issue inventory, bodies, full comments, linked evidence and counts |
| `issues-identity.md`, `issues-timeouts.md`, `issues-cancel.md` | Per-issue judgments and explicit exclusions; these are part of this audit trail |
| `open-pr-inventory.json`, `open-pr-candidates.json`, `open-pr-files/`, `open-pr-scope-review.tsv` | All open PRs and every repair candidate's file-scope screen |
| `prs/` and `issues/pr-*.json` / linked-PR files | Deeply read PR bodies, conversations, reviews/inline comments and relevant patches |
| `deep-apis-dispatch.md`, `deep-timers.md`, `deep-mutable-state.md`, `deep-persistence-observation.md` | Detailed source contracts, compensating paths, observation requirements and pending findings |
| Source read ledgers and developer-signal files | Full versus partial file coverage, TODO/FIXME/error-path investigation |
| `functional-command.json`, `functional-activity.jsonl`, `functional-exit.json`, `functional-summary.json` | Exact existing-test execution, full logs, exit code and method-level results |
| `handoff-audit.md` | Independent source/deliverable cross-check and corrections |

## 1. Reconnaissance

### Scope and structural map

One ordinary Activity belongs to a fixed Workflow Run in one cluster. Cover scheduling/start, attempt identity, completion/failure, retry, all four timeouts, heartbeat, cancellation, persistence, reload and Workflow result-consumption responsibility. The model's identifier is `(namespace, WorkflowID, RunID, ScheduledEventID)`; ActivityID is only unique among currently pending Activities and may be reused after deletion (`service/history/workflow/mutable_state_impl.go:4316-4323,4348-4369,2228-2258`). Start with one Activity, then add a second to exercise shared timer ordering.

| Layer | Core/interface source | Concurrency and authority |
|---|---|---|
| Worker-facing normalization | `service/frontend/workflow_handler.go` Activity methods | Deserialize issued token, normalize/reject payloads, invoke History, deliver response later |
| Activity RPC acceptance | Six `service/history/api/` Activity files and `activity_util.go` | Under Workflow lease: run/pending/start/attempt/version checks and Activity mutation |
| Mutable State | `service/history/workflow/mutable_state_impl.go`, `activity.go` | Cached aliases and a proposed transaction; persisted ActivityInfo is authoritative between History events |
| Work generation | `task_generator.go`, `timer_sequence.go` | Add generated tasks and timer masks to the mutation; earliest logical timer may cover many Activities |
| Asynchronous execution | Active timer and transfer executors | Timer/transfer workers acquire Workflow lease; release before Matching callback; retry on classified errors |
| Matching interface | `matching_engine.go`, partition manager and task writer interfaces | Add returns after sync-start success or awaited durable spool; worker poll response can still be lost |
| Execution persistence | Workflow context/transaction, shard context, execution manager, SQL store | History append precedes atomic execution/maps/buffer/task transaction; ownership and workflow revision checked |
| Observation | DescribeMutableState, task recorder, API payloads and task store | Different projections and times; none alone is a complete durable-execution trace |

The 13 declared core files total **18,490 physical lines**, including 10,101 lines of shared MutableState logic; this is not 18,490 Activity-only LOC. All 13 were read completely across the reviewers. Supporting interfaces, tests and SQL transaction code were read in full where listed in the ledgers; other referenced supporting functions were read selectively. This is not a full audit of every Temporal subsystem or backend.

### Actual baseline backend and settings

The existing functional execution used **Go 1.27.0 linux/amd64**, `CGO_ENABLED=0`, `GOMAXPROCS=6`, and build tags `disable_grpc_modules,test_dep`, consistent with the repository Makefile/test instructions. Explicit arguments selected SQL/SQLite. Shared test clusters use file-backed SQLite in temporary test paths with `journal_mode=wal`, `synchronous=normal`, `cache=shared`, `busy_timeout=30000`, and SQLite v3 schemas (`tests/testcore/functional_test_base.go:363-368`; `common/persistence/persistence-tests/setup.go:108-126`). The test log records created database paths under `parallel-20260910/scratch/activity/tmp` and emitted configuration. Test cleanup is not a persistence-recovery experiment; no enduring database snapshot was captured.

Functional tests use defaults from `common/dynamicconfig/constants.go` plus `tests/testcore/dynamic_config_overrides.go`, not an external dynamic-config file. Relevant pinned defaults are:

| Setting/condition | Actual source/test selection | Modeling consequence |
|---|---|---|
| `system.enableActivityRetryStampIncrement` | false; constants.go:239-243; no override in executed suites | Model false first, true separately. Do not import proposed removal in open #11716 |
| `system.enableCancelActivityWorkerCommand` | false; constants.go:208-212 | Ordinary baseline uses heartbeat observation; enabled worker-control push is separate |
| `system.enableActivityEagerExecution` | true; constants.go:203-207 | Actual request matters: schedule-to-close tests disable eager at activity_test.go:83,152; raw scheduling commands omit eager; other SDK tests may use it |
| Namespace/run | Tests register local namespaces and fixed runs | Nonzero global namespace versions were not functionally exercised; version compatibility still belongs in the source model |
| Retry options | Different per-test policies, including nil policy, finite limits and unlimited count | Preserve normalized ActivityInfo policy and effective deadlines, not one assumed default policy |
| Fault injection | Not enabled in the executed baseline | No injected commit loss/recovery result is claimed |
| Pause/rules/routing/time skipping | No Activity administration, workflow pause/rules or time-skipping calls in selected ordinary suites | Explicitly freeze these in the later model/harness rather than let hidden configuration alter successors |

The model should explicitly request non-eager execution for its first complete traces. The existing suite's passing eager/non-eager mixture is source/test evidence only, not validation of the proposed non-eager model. SQLite NORMAL/WAL without any restart test does not establish database/power-loss durability; PostgreSQL/Cassandra paths require their own execution evidence.

### Atomicity map

1. A priority semaphore of capacity one protects a local Workflow context (`workflow/context.go:143-164`). Handlers and timer logic mutate aliases while that lease is held. No arbitrary concurrent mutation of one ActivityInfo is allowed inside a leased action.
2. Dispatch captures request fields under lease and releases it before calling Matching (`transfer_queue_active_task_executor.go:234-286`; `timer_queue_active_task_executor.go:611-636`). History's accepted-start mutation is a later transaction.
3. `CloseTransactionAsMutation` assembles Activity updates/deletions, durable buffered events, execution metadata, condition/version and generated tasks (`mutable_state_impl.go:7607-7650`). Its cleanup and in-memory version advance occur before storage; those assignments are not proof of commit.
4. SQL appends raw History nodes first (`common/persistence/sql/execution.go:334-348`), then commits execution metadata, task insertion, ActivityInfo and buffered-event updates together (`execution_util.go:23-190`). Model a crash between these stages, not between independently committed Activity row/task row updates that the backend does not expose.
5. SQL takes shard ownership and concrete execution locks/conditions. `RangeID` and expected `DBRecordVersion` are independent fences; version zero uses legacy NextEventID condition (`sql/shard.go:152-176`; `execution_util.go:629-695`). An unqualified unconditional UPDATE after a lock is not evidence of missing optimistic concurrency; open #11714 preserves this contract while optimizing it.
6. A possibly successful error triggers shard reacquisition and task wakeups (`shard/context_impl.go:1501-1549`; `workflow/transaction_impl.go:184-214`). Cache reload reads persisted state; it does not restore the old tentative pointer. Notification, worker response and obsolete-task acknowledgement/deletion occur later.

## 2. Bug archaeology

### Coverage and counting discipline

| Search/review stage | Exact coverage | What the number means |
|---|---:|---|
| Current-path core keyword search over all local refs | 373 commits | Candidate commits matching fix/bug/race/panic/deadlock/correctness/crash/corrupt/leak/inconsistent/wrong/safety |
| Union after individual file rename-following histories | **394 commits** | All received scope classification and pinned-ancestry verification; no candidate sampling |
| Relevant classifications within 394 | 30 Activity core, 24 shared persistence/representation, 9 extensions | 63 relevant history entries, including features/refactors/hardening; not 63 confirmed bugs |
| Explicitly excluded within 394 | **331** | Other protocols, routing, replication, CHASM/Nexus, telemetry, bulk migration, etc.; per-SHA reasons retained |
| Additional topic-driven historical stamp PRs | 2 | #8536 and #8607 fully read; their merge diffs/ancestry separately recorded, not added to keyword-fix denominator |
| Issues collected across 9 searches | **300 unique** | Includes irrelevant features and supporting subsystem reports, not 300 bugs |
| Assigned issues deeply read | **30**, with **71 comments** | Entire bodies and comments verified; 270 remaining inventory issues were not silently counted as deeply read |
| Deep issue classifications | 9 confirmed historical mechanisms; 12 design/contract; 7 uncertain; 1 false narrative; 1 user error | Confirmed category includes an SDK defect and a narrower cleanup mechanism; none is a new current-core discovery |
| Open PR inventory | **372** | Complete `gh pr list --state open --limit 1000` snapshot |
| Repair keyword candidates | **215** | Title/body after stripping HTML template comments; all file scopes screened |
| In-scope/supporting open PR discussions deeply read | **17** | 16 primary-reader PRs plus #11727 by timeout reviewer; excluded scopes were not misreported as full discussion reads |

Searches combined `activity`, `heartbeat`, `activity timeout`, `activity retry`, `activity cancel`, `activity persistence`, `activity crash`, `activity label:bug`, and `activity label:"bug report"`. Empty label-filter results were retained. `gh issue view --comments` does not alone supply issue bodies; reviewers separately fetched/read body JSON and paginated comments. Counts and full evidence are in the issue-specific reports.

Every candidate commit's changed-file/hunk scope was reviewed. Significant in-scope diffs were read completely; reviewers expanded full commit diffs when modern-path filtering hid the substantive fix. Large generated proto/enum/source migrations were classified in scope, not called tens of thousands of deeply audited protocol-fix lines. All 394 candidates are ancestors of the target revision. Historical severity in ledgers describes the old mechanism if exercised, not a reproduced present defect.

Relevant-history hotspots (commits can touch multiple files): MutableState 38, Activity helpers 14, active timer executor 12, timer sequence 10, Workflow context 8, task generator 6. `commit-hotspots.json` preserves the full mapping. These are relevant-entry counts, not independent bug counts.

### All 30 deeply read issues

Detailed root cause, linked fix status, complete discussion evidence and exact source anchors are in [identity issues](analysis-evidence/issues-identity.md), [timeout issues](analysis-evidence/issues-timeouts.md), and [cancellation issues](analysis-evidence/issues-cancel.md).

| Issue | Classification | Disposition for this model |
|---|---|---|
| #11733 | Uncertain/code-supported open delivery concern | Child deadline can leave accepted start undelivered; #11734 already proposes recovery; timeout compensates, no permanent loss proof |
| #10320 | Uncertain/disputed explanation | Maintainer disputes claimed Matching deadlock; do not adopt narrative as confirmed root cause |
| #9118 | False/withdrawn root-cause narrative | Reporter withdrew generated atomicity explanation and resolved timeout settings; exclude claimed split commit bug |
| #459 | Uncertain historical matching loss | Limited public evidence; queue internals excluded, no present loss claim |
| #1897 | Design/contract | Duplicate terminal RPC success is not promised; effect idempotency differs from replaying acknowledgement |
| #2538 | Confirmed historical error-code bug | Fix present; reference only, not current terminal-safety issue |
| #5877 | Design/ByID distinction | Force completion and failure while retrying differ; do not impose token-attempt contract on ByID |
| #987 | Design/feature implemented | ByID can complete pending retry work; source fabricates Started when needed |
| #4799 | Design/identity context | Saved token can become stale after retry; ActivityID identifies broader pending work |
| #8376 | Uncertain/disputed heartbeat symptom | Closure says test issue; later disagreement remains; not a confirmed server heartbeat-loss claim |
| #11721 | Design/policy normalization limitation | Explicit zero versus default MaximumAttempts ambiguity; open #11727 proposes change, no durable-safety verdict |
| #7515 | Uncertain retry-interval report | Worker timestamps alone lack delivery/commit provenance; no confirmed reproduction |
| #3667 | Confirmed historical retry-disposition bug | Fixed; timeout type and retry-state enum are separate observations |
| #5914 | Confirmed historical failure-message mismatch | Fixed; preserve current reason/cause semantics, no pre-fix target |
| #1675 | Confirmed historical subsecond retry bug | Fixed retry arithmetic; local testing, not new protocol hunt |
| #1139 | Confirmed historical retry deadline bug | Fixed worker-facing deadline update; current source controls |
| #185 | Design/timeout policy context | Feature/design history; no present wrong-attempt claim |
| #290 | Design/timeouts redesign | Contract background, not a current defect |
| #2443 | Design/heartbeat-on-failure feature | Final heartbeat and failure share mutation; size handling must follow actual implementation |
| #2496 | Design/custom timeout retry feature | Current timeout exclusions belong in effective policy |
| #5316 | User error/contract misunderstanding | No heartbeat means cancellation need not reach worker promptly |
| #4673 | Confirmed SDK bug | SDK command-count fix; not a Temporal Server fix/reproduction at this pin |
| #4049 | Confirmed historical server cancellation bug | Fix `ed47a167a262` present; buffered-command interaction is reference only |
| #5135 | Design/cancellation latency request | Current code has optional worker-control push, default disabled; not universally heartbeat-only |
| #3358 | Confirmed historical observation bug | Fix `c6fb6b833159` present; no fabricated received heartbeat at start |
| #4781 | Design/expected two transitions | Maintainer accepts heartbeat update plus later timer regeneration write |
| #6689 | Confirmed narrower historical cleanup mechanism | Linked forum confirms abandoned-activity rows; reporter's own cause remains uncertain; present SQL cleanup inspected, no false fixing-PR attribution |
| #7593 | Uncertain closed report | No reproducible server cause; lack of worker-body execution differs from History accepted start |
| #10354 | Uncertain defect / observable design limitation | Intermediate retry failure can be absent from History on backoff cancellation; inspect ActivityInfo instead |
| #1468 | Design/transient Started representation | Nonnil retry policy still defers Started even with maximumAttempts=1 |

The 1 false and 1 user-error classifications are explicit exclusions, not a label applied to all unconfirmed or out-of-scope issues. One additional linked SDK issue and its fix discussion, plus all 8 posts of the #6689 community thread, were deeply read separately and are not included in the 30-issue denominator.

### Significant historical mechanisms and containment

| Commit | Root cause / current lesson | Use |
|---|---|---|
| `9002e943b069` | Eager start lacked the shared StartedClock assignment | Unify semantic identity observations; fixed reference |
| `fc70bd97f500` | Retry moved the ScheduleToClose anchor | FirstScheduledTime and legacy fallback; fixed reference |
| `3491846fe3cc` | XOR could set missing timer-created bits instead of clearing them | Timer-mask work coverage; fixed reference |
| `11e54a1b9ae6` | Deleting heartbeat timer on receipt removed necessary regeneration cue | Keep old cue until it re-evaluates latest deadline; fixed reference |
| `0ded458f7397`, `a5ea2aae30bc`, `8c64263019cb` | Timeout retry-state/type/message corrections | Preserve distinct current timeout path contract; fixed references |
| `a5b3c01ff544`, `331573389177` | Wall-clock rollback and millisecond persistence precision | Model selected clock domain and delayed execution correctly |
| `7708a7c93de1`, `1b482d5b4de1` | NextRetryDelay maximum override and subsecond arithmetic | Explicit override is not capped by ordinary MaximumInterval |
| `c3ac870f774a`, `4c940aa7edcf` | Request/ActivityInfo aliases used across lease or stale task-generation state | Copy handoff fields under lock, then revalidate at History |
| `673d5636b491`, `598aa479cf99` | Dirty cached state could survive transaction boundaries | Clear/check cache; do not mistake IsDirty for commit oracle |
| `c6fb6b833159` | Started time exposed as received heartbeat time | Independent observation schema |
| `abeeabd4a4c0`, `16be798b4afa` | Pause timer regeneration and paused attempt progression | Deferred administrative context only |

Closed fixes remain in Scenario evidence and reference pointers. No proposed adversary removes guards, restores an old timer mask, drops an atomic SQL statement, or recreates a pre-fix state. The stamp-disabled old-delivery question was explicitly checked against the complete #8536/#8607 reviews and kept out of new MC findings: it is the already-known rollout mechanism under an intentionally retained gate.

### Open PR verification

All 372 titles/bodies were collected; all 215 repair candidates were checked for changed-file scope. The 17 deeply read open discussions were #11734, #11714, #11713, #11660, #10549, #10050, #11214, #11716, #11992, #11397, #11403, #10238, #9332, #10317, #11644, #11804, and #11727. Their exact heads are retained in the inventory and PR evidence; their code is **not** assumed present in the target tree.

Material conclusions:

- **#11734:** same-request start response omits heartbeat/policy/type/namespace metadata at this pin; zero Version/StartVersion skip compatibility checks, so an automatic completion-rejection claim would be false. Known open code/test finding, not new MC discovery.
- **#11714/#11713:** SQL conditional-update/current-row optimization proposals preserve existing locked conditions. They do not establish missing atomicity in current Activity/task persistence.
- **#11660:** cached precommit event entries can outlive shard recreation; source-backed known open cache-lifetime concern. Keep source cache versus independent durable readback distinct.
- **#10549:** cache-size access after unlocking can race Update registry maps when size-based limits are enabled. A real race-test/code-review topic, outside the initial ordinary Activity protocol model and default disabled.
- **#10050:** maintainer review disputes practical retry effect without a configured driver retry policy. Do not claim adding idempotence flags alone makes all Cassandra writes safely retriable.
- **#11214/#11727:** retry-policy administrative update and zero/default normalization contracts; separate test work from ordinary durable lifecycle.
- **#11716:** proposed gate removal cannot replace actual pinned false default.
- **#11992/#11397:** arithmetic/architecture-specific backoff and unused jitter behavior; no new Activity protocol hunt.
- **#11403:** parked DLQ dispatch is outside fair healthy queue progress; the control-plane routing policy itself is excluded.
- **#10238:** inline review identifies spooling behavior changes not justified by the description's metrics-only claim. A title/body-only reading would miss this objection.
- **#9332/#10317/#11644/#11804:** transient-history visibility, search attributes, aggregate resource limits and user-timer performance respectively; none is an oracle for actual Activity start/commit, and unrelated feature implementations are excluded.

### Reference comparison

“Durable Activity execution” does not designate a supplied consensus paper or existing formal reference spec. Compared the official [Activity execution contract](https://docs.temporal.io/activity-execution) and [failure-detection documentation](https://docs.temporal.io/encyclopedia/detecting-activity-failures) with the pinned implementation. Activities may repeat effects, task loss is resolved through applicable timeout/retry, cancellation is cooperative, and task-token versus ByID identity differs. The implementation additionally compresses retry History, uses shared timer cues, and commits generated work with Mutable State. The pinned code, not current documentation for newly added CHASM/administrative features, is the modeling authority. No cross-implementation equivalence or novelty claim was made.

## 3. Deep analysis and answers to the priority questions

### 3.1 Earlier-attempt messages

The four ordinary completion/failure/heartbeat/canceled APIs share `api.IsActivityTaskNotFoundForToken` (`service/history/api/activity_util.go:58-80`). Under the lease they require pending ActivityInfo, a started marker and exact Attempt for nonempty ScheduledEventID. StartVersion equality is used only when both sides supply it; otherwise nonzero legacy token Version is checked. A zero version is unspecified/compatible. Ordinary Activity tokens contain neither StartedTime nor StartedEventId (`common/tasktoken/token.go:33-60`); do not borrow Workflow Task token guards.

Retry advances Attempt and clears started state; old worker messages therefore fail before mutation during backoff or the next running attempt. Terminal application deletes ActivityInfo and its pending ActivityId index; duplicate terminal RPC returns NotFound rather than reapplying. This allows only one durable outcome for that scheduled identity, while an ActivityID reused later has a different scheduled identity (`mutable_state_impl.go:4603-4950,2228-2258`). These are source-established protections, not model-checked results.

Task stamp belongs to server dispatch. Transfer/retry validate under lease, then Matching sends a later start callback. History checks current pending state, same-RequestId idempotency versus TaskAlreadyStarted and fresh-start stamp. Matching carries stamp but no attempt. The earlier attempt check at producer cannot be collapsed into a receiver check that does not exist. Under default-false stamp increments, delayed old dispatch can meet a later unstarted attempt without a not-before-ScheduledTime check; exact execution order remains a targeted test question and the historical gated mechanism is not promoted to new MC work.

Matching Add success awaits either sync start or task-writer persistence (`matching_engine.go:646-693`; `task_queue_partition_manager.go:607-673`; `task_writer.go:85-174`). Accepted start still differs from worker receipt. A start can commit while the shorter Matching child deadline expires; later different request ID is already started, leaving timeout/retry as recovery. The known open duplicate-start branch can omit prior heartbeat details; compare the recovered poll payload with independent persisted ActivityInfo.

### 3.2 Timeout, heartbeat, retry and delivery overlap

| Timeout | Logical deadline | Current resolution |
|---|---|---|
| ScheduleToStart | Current `ScheduledTime + ScheduleToStartTimeout`, only while unstarted | Terminal, not a retry of queue waiting; during backoff ScheduledTime is future eligibility |
| StartToClose | `StartedTime + StartToCloseTimeout`, only while started | Retry when policy permits; includes transient Started marker |
| ScheduleToClose | `FirstScheduledTime + ScheduleToCloseTimeout`, fallback ScheduledTime for old records | Whole-Activity deadline spanning attempts/backoff |
| Heartbeat | `max(StartedTime, LastHeartbeatUpdateTime) + HeartbeatTimeout`, only while started | Retry policy applies; received heartbeat details retained |

Sources: `workflow/timer_sequence.go:295-443`; `mutable_state_impl.go:6880-6975`; `common/retrypolicy/retry_policy.go:24-63`. RetryState additionally depends on policy presence and cancellation, whose checks precede timeout classification. Explicit application NextRetryDelay overrides MaximumInterval; the next start must not be strictly after retry expiration, but a whole attempt need not fit. Equality with expiration is representable (`workflow/retry.go:69-111`). Timer-driven inability to fit retry becomes ScheduleToClose timeout for compatibility, while failed RPC remains Failed (`timer_queue_active_task_executor.go:315-324`).

Physical timeout tasks are wakeup cues. Only the earliest deadline receives a new cue when uncovered; executing one cue snapshots and sorts **all** current Activity deadlines, processes expired entries and persists their effects in one Workflow mutation. It does not blindly act on the cue's attempt/stamp. A retry during that scan causes remaining old-attempt snapshot entries to be skipped; deletion causes later entries for that Activity to be skipped (`timer_queue_active_task_executor.go:230-305`). Preserve actual deadline/EventID/timeout-type tie order and millisecond comparison (`timer_sequence.go:477-510`; `queues/queue_scheduled.go:280-301`).

Heartbeat updates move a logical deadline while the old physical cue stays necessary. That cue clears its created bit only if it reaches the current dedup watermark, then creates needed successor work. Retry preserves the ScheduleToClose bit; rejecting old-stamp timeout cues would invent a lost-global-timer bug. On reload the heartbeat watermark is reconstructed conservatively as year 2000 from the persisted created bit; it is not durable and need not equal its pre-reload value (`mutable_state_impl.go:475-481`). Duplicates may produce extra maintenance work without extra terminal outcomes.

### 3.3 Rejected writes, lost responses and recovery

| Observation/fault | Durable meaning | Required subsequent observation |
|---|---|---|
| Concrete backend attempt rejects execution condition/ownership or is skipped before execution | That backend attempt did not commit its execution/task transaction; prior raw History or an earlier internally retried attempt may have committed | Establish the whole logical request outcome independently; do not infer old state solely from its final returned error |
| `Timeout` injected before execution | This injector skipped operation; caller error alone looks uncertain | Record injection outcome and reload old durable state; do not generalize all production timeouts as skipped writes |
| `ExecuteAndTimeout` | Underlying operation succeeded, then injected Timeout is returned | Commit receipt below wrapper or fenced execution/task readback |
| Real commit error / caller response loss | Commit may already have happened | Complete ownership fencing as needed, then independently establish durable outcome |
| Cache clear/reload | Volatile mutable state discarded, database retained | Read ActivityInfo, buffer, condition/version; allow watermark reconstruction |
| Shard reacquisition | New ownership fence resolves possible late prior write | Record old/new RangeID and actual reload; not equivalent to process restart |
| Process/database restart | Distinct failure experiment with backend-specific durability | Not performed; do not infer from test setup, cache clear or CloseShard |

Storage response classification, retry layers and task notifications are detailed in [persistence review](analysis-evidence/deep-persistence-observation.md) and [independent audit](analysis-evidence/handoff-audit.md). Shard context detaches write context from cancellation with a minimum timeout, so the request can outlive its caller (`shard/context_impl.go:2414-2435`). Surfaced unknown write outcomes trigger reacquisition to fence late writes before reliable readback (`1501-1549`). Success of a bounded valid result operation follows persistence; losing its response can make retry return NotFound while the earlier result remains durably committed. The persistence retry wrapper can repeat the same logical request before returning (`common/persistence/persistence_retryable_clients.go:252-264`): SQL Commit error maps to Unavailable (`sql/common.go:77-78`), which is retryable (`client/factory.go:270-277`), and a later backend attempt can then fail its condition. That final condition failure classifies the last attempt, not proof that all earlier attempts of the request were uncommitted. Record each backend attempt and independently establish the request outcome.

Raw History is not a commit oracle: public reads bound the visible prefix using Mutable State and versioned batch selection; conditional failure can trim excess batches. Cache entries can precede storage. Generated tasks and Activity/WFT/buffer mutations commit together; notifications and best-effort deletion occur afterwards. Do not split backend transactions or assume write error implies rollback.

### 3.4 Cancellation competes with result and timeout

Scheduled and retry-backoff ActivityInfo has no started marker; a valid cancellation command records cancellation immediately and arranges Workflow progress. Running cancellation sets CancelRequested. Worker heartbeat persists progress and returns the flag; a heartbeat timeout need not be configured for this voluntary heartbeat. Default-disabled worker-control push is an additional delivery interface when enabled and supported. It sends WorkerCommands through Matching's Nexus transport to SDK Core; it is not a standalone CHASM Activity or arbitrary Nexus-operation model (`common/workercommands/dispatcher.go:27-35,97-145`). Its delivery remains best effort and separate from the Activity cancellation acknowledgement.

Completion can win after a cancel request because it has no CancelRequested veto. Failure/timeout after that request stops retry but can resolve as Failed/TimedOut with CANCEL_REQUESTED disposition. Canceled acknowledgement requires both current identity and CancelRequested. Therefore “successful cancellation request always yields ActivityTaskCanceled” and “cancellation immediately stops external effects” are invalid invariants (`workflow_task_completed_handler.go:692-762`; completed API:85-126; canceled API:82-108; RetryActivity:6888-6914).

Terminal APIs request WFT creation, but the shared helper creates none when an existing WFT is scheduled/started. An acknowledged terminal may be durable in buffered events while its ActivityInfo is deleted. Existing WFT completion/failure/timeout flushes buffers and can create a follow-up, including an inline-started WFT without a transfer row (`api/update_workflow_util.go:80-89`; `mutable_state_impl.go:8573-8583`; `api/respondworkflowtaskcompleted/api.go:384,557-645`). Model **durable terminal information plus outstanding consumption responsibility**, not either one alone. Same-WFT command-generated immediate cancellation may be discarded if that transaction closes the Workflow; do not generalize it to deleting a previously acknowledged worker result (`historybuilder/event_store.go:168-175`, surrounding WFT close guards).

### 3.5 Adjacent findings, compensations and verification classification

| Finding | Verified source and compensating path | Status / next method |
|---|---|---|
| Same-request start omits response metadata | Fresh versus duplicate branches; zero versions skip token checks; attempt still checked | Known open #11734; targeted real response-loss/readback test, not new MC discovery |
| Timeout helper discards RetryActivity error | Executor:310-313; concrete retry task generator always nil and ordinary callback nonfailing under lease | CR-1, no established reachable ordinary storage/input trigger; never inject a fake AddTasks storage failure |
| Timer comparator returns true on equal keys | timer_sequence.go:508-509; normal per-Activity/type entries are unique | CR-2 local ordering audit, no demonstrated protocol consequence |
| Timeout invalid-state logging dereferences missing ActivityInfo | mutable_state_impl.go:4702-4709; actual ordinary caller fetched entry under same lease | CR-5 helper error-path review, no demonstrated missing-entry trigger |
| Default-off retry stamps allow same-stamp old delivery | Producer Attempt check lost at handoff; receiver lacks Attempt/time guard | Historical rollout/contract question CR-3, not rederived closed-fix MC |
| Reset running later attempt may invalidate current worker token | activity.go:319-349 resets Attempt but retains start; shared token guard compares Attempt | TV-3 extension contract/test pending; no reproduction or bug claim |
| HistoryTaskRecorder omits executed-timeout commit | Outer recorder nil-only gate, lower fault wrapper executes then returns Timeout | TV-1 concrete observer limitation; use lower-layer receipt or fenced readback |
| DatabaseMutableState may use cache | SkipForceReload=true avoids clear; LoadMutableState can itself flush/write | Explicit false, preserve reload action/version and establish ownership fence |
| Oversized public completion can return success after failure conversion | frontend/workflow_handler.go:1682-1706; analogous heartbeat/canceled transformations | Bound payloads for ordinary acknowledgement invariants; extension source contract |
| Ignored RecordLastActivityCompleteTime error | Existing entry and nonfailing updater under lease | Excluded as demonstrated bug; no intervening deletion |
| Generic dirty-cache detector assumed to catch every ActivityInfo-only mutation | IsDirty differs from isStateDirty; Activity update maps alone are not universal detector input | Do not use as blanket compensation; concrete error reachability still required |
| “No Started History event means no accepted start”; “retry interval nil means Matching accepted” | Both are representation/derived-observation mismatches | Explicit false-positive exclusions; independently observe ActivityInfo and handoff |

No candidate was discarded from code-review-only reporting because it appeared low value. Model-checkable candidates are limited to forward-looking compositions MC-1/MC-2 in the brief, without removing existing checks. Other TODOs and historical changes were scoped to exclusions or reference evidence with reasons in the per-file/per-commit reports.

## 4. Executed verification and handoff

### Existing functional execution

Exact command (full structured invocation and environment in `functional-command.json`):

```sh
GOMAXPROCS=6 CGO_ENABLED=0 go test -tags disable_grpc_modules,test_dep ./tests \
  -run '^TestActivity(TestSuite|ClientTestSuite)$' -count=1 -timeout=15m -json \
  -persistenceType=sql -persistenceDriver=sqlite
```

Executed against the clean pinned source; test sharding environment variables were removed. Exit **0**, package JSON elapsed **8.244 seconds** (textual package log 8.243). All 14 leaf methods passed, 0 failed/skipped. Counts exclude the two containing suites and the package result.

| Passed test method | Evidence actually checked by test | Important boundary |
|---|---|---|
| ActivityHeartBeatWorkflow_Success | Ten heartbeat RPCs, completion, exact final Workflow History | No durable transaction trace schema |
| ActivityHeartBeatWorkflow_Timeout | Late completion returns ActivityNotFound after heartbeat timeout; WFT progresses | No prior-attempt four-API matrix or crash |
| ActivityHeartBeat_RecordIdentity | Ordered heartbeat changes Describe identity; Workflow completes | Public projection only |
| ActivityRetry | Retryable then nonretryable failure; second Activity waiting timeout; WFT processes outcomes | Not exhaustive timer schedules |
| ActivityRetry_Infinite | Four failures then successful fifth execution | Name does not prove progress under infinitely failing worker |
| TryActivityCancellationFromWorkflow | Running worker receives CancelRequested and acknowledges | Test ends at acknowledgement, not completed formal trace endpoint |
| ActivityCancellationNotStarted | Cancellation command and following WFT processing | No race/reload matrix |
| ActivityTaskCompleteForceCompletion | ByID completion during retry backoff unblocks Workflow | Separate ByID contract, not ordinary old-token success |
| ActivityTaskCompleteRejectCompletion | Old token rejected during backoff | Test ends there; passing prefix not complete trace |
| ActivityScheduleToClose_FiredDuringBackoff | Two worker executions and terminal retry timeout disposition | Request disables eager; no recovery |
| ActivityScheduleToClose_FiredDuringActivityRun | Workflow times out while third attempt still runs/finishes | Correctly permits external work after server terminal |
| ActivityHeartbeatDetailsDuringRetry | SDK receives retained heartbeat; Describe/Workflow complete | SDK batching and observation timing matter |
| Activity_AttemptsExceeded | Finite maximum attempts gives final failure and History event | Name of error string does not make it nonretryable policy |
| ActivityTimeouts | Eight configured timeout combinations and heartbeat details | One Go test method, not eight independent complete formal traces |

Source anchors: `tests/activity_test.go:57,116,188,375,507,702,806,909,1054,1176,1289,1422,1454,1515`. The two ByID/token controls belong to the existing ordinary-Activity suites; they do not authorize silently expanding the initial formal model to all administration APIs.

### Complete trace and recovery plan for subsequent phases

The present Go JSON log preserves commands, test identities, server logs and test results. It is **not** NDJSON of all modeled ActivityInfo/transaction transitions. No validator was run, no complete formal trace was accepted, no corruption control was run against a model, and no TLC state count exists. Do not rename it as trace validation evidence.

Required independent observations:

1. Under a Workflow lease, deep-copy ActivityInfo and relevant WFT/buffer state before/after mutation. `CloneToProto` is deep (`mutable_state_impl.go:989-1007`), but its BufferedEvents reflects `bufferEventsInDB`; capture tentative builder buffers separately before close. Record scheduled ID, Attempt, StartVersion/Version/Stamp, request ID, started marker/time/clock, all deadlines/policy, heartbeat and cancellation state.
2. Preserve immutable submitted execution mutation, History batches, generated task identities and condition/version/RangeID. Assign a causal request/transaction sequence under the lock. A timestamp or application transition count alone is not a universal commit order.
3. Record actual persistence outcome below fault injection or independently read execution and task-store state after fencing. Standard test wiring puts `HistoryTaskRecorder` outside the lower fault wrapper; `ExecuteAndTimeout` returns past its nil-only gate, and Timeout is not retried by the persistence retry classifier (`testcore/onebox.go:172-187`; `persistence/client/fx.go:210-212`; `client/factory.go:197-218,270-277`). Never infer “no durable task” from that recorder's missing row.
4. Record lease release, Matching Add request/return, History start acceptance commit, actual worker poll payload/token, and result/heartbeat receipt/response as separate observations. Do not populate missing independent state from the received response itself or desired model successor.
5. For DescribeMutableState use **SkipForceReload=false**, record the clear/reload action, preserve both cache and DB projections, and observe any write during StartTransaction flush. A field named DatabaseMutableState is not sufficient. Take SQL readbacks quiescent under a valid fenced lease or bracket with unchanged record versions.
6. Finish every trace at independently confirmed Activity terminal information and Workflow responsibility/consumption. If a worker result committed during an in-flight WFT, follow buffer flush and the WFT that consumes it. Prefixes and missing observation intervals remain INCOMPLETE.

| Required complete scenario | Controls / final endpoint | Current status |
|---|---|---|
| Healthy schedule→start→heartbeat→complete→WFT consume | Independent ActivityInfo and committed task/buffer readback | Functional evidence available; full trace INCOMPLETE |
| Failure→retry→start with four old-token message kinds | All four rejected without current-state change; finish new attempt and WFT | Old completion prefix control exists; full matrix INCOMPLETE |
| Heartbeat extension with duplicate/delayed timeout cue | Compare current deadline, timer mask, durable cue and volatile reload watermark | Source analyzed; trace INCOMPLETE |
| ScheduleToClose during backoff/running, plus simultaneous timer types | Preserve final timeout type/retry-state/cause; worker may finish later | Functional evidence available; ordered task/state trace INCOMPLETE |
| Scheduled/running/backoff cancel vs completion/failure/timeout | Valid multiple outcomes; explicit worker cancellation observation; WFT endpoint | Partial functional coverage; complete race traces INCOMPLETE |
| Definitely skipped write versus ExecuteAndTimeout | Actual backend readback distinguishes same returned Timeout; resume Workflow | Not executed; INCOMPLETE |
| Terminal commit with in-flight WFT, lost response, cache reload and duplicate result | Terminal information retained; old result rejected; later WFT consumes | MC-1 handoff scenario, not executed |
| Two Activities share earliest cue; heartbeat/retry plus reload | No current deadline/retry work lost in one committed scan | MC-2 handoff scenario, not executed |

Cache reload, shard reacquisition, process restart and database restart each require their own fault/action marker and before/after durable evidence. `testcore.TestEnv.CloseShard` is only a shard operation; it must not be reported as server/database restart. Database outage/restart needs backend-specific setup and durability assumptions. Existing temporary SQLite cleanup is not a saved database restart experiment.

### Bounded verification recommendation

Build the ordinary lifecycle and validate complete healthy traces first. Proposed first bounds: one Workflow, one Activity, two attempts/workers, two ownership epochs, at most two pending copies of each cue/message and one storage/response fault. Use explicit millisecond time representatives for deadline equality/order, finite retry limit/expiration, valid payloads, no admin/routing/time-skipping. Then add two Activities for shared timer scanning, a concurrently started WFT, and separate retry-stamp false/true configurations. Bounds are recommendations; **no bounded state space was explored in this phase**.

Safety obligations must keep valid terminal information and consumption responsibility together; not merely “a WFT exists somewhere” or “a terminal buffer exists.” Late messages must not change another attempt. The backend transaction must be atomic and current-owner conditioned, while caller acknowledgement is separate. Timer work may be covered by an earlier physical cue or Workflow expiry, so avoid a false invariant requiring one persistent task per logical deadline.

Liveness requires time advancement, finite or policy-relevant deadlines, eventual queue/timer delivery and storage recovery, polling workers and WFT completion, plus an eventually stable healthy suffix. Unlimited failing retries need not succeed; a permanently paused Activity or dispatch parked in DLQ does not meet healthy-progress assumptions. Do not call nonconverged TLC searches passes; preserve INCOMPLETE and exact completed bounds, state counts and remaining frontier when subsequent phases run.

### Extension status

Pause/unpause, ResetActivity and ByID are contractually distinct. Detailed source comparison is in [Mutable State review](analysis-evidence/deep-mutable-state.md), including every reset/unpause variant. Running pause may allow current completion; pausing scheduled/backoff work changes stamp. Reset may reset Attempt to 1 while retaining a running start, invalidating an old attempt>1 token; reset flags can also clear/recreate work. ByID force completion can synthesize a Started event while pending in backoff. Those source facts do not establish extension bugs or extension formal fidelity. Only the two existing ByID/token functional controls ran; pause/reset traces and model extensions remain unvalidated and deferred until the complete ordinary core is calibrated.

The handoff preserves the user's four priorities, adjacent implementation-derived observation/WFT questions, explicit exclusions and all feasible source-analysis evidence. No fixes, historical regression hunts, fabricated trace successors or unearned verification verdicts were introduced.
