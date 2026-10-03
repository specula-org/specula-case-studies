# CR-29 Investigation

## Finding

CR-29 is code-review sourced. The candidate says `DefaultJobScheduler.schedule_job()` can write
`FINISHED:CAN_NOT_SCHEDULE` after an admin `abort_job` has already acknowledged and written
`FINISHED:ABORTED` for the same queued job.

## Step 1: Code Audit

Relevant sites:

- `nvflare/app_common/job_schedulers/job_scheduler.py:300-308`: after `_do_schedule_job()` returns,
  failed jobs have scheduling metadata refreshed; blocked jobs have scheduling metadata refreshed and
  then unconditionally call `job_manager.set_status(job.job_id, RunStatus.FINISHED_CANT_SCHEDULE, fl_ctx)`.
- `nvflare/app_common/job_schedulers/job_scheduler.py:347-354`: a candidate whose
  `schedule_count >= max_schedule_count` is appended to `blocked_jobs`; `_update_schedule_history()`
  increments the in-memory count before the post-processing refresh.
- `nvflare/private/fed/server/job_cmds.py:1051-1066`: the public admin `abort_job` command reads the
  current job status; if it is `SUBMITTED` or `DISPATCHED`, it writes `FINISHED:ABORTED` and replies
  "Aborted the job ... before running it."
- `nvflare/apis/impl/job_def_manager.py:459-481`: `SimpleJobDefManager.set_status()` is an unconditional
  metadata merge; there is no compare-and-swap or terminal-status guard.
- `nvflare/private/fed/server/job_runner.py:650-658`: normal scheduler entry path obtains submitted
  candidates and calls `scheduler.schedule_job()`.

Reachability:

- The scheduler path is reachable during ordinary job admission. A job with unsatisfied scheduling
  requirements can remain `SUBMITTED` while its `schedule_count` advances. On the next pass after the
  configured `max_schedule_count`, it becomes a blocked job and reaches the unconditional
  `FINISHED:CAN_NOT_SCHEDULE` write.
- The abort path is the normal admin command handler. For a `SUBMITTED` job, it writes
  `FINISHED:ABORTED` and returns success without calling `job_runner.stop_run()`.
- There is no status re-read between the blocked-job metadata refresh and the scheduler's final
  `FINISHED:CAN_NOT_SCHEDULE` write. Therefore an abort that commits in that window is overwritten.

Concrete trigger scenario:

1. A job is submitted with `min_clients=2` while only one client is online. The first scheduler pass
   leaves it `SUBMITTED` and records one failed scheduling attempt.
2. On the next pass, `schedule_count >= max_schedule_count`, so the scheduler puts the job in
   `blocked_jobs`.
3. After `refresh_meta()` for that blocked job but before `set_status(FINISHED_CANT_SCHEDULE)`, an admin
   invokes `abort_job <job_id>`.
4. The admin command reads `SUBMITTED`, writes `FINISHED:ABORTED`, and reports success.
5. The scheduler resumes and writes `FINISHED:CAN_NOT_SCHEDULE` over the acknowledged abort.

Safeguards checked:

- `JobRunner` re-checks job status before deploy/start for ready jobs, but this blocked-job path returns
  no ready job and has no equivalent guard.
- `SimpleJobDefManager.set_status()` and `FilesystemStorage.update_meta(replace=False)` do not enforce
  terminal monotonicity.
- Later `get_jobs_to_schedule()` scans only `SUBMITTED` jobs, so the final terminal value remains
  stored and visible. No downstream sync/resend/loopback was found that restores `FINISHED:ABORTED`.

## Step 2: Developer Knowledge Search

Comments/docs/tests:

- `docs/user_guide/core_concepts/job.rst:400-403` documents `max_schedule_count` as eventually giving
  up on a job by setting a cannot-schedule status. The doc spells it `FINISHED:CANT_SCHEDULE`, while the
  enum value is `FINISHED:CAN_NOT_SCHEDULE`.
