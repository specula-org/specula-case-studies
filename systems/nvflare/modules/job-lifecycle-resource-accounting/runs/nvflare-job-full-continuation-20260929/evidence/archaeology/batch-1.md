# Batch 1 archaeology (core-commits.txt lines 1-100)

STATUS: COMPLETE

Pinned HEAD: 53ba7ee567468ea7971dad4faccef13c6cb35dc2. All 100 batch commits verified ancestors of HEAD (`git merge-base --is-ancestor`).
Method: `git show --stat --format='%H%n%ad%n%s%n%n%b' <sha>` for every commit; `git show <sha> -- $(cat core-paths.txt)` for potentially relevant ones.
Classes: (a) in-scope bug fix; (b) in-scope feature/refactor changing lifecycle/resource semantics; (c) out of scope.

## Per-commit log (incremental)

### ENVIRONMENT BLOCKER (recorded before analysis)

Historical blob contents are NOT available in this repository's object store:
- `git show --stat ...` and `git show <sha> -- <core paths>` fail for all 100 batch commits with `fatal: unable to read <blob-id>` (even `git show --stat HEAD` fails, on the parent-side blob).
- `git rev-list --objects --missing=print HEAD -- <core paths>` -> 405 commits + 3016 trees + 36 blobs present, 1005 objects missing; the 36 present blobs are the HEAD versions only.
- `.git/objects/info/alternates` points at an external object store; no promisor remote is configured in this repo, and fetching would modify the repo / touch a forbidden remote, so it was NOT attempted.
Substitute evidence actually used per commit (all available):
- `git show -s --format='%H%n%ad%n%s%n%n%b' <sha>` (full message, incl. squash-merge sub-bullets),
- `git diff-tree --no-commit-id -r --name-status --no-renames <sha>` (files touched, A/M/D),
- the HEAD source of the touched functions (read directly) plus HEAD unit tests, to verify the fix's current form and to find analogous sites.
Consequence: mechanisms below are derived from commit messages + HEAD code, not from reading the historical hunks. Each (a) row states the confidence ("msg+HEAD") accordingly.

### Lines 1-20

| # | Commit | Date | Subject | Class | Note |
|---|--------|------|---------|-------|------|
| 1 | e1e2e1db | 2021-11-23 | Initial commit for 2.0 | c | Baseline import (all core client/server files `A`); no fix. `git show -s` fails (blob read); message read via `git cat-file -p`. |
| 2 | cbc0f8f9 | 2021-12-14 | Learner API / LearnerExecutor | c | Training API. |
| 3 | 5316ed4a | 2022-01-05 | Fixed args.log_config | c | Logging config. |
| 4 | a7cba783 | 2022-01-06 | Update copyright year | c | Headers. |
| 5 | 5821de59 | 2022-01-19 | NVFlare -> NVIDIA FLARE | c | Rename. |
| 6 | 64df6293 | 2022-01-20 | Logging streaming | c | Later removed by ec32c7e3. |
| 7 | 2684d27a | 2022-01-20 | Increase fed event firing frequency | b | Introduced two-phase end of run: ABOUT_TO_END_RUN (flush) then END_RUN; "more steps for ABORT command"; end-run sequence refactored into its own method. HEAD form: server_runner.py:203-232 (ABOUT_TO_END_RUN, END_RUN aux to clients, persist, check_end_run_readiness, END_RUN). |
| 8 | 57152d3a | 2022-01-21 | Removed tmp folders for server and client | b | Apps deployed/run directly in the workspace run folder (no tmp copy); a startup sleep removed. HEAD: AppDeployer targets workspace.get_app_dir(job_id) (job_runner.py:185-198, client_engine.py:462-480). |
| 9 | ec32c7e3 | 2022-01-27 | Remove log streaming | c | |
| 10 | b2bafcde | 2022-02-04 | Server docstrings | c | |
| 11 | 019fed5a | 2022-02-04 | Private docstrings | c | |
| 12 | da80cb20 | 2022-02-07 | Standardize error messages | c | asserts -> TypeError. |
| 13 | 4a255e2b | 2022-03-08 | HA support | c | HA/overseer (excluded). Squash of many unrelated PRs; message via cat-file. |
| 14 | 8ea41d48 | 2022-03-09 | HA in POC | c | HA. |
| 15 | 32ae998b | 2022-03-09 | get open port for client_executor | a (Low, msg-only) | Child job process listener port obtained dynamically instead of fixed -> avoids start failure on port collision. Superseded at HEAD: CJ connects back through the parent cell's internal listener (client_executor.py:285 PARENT_URL), no port chosen in client_executor. |
| 16 | b6bab46a | 2022-03-10 | Log levels | c | |
| 17 | 69d139e4 | 2022-03-11 | SAG HA | c | HA. |
| 18 | 903a494a | 2022-03-14 | isort/black/flake8 | c | |
| 19 | 433ca3c4 | 2022-03-14 | Persist wf_index | c | Snapshot/HA recovery (excluded). |
| 20 | 36ca4b8f | 2022-03-18 | set_run_number for snapshot restore | c | Snapshot/HA recovery. |

Coordinator confirmation (received mid-run): the alternate object store is a blob:none partial clone; no git command was run inside it, no fetch/lazy fetch was attempted. ALL 100 commits in this batch are therefore classified from message body + touched-file list (+ HEAD code verification); 0 commits had a readable diff.

### Lines 21-40

