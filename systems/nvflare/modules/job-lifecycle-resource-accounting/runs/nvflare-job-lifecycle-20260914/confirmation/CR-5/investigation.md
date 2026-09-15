# CR-5 Investigation

## Code Audit

- Source revision: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`, with local lifecycle probe instrumentation present in the provided worktree.
- Scheduler admission path:
  - `nvflare/app_common/job_schedulers/job_scheduler.py:299-304` catches exceptions around the complete `_do_schedule_job()` pass and returns `(None, None)`.
  - `nvflare/app_common/job_schedulers/job_scheduler.py:307-320` separately catches job-store failures while persisting failed/blocked scheduling metadata.
  - `nvflare/app_common/job_schedulers/job_scheduler.py:268-278` blocks new admissions when `len(self.scheduled_jobs) >= self.max_jobs`.
  - `nvflare/app_common/job_schedulers/job_scheduler.py:280-292` adds/removes job IDs on lifecycle events; completion/abort removal only happens if the corresponding event is delivered.
- Runner startup path:
  - `nvflare/private/fed/server/job_runner.py:720-729` starts a job, then registers it in `running_jobs`, then writes `RUNNING`.
  - `_start_run()` fires `JOB_STARTED` at `nvflare/private/fed/server/job_runner.py:370-371`, before the later `RUNNING` status write.
  - If any startup step in the surrounding try fails, `nvflare/private/fed/server/job_runner.py:732-751` removes runner-local maps, calls `_stop_run()`, writes `FAILED_TO_RUN`, updates deploy metadata, and fires `JOB_ABORTED`.
  - The failure-handler body has no nested guard. If `job_manager.set_status(... FAILED_TO_RUN ...)` at `nvflare/private/fed/server/job_runner.py:742` raises, the exception escapes the `JobRunner.run()` scheduling loop before `JOB_ABORTED` at line 751.
- Completion path:
  - `nvflare/private/fed/server/job_runner.py:535-543` catches terminal `job_manager.set_status()` failures and continues the completion loop, preserving retry.
  - Workspace save/cleanup failures are latched and retried/grace-bounded at `nvflare/private/fed/server/job_runner.py:505-533`.
  - This path is better contained than the startup failure handler.
- Status-store reachability:
  - `nvflare/apis/impl/job_def_manager.py:459-481` delegates status publication to the configured job store (`store.get_meta`, `store.update_meta`) without catching storage-layer exceptions. A per-job object/store failure can therefore raise from `set_status()`.
- Service caller:
  - `nvflare/private/fed/app/deployer/server_deployer.py:136-145` starts `job_runner.run(fl_ctx)` on a plain thread through `_start_job_runner()` with no catch/restart wrapper around `run()`.

## Reachable Trigger Scenario

1. A job is admitted and deployment succeeds.
2. `_start_run()` starts the server/client path and fires `JOB_STARTED`.
3. The later `RUNNING` status write fails due to a per-job job-store/storage exception.
4. `JobRunner.run()` enters its startup exception handler.
5. The same per-job status-store failure occurs while publishing `FAILED_TO_RUN`.
6. The handler exits before `JOB_ABORTED`, leaving `DefaultJobScheduler.scheduled_jobs` with the already-started job ID.
7. With `max_jobs=1`, a later eligible job is rejected at the scheduler's max-jobs gate.

## Developer Knowledge / Known Status Search

- GitHub PR #5191 (`https://github.com/NVIDIA/NVFlare/pull/5191`) is open as of 2026-09-14. It reports scheduler admission exceptions after resource reservation, retry bookkeeping, later-candidate scanning, cancellation acknowledgement behavior, and related resource cleanup. It does not report the reproduced `JobRunner.run()` startup-failure handler escape after `JOB_STARTED`.
- GitHub issue #5215 and PR #5216 (`https://github.com/NVIDIA/NVFlare/issues/5215`, `https://github.com/NVIDIA/NVFlare/pull/5216`) are closed/fixed. They report stale `scheduled_jobs` caused by sticky `CURRENT_JOB_ID` lifecycle event misattribution during concurrent start/completion, not a status-store exception inside the startup failure handler.
- GitHub issue #5220 and PR #5221 (`https://github.com/NVIDIA/NVFlare/issues/5220`, `https://github.com/NVIDIA/NVFlare/pull/5221`) are closed/fixed. They report delayed terminal publication for failed server jobs with pending client outcomes, not startup cleanup escaping before `JOB_ABORTED`.
- GitHub PRs #5072, #5091, #5117, #5143, and #5149 cover adjacent completion/outcome, workspace archival retry, client cleanup, and scheduler resource-admission handling.
- Search queries run against GitHub issues/PRs: `JobRunner FAILED_TO_RUN running_jobs completion`, `"FAILED_TO_RUN" "running_jobs"`, `"_job_complete_process" "set_status"`, `"Failed to publish finished status"`, `"JOB_ABORTED" "FAILED_TO_RUN"`, `"DefaultJobScheduler" "admission"`.
- Local git history searched for `job admission`, `admission`, `FAILED_TO_RUN`, `completion`, `running_jobs`, and `schedule`.
- Known-status conclusion for the reproduced mechanism: no existing issue/PR found for startup-failure `FAILED_TO_RUN` status publication raising after `JOB_STARTED` and leaving scheduler accounting stale. Adjacent bugs are known, but this exact mechanism/site is NEW.
