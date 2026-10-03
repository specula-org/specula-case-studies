# CR-33 Investigation

## Finding

CR-33: Retained SJ status reference can replace a newer failure record.

Source classification for this worker: Code Review. The supplied finding has no model-checking counterexample/config and describes a source-review mechanism.

## Step 1: Code Audit

### Cited code

- `nvflare/private/fed/server/fed_server.py:594-603`: `UPDATE_RUN_STATUS` reads `self.engine.run_processes.get(job_id)` under `FederatedServer.lock`, mutates that dict with `PROCESS_EXE_ERROR` and `PROCESS_FINISHED`, and assigns that same retained object to `engine.exception_run_processes[job_id]` when `execution_error` is true.
- `nvflare/private/fed/server/server_engine.py:203-233`: `wait_for_complete` reads the same `run_processes` entry, waits up to 2 seconds for `PROCESS_FINISHED`, records a nonzero SJ return code unless an exception entry already exists, then pops `run_processes[job_id]` under `engine.lock`.
- `nvflare/private/fed/server/job_runner.py:813-842`: `fail_run` is synchronized with `engine.lock`. If the job is still in `running_jobs` but no longer in `engine.run_processes`, and no exception entry exists yet, it creates a new `{PARTICIPANTS: {}}` failure record and writes `PROCESS_RETURN_CODE`.
- `nvflare/private/fed/server/job_runner.py:543-585`: completion classifies `PROCESS_RETURN_CODE == INFRASTRUCTURE_ERROR` as `FINISHED:ABNORMAL`, `PROCESS_RETURN_CODE == ABORTED` as `FINISHED:ABORTED`, and a finished record with only `PROCESS_EXE_ERROR=True` as `FINISHED:EXECUTION_EXCEPTION`.

### Call chain and reachability

The server job process reports its final run status from `ServerAppRunner.start_server_app`: an exception sets `FLContextKey.FATAL_SYSTEM_ERROR=True` at `server_app_runner.py:84-87`; the `finally` block always calls `update_job_run_status` at `server_app_runner.py:89-90`; `ServerEngine.update_job_run_status` sends `UPDATE_RUN_STATUS` by `fire_and_forget` at `server_engine.py:873-884`; the parent receives it in `FederatedServer._listen_command` at `fed_server.py:594-603`.

The process-wait side is independent: `ServerEngine._start_runner_process` records `run_processes[job_id]` under `engine.lock` at `server_engine.py:321-328` and starts the `wait_for_complete` thread. That thread can pop `run_processes[job_id]` at `server_engine.py:233`.

The client-failure side is also reachable during normal operation. `ClientExecutor._wait_child_process_finish` maps generic RC 1 while STARTING to `ProcessExitCode.INFRASTRUCTURE_ERROR` at `client_executor.py:639-642` and reports it to the server with `JobFailureMsgKey.CODE` at `client_executor.py:647-655`. `FederatedServer.process_job_failure` accepts reportable codes including `INFRASTRUCTURE_ERROR` and calls `job_runner.fail_run` at `fed_server.py:942-951`.

### Concrete trigger scenario

1. A job is in normal running state: `engine.run_processes[job]` points to the live SJ run-process dict, `JobRunner.running_jobs[job]` still contains the job, and at least one client outcome is pending.
2. The SJ finishes after an execution error and sends `UPDATE_RUN_STATUS(execution_error=True)`.
3. The handler executes `run_process_info = self.engine.run_processes.get(job_id)` and is delayed before `self.engine.exception_run_processes[job_id] = run_process_info`.
4. The SJ process exits. `wait_for_complete` does not see `PROCESS_FINISHED` because the handler is delayed; after the grace period it pops `engine.run_processes[job]`.
5. A client terminal outcome arrives with `INFRASTRUCTURE_ERROR` while the job is still in `running_jobs`. `process_job_failure` calls `fail_run`; because `engine.run_processes` is gone and `exception_run_processes` has no entry yet, `fail_run` creates a separate authoritative failure object with `PROCESS_RETURN_CODE=104`.
6. The delayed `UPDATE_RUN_STATUS` handler resumes and assigns the earlier retained live-run dict into `exception_run_processes[job]`, replacing the `fail_run` object.
7. The completion loop consumes `exception_run_processes[job]` and publishes `FINISHED:EXECUTION_EXCEPTION` from `PROCESS_EXE_ERROR=True`, instead of `FINISHED:ABNORMAL` from the client infrastructure failure code.

