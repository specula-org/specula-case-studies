# Modeling Brief: NVFlare Job Lifecycle and Resource Accounting

## 1. System Overview

- **System/pin:** NVIDIA/NVFlare, Python, `53ba7ee567468ea7971dad4faccef13c6cb35dc2`; eight core files total 4,037 physical lines, read completely. Source root: `/home/ubuntu/nvflare-job-lifecycle-20260914/source`.
- **Category A (Distributed / Message-Passing):** server/site commands coordinate admission and jobs; local resource locks, callback threads and process waiters create additional atomicity boundaries. Cooperative participants; no Byzantine, HA or crash-recovery model.
- **Reference:** local functional protocol contracts and pinned APIs/documentation, not a consensus algorithm or an existing theorem. The implementation separates reservation, allocation, process binding, startup acknowledgement, terminal status and cleanup.
- **Selected configuration for downstream modeling (not deployed here):** built-in `ListResourceManager(resources={"gpu": [0, 1]}, expiration_period=30)` plus `ListResourceConsumer`, default `ClientProcessJobLauncher`/`ServerProcessJobLauncher`, built-in job manager/filesystem metadata store. IDs represent exclusive managed units; no GPU computation is needed.
- **Policy:** `DefaultJobScheduler(max_jobs=2)` to expose competing jobs; also examine limit 1. Keep retry defaults 10 attempts, 10–600 s exponential intervals. Base job targets server/site-1/site-2, `min_clients=1`, `mandatory_clients=["site-1"]`; examine strict checking and tighter participant requirements separately.
- **Actual default:** `strict_start_job_reply_check=False`; admission/deploy enforce minimum/required sites, but non-strict start timeouts do not re-enforce them. Strict mode does. Start commands wait 20 s; reservation cleanup ticks every 1 s; normal client-outcome grace is 900 s and archival-error grace 60 s (`job_runner.py:109-111,313-360,494-522`; `server_engine.py:1068-1083`). This selected manager's 30 s TTL differs from provisioning's GPU-manager template TTL of 300 s.
- **Concurrency:** one admission thread, independent completion/server-exit/client-exit/heartbeat threads, concurrent site command callbacks; event dispatch is synchronous and catches ordinary component exceptions (`job_runner.py:441-541,633-731`; `apis/utils/event.py:27-84`; `fuel/f3/sfm/conn_manager.py:43,90-91,365-396`).

## 2. Scenarios

Source filenames below resolve under the source root; abbreviated core filenames have their full paths in §7. All new candidates are source-supported questions, not model counterexamples or executed reproductions.

### Scenario 1: Allocation identity crosses shared process environment

**Mechanism:** job-local allocation is converted into shared parent environment, then copied into a child at a later step.
**Evidence:**
- Code analysis: `app_common/resource_consumers/list_resource_consumer.py:31-37` sets global `CUDA_VISIBLE_DEVICES`; `scheduler_cmds.py:115-128` consumes before startup; `app_common/job_launcher/process_launcher.py:66-83` snapshots the environment later.
- Code analysis: callback delivery is concurrent; `server_engine.py:1082` times out without cancelling execution; `job_runner.py:345-360` can continue with other acknowledged sites. The allocation lock ends before consumption/launch (`auto_clean_resource_manager.py:153-164`).
**Affected code paths:** resource allocation → consumer → ClientEngine/JobExecutor startup → ProcessJobLauncher; server timeout and next-job admission.
**Suggested modeling approach:**
- Variables: per-job `allocation`, shared per-site `resourceEnv`, per-child `launchBinding`, command execution stage and reply waiter state.
- Actions: split `Allocate`, `Consume`, `SnapshotLaunchEnvironment`, `Spawn`, `Exit`, `Free`; derive overlapping starts from a timeout and a subsequent admitted job.
- Granularity: preserve the resource-manager mutex, but allow another job between consume and environment snapshot. No duplicate START or arbitrary command injection is necessary.
**Priority:** High. **Rationale:** strong supported cross-component path; distinct allocation payloads can still produce overlapping process bindings and later release a unit selected by another live child (MC-1).

