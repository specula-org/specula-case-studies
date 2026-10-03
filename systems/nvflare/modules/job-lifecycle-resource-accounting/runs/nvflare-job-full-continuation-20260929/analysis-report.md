# Analysis Report — NVFlare job lifecycle and resource accounting (nvflare-job)

Audit trail for the Specula **code-analysis** phase. The handoff document is `modeling-brief.md`; this report keeps the
evidence, coverage statistics, verification commands and exclusions behind it.

- Target: NVIDIA FLARE, Python. Pinned source `53ba7ee567468ea7971dad4faccef13c6cb35dc2` (2026-09-11), checkout
  `full/source`. Imports were confirmed to resolve to this checkout:
  `python3 -c "import nvflare; print(nvflare.__file__)"` → `.../full/source/nvflare/__init__.py`.
- Scope, from the target guidance: the default local-process launch path, covering resource reservation, deployment,
  startup, termination and cleanup across the server and participating clients. It also covers adjacent callers and
  exception handlers that decide resource ownership, job status and admission of later jobs.
- Excluded: training aggregation, model transfer, GPU computation, alternative launchers (docker/k8s/slurm) and HA
  recovery.
- Methodology: `skills/code-analysis/guide.md` plus `references/{bug-archaeology,deep-analysis,distributed-analysis,
  concurrent-analysis,modeling-brief-format}.md`, and `bug-confirmation/references/persistent-findings.md` for lookup.

---

## 0. Sources, restrictions and environment limits (read first)

| Item | Handling |
|---|---|
| Allowed sources | Pinned source and its reachable Git history, the installed Specula methodology, and dependency/tool docs. No GitHub issue/PR pages, web lookups, prior Specula case studies or runs, or the other arm's files were used. |
| History boundary | All mining used `git log HEAD` / `git rev-list HEAD` (3305 commits). `refs/remotes/origin/main` (7636087a, 2026-09-23) is **newer than the pin** and was never used. `--all` reaches 4085 commits and was not used. Every cited commit was checked as an ancestor of HEAD. |
| **Historical diffs unavailable** | `full/source/.git` has no local objects. Its alternates point to `/home/experiment/repos/nvflare/.git/objects`, a **partial clone** (`remote.origin.promisor=true`, `partialclonefilter=blob:none`). `git rev-list --objects --missing=print HEAD` reports 20 550 missing objects. `git show <sha> -- <core paths>` fails for **all 405** core-path commits (`evidence/archaeology/unreadable-diffs.txt`). Commit objects (full messages / PR bodies), trees (name-status) and HEAD blobs are available. |
| Decision on the limit | No lazy or explicit fetch was attempted: it would mean network access to the upstream host, could pull post-pin objects, and is an outward-facing action. Every commit was classified from its full message body, its touched-file list, and the current HEAD code and tests. This limitation is carried into all archaeology statistics below. |
| GitHub issues/PRs | **Not consulted** (not a permitted source). The skill's "30+ issues deeply read" target therefore reads N/A. PR numbers appear only as they occur in squash-merge subjects. |
| Persistent findings | `persistent-findings-context.json` has `previous: null` and no inherited records. `specula findings lookup` for abort_job, set_status, JobRunner.run, delete_job, _check_job_status, free_resources and notify_job_status returned `[]`. |
| Product source | Unmodified. All harnesses live under `.specula-output/evidence/harness/`, import the pinned modules, and stub only network/process edges. They use documented reproduction controls that only choose *when* a concurrent operation happens. |

---

## 1. Phase 1 — Reconnaissance

### 1.1 Category

**Category A (Distributed / Message-Passing), with intra-process thread interleavings.** The lifecycle is a protocol
between a server parent (SP), N client parents (CP) and per-job processes (server job SJ, client job CJ). It uses CellNet
request/reply RPCs with timeouts and no-reply semantics (CHECK_RESOURCE, CANCEL_RESOURCE, DEPLOY, START_JOB, ABORT,
REPORT_JOB_FAILURE, heartbeat with job IDs, UPDATE_RUN_STATUS). The failures that matter are message loss or timeouts,
process exit or crash, and client disconnect.

Inside SP and CP, several threads also mutate shared dictionaries and a job store without a single serialization point.
Model it distributed-style (actors, messages, crash/exit), and split handler steps at the check-then-act boundaries
listed in §1.4.

### 1.2 Default configuration on the local path

From `evidence/contracts.md` §1:
- **Client:** `GPUResourceManager(num_of_gpus={num_gpus}, mem_per_gpu_in_GiB={gpu_mem}, expiration_period=300)`, with
  both placeholders 0 unless the project sets capacity; POC defaults to 0/0. Also `GPUResourceConsumer` and
  `ClientProcessJobLauncher` (`nvflare/lighter/templates/master_template.yml:61-99`). The reservation-expiry tick is
  `check_period=1.0` (`auto_clean_resource_manager.py:27`); the class default `expiration_period` is 30.
