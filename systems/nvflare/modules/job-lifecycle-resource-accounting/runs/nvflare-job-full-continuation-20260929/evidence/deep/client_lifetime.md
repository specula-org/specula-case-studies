# Phase 3 deep analysis: CLIENT PARENT (CP) resource ownership and job-process lifetime

STATUS: IN PROGRESS

Pinned source: /home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/full/source (HEAD 53ba7ee5)
Scratch dir: .specula-output/evidence/deep/client_lifetime/

## 0. Files read (completeness log)
(appended as read)

Read completely (pinned HEAD 53ba7ee5):
- nvflare/private/fed/client/client_executor.py (696), client_engine.py (527), scheduler_cmds.py (184),
  training_cmds.py (213), admin.py (191), fed_client_base.py (449), communicator.py 530-649 (heartbeat/quit)
- nvflare/app_common/resource_managers/{auto_clean,list,gpu,passthrough}_resource_manager.py
- nvflare/app_common/resource_consumers/{gpu,list,passthrough}_resource_consumer.py, nvflare/apis/resource_manager_spec.py
- nvflare/utils/process_utils.py (352), nvflare/app_common/job_launcher/{process,client_process}_launcher.py,
  nvflare/utils/job_launcher_utils.py (504), nvflare/private/fed/utils/fed_utils.py get_job_launcher/get_return_code
Adjacent (read for tracing only): client_train.py (CP main, SYSTEM_START at :218), worker_process.py main (CJ,
  parent monitor :49-50,:122-124), client_app_runner.py start_run/notify_job_status/stop, app/utils.py monitor_parent_process,
  fuel/f3/mpm.py run (os._exit when non-daemon threads remain), fed_server.py client_heartbeat/_sync_client_jobs (959-1076),
  job_runner.py (_deploy_job, _start_run, _stop_run, run loop), server_engine.py start/abort/check/cancel/start_client_job,
  job_scheduler.py _try_job, app_deployer.py, master_template.yml (default client resources.json; sub_start.sh restart loop),
  fuel/f3/sfm/conn_manager.py (FRAME_THREAD_POOL_SIZE=100), core_cell.process_message/_process_request.

## 1. Harness (scratch, real product code; stubs only at network/process/nvidia-smi edges)

- `client_lifetime/cp_harness.py` (extended copy of evidence/harness/client_harness.py): real Check/Start/Cancel/Abort/
  NotifyJobStatus processors, ClientEngine.start_app/abort_app/shutdown (instance via __new__), the whole JobExecutor
  path (_PendingJobHandle, launch, attach, _wait_child_process_finish, abort_app, _terminate_job), the real
  ProcessJobLauncher.launch_job (os.environ.copy + posix_spawn(setsid)) with only get_command replaced by
  `child_stub.py` (records pid/pgid/CUDA_VISIBLE_DEVICES, optional same-pgid grandchild, sleeps), List/GPU resource
  managers + consumers (GPU edge: get_host_gpu_ids/get_host_gpu_memory_free patched to 2x16 GiB).
  Reproduction controls (timing only): Gate component blocking at BEFORE_JOB_LAUNCH (before STARTING registration)
  or inside launch_job (after registration, before spawn).
- Commands: `python3 cp_harness.py --out runN.json --only <scenario...>` (outputs run1_f1.json, run2_f2.json,
  run3_k7v_s5.json + .log/.stdout in client_lifetime/).

## 2. Path table: CHECK_RESOURCE -> process exit (resource-unit accounting)

Measured with `client_lifetime/path_matrix.py` (CountingLRM = real ListResourceManager + recording hooks only;
pool gpu=[0,1,2,3]; each path isolated in its own engine) -> `run4_path_matrix.json`. "free@leader-alive" = a free
happened while the CJ leader pid was alive; "free@pgid-desc" = a same-process-group descendant was alive at free time.