| # | Commit | Date | Subject | Class | Note |
|---|--------|------|---------|-------|------|
| 21 | 55ce1e65 | 2022-03-23 | Initial job management + admin commands | b | Introduced job store (JobDefManager) and server job admin commands (job_cmds.py `A`). Contract: job lifecycle is recorded as `status` meta in the job store; admin commands mutate it. |
| 22 | f31e5b71 | 2022-03-25 | Move job def into apis, add get_apps | c | Module move (nvflare/mt -> nvflare/apis). |
| 23 | d93b0c37 | 2022-03-30 | Runner process | b | Server side of each run moved into a child process (runner_process.py `A`); "Set the server to stopped after training complete"; "thread safe for server child process communication". HEAD form: ServerEngine._start_runner_process + wait_for_complete (server_engine.py:203-330); engine status set STOPPED after child exit (server_engine.py:234). |
| 24 | 64168432 | 2022-03-31 | Fix import issues | c | |
| 25 | 3843b5cc | 2022-04-01 | Remove pickle from job commands | c | Serialization/security. |
| 26 | 36c3fc7b | 2022-04-06 | Multi run support | b | Server and client support concurrent runs; per-run process tables keyed by run/job id; delete_run changed. HEAD: ServerEngine.run_processes / exception_run_processes (server_engine.py:104-105), JobExecutor.run_processes (client_executor.py:191). |
| 27 | c3899140 | 2022-04-06 | Docstrings, get app content | c | |
| 28 | 2f694e3e | 2022-04-07 | Fix job def and manager specs | c | Spec/signature fixes (msg-only; no lifecycle semantics stated). |
| 29 | 8ee1a33f | 2022-04-07 | Fix upload/download job cmds, add clone_job | c | Job transfer; clone creates new SUBMITTED job (HEAD job_def_manager.py:331-352). |
| 30 | 198a66f8 | 2022-04-07 | Keys in meta not being str | a (Low, msg-only) | Job meta written with non-str (enum) keys -> persisted/looked-up keys inconsistent (affects `status` and other meta). HEAD writes `.value` keys (job_def_manager.py:324,345,460) and JobMetaKey is a str-Enum; verified in the arm's Python 3.12 that `{'status':..}.get(JobMetaKey.STATUS)` hits and json encodes as "status". No residual. |
| 31 | 86f296d3 | 2022-04-07 | Add Job scheduler | b | Introduced ResourceManagerSpec token protocol: check_resources -> (ok, token) reservation; cancel/allocate/free keyed by token (HEAD resource_manager_spec.py:26-88); ListResourceManager, GPU consumer, JobSchedulerSpec. |
| 32 | da961b3b | 2022-04-12 | FLAdminAPI commands | c | |
| 33 | 9b2b96ca | 2022-04-15 | Scheduler integration | b | Added JobRunner (schedule -> deploy -> start -> completion status update), JobScheduler.remove_job, ResourceConsumer, client scheduler_cmds (CHECK_RESOURCE/START_JOB/CANCEL_RESOURCE). HEAD: job_runner.py:633-731, scheduler_cmds.py:57-157; client frees allocation on child exit (client_executor.py:676-679). |
| 34 | e851f708 | 2022-04-15 | __init__.py, ABORT command invisible | c | Admin command visibility. |
| 35 | 26d931cf | 2022-04-18 | Keep running clients for job | b | Per-run participants recorded so stop/abort target the job's clients. HEAD: RunProcessKey.PARTICIPANTS stored at start (server_engine.py:322-326) and used (intersected with connected clients) by _stop_run / _get_finished_job_status (job_runner.py:382-389, 580-584). |
| 36 | 057aec69 | 2022-04-19 | Snapshot write lock | c | Snapshot/HA restore of running jobs (excluded). |
| 37 | 7910aadb | 2022-04-19 | CI/CD requirements and tests | c | Touches job_runner/job_cmds/server_engine but message is CI/format only. |
| 38 | 1c0d5b43 | 2022-04-21 | cross_site_validation for multi_run | c | Training workflow. |
| 39 | c023cc9e | 2022-04-21 | Default PYTHONPATH if not set | a (Low, msg-only) | Child job process env assumed PYTHONPATH existed -> start failure when unset. Superseded at HEAD: launcher builds PYTHONPATH from sys.path + custom dir (job_launcher_utils.py:486-490, process_launcher.py:68-72). |
| 40 | b40885ec | 2022-04-21 | Enhance error message reporting | c | job_runner logging only (msg). |

### Lines 41-60

