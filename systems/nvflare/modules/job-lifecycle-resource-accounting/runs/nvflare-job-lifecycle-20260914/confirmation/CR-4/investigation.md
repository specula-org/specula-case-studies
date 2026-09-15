# CR-4 Investigation

Finding: CR-4, "Logical termination, outcome receipt and physical cleanup diverge"
Source: Code Review. The supplied finding says Scenario 4 model-checking was bounded and found no violation; there is no counterexample trace for this finding.
Pinned source head: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

## Step 1: Code Audit

Client start path:
- `nvflare/private/fed/client/scheduler_cmds.py:101-141` is the normal `START_JOB` request processor. It allocates resources with `resource_manager.allocate_resources(...)`, consumes them, then calls `engine.start_app(...)`. If an exception is raised after allocation, it frees `allocated_resources` in the exception handler.
- `nvflare/private/fed/client/client_engine.py:352-384` checks that the app is deployed, then delegates to `self.client_executor.start_app(...)`.
- `nvflare/private/fed/client/client_executor.py:199-342` registers a pending job handle under `run_processes[job_id]` before launching, attaches the real launcher handle after `launch_job`, preserves any pending abort, fires `AFTER_JOB_LAUNCH`, and starts `_wait_child_process_finish` as the cleanup waiter.

Client abort and cleanup path:
- `nvflare/private/fed/client/client_engine.py:392-408` asks the executor status. `STOPPED` is treated as already stopped only if the job is no longer registered in `run_processes`; if the job still has a registered handle, abort still reaches `client_executor.abort_app(...)`.
- `nvflare/private/fed/client/client_executor.py:495-558` sets `_abort_requested`, handles `STARTING`, `STARTED`, and `STOPPED`, and for `STARTED` or registered `STOPPED` waits through `_terminate_job` before returning.
- `nvflare/private/fed/client/client_executor.py:592-613` waits up to 10 seconds for the cleanup waiter to remove the job entry before terminating the handle.
- `nvflare/private/fed/client/client_executor.py:634-707` is the actual resource owner release point. It waits for the child handle, derives the return code, sends an acknowledged `REPORT_JOB_FAILURE` terminal outcome request to the root server, ignores/report-logs failed outcome reporting, then calls `resource_manager.free_resources(...)`, pops `run_processes[job_id]`, and fires `JOB_COMPLETED`.
- `nvflare/app_common/resource_managers/auto_clean_resource_manager.py:159-181` removes a reservation token at allocation time; expiry only frees still-reserved tokens, and `free_resources` is the allocated-resource return path.
- `nvflare/app_common/resource_managers/list_resource_manager.py:52-76` implements the selected ListResourceManager by removing resources from the deque on reserve and appending them back only on deallocate/free/cancel.

Server logical completion and outcome path:
- `nvflare/private/fed/server/server_engine.py:204-237` waits for the server job process, preserves authoritative exception return codes, pops `run_processes[job_id]`, and sets machine status stopped.
- `nvflare/private/fed/server/server_engine.py:360-418` aborts the server process by sending the child abort command, launching `_remove_run_processes`, waiting for the process table entry to disappear or for the grace to expire, then terminating the captured handle and popping the entry.
- `nvflare/private/fed/server/job_runner.py:119-128` maintains `_pending_client_outcomes` per job and per client.
- `nvflare/private/fed/server/job_runner.py:299-371` populates the pending outcome set before `start_client_job`, then filters it to active start replies according to the configured strict/non-strict semantics. Defaults: `strict_start_job_reply_check=False`; `client_outcome_wait_timeout=900.0`.
- `nvflare/private/fed/server/fed_server.py:907-959` authenticates terminal outcome reports, ignores untracked/duplicate job-client reports idempotently, applies failure or abort classification before resolving the reporting client, and then calls `resolve_client_outcome`.
- `nvflare/private/fed/server/fed_server.py:1006-1097` keeps normally completed server jobs alive to clients while outcome is pending, excludes already-failed server jobs from that protection, and resolves missing/dead client outcomes via heartbeat/dead-client reconciliation.
- `nvflare/private/fed/server/job_runner.py:449-555` publishes terminal job status only after the server process has gone away and either pending client outcomes are resolved, the job was administratively aborted, the server has an authoritative failure, or the configured outcome wait deadline expires. It then removes `running_jobs[job_id]` and pending outcome state.

Reachability:
- The relevant client paths are reachable through normal `CHECK_RESOURCE`, `START_JOB`, `ABORT`, client heartbeat cleanup, and child-process exit handling.
- The relevant server paths are reachable through normal job runner start/abort/completion, `REPORT_JOB_FAILURE`, and heartbeat/dead-client reconciliation.

