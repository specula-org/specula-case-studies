STATUS: IN PROGRESS

# Phase 3 deep analysis: JobRunner / DefaultJobScheduler / SimpleJobDefManager status writers and interleavings

Pinned source: 53ba7ee567468ea7971dad4faccef13c6cb35dc2 (HEAD). All file:line refs are to this revision.
Scratch dir: evidence/deep/runner_status/ (harness copy + outputs).

## 0. Files read completely
- nvflare/private/fed/server/job_runner.py (869)
- nvflare/app_common/job_schedulers/job_scheduler.py (388)
- nvflare/apis/impl/job_def_manager.py (593)
- nvflare/apis/job_def_manager_spec.py (351)
- nvflare/private/fed/server/job_cmds.py handlers: delete_job_id, configure_job_log, list_jobs, delete_job,
  abort_job, clone_job, submit_job (+ submit-token helpers), _download_job_comps
- nvflare/private/fed/server/training_cmds.py: shutdown, restart, remove_client
- nvflare/private/fed/server/server_commands.py (SJ-side command processors; no parent-side job-status writes)

(sections below are appended incrementally)

## 1. Status-writer table

Legend: Thread = RUN (JobRunner.run loop thread), CMP (JobRunner._job_complete_process thread), ADM (admin command
handler thread), CELL (cell handler thread: process_job_failure / client_heartbeat -> _sync_client_jobs), CLN
(FederatedServer.client_cleanup thread -> logout_client -> notify_dead_client), WFC (ServerEngine.wait_for_complete
thread per SJ), RMP (ServerEngine._remove_run_processes thread per abort), SHUT (server shutdown path).
"Blind" = unconditional write (no compare-and-set against the current persisted value). Note that
SimpleJobDefManager.set_status/update_meta are themselves unlocked read-modify-write of the WHOLE meta file
(filesystem_storage.py:251-275: get_meta -> dict.update -> _write(tmp)+os.replace), so every meta write can also
revert a field (including `status`) written by another thread between its read and its replace.

### 1a. Persistent job status / meta (job store, FilesystemStorage via SimpleJobDefManager)

| ID | Site | Thread | Value written | Guard / precondition checked | CAS? |
|----|------|--------|---------------|------------------------------|------|
| P1 | job_def_manager.py:324,328 create() (submit_job, submit-token path) | ADM | SUBMITTED (new object) | create_object(overwrite_existing=False) | create-only (safe) |
| P2 | job_def_manager.py:345,349 clone() (clone_job) | ADM | SUBMITTED (new object) | clone_object(overwrite_existing=False) | create-only |
| P3 | job_runner.py:670 set_status(DISPATCHED) | RUN | DISPATCHED | _check_job_status(SUBMITTED) at :661, BEFORE multi-second _deploy_job | Blind |
| P4 | job_runner.py:674-689 update_meta(deploy_detail, schedule_*) | RUN | whole meta RMW (status re-written with value read) | none | Blind RMW |
| P5 | job_runner.py:711 set_status(RUNNING) | RUN | RUNNING (+start_time) | _check_job_status(DISPATCHED) at :697, BEFORE _start_run (START_JOB wait up to 20 s) | Blind |
| P6 | job_runner.py:720 set_status(FAILED_TO_RUN) | RUN (except path) | FAILED_TO_RUN | none; unprotected (raise -> escapes run()) | Blind |
| P7 | job_runner.py:724 update_meta(deploy_detail) | RUN (except path) | whole meta RMW | none; unprotected | Blind RMW |
| P8 | job_runner.py:524 set_status(latched status) | CMP | FINISHED_{COMPLETED,ABORTED,EXECUTION_EXCEPTION,ABNORMAL} | job in running_jobs, not in run_processes, outcome wait done; NO check of persisted status | Blind (retry on exception, `continue`) |
| P9 | job_cmds.py:1062 set_status(FINISHED_ABORTED) | ADM (abort_job) | FINISHED_ABORTED | fresh get_job: status in {SUBMITTED, DISPATCHED} (check-then-act) | Blind |
| P10 | job_scheduler.py:303 refresh_meta (NO_RESOURCE jobs) | RUN (inside schedule_job) | whole meta RMW | none (job was SUBMITTED at candidate scan :650) | Blind RMW |
| P11 | job_scheduler.py:307 refresh_meta (blocked jobs) | RUN | whole meta RMW | none | Blind RMW |
| P12 | job_scheduler.py:308 set_status(FINISHED_CANT_SCHEDULE) | RUN | FINISHED_CANT_SCHEDULE | status SUBMITTED at candidate scan (stale by the whole _do_schedule_job duration) | Blind |
| P13 | job_cmds.py:528 job_def_manager.delete() | ADM (delete_job) | object removed (shutil.rmtree, non-atomic) | conn snapshot status (read at authorize time) not in {DISPATCHED, RUNNING} | Blind, stale guard |
| P14 | job_runner.py:770 set_status(FINISHED_ABNORMAL) | restore path | (out of scope: HA/restart) | job not in running_job_ids | Blind |
| P15 | job_runner.py:786 set_status(ABANDONED) | server start | (out of scope: restart) | status in {RUNNING, DISPATCHED} at scan | Blind |
| P16 | _ScheduleJobFilter.filter_job -> store.tag_object (job_def_manager.py:119) | RUN (scan) | "scheduled" tag file | status != SUBMITTED at scan | n/a (hides object from later scans) |

