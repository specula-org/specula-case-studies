# Modeling Brief — NVFlare job lifecycle and resource accounting

Source: `/home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/lite/source` @ `53ba7ee567468ea7971dad4faccef13c6cb35dc2` (clean tree).
Scope (user-supplied): default local-process launch path — resource reservation, deployment, startup, termination,
cleanup across server and clients, plus adjacent callers/exception handlers that decide resource ownership, job status,
or admission of later jobs. Excluded: aggregation, model transfer, GPU computation, alternative launchers, HA recovery.

## 1. System Overview

- NVFlare server parent (SP) + client parents (CP), Python, ~7.9k LOC in the in-scope files.
- **Category A (Distributed / Message-Passing)**: SP↔CP admin RPCs over CellNet with per-request timeouts
  (CHECK_RESOURCE 15 s, DEPLOY `admin_timeout`=10 s, START_JOB 20 s, ABORT 2 s optional), job processes (SJ/CJ)
  launched as OS processes; a shared file-system job store. Inside each parent there are independent threads
  (JobRunner scheduling loop, job-completion loop, admin-command handler threads, SJ `wait_for_complete` threads,
  CP START handlers, CJ waiter threads, resource-expiry thread), so intra-process interleavings matter as much as
  message timing.
- Protocol: job state machine SUBMITTED → DISPATCHED → RUNNING → FINISHED:* (or FINISHED:FAILED_TO_RUN), driven by
  `JobRunner.run` (nvflare/private/fed/server/job_runner.py:633-734) with job-store status as the only shared record;
  CP resource manager reservation → allocation → free (auto_clean_resource_manager.py:119-172).
- Key deviations from a clean reference state machine: the job-store status is written by three independent actors
  (runner, completion thread, admin commands) with **no lock and no compare-and-set** (`set_status`
  job_def_manager.py:459-481 is an unconditional read-modify-write, filesystem_storage.py:251-275); resource
  reservations are released either by explicit cancel, by allocation, or by an expiry timer (`expiration_period` ticks:
  constructor default 30, provisioned default 300 — lighter/templates/master_template.yml:78).

## 2. Scenarios

### Scenario 1: Unsynchronized abort vs. dispatch (check-then-act on job status)

**Mechanism**: `abort_job` sets FINISHED:ABORTED for SUBMITTED/DISPATCHED jobs without coordinating with the runner,
while the runner re-checks status only at two points and then unconditionally writes DISPATCHED and RUNNING.

**Evidence**:
- Code: job_cmds.py:1059-1066 (read status, `set_status(FINISHED_ABORTED)`, reply "Aborted the job … before running
  it"); job_runner.py:661 (SUBMITTED check), 669 (`_deploy_job`, multi-second), 670 (unconditional
  `set_status(DISPATCHED)`), 674-689 (`update_meta` read-modify-write), 697 (DISPATCHED check), 703-708
  (`_start_run`, SJ + client start, up to 20 s), 711 (unconditional `set_status(RUNNING)`).
- Contract: FLARE API `abort_job` docstring (fuel/flare_api/flare_api.py:560-572): "If job is not started yet, it will
  be cancelled and won't be scheduled."; runner log text at 662/699 shows intent not to deploy/start non-SUBMITTED /
  non-DISPATCHED jobs.
- Historical (bug-prone mechanism, reference only): 6d193a24 "Fix aborted job status publication race", e3568925
  "Fix aborted job download race", 9f49a109/bb840df0 abort status handling, a18489e4/cb784550 abort during client
  launch windows.

**Affected code paths**: `JobCommandModule.abort_job`, `JobRunner.run`, `SimpleJobDefManager.set_status/update_meta`.

**Suggested modeling approach**: store status variable; runner PC split at every store access; admin abort split into
read and act; history variables for "abort acknowledged" and "launch after ack". Split `update_meta` into read/write.

**Priority**: High — directly answers Q3; long windows (deploy/start duration); documented contract.

### Scenario 2: Job-store exceptions escaping the JobRunner loop (delete/scan races)

**Mechanism**: several job-store accesses in `JobRunner.run` sit outside its `try`, or inside its `except` handler,
and `ServerDeployer._start_job_runner` has no handler, so one StorageException/AttributeError ends scheduling forever.

**Evidence**:
- job_runner.py:650 `get_jobs_to_schedule` (outside try) → job_def_manager.py:517-531 `_scan` lists then `get_meta`
  per object; `get_meta` raises StorageException if the object vanished (filesystem_storage.py:310-329).
- job_runner.py:661 `_check_job_status` (outside try) → `get_job` returns None for a deleted job
  (job_def_manager.py:379-385) → `reload_job.meta` AttributeError (job_runner.py:738-739).