Concrete trigger scenario to test:
1. Job 1 is admitted for site `site-1` using ListResourceManager with one resource unit.
2. Job 1 starts on the client, transferring the reservation to an active allocation.
3. Server logical completion/abort removes the scheduler membership before the client cleanup waiter physically frees the resource.
4. Job 2 is eligible and the scheduler tries to admit it while Job 1's client resource is still allocated.
5. Job 1's child exits, the client reports/attempts the terminal outcome, frees the resource, and Job 2 is tried again.

Safeguards encountered:
- ListResourceManager keeps allocated resources out of the free pool until `free_resources`.
- Client cleanup frees resources after `job_handle.wait()`, not after logical `STOPPED`.
- Registered `STOPPED` jobs can still be aborted because `ClientEngine.abort_app` checks `get_run_processes_keys`.
- Server outcome tracking is keyed by job and client; duplicate/late untracked terminal reports are acknowledged but ignored.
- JobRunner retains the outcome barrier for normal completion, releases it for authoritative server failures, and bounds the wait by `client_outcome_wait_timeout`.

## Step 2: Developer Knowledge Search

Local git history on the cited files found these relevant merged fixes:
- `46cfc5170976baf34cd961646bb8989a0b342d46` / PR #5072, "Wait for client terminal outcomes before finalizing jobs", merged 2026-08-12. The commit message says the old root cause was that server-side process exit was treated as sufficient evidence of distributed completion, and the repair added a pending-client set, acknowledged terminal reports, and a bounded 900 second default wait.
- `21253dddc` / PR #5117, "Clean up clients after server job failure", merged 2026-08-13. The PR says heartbeat reconciliation had treated every pending outcome job as active, which masked orphaned client jobs after abnormal server-process exit; the fix allows cleanup after known server failure while preserving the normal outcome barrier.
- `535373a0824f90ca6b758fd2dc781b9f2f9064b9` / PR #5221, "Finalize failed jobs with missing client outcomes", merged 2026-08-27. The commit says the completion loop checked the pending-client barrier before evaluating an already-recorded server failure, leaving a failed job `RUNNING` until outcome or heartbeat timeout; it now releases pending outcomes for authoritative server failures.
- `52c966d1ed2bce31ef5fd2c2e62beabebc6dd12c` / PR #5194, "Report active client process exit failures", merged 2026-08-27. The commit says active client-worker exit code 1 is promoted to a reportable failure only when the worker was `STARTED` and not parent-aborted, preserving non-reportable teardown/abort behavior.

Issue/PR tracker search:
- GitHub API searches for `REPORT_JOB_FAILURE client_outcome cleanup`, `client_outcome_wait_timeout`, `"terminal outcome" "resource"`, `"physical cleanup"`, and `"Client app already stopped" cleanup` found no report for a remaining current-head mechanism that releases client resources twice/early/never or corrupts another job's accounting. The `client_outcome_wait_timeout` search found PR #5072.
- Title searches found PR #5072, #5117, #5194, #5221, and open PR #5191.
- PR #5191, "Handle unexpected job admission failures", is still open as of the GitHub API check on 2026-09-14. It covers admission-time reservation cleanup, retry bookkeeping, missing resource results, and cancellation acknowledgements, not the completed/aborted-job outcome-vs-physical-cleanup mechanism tested here.
- PR #5191 discussion includes the requested comment that built-in managers inherit `AutoCleanResourceManager` expiry and that a missing cancellation acknowledgement leaks only a reservation, not a running allocation, for the default expiry window. That comment is relevant to admission-time cancellation but not an exact CR-4 duplicate.

Comments/docs/tests:
- `docs/user_guide/core_concepts/job.rst` documents the contract: resources may be reserved during scheduling, allocated when a job is dispatched to a client, consumed when the job starts, and freed when the job is finished/completed/aborted.
- Existing focused tests in the source tree cover terminal outcome reporting, outcome barriers, missing/dead client reconciliation, failed-job finalization, and registered stopped worker abort behavior.

## Step 3: Known Status / Precedent

Known overlapping fixes exist for earlier lifecycle gaps (#5072, #5117, #5194, #5221), and open PR #5191 covers admission-time reservation cleanup. I did not find an existing public issue/PR/CVE/advisory reporting the same remaining mechanism at current head: logical completion/outcome receipt diverging from client physical cleanup such that ListResourceManager double-frees, early-frees, omits free, or corrupts another job's accounting.

Novelty for the current-head mechanism: NEW, subject to Phase 2 reproduction.