No persisted writer reads the current status atomically with its write; the only guards are check-then-act reads
(P3/P5/P9/P13) separated from the write by network I/O, and P8/P6/P12 have no status guard at all.

### 1b. In-memory lifecycle state

| ID | State / site | Thread | Lock | Guard | Kind |
|----|--------------|--------|------|-------|------|
| M1 | running_jobs[job_id]=job  job_runner.py:709-710 | RUN | self.lock | after _start_run returned | insert |
| M2 | del running_jobs[job_id]  :531-532 | CMP | self.lock | none (blind `del`, value fetched at :446 without lock) | delete (KeyError if absent) |
| M3 | del running_jobs[job_id]  :715-717 | RUN except | self.lock | membership checked | delete |
| M4 | remove_running_job :863-869 (only caller pause_server_jobs, which has NO caller) | - | self.lock | checked | dead code |
| M5 | job.run_aborted=True  mark_run_aborted :807 | ADM (abort_job->stop_run), CELL (UNSAFE_COMPONENT->stop_run; SJ HEARTBEAT->_set_job_aborted), SHUT (stop_all_runs) | none | only if job in running_jobs (else no-op, returns message) | flag set |
| M6 | _pending_client_outcomes[job]=set(client_sites) :308-309 | RUN | self.lock | before START_JOB | insert |
| M7 | _pending_client_outcomes[job].intersection_update :359-360 | RUN | self.lock | NONE: indexes [job_id] (KeyError if popped by fail_run) | update |
| M8 | pop :718 | RUN except | self.lock | - | delete |
| M9 | discard (resolve_client_outcome :118-120) | CELL, CLN | self.lock | - | update |
| M10 | pop :463 (server failed) / clear :474 (deadline) / pop :534 (finalized) | CMP | self.lock | - | delete |
| M11 | pop :841 fail_run | CELL, CLN | self.lock (+engine.lock for the check) | job in running_jobs or run_processes | delete |
| M12 | _client_outcome_deadlines setdefault :468 / pop :464,:535 / pop :842 | CMP / CMP / CELL,CLN | self.lock | - | - |
| M13 | _finished_job_states set :491, mutate :500,:522,:622-623, pop :533 | CMP only | none needed (single thread) except pop under lock | - | latch |
| M14 | engine.exception_run_processes[job] | WFC (server_engine.py:218-232, engine.lock), fail_run (:833, both locks), UPDATE_RUN_STATUS (fed_server.py:595-600, FederatedServer.lock - a DIFFERENT lock) | mixed | fail_run/WFC skip if code already set | insert |
| M15 | engine.remove_exception_process(job) :540 | CMP | engine.lock | executes for every job not in run_processes each pass (unless `continue`) | delete |
| M16 | engine.run_processes[job] insert server_engine.py:321-326; pop :233 (WFC), :408-409 (RMP after <=10 s + terminate) | RUN (inside start_app_on_server), WFC, RMP | engine.lock | - | - |
| M17 | scheduler.scheduled_jobs append on JOB_STARTED job_scheduler.py:276-280 (fired at job_runner.py:364 inside _start_run) | RUN | scheduler.lock | dedup | admission slot acquire |
| M18 | scheduled_jobs remove on JOB_COMPLETED/JOB_ABORTED :281-285 (fired at :537-538 CMP, :728 RUN except) | CMP / RUN | scheduler.lock | membership checked (idempotent) | admission slot release |

## 2. Harness (extended copy) and verification runs

- Harness: `evidence/deep/runner_status/rs_harness.py` (imports `base_harness_snapshot.py`, a byte-copy of
  `evidence/harness/lifecycle_harness.py` taken at 14:07, md5 9bd7ff8a490b910ffca82fa3978c1f8c; the original was not
  edited). Real code: JobRunner, DefaultJobScheduler, SimpleJobDefManager + FilesystemStorage (real temp files),
  JobCommandModule.abort_job/delete_job, FederatedServer.process_job_failure (real handler body, called unbound with a
  minimal `self` providing client_manager/engine/logger), JobMetaValidator.validate on a real zip.
  Stubs only at the RPC/process edge (inherited FakeEngine). Reproduction controls only choose WHEN a real admin/cell
  handler runs (it is started in its own named thread and joined at the chosen point). One explicit fault injection
  (N5 only).