| # | Commit | Date | Subject | Class | Note |
|---|--------|------|---------|-------|------|
| 41 | 48daa2a6 | 2022-04-22 | Implemented submit_job and list_jobs | b | Admission entry point: submit creates a job in status SUBMITTED for the scheduler (HEAD job_def_manager.py:308-329; job_cmds.py:1568+ with JobMetaValidator at 1586-1587). |
| 42 | ecbad1d5 | 2022-04-25 | Update commands | c | FLAdminAPI clone/list/shutdown. |
| 43 | be0a6303 | 2022-04-26 | Fix typos | c | scheduler_cmds typo. |
| 44 | 0aa58587 | 2022-04-26 | list_jobs when study is None | c | |
| 45 | 425c1dae | 2022-04-27 | Clean up job scheduler, resource manager, consumers | b | Resource manager/consumer moved to app_common and configured by path (fed_client.json components); scheduler_cmds changed. Contract: RESOURCE_MANAGER / RESOURCE_CONSUMER are site system components (HEAD scheduler_cmds.py:33-54). |
| 46 | a6a6664b | 2022-04-27 | abort_job in FLAdminAPI, get runner working | b | abort_job admin command wired to the JobRunner (HEAD job_cmds.py:1051-1084 -> job_runner.stop_run 798-800). |
| 47 | 1e087e06 | 2022-04-28 | Move job scheduler to app_common | c | Move. |
| 48 | 380ef1d2 | 2022-04-28 | Log separation | c | |
| 49 | e0aa5434 | 2022-04-28 | Enhance Job_runner logging | c | |
| 50 | cf536479 | 2022-04-28 | Codestyle | c | |
| 51 | ed96e734 | 2022-04-28 | Whitespace in log | c | |
| 52 | eaf1b5ba | 2022-04-29 | Missing min_sites and required_sites for Job | a (Medium, msg+HEAD) | Admission constraints were not carried from meta into the Job object, so scheduler/runner min_sites/required_sites checks could not take effect. HEAD: job_from_meta maps MIN_CLIENTS/MANDATORY_CLIENTS (job_def.py:227-244). RESIDUAL (verified, see lead L1): the raw meta value is used without type normalization, so a validator-accepted `min_clients: null` or `"2"` makes job_scheduler.py:229 / :166 raise TypeError. |
| 53 | 15291460 | 2022-05-02 | Job scheduler uses events | b | Contract: concurrency admission (max_jobs) counts jobs between JOB_STARTED and JOB_COMPLETED/JOB_ABORTED (HEAD job_scheduler.py:263-285); job runner fires those events (job_runner.py:364, 536-538, 728). "when no job manager defined, give error message" (job_runner.py:733-734). |
| 54 | 5f555281 | 2022-05-02 | Only persist FLComponent snapshot | c | Snapshot. |
| 55 | 21abe7d7 | 2022-05-03 | SecurityContentService for runner_process | c | Security init. |
| 56 | 71452211 | 2022-05-04 | Clean up server engine internal spec | c | |
| 57 | ab86226f | 2022-05-04 | Clean up server runner | c | |
| 58 | 84651755 | 2022-05-04 | Clean up fed server | c | |
| 59 | 7ee222a3 | 2022-05-05 | Update job scheduler + unit tests | b | Scheduler returns per-site DispatchInfo (app, requirement, token) and cancels reservations when min_sites/required-site resource checks fail (HEAD job_scheduler.py:207-261; tests/unit_test/app_common/job_schedulers/job_scheduler_test.py added). |
| 60 | 31d0ee10 | 2022-05-05 | Abs path, sort list_jobs | c | |

### Lines 61-80

| # | Commit | Date | Subject | Class | Note |
|---|--------|------|---------|-------|------|
| 61 | bbbbf063 | 2022-05-05 | Tensor in model weights for cross_validation | c | Model transfer. |
| 62 | 3c35e876 | 2022-05-06 | Sync clients in runner_process | b | SJ must fetch the job's participating clients from the parent before running. HEAD: ServerEngine.sync_clients_from_main_process, bounded 30 s then RuntimeError -> job process exits (server_engine.py:828-846, called at server_app_runner.py:96); parent answers GET_CLIENTS from run_processes[job].PARTICIPANTS (fed_server.py:584-592). |
| 63 | ec855326 | 2022-05-07 | FLARE-197 empty deploy_map | a (Medium, msg-only) | Runner did not reject a job with empty deploy_map before deploy/start. HEAD: rejected at submit (job_meta_validator.py:115-147, also requires server entry) and blocked by scheduler (job_scheduler.py:114-116 -> FINISHED_CANT_SCHEDULE). No residual found for validated jobs. |
| 64 | db90aff6 | 2022-05-09 | Ensure the job exit for abort_job | a (High, msg+HEAD) | abort_job did not guarantee the server job process exits (job left running). HEAD: abort_app_on_server always schedules _remove_run_processes -> job_handle.terminate() after <=10 s grace (server_engine.py:354-409). Residual: _stop_run acts only if the job is still in engine.run_processes (job_runner.py:382-383); client-side cleanup otherwise relies on heartbeat reconciliation (fed_server.py:1004-1017). |
| 65 | 28282fa9 | 2022-05-09 | Added a missing check in. | undetermined | job_cmds.py only; message too terse to identify the check without the diff. Not counted as (a). |
| 66 | d3e32795 | 2022-05-09 | FAILED_TO_RUN status; run_number format; delete workspace on failure | a (High, msg+HEAD) | Deploy/start failure left the job without a terminal status (stuck/non-terminal record). HEAD: run() except path sets FINISHED:FAILED_TO_RUN (job_runner.py:713-731). RESIDUALS: (i) the "delete the workspace if job failed to run" cleanup is gone at HEAD: JobRunner._delete_run (job_runner.py:415-439) has NO callers (grep); (ii) set_status(FAILED_TO_RUN) itself is unguarded inside the except handler (job_runner.py:720) - see lead L2. |
| 67 | 76db82ba | 2022-05-09 | makedirs for intermediate folders | c | Job store dirs. |
| 68 | 1058e40c | 2022-05-10 | Fix list resource manager, add tests | a (Critical, msg+HEAD) | Reservations made by check_resources had no expiry, so any schedule that was abandoned without cancel/allocate permanently lost capacity; also "Move consume resource before app starts". HEAD: AutoCleanResourceManager expiry (auto_clean_resource_manager.py:102-117, 131); consume before start_app (scheduler_cmds.py:116-128). RESIDUALS: runner abandon paths still never cancel and rely on expiry (lead L4); expiry is tick-counted and unrefreshed, so a reservation can lapse before START_JOB (allocate raises, auto_clean_resource_manager.py:156-163). |
| 69 | 9baa0c80 | 2022-05-13 | Pass SP target info to client process | c | HA/SP target. |
| 70 | 365da018 | 2022-05-13 | Fix client not online deploy error | a (Medium, msg+HEAD) | Deploy targeted deploy_map sites that were not connected -> spurious job failure. HEAD: deploy only to scheduled `sites` (job_runner.py:215-217). Residual: a scheduled client that disconnects before deploy makes validate_targets return invalid_inputs and raise for the whole job (job_runner.py:222-226), unlike the tolerated non-required deploy failure at 269-279 (policy inconsistency, Low). |
| 71 | efac72e6 | 2022-05-13 | Removed studies from submit/list | c | |
| 72 | cc184582 | 2022-05-13 | Docs; remove delete_job | c | delete_job later re-added (HEAD job_cmds.py:507). |
| 73 | f2fc2a4d | 2022-05-13 | Remove Study info | c | |
| 74 | 689983d6 | 2022-05-13 | Snapshot concurrent persist | c | HA snapshot / turn_to_hot. |
| 75 | 478718c6 | 2022-05-13 | Heartbeat jobs | b | Reconciliation contract: client reports running job ids in heartbeat; server replies ABORT_JOBS for jobs it does not run; client aborts them (HEAD fed_server.py:959-1060, communicator.py:594-646). |
| 76 | e7595e67 | 2022-05-16 | Overseer shutdown command | c | HA. |
| 77 | cb1d5354 | 2022-05-16 | abort_job could not abort all running jobs | a (High, msg+HEAD) | Multi-job abort/stop only reached part of the running jobs. HEAD: the analogous stop-all loop still iterates the LIVE dict view `for job_id in engine.run_processes.keys()` (job_runner.py:856) while wait_for_complete/_remove_run_processes pop entries from other threads (server_engine.py:233, 408-409) - see lead L3. |
| 78 | bece044d | 2022-05-18 | Sort jobs by submit time | b | FIFO admission order (job_scheduler.py:343-344). |
| 79 | 6bc40bb5 | 2022-05-19 | Execution exception status | a (Critical, msg+HEAD) | A job that started but failed while running was recorded with a non-failure terminal status. HEAD: FINISHED_EXECUTION_EXCEPTION via exception_run_processes / PROCESS_EXE_ERROR (job_runner.py:543-572, fed_server.py:594-603, server_engine.py:203-234). Residual: see lead L6 (UPDATE_RUN_STATUS is fire-and-forget, parent waits only 2 s, and its writer uses FederatedServer.lock while wait_for_complete/fail_run use engine.lock). |
| 80 | 192ea30f | 2022-05-20 | Split snapshot file | c | HA snapshot. |

