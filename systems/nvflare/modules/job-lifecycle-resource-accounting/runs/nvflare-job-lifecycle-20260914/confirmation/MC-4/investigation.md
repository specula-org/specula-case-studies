# MC-4 Investigation

## Code Audit

Source revision: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

The model-checking counterexample is real MC output. `spec/output/MC_hunt_s3_terminal_status-bfs.out` reports `Invariant NoTerminalResurrection is violated`; state 60 has `status |-> "COMPLETED"` and `terminalPublished |-> TRUE`, while state 61 has `status |-> "RUNNING"` and `terminalPublished |-> TRUE`.

Relevant implementation path:

- `nvflare/private/fed/server/job_runner.py:720-729`: after deploy and start, `JobRunner.run()` calls `_start_run(...)`, inserts `self.running_jobs[job_id] = ready_job` under `self.lock`, releases that lock, and then calls `job_manager.set_status(..., RunStatus.RUNNING, ...)`.
- `nvflare/private/fed/server/job_runner.py:449-536`: `_job_complete_process()` scans `self.running_jobs`; after the server process disappears and client outcomes are no longer pending, it computes a terminal status and calls `job_manager.set_status(job.job_id, status, completion_ctx)`.
- `nvflare/private/fed/server/job_runner.py:531-538`: after publishing the terminal status, the completion loop deletes `running_jobs` bookkeeping and fires terminal lifecycle events. It does not re-publish status afterward.
- `nvflare/apis/impl/job_def_manager.py:459-483`: `JobDefManager.set_status()` writes the requested status with `store.update_meta(..., replace=False)`. It has no guard that rejects `RUNNING` when the stored status is already terminal.

Reachability:

- The path is reachable through normal server operation: `JobRunner.run()` is the job runner loop, `_start_run()` uses the configured engine start path, and `_job_complete_process()` is started by `run()` before scheduling.
- The trigger requires a timing overlap: the startup thread has returned from `_start_run()` and registered `running_jobs`, but its `RUNNING` metadata write is delayed; meanwhile the completion thread observes the registered job after process exit and client outcome resolution and publishes `FINISHED:*`.
- The code has no post-terminal compare-and-set, no terminal-status guard in `set_status`, and no second terminal publication after the completion bookkeeping is removed.

Observed consumer:

- `nvflare/fuel/flare_api/flare_api.py:1674-1681`: `Session.monitor_job_and_return_job_meta()` reads `job_meta["status"]`; it returns `JOB_FINISHED` only for terminal statuses, otherwise it keeps polling until timeout.
- Therefore a resurrected `RUNNING` after terminal publication is externally visible as a public API monitor timeout or indefinite wait.

## Developer Knowledge Search

Issue/PR search covered upstream open and closed issues/PRs plus local git history after fetching remote refs:

- Required reference `https://github.com/NVIDIA/NVFlare/pull/5191` is open and concerns admission-exception cleanup, reservation cancellation, and retry bookkeeping. Its discussion explicitly covers reservation-expiry behavior and cancellation acknowledgment tradeoffs. It does not report terminal status being overwritten by a delayed startup `RUNNING` write at `JobRunner.run()` / `JobDefManager.set_status()`.
- `https://github.com/NVIDIA/NVFlare/issues/5215` and merged `https://github.com/NVIDIA/NVFlare/pull/5216` report/fix lifecycle event identity races caused by sticky `CURRENT_JOB_ID`. They affect scheduler accounting, workspace archival identity, and edge cleanup. They do not add a terminal-status guard or make the `RUNNING` status write atomic with `running_jobs` registration.
- Merged `https://github.com/NVIDIA/NVFlare/pull/5221` reports/fixes failed jobs remaining `RUNNING` while waiting for missing client outcomes. It changes completion barrier behavior and `fail_run` handling, but the current pinned code still writes `RUNNING` after `running_jobs` registration without checking whether terminal status was already published.
- Targeted tracker searches for `JobRunner RUNNING FINISHED set_status terminal`, `terminal status RUNNING job`, `running after finished job status`, and `resurrect RUNNING FINISHED job` returned no issue or PR reporting this exact mechanism.
- Local git history searches over `job_runner.py` and `job_def_manager.py` for `RUNNING`, `FINISHED`, `terminal`, `set_status`, and `running_jobs` found adjacent fixes (#5072, #5091, #5097, #5216, #5221), but no commit that reports or fixes the delayed startup `RUNNING` overwrite of an already-published terminal status.

## Known-Status / Precedent

Known-status evidence does not identify an already reported exact defect. The adjacent upstream records are different mechanisms at neighboring lifecycle sites. Novelty should be recorded as `NEW` for MC-4 based on the performed issue/PR and git-history searches.

## Reproduction Evidence

Executable repro:

`/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/repro/test_bugMC-4_terminal_resurrection.py`

Captured output:

`/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/MC-4/repro-output.txt`