- Command pattern (cwd = evidence/deep/runner_status):
  `timeout 60 python3 rs_harness.py <SCENARIO> --out <SCENARIO>.log > <SCENARIO>.stdout 2>&1`
  Scenarios run: N1_scan_delete, N1c_delete_control, N2a_cant_schedule_overwrites_abort (N2a.*),
  N2b_refresh_resurrects_abort (N2b.*), N3_failrun_during_start (N3.*), N3c_failrun_after_start (N3c.*),
  N4_unsafe_during_start (N4.*), N4c_unsafe_after_start (N4c.*), N6_min_clients_null (N6.*),
  N6s_min_clients_string (N6s.*), N5_cmp_blind_del (N5.*), K2v_delete_during_start (K2v.*). All exit=0.

Key observed outputs (verbatim excerpts):
- N1: `ADMIN delete_job(3d3fd6e6) -> ... deleted` then `JobRunner.run() TERMINATED by exception:
  StorageException: object .../store/jobs/3d3fd6e6-... does not exist` with traceback job_runner.py:650 ->
  job_def_manager.py:514 -> :527 `meta = store.get_meta(job_uri)` -> filesystem_storage.py:327;
  `"later_job_status_after_4s": "SUBMITTED"`, `"later_job_ever_started": false`.
  N1c control (same delete, not overlapping the scan): runner alive, later job RUNNING.
- N2a: `set_status(761d7403, FINISHED:ABORTED) OK` [ADMIN-abort_job, reply "Aborted the job ... before running it."]
  then `set_status(761d7403, FINISHED:CAN_NOT_SCHEDULE) OK` [JobRunner.run]; `"final_X": "FINISHED:CAN_NOT_SCHEDULE"`.
- N2b: `refresh_meta RMW read status=SUBMITTED; admin abort lands now` -> `set_status(f6635258, FINISHED:ABORTED) OK`
  (reply "Aborted the job ... before running it.") -> `"status_after_refresh_write": "SUBMITTED"` -> next pass:
  `deploying job f6635258`, `set_status(.., DISPATCHED)`, `SJ launched`, `event _job_started`,
  `set_status(.., RUNNING)` ... `set_status(.., FINISHED:COMPLETED)`; `"aborted_job_reached_RUNNING": true`.
- N3: `CELL process_job_failure(site-1, code=101) -> rc=ok`, `"pending_right_after_fail_run": ["<popped>"]`,
  `Failed to run the Job (7a51d98e-...): KeyError: '7a51d98e-...'`, `"final": "FINISHED:FAILED_TO_RUN"`,
  `"exception_run_processes_left": ["7a51d98e"]`, events `[_job_aborted]`.
  N3c control (same report after running_jobs insert): `FINISHED:EXECUTION_EXCEPTION`, no leftover entry.
- N4: `Job 34aaf442-... is not running. It can not be stopped.` (inside process_job_failure/UNSAFE), SJ aborted
  (`abort_app_on_server 34aaf442`), then `set_status(.., RUNNING)`, site-2 reports rc 0, `"final": "FINISHED:COMPLETED"`.
  N4c control (same report after running_jobs insert): `run_aborted=true`, `"final": "FINISHED:ABORTED"`.
- N6: `JobMetaValidator.validate -> valid=True err='' min_clients=None`; every second
  `error scheduling job ... job_scheduler.py, line 229 ... TypeError: '<' not supported between 'int' and 'NoneType'`;
  after 6 s `"good_job_status_after_6s": "SUBMITTED"`, `"resource_reservations_by_job": {"bad-min-clients": 5}`,
  `"cancel_calls": 0`, bad job `schedule_count: null` (never incremented).
  N6s ("2"): `valid=True ... min_clients='2'`; TypeError at job_scheduler.py:166 each pass; later job SUBMITTED;
  0 reservations.
- N5 (fault injection): `FAULT INJECTION: set_status(RUNNING) raises` -> runner except path `FINISHED:FAILED_TO_RUN`
  -> completion thread `FINISHED:EXECUTION_EXCEPTION` -> `Exception in thread Thread-1 (_job_complete_process) ...
  job_runner.py, line 532 ... del self.running_jobs[job_id] ... KeyError`; later job2: RUNNING 4 s after its SJ
  exited, `"scheduled_jobs_slots": ["a00dcc18"]` (slot held forever).