| Path | reserve | cancel/expire dealloc | allocate (raised) | free | exactly-once | lost / dup | free@leader-alive | free@pgid-desc | Free site |
|---|---|---|---|---|---|---|---|---|---|
| P01 success, CJ exits rc0 | 1 | 0/0 | 1 (0) | 1 | yes | -/- | no | no | client_executor.py:676-679 |
| P02 allocate fails (reservation expired) | 1 | 0/1 | 0 (1) | 0 | yes | -/- | - | - | expiry auto_clean:114-116 |
| P03 consume raises | 1 | 0/0 | 1 (0) | 1 | yes | -/- | - (no proc) | - | scheduler_cmds.py:131-133 |
| P04 launch raises (posix_spawn ENOENT -> Popen raises) | 1 | 0/0 | 1 (0) | 1 | yes | -/- | - | - | scheduler_cmds.py:131-133 (entry popped client_executor.py:312-316) |
| P05 start_app raises pre-registration (meta mismatch) | 1 | 0/0 | 1 (0) | 1 | yes | -/- | - | - | scheduler_cmds.py:131-133 |
| P05b start_app returns error STRING (K5, known) | 1 | 0/0 | 1 (0) | **0** | **no** | **[0] lost** | - | - | none |
| P06 ABORT while STARTING, before attach (pending handle) | 1 | 0/0 | 1 (0) | 1 | yes | -/- | no | no | :676 after kill at attach (:318-320) |
| P07 admin ABORT while STARTED (CJ ignores msg; kill after 10.0 s) | 1 | 0/0 | 1 (0) | 1 | yes | -/- | no | no | :676 |
| P08 ABORT while STOPPED-but-alive (kill after 10.0 s) | 1 | 0/0 | 1 (0) | 1 | yes | -/- | no | no | :676 |
| P09 heartbeat-cleanup abort while STARTED | 1 | 0/0 | 1 (0) | 1 | yes | -/- | no | no | :676 |
| P10 duplicate START_JOB same token while STARTING | 1 | 0/0 | 1 (1) | 1 | yes | -/- | no | no | 2nd allocate raises (auto_clean:163) |
| P11 dup START fresh token: STARTING -> "still registered" (freed); STARTED -> K5 string | 3 | 0/0 | 3 (0) | 2 | **no** | **[1] lost (K5)** | no | no | :131-133 for 2nd; none for 3rd |
| P12 2x admin ABORT + heartbeat cleanup concurrently (STARTED) | 1 | 0/0 | 1 (0) | 1 | yes | -/- | no | no | :676 (killpg x3 harmless) |
| P13 CJ leader exits normally, same-pgid grandchild alive (K8) | 1 | 0/0 | 1 (0) | 1 | yes | -/- | no | **yes** | :676 |
| P14 ABORT while STARTED; leader exits inside 10 s grace; grandchild survives abort (K8 variant) | 1 | 0/0 | 1 (0) | 1 | yes | -/- | no | **yes** | :676; `_terminate_job` returns early :587-589, no killpg |
| P15 cancel + expiry + duplicate cancel, no allocate | 2 | 1/1 | 0 | 0 | yes | -/- | - | - | cancel :142-144, expiry :114-116 |
| F1 ABORT before STARTING registration (run1_f1.json) | 1 | 0/0 | 1 (0) | 1 (only after later heartbeat cleanup) | yes | -/- | no | no | :676; abort itself dropped |
| S5 CP shutdown with running CJ + outstanding reservation (run3) | 2 | 0/0 (expiry thread stopped) | 1 | 0 by CP | n/a (CP exits) | reservation never expires after SYSTEM_END | - | - | none; CJ stops itself on parent death (F7) |

Conclusions for Q1:
- Every in-process path frees each allocated unit exactly once, and never while the CJ leader is alive (free only in
  the StartJobProcessor exception branch where no process exists, or after `job_handle.wait()` reaped the leader).
