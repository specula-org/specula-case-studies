# CR-16 Investigation

Source: Code Review

## Step 1: Code audit

Relevant code:

- `nvflare/private/fed/server/server_engine.py:203-234`: `wait_for_complete()` waits for the SJ process, reads `self.run_processes.get(job_id)` without holding `engine.lock`, waits up to 2 seconds for `PROCESS_FINISHED`, then under `engine.lock` calls `get_return_code()`, records a non-zero `PROCESS_RETURN_CODE` into `exception_run_processes`, and pops `run_processes`.
- `nvflare/private/fed/server/server_engine.py:354-409`: `abort_app_on_server()` snapshots the job handle, sends optional in-band ABORT, then starts `_remove_run_processes()` in a non-daemon background thread. `_remove_run_processes()` can terminate the captured handle and unconditionally pop the same `run_processes` entry.
- `nvflare/private/fed/utils/fed_utils.py:547-564`: `get_return_code()` reads the rc file first and otherwise returns `job_handle.poll()`, preserving real local launcher return-code behavior.
- `nvflare/private/fed/server/job_runner.py:441-541`: `_job_complete_process()` observes `exception_run_processes[job_id]`. With no exception record, `_classify_finished_job_status(None)` returns `FINISHED:COMPLETED`; with return code `1`, it returns `FINISHED:EXECUTION_EXCEPTION` (`job_runner.py:543-572`).

Race mechanics:

1. If cleanup pops `run_processes[job_id]` before `wait_for_complete()` executes line 205, the waiter skips return-code observation entirely. The SJ can have a real non-zero local-process return code, but `exception_run_processes` remains empty.
2. If `wait_for_complete()` reads the dict at line 205 before cleanup pops it, it retains the dict reference. Cleanup can still pop `run_processes`, but the waiter later writes `PROCESS_RETURN_CODE` through the retained dict and stores it in `exception_run_processes`.
3. The completion thread consumes this difference as a terminal-status difference: no exception record => `FINISHED:COMPLETED`; rc 1 recorded => `FINISHED:EXECUTION_EXCEPTION`.

Reachability:

- Normal start path reaches the injected state used by reproduction: `_start_runner_process()` launches a job handle, writes `self.run_processes[job_id] = {JOB_HANDLE, JOB_ID, PARTICIPANTS}`, and starts the waiter thread (`server_engine.py:315-328`).
- `_start_run()` calls `engine.start_app_on_server()` before inserting the job into `running_jobs` (`job_runner.py:304`, `job_runner.py:703-711`). It also registers pending client outcomes before waiting for START_JOB replies (`job_runner.py:308-310`).
- A fast client outcome is accepted once pending contains the client (`fed_server.py:938-940`). For `UNSAFE_COMPONENT`, `process_job_failure()` calls `job_runner.stop_run()` (`fed_server.py:952-955`).
- In this start window, `stop_run()` calls `_stop_run()` and reaches `engine.abort_app_on_server()` because `engine.run_processes` already has the SJ (`job_runner.py:374-392`), but `mark_run_aborted()` cannot set `job.run_aborted` because the job has not yet been inserted into `running_jobs` (`job_runner.py:798-811`). This leaves completion dependent on the exception/return-code record.

Safeguards/masks encountered:

- Ordinary admin abort of an already-running job is masked by `job.run_aborted=True`; `_job_complete_process()` then publishes `FINISHED:ABORTED` regardless of the SJ return-code race (`job_runner.py:486-489`).
- `fail_run()` records an authoritative failure before it calls `_stop_run()` (`job_runner.py:813-843`), so this specific race is not the usual fail-run path.
- The start-window `UNSAFE_COMPONENT`/stop path does not get either of those masks when it runs before `running_jobs` insertion.

## Step 2: Developer knowledge search

Local source/test search found no existing test for the pop-before-read interleaving:

- `tests/unit_test/private/fed/server/server_engine_test.py:248-265` asserts that `wait_for_complete()` records a first non-zero return code when the entry is present.
- `tests/unit_test/private/fed/server/server_engine_test.py:323-373` asserts that `_remove_run_processes()` terminates the captured handle and tolerates termination failure.
- No test covers `_remove_run_processes()` popping before `wait_for_complete()` reads `run_processes`.

Commit / history search performed in the pinned local repository:

- `git log --grep='wait_for_complete|remove_run_processes|return code|run_processes|PROCESS_RETURN_CODE|abort cleanup|UPDATE_RUN_STATUS' --all --regexp-ignore-case -- ...` found related lifecycle commits, but no exact report of cleanup-pop vs waiter rc observation.
- `git log -S'_remove_run_processes' -- server_engine.py tests/.../server_engine_test.py` found `924998da` and older HA cleanup work. `924998da` added/changed the current captured-handle cleanup behavior and comments, but the commit message is a generic cherry-pick of several PRs and does not identify this race.
- `git log -S'PROCESS_RETURN_CODE' -- server_engine.py job_runner.py fed_server.py tests/...` found return-code propagation and precedence work (`924998da`, `00589c73`, `535373a0`, `6608949c`, `e3568925`, etc.), but not this read/pop interleaving.

Developer intent evidence:

- `server_engine.py:386-388` says `_remove_run_processes()` always calls `terminate()` for the captured launcher handle as the launcher-managed cleanup path, even after the graceful wait.
- `server_engine_test.py:339-350` intentionally requires terminating a captured handle even after `wait_for_complete` already popped `run_processes`.
- `server_engine_test.py:248-265` intentionally requires non-zero SJ return codes to be recorded for classification.
- These intents conflict in the untested ordering where cleanup pops before the waiter gets the entry.

## Step 3: Known-status / precedent

Within the permitted local git history and tests, I found no issue/PR/commit message or test that reports this exact mechanism at this site: `_remove_run_processes()` popping before `wait_for_complete()` observes `run_processes`, thereby losing a real non-zero local-process return code and changing completion classification. Novelty recorded as NEW.

## Phase 2 reproduction summary

Reproduction file:

`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-16_cleanup_return_code_race.py`

Escalation:

- Level 0 pure black-box full deployment was not used for the final trigger; the race needs precise ordering at the SJ waiter/cleanup boundary.
- Level 1 timing alone was not sufficient without a stable way to hold the post-launch state.
- Level 2 state injection was used: the harness creates the normal post-`_start_runner_process()` `run_processes` entry with a real local `ProcessHandle`, then runs the real `abort_app_on_server()`, `_remove_run_processes()`, `wait_for_complete()`, and `JobRunner` classification logic.

Result:

The same real local child process exit code `1` is observed as `FINISHED:COMPLETED` when cleanup pops before the waiter reads the entry, and as `FINISHED:EXECUTION_EXCEPTION` when the waiter retained the dict before cleanup popped it.
