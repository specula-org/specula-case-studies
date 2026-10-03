# MC-6 Investigation

## Finding

MC-6 reports that two cleanup paths can race on `JobRunner.running_jobs`: the completion thread publishes a terminal status and then blindly deletes the running entry, while the runner startup path can still be pending at the late `RUNNING` status write and can remove the same entry during exception cleanup.

## Code audit

The completion loop scans `list(self.running_jobs.keys())` in `nvflare/private/fed/server/job_runner.py:443-445`. When the process is no longer present in `engine.run_processes`, it computes the finished status, saves the workspace, and calls `job_manager.set_status(job.job_id, status, completion_ctx)` inside a try/except at `job_runner.py:523-530`. That protects only the terminal status write. After a successful terminal publish, `job_runner.py:531-532` executes `del self.running_jobs[job_id]` under `self.lock` with no presence check and no surrounding exception handler. The lifecycle events that release downstream consumers are after this deletion at `job_runner.py:536-538`.

The startup path starts the job and inserts the running entry before publishing the `RUNNING` status. In `job_runner.py:703-711`, `_start_run` fires the start path, then the runner stores `self.running_jobs[job_id] = ready_job`, and only after that calls `job_manager.set_status(..., RunStatus.RUNNING, fl_ctx)`. The enclosing exception handler at `job_runner.py:713-720` removes the same `running_jobs` key if present before `_stop_run` and before writing `FAILED_TO_RUN`.

The admin delete command can act on a stale authorized job snapshot. `JobCommandModule.authorize_job_id` loads the job and stores it in the connection at `nvflare/private/fed/server/job_cmds.py:298-310`. `delete_job` later reads that stored job at `job_cmds.py:507-516` and rejects only if the snapshot status is `DISPATCHED` or `RUNNING`. It then calls `job_def_manager.delete(job_id, fl_ctx)` at `job_cmds.py:527-528` without reloading current status. `JobDefManager.delete` delegates to storage deletion at `nvflare/apis/impl/job_def_manager.py:354-356`; later status writes use `update_meta` at `job_def_manager.py:459-481`. The filesystem storage raises `StorageException` if `update_meta` targets a deleted object at `nvflare/app_common/storages/filesystem_storage.py:251-268`.

The live consequence is observable by `DefaultJobScheduler`. It appends the job on `JOB_STARTED` and removes it only on `JOB_COMPLETED` or `JOB_ABORTED` in `nvflare/app_common/job_schedulers/job_scheduler.py:275-285`. If the completion thread raises before the end event, the scheduler's `scheduled_jobs` retains the job and `max_jobs` admission can remain blocked.

## Reachable trigger

The code admits the following interleaving without source changes:

1. A submitted job is scheduled and `_start_run` starts the server/client job.
2. `JobRunner.run` inserts `running_jobs[job_id]`, but the late `set_status(RUNNING)` call has not returned.
3. The job process and client outcome complete, so `_job_complete_process` observes the job as finished.
4. Completion publishes a terminal `FINISHED:*` status successfully.
5. An already authorized admin `delete_job` command uses the terminal snapshot and deletes the job object.
6. The late `set_status(RUNNING)` raises because the job object was deleted.
7. The runner exception handler removes `running_jobs[job_id]`.
8. Completion resumes and executes `del self.running_jobs[job_id]`, raising `KeyError` before lifecycle release events.

This matches the model counterexample action sequence recorded in the validation handoff for MC-6: `AdminDeleteAuthorize`, `RunnerStartServerApp`, `SjFinish`, `SpWaitForComplete`, `RunnerStartCollect`, `RunnerInsertRunning`, `CmpFinalizeBegin`, `CmpPublish`, `AdminDeleteExec`, `RunnerSetRunning`, `RunnerExceptStop`, `CmpRemove`.

## Developer knowledge and known-status search

I found adjacent historical fixes, but no public issue or PR describing this exact mechanism at the same site. Local history searches for `running_jobs`, `KeyError`, completion thread deletion, `delete_job`, `CompletionAlive`, and related phrases did not find a prior report for the blind completion deletion after runner cleanup. Reviewed adjacent commits/PRs included:

- `784eb2d0` / PR #4632, mapping failed deletion of a still-running job to `JOB_NOT_DONE`; this is about rejecting an actively running delete, not the stale terminal snapshot plus completion blind delete.
- `e1206061` / PR #5216, fixing concurrent lifecycle accounting for event contexts; this is not the same `running_jobs` deletion collision.
- `1b009bdc` / PR #4471, fixing completion context job-id handling; this is not the same `KeyError` or cleanup race.
- `15bebb31` / PR #630, improving server-start/client-start failure cleanup; this added runner-side cleanup but does not cover the completion-thread blind deletion.
- PR #4986, related to Slurm launcher infrastructure failures; this is not the same mechanism.

GitHub issue/PR searches against `NVIDIA/NVFlare` for combinations of `running_jobs`, `KeyError`, `completion thread`, `delete_job`, `del self.running_jobs`, and `JobRunner completion KeyError` found no report of this same mechanism. The novelty status is therefore `NEW`.

## Reproduction evidence

The reproduction test is `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-6_completion_keyerror.py`.

It uses the pinned source at commit `53ba7ee567468ea7971dad4faccef13c6cb35dc2`, real `JobRunner.run`, real `_job_complete_process`, real `JobCommandModule.delete_job`, and `DefaultJobScheduler.handle_event`. The fakes stand in for process, storage, and network edges only to deterministically order the ordinary events above. The captured execution output is in `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-6/repro-output.txt`.
