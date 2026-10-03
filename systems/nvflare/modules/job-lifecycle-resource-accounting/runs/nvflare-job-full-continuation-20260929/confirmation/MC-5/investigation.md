# MC-5 Investigation

## Finding

MC-5 is model-checking-sourced. The supplied TLC output
`spec/output/continuation-S3-F16_refresh/tlc.out` violates
`NoRefreshWriteOverwrite`. The relevant trace reaches
`MCRunnerRefreshRead`, then `MCAdminAbortWrite("j2")`, then
`MCRunnerRefreshWrite`; the final state records:
`ovw = { [ j |-> "j2", w |-> "RefreshWrite", from |-> "FINISHED:ABORTED", to |-> "SUBMITTED" ] }`.

## Step 1: Code Audit

Relevant sites inspected:

- `nvflare/app_common/job_schedulers/job_scheduler.py:287-310`: `DefaultJobScheduler.schedule_job` catches scheduling failures, then for each failed job calls `job_manager.refresh_meta(job, self._get_update_meta_keys(), fl_ctx)` at line 303. Blocked jobs use the same refresh at line 307 before `FINISHED:CAN_NOT_SCHEDULE`.
- `nvflare/apis/impl/job_def_manager.py:487-505`: `SimpleJobDefManager.refresh_meta` copies scheduler-maintained keys from the in-memory `Job` snapshot and calls `update_meta`.
- `nvflare/apis/impl/job_def_manager.py:483-485`: `update_meta` delegates to `store.update_meta(..., replace=False)`.
- `nvflare/app_common/storages/filesystem_storage.py:251-275`: partial metadata update checks object existence, then for `replace=False` reads the whole metadata dict with `get_meta`, updates it in memory, and writes the whole metadata file. There is no lock covering the read/write interval.
- `nvflare/private/fed/server/job_cmds.py:1051-1066`: `abort_job` reads the job status. If it is `SUBMITTED` or `DISPATCHED`, it writes `FINISHED:ABORTED` via `job_manager.set_status(...)`, appends "Aborted the job ... before running it.", and returns without stopping a process.
- `nvflare/private/fed/server/job_runner.py:650-711`: the runner scans scheduling candidates, calls `schedule_job`, checks the selected job is still `SUBMITTED`, deploys it, writes `DISPATCHED`, starts it, inserts it into `running_jobs`, and writes `RUNNING`.

Call chain:

1. Normal server admission loop calls `JobRunner.run` at `job_runner.py:641-658`.
2. The runner obtains `SUBMITTED` candidates from `SimpleJobDefManager.get_jobs_to_schedule` (`job_def_manager.py:512-515`).
3. `DefaultJobScheduler.schedule_job` performs resource checks. If a queued job lacks resources, it records scheduling history through `refresh_meta` (`job_scheduler.py:303`).
4. `refresh_meta` performs a partial metadata update using filesystem storage's unlocked whole-dict read/modify/write.
5. Concurrent admin `abort_job` is a supported command path and can write `FINISHED:ABORTED` for the same `SUBMITTED` job.
6. If the scheduler read old metadata before the abort write and writes after it, the stale full metadata rewrites `status: SUBMITTED`.
7. On the next pass, `JobRunner.run` sees the job as a valid `SUBMITTED` candidate and can start it.

Reachability:

The precondition is reachable through supported operations: submit a job that cannot currently reserve client resources, let the scheduler perform a no-resource retry, and abort the still-queued job while the scheduler persists its retry metadata. The timing window is the filesystem storage partial update between `get_meta` and `_write`. No caller-side compare-and-set, lock, status re-check, or downstream reconciliation was found for this queued-job path.

Safeguards encountered:

- `JobRunner.run` re-checks `SUBMITTED` before deploy (`job_runner.py:661`), but after the stale refresh write the persisted status is again `SUBMITTED`, so the guard admits the job.
- `_ScheduleJobFilter` tags non-`SUBMITTED` jobs during scans (`job_def_manager.py:104-120`), but the abort in this interleaving lands after the scheduler already scanned the job as `SUBMITTED`; the refresh write restores `SUBMITTED` before the next scan.
- Running-job abort reconciliation (`job_runner.stop_run` / `mark_run_aborted`) does not apply because `abort_job` takes the `SUBMITTED` branch and only writes metadata.

## Step 2: Developer Knowledge Search

Local pinned git history and merged PR commit messages were searched with:

- `git log --grep='refresh_meta|update_meta|meta file|job status|abort.*status|aborted job status|race|job schedule' --regexp-ignore-case -- ...`
- `git log --grep='refresh.*abort|abort.*refresh|read.modify|read-modify|FINISHED_ABORTED.*SUBMITTED|SUBMITTED.*FINISHED_ABORTED|schedule.*abort' --regexp-ignore-case HEAD`
- `git blame` on `job_scheduler.py:295-310` and `filesystem_storage.py:251-275`
- `rg` in source, docs, and tests for `refresh_meta`, `update_meta`, `FINISHED_ABORTED`, `abort_job`, and status-race terms.

Developer evidence found:

- `38fa2c75` / PR `#2186` says "Fix meta file processing in storage and improve schedule job retrieval" and introduced the current mark-file scheduling scan behavior. It does not report or fix scheduler refresh restoring a stale job status over an abort.
- `6d193a24` / PR `#4633` says "Fix aborted job status publication race" and focuses on running-job status publication by server/job-runner handling. It does not mention the queued-job scheduler `refresh_meta` read/modify/write site.
- `e3568925` / PR `#4604` says "Fix aborted job download race" by delaying persisted terminal status for running aborted jobs until workspace archival. It does not cover the `SUBMITTED` abort branch at `job_cmds.py:1061-1066` or scheduler metadata refresh.
- Existing `job_cmds_test.py:1960-1976` asserts a `SUBMITTED` abort writes `FINISHED_ABORTED` and does not call `stop_run`. It does not cover a concurrent scheduler refresh or a later runner launch.
- Docs state `abort_job` "Aborts the job ... if it is running or dispatched" (`docs/user_guide/admin_guide/deployment/operation.rst:42`), while the implementation also handles `SUBMITTED` by writing `FINISHED:ABORTED`.
- Docs state a submitted job has one chance to execute and, once executed, "won't be scheduled again" (`docs/user_guide/core_concepts/job.rst:342-343`). The client tools treat `FINISHED:*` as terminal (`nvflare/tool/job/job_cli.py:1936`).

Continuation constraint note:

External issue/PR tracker discussions and newer upstream commits were not consulted because the continuation instructions prohibit inspecting newer commits or upstream issue/PR discussions. The known-status search therefore used the local pinned git history/merged PR metadata available at the source revision.

## Step 3: Known Status / Precedent

No local merged PR, commit message, test, or documentation entry was found that reports the exact mechanism at the same site: scheduler `refresh_meta` of a resource-blocked queued job using filesystem storage's unlocked full-metadata read/modify/write to restore `SUBMITTED` over `FINISHED:ABORTED`, followed by later launch.

Nearby precedents exist for other status races, especially running-job abort publication and scheduler event accounting, but they are different mechanisms and sites. Known-status for this mechanism is therefore recorded as `NEW`.