### Lines 81-100

| # | Commit | Date | Subject | Class | Note |
|---|--------|------|---------|-------|------|
| 81 | df92fab4 | 2022-05-20 | Fix handling of config exception during job running | a (High, msg+HEAD) | A config error inside a job process was not turned into a failure outcome (status/cleanup wrong). HEAD: mpm maps ConfigError -> ProcessExitCode.CONFIG_ERROR (fuel/f3/mpm.py:154-157); CJ reports it (client_executor.py:41-47, 647-674); server fail_run (fed_server.py:942-951); SJ code classified FINISHED_EXECUTION_EXCEPTION (job_runner.py:554-563). Residual: lead L9 (failure report during _start_run -> KeyError at job_runner.py:360). |
| 82 | 7a013824 | 2022-05-20 | authz for submit_job/list_jobs | c | Authorization. |
| 83 | 05164b14 | 2022-05-23 | Avoid exception swallow | a (Medium, msg-only) | server_engine swallowed an exception, hiding a start/stop failure. HEAD: start path exceptions propagate to the runner's FAILED_TO_RUN handler (server_engine.py:179-196, 236-330 -> job_runner.py:304-306, 713). Remaining swallow at server_engine.py:372-373 is intentional (falls through to forced terminate). No residual found. |
| 84 | 5b033b04 | 2022-05-23 | Snapshot log path | c | |
| 85 | 279cfcd4 | 2022-05-24 | Add cancelled resources to front | b | Deallocated units return to the head of the pool (list_resource_manager.py:52-55) - reuse order only. |
| 86 | 900f9af3 | 2022-05-24 | PCI_BUS_ID as CUDA_DEVICE_ORDER | c | GPU device ordering (GPU computation excluded). See low-priority lead L10 about process-global CUDA env. |
| 87 | a8265f1d | 2022-05-25 | abort_job random EOFError | a (Medium, msg-only) | Parent<->job-process command channel raised EOFError when the child closed during abort -> abort_job error. Superseded: cell messaging; abort command failure is tolerated and followed by terminate (server_engine.py:361-383). |
| 88 | 39c247d3 | 2022-05-25 | Fix job schedule and deploy with @ALL | a (High, msg+HEAD) | @ALL deploy_map not expanded consistently in scheduler and runner -> job unschedulable / wrong deploy set. HEAD: scheduler expands to online (study-enrolled) sites + server (job_scheduler.py:124-128); runner expands then filters by scheduled sites (job_runner.py:177-179, 215-217); validator forbids mixing @ALL with other sites (job_meta_validator.py:140-145). No residual found. |
| 89 | 72eb5462 | 2022-05-26 | Monitor parent process exit | a (High, msg+HEAD) | Job worker process did not exit when its parent died -> orphaned job process. HEAD: CJ and SJ both run monitor_parent_process (worker_process.py:121-124, runner_process.py:125-126; app/utils.py:45-50). Residual (Low): monitor starts only after setup (worker_process.py:50 vs 123) and only calls cooperative runner.stop(). |
| 90 | 327be8ff | 2022-05-26 | Fix resource manager | a (Critical, inferred) | Message terse; file list (client_engine_spec, client_engine_executor_spec, client_engine_internal_spec, client_engine, client_executor, list_resource_manager, client_train, base_client_deployer, server_engine) matches plumbing the allocation/token/resource_manager into start_app so the child-exit path can free them. HEAD: start_app(job_id, job_meta, allocated_resource, token, resource_manager) (client_engine_internal_spec.py:54-61) and free on child exit (client_executor.py:676-679). Confidence low-medium (inference). |
| 91 | e385955e | 2022-05-27 | Proper system shutdown (Bad file descriptor) | c | System (not job) shutdown ordering; HEAD server_engine.close (1099-1101). |
| 92 | 2998f1a3 | 2022-05-27 | authz test cases | c | |
| 93 | 975dc146 | 2022-05-27 | Fix resource manager clean up thread calling | a (High, msg+HEAD) | Reservation cleanup thread not driven correctly -> expiry never happened (capacity loss); also "Add checks to start client app" and "Use ERROR_MSG_PREFIX to check for errors". HEAD: cleanup thread on SYSTEM_START/SYSTEM_END (auto_clean_resource_manager.py:93-100; fired by client_train.py:218); start_app returns ERROR_MSG_PREFIX when app missing (client_engine.py:365-367); replies checked for the prefix (admin.py:131-137). Residual: lead L5 (allocation not freed when start_app returns an error string). |
| 94 | a8ee3c2b | 2022-05-27 | Fix check client replies | a (Medium, msg+HEAD) | Client reply evaluation mis-detected start/deploy failures (None replies / error bodies). HEAD: check_client_replies strict/non-strict (admin.py:80-140); deploy counts no-reply as failure (job_runner.py:261-267). Non-strict start mode tolerating required-site timeouts is DOCUMENTED (docs/programming_guide/timeouts.rst:2460-2467) - not a defect. |
| 95 | a449b49b | 2022-05-27 | authz for abort_job | c | Authorization. |
| 96 | a0d75eaa | 2022-05-28 | Fix abort job when server execution exception | a (High, msg+HEAD) | After the SJ failed, abort/completion did not clean up clients / job stuck. HEAD: _get_finished_job_status aborts active clients when exception_run_processes has the job (job_runner.py:574-585); exception entries removed only for jobs in running_jobs (job_runner.py:540). Residual (Low): entries created for jobs already removed on the FAILED_TO_RUN path are never removed (memory only). |
| 97 | a6dcce63 | 2022-05-29 | Fixed jobs run race condition | a (Critical, msg+HEAD) | Concurrent job operations raced (runner vs. status changes; client executor per-job state). HEAD guard: _check_job_status before deploy (job_runner.py:661) and before start (697), both check-then-act. RESIDUAL VERIFIED: lead L8 (abort acknowledged "before running it" is overwritten by DISPATCHED/RUNNING and the job runs). |
| 98 | 96a64e3c | 2022-05-31 | Treat several msgs as NON-ERROR | a (Medium, msg+HEAD) | Benign replies ("already started"/"already stopped"/"has not started") were treated as errors -> false start/abort failure. HEAD: returned without ERROR_MSG_PREFIX (client_engine.py:357-359, 390-400). No residual found. |
| 99 | 16edf78e | 2022-06-01 | run_number type hint | c | |
| 100 | 15bebb31 | 2022-06-01 | Server start success but client start failed | a (Critical, msg+HEAD) | When server start succeeded but client start failed, the server job process kept running, the job stayed in running_jobs, and no abort event freed the scheduler's max_jobs slot. HEAD: except path removes running job, _stop_run, FAILED_TO_RUN, JOB_ABORTED (job_runner.py:713-731). Residuals: L2 (set_status inside except unguarded), L4 (reservations not cancelled), L9 (KeyError race). |