- Lost capacity only via K5 (error-string returns; no supported trigger found, see Sec. 5) and K9 (expiry-only
  reclamation). No double-free caller exists on the CP (K6 stays a latent defensive gap; see Sec. 5).
- Units ARE returned while the job's process group can still use them (P13/P14, K8), including after an explicit abort.
- Resource *binding* (CUDA_VISIBLE_DEVICES) can conflict even when unit accounting is exact: F2/F2r below.

## 3. Findings (new, or new variants of known candidates)

### CL-1 ABORT that overtakes START_JOB before the STARTING entry exists is dropped as "already stopped"; START_JOB then launches the CJ anyway
- Claim: `ClientEngine.abort_app` (client_engine.py:390-404) decides from `get_status()` whose default for an
  unregistered job is STOPPED (client_executor.py:690-692) plus `job_id not in get_run_processes_keys()`, and returns
  "Client app already stopped." without recording anything. The STARTING entry (and its `_PendingJobHandle`, which
  exists precisely to "Hold an abort request until a launcher returns the real job handle", :52-77/:299-320) is only
  registered at client_executor.py:300-307, after allocate (scheduler_cmds.py:116), consume (:121), deployed-meta
  read/write (client_executor.py:225-250) and `get_job_launcher` (BEFORE_JOB_LAUNCH event, fed_utils.py:618-641).
  An ABORT processed in that window (FedAdminAgent requests run concurrently on the cell frame pool, 100 threads,
  conn_manager.py:43/:396) is lost; START_JOB then registers, launches, and the CJ runs holding its allocation.
- Trigger / assumptions: server sends TrainingTopic.ABORT (abort_client_run, job_runner.py:395-413) while this
  client's START_JOB is still pre-registration: (T1) `fail_run` after another client's fast CJ failure report
  (job_runner.py:813-852 -> _stop_run); (T2) `_start_run` raising after a start-reply timeout/explicit error of
  another client (job_runner.py:318-337, :713-720) while this slow client (>20 s, server_engine.py:1082) is still
  pre-registration; (T3) stop_all_runs during a start. Needs a slow pre-registration phase on the CP (e.g. slow
  `nvidia-smi` calls in GPUResourceConsumer.consume, slow BEFORE_JOB_LAUNCH handlers/disk). Admin `abort_job` during
  start does not send ABORT (status DISPATCHED -> status-only abort, E1), so it is not a trigger.
- Compensation: heartbeat reconciliation — once the SJ is gone (T1/T2 abort it), `_sync_client_jobs`
  (fed_server.py:1004-1017) lists the job in ABORT_JOBS and the CP calls abort_app(heartbeat_cleanup=True)
  (communicator.py:622-623/:640-649). Orphan window ~ heartbeat interval (10 s default) + SJ teardown (<=11 s) + CJ
  grace (<=10 s if STARTED). No compensation for T3 (server going away). Documented as eventual sync (G4).
- Verification: CONFIRMED (harness, real code; timing control = Gate at BEFORE_JOB_LAUNCH). run1_f1.json:
  abort_reply "Client app already stopped." with `registered: {}`; START_JOB then replied "Start the client
  app..."; 3 s later child alive, entry STARTING, gpu 0 still allocated, no CP->CJ message; only the later
  heartbeat-cleanup call killed it and freed the unit. Control F1c (abort after registration, before spawn): abort
  honoured, child killed at attach, unit freed.
- Severity: Low (bounded orphan + held capacity, compensated by heartbeat except T3; abort reply misleading).

### CL-2 Resource binding is process-global and never reset: a job whose allocation is empty inherits the previous job's CUDA_VISIBLE_DEVICES
- Claim: consumers write the CP's `os.environ` (gpu_resource_consumer.py:33; list_resource_consumer.py:37) and
  `ProcessJobLauncher.launch_job` copies `os.environ` (process_launcher.py:68). `consume` is skipped when the
  allocation is empty (scheduler_cmds.py:119-121), which is the normal case for jobs without GPUs because
  `get_resource_manager_spec` drops `num_of_gpus: 0` (job_launcher_utils.py:320-322) and GPUResourceManager reserves
  `{}` (gpu_resource_manager.py:176-186). Nothing restores the variable after a job ends.
