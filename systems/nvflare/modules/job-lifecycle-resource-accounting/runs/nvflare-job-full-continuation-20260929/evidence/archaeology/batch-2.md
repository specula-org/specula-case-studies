# Bug Archaeology Batch 2 (core-commits.txt lines 101-200)

STATUS: COMPLETE

Repository: /home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/full/source
Pinned HEAD: 53ba7ee567468ea7971dad4faccef13c6cb35dc2 (all 100 batch commits verified ancestors via `git merge-base --is-ancestor`).
Classes: (a) in-scope bug fix; (b) in-scope feature/refactor changing lifecycle/resource semantics; (c) out of scope.

## Environment limit (read first)
Historical diffs were UNAVAILABLE: the checkout borrows objects through alternates from a blobless partial clone; 568/568 core-path blobs touched by this batch are missing (`git cat-file -e` fails), so `git show <sha> -- <paths>` / `--stat` abort with "unable to read". No workaround was attempted (no fetch, no git command in the alternate repo). ALL 100 commits were therefore classified from full commit message + touched-file list (`git log -1 --format=%B`, `git show --no-renames --name-status`), and every mechanism / completeness claim was checked against the CURRENT HEAD source. Where the historical mechanism is inferred rather than stated in the message, the row says "inferred" or "unverifiable".

## Coverage statistics
| Metric | Count |
|---|---|
| Commits examined | 100 (lines 101-200) |
| Classified from message + file list only (diff unavailable) | 100 |
| (a) in-scope bug fixes | 19 (4 of them with inferred/unrecoverable mechanism: 7e9d036a, 8a3e3cb0, 5535bdb7, 9e1881da) |
| a? possible in-scope fix, mechanism unrecoverable | 3 (d7b3cccf, da28bc40, 0bc36461) |
| (b) in-scope semantic features/refactors | 14 (+58eb05f6 also carries a (b) part) |
| (c) out of scope | 64 |
| HEAD leads recorded | 13 (L1-L13); 4 confirmed by unit/harness runs against this arm's source (L1, L9, L11, L12) |

## (a) In-scope bug fixes
| Commit | Date | Summary | Root-cause mechanism | Component | Severity | Fix completeness at HEAD (file:line) |
|---|---|---|---|---|---|---|
| 03789dd9 | 2022-06-02 | abort_train with retry | abort racing a naturally exiting worker; run_processes entry removed at wrong point | CP JobExecutor abort | Medium | Retry loop kept (client_executor.py:493-545); single pop in waiter (680-681) + launch-failure pop (312-316). _terminate_job still SIGKILLs the process group of a possibly already-reaped pid after the 10 s wait (client_executor.py:581-600; process_utils.py:293-316) - PID-reuse hazard, Low. |
| def5c04c | 2022-06-15 | Delete job command enhance | no status guard on deleting an active job's store entry | admin delete_job | High | Guard only for DISPATCHED/RUNNING using job meta cached at authz time (job_cmds.py:516-521); delete itself unguarded (job_def_manager.py:354-356). SUBMITTED-but-in-flight jobs unprotected -> L12 (confirmed). |
| df539aab | 2022-09-23 | deploy error when one site rejects | one site's DEPLOY rejection escalated to whole-deploy error instead of per-site failure + min_sites/required_sites | SP JobRunner._deploy_job | High | Per-site handling now (job_runner.py:250-282). Reservations of rejected/timed-out sites never cancelled (692-695, 713-731) -> L2. |
| 7e9d036a | 2022-10-05 | Fix server engine abort_app_on_server | unrecoverable from message ("Fix server engine") | SP SJ abort | Medium (tentative) | HEAD abort path server_engine.py:354-409; see L3 (pop before RC recording; global engine_info.status). |
| 783f192b | 2022-10-07 | CTR-C kill all child processes | parent termination left job children running | CJ/parent teardown (mostly simulator) | Low | HEAD SJ/CJ watch parent liveness (monitor_parent_process, runner_process.py:126, worker_process.py:123). |
| 9a822f93 | 2022-10-12 | GPU check only when num != 0 | host validation applied to zero-capacity config | GPUResourceManager ctor | Low | Complete (gpu_resource_manager.py:116-117, 162-163, 185-186). |
| 2c89c887 | 2022-10-14 | Enhance job run status | terminal status from SJ process exit only, ignoring SJ-reported outcome | SP status derivation | Critical | SJ reports via fire-and-forget UPDATE_RUN_STATUS (server_app_runner.py:89-90; server_engine.py:873-884; fed_server.py:593-603), SP waits <=2 s (server_engine.py:207-217) -> L6. |
| 82fec3f7 | 2022-10-14 | Default False, token None | unsafe defaults on resource-check path (failure read as "enough") | CP CheckResource / scheduler | Medium | Complete for defaults (scheduler_cmds.py:65, 86-88; server_engine.py:1027-1040, 1058). Late replies -> L2. |
| 58eb05f6 | 2022-11-16 | Dead clients handle | iterating shared run_processes while other threads add/pop | SP engine/job tables | High | Snapshot used in get_engine_info (server_engine.py:149), pause_server_jobs (1094); NOT in stop_all_runs (job_runner.py:856), notify_dead_client (fed_server.py:1109), shutdown cmd (training_cmds.py:164) -> L5. |
| 0c03cf34 | 2023-01-20 | CJ terminate, not logout | job-process teardown used site-scope logout | CJ teardown | High | Complete: CJ calls terminate() (worker_process.py:152-153); logout only from CP close() (fed_client_base.py:430-445, caller client_engine.py:520). Other site-scope side effect remains -> L8. |
| 508c7d23 | 2023-03-02 | status not EXCEPTION on controller exception | controller exception not reaching SP status decision (report not matched to job) | SJ->SP status | Critical | Chain server_runner.py:153-156, 252-256 -> server_engine.py:873-884 -> fed_server.py:593-603; SJ exit code 0 on this path, so correctness rests on best-effort message within 2 s -> L6. |
| 3225529d | 2023-03-09 | job runner multiple start | scheduling loop startable more than once (HA trigger) -> duplicate dispatch | SP JobRunner | High | Complete for default path: single start (server_deployer.py:136, 144-145) + HotState gate (job_runner.py:643). |
| 8a3e3cb0 | 2023-03-16 | fix job status (inferred) | SJ exit vs status-report race decided before report arrived (inferred) | SP wait_for_complete | Critical (inferred) | Bounded 2 s wait (server_engine.py:207-217) -> L6. |
| 5535bdb7 | 2023-03-20 | Enhance job meta validator (inferred) | job meta the scheduler cannot process (no server in deploy_map) made scheduling raise | submit validation / scheduler | High (inferred) | Input-side only (job_meta_validator.py:146-147). Scheduler still aborts whole round on any per-job exception, no bookkeeping (job_scheduler.py:292-296, 364-369); validator/scheduler type mismatch on min_clients -> L9 (confirmed). |
| 30fbc3b0 | 2023-03-21 | Fix cell timing | commands to not-yet-connected job cell treated as hard errors | CP->CJ command channel | Low | Commands optional (client_executor.py:389, 420, 451, 479, 528, 618; message_send.py:76-79). |
| 9e1881da | 2023-03-22 | status after job aborted + server restarted | abort intent only in memory; restart left wrong recorded state | SP status / restart | High | Restart reconciliation hooks now have NO callers (job_runner.py:762-796) -> L10. |
| 1571296f | 2023-03-22 | abort job with only connected clients | abort to disconnected participant failed target validation | SP abort_client_run | High | _get_active_job_participants (job_runner.py:78-96, 381-393, 575-585). Residual all-or-nothing send (job_runner.py:63-66, 412-413), recovered by heartbeat sync (fed_server.py:1004-1017) - Low. |
| 07c3e3c5 | 2023-03-28 | cell not stopped on config error | error exit path skipped cell stop -> job process hang | job-process teardown | High | Complete (worker_process.py:131-156; runner_process.py:132-153; mpm.py:154-156). |
| b25e6bd3 | 2023-03-31 | job status for config error | config-error exit not mapped to failure terminal status | SP status derivation | Critical | CONFIG_ERROR -> FINISHED_EXECUTION_EXCEPTION (job_runner.py:554-563); client CONFIG_ERROR -> fail_run(EXCEPTION) (fed_server.py:942-951). -9 branch unreachable -> L7. |

