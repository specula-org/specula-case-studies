# MC-3 Investigation

## Step 1: Code Audit

Source head: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

The runner admits a scheduled job only if a freshly loaded copy is still `SUBMITTED` at `nvflare/private/fed/server/job_runner.py:676`. After that check, it calls `_deploy_job` at `job_runner.py:684`, then unconditionally publishes `DISPATCHED` at `job_runner.py:685`. It performs a second check for `DISPATCHED` at `job_runner.py:714` and, if the overwritten status is present, starts the run and publishes `RUNNING` at `job_runner.py:729`.

The admin abort command reads the job once at `nvflare/private/fed/server/job_cmds.py:1060-1063`. If that saved status is `SUBMITTED` or `DISPATCHED`, it writes `FINISHED:ABORTED` at `job_cmds.py:1064` and returns success with "Aborted the job ... before running it" at `job_cmds.py:1066-1069`.

The job manager status write is a plain metadata update at `nvflare/apis/impl/job_def_manager.py:459-481`; there is no compare-and-set, expected-state check, or terminal-state guard.

Reachable call chain:

- Normal scheduling: `JobRunner.run` -> scheduler returns a ready job -> `_check_job_status(... SUBMITTED ...)` -> `_deploy_job` -> `job_manager.set_status(... DISPATCHED ...)` -> `_check_job_status(... DISPATCHED ...)` -> `_start_run` -> `job_manager.set_status(... RUNNING ...)`.
- Normal admin operation: admin `abort_job` command -> `JobCommandModule.abort_job` -> `job_manager.get_job` -> `job_manager.set_status(... FINISHED_ABORTED ...)` -> success response.

Concrete trigger:

1. Job is `SUBMITTED`; scheduler checks it and enters deployment.
2. Deployment RPC blocks or is delayed.
3. Admin abort command reads `SUBMITTED`, writes `FINISHED:ABORTED`, and acknowledges the pre-run abort.
4. Deployment reply arrives successfully.
5. Runner writes `DISPATCHED` unconditionally, then sees `DISPATCHED` in its second check and starts the job.

Safeguards observed: there is a pre-deploy `SUBMITTED` check and a pre-start `DISPATCHED` check, but no re-check preserving terminal states before the `DISPATCHED` write. No downstream reconciliation was found in this path that restores `FINISHED:ABORTED` after the runner starts the job.

Counterexample alignment: `spec/output/MC_hunt_s3_abort_status-bfs.out` reports `AcceptedPreRunAbortPersists` violated. The relevant states show the scheduler in `deployWait` with `status = "ABORTED"` in State 19, then `status = "DISPATCHED"` in State 21 and `abortAck = TRUE` in State 22.

## Step 2: Developer Knowledge Search

Issue/PR search covered open/closed PRs and issues with `aborted job status publication`, `FINISHED:ABORTED DISPATCHED`, `abort_job DISPATCHED`, `JobRunner DISPATCHED abort`, `set_status DISPATCHED`, and `stale deployment abort`.

Relevant adjacent but not matching reports:

- <https://github.com/NVIDIA/NVFlare/pull/4613> and <https://github.com/NVIDIA/NVFlare/pull/4633> fix an aborted-status publication race for running jobs / heartbeat-driven abort and workspace publication. The patch changes `fed_server.py` and completion handling; it does not guard `JobRunner.run`'s deploy-time `DISPATCHED` write after a pre-run admin abort.
- <https://github.com/NVIDIA/NVFlare/pull/5216> fixes lifecycle event job-id accounting. It changes event payloads and scheduler event consumption; it does not change the unguarded `DISPATCHED` write at `job_runner.py:685`.
- <https://github.com/NVIDIA/NVFlare/pull/5191> is open and concerns admission exception cleanup, reservation cancellation, and retry bookkeeping. Its discussion covers resource cancellation expiry tradeoffs, not pre-run abort status persistence.
- <https://github.com/NVIDIA/NVFlare/pull/1613> introduced allowing `abort_job` in `SUBMITTED` and checking `SUBMITTED` before deploy / `DISPATCHED` before start, but it is an enhancement, not a report of this stale deploy write overwriting the accepted abort.

Local git history on the affected files shows adjacent lifecycle changes (`#5216`, `#5221`, `#5212`) but no commit that reports or fixes this exact mechanism.

No code comment or test near the cited code was found that documents the post-abort overwrite as intended or harmless. Existing tests cover that a submitted job is marked aborted by `abort_job`, but not concurrent deployment overwriting that terminal value.

## Step 3: Known Status / Precedent

Novelty: NEW. The required tracker and recent closed/merged PR search found adjacent lifecycle/status fixes, but no existing issue, PR, CVE, advisory, or known public report for this exact mechanism at this site: a successful deployment path writing `DISPATCHED` after an admin command has already acknowledged a pre-run `FINISHED:ABORTED` status.