- job_runner.py:720/724 `set_status(FAILED_TO_RUN)` / `update_meta` inside the `except` → StorageException for a
  deleted job (filesystem_storage.py:267-268).
- server_deployer.py:144-145 runs `job_runner.run(fl_ctx)` in a bare thread.
- `delete_job` allows deleting any job whose (pre-authz snapshot) status is not DISPATCHED/RUNNING
  (job_cmds.py:282-316, 516-528); the store status stays SUBMITTED during scheduling and the whole `_deploy_job`.
- Historical: 1b009bdc/e1206061 (runner/scheduler accounting blocking later jobs) show admission-blocking failures are
  treated as defects.

**Priority**: High — directly answers Q4 (an ordinary failed operation blocks every later eligible job).

### Scenario 3: Reservation/allocation ownership across scheduler and runner failure paths

**Mechanism**: reservations created by CHECK_RESOURCE are cancelled only on the scheduler's own NO_RESOURCE path;
every later failure/skip path relies on the expiry timer; START_JOB frees an allocation only when it raises.

**Evidence**:
- job_scheduler.py:199-261 (cancel only when min_sites/required-site checks fail); server_engine.py:1010-1041 (a
  timed-out CHECK reply becomes `(False, "")`, never cancelled); job_runner.py:661-663, 697-701 (`continue` after
  scheduling/deploy with reservations outstanding), 713-731 (except path never cancels).
- auto_clean_resource_manager.py:102-117 (expiry after `expiration_period` ticks), 153-164 (allocate raises for an
  expired token), 166-172 (free has no ownership check — double free would duplicate units).
- scheduler_cmds.py:114-133 frees only in `except`; client_engine.py:357-367 returns error strings (not exceptions)
  after allocation ("already started", "app does not exist").
- client_executor.py:676-682 frees at CJ exit; 299-334 registration/launch/attach windows.
- Historical: a6616c8a/5e2283fb/3bff3146 (admission failure handling), 975dc146 (resource cleanup thread).

**Priority**: Medium-High — answers Q1/Q4; conservation/ownership is mechanically checkable.

### Scenario 4: Completion, failure reports and start overlap

**Mechanism**: the completion thread, `fail_run` (client failure reports / dead-client reconciliation) and the runner
start path touch `running_jobs`, `_pending_client_outcomes`, `exception_run_processes` and status in separate steps.

**Evidence**: job_runner.py:308-310 & 359-360 (pending set created then `intersection_update` — KeyError if popped by
`fail_run` at 841), 709-711 (running_jobs add then RUNNING write, completion loop may finalize in between),
441-541 (completion multi-step), 798-811 (`stop_run` = `_stop_run` then `mark_run_aborted`), fed_server.py:906-957,
1004-1094; server_engine.py:203-234, 354-409.
- Historical: 46cfc517, 535373a0, 52c966d1 (outcome barrier), 6d193a24, 1b009bdc.

**Priority**: Medium.

### Scenario 5: Client process-exit cleanup and heartbeat reconciliation

**Mechanism**: CJ resources are freed only by the waiter at process exit; aborts that arrive before registration are
dropped and rely on heartbeat reconciliation (`_sync_client_jobs`).

**Evidence**: client_executor.py:299-334, 486-547, 622-688; client_engine.py:390-404; communicator.py:595-651;
fed_server.py:1004-1076.

**Priority**: Medium-Low (compensating heartbeat mechanism exists).

## 3. Modeling Recommendations

### 3.1 Model
- Job-store status with unconditional writes; runner PC per store access (S1, S2, S3, S4).
- Admin abort (read/act) and delete (pre-authz snapshot/act) as concurrent actors (S1, S2).
- Scheduler admission set `scheduled_jobs` and `max_jobs` (S2, S4).
- CP resource manager: free count, reservation tokens, allocation, expiry timer, CANCEL, START handler steps,
  CJ waiter free-at-exit (S3, S5).
- SJ process and completion thread with pending client outcomes; `fail_run` from client reports (S4).
- RPC timeouts as bounded faults with late client-side processing (S3).

### 3.2 Do Not Model
- Training workflow/aggregation, model transfer, streaming, GPU memory arithmetic (excluded by scope; resources
  abstracted as unit counts).
