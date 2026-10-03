# MC-3 Investigation

## Finding

MC-3 claims that `JobRunner.run` can publish `RUNNING` after the completion thread has already published a terminal status. Source is model checking with an actual counterexample for `TerminalStable`.

## Step 1: Code Audit

### Cited Code

- `nvflare/private/fed/server/job_runner.py:633-732`: `JobRunner.run` scheduling loop.
- `nvflare/private/fed/server/job_runner.py:703-711`: after `_start_run`, the runner inserts `running_jobs[job_id] = ready_job` under `self.lock`, releases the lock, then calls `job_manager.set_status(..., RunStatus.RUNNING, ...)`.
- `nvflare/private/fed/server/job_runner.py:441-541`: `_job_complete_process` scans `running_jobs`; if a job is absent from `engine.run_processes`, it classifies the run, publishes terminal status at line 524, removes `running_jobs[job_id]` at line 532, and removes the exception-process record at line 540.
- `nvflare/private/fed/server/job_runner.py:543-572`: nonzero server process return codes such as `ProcessExitCode.EXCEPTION` classify as `FINISHED:EXECUTION_EXCEPTION`.
- `nvflare/private/fed/server/server_engine.py:203-234`: `wait_for_complete` records a nonzero return code in `exception_run_processes` and pops `run_processes`.
- `nvflare/private/fed/server/server_engine.py:321-328`: `_start_runner_process` inserts into `run_processes` and starts `wait_for_complete`.

### Reachable Call Chain

Normal server startup starts `JobRunner.run(fl_ctx)`. The runner obtains scheduling candidates, deploys, writes `DISPATCHED`, calls `_start_run`, and then writes `RUNNING`. `_start_run` calls `engine.start_app_on_server`, which creates the server-job process record and starts a `wait_for_complete` thread. If that process exits nonzero before the runner reaches line 711, `wait_for_complete` can remove `run_processes`; once the runner has inserted `running_jobs` at line 710, the completion thread has all it needs to publish the terminal status before the runner's late `RUNNING` write.

This path is reachable through ordinary local-process job execution. The reproduction uses the real `JobRunner.run` and `_job_complete_process` entry points with the network/process edges stubbed as a test environment. It does not prepopulate `running_jobs`, call `_job_complete_process` directly, or patch NVFlare source.

### Trigger Scenario

1. A job is scheduled and deployed.
2. `_start_run` starts the server-job process and at least one client START path.
3. The server-job process exits with a nonzero code before the runner publishes `RUNNING`.
4. `wait_for_complete` records the exception and pops `engine.run_processes[job_id]`.
5. The runner inserts `running_jobs[job_id] = ready_job`.
6. The completion thread observes `job_id in running_jobs` and `job_id not in run_processes`, classifies `FINISHED:EXECUTION_EXCEPTION`, writes that terminal status, and removes `running_jobs[job_id]`.
7. The runner resumes and blindly writes `RUNNING`.

### Safeguards Checked

- There is no transition guard in this path that prevents `set_status(RUNNING)` from overwriting a `FINISHED:*` value.
- The runner's `self.lock` protects the `running_jobs` insertion only; it does not cover the status write at line 711.
- Completion removes `running_jobs` and the exception record after successful terminal publication, so the live system no longer has state that will cause the completion loop to republish the terminal status.
- `update_unfinished_jobs` exists at `job_runner.py:779-796`, but it is not part of the live completion loop and does not repair this state during the same run.

### Real Consumers

- `nvflare/private/fed/server/job_cmds.py:550-565` returns persisted job metadata through `get_job_meta`, so clients/admin tooling observe `RUNNING`.
- `nvflare/private/fed/server/job_cmds.py:1051-1074` implements `abort_job`. If persisted status is `RUNNING`, it calls `job_runner.stop_run`; after completion has already removed the job from `running_jobs`, `mark_run_aborted` returns `Job <id> is not running.`
- `nvflare/private/fed/server/job_cmds.py:1711-1721` rejects download when the stored status is not `FINISHED:*`.

## Step 2: Developer-Knowledge Search

### Documentation and Intent

- `docs/system_architecture/system_architecture.rst:206-214` describes the intended sequence: startup succeeds, the job is marked `RUNNING`; after SJ/CJ termination, the server archives the workspace and records the terminal job status.
- `docs/user_guide/core_concepts/job.rst:342-344` says once a job is executed, its status is updated and it will not be scheduled again.
- `docs/user_guide/nvflare_cli/job_cli.rst:228-236` describes `job wait` as returning one final terminal job status.
- `docs/user_guide/nvflare_cli/job_cli.rst:353-354` says a job must be in a terminal state before download.

These docs support terminal status as the durable lifecycle state observed by admin and CLI tooling.

### Git History / Blame

- `job_runner.py:710` originates from `2ea6522c Replace run_number with job_id in most occurrences. (#654)`.
- `job_runner.py:711` originates from `6f75707f`, a parent/job-process control change.
- Recent related fixes in this file include `6d193a24 Fix aborted job status publication race (#4633)`, `e1206061 Fix concurrent job lifecycle accounting (#5216)`, and `535373a0 Finalize failed jobs with missing client outcomes (#5221)`. None of the pinned-source code inspected adds a guard around the late `RUNNING` write.

### Tests

Existing `job_runner_test.py` coverage exercises completion publication and removal for jobs already in `running_jobs`, but the search did not find an in-tree test that asserts `RUNNING` cannot be written after a terminal completion publish. Existing `job_cmds_test.py` coverage includes `abort_job` branches but not this post-completion stale-`RUNNING` case.

## Step 3: Known Status / Precedent

Tracker search covered open and closed issues/PRs with targeted queries for `job_runner.py`, `RUNNING`, `FINISHED`, `running_jobs`, and status overwrite terms. It found:

- Same mechanism: NVIDIA/NVFlare issue #5301, "Delayed RUNNING status write can overwrite a completed job status", closed with `state_reason: not_planned` and no linked PR in the issue events inspected. This is the same site and mechanism as MC-3. Fix status for this pinned-source confirmation is therefore `unfixed`.
- Related but different mechanism: issue #5300, "Pre-run abort can be overwritten after client deployment starts".
- Related closed PRs found by search, such as #5221, #4633, and #4604, address adjacent lifecycle/status races but not the late `RUNNING` overwrite at this site in the pinned source.

Known-status result: `KNOWN (cite: https://github.com/NVIDIA/NVFlare/issues/5301; fix-status: unfixed)`.