### Safeguards checked

- `wait_for_complete` has a guard that preserves an existing exception entry before recording the SJ exit code (`server_engine.py:223-232`), but that does not protect against an `UPDATE_RUN_STATUS` handler that already retained an old `run_processes` reference and writes it later.
- `fail_run` has precedence logic under `engine.lock` and comments saying it establishes an authoritative terminal failure (`job_runner.py:821-840`), but `UPDATE_RUN_STATUS` does not use `engine.lock` and does not merge with an existing exception entry.
- `JobRunner._job_complete_process` later removes the exception entry after publishing (`job_runner.py:540`), but that is cleanup after the wrong terminal status has been published. No downstream sync or resend corrects the persisted status.

## Step 2: Developer-Knowledge Search

### Comments and tests

- `server_engine.py:223-228` explicitly says an external path such as `fail_run` may already have recorded an authoritative return code and that the SJ's secondary exit code must not overwrite it.
- `job_runner.py:837-840` says `fail_run` establishes an authoritative terminal failure.
- `job_runner.py:560-562` says an external failure return code must be preserved even if the SJ later reports a clean shutdown via `UPDATE_RUN_STATUS`.
- Tests added around PR #4552 cover adjacent precedence cases: `k8s_pending_timeout_status_test.py:231-278`, `job_runner_test.py:656-684`, and `server_engine_test.py:225-265`. They cover clean/secondary update or SJ exit-code clobbering, not the retained-reference `execution_error=True` replacement path.

### Commits and blame

- `34efe682` / PR #4552 `[2.8] Fix job timeout status in list_jobs` and cherry-pick `924998da` added the current status-precedence work. The PR describes K8s pending pods showing `RUNNING`, not a delayed `UPDATE_RUN_STATUS(execution_error=True)` replacing a separate failure object.
- `535373a0` added current `fail_run` locking/precedence and comments in `job_runner.py`.
- `fed_server.py:597-601` dates back to older update-status handling and was not changed to use `engine.lock` or preserve an existing exception entry.

## Step 3: Known Status / Precedent

Searches performed:

- Local history: `git log --all --grep` and path-limited searches for `UPDATE_RUN_STATUS`, `exception_run_processes`, `fail_run`, `PROCESS_EXE_ERROR`, `PROCESS_RETURN_CODE`, and status/client-outcome terms over `fed_server.py`, `server_engine.py`, `job_runner.py`, and server tests.
- Upstream issue/PR tracker via GitHub search API against `repo:NVIDIA/NVFlare`: queries for `UPDATE_RUN_STATUS exception_run_processes fail_run`, `exception_run_processes PROCESS_EXE_ERROR PROCESS_RETURN_CODE`, and `is:pr is:closed UPDATE_RUN_STATUS exception_run_processes`. Successful searches returned PR #4552 only; broader unauthenticated follow-up queries hit GitHub API rate limiting.

Known result: PR #4552 is related but not the same mechanism. It fixes/report-tests status preservation for K8s pending timeout, clean `UPDATE_RUN_STATUS`, and SJ exit-code overwrite. I found no issue/PR/commit reporting the exact same retained-reference mechanism where a delayed `execution_error=True` `UPDATE_RUN_STATUS` writes an old `run_processes` object back over a newer `fail_run` object after `run_processes` has been popped.

Novelty assessment: NEW.

## Reproduction Artifact

Test: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-33_retained_update_status_reference.py`

Output log: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-33_retained_update_status_reference.out`

Command:

```bash
timeout 60s python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-33_retained_update_status_reference.py
```