Possible in-scope fixes with unrecoverable mechanism (a?): d7b3cccf (2022-11-28, "race condition" in fed_server.py), da28bc40 (2023-03-01, QA bugs in job_runner/job_cmds), 0bc36461 (2023-03-23, QA issues in job_runner/job_cmds/client_app_runner).

## (b) In-scope semantic changes
- 34105850 (2022-06-14): admin delete_job re-introduced -> job-store entry may vanish while scheduler/runner hold a Job.
- 92b013bd (2022-09-01): ServerAppRunner/ClientAppRunner extracted; SJ always reports status + STOPPED in `finally` (server_app_runner.py:53-93).
- e5e8c15a (2022-09-09): sites may refuse DEPLOY (authz); per-site deploy detail; abort only if min_sites/required_sites violated.
- 242d831b (2022-09-14): GPUResourceManager + GPUResourceConsumer; allocation exported via process-global CUDA_VISIBLE_DEVICES.
- 5b7713f2 (2022-09-21): AutoCleanResourceManager: reservation = uuid-token lease auto-released after expiration_period unless allocated.
- b17d94ce (2022-09-22): GPUResourceManager becomes the default site resource manager (HEAD template: expiration_period 300, master_template.yml:72-79).
- 8693f5f2 (2022-09-30): ListResourceConsumer, same global-env export.
- 903567c7 (2022-10-20): float GPU memory quantities supported (non-conserving float arithmetic -> L1).
- 58eb05f6 (2022-11-16, b part): dead-client handling for running jobs; participant check at start.
- 80435afd (2022-12-12): adaptive scheduling with back-off, max_schedule_count -> terminal FINISHED_CANT_SCHEDULE, JOB_BLOCK_REASON.
- 728973c9 (2023-02-16): SP->CP admin requests over CellNet with per-call timeout; timed-out -> reply None, departed -> no reply object.
- 9c3d8736 (2023-02-17): CP/CJ over CellNet; job cell FQCN = client_fqcn.job_id.
- 6f75707f (2023-02-21): parent<->job-process control (abort, GET_CLIENTS, UPDATE_RUN_STATUS, heartbeat) becomes best-effort messaging; abort relies on grace wait + terminate().
- 17b8532a (2023-02-28): job processes exit via MPM (rc file preferred over launcher code), no self-kill.
- 195110c2 (2023-03-30): job status management; startup reconciliation of RUNNING/DISPATCHED (ABANDONED / FINISHED_ABNORMAL) - callers gone at HEAD (L10).