### Scenario 2: Startup rollback has no explicit cleanup-ownership commit

**Mechanism:** the same exception rollback applies both before and after a live child has acquired the allocated resources.
**Evidence:**
- Historical: commit `55e74fe2af` introduced consume-before-start and exception-only rollback; this is architectural context, not a pre-fix target.
- Code analysis: `client_executor.py:299-334` registers a pending handle, launches, attaches, then starts the cleanup waiter; `scheduler_cmds.py:129-133` frees on a propagated exception without checking whether launch already succeeded.
- Code analysis: early returned errors at `client_engine.py:357-367` bypass that rollback; a full supported fresh-allocation trigger is not yet established (CR-1).
**Affected code paths:** StartJobProcessor, ClientEngine.start_app, JobExecutor.start_app and child-exit waiter.
**Suggested modeling approach:**
- Variables: `cleanupOwner` (startup/waiter/none), `childAlive`, `handleRegistered`, `waiterStarted`, allocation payload and startup outcome.
- Actions: split successful spawn from waiter installation; allow an ordinary waiter-thread creation failure, then follow actual processor rollback and later heartbeat/abort.
- Granularity: do not replace production AFTER_JOB_LAUNCH dispatch with an exception-throwing mock; handler exceptions are swallowed (`apis/utils/event.py:74-82`).
**Priority:** High. **Rationale:** a concrete ordinary runtime failure can return capacity while its child remains live; controlled-fault confirmation should accompany the small ownership model (MC-2/TV-1). Thread-start failure alone does not establish double free.

### Scenario 3: Status decisions outlive their checked lifecycle state

**Mechanism:** status validation, local map publication and stored status updates are separate operations on independent threads.
**Evidence:**
- Historical: `a6dcce63ed` serialized launch/publication; `6f75707f34` later narrowed locks to map operations. Current-source questions are about present interleavings, not reverting either commit.
- Code analysis: `job_runner.py:661-711` checks SUBMITTED/DISPATCHED, later stores DISPATCHED/RUNNING; `server/job_cmds.py:1059-1066` can acknowledge an abort of those states without sending process stop.
- Code analysis: `job_runner.py:709-711` exposes `running_jobs` before RUNNING publication; completion can store a terminal state and remove that entry/slot at `524-538`. `apis/impl/job_def_manager.py:459-481` has no expected-state update guard.
**Affected code paths:** JobRunner.run, CLI abort_job, server process waiter, _job_complete_process, SimpleJobDefManager.set_status.
**Suggested modeling approach:**
- Variables: stored `jobStatus`, saved status-read result, admission program counter, `runningJobs`, process existence, acknowledged pre-run abort, terminal publication.
- Actions: separate status read, deployment/start, map registration, RUNNING write, terminal write and removal; compose with supported admin abort and quick process exit.
- Granularity: locks cover only their actual map operations. Preserve real client-outcome/archival delays instead of atomically inventing immediate completion.
**Priority:** High. **Rationale:** accepted abort may be overwritten; a stale RUNNING write may follow final removal, leaving no completion owner to repair status (MC-3/MC-4).

### Scenario 4: Logical termination, outcome receipt and physical cleanup diverge

