# MC-10 Investigation

## Step 1: Code Audit

### Cited sites

- `nvflare/private/fed/server/fed_server.py:932-956`: `process_job_failure` authenticates the client token, resolves the token to a registered client, checks `job_runner.is_client_outcome_pending(job_id, client_name)`, and then calls `job_runner.fail_run(...)` for `CONFIG_ERROR`, `EXCEPTION`, `INFRASTRUCTURE_ERROR`, and `ABORTED` reports. It resolves the client outcome only after `fail_run` or `stop_run`.
- `nvflare/private/fed/server/job_runner.py:441-541`: `_job_complete_process` handles jobs still in `running_jobs` after the SJ has disappeared from `engine.run_processes`. It may clear an unresolved pending-client set on outcome deadline, then creates and stores `_FinishedJobState(status=...)` before workspace archival and status publication. The latched `finished_state.status` is reused at publication.
- `nvflare/private/fed/server/job_runner.py:574-585`: `_get_finished_job_status` reads `engine.exception_run_processes.get(job.job_id)` and classifies `None` as `FINISHED_COMPLETED`.
- `nvflare/private/fed/server/job_runner.py:813-852`: `fail_run` treats a job as active if it is still in `running_jobs` or `engine.run_processes`; when active, it records `PROCESS_RETURN_CODE` in `engine.exception_run_processes`, drops pending client outcomes and deadlines, and calls `_stop_run`. The in-code comment states that `fail_run` establishes an authoritative terminal failure.
- `nvflare/private/fed/client/client_executor.py:647-674`: the client parent reports terminal child-process failures through `REPORT_JOB_FAILURE`.
- `nvflare/apis/impl/job_def_manager.py:459-481`: `set_status` persists the status that `_job_complete_process` publishes.
- `nvflare/fuel/flare_api/flare_api.py:1624-1635` and `:1673-1679`, plus `nvflare/private/fed/server/job_cmds.py:1528-1549`: public/admin consumers read the persisted job status and treat a terminal value as the job result.

### Call chain and reachability

The relevant normal-operation chain is:

1. `JobRunner._start_run` starts the SJ, sets `_pending_client_outcomes[job_id]`, starts client jobs, narrows pending outcomes to active clients, then `JobRunner.run` inserts `running_jobs[job_id]` and publishes `RUNNING`.
2. `ServerEngine.wait_for_complete` observes a clean SJ exit and removes `engine.run_processes[job_id]`.
3. The client parent's `_wait_child_process_finish` observes `ProcessExitCode.INFRASTRUCTURE_ERROR` (or another reportable failure) and sends `REPORT_JOB_FAILURE`.
4. `FederatedServer.process_job_failure` checks `is_client_outcome_pending`; if true, it later calls `JobRunner.fail_run`.
5. Concurrently, `_job_complete_process` sees the SJ removed from `run_processes`, waits for or expires pending client outcomes, latches `_FinishedJobState(status=FINISHED_COMPLETED)` if no exception record is present, then later publishes the latched status through `job_manager.set_status`.

The MC-10 counterexample instantiates this call chain. Extracted trace actions show: client exits with rc 1, the report micro-step reaches `reports ... accepted = TRUE` while `pending = {c1}`, completion clears the pending set and reads no failure, the report handler records `exc[j1].rc = 104`, and completion publishes the earlier `FINISHED:COMPLETED` latch.

### Trigger scenario

Concrete reachable scenario:

1. One client job is active and the server job exits cleanly.
2. The client process exits with an infrastructure failure and starts the `REPORT_JOB_FAILURE` handler.
3. The handler passes `is_client_outcome_pending` before the completion thread's pending-outcome deadline clears the set.
4. The completion thread clears unresolved pending outcomes, reads no exception record, and latches `FINISHED_COMPLETED`.
5. The handler resumes and calls `fail_run`, which records `ProcessExitCode.INFRASTRUCTURE_ERROR` while the job is still in `running_jobs`.
6. The completion thread publishes the previously latched `FINISHED_COMPLETED` and removes the exception record.