- Workspace archival retries (tested by existing unit tests; independent of ownership questions).
- HA/cold-state recovery, restart reconciliation (`update_unfinished_jobs` has no callers; excluded).
- Signature verification, authz, study registry, BYOC (security, not lifecycle).
- Docker/K8s/Slurm launchers (excluded).

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Status store | `status`, `deleted` | unconditional writes, deletion | S1,S2 |
| Runner PC | `rn` (pc, job, tokens, failed, meta snapshot) | faithful step split | S1-S4 |
| Admin actors | `abortPc`, `delPc`, `delSnap` | concurrent abort/delete | S1,S2 |
| History | `abortAck`, `launchAfterAck`, `wasTerminal` | contract observation | S1 |
| Admission | `scheduled`, `running` | max_jobs accounting | S2,S4 |
| CP resources | `free`, `resv`, `alloc`, `startH`, `cj`, `waiter` | ownership | S3,S5 |
| Server procs | `sj`, `runProc`, `excCode`, `pending`, `runAborted`, `comp` | completion overlap | S4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| AbortHonored | Safety | after "aborted before running" ack, the job is never launched and its status stays FINISHED:ABORTED (or deleted) | S1 |
| TerminalStatusStable | Safety | a terminal status is never replaced by a non-terminal one | S1,S4 |
| RunnerAlive | Safety | the JobRunner scheduling loop never terminates on an unhandled exception | S2 |
| NoStaleAdmission | Safety | every `scheduled_jobs` entry belongs to a job the runner/completion path still owns | S2,S4 |
| ResourceConservation | Safety | free + reserved + allocated = capacity per client (no double free / duplicate unit) | S3 |
| NoConflictingAllocation | Safety | a unit is never allocated to two live jobs | S3 |
| AllocationOwned | Safety | every allocation belongs to a live CJ/START handler/waiter (no permanent leak) | S3,S5 |
| FailedStartCleanedUp | Safety (diagnostic) | after FAILED_TO_RUN, no live SJ remains without a cleanup path | S4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable
| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC-1 | Can an abort acknowledged for a SUBMITTED/DISPATCHED job be followed by deployment/start and a non-aborted status? | AbortHonored, TerminalStatusStable | S1 |
| MC-2 | Can deleting a queued job (allowed operation) make the scheduling loop exit, blocking later jobs? | RunnerAlive | S2 |
| MC-3 | Can any failure/skip path leave a unit permanently allocated or duplicated on a client? | AllocationOwned, ResourceConservation | S3 |
| MC-4 | Can the completion/fail_run paths overlap the start path so a terminal status is overwritten or admission accounting goes stale? | TerminalStatusStable, NoStaleAdmission | S4 |

### 6.2 Test-Verifiable
| ID | Description | Suggested test approach |
|---|---|---|
| T-1 | Reservations abandoned by runner `continue`/except paths are held until expiry and reject a later eligible job's check | real POC run with ListResourceManager/GPUResourceManager(num_of_gpus=0) + abort during deploy |
| T-2 | START_JOB arriving after reservation expiry fails the job (deploy > expiration_period) | unit/integration timing test |

### 6.3 Code-Review-Only
| ID | Description | Suggested action |
|---|---|---|
| CR-1 | `ClientEngine.start_app` error-string returns after allocation are never freed (scheduler_cmds.py:114-133) | check reachability |
| CR-2 | `AutoCleanResourceManager.free_resources` has no ownership check (double free duplicates units) | check callers |
| CR-3 | GPUResourceManager accepts float/0 `expiration_period` that the base class rejects (gpu_resource_manager.py:80, 107-110 vs auto_clean_resource_manager.py:42-45) | config validation |
| CR-4 | `_start_run` `intersection_update` KeyError when `fail_run` pops pending outcomes (job_runner.py:359-360, 841) | check status outcome |
| CR-5 | Non-strict start check skips min_sites/required_sites (job_runner.py:318-353) | design note |

## 7. Reference Pointers
- Core files: job_runner.py:99-869; job_scheduler.py:38-389; job_cmds.py:507-548, 1051-1084; server_engine.py:179-409,
  1010-1083; scheduler_cmds.py:57-157; client_engine.py:349-404; client_executor.py:198-334, 486-688;
  auto_clean_resource_manager.py; list_resource_manager.py; filesystem_storage.py:251-433; job_def_manager.py:379-545;
  fed_server.py:560-620, 906-1116; server_deployer.py:95-146; flare_api.py:560-595 (contracts);
  docs/system_architecture/system_architecture.rst:185-235, 325-350; docs/programming_guide/resource_manager_and_consumer.rst.
- Archaeology: 294 commits touch the in-scope files; ~150 match bug-fix keywords; commit messages/trees are available
  but historical blobs are missing from the object store (diffs unavailable). GitHub issues/PRs were not consulted
  (pilot rules). No local commit message describes MC-1/MC-2 or the deletion/abort-dispatch races.