- K2v: delete (authorized on a SUBMITTED snapshot) during `_start_run`: `set_status(RUNNING) RAISED StorageException`,
  `set_status(FAILED_TO_RUN) RAISED StorageException`, `JobRunner.run() TERMINATED`; events `[_job_started]` only;
  `"scheduled_jobs_slots": ["f65dd202"]`.

## 3. Interleaving enumeration (thread pairs) and outcomes

Known = coordinator's K-list; "arch Lx" = lead already written (not reproduced) in evidence/archaeology/batch-3.md
section 5 or batch-4.md; NEW = not in K-list nor in archaeology leads.

| # | Threads | Interleaving | Outcome | Class |
|---|---------|--------------|---------|-------|
| I1 | RUN x ADM abort | abort(SUBMITTED) while job is a scheduling candidate, before :661 | :661 sees ABORTED -> skip; reserved tokens not cancelled | K9 |
| I2 | RUN x ADM abort | abort during _deploy_job (store still SUBMITTED) | :670 DISPATCHED over FINISHED_ABORTED, job runs | K1 (A1) |
| I3 | RUN x ADM abort | abort during _start_run (store DISPATCHED) incl. :710-:711 gap | :711 RUNNING over FINISHED_ABORTED | K1 (A2) |
| I4 | RUN x ADM abort | abort lands inside the :674 update_meta RMW | RMW re-writes DISPATCHED over FINISHED_ABORTED | K1 family (extra site P4) |
| I5 | RUN x ADM abort | abort during deploy/start, then deploy/start fails | :720 FAILED_TO_RUN over FINISHED_ABORTED (terminal->terminal) | K1 family (arch L6) |
| I6 | RUN x ADM abort | abort of a queued job X during another candidate's resource check in the pass where X is blocked | job_scheduler.py:308 CANT_SCHEDULE over FINISHED_ABORTED | **NEW RS-3** (confirmed N2a) |
| I7 | RUN x ADM abort | abort of a queued job lands inside refresh_meta RMW (job_scheduler.py:303 -> filesystem_storage.py:273-275) | FINISHED_ABORTED -> SUBMITTED; job later scheduled and RUNS | **RS-2** (arch L2, now confirmed N2b) |
| I8 | RUN x ADM delete | delete of an untagged job between list_objects and get_meta in the 1 s scan | StorageException escapes job_runner.py:650 -> JobRunner.run dies | **RS-1** (arch L3, site not in K2; confirmed N1) |
| I9 | RUN x ADM delete | delete of SUBMITTED job during schedule/deploy | :661 AttributeError / :720 StorageException -> run dies | K2 (G1/G2) |
| I10 | RUN x ADM delete | delete authorized on SUBMITTED snapshot, executes during _start_run | :711 + :720 raise -> run dies; JOB_STARTED without ABORTED/COMPLETED -> slot leak | K2 variant **RS-8** (confirmed K2v) |
| I11 | RUN x CELL | process_job_failure(fail code) during _start_run between :309 and :360 | fail_run pops pending -> KeyError at :360 -> FAILED_TO_RUN, exception entry leaked | **NEW RS-4** (confirmed N3) |
| I12 | RUN x CELL | same report between :360 and :710 | EXECUTION_EXCEPTION/ABORTED/ABNORMAL as designed | benign |
| I13 | RUN x CELL | process_job_failure(UNSAFE_COMPONENT) -> stop_run between :304 and :710 | SJ+CJs aborted, mark_run_aborted no-op -> FINISHED_COMPLETED | **NEW RS-5** (confirmed N4) |
| I14 | RUN x CELL | heartbeat _resolve_missing_client_outcome during start | job in run_processes or exception entry exists -> no fail_run | benign |
| I15 | RUN x CMP | SJ exits before :711; CMP publishes terminal first | RUNNING after terminal, stuck | K3 |
| I16 | RUN x CMP | :711 raises (transient store error) while CMP finalizes the same job | runner except deletes running_jobs entry; CMP `del` at :532 KeyError -> CMP dies; also FAILED_TO_RUN overwritten by EXECUTION_EXCEPTION | **NEW RS-7** (confirmed N5, fault injection) |
| I17 | CMP x ADM abort | abort(RUNNING) while CMP waits for client outcomes (SJ already exited normally) | run_aborted -> FINISHED_ABORTED, wait skipped; clients aborted later by heartbeat sync | design (not a defect) |
| I18 | CMP x ADM abort | abort(RUNNING) after status latched in _finished_job_states | admin told "Abort signal has been sent", final = latched status | benign |
| I19 | CMP x CELL | fail_run during outcome wait | next pass sees exception entry -> server_failed -> EXECUTION_EXCEPTION | correct |
| I20 | CMP x CELL | fail_run vs CMP finalization (:531-:540) | serialized by JobRunner.lock; fail_run either sees job inactive or its entry is removed at :540 | benign |
| I21 | CMP x WFC / UPDATE_RUN_STATUS | UPDATE_RUN_STATUS uses FederatedServer.lock, not engine.lock | same dict object stored in both maps; no lost code | benign |
| I22 | RUN (scheduler) x input | job with min_clients null / "2" accepted at submit | TypeError in _try_job every pass; later jobs never reached; null variant leaks reservations each pass | **NEW RS-6** (confirmed N6) |
| I23 | SHUT x WFC | stop_all_runs iterates live run_processes | RuntimeError | K4 |
| I24 | ADM shutdown x RUN/CMP | training_cmds.py:164 iterates live running_jobs.items() | RuntimeError in admin thread (command error only) | K4-like, **RS-10** (code reading) |
| I25 | CLN x WFC | fed_server.py:1108 notify_dead_client iterates live engine.run_processes.items(); client_cleanup loop (fed_server.py:290-304) has no try | RuntimeError would end the dead-client sweep thread | K4-like cross-area, **RS-10** (code reading) |

