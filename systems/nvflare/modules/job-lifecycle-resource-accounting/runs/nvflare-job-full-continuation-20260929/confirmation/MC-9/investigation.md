# MC-9 Investigation

## Phase 1: Code Audit

Finding: running-job abort can return success while the final published status is `FINISHED:COMPLETED`.

Primary source sites:

- `nvflare/private/fed/server/job_cmds.py:1051-1078`: `JobCommandModule.abort_job` is the public admin command path. For a non-terminal running job it calls `job_runner.stop_run(job_id, fl_ctx)`, then reports success when that returns an empty string.
- `nvflare/private/fed/server/job_runner.py:798-800`: `stop_run` first calls `_stop_run`, then calls `mark_run_aborted`.
- `nvflare/private/fed/server/job_runner.py:374-393`: `_stop_run` sends aborts to active clients and calls `engine.abort_app_on_server(job_id)`. It does not mark `job.run_aborted`.
- `nvflare/private/fed/server/job_runner.py:802-811`: `mark_run_aborted` marks the tracked job by setting `job.run_aborted = True`; if the job is still tracked it returns success.
- `nvflare/private/fed/server/job_runner.py:441-541`: `_job_complete_process` finalizes jobs once `job_id not in engine.run_processes`. If `_finished_job_states` has no latch and `job.run_aborted` is still false, it calls `_get_finished_job_status`.
- `nvflare/private/fed/server/job_runner.py:543-585`: `_classify_finished_job_status(None)` returns `RunStatus.FINISHED_COMPLETED`; `_get_finished_job_status` uses that when there is no exception process.
- `nvflare/private/fed/server/job_runner.py:524`: the completion loop publishes the selected terminal status through `job_manager.set_status`.
- `nvflare/private/fed/server/server_engine.py:203-234`: `wait_for_complete` removes the entry from `engine.run_processes` after the server app exits; a clean return code does not populate `exception_run_processes`.
- `nvflare/private/fed/server/server_engine.py:354-383`: `abort_app_on_server` sends `ABORT` and starts cleanup off-thread, then returns `""`.

Reachability:

The reachable precondition is a normally running job. `JobRunner.run` starts the server/client app path and then records `running_jobs[job_id] = ready_job` and `RunStatus.RUNNING` at `nvflare/private/fed/server/job_runner.py:703-711`. The admin entry point for the stop is `JobCommandModule.abort_job` at `job_cmds.py:1051`.

Concrete trigger:

1. A job is in normal `RUNNING` state with a run process in `engine.run_processes` and `job.run_aborted == False`.
2. Admin calls `abort_job`; `stop_run` enters `_stop_run`.
3. `_stop_run` causes the server app to exit cleanly and `wait_for_complete`/cleanup removes the run process before `mark_run_aborted` executes.
4. `_job_complete_process` observes the absent run process while `job.run_aborted` is still false and no exception process exists.
5. Completion latches/publishes `FINISHED:COMPLETED`.
6. Admin resumes, `mark_run_aborted` still finds the job in `running_jobs`, sets `run_aborted=True`, and `abort_job` reports success.

Counterexample evidence:

The MC counterexample in `spec/output/continuation-H4-probe_stop_success/tlc.out` violates `NoStoppedSuccess`.

- State 23: `MCRunnerSetRunning` has `status = "RUNNING"`, `runningJobs = {"j1"}`, `rp` present, `runAborted = FALSE`.
- State 25: `MCAdminStopRun("j1")` sends `ABORT`/`SJABORT`, sets admin pc to `MarkAborted`, and leaves `runAborted = FALSE`.
- State 28: `MCSpWaitForComplete("j1")` has `rp = None`, `exc = None`, `runningJobs = {"j1"}`, `runAborted = FALSE`.
- State 33: `MCCmpFinalizeBegin("j1")` latches `FINISHED:COMPLETED`.
- State 34: `MCCmpPublish` sets `status = "FINISHED:COMPLETED"` and `firstTerm = "FINISHED:COMPLETED"`.
- State 35: `MCAdminMarkAborted("j1")` sets `runAborted = TRUE` and `ackStop = TRUE` while the published status remains `FINISHED:COMPLETED`.