- Consequence: default config (GPUResourceManager + GPUResourceConsumer, master_template.yml:71-85): job B with no GPU
  requirement, started after/concurrently with GPU job A, is bound to A's device(s) although B owns none; contradicts
  "This ensures that each concurrent job will be using different GPU devices" (job.rst:313-316) when B uses CUDA.
  Before any GPU job ran, B would see all GPUs (CP env) — so B is unrestricted either way; the defect is the
  history-dependent steering onto a device that is accounted to another job.
- Verification: CONFIRMED (harness; GPU edge stubbed 2x16 GiB). run2_f2.json: Z->GPU0 ("0"), A->GPU1 ("1"),
  B rm_spec {} -> child CUDA_VISIBLE_DEVICES "1" while A (GPU1) still registered; CP env left at "1".
- Q4 variant (failed operation leaves state): a START_JOB that fails after consume (launch error) frees its units
  (scheduler_cmds.py:131-133) but leaves CUDA_VISIBLE_DEVICES naming them. run7_f2f.json (cp_harness_f2f.py): job A
  (2 GPUs) launch fails -> units freed, CP env "0,1"; job C then legitimately gets GPU0 ("0"); job B (rm_spec {})
  inherits "0" and shares C's device. A job started right after A's failure would have been bound to "0,1".
- Scope note: device *binding* of the resource-ownership chain (A8), not GPU computation. Severity: Low.

### CL-3 Overlapping START_JOB handlers race on os.environ: a job can be launched bound to another job's GPU (conflicting assignment)
- Claim: consume (env write) and launch (env copy) of two START_JOBs are not atomic w.r.t. each other
  (scheduler_cmds.py:116-128; process_launcher.py:68). If B's consume runs between A's consume and A's launch,
  A's process gets B's device; A's allocated device stays idle but accounted.
  (Same window: `os.environ.copy()` iterating while another thread first inserts CUDA_VISIBLE_DEVICES can raise
  "dictionary changed size", failing a launch; not reproduced, theoretical.)
- Trigger / assumptions: two START_JOBs for different jobs processed concurrently on one CP. The server's job runner
  sends START_JOBs sequentially and waits <=20 s for replies (job_runner.py:310, server_engine.py:1082), so overlap
  requires the first START_JOB to exceed the 20 s reply timeout pre-launch (then the next job can be scheduled).
- Verification: CONFIRMED mechanism (harness; Gate holds A at BEFORE_JOB_LAUNCH after consume). run2_f2.json
  F2r: env while A held "0" (A owns GPU0), B owns GPU1; both children report CUDA_VISIBLE_DEVICES "1".
- Severity: Low (rare precondition), but it directly violates the A8 ownership statement.

### CL-4 (K7 variant, supported trigger) CP death/shutdown/restart during CJ bootstrap leaves a busy-spinning CJ that parent-death cleanup cannot stop
- Claim: the CJ's STARTED notification loop (client_app_runner.py:177-215, known K7: never returns after
  retry_timeout, and after the timeout it no longer sleeps) is not interruptible by `ClientAppRunner.stop()`
  (:233-235), which is the only action of the parent-death monitor (app/utils.py:45-50; worker_process.py:122-124),
  and the monitor thread exits after calling it. When the CP process is gone, `send_request` to the CP returns
  COMM_ERROR immediately (core_cell.py:1531-1552 no waiter when nothing was sent), so the loop spins at full speed
  logging an ERROR per attempt. The CJ runs in its own session (posix_spawn setsid, process_utils.py:338), is not
  killed by sub_start.sh (`kill -9 $pid` of the CP only, master_template.yml:684-698), and the restarted CP has no
  record of it (in-memory run_processes / resource manager), so no heartbeat reconciliation can reach it.
