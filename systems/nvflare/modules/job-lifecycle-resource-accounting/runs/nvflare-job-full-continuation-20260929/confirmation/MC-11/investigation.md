# MC-11 Investigation

## Finding

MC-11 concerns a startup interval in which `JobRunner._start_run()` has already
created `_pending_client_outcomes[job_id]`, but `JobRunner.run()` has not yet
inserted `running_jobs[job_id]`. If the server job process exits cleanly in that
interval, `ServerEngine.wait_for_complete()` can also remove
`engine.run_processes[job_id]`.

## Source Audit

- `nvflare/private/fed/server/job_runner.py:304-310` starts the server app, then
  creates the pending-client outcome set before waiting for `start_client_job()`
  replies.
- `nvflare/private/fed/server/job_runner.py:703-710` inserts
  `running_jobs[job_id]` only after `_start_run()` returns.
- `nvflare/private/fed/server/server_engine.py:203-233` removes
  `engine.run_processes[job_id]` after the server job process exits; a zero exit
  leaves no `exception_run_processes[job_id]`.
- `nvflare/private/fed/server/fed_server.py:938-956` accepts a client terminal
  failure when the client is in the pending set, calls `job_runner.fail_run()`,
  and then resolves the client outcome.
- `nvflare/private/fed/server/job_runner.py:817-836` treats a job as inactive
  when both `running_jobs` and `engine.run_processes` lack the job. In that case
  it returns "not running" without recording `exception_run_processes`.
- `nvflare/private/fed/server/job_runner.py:444-489` later finalizes from the
  server outcome when `running_jobs` contains the job, `run_processes` is gone,
  no exception was recorded, and the pending set was resolved. The classifier at
  `job_runner.py:545-546` maps a missing exception process to
  `FINISHED:COMPLETED`.

## Reachability

The precondition is reachable through the normal local-process lifecycle:

1. The scheduler selects a submitted job and `JobRunner.run()` calls
   `_start_run()`.
2. `start_app_on_server()` inserts `engine.run_processes[job_id]` for the server
   job process.
3. `_start_run()` creates `_pending_client_outcomes[job_id]`.
4. A fast/no-op server workflow exits normally before `start_client_job()` has
   returned; `wait_for_complete()` removes `engine.run_processes[job_id]`.
5. A client job process reports `ProcessExitCode.EXCEPTION` through
   `FederatedServer.process_job_failure()`.
6. `fail_run()` sees neither active map, records no exception, and returns
   "not running"; `process_job_failure()` then resolves the pending client.
7. `_start_run()` returns, `JobRunner.run()` inserts `running_jobs[job_id]`, and
   completion publishes `FINISHED:COMPLETED`.

No impossible state is needed; the timing help is that the server process exits
cleanly before the client-start RPC finishes.

## Developer Intent

The status contract in `docs/system_architecture/system_architecture.rst:339-345`
distinguishes successful completion from execution exceptions. The local commit
history shows recently merged terminal-outcome repairs:

- `46cfc517` / PR `#5072`, "Wait for client terminal outcomes before finalizing
  jobs", says client terminal failures must be applied before releasing the
  reporting client from the completion barrier.
- `535373a0` / PR `#5221`, "Finalize failed jobs with missing client outcomes",
  preserves already-recorded server failures when client outcomes are pending.

Focused tests also encode the intended active path:
`tests/unit_test/private/fed/server/job_runner_test.py:688-708` records an
exception for active `fail_run()`, and
`tests/unit_test/private/fed/server/job_runner_test.py:857-881` releases the
client-outcome barrier only after active `fail_run()` establishes a terminal
failure. The MC-11 gap is not covered by those tests: the accepted client failure
arrives while the job is pending but not yet in either active map.

## Known Status

Permitted prior-report search was limited to the pinned local git history and
tests, per the continuation instructions. Searches over commit messages,
`-S _pending_client_outcomes`, `-S process_job_failure`, and related tests found
PRs `#5072`, `#5221`, and `#4432`, but no upstream fix for this exact startup
gap. The provided finding metadata identifies this as the historical Specula
dataset entry `MC-U1`, so the result is known by dataset ID and unfixed in this
worktree.

## Reproduction

Wrote and executed with the required outer timeout:

`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-11_startup_gap.py`

Command:

```bash
timeout 60s python /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-11_startup_gap.py | tee /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-11_startup_gap.out
```

The positive run uses real `JobRunner.run()`, real `_start_run()`, real
`FederatedServer.process_job_failure()`, and real `_job_complete_process()`.
The harness stubs the scheduler/environment edges and forces the real startup
timing: clean SJ exit after the pending table is created, before
`running_jobs[job_id]` is inserted. A passing active-tracking control sends the
same client failure after `running_jobs`/`run_processes` are active and confirms
that it records `ProcessExitCode.EXCEPTION` and classifies
`FINISHED:EXECUTION_EXCEPTION`.

Reproduction output:

```text
MC-11 startup-gap reproduction
worktree=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-11/worktree
repro.failure_reply_code=ok
repro.fail_run_inactive_log=True
repro.exception_record_present=False
repro.status_history=['DISPATCHED', 'RUNNING', 'FINISHED:COMPLETED']
active_control.failure_reply_code=ok
active_control.recorded_exception_code=101
active_control.classified_status=RunStatus.FINISHED_EXECUTION_EXCEPTION
active_control.pending_after_report=None
RESULT=REPRODUCED
```