## Mechanism groups (by shared mechanism)
- M1 Terminal status decided from incomplete or late evidence (process exit without job-reported outcome; report/exit race; exit-code mapping gaps; restart without reconciliation): 2c89c887, 508c7d23, 8a3e3cb0, b25e6bd3, 9e1881da. Residual at HEAD: L6, L7, L10.
- M2 Check-then-act on job status / job-store entry without an atomic or guarded transition (admin command vs scheduler/runner): def5c04c, 9e1881da, 1571296f (filter-then-send). Residual: L11, L12 (both confirmed), job_def_manager.set_status unconditional (job_def_manager.py:459-481).
- M3 Abort/cleanup racing natural completion, departure, or concurrent table mutation: 03789dd9, 1571296f, 7e9d036a, 58eb05f6. Residual: L3, L5, PID-reuse note in 03789dd9 row.
- M4 Cleanup scope / missing teardown on error exits (job-level code touching site-level state, or skipping cell/child cleanup): 0c03cf34, 07c3e3c5, 783f192b, 30fbc3b0. Residual: L8.
- M5 Per-site partial failure in deploy/start (one site's failure escalated, or failure not accounted): df539aab (+ e5e8c15a). Residual: L2.
- M6 Resource accounting defaults, arithmetic, and reservation/allocation lifetime: 82fec3f7, 9a822f93 (+ 5b7713f2, 903567c7, 242d831b). Residual: L1 (confirmed), L2, L4, L13.
- M7 Scheduler/admission robustness against one job's failure (one bad job or duplicate loop stalls admission): 5535bdb7, 3225529d. Residual: L9, L12 (confirmed).

## Possible unaudited sites at HEAD (leads)
| ID | Status | Severity | Mechanism | Evidence (HEAD file:line) |
|---|---|---|---|---|
| L1 | CONFIRMED (unit run, see 46-60 evidence) | Critical by rubric (permanent capacity loss); practical impact on requests equal to full/remaining GPU memory | Float GPU-memory accounting does not conserve capacity: 1 GiB GPU, jobs 0.1 + 0.2 freed B-then-A -> 0.9999999999999999; later 1 GiB job rejected until restart (can end FINISHED_CANT_SCHEDULE after max_schedule_count) | gpu_resource_manager.py:148-150, 188-197; auto_clean_resource_manager.py:166-172; job_scheduler.py:347-354 |
| L2 | code-level | Medium (transient loss up to lease, 300 s default) | Reservations handed to the runner are never cancelled on early exits (job no longer SUBMITTED/DISPATCHED, deploy failure, failed/excluded sites, server-start failure); late CHECK_RESOURCE replies after the 15 s timeout reserve on CP but SP records (False,"") and cannot cancel. Only lease expiry reclaims; interacts with back-off/max_schedule_count of later jobs | job_runner.py:661-663, 692-701, 304-306, 713-731; server_engine.py:1010-1041, 1052-1066 (only caller job_scheduler.py:231, 245); auto_clean_resource_manager.py:102-116; master_template.yml:77 |
| L3 | code-level (narrow window) | Low-Medium | stop_run marks run_aborted only after _stop_run returns; _job_complete_process reads job.run_aborted unsynchronized; _remove_run_processes pops run_processes after terminate() without waiting for wait_for_complete's RC recording; global engine_info.status set STOPPED by any single job's exit/abort | job_runner.py:798-800, 466, 486; server_engine.py:402-409 vs 218-233; 191-195, 234, 382 |
| L4 | code-level | Medium | GPU/List consumers write process-global CUDA_VISIBLE_DEVICES; consume() only runs for non-empty allocations, launcher copies os.environ -> a later CPU-only job inherits the previous job's GPU visibility; concurrent START_JOB handlers race on the variable | gpu_resource_consumer.py:33; list_resource_consumer.py:37; scheduler_cmds.py:119-121; process_launcher.py:68 |
| L5 | code-level | Medium-High | Live iteration over shared dicts mutated by wait_for_complete/_remove_run_processes/_job_complete_process threads (same mechanism fixed in 58eb05f6): stop_all_runs can raise mid-shutdown, leaving jobs un-aborted and ask_to_stop unset; notify_dead_client can drop notifications | job_runner.py:854-861 (caller fed_server.py:1243-1244); fed_server.py:1109; training_cmds.py:164; mutators server_engine.py:233, 408-409; job_runner.py:531-532 |
| L6 | code-level | Medium | Execution-error outcome of SJ (e.g. controller exception, FATAL_SYSTEM_ERROR handled without raising -> exit code 0) conveyed only by fire-and-forget UPDATE_RUN_STATUS; dropped if it arrives after the 2 s post-exit wait/pop -> FINISHED_COMPLETED | server_runner.py:252-256; server_engine.py:873-884, 207-233; fed_server.py:593-603; runner_process.py:142-149 |
| L7 | code-level | Low | `process_return_code == -9 -> FINISHED_ABNORMAL` unreachable for ProcessHandle (poll maps all codes except 0/1/9 to EXECUTION_ERROR), so a SIGKILLed SJ is reported EXECUTION_EXCEPTION | job_runner.py:570-571; process_launcher.py:29, 51-55; fed_utils.py:547-564 |
| L8 | code-level | Low | CJ start deletes the SITE's restart.fl/shutdown.fl markers written by the CP on shutdown/restart | worker_process.py:66-74, 197-209; client_engine.py:444, 455 |
| L9 | CONFIRMED (harness, see 76-90 evidence) | High | One job whose _try_job raises (min_clients as numeric string or null pass the validator) aborts every scheduling round before bookkeeping -> never reaches max_schedule_count; newer eligible jobs never tried; with null, a fresh reservation is leaked each round | job_scheduler.py:166, 199, 229, 292-296, 364-369; job_meta_validator.py:225-242; job_def.py:241 |
| L10 | code-level | High (job stuck RUNNING; not abortable/deletable) | Startup reconciliation update_unfinished_jobs/update_abnormal_finished_jobs has no callers; shutdown allowed with aborted-but-unfinalized jobs and stop_all_runs ends the completion thread -> after restart the job stays RUNNING: abort -> "not running", delete refused; ABANDONED documented but never set | job_runner.py:762-796, 443, 524, 802-811, 861; training_cmds.py:164-170; job_cmds.py:516-521, 1072-1075; docs/user_guide/nvflare_cli/job_cli.rst:236-237 |
| L11 | CONFIRMED (harness, below) | Critical (terminal status overwritten; aborted job runs) | abort_job of a SUBMITTED/DISPATCHED job while the runner deploys/starts it: FINISHED_ABORTED is overwritten by unconditional set_status(DISPATCHED/RUNNING); re-checks at 661/697 are check-then-act | job_cmds.py:1061-1066; job_runner.py:661, 669-670, 697-711; job_def_manager.py:459-481 |
| L12 | CONFIRMED (harness, see 91-100 evidence) | High (admission blocked until restart) | delete_job of a SUBMITTED job during scheduling: _check_job_status dereferences None outside the try -> JobRunner.run exits; during deploy the except handler's own set_status raises -> same | job_runner.py:661, 666-731, 737-739, 670, 720; job_cmds.py:516; job_def_manager.py:379-385; filesystem_storage.py:251-268; server_deployer.py:136, 144-145 |
| L13 | code-level (low reachability) | Medium if reached (permanent capacity loss) | CP start path: allocate_resources pops the token, but ClientEngine.start_app returns error strings (already started / app missing) instead of raising, and StartJobProcessor frees only on exception -> allocation never freed | client_engine.py:357-367; scheduler_cmds.py:114-137; auto_clean_resource_manager.py:153-164 |

Evidence for L11 (harness with the real JobRunner.run; _deploy_job/_start_run stubbed; store.set_status unconditional like job_def_manager.py:459-481; admin decision mirrors job_cmds.py:1061-1066):
```
abort reply: ['Aborted the job before running it.'] | start_run called for: ['job-A']
status history: ['FINISHED:ABORTED', 'DISPATCHED', 'RUNNING'] | final: RUNNING
```

Known-in-history note (per run rules): L5, L10, L12 and L9 are residual/regressed instances of mechanisms that this batch's own commits fixed elsewhere (58eb05f6; 9e1881da/195110c2; def5c04c; 5535bdb7). None of the leads came from external reports; all are from HEAD code reading and local harness runs.

---

## Per-commit log (appended incrementally during the run)

### EVIDENCE BLOCKER (recorded before analysis)

Historical file contents are NOT available in this repository's object store:
- `.git/objects/info/alternates` -> `/home/experiment/repos/nvflare/.git/objects`; the local store holds 0 loose/packed objects.
- `git cat-file --batch-all-objects --batch-check` reports 4241 commits, 41499 trees, but only 4777 blobs (HEAD tree has 5369 entries), i.e. a blobless store holding only the blobs of the checked-out tree.
- For this batch, `git diff-tree -r <sha> -- $(cat core-paths.txt)` lists 568 pre/post blob ids; `git cat-file -e` fails for all 568 (0 available).
- Consequently `git show <sha>` / `git show --stat <sha>` abort with `fatal: unable to read <blob>`; `git show HEAD~50:nvflare/private/fed/server/job_runner.py` -> `bad object`.
- No fetch was attempted (network / out-of-repo access forbidden by run rules; the repo has no promisor remote configured).

Method actually used per commit (all within the rules):
1. `git log -1 --format='%H%n%ad%n%s%n%n%b' <sha>` (full message; commit objects are present).
2. `git show --name-status --format= <sha>` (file list; tree objects are present).
3. For candidates: read the CURRENT HEAD code of the affected functions to (i) confirm the described fix mechanism still exists at HEAD, (ii) look for analogous sites that still have the same mechanism. Diff-level confirmation of what each historical fix changed is therefore NOT possible; claims about historical diffs are inferred from message + file list and marked as such.

### Commits 1-15 (lines 101-115)

| # | Commit | Date | Subject | Files (core) | Class | Notes |
|---|--------|------|---------|--------------|-------|-------|
| 101 | 69a62b34 | 2022-06-02 | Enhanced the child_process logging (#637) | worker_process.py, runner_process.py | c | logging_setup() only per message |
| 102 | 03789dd9 | 2022-06-02 | Enhance the abort_train with retry (#634) | client_executor.py | **a** | Msg: retry abort; "When the run already terminated, break out from the abort_train loop"; "Added the self.run_processes.pop(run_number) in the right place". Mechanism: abort racing a naturally-exiting worker (abort path raising / retrying on an already-gone process) + run_processes registration removed at the wrong point. HEAD retains retry loop + comment (client_executor.py:493-545) and single pop site in waiter (client_executor.py:680-681, plus launch-failure pop 312-315). |
| 103 | 2ea6522c | 2022-06-08 | Replace run_number with job_id (#654) | ~all core files | c | mechanical rename (no body); diff unreadable |
| 104 | b6c95d5c | 2022-06-08 | Added support for name in meta.json (#653) | job_def.py, job_cmds.py | c | job display name |
| 105 | e1bf063e | 2022-06-13 | Squash all commits to one (#655) | job_def_manager.py, job_def.py, job_def_manager_spec.py, job_runner.py, file_transfer.py, +job_def_manager_test.py | c? (unverifiable) | Empty message, diff unreadable; file set suggests job-store / workspace-save API work. Not classifiable as a fix. |
| 106 | 34105850 | 2022-06-14 | Added back delete_job command, removed delete_workspace (#662) | job_cmds.py, training_cmds.py | b | Re-introduces admin delete of a job-store entry (lifecycle: store entry can vanish while scheduler/runner hold the Job). |
| 107 | 66391a87 | 2022-06-15 | Fix integration tests (#663) | job_def_manager.py, job_def.py, client_engine.py, client_executor.py (+tests) | c? (unverifiable) | Empty message; touches client executor/engine but diff unreadable; cannot claim a lifecycle fix. |
| 108 | def5c04c | 2022-06-15 | Delete job command enhance (#670) | job_def_manager.py, job_def_manager_spec.py, job_cmds.py | **a** | Msg: "Added error handle not allowing running job to be deleted." Mechanism: missing status guard on delete of an active job. HEAD guard: job_cmds.py:516-521 (DISPATCHED/RUNNING rejected) using job meta cached in conn at authz time; job_def_manager.delete (job_def_manager.py:354-356) has no status check/lock -> check-then-act window (see leads). |
| 109 | 17ed3eed | 2022-06-15 | Use custom StorageException instead of RuntimeError (#672) | job_def_manager.py | c | exception type only (relevant later: get_job returns None on StorageException, job_def_manager.py:379-385) |
| 110 | 07944d20 | 2022-06-15 | Unregister client on stop_fl.sh shutdown (#674) | client_engine.py | c | client (not job) lifecycle; reverted by 6979c797 next day |
| 111 | 6979c797 | 2022-06-16 | Revert stop_fl.sh PR (#679) | client_engine.py | c | revert |
| 112 | b1b9e108 | 2022-06-17 | Added run_duration for the job (#680) | job_def_manager.py, job_def.py, job_cmds.py | c | adds START_TIME/DURATION meta written inside set_status (job_def_manager.py:459-481) |
| 113 | 8e11bae0 | 2022-06-28 | print -> logger.info in client executor (#699) | client_executor.py | c | logging |
| 114 | f2780b2a | 2022-06-28 | Add list_files and download_job single file (#698) | job_def.py, job_cmds.py | c | download UX |
| 115 | 38c2b323 | 2022-07-29 | Bind to 0.0.0.0 (#725) | fed_server.py | c | network bind / helm |

### Commits 16-30 (lines 116-130)

| # | Commit | Date | Subject | Files (core) | Class | Notes |
|---|--------|------|---------|--------------|-------|-------|
| 116 | 99c199e2 | 2022-08-08 | Add MPI example / multi aux request (#719) | fed_server.py, server_engine.py, runner_process.py | c | collective-comm feature, removed again by 378499a8 |
| 117 | 55e74fe2 | 2022-08-19 | Add report resources command and processors (#766) | resource_manager_spec.py, list_resource_manager.py, client_executor.py, scheduler_cmds.py, job_runner.py | c | read-only report_resources() API (HEAD: auto_clean_resource_manager.py:174-176, scheduler_cmds.py:160-169); no ownership change inferred |
| 118 | 55f87bf1 | 2022-08-25 | Only restore the FLComponent from the snapshot (#796) | server_engine.py | c | HA snapshot restore (excluded) |
| 119 | 6ddf1d37 | 2022-08-29 | Clean up fuel utils and client executor (#761) | client_engine.py, client_executor.py, scheduler_cmds.py | c (unverifiable) | "clean up"; diff unreadable |
| 120 | 92b013bd | 2022-09-01 | Simulator (#757) | +client_app_runner.py, +server_app_runner.py, worker_process.py, runner_process.py, fed_server.py, server_engine.py, fed_client_base.py | b | Extracted ServerAppRunner/ClientAppRunner used by SJ/CJ mains. HEAD contract: ServerAppRunner.start_server_app always runs update_job_run_status() + STOPPED + stop_training() in `finally` and sets FATAL_SYSTEM_ERROR on exception (server_app_runner.py:53-93, finally at 89-93). |
| 121 | 88c94191 | 2022-09-01 | Merged FOBS (#818) | job_def_manager.py, scheduler_cmds.py, fed_server.py, server_engine.py | c | serialization |
| 122 | 378499a8 | 2022-09-02 | Remove collective communication codes (#835) | fed_server.py, server_engine.py, runner_process.py | c | removal |
| 123 | dd5a35e8 | 2022-09-08 | cherry-pick 2.2 changes (#868) | fed_client_base.py | c | simulator/communicator |
| 124 | e5e8c15a | 2022-09-09 | Dev authz integrate (#856) | 15 core files incl. job_runner.py, job_cmds.py, training_cmds.py, server_engine.py, client_engine.py | b | Msg: "compute complete job deploy detail", authz/site policy. New ordinary partial-deploy failure mode: a site may refuse DEPLOY (authz/policy); per-site outcome recorded in JOB_DEPLOY_DETAIL; job aborted only if min_sites/required_sites violated (HEAD job_runner.py:241-282). |
| 125 | afc4535d | 2022-09-13 | task_request_interval configurable (#878) | server_engine.py, scheduler_cmds.py, client_app_runner.py, server_runner.py | c | task polling config |
| 126 | 242d831b | 2022-09-14 | Add GPU resource consumer (#763) | +gpu_resource_manager.py, list_resource_manager.py, resource consumer | b | Introduces GPUResourceManager (per-GPU memory reservation) + GPUResourceConsumer that exports allocation via process-global os.environ["CUDA_VISIBLE_DEVICES"] (HEAD gpu_resource_consumer.py:33; list_resource_consumer.py:37). See lead L4. |
| 127 | 471e9e3e | 2022-09-19 | Fed stats privacy2 (#897) | job_runner.py | c (unverifiable) | fed-stats privacy feature; job_runner hunk unreadable |
| 128 | 71f5c8ae | 2022-09-20 | Fix ci/cd (#900) | gpu_resource_manager.py | c (unverifiable) | CI fix; hunk unreadable |
| 129 | 5b7713f2 | 2022-09-21 | Add base resource manager (#905) | +auto_clean_resource_manager.py, +base_resource_manager.py, resource_manager_spec.py, gpu/list managers, scheduler_cmds.py | b | Introduces AutoCleanResourceManager: reservation = lease keyed by uuid token, auto-released after expiration_period ticks unless allocate_resources() pops it (HEAD auto_clean_resource_manager.py:102-164). Lease expiry is the only reclamation for reservations orphaned by server-side early exits (see leads L2). |
| 130 | b17d94ce | 2022-09-22 | Use GPU 0 GPUResourceManager as default (#910) | auto_clean_resource_manager.py, -base_resource_manager.py | b | Default site resource manager becomes GPUResourceManager (HEAD master_template.yml:72-79: GPUResourceManager, expiration_period 300 + GPUResourceConsumer). |

### Commits 31-45 (lines 131-145)

| # | Commit | Date | Subject | Files (core) | Class | Notes |
|---|--------|------|---------|--------------|-------|-------|
| 131 | df539aab | 2022-09-23 | Fixes several problems found during authz testing (#914) | job_def.py, job_cmds.py, job_runner.py, server_engine.py | **a** | Msg item 2: "Fixed the deploy error when one site rejects the job." Mechanism: a single site's DEPLOY rejection mishandled -> whole deploy errored instead of per-site failure + min_sites/required_sites decision. HEAD: per-reply rc/no-reply handling job_runner.py:250-282. Analogous gap at HEAD: reservation tokens of rejected/failed sites are never cancelled (partial continue path job_runner.py:692-695; full-abort except path 713-731) -> held until lease expiry (lead L2). Item 1 (clone_job fields) out of scope. |
| 132 | fdf1eb8e | 2022-09-23 | Fix mgpu executor (#924) | worker_process.py, runner_process.py, fed_server.py | c | fobs_initialize in every process |
| 133 | 3f3c0492 | 2022-09-23 | Add secure logging (#919) | 12 core files | c | logging wrappers |
| 134 | b575e69f | 2022-09-26 | Clean up utils, unify job constants (#934) | 8 core files | c | constants refactor |
| 135 | 33bf14b5 | 2022-09-26 | Removed unused server_meta (#935) | fed_client_base.py | c | dead code |
| 136 | a003aff2 | 2022-09-27 | Clean up client engine specs (#906) | client_run_manager.py | c | spec cleanup |
| 137 | 8693f5f2 | 2022-09-30 | Add ListResourceConsumer (#970) | +list_resource_consumer.py | b | Second consumer exporting allocation through process-global CUDA_VISIBLE_DEVICES (HEAD list_resource_consumer.py:37); same env-leak mechanism as L4. |
| 138 | 7e9d036a | 2022-10-05 | Fix server engine abort_app_on_server (#989) | server_engine.py | **a** | Msg only "Fix server engine"/"Address comment"; diff unreadable, precise mechanism unrecoverable. Component: server-side SJ abort. HEAD abort path: server_engine.py:354-409 (ABORT to SJ, off-thread _remove_run_processes that terminate()s captured handle and pops run_processes WITHOUT waiting for wait_for_complete's return-code recording at 203-233) -> see lead L3; also sets global engine_info.status=STOPPED although other jobs may run (382, 234). |
| 139 | 783f192b | 2022-10-07 | Fix CTR-C to kill all child processes (#994) | worker_process.py (+simulator) | a (Low, simulator-leaning) | Msg: "Terminate all child processes created by server for CTR-C." Mechanism: parent-termination path did not reap/kill children (orphaned job processes). Only worker_process.py in core; other files are simulator. HEAD: SJ/CJ poll parent liveness via monitor_parent_process (runner_process.py:126) instead. |
| 140 | 9f091b3d | 2022-10-12 | Fix info collect commands (#1001) | fed_server.py, job_runner.py, run_manager.py, server_engine.py | c | info-collector/show_stats plumbing (files info_coll_cmd.py, info_collector.py) |
| 141 | 9a822f93 | 2022-10-12 | Check GPU number/memory only when number is not 0 (#1010) | gpu_resource_manager.py | a (Low) | Mechanism: construction-time host validation applied even to zero-capacity config -> resource manager (and site) failed to start on GPU-less hosts. HEAD guard gpu_resource_manager.py:116-117 (`if num_of_gpus > 0`); runtime paths also short-circuit num_gpu==0 (162-163, 185-186). Complete. |
| 142 | 04dd40bc | 2022-10-13 | fix typing, fix abort_task error (#1024) | job_cmds.py | c | task-level abort command (not job lifecycle) |
| 143 | 2c89c887 | 2022-10-14 | Enhance job run status (#1023) | fed_server.py, job_runner.py, server_app_runner.py, server_engine.py, server_runner.py | **a** | Msg: "update the job_run_status to parent process"; "Added update_job_run_status to update the proper job run status". Mechanism: terminal RunStatus derived only from SJ process exit, not from SJ-reported execution outcome -> wrong terminal status. HEAD: SJ `finally` -> update_job_run_status fire_and_forget UPDATE_RUN_STATUS (server_app_runner.py:89-90; server_engine.py:873-884); parent sets PROCESS_FINISHED/EXE_ERROR (fed_server.py:593-603); wait_for_complete waits <=2 s (server_engine.py:207-217); classification job_runner.py:543-572. Residual: fire-and-forget report arriving after the 2 s wait/pop is dropped (fed_server.py:598 `if run_process_info is not None`), so EXE_ERROR with exit code 0 would classify COMPLETED (lead L6). |
| 144 | 0478f0e7 | 2022-10-14 | set the peer_ctx to private (#1021) | fed_server.py | c | context privacy |
| 145 | 9eb6bb47 | 2022-10-14 | Fix shutdown command when authz failed (#1008) | training_cmds.py (client) | c | admin authz for site shutdown |

### Commits 46-60 (lines 146-160)

| # | Commit | Date | Subject | Files (core) | Class | Notes |
|---|--------|------|---------|--------------|-------|-------|
| 146 | 82fec3f7 | 2022-10-14 | Default should be False and token is None (#1035) | job_scheduler.py, scheduler_cmds.py | **a** | Mechanism: unsafe defaults on the resource-check path (a failed/absent check could be read as "enough" with a non-null token -> dispatch without a real reservation). HEAD: CP defaults `False, ""` and exception path returns not-enough + reason string (scheduler_cmds.py:65, 86-88); SP defaults IS_RESOURCE_ENOUGH False and no-reply -> (False, "") (server_engine.py:1027-1040); cancel only when `is_resource_enough and token` (server_engine.py:1058). Complete for defaults; see L2 for late replies. |
| 147 | ab6225da | 2022-10-17 | log send_task_result exception (#1051) | client_run_manager.py | c | logging |
| 148 | 903567c7 | 2022-10-20 | Allow GPUResourceManager/Consumer to handle float GPU memory (#1073) | gpu_resource_consumer.py, gpu_resource_manager.py | b | Contract: memory quantities may be float. HEAD accounting uses plain float -=/+= (gpu_resource_manager.py:148-150, 191-193) -> non-conserving; CONFIRMED unit-level drift, see lead L1. |
| 149 | 88329e22 | 2022-10-21 | Fix typo (#1081) | gpu_resource_manager.py | c | typo |
| 150 | 8e563681 | 2022-10-26 | Fixed abort_job HA failed to remove snapshot (#1091) | server_engine.py | c | HA snapshot cleanup (excluded) |
| 151 | eb782533 | 2022-10-26 | rename check_result to is_enough_resource (#1096) | resource spec/managers/scheduler | c | rename |
| 152 | ce306e04 | 2022-11-02 | Upgrade for Python 3.10 (#1102) | client_engine.py, fed_server.py, server_engine.py | c | py3.10 / grpc |
| 153 | 58eb05f6 | 2022-11-16 | Dead clients handle (#1136) | fed_server.py, job_cmds.py, job_runner.py, server_engine.py, server_runner.py | **a** + b | (b) dead-client handling for running jobs + participants check on start. (a) Msg: "Changed the self.run_processes.items() to self.run_processes.keys()" then "Changed to use keys = list(self.run_processes.keys())" => mechanism: iterating a shared job table while other threads add/pop entries (RuntimeError: dictionary changed size during iteration). HEAD snapshot present in get_engine_info (server_engine.py:149), pause_server_jobs (1094). NOT applied at: job_runner.stop_all_runs `for job_id in engine.run_processes.keys()` (job_runner.py:856) and fed_server.notify_dead_client `for ... in self.engine.run_processes.items()` (fed_server.py:1109); also training_cmds.shutdown iterates live running_jobs (training_cmds.py:164) -> lead L5. |
| 154 | d7b3cccf | 2022-11-28 | Fixed a race condition and client privacy.json issue (#1164) | fed_server.py (+fl_conf.py) | a? (unverifiable) | "race condition" in fed_server.py; body empty, diff unreadable -> mechanism unrecoverable; privacy.json part is config. Listed as possible in-scope fix without mechanism. |
| 155 | 34e8c743 | 2022-11-28 | Add signature to each folder of submitted jobs (#1152) | job_cmds.py | c | job signing |
| 156 | d293aaf4 | 2022-12-01 | Fix signing jobs in POC (#1169) | training_cmds.py, job_runner.py | c | signature verification on deploy (security) |
| 157 | 62ac8c6b | 2022-12-07 | Simulator hang OOM (#1159) | fed_client_base.py, fed_server.py | c | simulator |
| 158 | 80435afd | 2022-12-12 | Scheduler enhancement (#1184) | job_def_manager.py, job_def.py, job_scheduler_spec.py, job_scheduler.py, scheduler_cmds.py, job_cmds.py, job_runner.py, server_engine.py | b | Adaptive scheduling: per-job schedule_count with exponential back-off, max_schedule_count -> terminal FINISHED_CANT_SCHEDULE, schedule history, JOB_BLOCK_REASON hook (HEAD job_scheduler.py:287-378, 191-197). Makes transient capacity loss (L2) and permanent loss (L1) observable as a terminal status for a later eligible job. |
| 159 | ba4d4b71 | 2023-01-13 | add flare_api initial changes (#1161) | client_engine.py, training_cmds.py, job_cmds.py | c | admin API |
| 160 | 0c03cf34 | 2023-01-20 | Only terminate the local session in the worker_process, not logout the client (#1236) | worker_process.py, fed_client_base.py | **a** | Mechanism: CJ teardown used site-scope cleanup (logout/quit of the whole client registration) instead of job-local terminate -> a job's exit de-registered the site for all other/later jobs. HEAD: worker_process.py:152-153 calls terminate(); logout only via FederatedClientBase.close() (fed_client_base.py:430-445) whose only caller is CP shutdown_client (client_engine.py:520). Complete. Related site-scope side effect still in CJ start: remove_restart_file() deletes the SITE's restart.fl/shutdown.fl (worker_process.py:66-74,197-209) which the CP writes on shutdown/restart (client_engine.py:444,455) -> lead L8 (Low). |

Evidence for L1 (commands run from /tmp with the prepared env; `nvflare` resolves to this arm's source):
```
$ python3 - <<'PYEOF'
from nvflare.app_common.resource_managers.gpu_resource_manager import GPUResourceManager
from nvflare.apis.fl_context import FLContext
rm = GPUResourceManager(num_of_gpus=1, mem_per_gpu_in_GiB=1, expiration_period=30, ignore_host=True)
ctx = FLContext()
ok1, t1 = rm.check_resources({"num_of_gpus": 1, "mem_per_gpu_in_GiB": 0.1}, ctx); a1 = rm.allocate_resources({}, t1, ctx)
ok2, t2 = rm.check_resources({"num_of_gpus": 1, "mem_per_gpu_in_GiB": 0.2}, ctx); a2 = rm.allocate_resources({}, t2, ctx)
rm.free_resources(a2, t2, ctx)   # job B finishes first
rm.free_resources(a1, t1, ctx)   # then job A
print("memory after both freed:", repr(rm.resources[0].memory))
ok3, t3 = rm.check_resources({"num_of_gpus": 1, "mem_per_gpu_in_GiB": 1}, ctx)
print("later job needing full 1 GiB admitted?", ok3, repr(t3))
PYEOF
memory after both freed: 0.9999999999999999
later job needing full 1 GiB admitted? False ''
```
(nvflare import path printed as .../full/source/nvflare. The same two jobs freed A-then-B return exactly 1.0; a brute-force scan over small decimal pairs found 1235 lossy (capacity, a, b, free-order) combinations, e.g. (1, 0.3, 0.1, A-then-B) -> 0.9999999999999999, (2, 0.2, 0.4, B-then-A) -> 1.9999999999999998.)

### Commits 61-75 (lines 161-175)

| # | Commit | Date | Subject | Files (core) | Class | Notes |
|---|--------|------|---------|--------------|-------|-------|
| 161 | 474d6ab6 | 2023-01-23 | Fix integration tests (#1239) | worker_process.py, job_cmds.py | c | test driver / list_jobs |
| 162 | 728973c9 | 2023-02-16 | FL server deploy integrate with cellnet (#1376) | fed_server.py, +message_send.py, server_engine.py | b | SP->CP admin requests (check_resource/deploy/start/cancel/abort) become CellNet multi-requests with per-call timeout; timed-out target -> ClientReply.reply None, departed client -> no ClientReply at all (HEAD message_send.py:65-111). Late CP-side effects after an SP timeout are invisible to the SP (feeds L2). |
| 163 | 9c3d8736 | 2023-02-17 | FL Client integrate with FCI Cellnet (#1380) | client_engine.py, client_executor.py, fed_client_base.py, fed_server.py | b | CP<->CJ and CP<->SP transport over CellNet (client registration, job cell FQCN = client_fqcn.job_id; HEAD client_executor.py:352-353). |
| 164 | 6f75707f | 2023-02-21 | Job run integrate with FCI Cellnet (#1387) | 13 core files (job_runner, server_engine, runner/worker_process, client_app_runner, ...) | b | Parent<->job-process commands (abort, GET_CLIENTS, UPDATE_RUN_STATUS, heartbeat) become best-effort cell messages with timeouts/optional delivery; hence abort paths rely on a grace wait + terminate() fallback (HEAD server_engine.py:354-409, client_executor.py:486-601) and SJ bootstrap retries GET_CLIENTS for 30 s (server_engine.py:828-846). |
| 165 | 62922720 | 2023-02-22 | Simulator integration with FCI Cellnet (#1398) | fed_server.py | c | simulator |
| 166 | 845945b1 | 2023-02-22 | Limit number of jobs in list_jobs (#1381) | job_cmds.py | c | listing |
| 167 | 3c4368d8 | 2023-02-23 | Ha fix (#1407) | runner_process.py, fed_client_base.py | c | HA (excluded) |
| 168 | 264d7887 | 2023-02-24 | fix default order of jobs in list_jobs (#1416) | job_cmds.py | c | listing |
| 169 | 309a9633 | 2023-02-27 | Avoid simulator cell error after END_RUN (#1431) | fed_client_base.py | c | simulator |
| 170 | 29de03ca | 2023-02-27 | Enable Simulator to use resources.json (#1435) | fed_client_base.py | c | simulator |
| 171 | 1c444414 | 2023-02-27 | Fix list jobs argument parsing (#1427) | job_cmds.py | c | listing |
| 172 | 17b8532a | 2023-02-28 | Job run process not to kill its own process; let MPM manage (#1440) | worker_process.py, runner_process.py, client_app_runner.py, client_run_manager.py, server_app_runner.py, server_engine.py | b | Contract: SJ/CJ no longer self-kill; exit through mpm.run which maps ConfigError/ComponentNotAuthorized/Exception to CONFIG_ERROR/UNSAFE_COMPONENT/EXCEPTION and writes an rc file that parents prefer over the launcher code (HEAD mpm.py:144-163; fed_utils.get_return_code 547-564). Side effect visible at HEAD: ProcessHandle.poll maps any non-{0,1,9} code incl. SIGKILL(-9) to EXECUTION_ERROR (process_launcher.py:29,51-55), so the `process_return_code == -9 -> FINISHED_ABNORMAL` branch (job_runner.py:570-571) is unreachable for the default launcher (lead L7, Low). |
| 173 | da28bc40 | 2023-03-01 | Fixed a few QA bugs (#1445) | job_cmds.py, job_runner.py | a? (unverifiable) | empty body, diff unreadable; touches job_runner -> possible lifecycle fix, mechanism unrecoverable |
| 174 | 508c7d23 | 2023-03-02 | Fixed job status not updated to exception when controller exception (#1447) | fed_server.py, server_engine.py, server_runner.py | **a** | Mechanism: workflow-controller exception did not reach the SP's terminal-status decision (SJ ends "cleanly"; "Added a job_id in runner_process check" => status report not matched to the job's run_process entry) -> FINISHED_COMPLETED instead of FINISHED_EXECUTION_EXCEPTION. HEAD chain: control_flow exception -> system_panic (server_runner.py:153-156) -> FATAL_SYSTEM_ERROR prop + abort (252-256) -> update_job_run_status fire_and_forget keyed by job_id (server_engine.py:873-884) -> fed_server.py:593-603. SJ exit code stays 0 on this path (mpm rc=None), so correctness depends solely on best-effort delivery within the 2 s grace (server_engine.py:207-217) -> lead L6. Severity Critical (wrong terminal status). |
| 175 | bc1a9c3b | 2023-03-08 | fix shutdown log messages (#1465) | client_executor.py, client_run_manager.py, server_engine.py, server_runner.py | c | logging |

### Commits 76-90 (lines 176-190)

| # | Commit | Date | Subject | Files (core) | Class | Notes |
|---|--------|------|---------|--------------|-------|-------|
| 176 | 143bd24d | 2023-03-08 | Server Listens on All Interfaces (#1471) | fed_server.py | c | network |
| 177 | f19311d4 | 2023-03-09 | cleanup error msg; fix sag wait; fix get_task timeout (#1479) | fed_client_base.py, server_runner.py | c | task fetch / SAG (excluded) |
| 178 | 3225529d | 2023-03-09 | Fix job runner multiple start issue (#1466) | fed_server.py, job_runner.py (+HA test cfg two_servers.yml) | **a** (HA-triggered) | Msg: "Start job runner when server is turn to hot". Mechanism: the JobRunner scheduling loop could be started more than once -> concurrent scheduling loops (double dispatch/reservation of the same SUBMITTED job). Trigger was HA state change (excluded), but effect is on admission. HEAD: single start site server_deployer.py:136 (thread) / 144-145 (`grep job_runner.run` finds no other) and hot-state gate job_runner.py:643. Complete for the default path. |
| 179 | d3d15c02 | 2023-03-10 | fix api status and dead job message (#1484) | fed_server.py | c | message text |
| 180 | 150f8562 | 2023-03-10 | protect server state against multiple state changes (#1489) | fed_server.py | c | HA hot/cold state (excluded) |
| 181 | d94527ef | 2023-03-13 | fix job listing (#1496) | job_cmds.py | c | listing |
| 182 | 597b29d5 | 2023-03-14 | silent abort message logging (#1505) | job_cmds.py, job_runner.py, message_send.py | c | abort-to-clients sent optional/silent (HEAD job_runner.py:409 `optional=True`, reply ignored 410-411) |
| 183 | e71701ae | 2023-03-14 | not creating internal listener for the job cell (#1507) | fed_client_base.py, fed_server.py | c | transport |
| 184 | 9b42bf26 | 2023-03-16 | Optimize get_all_clients at training start (#1524) | client_app_runner.py, client_run_manager.py | c | CJ startup optimization |
| 185 | 8a3e3cb0 | 2023-03-16 | fix job status and speed up fed event end_run (#1523) | server_engine.py (+fed_event.py, socket_conn.py, flare_api.py) | **a** (inferred) | "fix job status" in server_engine + faster END_RUN fed event => mechanism (inferred, diff unreadable): SP decided terminal status before the SJ's UPDATE_RUN_STATUS arrived (report/exit race). HEAD: bounded 2 s wait for PROCESS_FINISHED before classifying (server_engine.py:207-217 comment "Wait for the job process to finish UPDATE_RUN_STATUS process"). Residual = bounded wait on best-effort message (L6). Severity Critical (wrong terminal status). |
| 186 | 2f8e73b6 | 2023-03-20 | Ha authentication fix (#1535) | runner_process.py, client_run_manager.py, fed_server.py, server_engine.py | c | HA/auth (excluded) |
| 187 | 9644edd7 | 2023-03-20 | Fixed shared object issue in controller task return (#1549) | server_runner.py | c | task result object sharing (excluded) |
| 188 | 5535bdb7 | 2023-03-20 | Enhance job meta validator (#1555) | job_def.py, job_scheduler.py, job_meta_validator.py (+test data missing_server_in_deployment) | **a** (inferred) | Mechanism (inferred from test data + scheduler change): a job meta the scheduler cannot process (no server in deploy_map -> `sites_to_app[SERVER_SITE_NAME]` KeyError) made scheduling raise; fixed by rejecting at submit (HEAD job_meta_validator.py:146-147). Fix is input-side only: the scheduler still aborts the WHOLE round on any per-job exception with no bookkeeping (job_scheduler.py:292-296, 364-369) and still indexes `sites_to_app[SERVER_SITE_NAME]` unguarded (257-258). Validator accepts min_clients as numeric string (converted only for the check, 225-242) or null (skipped, 240), while job_from_meta keeps the raw value (job_def.py:241) and the scheduler compares ints to it (job_scheduler.py:166, 229) -> CONFIRMED head-of-line admission block, lead L9. Severity High. |
| 189 | 30fbc3b0 | 2023-03-21 | Fix cell timing (#1558) | client_executor.py, fed_client_base.py, fed_server.py, job_cmds.py, job_runner.py, message_send.py | a (Low) | Msg: "fix cell setup timing", "make client_cmd channel messages optional", "fix invalid client error". Mechanism: parent->job-cell commands issued before the job cell is reachable (startup window) treated as hard errors. HEAD: commands to CJ are `optional=True` (client_executor.py:389, 420, 451, 479, 528, 618; message_send.py:76-79 forces optional for job targets). |
| 190 | 5a130cff | 2023-03-21 | Fixed -m option in list_jobs (#1556) | job_cmds.py | c | listing |

Evidence for L9 (run from the repo root with the prepared env; uses the HEAD unit-test MockServerEngine; no product code modified):
```
$ python3 - <<'PYEOF'   # abbreviated; full script retained in transcript
from tests.unit_test.app_common.job_schedulers.job_scheduler_test import MockServerEngine, Site, create_resource
from nvflare.apis.job_def import job_from_meta, JobMetaKey
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler
# older job: deploy_map {"app": ["server","site1","site2"]}, resource_spec {}, min_clients "2" (or None), submit_time 1.0
# newer job: same, min_clients 2, submit_time 2.0; scheduler DefaultJobScheduler(max_jobs=1, min_schedule_interval=0.0)
# three schedule_job() rounds with candidates [older_bad, newer_ok]; control round with [newer_ok] only
PYEOF
TypeError: '<' not supported between instances of 'int' and 'NoneType'   (job_scheduler.py:229, logged "error scheduling job")
min_clients='2': scheduled per round=[None, None, None]; old schedule_count=None; new schedule_count=None
min_clients=None: scheduled per round=[None, None, None]; old schedule_count=None; new schedule_count=None
control (valid job alone): job-new
```
Interpretation: the bad job's exception is swallowed by schedule_job before _update_schedule_history, so it is never counted toward max_schedule_count (never blocked) and the newer eligible job is never tried -> admission blocked until the bad job is aborted/deleted. For min_clients=None the exception occurs after _check_client_resources (line 199), so each 1 s round also leaves a reservation that only lease expiry reclaims (L2).

### Commits 91-100 (lines 191-200)

| # | Commit | Date | Subject | Files (core) | Class | Notes |
|---|--------|------|---------|--------------|-------|-------|
| 191 | 9e1881da | 2023-03-22 | Fix incorrect server status after job aborted and server restarted | fed_server.py, job_runner.py, server_runner.py | **a** | Empty body, diff unreadable. Mechanism (from subject): an aborted job's recorded state was wrong after a server restart (abort intent lives only in memory: Job.run_aborted, job_def.py:173; terminal status persisted only by _job_complete_process, job_runner.py:524). HEAD regression risk: the restart reconciliation hooks update_unfinished_jobs / update_abnormal_finished_jobs (job_runner.py:762-792) have NO callers anywhere in the repo, and shutdown is allowed while aborted jobs are still unfinalized (training_cmds.py:164-170) while stop_all_runs sets ask_to_stop which ends _job_complete_process (job_runner.py:443, 861) -> lead L10. Severity High (job stuck RUNNING: abort -> "Job ... is not running" job_runner.py:802-811; delete refused job_cmds.py:516-521). |
| 192 | 1571296f | 2023-03-22 | Fix abort job with only connected clients (#1563) | job_cmds.py, job_runner.py | **a** | Mechanism: abort addressed to all original participants; a disconnected participant made target validation fail ("unknown clients") so abort was not delivered/processed. HEAD: _get_active_job_participants filter (job_runner.py:78-96) used by _stop_run (381-393) and _get_finished_job_status (575-585). Residual: filter-then-send is not atomic and _send_to_clients raises before sending to ANY client if one target became invalid (job_runner.py:63-66; client_manager.get_all_clients_from_inputs 445-459), caught/logged at 412-413 -> remaining clients rely on heartbeat _sync_client_jobs abort (fed_server.py:1004-1017). Low. |
| 193 | 0bc36461 | 2023-03-23 | Qa issues (#1568) | client_app_runner.py, job_cmds.py, job_runner.py | a? (unverifiable) | body "QA issues/Refactored"; diff unreadable |
| 194 | 75784a3a | 2023-03-24 | End simulator run after client exception (#1582) | fed_client_base.py | c | simulator |
| 195 | be5070bb | 2023-03-28 | Cell no executor pool (#1590) | fed_server.py | c | perf |
| 196 | 07c3e3c5 | 2023-03-28 | Fixed cell not stopped properly when config error (#1597) | fed_client_base.py (+mpm.py) | **a** | Mechanism: ConfigError exit path in job process skipped cell stop -> job process hung instead of exiting (stuck job / leaked process holding resources until killed). HEAD: worker_process.py:131-156 and runner_process.py:132-153 run shutdown_job_process_runtime(stop_cell=...) in `finally`; mpm maps ConfigError -> CONFIG_ERROR rc (mpm.py:154-156). Complete for paths after cell creation; earlier ConfigErrors occur before any cell exists. |
| 197 | 9c041f91 | 2023-03-29 | Fix abort job command return message (#1603) | job_cmds.py | c | message |
| 198 | 195110c2 | 2023-03-30 | Job status management enhancement (#1613) | job_def.py, runner_process.py, fed_server.py, job_cmds.py, job_runner.py, server_engine.py | b | "job status enhancement. Added HA mode." Contract introduced (inferred from HEAD remnants): persisted RUNNING/DISPATCHED jobs are reconciled at server start (ABANDONED non-HA / FINISHED_ABNORMAL HA) (job_runner.py:762-796); ABANDONED is still documented as a terminal state for `nvflare job wait` (docs/user_guide/nvflare_cli/job_cli.rst:235-237) but no caller remains at HEAD (lead L10). |
| 199 | f3418280 | 2023-03-31 | Fixes several shutdown related issues (#1608) | fed_server.py | c | communicator exit_func / FOBS msg (process shutdown, not job lifecycle) |
| 200 | b25e6bd3 | 2023-03-31 | fixed the job status for config error (#1615) | job_def.py, runner_process.py, fed_server.py, job_runner.py, server_app_runner.py, server_engine.py (+mpm.py, fl_constant.py) | **a** | Mechanism: SJ config error exit code not mapped to a failure terminal status (config-error job reported as completed/other); added ProcessExitCode rc via mpm and FINISHED_ABNORMAL. HEAD: CONFIG_ERROR -> FINISHED_EXECUTION_EXCEPTION (job_runner.py:554-563); ABNORMAL now only for INFRASTRUCTURE_ERROR (550-551) and raw -9 (570-571, unreachable, L7). Client side: CONFIG_ERROR reported -> fail_run(EXCEPTION) (fed_server.py:942-951). Severity Critical (wrong terminal status); fix complete for rc-file path. |

Evidence for L12 (harness with the real JobRunner.run; engine/job-store/scheduler mocked; job store mirrors SimpleJobDefManager.get_job returning None for a missing object, job_def_manager.py:379-385):
```
$ timeout 60 python3 - <<'PYEOF'   # abbreviated; full script retained in transcript
# in-memory store; scheduler.schedule_job returns job-A but first removes it from the store
# (= admin delete_job of a SUBMITTED job during the scheduler's resource check; delete guard only
#  rejects DISPATCHED/RUNNING, job_cmds.py:516); then add a later eligible job-B
PYEOF
scheduling thread alive after deleted-job race: False | error: ['AttributeError("\'NoneType\' object has no attribute \'meta\'")']
schedule_job calls while later eligible job-B waits: 0 | job-B status: SUBMITTED
```
Mechanism: _check_job_status (job_runner.py:737-739) dereferences get_job(...).meta; the call at 661 is outside the try block (666-731); server_deployer.py:136, 144-145 runs job_runner.run once with no restart. A delete after the SUBMITTED re-check but during deploy fails later instead: set_status(DISPATCHED) (670) raises StorageException (filesystem_storage.py:251-268) and the except handler's own set_status(FAILED_TO_RUN) (720) raises again, also escaping run().

