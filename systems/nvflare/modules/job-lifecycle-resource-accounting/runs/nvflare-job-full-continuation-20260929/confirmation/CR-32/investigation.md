# CR-32 Investigation

## Finding

CR-32 is a code-review finding about lock/RPC ordering and late lifecycle notifications. I narrowed the confirmation target to the concrete server-side abort/completion ordering that can publish a completed terminal status after an accepted admin abort.

## Relevant Code Path

- `nvflare/private/fed/server/job_cmds.py:1051-1078`: the public admin `abort_job` command calls `job_runner.stop_run(job_id, fl_ctx)` for running jobs. On an empty return message it reports success with `Abort signal has been sent to the server app.`
- `nvflare/private/fed/server/job_runner.py:374-391`: `_stop_run` aborts clients and then calls `engine.abort_app_on_server(job_id)`.
- `nvflare/private/fed/server/job_runner.py:798-800`: `stop_run` calls `_stop_run` first, then calls `mark_run_aborted`.
- `nvflare/private/fed/server/job_runner.py:802-811`: `mark_run_aborted` sets `job.run_aborted = True` only after `_stop_run` returns.
- `nvflare/private/fed/server/server_engine.py:203-234`: `wait_for_complete` removes `engine.run_processes[job_id]` after a clean child-process exit and does not record an exception for return code 0.
- `nvflare/private/fed/server/job_runner.py:441-541`: `_job_complete_process` finalizes a job after `engine.run_processes` no longer contains it. If `job.run_aborted` is still false, it classifies a clean server outcome as `FINISHED:COMPLETED` and publishes that status with `job_manager.set_status`.

The race window is between the start of `stop_run` and the later `mark_run_aborted` call. During that window, the server child process may shut down cleanly in response to the abort RPC, `wait_for_complete` may remove the run process, and the completion loop may publish `FINISHED:COMPLETED` before the abort flag is visible.

## Reachability

The injected starting state used by the repro is a normal running server job state:

1. A job is scheduled and started by `JobRunner._start_run`, which records it in `running_jobs` and starts the server app.
2. The server engine tracks the child process in `engine.run_processes`, and the normal completion watcher is active.
3. An operator or API caller issues `abort_job`, which reaches `JobCommandModule.abort_job` and `JobRunner.stop_run`.
4. The child server runner receives the abort command and exits cleanly before `stop_run` reaches `mark_run_aborted`.

The repro controls the timing of the child abort RPC and fake child process but uses the real `JobCommandModule.abort_job`, `JobRunner.stop_run`, `JobRunner._job_complete_process`, `ServerEngine.abort_app_on_server`, `ServerEngine.wait_for_complete`, and `ServerEngine._remove_run_processes` methods.

## Developer Intent

- `docs/user_guide/admin_guide/deployment/operation.rst:42` documents `abort_job job_id` as aborting a running or dispatched job.
- `nvflare/fuel/flare_api/flare_api.py:560-581` documents `abort_job`; if the job is being executed, it will be aborted.
- `docs/system_architecture/system_architecture.rst:339-342` defines `FINISHED_COMPLETED` as successful completion and `FINISHED_ABORTED` as a job aborted by admin request or by a failure classified as an abort.
- Existing tests verify adjacent intent: `tests/unit_test/private/fed/server/job_runner_test.py:782-800` expects `stop_run` to mark a running job aborted, and completion tests expect `FINISHED_ABORTED` when `run_aborted` is already true before finalization.

## Prior-Report / Known-Status Search

I did not read `bug-report.md`, other findings, or the shared repair queue. For known-status, I searched local git metadata and local tests/docs only:

- `git log --oneline --decorate --all --grep='abort.*completed\|completed.*abort\|stop_run\|mark_run_aborted\|FINISHED_COMPLETED\|FINISHED_ABORTED\|JOB_ABORTED' -- ...`
- `git log --oneline --decorate --all -S'mark_run_aborted' -- nvflare/private/fed/server/job_runner.py`
- `rg -n 'FINISHED_ABORTED|FINISHED_COMPLETED|abort_job|stop_run' docs nvflare tests/unit_test/private/fed/server`

The local git metadata contains later fixes titled `f2b0039e [2.8] Fix aborted job status publication race (#4613)` and `6d193a24 Fix aborted job status publication race (#4633)`. I did not inspect those newer diffs. This makes the mechanism KNOWN/fixed upstream or in the provided local metadata, while the checked-out pinned source remains at `53ba7ee567468ea7971dad4faccef13c6cb35dc2` and still has the vulnerable ordering.

## Reproduction Plan

Write and execute `repro/test_bugCR-32_stop_run_completion_race.py`.

The script runs:

- A control case where the abort RPC returns immediately. The admin abort returns OK and completion publishes `FINISHED:ABORTED`.
- A timed race case where the child process exits cleanly while the abort RPC is still in progress. The completion loop observes no run process and `job.run_aborted == False`, publishes `FINISHED:COMPLETED`, then the admin abort returns OK and only then `stop_run` marks the now-finalizing job aborted.

Expected bug evidence: the public admin abort command reports success, but the recorded terminal status is `FINISHED:COMPLETED` instead of `FINISHED:ABORTED`, and there is no later mechanism to revise it because `_job_complete_process` removes the job from `running_jobs`.