### 3a. JOB_STARTED / JOB_ABORTED / JOB_COMPLETED pairing (admission slot = DefaultJobScheduler.scheduled_jobs)

| Path | STARTED (:364) | ABORTED | COMPLETED | Slot |
|------|----------------|---------|-----------|------|
| normal finish | yes | - | :538 | released |
| abort/fail while RUNNING (in running_jobs) | yes | :537 if status ABORTED | :538 | released |
| stop_run after SJ exit, job still in running_jobs | yes | :537 | :538 | released (status ABORTED unless already latched) |
| _start_run raises before :364 (incl. RS-4 KeyError) | no | :728 | - | no-op |
| :711/:712 raises, handler completes | yes | :728 | - | released |
| :711 raises and :720/:724 raise (K2/K2v) | yes | never | never | **leaked** (runner also dead) |
| skip at :663 / :701 | no | - | - | none (tokens leak, K9) |
| CMP set_status keeps failing (:525-530 `continue`) | yes | never | never | **leaked** while it fails (needs a persistent store failure, e.g. object deleted while in running_jobs) |
| CMP thread dead (RS-7) | yes | never | never | **leaked** for all running and later jobs |
| RS-5 (UNSAFE during start) | yes | never (status not ABORTED) | :538 | released, wrong status |
Double release is harmless (membership-checked remove, job_scheduler.py:283-285).

## 4. Findings

### RS-1  Concurrent delete during the 1 s candidate scan kills JobRunner.run (admission halts permanently)
- Claim: `JobRunner.run` calls `job_manager.get_jobs_to_schedule(fl_ctx)` outside any try (job_runner.py:650).
  `SimpleJobDefManager._scan` lists job dirs (`store.list_objects`, job_def_manager.py:519) and then reads each job's
  meta (`store.get_meta`, :527) and may tag it (`store.tag_object`, :119) without tolerating a job that vanished in
  between. FilesystemStorage.get_meta raises StorageException for a missing object (filesystem_storage.py:325-327);
  tag_object would raise FileNotFoundError (:435-439). The exception escapes run(); `_start_job_runner`
  (server_deployer.py:144-145) has no guard/restart. The completion thread keeps running, so only admission stops.
- Trigger: ordinary `delete_job` (allowed for SUBMITTED / finished jobs, job_cmds.py:516) of any job not yet tagged
  "scheduled" (every SUBMITTED job, plus jobs whose status changed less than ~1 scan ago) landing between the listing
  and that job's meta read. `delete_object` is `shutil.rmtree` (non-atomic), which additionally lets `_read` fail on a
  half-removed object.
- Window: from the moment the listing passes the job until `_scan` reaches it: proportional to the number of job dirs
  (listing checks 3 paths per dir, incl. all historical jobs) plus meta reads of queued jobs; repeats every ~1 s.
- Compensating mechanisms: none (no try, no restart, no watchdog). K2 covers :661/:697/:720 only.
- Verdict: CONFIRMED (harness N1; control N1c shows the same delete outside the window is harmless).
  Matches archaeology lead batch-3 L3 (not reproduced there); the :650 site is not part of K2.
- Severity: High (a single ordinary admin action with a timing coincidence stops all later scheduling until server
  restart; no user-visible error).

### RS-2  Scheduler refresh_meta read-modify-write resurrects an aborted queued job (FINISHED_ABORTED -> SUBMITTED; job then runs)
- Claim: for every job that fails a scheduling attempt, `schedule_job` calls `job_manager.refresh_meta(job, keys)`
  (job_scheduler.py:300-303) -> `update_meta` -> `FilesystemStorage.update_meta(replace=False)`: `prev_meta = get_meta()`,
  `prev_meta.update(schedule keys)`, `_write(meta)` (filesystem_storage.py:251-275) with no lock (the only lock in
  SimpleJobDefManager is `_submit_record_lock`). If `abort_job` (job_cmds.py:1058-1066: status SUBMITTED ->
  `set_status(FINISHED_ABORTED)`) commits between that read and that replace, the scheduler writes the stale
  `status: SUBMITTED` back. The job is then an ordinary candidate again; once resources suffice it is deployed,
  DISPATCHED, started, RUNNING and finishes COMPLETED, although the admin received "Aborted the job ... before
  running it."