- Trigger: CP process exit (admin shutdown/restart client, crash, stop_fl kill -9) at any time between CJ launch and
  the CJ's first successful NOTIFY_JOB_STATUS STARTED — i.e. the whole CJ bootstrap (imports, config, component
  construction, cell connect: seconds). Nothing in that bootstrap blocks on the CP (sync_up_parents_process is local,
  client_run_manager.py:317-343).
- Verification: CONFIRMED with real CellNet processes (k7v_real_cells.py -> run6_k7v_real_cells_procs.json): root
  cell process + CP cell process + CJ cell (this process) running the real notify loop; control notify OK in 7 ms;
  after SIGKILL of the CP process and `runner.stop()` (client_runner.abort called once), the loop never returned:
  9007 attempts in the first 4 s, 15499 in the next 4 s (~3875/s), every reply `comm_error` in ~0-2 ms.
  Unit level also in run3 (K7v: 70 further attempts within 4 s after stop()). Not run as a full worker_process.
- Compensation: none automatic (F7 is defeated; heartbeat reconciliation belongs to the dead CP). Manual kill only.
- Severity: Medium (permanent orphan process: 100% of a core + unbounded job-log growth; invisible to the new CP,
  which may admit new jobs as if the host were idle).

### CL-5 (K8 site/variant) An explicit abort does not kill same-group descendants if the CJ leader exits inside the grace period
- Claim: `_terminate_job` (client_executor.py:581-601) returns as soon as the run_processes entry disappears
  (:587-589), i.e. as soon as `_wait_child_process_finish` reaped the leader and freed the units (:676-681); no
  `killpg` is ever sent. (Even if it were, K8: `ProcessAdapter._kill_process_group` resolves the pgid from the
  reaped leader pid and returns on ProcessLookupError, process_utils.py:300-304.) Descendants that share the CJ's
  process group (e.g. training subprocesses started without a new session) survive the abort and keep using units
  that are already back in the pool.
- Verification: CONFIRMED (path_matrix P14): leader exits 2 s after ABORT, `grandchild_alive_after_abort_returned:
  true`, free recorded with `grandchild_alive_at_free: true`. P13 is the known K8 normal-exit case.
- Severity: as K8 (known root cause); listed only as an additional site.

### CL-6 (design limitation / observation) CP shutdown or restart neither aborts nor waits for CJs; all CP-side ownership state is in memory
- Facts: `ClientEngine.shutdown/restart` (client_engine.py:442-460) fire SYSTEM_END (stops the reservation-expiry
  thread, auto_clean:96-100) and start `shutdown_client` (:512-527: heartbeat_done, close/logout, status STOPPED);
  `FederatedClientBase.terminate` only logs (fed_client_base.py:447-449). The main loop then exits
  (client_train.py:178-181) and mpm `os._exit`s because the non-daemon `_wait_child_process_finish` threads are still
  alive (mpm.py run: non-daemon thread check -> os._exit). Running CJs are left to F7 (monitor_parent_process,
  1 s poll, cooperative `client_runner.abort()`); the restarted CP (>= ~10-15 s later via sub_start.sh loop) starts
  with a full resource pool and an empty run_processes.
- Harness S5 (run3_k7v_s5.json): after shutdown() the child stayed alive and registered, no CP->CJ message was sent,
  the allocation was not freed, and an outstanding reservation no longer expired (expiry thread stopped).
- Verdict: PLAUSIBLE, Low under the cooperative-participant assumption (F7 normally stops the CJ within seconds);
  residual overlap comes from CL-4 (bootstrap window, never stops) and CL-5/K8 (descendants). Documented only for
  container backends (G7); nothing documents that the process backend relies solely on CJ self-termination.

## 4. Concurrency map (Q2)

