# Main-context reading notes (persisted incrementally)

Pinned source: 53ba7ee567468ea7971dad4faccef13c6cb35dc2 (2026-09-11). History restricted to `git rev-list HEAD` (3305 commits).
Excluded: refs/remotes/origin/main (7636087a, 2026-09-23, newer than pin) and any non-ancestor refs (`--all` = 4085 commits).
GitHub issues/PRs NOT consulted (not a permitted source in this pilot); archaeology uses commit messages + diffs only.
Python: nvflare imports resolve to full/source/nvflare/__init__.py (venv nvflare-lite-full-opus55-20260925/nvflare-venv).
persistent-findings-context.json: previous=null, inherited_records={} (no prior-run history).

## Files read in full (session 1)
- nvflare/apis/resource_manager_spec.py (88 lines)
- nvflare/app_common/resource_managers/auto_clean_resource_manager.py (176)
- nvflare/app_common/resource_managers/list_resource_manager.py (82)
- nvflare/app_common/resource_managers/passthrough_resource_manager.py (105)
- nvflare/app_common/resource_managers/gpu_resource_manager.py (203)
- nvflare/app_common/resource_consumers/{gpu,list,passthrough}_resource_consumer.py
- nvflare/app_common/job_schedulers/job_scheduler.py (388)
- nvflare/private/fed/server/job_runner.py (869)

## Observations to verify (NOT yet findings)
O1 AutoCleanResourceManager.free_resources (auto_clean_resource_manager.py:166-172) deallocates the given dict with no
   token/ownership check. ListResourceManager._deallocate appendleft()s units (list_resource_manager.py:52-55);
   GPUResourceManager._deallocate adds memory (gpu_resource_manager.py:148-150). A double free (or free of never-allocated
   resources) would duplicate units / inflate capacity -> conflicting assignment later. Need: all free_resources callers.
O2 Reservation expiry is tick based: _check_expired (102-117) decrements each check_period (1.0s) from expiration_period
   (30) and deallocates. allocate_resources raises RuntimeError if token gone (153-164). Window check->allocate spans
   server deploy of app to all clients + server app start. If >30s, client start fails. Need: client start path.
O3 Cleanup thread only starts on SYSTEM_START (93-100). Is SYSTEM_START delivered to the client-parent resource manager?
O4 GPUResourceManager accepts float/0 expiration_period (107-110) but base requires int>0 (42-45): inconsistent validation.
O5 DefaultJobScheduler admission = len(scheduled_jobs) < max_jobs (263-273); scheduled_jobs mutated only by events
   JOB_STARTED (append) / JOB_COMPLETED|JOB_ABORTED (remove) (275-285) + restore/remove_scheduled_job (380-388).
   If JOB_ABORTED/COMPLETED is delivered before JOB_STARTED for the same job, slot would leak. Check event ordering.
O6 _try_job: tokens obtained at 199; exceptions after that (AFTER_CHECK_CLIENT_RESOURCES handlers at 201, loop 212-227)
   are caught by schedule_job (292-296) without cancel -> reservations leak until expiry.
O7 _try_job success returns dispatch info only for sites with enough resources (212-261).
O8 JobRunner.run (633-734): scheduler returns job+tokens; `_check_job_status(...SUBMITTED)` -> `continue` at 661-663
   without cancelling the tokens just reserved; `_check_job_status(...DISPATCHED)` -> `continue` at 697-701 after
   deploy without cancel/cleanup of deployed clients.
O9 JobRunner.run exception handler (713-731): when _deploy_job raises, job_id is None -> no _stop_run, no
   cancel_client_resources for reserved tokens; status FAILED_TO_RUN; JOB_ABORTED fired.
O10 Status publication order at 709-711: running_jobs[job_id]=job (under lock) THEN set_status(RUNNING) (outside lock).
   _job_complete_process thread (441-541) may finalize a fast-failing job (server_failed skips outcome wait) between
   710 and 711 -> terminal status overwritten by RUNNING? Need job_def_manager.set_status transition guards.