- Trigger/assumptions: user aborts a queued job that is waiting for resources (NO_RESOURCE retries, the common reason
  a job stays queued); abort commit must fall in the RMW window. Measured window on this host (ext4, fsync in
  `_write`): median 3.6 ms, p90 4.8 ms, max 10.6 ms (`rmw_window_probe.py` -> `rmw_window_probe.out`). The job is
  retried with backoff (10 s .. 600 s), so per-abort likelihood is low; impact is an explicitly aborted job running.
- Compensating mechanisms: `_check_job_status(SUBMITTED)` at :661 passes (status really is SUBMITTED again); the
  "scheduled" tag is only created by the scan in the same thread, so it cannot hide the resurrected job.
- Verdict: CONFIRMED (harness N2b: `status_after_refresh_write: SUBMITTED`, `aborted_job_reached_RUNNING: true`,
  final COMPLETED). Reproduction control only chose the moment the real abort_job handler ran (inside the real
  update_meta read->write window). Matches archaeology lead batch-3 L2 example (not reproduced there).
  Same RMW also exists at job_runner.py:674 (P4, reverts to DISPATCHED: K1 family) and :724 (P7, terminal only).
- Severity: Medium (High impact: terminal->non-terminal regression, aborted job consumes resources and runs;
  low likelihood per abort).

### RS-3  FINISHED_CANT_SCHEDULE blindly overwrites a user abort (terminal -> different terminal)
- Claim: blocked jobs are decided from the candidate snapshot taken at job_runner.py:650; after the whole
  `_do_schedule_job` pass (including other candidates' resource checks, up to 15 s each, server_engine.py:1022)
  `schedule_job` writes `set_status(FINISHED_CANT_SCHEDULE)` unconditionally (job_scheduler.py:305-308).
  An abort committed in that window (store FINISHED_ABORTED; admin told "Aborted the job ... before running it.")
  is overwritten.
- Compensating mechanisms: none; no status re-check before :308.
- Verdict: CONFIRMED (harness N2a: history ADMIN FINISHED:ABORTED then JobRunner.run FINISHED:CAN_NOT_SCHEDULE).
- Severity: Low (both terminal, no resource effect; outcome misreported, user action not reflected).

### RS-4  fail_run during _start_run -> KeyError at job_runner.py:360 -> misclassified FAILED_TO_RUN + leaked exception record
- Claim: `_start_run` registers `_pending_client_outcomes[job_id]` at :308-309, then waits for START_JOB replies
  (`start_client_job`, up to 20 s, server_engine.py:1082) and later does
  `self._pending_client_outcomes[job_id].intersection_update(...)` (:359-360) without checking the key.
  A client whose CJ fails right after launch reports REPORT_JOB_FAILURE; `process_job_failure` accepts it
  (`is_client_outcome_pending` is already true, fed_server.py:938) and calls `fail_run` (fed_server.py:951), which sees
  the job in `engine.run_processes` (SJ launched at :304), records the code in `exception_run_processes` and pops
  `_pending_client_outcomes[job_id]` (job_runner.py:841). The runner then raises KeyError at :360 and takes the generic
  except path: FAILED_TO_RUN (:720), JOB_ABORTED (:728), second `_stop_run`. The `exception_run_processes` entry is
  never removed (only CMP removes entries, :540, and the job never entered running_jobs).
- Trigger: realistic with >1 client: a fast client's CJ crashes during startup (CP converts rc 1 while STARTING to
  INFRASTRUCTURE_ERROR, client_executor.py:639-643; or EXCEPTION/CONFIG_ERROR/ABORTED) while another client's START_JOB
  reply is still outstanding.
- Contract impact: fail_run is documented as the authoritative terminal failure (job_runner.py:837-840); the same
  report arriving slightly later gives FINISHED_EXECUTION_EXCEPTION / FINISHED_ABNORMAL / FINISHED_ABORTED (control N3c).
  Leak is per job id (no cross-job effect); duplicate ABORT to SJ/CJs.
- Verdict: CONFIRMED (harness N3: `Failed to run the Job (...): KeyError`, `final: FINISHED:FAILED_TO_RUN`,
  `exception_run_processes_left: [7a51d98e]`; control N3c: EXECUTION_EXCEPTION, no leftover). Note: the shared
  harness received a scenario `K_failrun_during_start` from another agent while this analysis ran; this finding was
  derived and verified independently in rs_harness.py with the real process_job_failure body.
