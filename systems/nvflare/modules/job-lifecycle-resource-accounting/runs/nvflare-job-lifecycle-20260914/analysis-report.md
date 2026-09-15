# Analysis Report: NVFlare Job Lifecycle and Resource Accounting

Analysis date: 2026-09-14 UTC. Source: `/home/ubuntu/nvflare-job-lifecycle-20260914/source`, pinned at `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Primary handoff: [modeling-brief.md](modeling-brief.md).

The strongest current source-supported question is whether delayed competing starts inherit the same resource selection through the parent process environment despite receiving disjoint allocations. Two independent status-publication races and a post-spawn cleanup-handoff failure also merit downstream verification. The reservation mutex/token checks, lifecycle event-ID fix and several cleanup backstops are already implemented. This report does not claim a confirmed production defect, a model counterexample or exhaustive correctness.

## Method and evidence boundary

Followed the user-selected `code-analysis` skill at `/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/Specula/skills/code_analysis/SKILL.md`: full `guide.md`, shared deep analysis, distributed analysis, bug archaeology, modeling-brief format and example were read. Category classification preceded archaeology. Reconnaissance, historical issue/commit review, deep source analysis and synthesis were completed; issue verification and deep analysis used three parallel agents plus root cross-review, within the available four execution slots.

This is **Category A (Distributed / Message-Passing)**. Server/site requests establish distributed lifecycle ownership; threads and process waiters add local concurrency. No BFT overlay applies. No reference consensus paper exists for this target: the reference is the supported local job protocol, resource APIs and pinned documentation, with expected properties investigated rather than assumed true.

Only the run's output/evidence directory was changed. The pinned source was read only and remained clean. The source checkout is shallow; an independent full-ancestry filtered bare clone was created at `evidence/nvflare-history.git`, preserving the investigation worktree. Live GitHub retrieval used read-only `gh` and browser access. No publication, PR, maintainer contact, source patch, regression execution, process experiment, GPU workload, TLA+ spec generation, TLC run or trace validation occurred.

Evidence levels used here:

| Level | What this run established |
|---|---|
| Pinned source | Exact branches, locks, exception handlers, supported callers, configuration semantics and compensations |
| Historical evidence | Commit diffs and full selected GitHub discussions, with fix/branch/known-issue distinctions |
| New candidate | Source-supported mechanism with remaining model/local-execution obligations; not a reproduced bug |
| Model counterexample / trace conformance / controlled-fault evidence | **None produced in this phase** |
| Production consequence | Inferred possible impact where stated; untested, with trigger and scope limits recorded |

## Phase 1: structural map and selected configuration

### Core inventory

All eight core files were read completely by root and independently across deep-analysis agents. Counts include comments and blank lines, not executable-only LOC.

| Core file under `nvflare/` | Lines | Responsibility |
|---|---:|---|
| `app_common/job_schedulers/job_scheduler.py` | 388 | Eligible candidates, site policy, resource check/cancel, retries, scheduler membership |
| `private/fed/server/job_runner.py` | 869 | Deployment/start/abort, running registry, outcomes, terminal publication and archival grace |
| `private/fed/server/server_engine.py` | 1,115 | Server child ownership, site requests, response conversion and abort cleanup |
| `private/fed/client/scheduler_cmds.py` | 184 | Resource check, allocation/consumption/start and cancellation processors |
| `private/fed/client/client_engine.py` | 527 | Client startup prechecks and lifecycle entrypoints |
| `private/fed/client/client_executor.py` | 696 | Pending handles, local child launch, abort intent, wait/report/free |
| `app_common/resource_managers/auto_clean_resource_manager.py` | 176 | Lock-protected reservation TTL, allocation transfer and release |
| `app_common/resource_managers/list_resource_manager.py` | 82 | Concrete exclusive unit deque accounting |
| **Total** | **4,037** | |

Adjacent complete reads include the process launcher/adapter, ListResourceConsumer, resource interface, client admin dispatcher, shared event dispatcher and event job-ID helper. The runner agent also read FLComponent/FLContext fully. Targeted adjacent reads include production transport, server heartbeat/outcome processing, job commands, metadata store, client status-notification runner and provisioning/docs. Full versus targeted inventories are preserved in [deep-client.md](evidence/deep-client.md), [deep-runner.md](evidence/deep-runner.md) and [deep-resources-server.md](evidence/deep-resources-server.md); unrelated portions of those larger adjacent modules are not claimed exhaustively reviewed.

### Selected analytical configuration

The following is a concrete downstream modeling choice, not a claim that a live cluster/configuration was deployed in this phase:

- Server: `DefaultJobScheduler(max_jobs=2)`, built-in SimpleJobDefManager/FilesystemStorage, default local ServerProcessJobLauncher. Retain retry defaults: 10 attempts, minimum interval 10 s, maximum 600 s (`job_scheduler.py:39-60,347-375`). A `max_jobs=1` comparison is useful for cleanup/queue behavior; the constructor default is 1 and the provisioning template uses 4 (`lighter/templates/master_template.yml:209-231`).
- Sites: `ListResourceManager(resources={"gpu": [0, 1]}, expiration_period=30)` and `ListResourceConsumer`, default ClientProcessJobLauncher. Each configured unit is unique and exclusive; a valid ordinary job requests an integer count such as `{"gpu": 1}` for each applicable site. Custom resource keys survive normalization (`utils/job_launcher_utils.py:311-323`). Invalid count handling is retained separately as CR-3.
- Base participant policy: server, site-1 and site-2 targeted; `min_clients=1` and `mandatory_clients=["site-1"]`, mapping to `Job.min_sites=1` and `required_sites=["site-1"]` (`apis/job_def.py:144-165,241-242`). Base strict-start setting is false. Explore true, higher minimum and changed required sets explicitly; do not silently impose all-site success.
- ListResourceManager inherits a one-second cleanup tick and default TTL count 30. This differs from the provisioned GPUResourceManager template's 300 (`lighter/templates/master_template.yml:73-89`). Expiry is counted in scheduled ticks, not a hard wall-clock deadline; a live fairly scheduled cleanup thread is a progress condition (`auto_clean_resource_manager.py:93-117`).
- Linux local process semantics, cooperative sites, supported scheduling/admin APIs, ordinary finite I/O failures/timeouts/delays/process exits. Scope excludes HA/crash recovery, aggregation, transfer internals, GPU computation, external trainers and alternative launchers. Resource environment binding is in scope because it determines which assigned unit a child selects.

### Exact participant/reply policy

| Stage | Success/failure decision | Evidence |
|---|---|---|
| Admission | Required sites must be applicable/connected; enough positive resource replies must satisfy minimum and required sites. Normal insufficient-resource outcomes cancel successful reservations. Server capacity is assumed sufficient. | `job_scheduler.py:139-178,199-259` |
| Deployment | Every requested client token initially maps to None; timeout/missing or non-OK reply is failed deployment. Fail the job only if resulting minimum/required policy fails; otherwise exclude failed sites from start. | `server/admin.py:286-305`; `job_runner.py:250-282,692-695` |
| Start, both modes | An empty reply list or count mismatch raises. ERROR-prefixed string bodies raise. The server process is already launched before waiting for client start replies. | `server/admin.py:101-105,131-140`; `job_runner.py:304-310` |
| Strict start (`true`) | Missing client identities/non-OK headers raise. None replies become timed-out sites; caller enforces minimum/required sites and excludes permissible timeouts. | `server/admin.py:111-132`; `job_runner.py:324-343` |
| Non-strict start (`false`, actual default) | None replies are ignored and excluded from active metadata without re-enforcing minimum/required sites. Non-OK headers are not examined by this branch; see CR-5. A populated ClientReply list containing None payloads differs from an empty list. | `server/admin.py:133-142`; `job_runner.py:313-317,345-360`; `docs/user_guide/timeout_troubleshooting.rst:300-304` |
| After startup | `JOB_CLIENTS` and pending outcomes reflect the active reply set. They do not revoke a delayed callback that is already allocating/launching, nor update the original server participant snapshot. | `job_runner.py:298-310,355-360`; `server_engine.py:321-338` |

The helper docstring claims non-OK headers always raise, but non-strict implementation only checks an ERROR-prefixed string. The model must follow executable behavior and separately record the discrepancy, not treat the docstring as a guard. Missing start replies are not evidence that a command was never executed.

### Ownership and concurrency map

| Stage/control loop | Actual atomicity boundary | Ownership/correlation |
|---|---|---|
| Reserve | One RM lock spans availability check and deque removal, then token insertion | Units move free → reserved (`auto_clean_resource_manager.py:123-138`) |
| Expire/cancel | Same lock, guarded token pop followed by deallocation | Only still-reserved units return; repeated cancellation is harmless (`102-117,140-151`) |
| Allocate | Same lock, require existing token and pop it | Units leave TTL tracking; caller now holds the payload (`153-164`) |
| Consume → launch | No common lock; consumer sets global environment, launcher later copies it | Binding can diverge from the allocation payload (`list_resource_consumer.py:31-37`; `process_launcher.py:68`) |
| Client launch | Per-job pending record under executor lock; launch outside it; then attach and waiter creation | Pending handle owns abort intent; cleanup handoff is later (`client_executor.py:299-334`) |
| Client cleanup | One waiter observes real exit, reads/reports outcome, frees, removes record, fires event | Normal free follows wait; report errors do not skip it (`622-688`) |
| Server launch/exit | Launch → engine registry → watcher; normal watcher waits before map removal | Separate from runner's `running_jobs` and stored RUNNING (`server_engine.py:203-234,315-328`) |
| Server abort | Captured handle, bounded grace, terminate request, unconditional map removal | Request is weaker than observing exit (`354-409`); CR-2, not a proven resource leak |
| Runner completion | Independent loop, individual map locks, separate store updates | Pending outcomes and archival grace precede terminal publication/removal (`job_runner.py:441-541`) |
| Lifecycle events | Synchronous, per-handler Exception caught, event data reset before each handler | Explicit job ID; scheduler add/remove is membership-guarded under lock (`apis/utils/event.py:38-84`; `job_scheduler.py:275-285`) |
| Requests/replies | Fresh waiter ID plus target; waiter removed on completion/timeout | Late old replies are dropped; timeout does not stop receiver execution (`core_cell.py:1512-1574,1986-2028`) |

The admission thread is single-threaded, but that does not serialize site execution after a timeout. F3 dispatch submits frames to a 100-worker pool and calls the processor without a per-site startup mutex (`fuel/f3/sfm/conn_manager.py:43,90-91,365-396`; `private/fed/client/admin.py:164-165`). This production path establishes concurrency without relying on Simulator or invented parallel scheduling calls.

## Phase 2: archaeology coverage and current known-issue status

### Quantitative coverage

| Item | Actual coverage |
|---|---|
| Core path history | 248 unique commits screened across fetched public branches; 217 pin ancestors, 31 other-branch entries |
| Keyword scan | 152 candidates matching fix/bug/race/panic/deadlock/correctness/crash/corrupt/leak/inconsistent/wrong in subjects/bodies; 131 pin ancestors |
| Non-keyword coverage | All 96 remaining path commits screened, not sampled |
| Detailed mechanism ledger | 90 functional/mechanism references (62 keyword, 28 non-keyword), 13 branch counterparts; 145 exclusions (23 security/policy, 11 HA, 111 other) |
| Archived diffs | All 248 path-filtered patches; significant functional changed lines reviewed. Large out-of-scope imports/security/HA implementations were screened for exclusion, not claimed exhaustively audited |
| Supplemental adjacent history | All 10 commits for ListResourceConsumer/ProcessJobLauncher read, including two equivalent spawn changes and mechanical/feature changes; overlaps not added to 248 as distinct core commits |
| Issue collection | 154 unique issues from ten searches: bug label, scheduler, reservation, resource, job abort/start/deploy/stuck/cleanup, process exit; raw search files and union archived |
| Issue deep reading | 33 actual issue bodies plus all 159 comments; 15 historical confirmed bugs/limitations, 3 acknowledged design/support requests, 5 user errors, 2 expected/disputed reports, 8 uncertain/support reports |
| False-positive issue exclusions | 7 primary reports explicitly excluded as user error/expected behavior; separate historical-fixed, out-of-scope and insufficient-evidence exclusions do not inflate this count |
| Open PRs | All 15 bodies and all file paths reviewed; all functional fix-intent PRs (5073, 5191, 5286) and four dependency-fix discussions deeply read; one security change read for exclusion only; seven feature discussions downloaded without deep-read claim |
| Additional PR discussions | 17 resolution PRs deeply read across both batches; 32 distinct PRs inventoried in total, 25 full discussions including the security-exclusion review, seven feature inventories |
| Tests/model/production runs | Zero executed in this analysis phase |

**These are not 90 distinct confirmed bugs, 154 deeply reviewed issues, or 32 exhaustively reviewed feature PRs.** Every count has a defined evidence boundary. Issue attachments/private repositories and unrelated linked web pages were not independently audited. Full per-commit root cause/component/severity/pin status is in [history-audit.md](evidence/history-audit.md) and its [machine-readable ledger](evidence/history-review-ledger.json); original full patches are linked there. [issues-a.md](evidence/issues-a.md) and [issues-b.md](evidence/issues-b.md) preserve every deeply read issue's classification and full-thread evidence, including later PR follow-ups. Historical severity is an analyst functional assessment, not a security score.

### Historical mechanisms and containment

| Mechanism | Historical evidence | Current disposition |
|---|---|---|
| Reservation/allocated distinction | `1058e40c96` introduced existing-token allocation; `55e74fe2af` moved consumption and exception rollback; resource-manager migration preserves token/mutex design | Existing-token defense is retained. Current post-allocation handoff questions require independent evidence |
| Broad versus narrow lifecycle serialization | `a6dcce63ed` serialized launch/register/status; `6f75707f34` narrowed broad locks | Current status gaps are inspected directly; no pre-fix code is recreated |
| Wrong job from shared sticky context | [5215](https://github.com/NVIDIA/NVFlare/issues/5215), fixed by pinned `e120606196`; earlier `1b009bdcc5` fresh-context repair was insufficient | Explicit event ID and guarded scheduler membership retained; remaining metrics attribution is known and excluded |
| Early abort visibility | Pinned `cb784550b8` and `a18489e436` cover STARTING and pending handles | Do not assert lost abort before handle attachment; post-spawn cleanup ownership is a different boundary |
| Server failure versus pending client outcomes | [5115](https://github.com/NVIDIA/NVFlare/issues/5115), [5220](https://github.com/NVIDIA/NVFlare/issues/5220), fixed by `21253dddc4`/`535373a082` | Heartbeat cleanup and authoritative-failure bypass retained; old failures are not MC targets |
| Startup policy/timeout ambiguity | Historical deploy delay [3730](https://github.com/NVIDIA/NVFlare/issues/3730); pinned `f8efaeb78c` handles timed-out deploy sites and strict/non-strict policy | Actual configurable policy preserved; permitted partial startup is not automatically a defect |
| Admission exceptions and retry starvation | Open [5191](https://github.com/NVIDIA/NVFlare/pull/5191) | Known overlap; not a new discovery or a new model hunt |

The supplemental consumer/launcher history is fully preserved in [consumer-launcher-history.diff](evidence/consumer-launcher-history.diff). The consumer's shared environment assignment dates to `8693f5f2`; launcher refactors continue to snapshot the environment. No reviewed history/discussion established that the newly identified consume/snapshot or status-publication interleavings are already resolved. This is a bounded novelty search, not a guarantee that no unpublished or uncollected report exists.

### PR 5191 status

On 2026-09-14 the live API and browser showed **OPEN, unmerged**, head `27ecde2ab85b38734072b90128dc5dc2e8390882`, last updated `2026-08-26T23:20:32Z`. All three conversation comments, seven submitted reviews, nine inline comments and five changed-file patches were read. Its proposed admission cleanup and retry changes are separate from this pin. [PR 5191](https://github.com/NVIDIA/NVFlare/pull/5191)

The [specified maintainer comment](https://github.com/NVIDIA/NVFlare/pull/5191#issuecomment-5432240101) supports centralized cleanup but disputes aborting a scheduling pass merely because cancellation acknowledgement is absent. Its requested verify/log/continue behavior remains a proposal. The pinned source independently confirms that expiry owns abandoned reservations; allocated payloads have already left the expiry map. Neither missing acknowledgement nor a roughly 30-second discussion estimate proves a permanent leak or a hard real-time bound.

### Deep issue dispositions

The 33 issues are individually documented in the linked batch reports. Mechanism counts are not issue counts: 3822/3830, for example, concern related Flower cleanup behavior. High-value exclusions include user-side version mismatch (3877), code indentation (3060), missing server dependency (2601), host/environment exhaustion (2326's primary report), and configured admin timeout (316's primary report). Expected behavior explains 2559's capacity units and 1336's workspace placement. Unconfirmed reports such as 3196/3197, 1371, 1433 and 849 were not upgraded from a shared symptom or CLOSED label into a defect. Old initialization END_RUN behavior in 1221 is fixed; transport WAIT_UNTIL behavior cited in 1821 is absent at the pin. These exclusions constrain the model rather than supplying answer-key faults.

## Phase 3: verified new candidates and remaining review questions

### MC-1 — Resource binding can diverge from disjoint allocation ownership

**Strength/ranking:** strongest current interleaving candidate; high source confidence, local execution and model validation pending. **Scenario 1.**

1. A and B are distinct valid jobs. Site-2 has exclusive IDs 0 and 1; server concurrency permits two jobs. A also has an acknowledged required site-1, satisfying the selected minimum.
2. A's site-2 handler successfully transfers its reservation to allocation 0, then the consumer writes selection 0. It is delayed in ordinary preparation before the launcher's environment copy (`scheduler_cmds.py:115-128`; `client_executor.py:221-298`).
3. The server's site-2 START wait expires while the handler continues. Other replies let the selected startup policy proceed. A later scheduling pass admits B against remaining ID 1 (`server_engine.py:1082`; `job_runner.py:345-360,641-657`).
4. B's consumer writes selection 1. Both launchers may snapshot selection 1, although their cleanup payloads still say A owns 0 and B owns 1 (`list_resource_consumer.py:31-37`; `process_launcher.py:68-81`).

The resource mutex preserves deque uniqueness but does not cover consume→snapshot. A child has not been given a per-job environment derived from its allocation. TTL cannot fix this because A's allocation already left the reservation map. Pending handles only serialize same-job registration and save abort intent. Transport correlation associates replies correctly but does not revoke a timed-out callback. Normal eventual exit/free of B could expose the unit still selected by A.

**Observable boundary:** child resource-selection environment versus allocation payload, and later free capacity. GPU execution, actual GPU memory use and workload degradation were not tested. The model should derive concurrent starts through supported timeout/admission behavior and inspect bindings; it should not add arbitrary duplicate commands. A later local check can observe inherited IDs without running GPU computation.

### MC-2 / TV-1 — Post-spawn waiter failure invokes pre-spawn rollback

**Strength:** high confidence in source ownership gap; specific ordinary runtime failure requires controlled confirmation. **Scenario 2.**

`JobExecutor.start_app` creates the child at line 309, attaches the handle at 318, then starts the cleanup waiter at 334. A failure to start that thread propagates to `StartJobProcessor`'s exception handler, which frees any allocated payload (`scheduler_cmds.py:129-133`) without terminating or waiting for the already spawned child. The child registration persists, but no waiter was created to own exit/free/removal. Another job can see returned capacity while the child remains alive.

Later heartbeat/abort can terminate the child, but does not undo the earlier unsafe availability interval or automatically install the missing waiter. This specific path does **not** prove double free: waiter creation failed. Double free would require a separate supported path where both rollback and a running waiter release the allocation.

**Required fidelity:** preserve the production dispatcher. Ordinary AFTER_JOB_LAUNCH handler exceptions are caught at `apis/utils/event.py:74-82`; a fake engine that propagates them is not a valid trigger. Do not substitute a custom launcher that spawns then raises for the selected default backend. The focused fault point is ordinary cleanup-thread creation after a real local spawn. No such fault was executed here.

### MC-3 — Successful pre-run abort can be overwritten by later startup

**Strength:** high source confidence; supported admin API and independent admission thread. **Scenario 3.**

JobRunner's SUBMITTED and DISPATCHED rechecks (`661,697`) occur before deployment/start and before unconditional status writes (`670,711`). Meanwhile `JobCommandModule.abort_job` handles a stored SUBMITTED/DISPATCHED job by storing FINISHED_ABORTED and returning success, without invoking stop or setting the in-memory `run_aborted` flag (`job_cmds.py:1059-1066`).

If abort occurs after a successful recheck but during deployment/start, the runner can subsequently overwrite it with DISPATCHED/RUNNING and launch/retain the process. Earlier aborts are caught by the rechecks; those checks do not cover the later interval. Completion at some future time does not make the acknowledged pre-run abort effective. Model status reads and their subsequent actions separately, including whether a process has already been created when abort is acknowledged.

**Impact boundary:** possible execution after a successful pre-run abort and loss of the abort status. No race-controlled local reproduction has been performed. The property concerns an acknowledged abort and cleanup obligation, not immediate synchronous termination of every stop request.

### MC-4 — Completion can remove a job before stale RUNNING publication

**Strength:** high source confidence; requires a quick exit or delayed startup/store publication. **Scenario 3.**

`JobRunner.run` inserts `running_jobs[job_id]` under its lock (`709-710`), releases it, and only then calls `set_status(RUNNING)` (`711`). An independent server waiter may already have removed the exited process. The completion loop can observe the runner entry, satisfy or bypass client outcomes, save terminal status (`524`), remove the runner state (`531-535`) and release scheduler membership (`537-538`) before the delayed RUNNING write.

`SimpleJobDefManager.set_status` does not compare expected status or reject resurrection (`apis/impl/job_def_manager.py:459-481`). Its built-in metadata update is an unconditional read/update/write (`filesystem_storage.py:251-275`). With the runner entry removed, no regular completion iteration remains to repair the stale persistent RUNNING status. The outcome and archival grace only add delay; they do not order completion after RUNNING publication. A quick authoritative server failure can bypass the normal client-outcome wait.

**Impact boundary:** RUNNING stored for a job with no tracked/live server job and with a released scheduler slot. This differs from the already-fixed server failure waiting for missing client outcomes. HA/startup reconciliation is outside scope and is not a live compensator.

### TV-2 — An ordinary error in failure handling can stop later admission

`JobRunner.run` has no outer recovery guard around candidate retrieval/recheck (`650-661`), and its startup exception branch does not guard stop, FAILED_TO_RUN publication or deploy-detail update (`719-725`). An ordinary metadata I/O error can therefore escape the thread; `server_deployer.py:136,144-145` starts it without a restart wrapper. Recovery of the store later does not restart that ended thread. If JOB_STARTED already ran, an escaped error can also skip JOB_ABORTED and its slot removal (`728`).

This is outside #5191's scheduler-only exception boundary. Prefer a local test with finite store failures, service-thread survival and a second eligible job, rather than treating permanent store failure as a violation of unconditional progress. No test was run.

### TV-3 — Two removals can end the completion loop

After runner insertion, a RUNNING write can fail and the startup catch removes the entry (`709-717`). Completion may already have retained the same Job reference (`446-447`) and later executes unconditional `del self.running_jobs[job_id]` (`532`). The lock serializes deletions but does not make the second deletion conditional. KeyError can escape the completion loop, which has no encompassing per-job/loop catch (`441-541`), preventing later jobs from completing through that service.

This needs both the interleaving and a finite ordinary status-store error. Existing archival/publication retries do not cover the deletion. It is a targeted controlled-fault/interleaving test candidate, not a confirmed service outage.

### Code-review-only ledger

| ID | Verified source observation | Compensation / remaining obligation | Disposition |
|---|---|---|---|
| CR-1 | StartJobProcessor frees only exceptions, but ClientEngine returns on already STARTED or missing app (`scheduler_cmds.py:114-137`; `client_engine.py:357-367`) | Same-token repeat fails before this branch. Fresh allocation for an already-running job needs a supported second attempt; arbitrary workspace deletion is excluded. | Retain branch asymmetry, unconfirmed full-chain trigger; no MC hunt yet |
| CR-2 | Server abort calls terminate then removes engine entry even on error (`server_engine.py:385-409`); local terminate only signals and logs failures (`process_utils.py:293-316`) | Same-user local process has no established persistent signal-failure trigger here; server capacity is assumed unlimited. Do not equate all OS processes with scheduler slots. | Contract/error-retention review or focused local fault test, no proven permanent leak |
| CR-3 | ListRM availability compares counts, then dequeues per key before token insertion; a later incompatible count may raise after mutation (`list_resource_manager.py:57-76`; `auto_clean_resource_manager.py:128-131`) | General validation preserves custom fields (`job_meta_validator.py:265-284`; `job_launcher_utils.py:263-323`); absent token means TTL cannot repair partial mutation. Validate supported input contract first. | Invalid-input functional robustness; prevalidate counts or rollback. Not an arbitrary malformed-input MC adversary |
| CR-4 | STARTED notification has configured 15 s retry timeout, but deadline branch only logs and continues (`client_app_runner.py:65-80,171-222`) | Finite delay can recover; independent abort/heartbeat can stop a child. No unconditional progress with permanently unavailable parent is required. | Reconcile documented retry bound; low-priority local deadline test |
| CR-5 | Non-strict reply checker ignores non-OK header while docstring says otherwise (`server/admin.py:89-99,133-137`) | Most StartJobProcessor errors are ERROR-prefixed bodies; ordinary valid selected-path header-only producer needs verification. Generic admin error replies use headers (`admin_defs.py:78-83`). | Source/doc/response-shape review; no claimed selected-path false success yet |
| CR-6 | Empty `get_job_clients` result becomes all connected clients on server launch (`server_engine.py:296-338`) | Requires selected clients disconnecting during startup; later reply-count/policy failure and stop may compensate. No wrong-job allocation consequence established. | Participant snapshot review, no MC promotion |

All CR entries are retained for later audit rather than filtered by a predicted low-impact verdict. Conversely, a KeyError alone from `fail_run` clearing `_pending_client_outcomes` while `_start_run` intersects it (`job_runner.py:359-360,841-842`) is not promoted: the outer startup failure path can still stop and mark the job failed. A new claim would need observable downstream damage beyond that expected failed-start outcome.

## Explicit exclusions and compensating mechanisms

| Suspected claim | Why it is not established / what must remain faithful |
|---|---|
| Expiry/cancel frees an allocation or allocates a stale token from available capacity | All operations share the RM lock; allocation pops the reservation and missing token raises. Expiry/cancel only inspect reservations (`auto_clean_resource_manager.py:102-164`). |
| Lost cancel acknowledgement is a permanent leak | Built-in TTL remains cleanup owner for reservations. Pinned engine ignores cancellation replies (`server_engine.py:1052-1066`); that is different from abandoned allocations. |
| Optional failed deployment must fail the whole job | Deployment applies minimum/required policy. Failed optional sites can be excluded, with their unallocated reservations left for expiry (`job_runner.py:250-282,692-695`). |
| Non-strict start timeout necessarily violates min_sites | The default explicitly does not enforce these thresholds again at start; documented at `timeout_troubleshooting.rst:300-304`. Evaluate strict and non-strict separately. |
| Component exception necessarily aborts admission/start | Production dispatcher catches and records ordinary handler exceptions; simplified throwing mocks are not equivalent (`apis/utils/event.py:54-82`). |
| Early abort before a launcher returns is lost | Pinned pending-handle registration and deferred abort are present (`client_executor.py:52-91,299-320`). |
| STOPPED or abort reply directly frees units | Client STOPPED retains a handle; abort requests termination but normal free is owned by the exit waiter (`client_engine.py:390-404`; `client_executor.py:486-688`). |
| Repeated abort/completion necessarily double-frees | Abort does not call free, ordinary same-job registration is guarded, and one waiter owns free. RM free is not idempotent, but duplicate caller ownership must be established. |
| Lost terminal report or RC-file parse error skips free | Report failures are caught (`client_executor.py:648-679`); RC-file errors fall back (`fed_utils.py:547-564`). |
| All client-outcome or archival delays are permanent scheduler leaks | Normal outcome wait has configured deadline; server failure bypasses it. Archival errors have per-job 60 s grace; metadata publication errors retry (`job_runner.py:448-530`). These do not excuse an ended service thread. |
| Late reply changes the next job's reservation/result | Request waiter ID and destination map preserve correlation; late replies without a waiter are dropped (`core_cell.py:1512-1574,1986-2028`; `message_send.py:22-35,68-110`). Delayed execution is a separate concern. |
| Shared CURRENT_JOB_ID still selects the wrong lifecycle event job | Explicit event data takes precedence; dispatcher resets it per handler; scheduler operations are membership-guarded (`job_utils.py:111-123`; `job_scheduler.py:275-285`). Fixed history is reference only. |
| Repeated job notifications can be arbitrarily reordered across attempts | No asynchronous event queue or supported fresh START retry of an active same-ID job was established. Model real publishers/attempts; client reports use explicit job/client pending pairs (`fed_server.py:925-956`). |
| Runner/engine locks obviously deadlock by inversion | `fail_run` nests runner→engine, while completion releases engine before taking runner (`job_runner.py:448-455,815-816`); the suspected inverse nesting is absent. |
| One completed job's global engine STOPPED means another job lost its slot | Engine info is recomputed from run_processes (`server_engine.py:142-159`); a transient display flag alone is not scheduler/resource corruption. |
| Old fixed initialization, return-code, transport, or Flower bugs are fresh model targets | Their implemented/removal compensations are retained; external trainer/Simulator/backend conclusions do not establish selected production-chain behavior. |

## Required-question and interaction coverage

| User priority | Investigated result and handoff |
|---|---|
| Q1: expiry/cancel versus delayed start | Reservation transfer is serialized and stale token rejected. Allocation-to-process binding remains a separate strong MC-1 question. Preserve TTL after lost replies and absence of TTL after allocation. |
| Q2: partial deployment/start and cleanup owner | Exact policy table above; optional failures need not abort. MC-2 targets post-spawn cleanup transfer; CR-1 is returned-error asymmetry with an unresolved supported trigger. No permanent reservation leak inferred from deployment exclusion. |
| Q3: abort/normal completion/child exit | Normal client free follows real wait, not logical status. MC-2 investigates premature rollback; CR-2 records weaker server abort observation. Repeated notifications alone do not show double free. |
| Q4: delayed replies/repeated events with another job | Request IDs, job IDs, pending pairs and idempotent scheduler membership compensate wrong-job corruption. MC-3/MC-4 concern current same-attempt status publication, not restoration of fixed event-ID confusion. |
| Q5: failed first job blocks eligible later job | #5191 is known; normal TTL/backoff/pass retry remain. TV-2/TV-3 target additional runner service-error boundaries. Progress is conditional on satisfiable resources and eventual functioning store/transport/cleanup, not perpetual site failure. |

All must-cover chains were followed: DefaultJobScheduler↔JobRunner↔ServerEngine resource/cancel/deploy/start requests; client processors↔ClientEngine↔JobExecutor↔ListResourceManager/consumer↔local process/waiter; resource TTL/cancel/allocation/free; lifecycle event dispatch into scheduler bookkeeping; server/client outcomes, heartbeat cleanup and job metadata APIs.

## Existing-test audit and downstream verification recommendations

Tests were read, not run. The user-listed suites cover useful local branches but do not establish the complete chain:

| Suite | Existing evidence and limitation |
|---|---|
| `tests/unit_test/app_common/job_schedulers/job_scheduler_test.py` | Scheduler policy/retry/event-ID tests; dummy resource manager and no-op event engine in main fixtures. No production TTL/allocation/child chain. |
| `tests/unit_test/app_common/resource_managers/list_resource_manager_test.py` | Sequential reserve/cancel/allocate/free, two reservations in reversed allocation order, cancelled capacity reuse, one mocked expiry tick. No concurrent consumer/launcher binding. |
| `tests/unit_test/private/fed/server/job_runner_deploy_test.py` | Stubbed timeout/minimum/optional-failure cases; integration-named test manually filters and invokes start, without concurrent production admission/completion/admin loops. |
| `tests/unit_test/private/fed/client/scheduler_cmds_test.py` | One CheckResourceProcessor exception-diagnostic test; no StartJobProcessor cleanup accounting. |
| `tests/unit_test/private/fed/client/client_executor_test.py` | Pending handle, abort/STOPPED, launch failure, status/return-code/report handling; mostly mock handles. Report-failure cleanup tests supply no allocation, so do not prove capacity restoration. |
| Adjacent JobRunner/event/store/process tests | Some real event-dispatch and strict reply-check paths, mocked launch/process operations, outcome/archival/status retries. None inspected coordinates the complete MC-3/MC-4 status window with admission and completion. |

Recommended order for Spec Generation: build the faithful reservation/start/exit base, then MC-1, MC-3/MC-4, and MC-2 with its focused ordinary-fault test. Preserve event dispatch, request correlation, participant semantics and TTL rather than simplifying them into desired invariants. Split actions at observed locks, request boundaries and status writes; do not make an entire high-level start atomic.

For later trace conformance, record job ID, admission attempt/token, site, request/waiter identity, allocated units, consumed resource selection, child environment snapshot/handle, actual process exit, report outcome, free and metadata publication. A server-issued command, a reply, child check-in, terminal status and physical cleanup are different trace events. A trace matching a model is conformance evidence, not proof of the candidate; a finite TLC run is bounded state-space evidence, not a production verdict.

Condition progress on fair reservation ticks, eventual completion or effective stop of the owned local process, eventual usable communication/store, and a genuinely eligible next job below configured limits. Preserve short startup failures, delayed callback execution and finite I/O errors. Unbounded waits caused by permanently unavailable sites do not justify unconditional eventual-start claims. All proposed MC questions are forward-looking current-source mechanisms; none asks to recreate a closed historical fix.

## Evidence index

- [Modeling brief](modeling-brief.md): seven-section Scenario handoff with four MC questions, three test items and six CR entries.
- [Complete core commit ledger](evidence/history-audit.md), [raw inventory](evidence/history-inventory.json), [review ledger](evidence/history-review-ledger.json), and `evidence/history-diffs/`: all 248 screened path-history entries.
- [Adjacent consumer/launcher history](evidence/consumer-launcher-history.diff): ten complete path-history patches.
- [Collected issue union](evidence/issues-collected.json), `evidence/issues-search-0.json` through `issues-search-9.json`, [open PR snapshot](evidence/open-prs.json).
- [Issue/PR audit A](evidence/issues-a.md) and `evidence/issues-a/`: 13 issues, all open PR inventories, nine additional resolution discussions, exact #5191 records.
- [Issue/PR audit B](evidence/issues-b.md) and `evidence/issues-b-raw/`: 20 issues, eight additional full resolution discussions.
- [Client audit](evidence/deep-client.md), [runner/event audit](evidence/deep-runner.md), [resource/server audit](evidence/deep-resources-server.md): detailed independent source findings, compensations, full-read boundaries and tests inspected.
