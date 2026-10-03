# CR-9 Investigation

## Step 1: Code Audit

Finding source: code review; no model-checking counterexample or invariant is attached.

Primary site:
- `nvflare/private/fed/client/client_app_runner.py:171-222`: `ClientAppRunner.notify_job_status` builds a `NOTIFY_JOB_STATUS` request, derives the CP FQCN from the child FQCN, then loops forever. If `retry_timeout` is absent it returns after one send. If `retry_timeout` is present, success (`ReturnCode.OK`) returns, but `duration > retry_timeout` only logs an error at lines 217-220. The sleep is only in the non-timeout branch at line 222, so after the timeout window the loop continues without either returning or sleeping.
- `nvflare/private/fed/client/client_app_runner.py:183-185`: the docstring says the loop retries until the notification is sent successfully "or the retry_timeout has been reached."
- `nvflare/private/fed/client/client_app_runner.py:65-77`: `start_run` uses this loop for the STARTED notification, with `notify_cp_retry_timeout` defaulting to 15 seconds.
- `nvflare/private/fed/client/client_app_runner.py:233-235`: `stop()` only calls `self.client_runner.abort()`; it does not set a flag checked by `notify_job_status`.

Call chain and normal reachability:
- The default local process launcher starts job processes through `ProcessJobLauncher.launch_job` (`nvflare/app_common/job_launcher/process_launcher.py:66-83`), which calls `spawn_process`.
- `spawn_process` starts job processes in a new session/process group (`nvflare/utils/process_utils.py:320-349`). A parent CP kill is therefore not an OS kill of the CJ.
- The CJ entry point is `nvflare/private/fed/app/client/worker_process.py:121-126`: it constructs `ClientAppRunner`, starts `monitor_parent_process`, then calls `client_app_runner.start_run(...)`.
- `monitor_parent_process` (`nvflare/private/fed/app/utils.py:45-50`) checks whether the captured parent PID still exists and calls `runner.stop()` once it disappears.
- A successful notification reaches `NotifyJobStatusProcessor.process` (`nvflare/private/fed/client/training_cmds.py:202-213`), then `ClientEngine.notify_job_status` (`nvflare/private/fed/client/client_engine.py:384-385`), then `JobExecutor.notify_job_status` (`nvflare/private/fed/client/client_executor.py:347-350`), which updates the CP's in-memory run-process status.

Trigger scenario:
1. The CP launches a CJ through the local process launcher.
2. The CJ enters `ClientAppRunner.start_run` and tries to send STARTED to the CP.
3. The CP exits or is killed during this bootstrap window, before the STARTED notification succeeds.
4. The CJ's parent monitor observes parent death and calls `ClientAppRunner.stop()`, so `client_runner.abort()` is invoked.
5. The active `notify_job_status` call continues anyway because it has no stop check and no timeout return. With the CP gone, CellNet replies `comm_error`; after `retry_timeout` the loop stops sleeping and keeps retrying.

Safeguards checked:
- The parent-death monitor fires, but `stop()` only aborts the runner and does not interrupt the notification loop.
- Heartbeat reconciliation is a CP mechanism (`nvflare/private/fed/client/communicator.py:581-649`); if the CP process is dead, it cannot send heartbeats or receive server abort-job reconciliation.
- The server-side heartbeat sync (`nvflare/private/fed/server/fed_server.py:1004-1017`) can only respond to a live CP heartbeat. It does not reach an orphaned CJ whose CP has died and whose restarted CP has no in-memory `run_processes` entry.
- Provisioned `stop_fl.sh` kills only the parent PID at `nvflare/lighter/templates/master_template.yml:684-698`, not the independently launched CJ process group.

## Step 2: Developer-Knowledge Search

Code comments and docs:
- The strongest local developer-intent evidence is the docstring at `client_app_runner.py:183-185`, which explicitly says `retry_timeout` is a cap.
- No adjacent TODO/FIXME/HACK comment says the current infinite retry is intended.
- `rg` across `docs`, `nvflare`, and `tests` found no test or documentation asserting that `notify_job_status` should retry forever after `retry_timeout`.

Git history:
- `0a0d3abd` / PR #2247, "Enhanced the client job status", introduced the CJ-to-CP status-report mechanism. The PR body says the parent should keep accurate client job status during the job run lifecycle; it does not report or justify infinite retry after parent death.
- `c8536f6b` added the current docstring and loop shape for `retry_timeout`, including the explicit "retry_timeout has been reached" wording.
- `72eb5462` added/cherry-picked monitor-parent-process behavior, and `17b8532a` supplied `ClientAppRunner.stop`; neither records this retry-loop behavior as intended.
- Local `git log` searches for `notify_job_status`, `retry_timeout`, `parent process`, `monitor_parent`, `worker_process`, and `client_app_runner` found no commit message reporting this exact defect.

Upstream issue/PR search:
- GitHub issue/PR search queries run against `NVIDIA/NVFlare`: `notify_job_status retry_timeout`, `"ClientAppRunner" "retry_timeout"`, `"notify_cp_retry_timeout"`, `"monitor_parent_process" "notify_job_status"`, `"parent process" "notify_job_status"`, `"ClientAppRunner" "parent" "retry"`, `"cannot notify status"`, and `"NOTIFY_JOB_STATUS" "parent"`.
- Exact retry/parent-death searches returned no issue or PR reporting this mechanism.
- Two broader hits were reviewed:
  - PR #2247, "Enhanced the client job status": introduces the status report mechanism; not a bug report for parent death or timeout retry.
  - PR #5112, "FLARE-3123/3125: harden CellNet job command trust boundaries": security hardening for command senders; not this liveness/retry defect.

## Step 3: Known-Status / Precedent

No upstream issue, PR, CVE/advisory, or local git-history entry found in this search reports the same mechanism at the same site. This supports `Novelty: NEW` for CR-9.