- Severity: Low.

### RS-5  UNSAFE_COMPONENT report during the start window: SJ and CJs are aborted but the job is finalized FINISHED_COMPLETED
- Claim: `process_job_failure` maps `UNSAFE_COMPONENT` to `job_runner.stop_run` (fed_server.py:952-955).
  `stop_run` = `_stop_run` (aborts SJ + clients whenever `engine.run_processes` has the job, job_runner.py:381-393) +
  `mark_run_aborted`, which only sets `job.run_aborted` if the job is already in `running_jobs` (:802-811); the return
  message is ignored by the caller. Between `start_app_on_server` (:304) and `running_jobs[job_id]=...` (:709-710)
  the SJ exists but the job is not in running_jobs, so the abort is executed but not recorded. The runner then inserts
  the job and writes RUNNING; the aborted SJ exits normally (ServerRunner.abort only triggers abort_signal,
  server_runner.py:607-611; start_server_app returns; mpm rc 0/None), so no exception record exists and
  `_classify_finished_job_status(None)` = FINISHED_COMPLETED (:545-546); other clients' aborted CJs report rc 0 or 1,
  which only resolve outcomes.
- Trigger: component-authorization rejection in a CJ (the typical UNSAFE_COMPONENT moment is CJ startup) reported
  while the runner is still in `_start_run` (other START_JOB replies outstanding).
- Compensating mechanisms: none for the status; the SJ heartbeat path `_set_job_aborted` (fed_server.py:616-622)
  only applies to jobs missing from run_processes that still heartbeat.
- Verdict: CONFIRMED (harness N4: `Job ... is not running. It can not be stopped.`, SJ aborted, final
  FINISHED:COMPLETED; control N4c: same report after insertion -> run_aborted true -> FINISHED:ABORTED).
  Not in K-list; archaeology batch-4 row 352 / batch-3 L4 discuss the UNSAFE->ABORTED mapping and rc mapping, not this
  window.
- Severity: Medium (a job rejected by site security policy and actually aborted is reported as successfully completed;
  outcome depends on timing).

### RS-6  One accepted job with `min_clients: null` (or a numeric string) stalls the scheduler for every later job
- Claim: JobMetaValidator treats `min_clients: null` as "not set" (job_meta_validator.py:240-249, `if value is not
  None`) and validates strings via int conversion without normalizing meta. `job_from_meta` passes the raw value
  (job_def.py:241). `_try_job` guards :166 with `job.min_sites and ...` but not :229 (`num_sites_ok < job.min_sites`),
  and a string fails at :166. The TypeError escapes `_try_job` -> `_do_schedule_job` -> caught by the bare `except` in
  `schedule_job` (job_scheduler.py:292-296). Consequences: (a) the loop over candidates (sorted by submit time,
  :344-376) aborts at the bad job every pass, so every later-submitted job is never tried; (b)
  `_update_schedule_history` is skipped, so schedule_count/last_schedule_time never change: no backoff, never
  blocked, retried every ~1 s forever; (c) null variant: the resource check (client reservation, :199) happened and is
  never cancelled -> a new leaked reservation per pass.
- Compensating mechanisms: an admin can abort/delete the bad job (its status is SUBMITTED); the error is only in the
  server log ("error scheduling job" every second).
- Verdict: CONFIRMED (harness N6: validator `valid=True min_clients=None`; TypeError at job_scheduler.py:229 every
  pass; later job SUBMITTED after 6 s; 5 reservations, 0 cancels; N6s: `min_clients='2'` -> TypeError at :166,
  later job starved).
- Severity: Medium (input is accepted by the product's own validation; one job blocks admission of all later jobs and
  (null) leaks client reservations each second until noticed). The FedJob/recipe APIs always emit a positive int, so
  the trigger needs a hand-written meta.
- Hardening note (unsupported input, not counted): user meta.json may also carry internal keys `schedule_count`,
  `last_schedule_time`, `schedule_history` (create() does not strip them); malformed values raise at :347-359 or in
  `_update_schedule_history` AFTER a successful reservation, same halt pattern.

### RS-7  Blind `del self.running_jobs[job_id]` in the completion thread (job_runner.py:532) can kill finalization for all jobs
- Claim: CMP fetches `job` without the lock (:446), finalizes (status latch, workspace archival, set_status) and then
  deletes with `del self.running_jobs[job_id]` (:531-532) without a membership check. The runner's except path deletes
  the same key (:715-717) when anything after :710 raises (only `set_status(RUNNING)` at :711 can). If that happens
  while CMP is finalizing the same job (SJ already exited, e.g. failed at startup), CMP raises KeyError, the thread
  ends (no try around the loop body), and no job is ever finalized again: RUNNING forever, `scheduled_jobs` slots held
  (default max_jobs=1 -> admission halted). The same interleaving also overwrites FAILED_TO_RUN with
  FINISHED_EXECUTION_EXCEPTION.