O11 _start_run non-strict mode: clients with no reply are dropped from active set (345-353) but may still start later.
O12 mark_run_aborted sets job.run_aborted without lock (802-811); stop_run = _stop_run + mark_run_aborted.

## ENVIRONMENT LIMIT (session 2)
- full/source/.git has no local objects; alternates -> /home/experiment/repos/nvflare/.git/objects, which is a PARTIAL CLONE
  (remote.origin.promisor=true, partialclonefilter=blob:none). `git rev-list --objects --missing=print HEAD` reports
  20550 missing objects. All 405 core-path commits have unreadable diffs (evidence/archaeology/unreadable-diffs.txt).
- Available: commit objects (full messages/PR bodies), trees (name-status), HEAD blobs (working tree).
- Decision: do NOT lazy-fetch/`git fetch` (network to GitHub; could pull post-pin objects; outward-facing). Archaeology
  uses commit bodies + file lists + current HEAD code/tests. All subagents instructed accordingly.

## Files read in full (session 2)
- nvflare/private/fed/client/scheduler_cmds.py (184), client_engine.py (527), client_executor.py (696)
- nvflare/app_common/job_launcher/{process,client_process,server_process}_launcher.py, nvflare/apis/job_launcher_spec.py
- nvflare/utils/process_utils.py ProcessAdapter/spawn_process; nvflare/apis/utils/event.py fire_event_to_components
- server_engine.py: 92-131, 161-420, 846-930, 1005-1100; admin.py check_client_replies (80-140), send_requests
- job_cmds.py: delete_job_id (337-361), delete_job (507-548), abort_job (1051-1084)
- job_def_manager.py: filters (60-121), set_status (459-481), update_meta/refresh_meta, scans

## More observations (session 2)
O13 StartJobProcessor (scheduler_cmds.py:96-137): allocate_resources consumes token; frees only on EXCEPTION (129-133).
    ClientEngine.start_app (client_engine.py:349-382) returns strings (no raise) for "already started" (357-359) and
    "ERROR: Client app does not exist" (365-367) AFTER allocation -> allocation never freed (not in reserved dict, so
    auto-clean cannot reclaim) = permanent capacity loss candidate. Need reachability (who deletes app dir between
    deploy and start? DELETE_RUN sender = job_cmds.delete_job_id (343: only guards engine.run_processes)).
O14 JobExecutor.start_app (client_executor.py:198-334): registers STARTING entry (299-307) before launch; launch failure
    pops+raises (312-316) -> StartJobProcessor frees. After launch: AFTER_JOB_LAUNCH event (326; fire_event swallows
    handler exceptions), waiter thread started (330-334). _wait_child_process_finish (622-688): wait, rc, report
    failure (try/except), free_resources (676-679, no try), pop entry (681), fire JOB_COMPLETED (687).
O15 abort_app (486-547): marks _ABORT_REQUESTED; STARTING -> pending/real terminate; STOPPED -> _terminate_job; STARTED
    -> ABORT msg + _terminate_job (10s grace then killpg). Statuses EXCEPTION(4)/NOT_STARTED -> "already terminated".
O16 Server _remove_run_processes (server_engine.py:385-409) ALWAYS terminate()s captured handle (killpg SIGKILL) even
    after graceful exit, then pops run_processes; may pop before wait_for_complete (203-234) reads run_process_info ->
    SJ rc not recorded. killpg after reap = PID-reuse hazard (low probability).
O17 check_client_replies (admin.py:80-140): explicit ERROR-prefixed reply from ANY client raises (fails whole job);
    timeouts tolerated per min_sites/required_sites in _start_run.
O18 check_client_resources (server_engine.py:1010-1041): no reply -> (False,"") -> reservation made by a slow client is
    never cancelled (expiry only). Offline sites silently omitted.
O19 job_def_manager.set_status (459-481): NO transition guard (unconditional merge). abort_job for SUBMITTED/DISPATCHED
    (job_cmds.py:1061-1066) only writes FINISHED_ABORTED; JobRunner.run later writes DISPATCHED (670) / RUNNING (711)
    unconditionally -> abort can be overwritten and job runs anyway (candidate "lost abort"). Check at 697 is TOCTOU.