CP threads: (a) cell frame pool, 100 threads (conn_manager.py:43,:91,:396) running `FedAdminAgent._dispatch_request`
(admin.py:100-177) for every CLIENT_MAIN topic, concurrently, no per-job serialization; (b) heartbeat thread (daemon,
fed_client_base.py:396-399 -> communicator.py:581-638); (c) one non-daemon `_wait_child_process_finish` thread per
launched CJ (client_executor.py:330-334); (d) short `_terminate_job` threads spawned+joined by abort_app (:518-520,
:531-533); (e) AutoClean expiry thread (auto_clean:102-117); (f) `shutdown_client` thread (client_engine.py:447/:457).

| Shared state | Writers (lock) | Readers (lock) | Observed consequence |
|---|---|---|---|
| `JobExecutor.run_processes` membership | register (:300-307, lock), launch-fail pop (:313-315, lock), wait-thread pop (:680-681, lock) | get_run_processes_keys (:695, lock); `get_status` (:691, NO lock); check_status (:365, NO lock); wait-thread handle read (:626, NO lock) | TOCTOU in ClientEngine.abort_app (unlocked get_status + separate keys read, then act) -> CL-1 |
| entry STATUS | notify_job_status (:347-350, NO lock, last-writer-wins, no monotonicity) | abort_app (:497-504 lock), wait thread RC classification (:632-643 lock), ClientEngine.start_app/abort_task (unlocked) | lock on reader side does not order against the unlocked writer; a late/duplicate STARTED could regress STOPPED (CJ serializes STARTED->run->STOPPED, so only a delayed duplicate of a retried STARTED could; negligible) |
| entry `_abort_requested` | abort_app (:500, lock) | wait thread (:635, lock) | consistent |
| `_PendingJobHandle` | own lock (:56-77) | own lock | consistent (P06, F1c) |
| resource manager pool/reservations | check/cancel/allocate/free/expiry all under `self._lock` (auto_clean:123,141,155,167,105) | report (:175, lock) | unit accounting exact in every path (Sec. 2); no ownership check on free (K6) |
| process `os.environ` (CUDA_VISIBLE_DEVICES) | consumer.consume in START_JOB threads (gpu_resource_consumer.py:33, list_resource_consumer.py:37; NO lock) | ProcessJobLauncher.launch_job `os.environ.copy()` (process_launcher.py:68; NO lock) | CL-3 (overlap), CL-2 (persistence across jobs) |
| `FederatedClientBase._shutdown_lock` | close() (fed_client_base.py:430-445) | send_request_before_shutdown (:423-428) held across a <=5 s request | frees of concurrently exiting CJs are serialized behind each other's outcome reports (free happens after the report, :648-679); benign delay |
| `communicator.heartbeat_done` | shutdown_client, close (lock), client_register/send_heartbeat on FLCommunicationError | heartbeat loop, send_request_before_shutdown (lock) | once set, no heartbeat reconciliation and no outcome reports; CP exits shortly after (CL-6) |
| AutoClean `_cleanup_thread` | SYSTEM_START/SYSTEM_END handlers (auto_clean:93-100) | - | after SYSTEM_END reservations never expire (S5); a second SYSTEM_START would raise (thread None / already started) — only fired once per CP (client_train.py:218) |
| heartbeat thread time budget | abort_app(heartbeat_cleanup) is synchronous; STARTED/STOPPED jobs block it <= 10 s each (:518-533, :581-595) | - | heartbeats delayed N x 10 s; server dead-client timeout default 600 s (server_deployer.py:74) -> negligible |

Other per-topic notes: DELETE_RUN (training_cmds.py:143-155 -> client_engine.py:482-487) and DEPLOY (AppDeployer
rmtree of an existing run dir, app_deployer.py:55-56) do not consult run_processes; neither is sent for a running
job in supported flows (delete_workspace disabled, job_cmds.py:163-171; one deploy per scheduled job).