- Trigger/assumptions: a transient job-store write failure at :711 (e.g. I/O error) coinciding with CMP finalizing
  that job; a persistent failure (object deleted) makes CMP's own set_status fail too and it never reaches :532.
- Verdict: CONFIRMED mechanically with explicit fault injection (harness N5: `KeyError` traceback at :532, completion
  thread dead, job2 RUNNING 4 s after its SJ exit, slot held). Real trigger requires the stated fault.
- Severity: Low (likelihood) / High (impact).

### RS-8  (variant of K2) delete during `_start_run` leaves JOB_STARTED without JOB_ABORTED/COMPLETED
- delete_job checks the authorize-time snapshot (job_cmds.py:507-521, JOB set by authorize_job_id :282-316), so a job
  that turned DISPATCHED after authorization can be deleted while `_start_run` runs. :711 and then :720 raise, run()
  dies (K2), and because JOB_STARTED already fired (:364) the `scheduled_jobs` entry is never removed.
- Verdict: CONFIRMED (harness K2v: events only `_job_started`, `scheduled_jobs_slots: [f65dd202]`). Additional
  consequence of known K2, not a new root cause.

### RS-9  Additional K9 sites (reservation tokens only reclaimed by expiry)
- Deploy-failed clients: `deployable_clients` excludes `failed_clients` (job_runner.py:692-695); their tokens from
  `_try_job` are never cancelled. RS-6 (null) path: reservation made at job_scheduler.py:199 then exception before
  any cancel. Also: skip paths :663/:701 and every exception path in run() (already K9). Code reading.

### RS-10  More live-collection iterations (K4 pattern)
- training_cmds.py:164 `for _, job in engine.job_runner.running_jobs.items()` (admin shutdown) without JobRunner.lock
  while RUN/CMP insert/delete (:710/:532): RuntimeError in the admin thread (command fails). Low.
- fed_server.py:1108 `notify_dead_client` iterates `engine.run_processes.items()` while WFC/RMP pop entries; caller
  chain `client_cleanup` -> `remove_dead_clients` -> `logout_client` (fed_server.py:290-330) has no try, so a
  RuntimeError would end the dead-client sweep thread (dead clients no longer removed, outcome resolution via that path
  lost). Cross-area (server_engine/fed_server); code reading only, PLAUSIBLE.

### RS-11  PLAUSIBLE / not triggered (developer signals)
- CMP calls `_get_finished_job_status` -> `abort_client_run` unprotected at :489; `abort_client_run` catches only
  RuntimeError (:408-413). Any other exception from the fan-out ends CMP. No concrete trigger found.
- `_start_runner_process` stores `job_clients or self.client_manager.clients` as PARTICIPANTS (server_engine.py:318-326):
  an empty job_clients (all deployable clients disconnected between deploy and :296) aliases the live client dict,
  later iterated by `_get_active_job_participants` in CMP (:489) / RUN except path (:719) -> possible RuntimeError.
  Edge; not reproduced.
- Start-phase policy asymmetry: a deployable client that disconnected between deploy and start gets no START_JOB
  request, so `check_client_replies` raises "not enough replies" (admin.py:104-105) even in non-strict mode, where
  timed-out clients are silently excluded -> FAILED_TO_RUN regardless of min_sites. Clean failure; noted only.

### Refuted / benign candidates
- `_try_job` ALL_SITES aliasing (`applicable_sites = online_site_names` then `.append`) and duplicate sites across
  apps: unreachable for accepted jobs; JobMetaValidator rejects ALL_SITES combined with any other site and duplicate
  sites (job_meta_validator.py:140-151). Required sites outside deploy map -> NO_RESOURCE until blocked (correct).
- `_job_complete_process` `list(self.running_jobs.keys())` (:444): a single C-level copy under the GIL; not a K4 site.
- fail_run vs CMP finalization and vs wait_for_complete: serialized by JobRunner.lock/engine.lock, code-precedence
  logic consistent (server_engine.py:218-233, job_runner.py:815-842).
- UPDATE_RUN_STATUS under FederatedServer.lock (fed_server.py:594-603): stores the same dict object as run_processes,
  so no lost return code.
- Abort while CMP waits for client outcomes -> FINISHED_ABORTED and wait skipped: explicit design (:466).
- Lifecycle events carry explicit job ids (`_fire_job_lifecycle_event` + `get_event_job_id`), so slot release cannot
  hit another job.