O20 JobRunner._delete_run (job_runner.py:415-439) has no callers (dead code).

## VERIFIED IN REAL CODE (harness: evidence/harness/lifecycle_harness.py; logs: evidence/harness/logs/*.stdout|*.log)
Command: cd evidence/harness && python3 lifecycle_harness.py <scenario> --out logs/<scenario>.log
- S0_control: 2 jobs, max_jobs=1 -> each DISPATCHED->RUNNING->FINISHED:COMPLETED, JOB_STARTED/COMPLETED balanced.
- A1_abort_during_deploy: admin abort_job reply "Aborted the job ... before running it." but store history
  FINISHED:ABORTED -> DISPATCHED -> RUNNING -> FINISHED:COMPLETED; SJ launched + START_JOB sent after abort.  [LOST ABORT]
- A2_abort_during_start: DISPATCHED -> FINISHED:ABORTED -> RUNNING -> FINISHED:COMPLETED. [LOST ABORT]
- G1_delete_during_schedule: delete_job(SUBMITTED) during resource check -> JobRunner.run() dies with
  AttributeError 'NoneType' object has no attribute 'meta' (job_runner.py:661 -> :739); later job stays SUBMITTED. [ADMISSION HALT]
- G2_delete_during_deploy: set_status(DISPATCHED) StorageException -> handler set_status(FAILED_TO_RUN) StorageException
  escapes -> run() dies; later job never scheduled. [ADMISSION HALT]
- B_running_overwrite (reproduction control delays set_status(RUNNING) until completion published): final RUNNING after
  FINISHED:EXECUTION_EXCEPTION; running_jobs/scheduled_jobs empty; abort_job -> "is not running"; delete_job -> "is
  running, could not be deleted". [STATUS REGRESSION; needs runner descheduling between :710 and :711]
- specula findings lookup (abort_job,set_status,JobRunner.run,delete_job,_check_job_status,free_resources,notify_job_status) -> []
- H_stop_all_runs: 2 RUNNING jobs; SJ of job1 exits during the loop -> JobRunner.stop_all_runs raises
  "RuntimeError: dictionary changed size during iteration" (job_runner.py:856 iterates live engine.run_processes.keys());
  job2 never aborted, ask_to_stop stays False. Path: admin shutdown/restart -> server_shutdown -> fl_shutdown
  (fed_server.py:1243-1247) -> stop_all_jobs (server_engine.py:1089-1091). SYSTEM_END + super().fl_shutdown() skipped.
- pgroup_probe.py (real spawn_process/ProcessHandle): leader alive -> terminate() kills descendant; leader exited+reaped
  -> terminate() no-op (getpgid(leader) ProcessLookupError, process_utils.py:300-304) -> descendant survives in job pgid.
  In-tree Client API trainer uses start_new_session=True (external_process_backend.py:488-500) so it is NOT affected.
- contracts.md (subagent, STATUS: COMPLETE): default client GPUResourceManager(num_of_gpus=0,mem=0,expiration_period=300)
  + GPUResourceConsumer + ClientProcessJobLauncher; server DefaultJobScheduler(max_jobs=4); U1 reservations reclaimed
  only by expiry on skip/fail paths; U3 disconnect between schedule and deploy/start fails whole job; U5 signal exit ->
  EXECUTION_ERROR so -9 branch unreachable for process SJ.
