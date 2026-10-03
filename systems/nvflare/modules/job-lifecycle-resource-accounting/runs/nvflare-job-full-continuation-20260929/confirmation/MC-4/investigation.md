# MC-4 Investigation

## Scope

Finding: MC-4, model-checking source, invariant `NoStartKeyError` / F5.

Inspected source checkout:
`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-4/worktree`
at `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

Skill files used from the pinned framework directory:
`framework/skills/bug-confirmation/SKILL.md`, `guide.md`, `phases/01-investigation.md`,
`phases/02-reproduction.md`, and `references/persistent-findings.md`.

Handoff records inspected for MC-4/F5 context:
`handoff/conversations/README.md`, `index.json`, and targeted `rg` hits for `MC-4`, `F5`,
`NoStartKeyError`, `KeyError`, and `_pending_client_outcomes` in the four phase transcripts and relevant
analysis-child transcripts. Prior conclusions were treated as leads only and rechecked against the pinned source.

## Step 1: Code audit

### Relevant code

- `nvflare/private/fed/server/job_runner.py:287-364`: `_start_run` starts the server job process, creates
  `_pending_client_outcomes[job_id]` at `:308-310`, sends START_JOB to clients, then directly indexes
  `_pending_client_outcomes[job_id]` at `:359-360` to intersect with the active sites.
- `nvflare/private/fed/server/job_runner.py:703-720`: the scheduling loop calls `_start_run`; any exception
  before `running_jobs[job_id]` insertion and `RUNNING` publication is caught and converted to
  `RunStatus.FAILED_TO_RUN`.
- `nvflare/private/fed/server/job_runner.py:813-843`: `fail_run` is accepted when the job is in
  `running_jobs` or `engine.run_processes`; it records `RunProcessKey.PROCESS_RETURN_CODE` in
  `engine.exception_run_processes`, then pops `_pending_client_outcomes[job_id]` at `:841`.
- `nvflare/private/fed/server/fed_server.py:906-957`: `process_job_failure` validates an authenticated
  REPORT_JOB_FAILURE message, checks `job_runner.is_client_outcome_pending`, and for
  `EXCEPTION`/`CONFIG_ERROR`/`INFRASTRUCTURE_ERROR`/`ABORTED` calls `job_runner.fail_run`.
- `nvflare/private/fed/client/client_executor.py:622-665`: the client parent waits for the child worker, maps
  actionable return codes, and sends REPORT_JOB_FAILURE to the server. Generic RC 1 is reportable as
  `INFRASTRUCTURE_ERROR` while STARTING and as `EXCEPTION` while STARTED.
- `nvflare/private/fed/server/server_engine.py:179-196,321-329`: `start_app_on_server` launches the server job
  process and records `engine.run_processes[job_id]` before `_start_run` sends START_JOB to clients.
- `nvflare/private/fed/server/server_engine.py:1068-1083`: `start_client_job` sends START_JOB requests with a
  20 second timeout.

### Call chain and reachability

Normal server scheduling path:
`JobRunner.run` -> scheduler returns a ready job -> `_deploy_job` -> `job_manager.set_status(DISPATCHED)` ->
`_start_run` -> `engine.start_app_on_server` -> `engine.start_client_job` -> `job_manager.set_status(RUNNING)`.

Failure-report path:
client worker exits -> `ClientExecutor._wait_child_process_finish` sends REPORT_JOB_FAILURE ->
`FederatedServer.process_job_failure` -> `JobRunner.fail_run`.

The precondition is reachable through normal operations: after `start_app_on_server` returns successfully,
`engine.run_processes[job_id]` exists and `_pending_client_outcomes[job_id]` has been set, but `_start_run` may still
be waiting for START_JOB replies from other clients. A fast-failing client can report the failure in that interval.

### Trigger scenario

1. A job is scheduled for two clients.
2. The server job process launch succeeds, creating `engine.run_processes[job_id]`.
3. `_start_run` creates `_pending_client_outcomes[job_id] = {"site-1", "site-2"}` and enters the START_JOB collection.
4. `site-1`'s client job process exits during startup and sends REPORT_JOB_FAILURE with an actionable code
   (`EXCEPTION` in the reproduction; `INFRASTRUCTURE_ERROR` is also reachable for STARTING generic RC 1).
5. `process_job_failure` accepts the report because the pending set exists, and calls `fail_run`.
6. `fail_run` records the failure code and pops `_pending_client_outcomes[job_id]`.
7. START collection resumes and `_start_run` executes
   `self._pending_client_outcomes[job_id].intersection_update(active_client_sites)`, raising `KeyError`.
8. `JobRunner.run` catches the exception and records `FINISHED:FAILED_TO_RUN` instead of allowing the recorded
   execution failure to complete through the normal `FINISHED:EXECUTION_EXCEPTION` path; the exception entry is left
   behind because the job never entered `running_jobs`.

### Safeguards checked

- `process_job_failure` has an idempotent guard for untracked/late reports, but in this window the report is tracked
  and intentionally accepted (`fed_server.py:938-951`).
- `fail_run` is guarded by `running_jobs` or `engine.run_processes`; the server process entry exists in this window.
- `_start_run` does not check whether `_pending_client_outcomes[job_id]` still exists before indexing it.
- The completion thread removes exception entries only for jobs in `running_jobs`; this job has not yet been inserted.
- The same failure report after `running_jobs` insertion finalizes as `FINISHED:EXECUTION_EXCEPTION`, confirming that
  the START-collection KeyError changes the outcome.

## Step 2: Developer-knowledge search

### Source comments / docs / tests

- `job_runner.py:837-840` states the developer intent directly:
  `fail_run establishes an authoritative terminal failure. Remaining client reports cannot change that status and must not hold terminal publication behind the normal outcome grace period`.
- `server_engine.py:223-232` similarly preserves an external authoritative failure recorded in
  `exception_run_processes` from being overwritten by the server job's secondary exit code.
- Tests in `tests/unit_test/private/fed/server/job_runner_test.py` cover pending client outcomes, server failure
  barrier release, late outcome behavior, and report processing, but no test was found for a client failure report
  during `_start_run` before `running_jobs` insertion.

### Local git history

Searched local history with terms covering `_pending_client_outcomes`, `client outcome`, `REPORT_JOB_FAILURE`,
`FAILED_TO_RUN`, `start_client_job`, `fail_run`, and `KeyError`.

Related commits:

- `46cfc5170976baf34cd961646bb8989a0b342d46` / PR #5072, "Wait for client terminal outcomes before finalizing jobs":
  introduced the pending-client outcome barrier. The body says failures are applied before the barrier is released.
  It does not report the START-collection pop-then-index KeyError.
- `9b5dddfd2d24cfd013c16ea3fabca5e4dd482f46` / PR #5097, "Harden Client API and Swarm abort cleanup":
  reinforces that generic job-process lifecycle reports authoritative process results before shutdown.
- `535373a0824f90ca6b758fd2dc781b9f2f9064b9` / PR #5221, "Finalize failed jobs with missing client outcomes":
  fixes a different guard-order issue after a server-process failure was already recorded and the server process
  stopped; it does not cover the `_start_run` START-reply narrowing window.
- `21253dddc479ec256d6ad518d03c346fe177f971` / PR #5117, "Clean up clients after server job failure":
  fixes client cleanup after abnormal server-process exit, not this START collection KeyError.

### Upstream issue / PR search

Read-only GitHub issue/PR search against `NVIDIA/NVFlare`:

- `_pending_client_outcomes KeyError`: 0 results.
- `start_client_job fail_run`: 0 results.
- `FAILED_TO_RUN REPORT_JOB_FAILURE`: 0 results.
- `pending client outcomes start job`: 3 related results: #5072, #5194, #5220.

Related but not the same mechanism:

- #5220 reports a failed server job remaining RUNNING while waiting for a disconnected client outcome. Same barrier
  subsystem, different site and outcome.
- #5194 reports active client process exit failures not being reported for generic RC 1. It supplies a reportable
  failure mechanism, but not the server-side START-collection KeyError.
- #5072 introduced the pending-client outcome protocol; it is not a bug report for this mechanism.

Known-status conclusion: no public issue/PR found that reports this exact mechanism at this site. Novelty should be
recorded as NEW.

## Phase 2 reproduction

Test written and executed:
`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-4_start_keyerror.py`

Command:
`timeout 5m python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-4_start_keyerror.py`

Output saved to:
`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-4/repro-output.txt`

Escalation level: Level 1/2 boundary. The harness uses the real `JobRunner.run`, `_start_run`, `fail_run`, and
`FederatedServer.process_job_failure`, and only stubs the deployment/network/process-launch boundaries to place an
ordinary authenticated client failure report at the START-collection timing window. The precondition it instantiates
is reachable through the real call sequence documented above: `start_app_on_server` records `run_processes`, then
`_start_run` sets `_pending_client_outcomes`, then a real client REPORT_JOB_FAILURE is accepted before all START replies
are collected.

Observed result:

- Failing window final status: `FINISHED:FAILED_TO_RUN`.
- Failing window trace contains:
  - `start_client_job(...) entered; pending={'job-failure_during_start': {'site-1', 'site-2'}}`
  - `process_job_failure(...) begin`
  - `process_job_failure end; pending={}; exception_entry={... '_process_return_code': 101}`
  - `set_status(job-failure_during_start, FINISHED:FAILED_TO_RUN)`
  - `Failed to run the Job (...): KeyError: 'job-failure_during_start'`
- Control (`failure_after_start`) final status: `FINISHED:EXECUTION_EXCEPTION`; its exception entry is removed.

This demonstrates both the direct KeyError and the wrong observed outcome at the real consumer:
`JobRunner.run`'s exception handler (`job_runner.py:713-720`) records `FAILED_TO_RUN` after the KeyError, whereas the
same authoritative failure after normal start is consumed by `_job_complete_process` and published as
`FINISHED:EXECUTION_EXCEPTION`.