---

## Coverage stats

- Commits examined: 100 / 100 (core-commits.txt lines 1-100, 2021-11-23 .. 2022-06-01), all verified ancestors of pinned HEAD.
- Evidence basis: 100 commits classified from message body + touched-file list + HEAD code; 0 had readable diffs (environment limit: historical blobs absent, see blocker above).
- (a) in-scope bug fixes: **23** — Critical 5 (1 of them inferred), High 8, Medium 7, Low 3. Confidence: msg+HEAD 16, msg-only 6, inferred-from-file-list 1.
- (b) in-scope feature/refactor with lifecycle/resource semantics: **17**.
- (c) out of scope: **59**.
- undetermined: **1** (28282fa9 "Added a missing check in." — job_cmds.py only, message too terse).

## (a) In-scope bug fixes

| Commit | Date | Summary | Root-cause mechanism | Component | Sev | Fix completeness / analogous HEAD sites |
|---|---|---|---|---|---|---|
| 1058e40c | 2022-05-10 | List RM fix: reservation expiry, consume before start | reservation had no lifetime bound -> abandoned schedule = permanent capacity loss | ListResourceManager / scheduler_cmds | Critical | Expiry exists (auto_clean_resource_manager.py:102-117). Runner abandon paths still never CANCEL and rely on expiry; expiry is unrefreshed and can lapse before START_JOB (L4). |
| 6bc40bb5 | 2022-05-19 | Execution-exception job status | terminal status derived without child-failure signal | job_runner / server_engine / runner_process | Critical | HEAD classification job_runner.py:543-572. Failure signal still partly async/unsynchronized (L6, unconfirmed). |
| 327be8ff | 2022-05-26 | Fix resource manager (inferred) | allocation/token/RM not plumbed to the child-exit free path -> allocations never freed | client_engine specs / client_executor | Critical (inferred) | HEAD frees on child exit (client_executor.py:676-679). Error-string return path does not free (L5). |
| a6dcce63 | 2022-05-29 | Jobs run race condition | status transitions by admin vs runner are check-then-act | job_runner / client_executor | Critical | Guards at job_runner.py:661, 697 are non-atomic; runner overwrites status unconditionally (670, 711). VERIFIED residual L8. |
| 15bebb31 | 2022-06-01 | Server start ok, client start failed | partial start left SJ running, job in running_jobs, max_jobs slot held | job_runner / admin | Critical | HEAD except path job_runner.py:713-731. Residuals: set_status in except unguarded (L2), tokens not cancelled (L4), KeyError race (L9). |
| db90aff6 | 2022-05-09 | Ensure job exit on abort_job | abort did not guarantee SJ termination | job_runner | High | HEAD terminate after grace (server_engine.py:354-409). _stop_run is a no-op once the job left run_processes (job_runner.py:382-383). |
| d3e32795 | 2022-05-09 | FAILED_TO_RUN status | deploy/start failure left job non-terminal | job_runner / job_def | High | FAILED_TO_RUN set at job_runner.py:720 (unguarded, L2). The commit's "delete workspace if job failed to run" is gone: _delete_run (job_runner.py:415-439) has no callers. |
| cb1d5354 | 2022-05-16 | abort could not abort all jobs | multi-job stop reached only part of the jobs | server_engine / training_cmds | High | stop_all_runs iterates live dict (job_runner.py:856) - VERIFIED residual L3; same pattern fed_server.py:1109, training_cmds.py:164. |
| df92fab4 | 2022-05-20 | Config exception during job running | config error in job process not mapped to a failure outcome | worker_process / client_executor / job_runner | High | HEAD: mpm.py:154-157, client_executor.py:41-47/647-674, fed_server.py:942-951, job_runner.py:554-563. Residual L9. |
| 39c247d3 | 2022-05-25 | Schedule/deploy with @ALL | @ALL not expanded consistently | job_scheduler / job_runner / validator | High | Consistent at HEAD (job_scheduler.py:124-128; job_runner.py:177-179, 215-217; job_meta_validator.py:140-145). |
| 72eb5462 | 2022-05-26 | Monitor parent process exit | orphaned job process after parent death | worker_process | High | CJ and SJ monitors (worker_process.py:121-124; runner_process.py:125-126). Low residual: monitor starts after setup, cooperative stop only. |
| 975dc146 | 2022-05-27 | RM cleanup thread; start-app checks; ERROR_MSG_PREFIX | expiry thread not driven; start errors not detected | auto_clean RM / client_engine / scheduler_cmds | High | HEAD: auto_clean_resource_manager.py:93-100; client_engine.py:365-367; admin.py:131-137. Allocation leak on error-string return (L5). |
| a0d75eaa | 2022-05-28 | Abort job after server execution exception | cleanup/abort path assumed live SJ entry | job_runner / server_engine | High | HEAD job_runner.py:574-585. exception_run_processes entries of FAILED_TO_RUN jobs never removed (only 540 for running_jobs) - memory only. |
| eaf1b5ba | 2022-04-29 | min_sites/required_sites missing in Job | admission constraints not carried meta->Job | job_def / client_engine | Medium | job_from_meta maps them (job_def.py:227-244) but without type normalization - VERIFIED residual L1. |
| ec855326 | 2022-05-07 | Empty deploy_map | invalid job reached deploy | job_runner | Medium (msg-only) | Rejected at submit and blocked by scheduler (job_meta_validator.py:115-147; job_scheduler.py:114-116). |
| 365da018 | 2022-05-13 | Client not online deploy error | deploy targeted unscheduled/offline sites | job_runner | Medium | Deploy limited to scheduled sites (job_runner.py:215-217); a scheduled site that disconnects before deploy still fails the whole job (222-226) unlike tolerated failures (269-279) - Low. |
| 05164b14 | 2022-05-23 | Avoid exception swallow | failure hidden by broad except | server_engine | Medium (msg-only) | Start path propagates at HEAD; only intentional swallow at server_engine.py:372-373. |
| a8265f1d | 2022-05-25 | abort_job random EOFError | parent/child command channel closed during abort | fed_server / command agents | Medium (msg-only) | Superseded by cell messaging + forced terminate (server_engine.py:361-383). |
| a8ee3c2b | 2022-05-27 | Fix check client replies | reply evaluation mis-detected failures | admin / job_runner | Medium | admin.py:80-140. Non-strict start tolerance is documented (timeouts.rst:2460-2467), not a defect. |
| 96a64e3c | 2022-05-31 | Benign msgs as non-error | benign replies classified as errors | client_engine | Medium | client_engine.py:357-359, 390-400. No residual. |
| 32ae998b | 2022-03-09 | Open port for client_executor | fixed/conflicting child port -> start failure | client_executor | Low (msg-only) | Superseded (client_executor.py:285 parent cell URL). |
| 198a66f8 | 2022-04-07 | Meta keys not str | non-str meta keys -> inconsistent persisted status/meta | job_def_manager | Low (msg-only) | `.value` keys + str-Enum at HEAD; verified lookup/JSON behavior in py3.12. |
| c023cc9e | 2022-04-21 | Default PYTHONPATH | child env precondition missing | client_executor / server_engine | Low (msg-only) | Superseded (job_launcher_utils.py:486-490). |