- client_harness.py (real Check/Start/CancelResourceProcessor, ClientEngine.start_app, JobExecutor, ListResourceManager,
  ClientAppRunner.notify_job_status) -> logs/client_harness.json:
  C1 START with app dir absent: reply "NVFLARE_ERROR: Client app does not exist..."; unit 0 neither free nor reserved
     after expiry window; later 2-unit job refused. [LATENT PERMANENT LEAK; trigger outside supported envelope]
  C3 expiry vs slow deploy: B admitted after A expired; A START fails "No reserved resources for token"; no double
     assignment (safety holds; A's job fails).
  C4 double free_resources duplicates unit ([0,0,1]); next allocation gets [0,0]. [DEFENSIVE GAP; no known caller]
  C2 notify_job_status(retry_timeout=1.0) still retrying after 6 s (100 attempts). [CONFIRMED retry-bound defect]
- l9_l1_probe.py -> logs/l9_l1_probe.json (main-context re-verification of archaeology leads):
  L9 JobMetaValidator._validate_min_clients accepts "2" and None (job_meta_validator.py:225-249; converted value not
     written back); scheduler raises TypeError at job_scheduler.py:166 ("2") / :229 (None), swallowed at :294-296
     BEFORE _update_schedule_history -> bad job schedule_count stays 0 (never CANT_SCHEDULE); later valid job never
     started in 6 s; runner alive. [HEAD-OF-LINE ADMISSION STARVATION]
  L1 GPUResourceManager(1 GPU, 1 GiB): alloc 0.1 + 0.2 then free in reverse -> memory 0.9999999999999999; 1 GiB job
     refused afterwards (gpu_resource_manager.py:148-150,188-197). [PERMANENT CAPACITY LOSS, float accounting]
- archaeology batch-1/2/3 COMPLETE (all diffs unavailable; classified from bodies+file lists+HEAD code).
  batch-1 extra: KeyError variant - fail_run during _start_run pops _pending_client_outcomes -> _start_run :359-360
  KeyError -> FAILED_TO_RUN for a job that started (verified by batch-1 agent, batch1_lead_checks.py).
  batch-2 extra: L6 exception status only via fire-and-forget UPDATE_RUN_STATUS + 2 s grace (server_engine.py:873-884,
  207-233); L10 restart reconciliation (update_unfinished_jobs etc.) has no callers (confirmed grep: no callers);
  L4 CUDA_VISIBLE_DEVICES inherited by later jobs; notify_dead_client live-dict iteration (fed_server.py:1109).
  batch-3 extra: L2 FilesystemStorage.update_meta unlocked RMW (filesystem_storage.py:251-275) lost-update risk;
  L8 engine.lock held across <=5 s send_request (server_engine.py:899-928).
- archaeology ALL COMPLETE: b1 100 (23a/17b/59c/1?), b2 100 (19a/14b/64c/+3 possible), b3 100 (9a/12b/79c),
  b4 60 (9a/10b/41c), b5 45 (18a/4b/23c) => 405 commits; 78 (a) in-scope fixes; 57 (b); 266 (c); 4 undetermined.
  b5 contracts list (13) = invariant anchors. b5 extra: L5 second shape resource_spec {site:{"process":"x"}} passes
  validation but get_resource_manager_spec raises ValueError (job_launcher_utils.py:315-316) -> same starvation;
  L7 client_cleanup loop (fed_server.py:290-304, no try) -> remove_dead_clients -> logout_client -> notify_dead_client
  iterates live engine.run_processes.items() (:1109) -> RuntimeError would kill dead-client sweeper permanently;
  L8(a) portable num_of_gpus carries no mem (not allowed under @default, job.rst:144-145) -> GPUResourceManager reserves
  0 memory -> unlimited sharing of GPU 0 (vs job.rst:313-316 "each concurrent job will be using different GPU devices",
  stated for the list-based example manager) [contract ambiguity]; R1 status publication retried unbounded holding slot.
- K_failrun_during_start (main-context verification of batch-1 L9 / batch-5 L3): client failure report during
  _start_run -> fail_run accepted (records EXCEPTION, pops pending, _stop_run) but returns "Job ... is not running.";
  _start_run KeyError at job_runner.py:360 -> FINISHED:FAILED_TO_RUN (not EXECUTION_EXCEPTION); exception_run_processes
  entry left; slots balanced (JOB_ABORTED only). [WRONG TERMINAL CATEGORY + stale entry + misleading message]
- rmw_probe.py -> logs/rmw_probe.json: scheduler NO_RESOURCE refresh_meta (update_meta RMW) paused between read and write
  (timing control only) while admin abort_job wrote FINISHED_ABORTED -> final SUBMITTED; aborted job still returned by
  get_jobs_to_schedule. [F16 LOST UPDATE -> queued-job abort lost; tiny window per retry]
