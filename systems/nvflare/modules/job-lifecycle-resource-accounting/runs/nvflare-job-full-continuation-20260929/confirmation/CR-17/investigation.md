# CR-17 Investigation

## Code audit

Source is the CR-17 worktree at commit `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

Cited path:

- `nvflare/private/fed/server/fed_server.py:942-956`: `FederatedServer.process_job_failure` sends `CONFIG_ERROR`, `EXCEPTION`, `INFRASTRUCTURE_ERROR`, and `ABORTED` client terminal reports through `job_runner.fail_run(...)`; `UNSAFE_COMPONENT` is different and calls `job_runner.stop_run(...)`.
- `nvflare/private/fed/server/job_runner.py:287-364`: `_start_run` starts the server app at line 304, inserts `_pending_client_outcomes[job_id]` at lines 308-309, starts client jobs at line 310, and fires `JOB_STARTED` at line 364.
- `nvflare/private/fed/server/job_runner.py:703-711`: after `_start_run` returns, `JobRunner.run` inserts the job into `running_jobs` and writes `RUNNING`.
- `nvflare/private/fed/server/job_runner.py:374-393`: `_stop_run` aborts the server and clients when `engine.run_processes` has the job.
- `nvflare/private/fed/server/job_runner.py:798-811`: `stop_run` calls `_stop_run`, then `mark_run_aborted`; `mark_run_aborted` only sets `job.run_aborted = True` if the job is already in `running_jobs`.
- `nvflare/private/fed/server/job_runner.py:485-489` and `543-568`: the completion thread publishes `FINISHED:ABORTED` only if `job.run_aborted` is true; without an exception record and without `run_aborted`, a cleanly aborted server job is classified as `FINISHED:COMPLETED`.
- `nvflare/private/fed/client/client_executor.py:630-655`: clients preserve/report return codes, including `UNSAFE_COMPONENT`, through the terminal outcome report.

Reachable trigger sequence:

1. `JobRunner.run` schedules a job and `_start_run` starts the server job, creating `engine.run_processes[job_id]`.
2. `_start_run` creates `_pending_client_outcomes[job_id]`, then sends `START_JOB` to clients.
3. During this startup window, a client job exits with preserved `UNSAFE_COMPONENT` and reports `REPORT_JOB_FAILURE`.
4. `FederatedServer.process_job_failure` accepts the report because that client is pending, then calls `job_runner.stop_run`.
5. `_stop_run` aborts the server job, but `mark_run_aborted` sees no `running_jobs[job_id]` yet and does not record the abort.
6. `_start_run` returns; `JobRunner.run` inserts the job into `running_jobs` and writes `RUNNING`.
7. After client outcomes resolve and the cleanly aborted server job is removed from `run_processes`, `_job_complete_process` publishes `FINISHED:COMPLETED`.

Safeguards checked:

- `fail_run` records an authoritative `exception_run_processes[job_id][PROCESS_RETURN_CODE]` and releases the outcome barrier, but the unsafe path deliberately does not use `fail_run`.
- The server-job heartbeat `_set_job_aborted` path applies to jobs missing from `run_processes` that still heartbeat; it does not repair the startup-window `stop_run` marker miss.
- The outcome barrier delays completion until remaining client outcomes resolve; it does not infer `FINISHED_ABORTED` from the earlier unsafe stop.

## Developer knowledge search

In-tree tests and comments show intended pieces:

- `tests/unit_test/private/fed/server/fed_server_test.py:778-816` asserts `UNSAFE_COMPONENT` reports call `stop_run`, not `fail_run`.
- `tests/unit_test/private/fed/server/job_runner_test.py:782-800` asserts `stop_run` does not publish terminal status before completion and only sets the in-memory `run_aborted` marker.
- `tests/unit_test/private/fed/server/job_runner_test.py:688-709` and `857-881` assert `fail_run` records an authoritative exception process and releases pending client outcomes.
- `nvflare/private/fed/server/job_runner.py:837-840` comments that `fail_run` establishes an authoritative terminal failure and bypasses the normal outcome grace period.
- `docs/design/job_launcher_and_job_handle.md:88-100` documents that launchers can return `UNSAFE_COMPONENT`.

Local commit history / precedent search:

- Searched local git history with `git log --grep` and `git log -S` for `UNSAFE`, `UNSAFE_COMPONENT`, `ComponentNotAuthorized`, `stop_run`, `run_aborted`, `job failure`, and `REPORT_JOB_FAILURE` over the relevant server/client files.
- Related commits found: `6d193a24` ("Fix aborted job status publication race"), `46cfc517` ("Wait for client terminal outcomes before finalizing jobs"), `535373a0` ("Finalize failed jobs with missing client outcomes"), and `71fbcaae` ("Fix K8s child failure propagation").
- Those commits address adjacent abort/failure propagation and outcome ordering, but the local history did not show a report or fix for this exact mechanism: `UNSAFE_COMPONENT` during `_start_run` routed through `stop_run`, with `mark_run_aborted` no-op before `running_jobs` insertion, leading to `FINISHED:COMPLETED`.

Known-status result: no matching existing local issue/PR/commit found for this exact site and mechanism. External issue/PR lookup was not performed because the continuation instructions prohibit consulting external answers/upstream discussions; the local git history includes PR numbers and recently merged commits available in the checkout.