Safeguards found:

- `process_job_failure` rejects unknown, unauthenticated, or non-pending reports. This does not help after the report has already passed the pending check.
- `_job_complete_process` checks existing server failure before applying the pending-outcome barrier. This does not help when the failure is recorded after the completion thread has read the exception map and latched the status.
- `fail_run` records authoritative failure under `runner.lock` and `engine.lock`, but `_finished_job_states` is not invalidated or recomputed after `fail_run`.
- Completion removes `engine.exception_run_processes[job_id]` after publishing, so the recorded failure is not a later correcting mechanism.

## Step 2: Developer-Knowledge Search

### Comments and tests

- `job_runner.py:837-840` says `fail_run` establishes an authoritative terminal failure and that remaining client reports cannot change that status or hold publication behind the normal outcome grace period.
- `tests/unit_test/private/fed/server/job_runner_test.py:647-684` asserts failure return codes override a clean SJ finish so list/status shows `FINISHED:EXECUTION_EXCEPTION` rather than `FINISHED:COMPLETED`.
- `tests/unit_test/private/fed/server/job_runner_test.py:857-881` asserts `fail_run` releases the client outcome barrier.
- `tests/unit_test/private/fed/server/job_runner_test.py:1025-1063` asserts the completion loop may finalize from server outcome after the client-outcome grace expires.
- No existing test covers the interleaving where a client report passes the pending check before deadline expiry but calls `fail_run` after completion has latched the server outcome.

### Blame / commits

- `git blame` attributes the client outcome gate and report handling around `fed_server.py:932-956` and `job_runner.py:455-480,534-535` to `46cfc517` ("Wait for client terminal outcomes before finalizing jobs (#5072)"). The commit message says the old root cause was treating server-side exit as sufficient and allowing client failure after server publication, and that the repair applies reported failures before removing the reporting client from the barrier.
- `job_runner.py:448-465` and `:817-840` are from `535373a0` ("Finalize failed jobs with missing client outcomes (#5221)"). The commit message says a known non-ABORTED server failure should finalize without waiting for missing client outcomes.
- `52c966d1` ("Report active client process exit failures (#5194)") explains that active client worker exits should reach the server as bounded failures.

These commits establish developer intent that actionable client failures and `fail_run` failure codes should decide the terminal status. They do not mention the specific stale-latch race after `is_client_outcome_pending` has returned true but before `fail_run` runs.

## Step 3: Known-Status / Precedent

Searches run:

- Local history: `git log --all --grep='client outcome|fail_run|job failure|terminal outcome|FINISHED:COMPLETED|FINISHED_ABNORMAL|job final' --regexp-ignore-case`.
- Local history exact terms: `git log --all --grep='outcome.*latch|latch.*outcome|FinalMatchesOutcome|client.*failure.*completed|completed.*client.*failure|fail_run.*finished|finished_state.*fail_run|pending.*outcome.*fail_run' --regexp-ignore-case`.
- Source/docs/tests: `rg` for `terminal outcome`, `client outcome`, `fail_run`, `job failure`, `FINISHED_COMPLETED`, and adjacent phrases.
- GitHub issue/PR API searches for exact and near-exact phrases: `"finished_state" "fail_run"`, `"Dropped terminal outcome" "FINISHED:COMPLETED"`, `"client_outcome_wait_timeout" "fail_run"`, `"REPORT_JOB_FAILURE" "FINISHED:COMPLETED"`, and `"client failure" "FINISHED:COMPLETED"`.

Results:

- PR #5072 is a broader, already fixed predecessor: the server used to publish `FINISHED:COMPLETED` before receiving client terminal outcomes at all. MC-10 is a narrower residual: the report is accepted while the job is active, `fail_run` records the failure, but a stale completion latch still publishes success.
- PR #5221 covers known server failures with missing client outcomes, not a client failure recorded after a completion latch.
- No public issue/PR/CVE/advisory or prior dataset entry found for the exact same mechanism at the same site.

Known-status conclusion: Novelty is `NEW` for this mechanism.
