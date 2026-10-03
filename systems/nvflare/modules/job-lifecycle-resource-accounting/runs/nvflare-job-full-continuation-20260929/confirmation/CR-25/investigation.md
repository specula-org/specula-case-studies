# CR-25 Investigation

## Scope

Finding: delayed server-job (SJ) heartbeat marks a normally completed job as aborted.

Source: code review. No model-checking counterexample was provided for this finding.

## Step 1: Code Audit

Relevant sites:

- `nvflare/private/fed/server/fed_server.py:605-612`: `_listen_command` handles `ServerCommandNames.HEARTBEAT`. If `job_id` is not in `engine.run_processes`, it calls `engine.abort_app_on_server(job_id)` and `_set_job_aborted(job_id)`, then logs that the job "should not be running".
- `nvflare/private/fed/server/fed_server.py:616-623`: `_set_job_aborted` loads the persisted job metadata. If stored status is `RUNNING`, it calls `engine.job_runner.mark_run_aborted(job_id, fl_ctx)`.
- `nvflare/private/fed/server/job_runner.py:802-811`: `mark_run_aborted` sets `job.run_aborted = True` when the job is still present in `running_jobs`; it does not check the SJ process outcome.
- `nvflare/private/fed/server/job_runner.py:484-492`: the completion thread latches `FINISHED_ABORTED` whenever `job.run_aborted` is true, before checking the SJ outcome.
- `nvflare/private/fed/server/job_runner.py:523-538`: the latched terminal status is persisted and `JOB_ABORTED` is fired for `FINISHED_ABORTED`.
- `nvflare/private/fed/server/server_engine.py:203-234`: after a job process exits, `wait_for_complete` waits up to 2 seconds for `UPDATE_RUN_STATUS`, records a nonzero return code if present, and removes the job from `run_processes`.
- `nvflare/private/fed/server/fed_server.py:1160-1168`: the SJ-side parent loop sends `ServerCommandNames.HEARTBEAT` to the parent via `cell.fire_and_forget`.
- `nvflare/private/fed/server/server_app_runner.py:89-93`: the SJ normal completion path sends `UPDATE_RUN_STATUS`, marks the server stopped, and stops training in `finally`.

Call chain:

1. Normal job start reaches `JobRunner.run`: after `_start_run`, it inserts the `Job` into `running_jobs` and persists status `RUNNING` (`job_runner.py:703-711`).
2. The SJ process exits normally. `ServerAppRunner.finally` calls `update_job_run_status` (`server_app_runner.py:89-90`), and the parent `ServerEngine.wait_for_complete` removes `run_processes[job_id]` (`server_engine.py:203-234`).
3. Before `JobRunner._job_complete_process` publishes the terminal status, a legitimate SJ heartbeat message that was already sent or delayed by transport is delivered to `FederatedServer._listen_command`.
4. Because `run_processes` no longer contains the job while persisted status is still `RUNNING`, `_set_job_aborted` sets `job.run_aborted = True`.
5. The completion thread publishes `FINISHED_ABORTED` instead of the normal `FINISHED_COMPLETED`.

Reachability:

- The precondition "status is persisted as `RUNNING`, `running_jobs` still contains the job, and `run_processes` has just been removed" is a normal completion window: `JobRunner.run` writes `RUNNING`, and only `_job_complete_process` removes `running_jobs` after terminal publication.
- The heartbeat is a valid protocol message from an SJ (`ServerCommandNames.HEARTBEAT`), sent via fire-and-forget from `fed_server.py:1160-1168`. A delayed fire-and-forget message can be processed after `wait_for_complete` removes `run_processes`.
- No caller-side guard distinguishes "untracked because the SJ normally exited and is awaiting finalization" from "untracked but should be aborted".

Safeguards / masks checked:

- `_set_job_aborted` does not check `exception_run_processes`, `PROCESS_FINISHED`, a completion latch, or whether the SJ reported normal `UPDATE_RUN_STATUS`.
- The completion thread treats `job.run_aborted` as authoritative and publishes `FINISHED_ABORTED`.
- The bad status is persisted as terminal. No downstream mechanism was found that changes `FINISHED_ABORTED` back to `FINISHED_COMPLETED`.

Real consumer:

- The CLI treats `FINISHED:ABORTED` as a terminal abort/failure (`nvflare/tool/job/job_cli.py:1935-1936`, `2769-2784`), whereas normal completion should be `FINISHED:COMPLETED` per `docs/system_architecture/system_architecture.rst:339-342`.

Trigger scenario:

1. A job is running normally.
2. The SJ sends or has in flight a parent heartbeat.
3. The SJ exits cleanly and sends `UPDATE_RUN_STATUS`.
4. `ServerEngine.wait_for_complete` removes `run_processes[job_id]`.
5. Before the completion thread publishes the terminal status, the delayed heartbeat is handled.
6. `_set_job_aborted` observes persisted `RUNNING`, sets `job.run_aborted`, and the completion thread publishes `FINISHED_ABORTED`.

## Step 2: Developer Knowledge Search

Local git history search performed:

- `git log HEAD --grep='Missing sj heartbeat' --grep='aborted job status publication race' --grep='heartbeat reconciliation' --grep='normal completion' --grep='_set_job_aborted' --grep='job should not be running' --grep='delayed heartbeat' --grep='FINISHED_ABORTED' --regexp-ignore-case`
- `git log HEAD -S'_set_job_aborted' -- nvflare/private/fed/server/fed_server.py`
- `git log HEAD -S'Job: {job_id} should not be running' -- nvflare/private/fed/server/fed_server.py`
- `git log HEAD -S'mark_run_aborted(job_id' -- nvflare/private/fed/server/fed_server.py nvflare/private/fed/server/job_runner.py`
- `git blame -L 594,623 -- nvflare/private/fed/server/fed_server.py`
- `git blame -L 484,538 -- nvflare/private/fed/server/job_runner.py`
- `git blame -L 203,234 -- nvflare/private/fed/server/server_engine.py`

Evidence found:

- `8bb1b84c` / PR subject `Missing sj heartbeat (#2583)` introduced the SJ heartbeat behavior. The local commit message says: "Added the missing SJ heartbeat, fixed the early abort_job command issue." Blame attributes `fed_server.py:606-620` to this commit.
- `6d193a24` / PR subject `Fix aborted job status publication race (#4633)` changed `_set_job_aborted` to call `mark_run_aborted` and added focused tests. Its commit message says aborted-job status publication should be deterministic and not race with job completion/status updates. It also says `stop_run()` still sets `job.run_aborted` immediately and "only delays persisted FINISHED_ABORTED until workspace save has completed."
- Unit test `tests/unit_test/private/fed/server/fed_server_test.py:552-568` asserts `_set_job_aborted` calls `mark_run_aborted` and does not publish status directly.
- Unit tests in `tests/unit_test/private/fed/server/job_runner_test.py` assert `job.run_aborted` leads to `FINISHED_ABORTED`, and assert a non-aborted clean completion path can publish `FINISHED_COMPLETED`.
- No comment, doc, or test found that states a delayed SJ heartbeat after normal SJ exit is intended to convert a clean completion into an aborted terminal status.

Developer intent evidence:

- Documentation says `FINISHED_COMPLETED` means "Job completed successfully" and `FINISHED_ABORTED` means "Job aborted by admin request or by a failure classified as an abort" (`docs/system_architecture/system_architecture.rst:339-342`).
- Documentation describes heartbeat self-healing for out-of-sync jobs, especially clients running jobs that should not be running (`docs/user_guide/core_concepts/job.rst:349-358`). It does not describe using a delayed SJ heartbeat to override normal completion.

## Step 3: Known Status / Precedent

Known-status search was performed in local pinned git history and in-tree tests/docs. External issue/PR pages were not consulted because the continuation instructions prohibit inspecting upstream issue/PR discussions or newer upstream commits for this run.

Closest local history:

- `8bb1b84c` reports adding missing SJ heartbeat to fix an early abort path. This is the mechanism that introduced the heartbeat abort branch, but it is not a report of delayed normal completion being marked aborted.
- `6d193a24` reports an aborted-job status publication race. It concerns delaying persisted `FINISHED_ABORTED` until completion/workspace-save, not a delayed SJ heartbeat poisoning normal completion.
- `535373a0` preserves the normal outcome barrier for normal completion and launcher `ABORTED` precedence, but its root cause is failed jobs with missing client outcomes, not this heartbeat path.

No local pinned-history commit, in-tree test, or doc was found that reports this exact defect: a delayed SJ heartbeat after `run_processes` removal but before completion publication causing a normally completed job to persist `FINISHED:ABORTED`.

Novelty for final report: NEW, based on the above permitted local-history search.

## Phase 2 Reproduction Summary

Reproduction file:

`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-25_delayed_sj_heartbeat.py`

Command:

`timeout 5m python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-25_delayed_sj_heartbeat.py`

Output:

```text
CONTROL final_status=FINISHED:COMPLETED run_aborted=False
TRIGGER final_status=FINISHED:ABORTED run_aborted_after_heartbeat=True
EXPECTED normal completion should remain FINISHED:COMPLETED.
BUG_TRIGGERED=True
```

Escalation:

- Level 0: a full cluster black-box run was not attempted in this per-finding environment.
- Level 1: a full local deployment with timing-only delay was not built because the per-finding harness would need to hold the SJ heartbeat transport precisely between `ServerEngine.wait_for_complete` and the 1-second completion thread pass.
- Level 2: reproduced by instantiating the reachable normal-completion window and delivering a valid `ServerCommandNames.HEARTBEAT` through `FederatedServer._listen_command`. The injected precondition corresponds to the real call sequence `JobRunner.run` inserts `running_jobs` and writes `RUNNING` (`job_runner.py:703-711`), then `ServerEngine.wait_for_complete` removes `run_processes` after normal SJ exit (`server_engine.py:203-234`), before `_job_complete_process` removes `running_jobs` and publishes terminal status (`job_runner.py:441-538`).
- Level 3: not used.

Conclusion after reproduction:

The finding is reproduced. The delayed heartbeat permanently changes a normally completed job's persisted terminal status to `FINISHED:ABORTED`, and CLI/status consumers treat that status as an abort/failure.
