# Instrumentation points (copied patch, current build)

Paths below are relative to `harness/build/nvflare_src/nvflare`, except the `src/nvf_env.py` edge hooks. These are locations in the instrumented copy, not pristine source citations. The section extents restrict schedules as explained in [INSTRUMENTATION.md](INSTRUMENTATION.md).

| Event(s) | Location | Section extent / notes |
|---|---|---|
| RunnerScanList | apis/impl/job_def_manager.py:521 | around `store.list_objects` (only in `runner_scan` context, set at :515) |
| RunnerScanRead | job_def_manager.py:528 → app_common/job_schedulers/job_scheduler.py:277 | from the first meta read (tags included) until the end of `_exceed_max_jobs` |
| RunnerScanReadDeleted | job_def_manager.py:540-541 | `get_meta` raised for a listed object (re-raised; run() dies) |
| RunnerTryNext | job_scheduler.py:202 (CHECK branch, tracer increments att), :365 (blocked), :383 (no CHECK), :302 (`_try_job` raised) | one per candidate |
| RunnerBackoffSkip / RunnerTryDone | job_scheduler.py:374 / :396 | TryDone only if the candidate list was non-empty |
| RunnerCheckCollect / RunnerCheckTimeout | private/fed/server/server_engine.py:1031 | after `_send_admin_requests`; the tracer names it Timeout if a reply is missing/`None` |
| RunnerRefreshRead / RunnerRefreshWrite | app_common/storages/filesystem_storage.py:270 / :282 (context set at job_scheduler.py:311, :316) | the two halves of `update_meta` (gate `rmw.between` at :280) |
| RunnerSetCantSched | job_scheduler.py:318 | around `set_status(FINISHED_CANT_SCHEDULE)` |
| RunnerCheckSubmitted / RunnerCheckDispatched | private/fed/server/job_runner.py:778 (`_check_job_status`) | around `get_job` + compare; emitted on raise too |
| RunnerDeployJob | job_runner.py:227 (unknown clients, `failed=[]`), :284 (deploy failure), :288 (success) | exits of `_deploy_job`; `arg.failed` mapped to c-names |
| RunnerSetDispatched | job_runner.py:697 | around `set_status(DISPATCHED)` |
| RunnerMetaRead / RunnerMetaWrite | filesystem_storage.py:270 / :282 (context `rmw:RunnerMeta` at job_runner.py:702) | the RMW at :674 of the pinned file |
| RunnerStartServerApp (/Fail) | job_runner.py:301 → :317 | `get_job_clients` .. SJ launch .. pending registration; the stub SJ launcher renames it `RunnerStartServerAppFail` when it raises; an error return is closed by run()'s handler (:747) |
| RunnerStartCollect / RunnerStartTimeout | job_runner.py:322 → :377 | after `start_client_job` returns .. JOB_STARTED; the tracer names it Timeout if a START reply is `None`; raises closed at :747 |
| RunnerInsertRunning / RunnerSetRunning | job_runner.py:739 / :743 | around the insert under `self.lock` / around `set_status(RUNNING)` |
| RunnerExceptStop / RunnerExceptSetFailed / RunnerExceptMeta | job_runner.py:748→755 / :756 / :759→767 | except path; ExceptMeta ends after JOB_ABORTED (or when `update_meta` raises: run() dies, closed by the thread wrapper) |
| CmpFinalizeBegin / CmpOutcomeDeadline | job_runner.py:460 → :511; :492 (intermediate emit) | from the `run_processes` pre-check to the latch; cancelled (:488, :562, :565) when there is nothing to finalize |
| CmpPublish / CmpRemove | job_runner.py:543 / :552 → :564 | publish `set_status`; `del running_jobs` .. events .. `remove_exception_process` (a KeyError kills the thread, closed by excepthook) |
| AdminStopRun / AdminMarkAborted | job_runner.py:843 / :845 (`stop_run`) | absorbed when called inside `SpProcessJobFailure` |
| AdminAbortBegin / AdminAbortWrite | private/fed/server/job_cmds.py:1070 / :1080 | Begin cancelled unless SUBMITTED/DISPATCHED/RUNNING |
| AdminDeleteAuthorize / AdminDeleteExec | job_cmds.py:301 / :514 | only in the `admin_delete` context (set by `Env.admin_delete`) |
| AdminDisable | server_engine.py:631 | around `disable_client` + token cleanup |
| SpWaitForComplete | server_engine.py:220 (after pop), :238 (entry already gone) | the ≤2 s UPDATE_RUN_STATUS wait is **outside** the section |
| SpRemoveRunProcesses | server_engine.py:407 | `terminate()` + final pop (the ≤10 s wait loop is outside) |
| SpUpdateRunStatus / SpProcessJobFailure | private/fed/server/fed_server.py:599 / :912 (wrapper method) | whole handler |
| SweepBegin / SweepEnd | fed_server.py:1116 (emit) / :319 (section around `logout_client`) | `logout_client` .. pending loop (SweepBegin) .. run_processes loop (SweepEnd) |
| CpCheckResource / CpCancelResource | private/fed/client/scheduler_cmds.py:69 / :161 | whole resource-manager call |
| CpStartAllocate (/AppMissing) | scheduler_cmds.py:123 → private/fed/client/client_engine.py:360/:370/:372 | allocate .. `start_app` status + app-dir checks; failures closed at scheduler_cmds.py:145 after the free |
| CpStartRegister | client_executor.py:303 → :312 | STARTING registration; "still registered" raise closed at scheduler_cmds.py:145 after the free |
| CpStartLaunch (/Fail) | client_executor.py:315 → :344 (renamed at :321) | launch .. attach (pending abort honoured) .. waiter thread start |
| CpAbortApp | client_engine.py:397 → client_executor.py:522/:531/:545/:549/:558 (or client_engine.py:404/:408/:412) | status read .. abort recorded (.. `terminate()` / CJ ABORT fired / `_terminate_job` started), before the join |
| CpTerminateJob | client_executor.py:601 → :606 (early return) / :620 (after `terminate()`) | per poll iteration; cancelled (:613) between polls |
| CpChildFinished | client_executor.py:650 → :704 | reap .. rc remap .. REPORT (deferred) .. free .. pop |
| CpTick | app_common/resource_managers/auto_clean_resource_manager.py:106 → :120 | one real tick body; no event when nothing is reserved |
| SjFinish / SjCrash / SjHandleAbort | src/nvf_env.py `Env.sj_finish` / `sj_crash` / `sj_handle_abort` | stub SJ at the process edge |
| CjNotifyStarted / CjNotifyStopped / CjHandleAbort | `Env.cj_notify_started` / `cj_notify_stopped` / `_cj_on_abort` | wrap the real `NotifyJobStatusProcessor` |
| CjExit / CjGroupExit | `Env.cj_exit` / `cj_group_exit` | stub CJ leader / descendants |
| Heartbeat | `Env.heartbeat` | CP `get_all_job_ids` + real `FederatedServer._sync_client_jobs`; the abort list is then processed by the real `Communicator._clean_up_runs` (CpAbortApp, flag=TRUE) |
| ClientCrash | `Env.client_crash` | CP stops; its CJs exit; queued requests to it are purged |
| LoseMsg | `Network.lose` (drop policy or `drop_held`) | identity = the dropped message |

Reproduction gates (no-op unless a scenario registers them; never honoured while `T` is held):
`runner.after_scan_list` (job_def_manager.py:525), `runner.before_check_submitted` (job_runner.py:686),
`runner.after_deploy` (:696), `runner.before_check_dispatched` (:726), `runner.before_set_running` (:742),
`runner.after_start_client_job` (:319), `rmw.between` (filesystem_storage.py:280),
`wfc.after_read` (server_engine.py:208; retained source entry, before the UPDATE wait).


## Phase 3 addition

- `SpWaitRead(job, arg.record_present)`: `ServerEngine.wait_for_complete`, pristine SE:204–205, after process.wait returns and around the actual run_processes.get. Own trace section; records before wfc.after_read gate. No product transition added. Trace checks the captured Boolean and full post-state.