**Mechanism:** distinct observations drive status, scheduler membership and resource release on separate control loops.
**Evidence:**
- Historical/reference only: issues [5115](https://github.com/NVIDIA/NVFlare/issues/5115) and [5220](https://github.com/NVIDIA/NVFlare/issues/5220) are fixed at this pin; heartbeat and authoritative-failure bypass must remain intact.
- Code analysis: client STOPPED retains ownership; normal release follows `wait()` (`client_engine.py:390-404`; `client_executor.py:622-688`). Report errors are caught before free. Server abort's bookkeeping removal follows terminate request without observed exit (`server_engine.py:385-409`).
**Affected code paths:** abort processors, client/server waiters, terminal outcome receiver, heartbeat synchronization, runner completion and lifecycle events.
**Suggested modeling approach:**
- Variables: stop sent/received, logical client status, actual child state, exit observed, outcome pending, archival/publication stage, free count.
- Actions: retain normal wait-before-free; permit terminal report loss and bounded outcome/archival delay; follow heartbeat cleanup after server failure.
- Granularity: neither stop acknowledgement nor STOPPED implies resource quiescence. Treat server terminate/pop as CR-2 until its ordinary local failure consequence is established; no standalone hunt for an assumed broken SIGKILL.
**Priority:** Medium. **Rationale:** required Q3 coverage and necessary context for Scenario 2; normal repeated abort/completion does not itself establish duplicate resource release.

### Scenario 5: Per-job failure can escape a scheduling or completion service

**Mechanism:** error containment varies between normal admission failure, unexpected admission exception, startup cleanup, and completion retries.
**Evidence:**
- Known/open: [PR 5191](https://github.com/NVIDIA/NVFlare/pull/5191), head `27ecde2ab85b38734072b90128dc5dc2e8390882`, was OPEN/unmerged on 2026-09-14. Admission cancellation/retry-history gaps overlap its scope; they are not new findings.
- Code analysis: `job_scheduler.py:292-310,364-375` catches around the whole candidate pass; runner's FAILED_TO_RUN/update/stop calls inside its catch remain unguarded (`job_runner.py:713-730`). Completion's unconditional deletion can race startup-failure removal (`532` versus `715-717`).
- Compensation: reservations retain TTL ownership; archival errors yield to other jobs and have 60 s grace, while terminal status-store errors retry (`494-530`).
**Affected code paths:** _try_job/_do_schedule_job, JobRunner.run failure branch, _job_complete_process, metadata store and thread entrypoint.
**Suggested modeling approach:**
- Variables: preserve retry count/history/backoff, resource TTL and cleanup owners; add `serviceAlive` and failure-branch program counters only if TV-2/TV-3 justify extending the model.
- Actions: first test finite metadata errors, competing removals and subsequent eligible-job admission/completion; retain #5191 as known context without a rediscovery hunt.
- Granularity: distinguish store calls, locked map deletion and exception exit. Progress assumes eventual transport/store recovery, cleanup ticks and process exit; permanently unsatisfiable requests need not start.
**Priority:** Medium. **Rationale:** user Q5 is covered without declaring a lost cancellation acknowledgement a permanent leak or requiring success despite unavailable sites.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Actual reserve/allocate/free ownership | Scenarios 1–2; available units and process bindings can diverge | Multiset/list-derived capacity plus per-token reservation and per-job allocation; keep all RM lock blocks atomic |
| Selected participant policy and delayed command execution | Scenarios 1–2; a reply timeout permits overlapping work | Separate requested, reserved, deployed, acknowledged and actually launched sites; encode strict/non-strict behavior from report policy table |
| Launch resource binding and cleanup handoff | Scenarios 1–2 are new cross-component questions | Shared resource environment, child snapshot and explicit pre/post-spawn ownership stages |
| Stored status versus process/map state | Scenario 3 | Split reads/writes/registration and preserve the real admin abort branch |
| Exit/report/cleanup order | Scenarios 2 and 4 | Wait before ordinary free, report failure continuation, heartbeat and finite outcome/archival grace; represent failures separately from nontermination |
| Admission attempt identity and production events as faithful context | Required Q4/Q5; no arbitrary wrong-job/duplicate-start adversary | Fresh reservation tokens and transport waiter IDs; retries only while eligible; synchronous events carry explicit job IDs with idempotent scheduler membership |

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Training rounds, aggregation, model transfer internals, GPU computation, external trainers/alternative launchers, HA/crash recovery | Explicit user scope; resource binding can be observed without executing these mechanisms |
| Workspace contents or arbitrary removal of deployed files | Explicit scope; retain only cleanup delay/error/success needed for lifecycle completion |
| Pre-fix missing-token allocation, sticky-event-ID bug, old heartbeat/outcome-barrier failures | Already fixed; reference context only, no reverting guards or historical-answer hunt |
| #5191's acknowledged admission exception/cancellation bookkeeping as a new discovery | Known open issue; retain accurate baseline and mark overlap |
| Arbitrary repeated START with fresh tokens for the same running job; fabricated wrong-job notifications | No supported scheduling-attempt path established; same-token allocation is rejected |
| Universal scheduler-count equals live-OS-process-count invariant | Launch and cleanup legitimately span separate stages; inspect ownership and stable status instead |
| Invalid custom resource counts as an unconstrained protocol fault | CR-3 first: establish/repair input contract, then decide scope; do not silently discard the finding to make a model pass |

## 4. Proposed Extensions

| Extension beyond abstract admit/start/finish | Variables | Purpose | Scenario |
|---|---|---|---|
| Resource binding | `allocation, resourceEnv, launchBinding` | Compare manager ownership with child's selected unit | 1 |
| Cleanup handoff | `handleRegistered, childAlive, waiterStarted, cleanupOwner, freeCount` | Separate rollback before spawn from cleanup after actual use | 2 |
| Non-atomic status publication | `jobStatus, checkedStatus, admissionPC, runningJobs, abortAck, terminalPublished` | Explore abort/completion against stale startup writes | 3 |
| Distributed lifecycle observations | `commandStage, replyWaiter, outcomePending, logicalStatus, exitObserved, cleanupStage` | Preserve policy and quiescence distinctions around the new questions | 1–4 |

## 5. Proposed Invariants

| Property | Type | Description | Targets |
|---|---|---|---|
| ResourceConservation | Safety | Initially unique managed units occur exactly once across free/reserved/allocated ownership; count multiplicities, not only set membership | Standard resource contract; Scenarios 1–2 |
| ProcessBindingMatchesOwnership | Safety | A live child's selected managed units belong to its current allocation and do not overlap another live child's exclusive binding | MC-1 |
| NoFreeWhileInUse | Safety | A unit selected by a live owned child is not free or reassigned | MC-1/MC-2 |
| CleanupOwnerOrCompleted | Safety + conditional liveness | Every transferred allocation has an effective cleanup owner or is released after exit; eventually release under stated progress assumptions | MC-2, Scenario 4 |
| AcceptedPreRunAbortPersists | Safety + conditional liveness | A successful pre-run abort cannot be undone by stale deployment/start publication; overlapping created processes must have cleanup ownership | MC-3 |
| NoTerminalResurrection | Safety | Within one supported attempt, terminal publication/removal cannot be followed by stale RUNNING publication | MC-4 |
| OtherEligibleJobProgress | Conditional liveness | With a free configured slot, satisfiable resources and eventual service/transport/store recovery, another eligible job is eventually considered | TV-2/TV-3 first; Scenario 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Forward-looking question | Expected violation if confirmed | Scenario |
|---|---|---|---|
| MC-1 | Can a delayed legitimate start and the next admitted job snapshot the same resource selection despite disjoint reservations/allocations? | ProcessBindingMatchesOwnership; possibly NoFreeWhileInUse after one exits | 1 |
| MC-2 | Can failed waiter installation after successful default local spawn apply pre-launch rollback and expose the live child's units to another job? | NoFreeWhileInUse, CleanupOwnerOrCompleted | 2 |
| MC-3 | Can the supported successful SUBMITTED/DISPATCHED abort be overwritten after a runner status recheck but before its next status write? | AcceptedPreRunAbortPersists | 3 |
| MC-4 | Can completion publish terminal/remove the job between registration and the delayed RUNNING write, leaving stale persistent RUNNING with no completion owner? | NoTerminalResurrection | 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested local functional verification |
|---|---|---|
| TV-1 | MC-2's post-spawn thread-creation failure boundary | Preserve real dispatch/manager/handle ownership; fail only cleanup-waiter installation, observe live process and available units, then reclaim the test child |
| TV-2 | A finite metadata error in the runner failure branch escapes the unsupervised admission thread | Observe thread survival, retry/event bookkeeping and a second eligible job after store recovery (`job_runner.py:713-730`; `server_deployer.py:144-145`) |
| TV-3 | Completion removal races startup-failure removal and may stop unrelated completion | Coordinate the two production branches around map removal; verify unrelated completion continues (`job_runner.py:446-447,531-538,715-717`) |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | Returned startup error skips allocation rollback | Establish a supported fresh-allocation trigger for `client_engine.py:357-367`; same-token replay and arbitrary workspace deletion do not qualify |
| CR-2 | Server terminate request followed by unconditional bookkeeping removal | Review local handle contract/error retention (`server_engine.py:385-409`; `process_utils.py:293-316`); no confirmed persistent local-process consequence |
| CR-3 | Invalid custom count can raise after partial dequeue but before TTL-token registration | Validate all count types/ranges before mutation or provide exception rollback (`list_resource_manager.py:57-76`; `auto_clean_resource_manager.py:128-131`); retain as input-contract finding |
| CR-4 | STARTED-notification retry deadline only logs after expiry | Reconcile documented bound with loop behavior and independent abort cleanup (`client_app_runner.py:171-222`); one lost reply is not a permanent leak |
| CR-5 | Non-strict reply helper ignores error headers contrary to its docstring | Review actual `error_reply` producer reachability before promoting (`server/admin.py:89-99,133-137`; `private/admin_defs.py:78-83`) |
| CR-6 | Empty selected client snapshot falls back to all connected clients | Review disconnect-during-start policy and participant identity (`server_engine.py:296-338`); no wrong-job resource consequence established |

## 7. Reference Pointers

- Full audit: [analysis-report.md](analysis-report.md); [history ledger](evidence/history-audit.md), [issue audit A](evidence/issues-a.md), [issue audit B](evidence/issues-b.md), [client audit](evidence/deep-client.md), [runner audit](evidence/deep-runner.md), [resource/server audit](evidence/deep-resources-server.md).
- Core paths: `nvflare/app_common/job_schedulers/job_scheduler.py:104-378`; `nvflare/private/fed/server/job_runner.py:149-541,633-731,798-852`; `nvflare/private/fed/server/server_engine.py:179-409,1007-1083`; `nvflare/private/fed/client/scheduler_cmds.py:57-157`; `nvflare/private/fed/client/client_engine.py:349-404`; `nvflare/private/fed/client/client_executor.py:198-350,486-688`; `nvflare/app_common/resource_managers/auto_clean_resource_manager.py:93-176`; `nvflare/app_common/resource_managers/list_resource_manager.py:33-82`.
- Known/reference: [5191 full discussion](https://github.com/NVIDIA/NVFlare/pull/5191), especially [expiry/tradeoff comment](https://github.com/NVIDIA/NVFlare/pull/5191#issuecomment-5432240101); [fixed lifecycle identity issue 5215](https://github.com/NVIDIA/NVFlare/issues/5215); fixed issues 5115/5220 above. These are not new MC targets.
- Local contracts: `nvflare/apis/resource_manager_spec.py:26-88`; `docs/programming_guide/resource_manager_and_consumer.rst`; `docs/user_guide/core_concepts/job.rst:355-410`; `docs/user_guide/timeout_troubleshooting.rst:294-304`.
- Execution boundary: code/history/discussion analysis only. No TLA+ spec, TLC, trace validation, process-fault experiment or test run was performed; all four MC findings require downstream confirmation.
