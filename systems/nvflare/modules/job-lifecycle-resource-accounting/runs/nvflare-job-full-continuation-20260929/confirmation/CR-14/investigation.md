# CR-14 Investigation

## Finding

Code-review finding: best-effort server-job `UPDATE_RUN_STATUS` can arrive after the parent has stopped tracking the job process, losing an `execution_error=True` signal and causing the job to be finalized as completed.

## Step 1: Code audit

Relevant sites:

- `nvflare/private/fed/server/server_engine.py:203-233`: `wait_for_complete()` waits for the child process, then polls `run_process_info[RunProcessKey.PROCESS_FINISHED]` for at most `max_wait = 2.0` seconds. If the flag is not set in time, it proceeds to read the child return code and pops `self.run_processes[job_id]` at line 233.
- `nvflare/private/fed/server/server_engine.py:873-884`: the server job reports final status with `self.server.cell.fire_and_forget(... topic=ServerCommandNames.UPDATE_RUN_STATUS ...)`. The payload is `{"execution_error": fl_ctx.get_prop(FLContextKey.FATAL_SYSTEM_ERROR, False)}`. There is no request/reply acknowledgement in this path.
- `nvflare/private/fed/server/fed_server.py:594-604`: the parent receives `UPDATE_RUN_STATUS`, fetches `self.engine.run_processes.get(job_id)`, and only records `PROCESS_EXE_ERROR` / `PROCESS_FINISHED` if that entry is still present. If `run_processes[job_id]` has already been popped, the handler still returns OK but drops the status update.
- `nvflare/private/fed/server/server_app_runner.py:84-91`: `ServerAppRunner.start_server_app()` sets `FATAL_SYSTEM_ERROR` on exceptions and always calls `update_job_run_status()` in `finally`.
- `nvflare/private/fed/server/server_runner.py:252-256`: an in-run fatal event sets `FLContextKey.FATAL_SYSTEM_ERROR=True` and aborts the current run. This can leave the process to shut down normally, so the final status update can be the only signal distinguishing `FINISHED_EXECUTION_EXCEPTION` from clean completion.
- `nvflare/private/fed/server/job_runner.py:441-540`: the completion thread publishes a terminal status once the job disappears from `engine.run_processes`.
- `nvflare/private/fed/server/job_runner.py:543-572`: `_classify_finished_job_status(None)` returns `FINISHED_COMPLETED`; if an exception process with `PROCESS_FINISHED=True` and `PROCESS_EXE_ERROR=True` is present, it returns `FINISHED_EXECUTION_EXCEPTION`.
- `nvflare/apis/impl/job_def_manager.py:459-481`: `set_status()` persists the terminal status consumed by admin/status readers.

Reachable trigger sequence:

1. A job is scheduled and started normally. `JobRunner._start_run()` calls `engine.start_app_on_server()`, and `ServerEngine._start_runner_process()` inserts `engine.run_processes[job_id]` and starts the `wait_for_complete` thread (`server_engine.py:321-328`).
2. During the server app run, an event fires `EventType.FATAL_SYSTEM_ERROR`. `ServerRunner.handle_event()` sets sticky `FLContextKey.FATAL_SYSTEM_ERROR=True` and aborts the run (`server_runner.py:252-256`).
3. The server job process reaches `ServerAppRunner.start_server_app()`'s `finally` block and sends `UPDATE_RUN_STATUS(execution_error=True)` through `fire_and_forget` (`server_app_runner.py:89-90`, `server_engine.py:873-884`).
4. The child process exits with return code 0. If the `UPDATE_RUN_STATUS` callback reaches the parent before `wait_for_complete`'s 2 second wait expires, the parent records `PROCESS_EXE_ERROR=True` and completion publishes `FINISHED_EXECUTION_EXCEPTION`.
5. If delivery is delayed beyond that 2 second wait, `wait_for_complete` sees no nonzero return code and pops `run_processes[job_id]`. The later `UPDATE_RUN_STATUS` handler sees no entry and silently records nothing. Completion then publishes `FINISHED_COMPLETED`.

Safeguards checked:

- Nonzero process return codes are a safeguard: `wait_for_complete()` records nonzero return codes in `exception_run_processes`. CR-14 is specifically the rc=0 path where the fatal signal is carried only by `UPDATE_RUN_STATUS`.
- Client outcome handling does not repair this server-side status loss. When there is no `exception_run_processes[job_id]`, `_classify_finished_job_status(None)` returns completed. No later `UPDATE_RUN_STATUS` handler path revisits the published terminal status.
- The handler returns OK for the late message, but because `run_processes[job_id]` is absent it does not write `exception_run_processes`.

## Step 2: Developer knowledge search

Comments / tests near the code:

- `server_engine.py:207-216` explicitly says the parent is waiting for the job process to finish `UPDATE_RUN_STATUS`, but bounds that wait to 2 seconds and then logs that the update did not finish fast enough.
- `job_runner.py:560-563` comments that an external failure code should be preserved even if the SJ later reports a clean shutdown. This covers failure-code precedence, not a late best-effort `execution_error=True` update after `run_processes` has been popped.
- Existing tests cover nonzero return-code precedence and clean SJ-finish precedence (`tests/unit_test/private/fed/server/server_engine_test.py:225-265`, `tests/unit_test/private/fed/server/job_runner_test.py:656-684`, `tests/unit_test/private/fed/server/job_runner_test.py:884-940`). I found no test for `UPDATE_RUN_STATUS(execution_error=True)` arriving after the pop.

Git history / PR search:

- `git blame` shows the 2 second wait and pop are old status-management code, while later fixes added failure-code precedence around `exception_run_processes`.
- Local history found related status fixes: `34efe682/#4552`, `924998da/#4592`, `6d193a24/#4633`, `46cfc517/#5072`, and `71fbcaae/#5047`. These address timeout status, abort status races, client terminal outcomes, and child/launcher failure propagation. None report this exact mechanism: best-effort `UPDATE_RUN_STATUS(execution_error=True)` arriving after `run_processes` is popped.
- GitHub issue/PR search:
  - API search `repo:NVIDIA/NVFlare UPDATE_RUN_STATUS execution_error run_processes`: `total_count=0`.
  - API search `repo:NVIDIA/NVFlare "UPDATE_RUN_STATUS" "didn't finish fast enough"`: `total_count=0`.
  - API search `repo:NVIDIA/NVFlare "update_job_run_status" "fire_and_forget"`: `total_count=0`.
  - API / `gh search prs` for `"PROCESS_EXE_ERROR" "FINISHED_EXECUTION_EXCEPTION"` found PR #5047 and PR #4552, both related but not the same late-best-effort update mechanism.
  - `gh search issues` for `UPDATE_RUN_STATUS execution_error run_processes` found no open or closed issues.

## Step 3: Known-status / precedent

Known-status result: no existing issue / PR / CVE / advisory found for this exact mechanism at this site. Related PRs show developer attention to adjacent status races, but not the late `UPDATE_RUN_STATUS` loss. Novelty should be recorded as `NEW`.

## Phase 2 reproduction setup

Reproduction file:

`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-14_late_update_run_status.py`

Command executed:

```bash
timeout 5m python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-14_late_update_run_status.py
```

The reproduction uses real `ServerEngine.wait_for_complete()`, real `FederatedServer._listen_command()` handling of `UPDATE_RUN_STATUS`, and real `JobRunner._job_complete_process()` publication. The process handle, job store, and delivery timing are controlled to compare an on-time control against a delayed-status case. This is Level 2 state injection for the already-started server-job precondition; the injected precondition is reachable by the real sequence above.