Safeguards checked:

- Completion removes `running_jobs` only after `job_manager.set_status` returns (`job_runner.py:531-535`), so there is a real window where `mark_run_aborted` can still succeed after the wrong status has been selected/published.
- `mark_run_aborted` only mutates the tracked in-memory job and returns `""`; it does not republish a terminal status.
- No downstream correction path was found after completion removes the job from `running_jobs`.

## Phase 1: Developer Knowledge / Known Status

Pinned git history contains related upstream PR-linked commits:

- `e3568925da9a6128ada6515f8fd7f9f0bf1c6bbf` / PR `#4604`, "Fix aborted job download race": the stated intent is to delay persisted terminal status for aborted jobs until the completion path saves workspace artifacts. The message says "`stop_run()` still signals abort immediately and sets `job.run_aborted` immediately."
- `f2b0039e07cbcc86ab0d4e60c6711e6f4d1ee590` / PR `#4613`, "Fix aborted job status publication race": routes heartbeat-driven aborted jobs through `JobRunner` and centralizes final completion sequence.
- `6d193a24d5d5637adc28c1f43d15be831342aec2` / PR `#4633`, "Fix aborted job status publication race": says aborted job status publication should be deterministic and should not race with job completion/status updates.

Existing tests:

- `tests/unit_test/private/fed/server/job_runner_test.py:782-800` asserts `stop_run` sets `job.run_aborted` and does not publish terminal status before completion, but it mocks `_stop_run`, so it does not cover completion interleaving while `_stop_run` is waiting on abort/cleanup.
- `tests/unit_test/private/fed/server/fed_server_test.py:552-568` checks `_set_job_aborted` routes through `mark_run_aborted` without direct status publication.
- Existing completion tests cover workspace ordering and status publication, but not the stop-before-marker race.

Novelty:

Local pinned git history and PR-linked commit messages show a known aborted-job status publication race area, and the supplied finding explicitly identifies this as a recheck of historical `MC-E`. The current source at `53ba7ee567468ea7971dad4faccef13c6cb35dc2` still reproduces this narrower stop-before-marker mechanism, so fix status is unfixed.

## Phase 2: Reproduction

Test file:

`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-9_stop_before_marker.py`

Escalation ladder:

- Level 0: A full black-box cluster reproduction was not used in this per-finding worker; the public admin path was identified but deterministic process-exit timing needs a running deployment and precise race timing.
- Level 1: Timing assistance alone was insufficient without a live deployment, because the test environment does not naturally launch a full server app process for this isolated job-runner path.
- Level 2: State injection was used only for the reachable `RUNNING` precondition matching counterexample State 23/24 and the normal `JobRunner.run` post-start state (`job_runner.py:703-711`). The trigger itself uses the real `JobCommandModule.abort_job` admin handler and real `JobRunner._job_complete_process`.
- Level 3: Not used.

Command executed:

```bash
timeout 60s python /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-9_stop_before_marker.py
```

Output:

```text
MC-9 reproduction: stop-before-marker interleaving
escalation_level=2 (state injection of CE State 23/24 RUNNING precondition; real admin abort path)
admissible_precondition=counterexample State 23/24 has status RUNNING, runningJobs={j1}, rp present, runAborted=FALSE
real_entrypoint=nvflare/private/fed/server/job_cmds.py:1051 JobCommandModule.abort_job
completion_path=nvflare/private/fed/server/job_runner.py:441 _job_complete_process
admin_strings=['Abort signal has been sent to the server app.']
admin_errors=[]
admin_success=True
published_statuses=['FINISHED:COMPLETED']
final_published_status=FINISHED:COMPLETED
job_run_aborted_after_admin=True
running_jobs_after_completion=[]
expected_if_abort_wins=FINISHED:ABORTED or abort reports job not running
BUG_TRIGGERED=True
```

Reproduction interpretation:

The real admin caller reports success while the real completion path publishes `FINISHED:COMPLETED`. The injected precondition is the reachable running-job state from the counterexample and from `JobRunner.run`. The wrong status remains after completion removes the job from `running_jobs`; `mark_run_aborted` only flips the in-memory job flag and does not correct the already published terminal status.