## (b) In-scope features/refactors that set lifecycle/resource contracts

- 2684d27a: end of run is two-phase ABOUT_TO_END_RUN -> END_RUN (server_runner.py:203-232).
- 57152d3a: apps deployed/run in the workspace run folder (no tmp copy).
- 55ce1e65: job store + admin job commands; lifecycle recorded as `status` meta.
- d93b0c37: server run executes in a child process (SJ); parent tracks it (server_engine.py:203-330).
- 36c3fc7b: concurrent runs; per-job process tables keyed by job id (server_engine.py:104-105; client_executor.py:191).
- 86f296d3: token protocol check->(ok, token) -> cancel/allocate/free (resource_manager_spec.py:26-88).
- 9b2b96ca: JobRunner schedule->deploy->start->finalize; client CHECK/START/CANCEL handlers (job_runner.py:633-731; scheduler_cmds.py:57-157).
- 26d931cf: per-job participants recorded; abort targets participants ∩ connected (server_engine.py:322-326; job_runner.py:382-389).
- 48daa2a6: submit_job creates SUBMITTED job (job_def_manager.py:308-329).
- 425c1dae: RESOURCE_MANAGER / RESOURCE_CONSUMER are configured site components (scheduler_cmds.py:33-54).
- a6a6664b: abort_job admin command -> JobRunner.stop_run (job_cmds.py:1051-1084).
- 15291460: max_jobs admission counts JOB_STARTED..JOB_COMPLETED/JOB_ABORTED (job_scheduler.py:263-285).
- 7ee222a3: DispatchInfo per site; cancel reservations when min/required-site resource checks fail (job_scheduler.py:207-261).
- 3c35e876: SJ syncs participants from parent (bounded 30 s) (server_engine.py:828-846).
- 478718c6: heartbeat reconciliation; server tells client to abort jobs it does not run (fed_server.py:959-1060; communicator.py:594-646).
- bece044d: FIFO admission by submit time (job_scheduler.py:343-344).
- 279cfcd4: freed units return to pool head (list_resource_manager.py:52-55).