- `docs/system_architecture/system_architecture.rst:331-342` describes `SUBMITTED`, `DISPATCHED`,
  `RUNNING`, `FINISHED_COMPLETED`, and `FINISHED_ABORTED`; `FINISHED_ABORTED` means a job aborted by
  admin request or failure classified as abort.
- `tests/unit_test/app_common/job_schedulers/job_scheduler_test.py:707-720` asserts that exceeding
  `max_schedule_count` causes `FINISHED_CANT_SCHEDULE`.
- `tests/unit_test/private/fed/server/job_cmds_test.py:1960-1976` asserts that aborting a submitted job
  calls `set_status()` and reports "Aborted the job ... before running it."
- No test was found that covers the overlap between those two paths.

Local commit/blame evidence:

- `git blame -L 300,308 -- nvflare/app_common/job_schedulers/job_scheduler.py` attributes the blocked-job
  refresh and status write to commit `80435afde` from 2022.
- `git blame -L 1058,1063 -- nvflare/private/fed/server/job_cmds.py` shows the submitted/dispatched abort
  check at line 1061 was touched by `3a20796da` in 2026, while the status write at line 1062 dates to
  `195110c24`.
- `git show e1206061` ("Fix concurrent job lifecycle accounting (#5216)") fixes lifecycle event job-id
  accounting for `scheduled_jobs`; it does not add a blocked-job status guard or mention this abort versus
  cannot-schedule overwrite.

Prior handoff evidence:

- The interrupted run's conversation exports mention an RS-3 hypothesis/evidence with the same shape, but
  the handoff README says the original run stopped before Phase 4 confirmation and that historical
  conclusions are evidence to audit, not trusted verification results. This is not treated as an already
  published issue/PR/CVE/advisory or completed prior Specula dataset entry.

## Step 3: Known Status / Precedent

Searches performed in the pinned checkout:

- `git log HEAD --oneline --grep='CAN_NOT_SCHEDULE|CANT_SCHEDULE|FINISHED:CAN_NOT_SCHEDULE|FINISHED:CANT_SCHEDULE|abort.*schedule|schedule.*abort|terminal status|lifecycle accounting|aborted job' --regexp-ignore-case --extended-regexp`
- `git log HEAD --oneline --all-match --grep='CAN_NOT_SCHEDULE' --grep='ABORT' -- nvflare/app_common/job_schedulers/job_scheduler.py nvflare/private/fed/server/job_cmds.py`
- `git log HEAD --oneline --grep='schedule' --grep='abort' --all-match -- nvflare/app_common/job_schedulers/job_scheduler.py nvflare/private/fed/server/job_cmds.py`
- Repository text search for `CAN_NOT_SCHEDULE`, `CANT_SCHEDULE`, `abort.*schedule`, `terminal status`,
  and `FINISHED:ABORTED`.
- Exact local history searches:
  `git log HEAD -S'FINISHED_CANT_SCHEDULE' -- nvflare/app_common/job_schedulers/job_scheduler.py
  nvflare/apis/job_def.py nvflare/apis/impl/job_def_manager.py`,
  `git log HEAD -S'FINISHED_ABORTED' -- nvflare/private/fed/server/job_cmds.py
  nvflare/apis/impl/job_def_manager.py`, and
  `git log HEAD -G'CAN_NOT_SCHEDULE|CANT_SCHEDULE|FINISHED_ABORTED|abort_job' -- ...`.
  These found the original scheduler/status-management commits (`80435afd`, `195110c2`, `b1b9e108`,
  `ba4d4b71`, `e5e8c15a`, `55ce1e65`) rather than a report or fix for this overlap.

Result:

- No local issue reference, commit message, test, or documentation entry was found that reports this exact
  mechanism at this exact scheduler/abort site. The explicit continuation instructions prohibit browsing
  newer upstream issue/PR discussions, so the known-status search was limited to the pinned source history
  and local handoff artifacts.

Phase-1 pre-filter:

- The finding is code-review sourced, but no already-reported exact defect was found in allowed sources.
  Proceeded to Phase 2 reproduction.