- **Server:** `DefaultJobScheduler(max_jobs=4)` (class defaults are `max_jobs=1, max_schedule_count=10,
  min_schedule_interval=10, max_schedule_interval=600`), `SimpleJobDefManager`, `FilesystemStorage` and
  `ServerProcessJobLauncher` (`master_template.yml:182-240`). There is no server resource manager ("we are assuming
  server resource is sufficient", `job_scheduler.py:178`).
- **Portable CPU/memory** are stripped before admission (`job_launcher_utils.py:311-323`). Only positive GPU requests and
  site-specific keys reach the resource manager.

### 1.3 Core files (in-scope logic ≈ 11 k LOC across 20+ files; key ones read in full)

| Component | File (LOC) | Role |
|---|---|---|
| Server runner | `nvflare/private/fed/server/job_runner.py` (869) | `run()` scheduling loop (schedule → deploy → start → RUNNING), `_job_complete_process` finalization thread, `stop_run`/`fail_run`/`stop_all_runs` |
| Scheduler | `nvflare/app_common/job_schedulers/job_scheduler.py` (388) | `DefaultJobScheduler`: admission (`max_jobs` via `scheduled_jobs`), `_try_job`, reservation cancel on rejection, back-off/give-up |
| Server engine | `nvflare/private/fed/server/server_engine.py` (1115) | `run_processes`/`exception_run_processes`, SJ launch, `wait_for_complete`, `abort_app_on_server`/`_remove_run_processes`, CHECK/CANCEL/START fan-out |
| Server comms | `nvflare/private/fed/server/fed_server.py` (1253) | UPDATE_RUN_STATUS/HEARTBEAT from SJ, client heartbeat job sync, `process_job_failure`, dead-client sweeper |
| Admin commands | `nvflare/private/fed/server/job_cmds.py` (1827; lifecycle handlers) | `abort_job`, `delete_job`, `submit_job`, `list_jobs` |
| Job store | `nvflare/apis/impl/job_def_manager.py` (593), `app_common/storages/filesystem_storage.py` | `set_status` (no transition guard), `update_meta` read-modify-write, scheduling scan |
| Client handlers | `nvflare/private/fed/client/scheduler_cmds.py` (184), `training_cmds.py` (213) | CHECK/START/CANCEL resource handlers; ABORT, DEPLOY, DELETE_RUN, NOTIFY_JOB_STATUS |
| Client engine / executor | `client_engine.py` (527), `client_executor.py` (696) | `start_app` (string-return errors), `JobExecutor` launch registration, `_PendingJobHandle`, abort, process-exit waiter that frees resources |
| Resource managers | `app_common/resource_managers/{auto_clean,list,gpu,passthrough}_resource_manager.py` | reservation tokens with tick expiry, allocate pops reservation, free without ownership check |
| Local launcher | `app_common/job_launcher/process_launcher.py`, `nvflare/utils/process_utils.py` | `posix_spawn(setsid)`; `terminate()` = `killpg(getpgid(pid))`; exit-code mapping {0,1,9} |
| Job-process side | `client_app_runner.py`, SJ/CJ mains (`app/server/runner_process.py`, `app/client/worker_process.py`) | STARTED/STOPPED notification to CP; rc file; UPDATE_RUN_STATUS |

### 1.4 Concurrency model and atomicity boundaries

**Server parent threads**
- `JobRunner.run` is one thread with a 1 s tick. It is started once with no guard or restart
  (`server_deployer.py:136,144-145`).
- `_job_complete_process` is one thread with a 1 s tick.
- Admin command threads.
- Cell handler threads: client heartbeat → `_sync_client_jobs`, `process_job_failure` → `fail_run`/`stop_run`, SJ
  `_listen_command`.
- One `wait_for_complete` thread per SJ; `_remove_run_processes` threads after an abort.
- The `client_cleanup` dead-client sweeper, whose loop has no try/except.

**Client parent threads**
- Admin request handlers on CellNet worker threads, so they may run concurrently.
- The heartbeat thread, which aborts jobs the server does not know.
- One `_wait_child_process_finish` thread per CJ; `_terminate_job` threads.
- The `AutoCleanResourceManager` expiry thread with a 1 s tick, started by `SYSTEM_START` (`client_train.py:218`).

**Locks**

| Lock | Guards | Notes |
|---|---|---|
| `JobRunner.lock` | `running_jobs` writes, `_pending_client_outcomes`, `_client_outcome_deadlines` | Many reads are unlocked, e.g. `list(self.running_jobs.keys())`. |
| `ServerEngine.lock` | `run_processes`/`exception_run_processes` in some sites | Iteration sites (`stop_all_runs` :856, `notify_dead_client` :1109) are unlocked. |
| `FederatedServer.lock` | UPDATE_RUN_STATUS writes to `run_processes[...]`/`exception_run_processes` | A *different* lock from `ServerEngine.lock` (`fed_server.py:596`). |
| `DefaultJobScheduler.lock` | `scheduled_jobs` | — |
| `JobExecutor.lock` | CP `run_processes` | — |
| `AutoCleanResourceManager._lock` | pool and reservations | — |
| (none) | job store status | `FilesystemStorage.update_meta` is an unlocked get-merge-write (`filesystem_storage.py:251-275`). |

**Check-then-act boundaries that the model must split**
- Runner, `job_runner.py`: status check SUBMITTED (:661) → deploy (:669) → write DISPATCHED (:670) → check DISPATCHED
  (:697) → `_start_run` (:703) → `running_jobs` insert (:709-710) → write RUNNING (:711).
- Admin `abort_job`, `job_cmds.py:1059-1066`: read status → blind write FINISHED_ABORTED.
- Completion thread: finalize and `set_status(terminal)` (:523-524) → delete from `running_jobs` (:531-535) → events
  (:536-538).
- CP start: `allocate_resources` pops the reservation (`scheduler_cmds.py:116`) → `ClientEngine.start_app` returns an
  error *string* or launches (`client_engine.py:357-382`) → the process-exit waiter frees
  (`client_executor.py:676-679`).

---

## 2. Phase 2 — Bug archaeology

### 2.1 Coverage

Five parallel archaeology workers covered every commit reachable from HEAD that touches the 27 core paths
(`evidence/archaeology/core-paths.txt`). Per-commit logs are in `evidence/archaeology/batch-{1..5}.md`, each marked
`STATUS: COMPLETE`.

| Batch (lines of core-commits.txt) | Period | Commits | (a) in-scope fixes | (b) in-scope semantics changes | (c) out of scope | undetermined |
|---|---|---:|---:|---:|---:|---:|
| 1 (1-100) | 2021-11 .. 2022-06 | 100 | 23 | 17 | 59 | 1 |
| 2 (101-200) | 2022-06 .. 2023 | 100 | 19 | 14 | 64 | 3 (mechanism unrecoverable) |
| 3 (201-300) | 2023 .. 2025-02 | 100 | 9 | 12 | 79 | 0 |
| 4 (301-360) | 2025-02 .. 2026-07 | 60 | 9 | 10 | 41 | 0 |
| 5 (361-405) | 2026-07 .. 2026-09 | 45 | 18 | 4 | 23 | 0 |
| **Total** | | **405** | **78** | **57** | **266** | **4** |

Two caveats apply to every row:
- **No historical diff was readable** (§0). Every classification rests on the commit body, the touched-file list and
  the HEAD code/tests.
- Mechanisms stated for historical fixes are therefore inferences. The body text is usually detailed for the
  2025-2026 squash merges and sparse for 2022.

GitHub issues and PRs: not consulted (0 read; not a permitted source).

**Hotspots** (count of the 78 in-scope fixes touching each file; `git diff-tree --name-only` over
`evidence/archaeology/in_scope_fixes.txt`):

| File | Fixes |
|---|---:|
| `job_runner.py` | 37 |
| `server_engine.py` | 24 |
| `client_executor.py` | 20 |
| `fed_server.py` | 18 |
| `fl_constant.py` | 9 |
| `job_def.py` | 8 |
| `scheduler_cmds.py`, `client_engine.py`, `worker_process.py`, `job_scheduler.py` | 7 each |
| `job_cmds.py` | 6 |
| `fed_utils.py`, `server_runner.py`, `mpm.py` | 5 each |

The server runner/engine pair is the dominant bug locus. 2026 alone has 86 core-path commits, including 18 in-scope
fixes in the last two months before the pin.

### 2.2 Historical mechanism groups (evidence of bug-proneness; reference, not targets)

**H1 — Competing or mistimed status writers / check-then-act on job status.**

| Commit | Summary |
|---|---|
| a6dcce63 | Admin status change vs runner done as check-then-act |
| def5c04c | Delete had no status guard |
| bb840df0 | FINISHED_ABORTED written at abort time, not at exit |
| 9f49a109 | — |
| 9e1881da | Wrong state after abort then restart |
| 8bb1b84c | Abort before SJ could accept commands |
| e3568925 | Aborted status published before archival |
| 6d193a24 | Abort paths racing the completion loop |
| 1b009bdc | Completion used the scheduler's context |
| e1206061 | Sticky `CURRENT_JOB_ID` → wrong-job accounting → stale `scheduled_jobs` blocked admission |

Recent fixes made publishers carry an explicit job id and ordered publication after archival. **No fix introduced a
transition guard in `set_status`** (it is still a blind merge, `job_def_manager.py:459-481`).

**H2 — Final status built from missing, late or asynchronous failure signals.**

| Commit | Summary |
|---|---|
| 2c89c887 | — |
| 508c7d23 | — |
| 8a3e3cb0 | — |
| b25e6bd3 | — |
| 6bc40bb5 | — |
| d3e32795 | — |
| df92fab4 | — |
| a0d75eaa | — |
| a060c60f | Return-code file introduced |
| 4327d7c3 | Empty rc file aborted exit cleanup → permanent client capacity loss |
| 1f39ccf8 | Every client failure report dropped |
| 924998da | Authoritative failure code overwritten by the SJ exit code |
| 46cfc517 | Server finalized before client outcomes |
| 535373a0 | — |
| 196a3fdd | — |
| 52c966d1 | — |
| 00589c73 (b) | INFRASTRUCTURE_ERROR precedence |

**H3 — Abort not reaching every process / abort intent dropped in a window.**

| Commit | Summary |
|---|---|
| db90aff6 | — |
| cb1d5354 | — |
| 72eb5462 | — |
| a8265f1d | — |
| 03789dd9 | — |
| 1571296f | — |
| 7e9d036a | — |
| cb784550 | STARTING not covered by the client abort guard |
| a18489e4 | Registration after launch dropped abort → `_PendingJobHandle` |
| 9b5dddfd | STOPPED treated as exited; late exits overrode abort |

The client side is now thoroughly guarded. The **server-side** analogue (the DISPATCHED/start window) was not changed
(see F1).

**H4 — Resource lifetime not closed on every exit path.**

| Commit | Summary |
|---|---|
| 1058e40c | Reservations had no expiry → AutoClean expiry introduced |
| 975dc146 | Cleanup thread not run |
| 327be8ff | Allocation not handed to the exit free path (inferred) |
| 15bebb31 | Server start ok + client start failed left the SJ running and a slot held |
| 4327d7c3 | — |
| a6616c8a | Exception before `_cancel_resources` leaked reservations |
| 82fec3f7 | Failed check read as enough |
| 9a822f93 | — |
| 03b56e8b | GPU manager ignored `CUDA_VISIBLE_DEVICES` |
| ce966f2d | Portable spec regressions |

The runner-side skip/failure paths were never given cancellation; they rely on expiry (F6).

**H5 — One bad job or one exception stalls scheduling for everyone.**

| Commit | Summary |
|---|---|
| 5535bdb7 | A job the scheduler cannot process made scheduling raise; fixed only at submit |
| 3225529d | Scheduler loop started twice |
| 38fa2c75 | Scan raced writers |
| 47684966 | Malformed mandatory-clients entries aborted the whole scheduling pass |
| 6608949c | Unbounded archival retry held the slot |
| 71fbcaae | rc write failure skipped `os._exit` |

The 47684966 fix is incomplete: F2 and F4 are open instances.

**H6 — Live-collection iteration under concurrent mutation.**

| Commit | Summary |
|---|---|
| 58eb05f6 | Job table iterated while other threads add/remove entries |

Open sites remain at `job_runner.py:856` and `fed_server.py:1109` (F7).

**H7 — Partial deploy/start vs `min_sites`/`required_sites` policy.**

| Commit | Summary |
|---|---|
| df539aab | One site's deploy rejection failed the whole deploy |
| 365da018 | — |
| a8ee3c2b | — |
| eaf1b5ba | — |
| 39c247d3 | `@ALL` expansion |
| f8efaeb7 | Deploy timeout counted as success; strict start aborted jobs meeting `min_sites`; dead-job before first report |

### 2.3 Contracts established by recent fixes (from batch 5; anchors in HEAD tests)

These are the property anchors used for the proposed invariants:

1. **Abort intent** is preserved from client registration onward (client_executor_test.py:55-146,184-321).
2. **Single launch ownership:** one registration per job id.
3. **Terminal status ordering:** publish only after every active client outcome, unless the 900 s grace elapsed, an
   admin abort occurred, or an authoritative server failure exists (job_runner_test.py:885-1063).
4. **Failure before barrier release:** a reported failure is applied before the outcome barrier is released; late or
   duplicate reports are idempotent.
5. **Status precedence:** `run_aborted` > INFRASTRUCTURE_ERROR > other failure codes > launcher ABORTED; a clean
   UPDATE_RUN_STATUS never masks a recorded failure (job_runner_test.py:586-768).
6. **Actionable client exits are reported** (client_executor_test.py:620-667).
7. **Heartbeat liveness:** a pending outcome protects client jobs only while the SJ has not failed
   (fed_server_test.py:508-550).
8. **Balanced accounting:** each JOB_STARTED is balanced by exactly one JOB_COMPLETED/JOB_ABORTED of the same id
   (job_scheduler_test.py:346-372).
9. **Token lifecycle:** every token returned with `is_resource_enough=True` is consumed or cancelled, and rejection
   bookkeeping must not raise first (job_scheduler_test.py:493-545).
10. **No starvation by a malformed candidate:** it is BLOCKed without interrupting later candidates
    (job_scheduler_test.py:432-490).
11. **Bounded completion:** artifacts are ready before the terminal status.
12. **Job-process teardown order.**
13. **Site-local resource-manager errors.**

Documented contracts (`evidence/contracts.md` §2):
- `abort_job` "abort a job if it is running or dispatched" (`job_cmds.py:220`; `operation.rst:42`).
- "Once submitted, a job only has one chance to be executed ... won't be scheduled again" (`job.rst:342-345`).
- Every `FINISHED:*` status is terminal (`job_cli.py:1926-1936`).
- Cancel on non-admission (`job.rst:284-286`).
- Free "once the job is finished (completed normally or aborted)" (`job.rst:293-294`).
- "each concurrent job will be using different GPU devices" (list-manager example, `job.rst:313-316`).
- Resource checks are virtual bookkeeping; interference from outside NVFlare is not the manager's responsibility
  (`resource_manager_and_consumer.rst:17-20, 99-101`).

### 2.4 Known matches already present in permitted source/history (recorded separately)

Subject/body searches of HEAD-reachable commits by batches 4 and 5 found **no commit addressing F1–F9**. The closest
are unrelated: 784eb2d0 maps running-job delete to JOB_NOT_DONE in the CLI; 31a77288 (2022) concerns
CUDA_VISIBLE_DEVICES. In-tree acknowledgments that bound or explain some findings:

| Source | What it says | Bearing |
|---|---|---|
| `docs/user_guide/timeouts.rst:2460-2467` | Non-strict start mode does not enforce `min_sites`/`required_sites` for timeouts | Documented; not a defect |
| `resource_manager_and_consumer.rst:17-20,99-101` | Resource checks are virtual bookkeeping | Bounds external-interference claims |
| `docs/design/job_launcher_and_job_handle.md` §10 item 2 | Process launcher has no start timeout | Known limitation |
| `job_runner_test.py:118-119,419-426` | Name the sticky job-id race | Fixed by e1206061 |
| `docs/release_notes/flare_272.rst:280-323` | Earlier deploy-timeout, dead-client and start-timeout fixes | Historical context |

---

## 3. Phase 3 — Deep analysis: verified findings

### Verification harnesses

All harnesses live under `evidence/harness/`. Run them from that directory; outputs go to `logs/`.

- **`lifecycle_harness.py <scenario> --out logs/<scenario>.log`**, stdout in `logs/<scenario>.stdout`.
  - Real: `JobRunner.run` with its completion thread, `DefaultJobScheduler`, `SimpleJobDefManager` on
    `FilesystemStorage`, the `JobCommandModule.abort_job`/`delete_job` handlers, and `check_client_replies`.
  - Stubbed: client RPC fan-out; SJ launch (`start_app_on_server` registers `run_processes` exactly as
    `_start_runner_process` does); SJ exit (`sj_exit` mirrors `wait_for_complete`); and `JobRunner._deploy_job`,
    replaced per instance by a no-network success that returns `(job_id, [])`.
  - Reproduction controls: hooks inside the stubs run a real admin handler at a chosen moment; scenario B adds a
    bounded delay before `set_status(RUNNING)`.
  - Control scenario `S0_control`: two jobs with `max_jobs=1` each go DISPATCHED→RUNNING→FINISHED:COMPLETED;
    JOB_STARTED/JOB_COMPLETED are balanced and the second job is admitted only after the first completes.
- **`client_harness.py --out logs/client_harness.json`**. Real: `Check/Start/CancelResourceProcessor`,
  `ClientEngine.start_app` (instance built with `__new__`), `JobExecutor`, `ListResourceManager` with its expiry thread
  started by SYSTEM_START, `ListResourceConsumer`, and `ClientAppRunner.notify_job_status`.
- **`pgroup_probe.py`** → `logs/pgroup_probe.log`. Real `spawn_process` and `ProcessHandle`.
- **`l9_l1_probe.py`** → `logs/l9_l1_probe.json`. Real `JobMetaValidator._validate_min_clients`, scheduler/runner via
  the lifecycle harness, and `GPUResourceManager(ignore_host=True)`.

Severity scale:
- **Critical:** wrong terminal status or permanent capacity loss.
- **High:** job stuck, leaked process, or blocked admission.
- **Medium / Low:** everything else.

### F1 — An acknowledged admin abort is lost when it lands during deploy or start (Q3) — **CONFIRMED**, Critical

**Code**
- `abort_job` handles SUBMITTED/DISPATCHED by only writing FINISHED_ABORTED and replying "Aborted the job … before
  running it." (`job_cmds.py:1059-1066`). Nothing is sent to `JobRunner` or the clients.
- The runner re-reads status before deploy (`job_runner.py:661`) and before start (`:697`), which is check-then-act. It
  then writes **blindly**: DISPATCHED (`:670`) after `_deploy_job` returns, and RUNNING (`:711`) after `_start_run`
  returns.
- `SimpleJobDefManager.set_status` has no transition guard (`job_def_manager.py:459-481`). It is an unconditional
  `update_meta(replace=False)`.

**Windows**
- (a) The whole of `_deploy_job` (deploy RPC up to `admin_timeout`, default 10 s), plus scheduler→runner handoff
  (`:656-669`).
- (b) The whole of `_start_run`: SJ launch plus START_JOB fan-out up to 20 s (`server_engine.py:1082`).

**Evidence**
- `logs/A1_abort_during_deploy.stdout`: admin reply `Aborted the job <id> before running it.`; store history
  `FINISHED:ABORTED → DISPATCHED → RUNNING → FINISHED:COMPLETED`; the SJ was launched and START_JOB sent *after* the
  acknowledgment; a scheduler slot was consumed.
- `logs/A2_abort_during_start.stdout`: `DISPATCHED → FINISHED:ABORTED → RUNNING → FINISHED:COMPLETED`.

**Contracts violated**
- `abort_job` "abort a job if it is running or dispatched" (`job_cmds.py:220`; `operation.rst:42`).
- Terminal statuses are final (`job_cli.py:1926-1936`).

**Compensation checked**
- `run_aborted` is never set on this path.
- The heartbeat reconciler only aborts client jobs the server does not track, and this job *is* tracked.

**Variant (lower impact).** When the abort lands between `:670` and `:697`, the runner skips the job. The reservations
dispatched at scheduling are then neither consumed nor cancelled (F6), and the deployed server/client run directories
are left behind: `JobRunner._delete_run` has no callers (`:415-439`).

### F2 — Deleting a SUBMITTED job while the runner holds it kills `JobRunner.run` and admission stops permanently (Q4) — **CONFIRMED**, High

**Code**
- `delete_job` refuses only DISPATCHED/RUNNING (`job_cmds.py:516-521`), so a SUBMITTED job that the runner has already
  taken is deletable during `_try_job` (CHECK round trip up to 15 s) and during `_deploy_job`, where the status is
  still SUBMITTED.
- After deletion, `get_job` returns `None` (`job_def_manager.py:379-385`, `filesystem_storage.py:326-327`).
- `_check_job_status` dereferences `.meta` on it (`job_runner.py:737-739`). The call at `:661` sits **outside** the
  loop's `try` (`:666`).
- Inside the `try`, `set_status(DISPATCHED)` raises `StorageException`. The handler then calls
  `set_status(FAILED_TO_RUN)` (`:720`) unprotected, and that raises too.
- `run()` is started once in a bare thread (`server_deployer.py:136,144-145`); nothing restarts it.

**Evidence**
- `logs/G1_delete_during_schedule.stdout`: `run()` terminated with `AttributeError: 'NoneType' object has no attribute
  'meta'`; a later valid job stays SUBMITTED and is never scheduled.
- `logs/G2_delete_during_deploy.stdout`: `set_status(DISPATCHED) RAISED StorageException` → `set_status(FAILED_TO_RUN)
  RAISED StorageException`; runner dead; the later job is never scheduled.

**Other exposure.** An exception in `get_jobs_to_schedule` (`:650`, outside the `try`) has the same effect, e.g. a job
deleted between `list_objects` and `get_meta` during the 1 Hz scan (`job_def_manager.py:517-531`).

**Contract violated.** Later eligible jobs must remain admissible: batch-5 contract 10 and `job.rst:365-369`.

### F3 — Terminal status regresses to RUNNING when completion publishes between `:710` and `:711` (Q3) — **CONFIRMED** (needs runner descheduling), Medium

**Code.** `running_jobs[job_id]=job` is published under `self.lock` (`job_runner.py:709-710`), but
`set_status(RUNNING)` (`:711`) runs outside the lock. The completion thread picks up any job that is in `running_jobs`
and not in `engine.run_processes` (`:444-445`). When the SJ has already failed, it skips the outcome wait
(`:451-465`), publishes a terminal status, removes the job from `running_jobs`, and fires JOB_COMPLETED.

**Evidence.** `logs/B_running_overwrite.stdout`. The SJ exits with EXCEPTION during START_JOB. The reproduction control
delays `set_status(RUNNING)` until JOB_COMPLETED fires, then:

| Observation | Result |
|---|---|
| Store history | `DISPATCHED → FINISHED:EXECUTION_EXCEPTION → RUNNING` (final **RUNNING**) |
| `running_jobs` / `scheduled_jobs` | both empty |
| `abort_job` | error "Job … is not running." |
| `delete_job` | "job … is running, could not be deleted" |

The job is stuck until a restart, and even then nothing reconciles it (F18).

**Likelihood.** The runner must be descheduled while the completion thread finishes abort fan-out (≤ 2 s) and
archival. This is rare, but nothing prevents it.

### F4 — A validator-accepted malformed candidate starves every later job (Q4) — **CONFIRMED**, High

**Code**
- `_validate_min_clients` deliberately accepts numeric strings but does not write the converted value back. It also
  skips `None` (`job_meta_validator.py:225-249`). So `Job.min_sites` is `"2"` or `None` (`job_def.py:236-243`).
- `_try_job` then raises `TypeError` at `job_scheduler.py:166` (`"2"`) or `:229` (`None`).
- `schedule_job`'s bare `except` (`:292-296`) swallows it **before** `_update_schedule_history` (`:364-375`). The job's
  count and back-off therefore never advance, so it is never BLOCKed or given up, and it is retried first on every
  pass because candidates are sorted by submit time (`:344`).

**Evidence** (`logs/l9_l1_probe.json`)
- The validator accepts both `"2"` and `None`.
- The bad job stays SUBMITTED with `schedule_count` 0.
- A valid job submitted later is never started (checked over 6 s), while the runner stays alive.
- Batch 5 found a second shape: legacy `resource_spec: {site: {"process": "x"}}` passes validation but
  `get_resource_manager_spec` raises `ValueError` (`job_launcher_utils.py:315-316`).

**Contract violated.** Batch-5 contract 10, established by 47684966 for mandatory clients, whose fix is incomplete here.

### F5 — A client failure report during `_start_run` produces KeyError → FAILED_TO_RUN for a job that started (Q2) — **CONFIRMED**, Medium

**Code**
- `_pending_client_outcomes[job]` is set at `job_runner.py:309`.
- `process_job_failure` (`fed_server.py:938-956`) calls `fail_run`. Because the SJ is in `run_processes`, `fail_run`
  accepts the report (`:817`), records the code (`:823-833`), pops the pending set (`:841`), and stops the run (`:843`).
- `_start_run` then indexes the popped entry (`:359-360`) and raises `KeyError`. The handler writes FAILED_TO_RUN and
  fires JOB_ABORTED.

**Evidence** (`logs/K_failrun_during_start.stdout`)
- `fail_run` returned "Job … is not running." even though it had stopped the job.
- Final status `FINISHED:FAILED_TO_RUN`, not EXECUTION_EXCEPTION.
- The `exception_run_processes` entry is left behind; only the completion thread removes entries (`:540`).
- Slots stay balanced: no JOB_STARTED was fired.

Independently reproduced by archaeology batches 1 and 5.

### F6 — Reservations dispatched to the runner are never cancelled on its skip/failure paths (Q1, Q4) — **CODE-CONFIRMED**, Medium (design backstop)

**Code**
- Only `job_scheduler.py:231` and `:245` cancel reservations.
- Paths that neither cancel nor consume:
  - SUBMITTED-check skip (`job_runner.py:661-663`) and DISPATCHED-check skip (`:697-701`);
  - deploy exception (`:669→:713-731`);
  - failed-deploy clients dropped from START (`:692-695`);
  - SJ start failure (`:304-306`);
  - scheduler exceptions after CHECK (`:199-227` swallowed by `:292-296`);
  - late CHECK replies recorded as `(False,"")` (`server_engine.py:1039-1040`; cancel requires `ok and token`, `:1058`).

**Compensation.** AutoClean expiry reclaims them (`auto_clean_resource_manager.py:102-116`): 300 ticks × 1 s with the
provisioned config, 30 by class default. Until then the capacity is unavailable, and later jobs get NO_RESOURCE and
exponential back-off (`job_scheduler.py:356-362`).

**Contracts.** The docs promise cancellation only for non-admitted jobs (`job.rst:284-286`). Batch-5 contract 9 ("every
token … consumed or cancelled") is stated for the scheduler only. This is therefore a gap in the documented contract
rather than a violation of one.

### F7 — Live-dict iteration under concurrent mutation (Q3, Q4) — **CONFIRMED** (`stop_all_runs`); `notify_dead_client` see §4

**Code.** `stop_all_runs` iterates `engine.run_processes.keys()` (`job_runner.py:856`) while `wait_for_complete`
(`server_engine.py:233`) and `_remove_run_processes` (`:408-409`) pop entries from other threads.

**Path.** The admin `shutdown`/`restart` command runs `server_shutdown` → `fl_shutdown` → `stop_all_jobs`
(`server_engine.py:416-440,1104-1115`; `fed_server.py:1243-1247`).

**Evidence.** `logs/H_stop_all_runs.stdout`, with two RUNNING jobs:
- `RuntimeError: dictionary changed size during iteration` once the first SJ exits mid-loop;
- the second job was never aborted and `ask_to_stop` stayed False;
- `SYSTEM_END` and `super().fl_shutdown()` were skipped.

The same pattern exists at `fed_server.py:1109`, inside a sweeper thread that has no handler (`:290-304`).

### F8 — Fractional GPU-memory accounting drifts and permanently loses capacity (Q1) — **CONFIRMED**, High

**Code.** `GPUResourceManager` reserves by subtracting float GiB (`gpu_resource_manager.py:188-197`) and frees by adding
(`:148-150`). There is no reconciliation with the configured capacity.

**Evidence** (`logs/l9_l1_probe.json`). On one GPU with 1 GiB, allocate 0.1 and 0.2, then free them in reverse:
memory is `0.9999999999999999`, and a later 1 GiB job is refused for the life of the CP.

**Scope note.** This is accounting (in scope), not GPU computation.

### F9 — A client allocation leaks when `ClientEngine.start_app` fails by returning a string (Q1) — **CONFIRMED mechanism**; trigger outside the supported envelope, Low

**Code**
- `StartJobProcessor` frees only on an exception (`scheduler_cmds.py:114-133`).
- `ClientEngine.start_app` returns "Client app already started." (`client_engine.py:357-359`) or the "Client app does
  not exist" error string (`:365-367`), in both cases *after* allocation.
- `allocate_resources` has already popped the reservation (`auto_clean_resource_manager.py:153-164`), so expiry can
  never reclaim it.

**Evidence** (`logs/client_harness.json` c1). The START reply is `NVFLARE_ERROR: Client app does not exist…`. Unit 0 is
then neither free nor reserved after the expiry window, and a 2-unit job is refused.

**Trigger.** The only in-tree way to remove a deployed app dir before START is the **disabled** `delete_workspace`
command (`job_cmds.py:163-171`) or manual deletion; a duplicate START_JOB is not produced by cooperative servers. With
the default 0-GPU manager the allocation is `{}`, so there is no capacity effect.

**Classification.** Latent defensive gap.

### F10 — `ProcessHandle.terminate()` cannot reach the job's process group once the leader has been reaped (Q3) — **CONFIRMED probe**, Medium

**Code**
- `ProcessAdapter._kill_process_group` resolves `os.getpgid(self.pid)`, which raises `ProcessLookupError` once the
  leader has been reaped, so it returns without killing anything (`process_utils.py:293-316`). The docstring promises
  "Sends SIGKILL to the entire process group" (`:226-232`). Jobs are spawned with `setsid`, so pgid == pid.
- The client frees the job's resources as soon as the leader exits (`client_executor.py:626-679`).
- The server always calls `terminate()` after a graceful exit (`server_engine.py:402-407`); that call is then a no-op,
  or, under PID reuse, hits the wrong group (F20).

**Evidence** (`logs/pgroup_probe.log`)

| Case | Descendant after `terminate()` |
|---|---|
| Leader alive | killed |
| Leader exited and reaped | **survived** |

**Reachability.** Requires job code that leaves same-group descendants alive. The in-tree Client API trainer uses
`start_new_session=True` (`external_process_backend.py:488-500`) and is not affected.

### F11 — `ClientAppRunner.notify_job_status` never honors `retry_timeout` (Q2 startup) — **CONFIRMED**, Low-Medium

**Code.** In the loop at `client_app_runner.py:197-222`, `duration > retry_timeout` only logs an error; there is no
return or break, and the sleep happens only in the `else`. This contradicts the docstring (`:183-186`): "retry until …
sent successfully, or the retry_timeout has been reached".

**Evidence.** `logs/client_harness.json` c2: with `retry_timeout=1.0`, the call had not returned after 6 s and had made
100 attempts, one error log each.

**Effect.** When the CP never acknowledges, the CJ never runs its job and emits an error log on every attempt. It stays
STARTING at the CP until an abort or heartbeat cleanup kills it (`client_executor.py:505-512`). If `send_request` fails
fast, the loop hot-spins.

### F16 — Unlocked read-modify-write in the job store loses concurrent status writes (Q3) — **CONFIRMED** (timing control), Medium

**Code**
- `FilesystemStorage.update_meta(replace=False)` is `get_meta → dict.update → _write` with no lock
  (`filesystem_storage.py:251-275`). Every `set_status`/`update_meta`/`refresh_meta` goes through it
  (`job_def_manager.py:459-505`).
- Concurrent writers include:
  - runner `update_meta` (`job_runner.py:674-689`);
  - scheduler `refresh_meta` for NO_RESOURCE/BLOCK candidates (`job_scheduler.py:299-308`);
  - completion `set_status` (`:524`);
  - admin `abort_job` (`job_cmds.py:1062`).

**Evidence** (`evidence/harness/rmw_probe.py`, `logs/rmw_probe.json`). Real scheduler NO_RESOURCE path and real
`abort_job`. The scheduler's meta write is paused between its read and its write, and the abort runs inside that gap:
- admin reply: `Aborted the job … before running it.`;
- final status **SUBMITTED**;
- the job is returned again by `get_jobs_to_schedule`, so the aborted job will be scheduled and run later.

**Relation to F1.** This is a second abort-loss window, and it applies to jobs that are merely queued. The window per
scheduling retry is short: one meta file read/write.