## Mechanism groups (by shared mechanism)

- **G1 Resource-lifetime closure on every exit path** (reservation/allocation must end in allocate+free or cancel/expiry): 1058e40c, 975dc146, 327be8ff, 15bebb31. HEAD residuals: L4 (abandon paths rely on unrefreshed expiry), L5 (error-string return path never frees; free not token-checked).
- **G2 Non-atomic status transitions between admin commands and the runner** (check-then-act, blind overwrite): a6dcce63 (+ a6a6664b contract). HEAD residuals: L8 (verified), L2 trigger (delete vs schedule, verified).
- **G3 Terminal-status derivation from incomplete/async failure signals**: 6bc40bb5, d3e32795, df92fab4, a0d75eaa. HEAD residuals: L6 (unconfirmed), L9 (verified), L8 (terminal->non-terminal regression).
- **G4 Partial success of multi-party deploy/start vs min_sites/required_sites policy**: 15bebb31, 365da018, a8ee3c2b, eaf1b5ba, 39c247d3. HEAD residuals: L1 (verified), deploy unknown-client inconsistency (Low); non-strict start tolerance is documented.
- **G5 Stop/abort not reaching every process of every job; orphaned processes**: db90aff6, cb1d5354, 72eb5462, a8265f1d. HEAD residual: L3 (verified) + two more live-iteration sites.
- **G6 Error-signal classification (false errors / swallowed errors)**: 96a64e3c, 05164b14, a8ee3c2b, 975dc146 (ERROR_MSG_PREFIX). HEAD residual: L5 (error string not treated as failure for cleanup).
- **G7 Job-process start preconditions / input normalization**: 32ae998b, c023cc9e, ec855326, 198a66f8, eaf1b5ba. HEAD residual: L1 (raw, unnormalized min_clients).

## Possible unaudited sites at HEAD

Evidence script (outside repo, real product code + stubs): `batch1_lead_checks.py`; run from source root `python3 <evidence>/archaeology/batch1_lead_checks.py all`; captured output `batch1_lead_checks.out`. `git status --porcelain` empty before and after.

- **L8 [VERIFIED in-memory; Critical] abort of SUBMITTED/DISPATCHED job is lost.** job_cmds.py:1061-1066 sets FINISHED_ABORTED and replies "Aborted the job ... before running it"; runner then blindly writes DISPATCHED (job_runner.py:670) and RUNNING (711) after check-then-act guards (661, 697); set_status has no transition check (job_def_manager.py:459-481). Output: history `FINISHED:ABORTED -> DISPATCHED -> RUNNING`, job started, run_aborted False (both windows: during _deploy_job and during _start_run). Contract: docs/user_guide/admin_guide/deployment/operation.rst:42 ("Aborts the job ... if it is running or dispatched"). Also for a DISPATCHED abort that does take effect, deployed apps and client reservations have no cleanup owner (continue at 697-701). Related: a6dcce63, a6a6664b.
- **L2 [VERIFIED in-memory; High] scheduler loop dies on a concurrent delete -> all later jobs blocked.** delete_job allows SUBMITTED (job_cmds.py:516) using a snapshot from authorization (298-310); `_check_job_status` dereferences `get_job(...)` = None (job_runner.py:737-739) at line 661, which is outside the try (666); run() has no outer guard and is started bare (server_deployer.py:136, 144-145). Output: `AttributeError: 'NoneType' object has no attribute 'meta'` escapes JobRunner.run; job-B stays SUBMITTED. Same failure class: get_jobs_to_schedule at 650 (store _scan can raise StorageException if a job disappears between list_objects and get_meta: job_def_manager.py:517-531, filesystem_storage.py:324-327) and set_status(FAILED_TO_RUN) inside the except handler (720). Window: the scheduler's client resource-check round trip (up to 15 s, server_engine.py:1023). Related: 15bebb31, d3e32795.
- **L1 [VERIFIED in-memory; High, config-edge] raw `min_clients` types break the scheduling pass (head-of-line block).** JobMetaValidator validates a converted copy but persists raw meta (job_meta_validator.py:240-249, 62-86; used at job_cmds.py:1586-1587); job_from_meta passes it raw (job_def.py:241); scheduler compares as int (job_scheduler.py:166 for str before reservation; 229 for None after reservation at 199). TypeError is swallowed at 294-296: the bad job is never counted/marked CANT_SCHEDULE and every later-submitted job is never tried; for null, fresh reservations every pass are never cancelled. Violates contract in tests/unit_test/app_common/job_schedulers/job_scheduler_test.py:455-492. Precondition: hand-authored meta with `min_clients: null` or `"2"` (FedJob API rejects it, job_config/api.py:213). Related: eaf1b5ba, 7ee222a3.
- **L3 [VERIFIED with simulated concurrent pop; Medium] stop_all_runs aborts partway.** job_runner.py:856 iterates live `engine.run_processes.keys()` while wait_for_complete (server_engine.py:233) and _remove_run_processes (408-409) pop on other threads -> RuntimeError after the first job; rest not stopped, ask_to_stop stays False; caller fed_server.fl_shutdown (1243-1247) then skips SYSTEM_END and base shutdown. Same pattern: fed_server.py:1109 (dead-client notify loop over run_processes.items()), training_cmds.py:164 (running_jobs.items() without JobRunner.lock). Related: cb1d5354.
- **L9 [VERIFIED in-memory; Low-Medium] failure report during start -> KeyError -> wrong terminal category.** fail_run pops `_pending_client_outcomes[job_id]` (job_runner.py:841) while `_start_run` later indexes it (359-360) -> KeyError -> except path -> FAILED_TO_RUN + JOB_ABORTED although the job started and failed in execution; its exception_run_processes entry is never removed (540). Related: df92fab4, 15bebb31.
- **L4 [read-verified; Medium] reservations abandoned without CANCEL; expiry unrefreshed.** No cancel on: job_runner.py:661-663, 697-701, 713-720 (deploy exception, job_id None), 692-695 (non-required deploy failures), start timeouts; scheduler exception path (L1); check reply timeout -> (False, "") with unknown token (server_engine.py:1040). All rely on AutoClean expiry (auto_clean_resource_manager.py:102-117, default 30 ticks x check_period); expiry is not extended, so check (<=15 s) + deploy (admin_timeout, default 10 s, configurable) + SJ start can exceed it -> allocate raises (156-163) -> START_JOB error -> whole job FAILED_TO_RUN. Needs a timing experiment. Related: 1058e40c, 975dc146.
- **L5 [read-verified; Low, latent] allocation not freed on error-string start result.** StartJobProcessor frees only in `except` (scheduler_cmds.py:129-133); ClientEngine.start_app returns strings without raising (client_engine.py:357-359, 366-367). free_resources does not check token/ownership (auto_clean_resource_manager.py:166-172), so any double-free would inflate capacity. Not reachable with cooperative participants found so far. Related: 975dc146, 327be8ff.
- **L6 [read-only, needs experiment; potentially Critical] execution-error status can be lost.** SJ reports execution_error only via fire-and-forget UPDATE_RUN_STATUS (server_engine.py:873-884; server_app_runner.py:89-90); parent waits <=2 s after exit (server_engine.py:206-216) and the handler drops it once run_processes is popped (fed_server.py:596-603); that handler uses FederatedServer.lock while wait_for_complete/fail_run use engine.lock (server_engine.py:218; job_runner.py:815-816). With rc 0 after a workflow panic, a late report yields FINISHED_COMPLETED (job_runner.py:545-546). Related: 6bc40bb5.
- **L10 [read-only; Low, GPU-adjacent]** consumers set process-global CUDA_VISIBLE_DEVICES in the client parent (list_resource_consumer.py:37; gpu_resource_consumer.py:33); launcher copies os.environ (process_launcher.py:68); nothing resets it and consume is skipped for empty allocations (scheduler_cmds.py:119-121), so later jobs inherit the previous job's device list; overlapping START_JOB handling on one client could interleave consume->launch.
- Low observations: _delete_run dead code (job_runner.py:415-439) so FAILED_TO_RUN leaves deployed run dirs; deploy unknown-client aborts whole job (job_runner.py:222-226) vs tolerated failures (269-279); GPUResourceManager accepts float/0 expiration (gpu_resource_manager.py:107-110) that the base class rejects (auto_clean_resource_manager.py:42-45) - config-time error only.

## Known matches already present in permitted source (recorded separately)

- docs/user_guide/admin_guide/deployment/operation.rst:42 - abort_job contract ("if it is running or dispatched"); L8 contradicts it.
- tests/unit_test/app_common/job_schedulers/job_scheduler_test.py:455-492 - contract "malformed metadata must not interrupt scheduling"; L1 contradicts it for min_clients.
- docs/release_notes/flare_272.rst:406 - same `None < int` min_clients TypeError mechanism fixed in SwarmServerController (a workflow, out of scope) - mechanism match at a different site.
- docs/programming_guide/timeouts.rst:2460-2467 and docs/user_guide/timeout_troubleshooting.rst:300-302 - document that non-strict START_JOB mode does not enforce min_sites/required_sites; therefore NOT reported as a defect.
