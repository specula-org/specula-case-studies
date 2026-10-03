# Confirmation Report — nvflare-job

## Final Result

Reproduced bugs: 38 = 33 NEW + 4 KNOWN-unfixed + 1 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 1
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 39
Dispositions: 39 total = 38 reproduced + 0 env-limited + 0 masked + 1 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred

| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | MC-4 | REPRODUCED | yes |
| 5 | MC-5 | REPRODUCED | yes |
| 6 | MC-6 | REPRODUCED | yes |
| 7 | MC-7 | REPRODUCED | yes |
| 8 | MC-8 | REPRODUCED | yes |
| 9 | MC-9 | REPRODUCED | yes |
| 10 | MC-10 | REPRODUCED | yes |
| 11 | MC-11 | REPRODUCED | yes |
| 12 | MC-12 | REPRODUCED | yes |
| 13 | MC-13 | REPRODUCED | yes |
| 14 | CR-4 | REPRODUCED | yes |
| 15 | CR-6 | REPRODUCED | yes |
| 16 | CR-7 | REPRODUCED | yes |
| 17 | CR-9 | REPRODUCED | yes |
| 18 | CR-10 | REPRODUCED | yes |
| 19 | CR-11 | REPRODUCED | yes |
| 20 | CR-12 | REPRODUCED | yes |
| 21 | CR-14 | REPRODUCED | yes |
| 22 | CR-15 | REPRODUCED | yes |
| 23 | CR-16 | REPRODUCED | yes |
| 24 | CR-17 | REPRODUCED | yes |
| 25 | CR-19 | REPRODUCED | yes |
| 26 | CR-20 | REPRODUCED | yes |
| 27 | CR-21 | REPRODUCED | yes |
| 28 | CR-22 | REPRODUCED | yes |
| 29 | CR-23 | REPRODUCED | yes |
| 30 | CR-24 | REPRODUCED | yes |
| 31 | CR-25 | REPRODUCED | yes |
| 32 | CR-26 | REPRODUCED | yes |
| 33 | CR-27 | REPRODUCED | yes |
| 34 | CR-28 | REPRODUCED | yes |
| 35 | CR-29 | REPRODUCED | yes |
| 36 | CR-30 | FALSE POSITIVE | no |
| 37 | CR-31 | REPRODUCED | yes |
| 38 | CR-32 | REPRODUCED | yes |
| 39 | CR-33 | REPRODUCED | yes |

## Entry 1: Queued cancellation can be overwritten by concurrent lifecycle writes

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/job_runner.py:670

## Description
`abort_job` can acknowledge a queued abort by setting `FINISHED:ABORTED`, but the runner can then overwrite that status with `DISPATCHED` and `RUNNING`.

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 1 timing assistance triggered it; no state injection or source patch.
2. Level 2/3 precondition: not applicable.
3. Real consumer/caller: `nvflare/fuel/flare_api/flare_api.py:575` receives the OK abort response; `nvflare/private/fed/server/job_runner.py:711` later publishes `RUNNING`.
4. Permanent or masked: not masked in the reproduced execution. The job remains `RUNNING`, `run_aborted=False`, with a live run process.

## Trigger scenario
The runner passes the `SUBMITTED` status check at `job_runner.py:661`. A concurrent abort marks the job `FINISHED:ABORTED` at `job_cmds.py:1062` and returns success. The runner resumes and writes `DISPATCHED` at `job_runner.py:670`, then starts the job and writes `RUNNING` at `job_runner.py:711`.

## Developer intent
`flare_api.abort_job` documents that if a job is not started yet, it “will be cancelled and won't be scheduled” (`flare_api.py:569`). The server queued-abort branch also returns “Aborted the job ... before running it.” Local pinned-history/docs/tests search found no prior report for this exact overwrite mechanism.

## Reproduction result
Command:
```bash
timeout 90s python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-1_queued_abort.py 2>&1 | tee /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-1/repro-output.log
```

Output:
```text
WORKTREE=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-1/worktree
ESCALATION=Level 1 timing-controlled harness; no state injection; no product source patch
CONTROL abort-before-schedule
  abort_reply=['Aborted the job mc1-control before running it.']
  status_history=FINISHED:ABORTED
  final_status=FINISHED:ABORTED
  jobs_to_schedule_after_abort=0
  control_ok=True
SCENARIO abort-during-deploy
  abort_reply=['Aborted the job mc1-deploy before running it.']
  abort_errors=[]
  status_history=FINISHED:ABORTED -> DISPATCHED -> RUNNING
  final_status=RUNNING
  started_after_ack=True
  run_aborted=False
  bug_triggered=True
SCENARIO abort-during-start
  abort_reply=['Aborted the job mc1-start before running it.']
  abort_errors=[]
  status_history=DISPATCHED -> FINISHED:ABORTED -> RUNNING
  final_status=RUNNING
  started_after_ack=True
  run_aborted=False
  bug_triggered=True
RESULT: BUG REPRODUCED - acknowledged queued abort was overwritten and the job started RUNNING
```

## Recommendation
Make job-status transitions conditional/atomic across abort and runner lifecycle writes, and recheck abort state immediately before writing `DISPATCHED` or `RUNNING`.

---

## Entry 2: Deleting a listed job can terminate the only scheduling thread

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `nvflare/apis/impl/job_def_manager.py:527`

## Description
Confirmed. `SimpleJobDefManager._scan` lists job objects, then reads metadata for each listed object without handling `StorageException`. If a SUBMITTED job is deleted between `list_objects` and `get_meta`, `FilesystemStorage.get_meta` raises, and the exception escapes `JobRunner.run` before its deployment exception handler. That terminates the scheduling loop.

I also corrected `confirmation/MC-2/issue.json`; it now passes `persistent_findings.validate_issue_proposal`.

## Trigger scenario
A hot server with clients runs `JobRunner.run`. During `get_jobs_to_schedule`, an admin-supported `delete_job` removes a listed SUBMITTED job before `_scan` reads its metadata. A later SUBMITTED job is then added, but the only scheduler thread is already dead.

## Developer intent
SUBMITTED jobs may be deleted through normal admin command handling; only DISPATCHED/RUNNING jobs are rejected. Storage already treats missing metadata as an ordinary `StorageException`, and other job-manager callers sometimes guard storage reads, but `_scan` does not.

## Reproduction result
Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 1 timing assistance only; normal product APIs performed the job creation/delete/scheduling path.
2. Level 2/3 injection used? **no**.
3. Real consumer/caller observing wrong outcome: `JobRunner.run` at `nvflare/private/fed/server/job_runner.py:650`; after the exception, later scheduling at lines 655-658 is never reached.
4. Bad state permanent or masked? **permanent within the server process**. No downstream guard, loopback, or restart mechanism revived the scheduler thread in the reproduction.

Executed repro: `repro/test_bugMC-2_scan_delete_kills_runner.py`

```text
LEVEL0 no timing: runner_alive=True exception=None later_schedule_calls=1 later_status=SUBMITTED
LEVEL1 timing-assisted delete-after-list-before-get_meta: runner_alive=False exception=StorageException: object /tmp/mc2-level1-4pk8m46b/jobs/3359b541-1ebe-4bb3-a73c-37a95a7670a8 does not exist scheduler_calls_after_later_job=0 later_status=SUBMITTED
LEVEL1 traceback_last_line=nvflare.apis.storage.StorageException: object /tmp/mc2-level1-4pk8m46b/jobs/3359b541-1ebe-4bb3-a73c-37a95a7670a8 does not exist
RESULT: REPRODUCED MC-2
```

## Recommendation
Guard `_scan` metadata reads against missing/deleted listed jobs, skip the vanished object, and keep `JobRunner.run` from terminating on scan-time storage exceptions outside the deployment handler.

---

## Entry 3: A late RUNNING write can replace an already-published terminal outcome

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/NVIDIA/NVFlare/issues/5301; fix-status: unfixed)
- **Location**: nvflare/private/fed/server/job_runner.py:711

## Description
`JobRunner.run` inserts a job into `running_jobs` before persisting `RUNNING`. The completion thread can observe that insertion, publish `FINISHED:EXECUTION_EXCEPTION`, remove the job, and then the runner’s late unguarded `RUNNING` write regresses persisted status for a completed job.

## Trigger scenario
A local-process server job exits nonzero during `_start_run`. `wait_for_complete` removes `engine.run_processes[job_id]`; after `running_jobs[job_id] = ready_job` but before `set_status(RUNNING)`, `_job_complete_process` publishes terminal status and removes `running_jobs`; then line 711 writes `RUNNING`.

## Developer intent
Docs describe `RUNNING` as active execution and terminal status as the recorded result after SJ/CJ termination. Admin consumers treat `FINISHED:*` as terminal: `abort_job` avoids stopping finished jobs, and download requires terminal status. Issue #5301 reports this exact mechanism and is closed `not_planned`.

## Reproduction result
Repro file: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-3_late_running_overwrites_terminal.py`

Command:
```bash
timeout 120s env PYTHONPATH=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-3/worktree python /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-3_late_running_overwrites_terminal.py
```

Output:
```json
{
  "bug_triggered": true,
  "consumer_abort_job_messages": [
    [
      "ERROR",
      "Job job-mc3 is not running."
    ]
  ],
  "level0_control": {
    "description": "normal JobRunner.run path with no timing gate",
    "final_status": "FINISHED:EXECUTION_EXCEPTION",
    "status_history": [
      "DISPATCHED",
      "RUNNING",
      "FINISHED:EXECUTION_EXCEPTION"
    ]
  },
  "level1_timing_assisted": {
    "description": "same path, but the RUNNING persistence call waits until completion publishes terminal and removes running_jobs",
    "exception_run_processes": [],
    "final_status": "RUNNING",
    "run_processes": [],
    "running_jobs": [],
    "status_history": [
      "DISPATCHED",
      "FINISHED:EXECUTION_EXCEPTION",
      "RUNNING"
    ]
  }
}
```

Persistent finding proposal was also repaired and validated:
```json
{"id":"MC-3","status":"REPRODUCED","valid":true}
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? yes, Level 1 timing assistance.
2. Level 2/3 was not used.
3. Real consumer/caller: `JobCommandModule.abort_job`, `nvflare/private/fed/server/job_cmds.py:1051`, observes persisted `RUNNING` and returns `Job job-mc3 is not running.`
4. The bad state is permanent in the live run: completion already removed `running_jobs` and `exception_run_processes`, and no same-run loop republishes terminal status.

## Recommendation
Guard status transitions so non-terminal writes cannot overwrite `FINISHED:*`, or re-check persisted status after `_start_run` and before line 711. A compare-and-set or terminal latch shared by runner and completion paths would address the root cause.

---

## Entry 4: An early authoritative client failure can make START collection raise KeyError

- **Finding ID**: MC-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-4/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `nvflare/private/fed/server/job_runner.py:360`

## Description
Confirmed. During `_start_run`, `_pending_client_outcomes[job_id]` is populated before START replies are collected, but `fail_run()` can remove that key when a real authenticated client failure report arrives in the same window. `_start_run` later indexes the removed key directly, raising `KeyError`; `JobRunner.run` catches it and publishes `FINISHED:FAILED_TO_RUN` instead of preserving the authoritative client failure outcome.

## Trigger scenario
A two-client job starts. The server process launch succeeds and records `engine.run_processes[job_id]`; `_start_run` sets `_pending_client_outcomes[job_id]`. Before all START replies return, one client reports an actionable process failure through `FederatedServer.process_job_failure()` -> `JobRunner.fail_run()`, which pops the pending outcome entry. START collection then resumes and hits the direct index at `job_runner.py:360`.

## Developer intent
`fail_run()` records an authoritative terminal failure in `engine.exception_run_processes`, and the normal post-start control path publishes that as `FINISHED:EXECUTION_EXCEPTION`. The reproduced START-window path instead routes through the generic `_start_run` exception handler at `job_runner.py:713-720`.

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 timing control used; injected precondition is reachable via real call sequence: `JobRunner.run` -> `_start_run` -> `ServerEngine.start_app_on_server` records `run_processes` -> `_pending_client_outcomes[job_id]` is set -> real client worker failure sends REPORT_JOB_FAILURE -> `FederatedServer.process_job_failure` -> `JobRunner.fail_run`.
3. Real consumer/caller observing wrong outcome: `JobRunner.run`, `nvflare/private/fed/server/job_runner.py:713`, catches the `KeyError` and records `FAILED_TO_RUN` at `job_runner.py:720`.
4. Bad state is **permanent** for that job: final status remains `FINISHED:FAILED_TO_RUN`, and the authoritative exception entry is left behind in the failing window. The after-start control publishes `FINISHED:EXECUTION_EXCEPTION`, so this is not masked.

## Reproduction result
Wrote and executed:
`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-4_start_keyerror.py`

Real output excerpt:
```text
MC-4 reproduction result
{
  "failing_window": {
    "mode": "failure_during_start",
    "final_status": "FINISHED:FAILED_TO_RUN",
    "status_history": [
      "SUBMITTED",
      "DISPATCHED",
      "FINISHED:FAILED_TO_RUN"
    ],
    "exception_run_processes": {
      "job-failure_during_start": 101
    },
    "trace": [
      "start_client_job(job-failure_during_start) entered; pending={'job-failure_during_start': {'site-2', 'site-1'}}",
      "process_job_failure(site-1, job-failure_during_start, EXCEPTION) begin",
      "process_job_failure end; pending={}; exception_entry={'_job_id': 'job-failure_during_start', ... '_process_return_code': 101}; reply_rc=ok",
      "set_status(job-failure_during_start, FINISHED:FAILED_TO_RUN)",
      "log_error: Failed to run the Job (job-failure_during_start): KeyError: 'job-failure_during_start'"
    ]
  },
  "after_start_control": {
    "mode": "failure_after_start",
    "final_status": "FINISHED:EXECUTION_EXCEPTION",
    "status_history": [
      "SUBMITTED",
      "DISPATCHED",
      "RUNNING",
      "FINISHED:EXECUTION_EXCEPTION"
    ]
  }
}
BUG TRIGGERED: failure during START collection raised KeyError and published FINISHED:FAILED_TO_RUN; the same failure after running_jobs insertion published FINISHED:EXECUTION_EXCEPTION.
```

Also validated `issue.json` through `persistent_findings.validate_issue_proposal`: `MC-4 / REPRODUCED / model-checking`, with 8 source dependencies and 3 evidence artifacts.

## Recommendation
Make START collection tolerate an authoritative `fail_run()` that removes `_pending_client_outcomes[job_id]`: avoid direct indexing after START replies, preserve the recorded exception outcome, and ensure cleanup removes the exception-process entry for jobs failed before `running_jobs` insertion.

---

## Entry 5: A metadata refresh can restore SUBMITTED after a successful abort

- **Finding ID**: MC-5
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-5/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: nvflare/app_common/job_schedulers/job_scheduler.py:303

**Checklist**
1. Did Level 0 or Level 1 alone trigger it: **yes**. Level 1 timing assistance reproduced it; no state injection or source patch was used.
2. Not applicable; no Level 2 or Level 3 technique was used.
3. Real consumer/caller: `JobRunner.run` observes the restored `SUBMITTED` state at `nvflare/private/fed/server/job_runner.py:650`, then proceeds through deploy/start at `job_runner.py:669` and `job_runner.py:703`.
4. The bad state is not masked before consequence. The stale `SUBMITTED` is consumed by a later runner pass and the acknowledged-aborted job is launched.

## Description

A scheduler refresh of a resource-blocked queued job reaches `FilesystemStorage.update_meta(replace=False)`, which reads the whole metadata dictionary, merges partial scheduler fields, and rewrites the whole file without serializing the read/write interval. If `abort_job` writes `FINISHED:ABORTED` between that read and write, the refresh can restore stale `SUBMITTED`.

The resumed deliverable gap was the persistent `issue.json`; it now validates through `persistent_findings.validate_issue_proposal`.

## Trigger scenario

A `SUBMITTED` job is resource-blocked, so the scheduler refreshes its schedule metadata. During the storage RMW window, admin abort succeeds for the same queued job. The stale refresh write restores `SUBMITTED`; when resources later become available, `JobRunner.run` schedules and starts the job after abort acknowledgement.

## Developer intent

`abort_job` explicitly treats `SUBMITTED`/`DISPATCHED` jobs as abortable and writes `FINISHED:ABORTED` at `nvflare/private/fed/server/job_cmds.py:1062`. `JobRunner.run` also checks status before deploy/start, so terminal abort status is intended to prevent later launch.

## Reproduction result

Executed and saved output from `repro/test_bugMC-5_refresh_abort.py`.

```text
nvflare_source=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-5/worktree/nvflare/__init__.py
LEVEL0 bounded unassisted run:
  abort_reply=['Aborted the job 5c32156b-193a-4b08-8789-3cd29269eb0e before running it.']
  final_status=FINISHED:ABORTED
  launched_after_abort=False
  runner_exception=None
LEVEL1 refresh_meta RMW read status=SUBMITTED
LEVEL1 status immediately after abort=FINISHED:ABORTED
LEVEL1 status after refresh write=SUBMITTED
LEVEL1 timing-assisted run:
  abort_reply=['Aborted the job 5faaed78-4935-4c23-a74a-001b28038527 before running it.']
  status_after_abort=FINISHED:ABORTED
  status_after_refresh_write=SUBMITTED
  final_status=RUNNING
  launched_after_acknowledged_abort=True
  resource_checks=[('5faaed78-4935-4c23-a74a-001b28038527', False), ('5faaed78-4935-4c23-a74a-001b28038527', True)]
  cancel_calls=1
  lifecycle_events=[('_before_check_client_resources', ''), ('_after_check_client_resources', ''), ('_before_check_client_resources', ''), ('_after_check_client_resources', ''), ('_job_started', '5faaed78-4935-4c23-a74a-001b28038527')]
  runner_exception=None
REPRODUCED: final_status=RUNNING launched_after_abort=True
```

## Recommendation

Make filesystem metadata partial updates atomic across read/merge/write, or preserve terminal status with a compare-and-retry guard before writing stale metadata. Add a regression test for scheduler refresh overlapping `abort_job` on a submitted, resource-blocked job.

---

## Entry 6: Competing cleanup paths can terminate the completion thread with KeyError

- **Finding ID**: MC-6
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-6/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/job_runner.py:532

## Description

MC-6 is reproduced. `_job_complete_process` publishes the terminal status, then blindly deletes `self.running_jobs[job_id]`. If the runner’s late `set_status(RUNNING)` fails after an admin delete removes the job object, the runner exception path can delete the same running entry first, leaving completion to raise `KeyError` at `job_runner.py:532`.

The live consequence is that completion dies before `JOB_COMPLETED` / `JOB_ABORTED`, so `DefaultJobScheduler.handle_event` at `nvflare/app_common/job_schedulers/job_scheduler.py:281` never releases its `scheduled_jobs` slot.

## Trigger scenario

Sequence reproduced: job starts, `running_jobs` is inserted, job process/client outcome finish before the late `RUNNING` status write returns, completion publishes `FINISHED:COMPLETED`, real `JobCommandModule.delete_job` deletes the terminal job object, late `RUNNING` write raises, runner cleanup removes `running_jobs[job_id]`, then completion raises `KeyError` on its unguarded delete.

## Developer intent

Prior-report search found adjacent lifecycle/delete fixes, but no public issue or PR for this same stale-delete plus completion blind-delete mechanism. Reviewed PR/commits included #4632, #5216, #4471, #630, and #4986; none addressed this site/mechanism. Novelty is `NEW`.

## Reproduction result

Repro written and executed: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-6_completion_keyerror.py`

Captured output:

```text
Exception in thread Thread-1 (_job_complete_process):
Traceback (most recent call last):
  File "/usr/lib/python3.12/threading.py", line 1073, in _bootstrap_inner
    self.run()
  File "/usr/lib/python3.12/threading.py", line 1010, in run
    self._target(*self._args, **self._kwargs)
  File "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-6/worktree/nvflare/private/fed/server/job_runner.py", line 532, in _job_complete_process
    del self.running_jobs[job_id]
        ~~~~~~~~~~~~~~~~~^^^^^^^^
KeyError: 'job-mc6'
=== MC-6 reproduction output ===
JobRunner.run: set_status(DISPATCHED)
runner: entered late set_status(RUNNING)
process/client: job finished before RUNNING write returned
Thread-1 (_job_complete_process): set_status(FINISHED:COMPLETED)
job store: deleted job object
admin: delete_job reply=[('string', 'Job job-mc6 deleted. Submit records marked deleted: 0.', None), ('success', '', {'status': 'ok', 'info': '', 'job_id': 'job-mc6', 'submit_records_marked_deleted': 0})]
runner: exception cleanup removed running_jobs before completion remove
runner: set_status(FAILED_TO_RUN) reached after delete
thread_errors=[('Thread-1 (_job_complete_process)', 'KeyError', "'job-mc6'")]
runner_exception=StorageException: object jobs/job-mc6 does not exist after admin delete
events=[('_job_started', 'job-mc6')]
scheduled_jobs=['job-mc6']
running_jobs=[]
job_deleted=True
completion_keyerror=True
started_events=[('_job_started', 'job-mc6')]
completed_events=[]
aborted_events=[]
PASS: reproduced completion thread KeyError and unreleased scheduler slot
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no** for a full black-box deployment; the repro is a deterministic component-level harness with process/storage timing controlled.
2. The controlled precondition is reachable by the real API/model sequence: `RunnerInsertRunning -> CmpPublish -> AdminDeleteExec -> RunnerSetRunning -> RunnerExceptStop -> CmpRemove`, with real `delete_job` deleting after terminal status.
3. Real consumer/caller: `DefaultJobScheduler.handle_event`, `nvflare/app_common/job_schedulers/job_scheduler.py:281`, observes no end event and leaves `scheduled_jobs=['job-mc6']`.
4. The bad state is permanent for that server run unless restarted or manually repaired; no downstream mechanism restarts `_job_complete_process` or emits the missing release event. Not masked.

## Recommendation

Make job cleanup idempotent across runner and completion paths. At minimum, replace the completion blind delete with a guarded removal and ensure lifecycle release events are emitted exactly once even if status/store cleanup races with admin deletion. Also consider reloading status during `delete_job` execution instead of trusting the authorization snapshot.

---

## Entry 7: Concurrent process removal can terminate dead-client cleanup

- **Finding ID**: MC-7
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-7/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/fed_server.py:1109

## Description
`FederatedServer.notify_dead_client` iterates `self.engine.run_processes.items()` live. While the body is notifying a child job, normal process cleanup can remove another entry from the same dictionary; the next iterator advance raises `RuntimeError`. `BaseServer.client_cleanup` does not catch it, so the cleanup thread exits.

## Trigger scenario
A dead-client sweep logs out an expired client participating in multiple active jobs. During `_notify_dead_job` for one job, `ServerEngine.wait_for_complete` removes a different job from `run_processes`, invalidating the live iterator.

## Developer intent
The cleanup thread is started once and is intended to keep removing expired clients. Search of local history plus upstream issue/PR queries found no same-site report for `notify_dead_client` iterating `run_processes.items()` while process cleanup removes entries. A prior local commit fixed the same hazard class at another `run_processes` iterator by snapshotting keys, but not this site.

## Reproduction result
Executed and refreshed the captured log:
```bash
timeout 45s python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-7_sweeper_iterator.py
```

Output:
```text
source: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-7/worktree
escalation:
  Level 0/1 full-deployment trigger: not reproduced in this compact worker harness
  Level 2 reachable state injection: run_processes populated as _start_runner_process does
  Timing assistance: fake child RPC blocks while real ServerEngine.wait_for_complete pops job-B
CONTROL no concurrent run_processes mutation:
  dead token removed=True
  cleanup thread alive after first pass=True
  captured exceptions=[]
REPRO concurrent ServerEngine.wait_for_complete removal during notify_dead_client:
  notifications_before_failure=[('job-A', 'site-dead', 'client dead')]
  job-B removed by real wait_for_complete=True
  cleanup thread dead=True
  captured exceptions=["RuntimeError('dictionary changed size during iteration')"]
  later expired client still registered after >5s=True
  ServerEngine.get_clients() after later expiry=['site-later']
RESULT: MC-7 reproduced
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 used a reachable precondition: `_start_runner_process` creates multiple `run_processes` entries; `client_cleanup` enters dead-client cleanup; `notify_dead_client` iterates those entries; `wait_for_complete` pops another entry during notification. This matches the counterexample’s `SpWaitForComplete` interleaving inside the sweep.
3. Real consumer/caller observing the wrong outcome: `ServerEngine.get_clients()` at `nvflare/private/fed/server/server_engine.py:173`, used by scheduler admission at `nvflare/private/fed/server/job_runner.py:646`, returns stale `site-later`.
4. The bad state is permanent for this server instance: the cleanup thread is started once at `fed_server.py:286` and is not restarted after the uncaught exception.

The remaining acceptance blocker was also cleared: `confirmation/MC-7/issue.json` now validates with the pinned persistent-findings helper.

## Recommendation
Snapshot `run_processes` before iterating in `notify_dead_client`, or protect iteration/removal with a shared lock. Also guard `client_cleanup` so one notification failure cannot permanently stop future dead-client cleanup.

---

## Entry 8: Client resources can be freed while same-group descendants remain alive

- **Finding ID**: MC-8
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-8/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `nvflare/private/fed/client/client_executor.py:676`

## Description
`JobExecutor._wait_child_process_finish` frees the client allocation after the launched job leader exits, but the process launcher runs jobs in a POSIX process group. If the leader leaves a same-process-group descendant alive, the resource is returned to the pool and a later job can be started on the same unit while the descendant is still using it.

## Trigger scenario
Job A starts normally through `CHECK_RESOURCE` / `START_JOB`, spawns a same-process-group child, and exits successfully. The client waiter reaps the leader, frees GPU unit `0`, and unregisters Job A. Job B then reserves and starts on GPU unit `0` while Job A’s descendant is still alive.

## Developer intent
Docs and tests say process handles own job lifecycle and `terminate()` kills the process group. Local history found adjacent Client API external-trainer cleanup work (`#5097`), but not this generic `JobExecutor` resource lifetime defect; that fix is already in this source and does not cover this path.

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**: Level 1, normal client request processors plus timing observation; no state injection or product patch.
2. Level 2/3 precondition: not used.
3. Real consumer/caller observing wrong outcome: Job B is admitted by `nvflare/private/fed/client/scheduler_cmds.py:116`, bound by `nvflare/app_common/resource_consumers/list_resource_consumer.py:37`, and launched from `nvflare/app_common/job_launcher/process_launcher.py:68` with `CUDA_VISIBLE_DEVICES=0`.
4. Permanent or masked? Not masked. The overlap persists until the descendant exits; `terminate()` after leader reap cannot recover the group, and no downstream guard prevents Job B from starting.

## Reproduction result
Command:
```bash
timeout 2m python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-8_process_group_resource_reuse.py
```

Output:
```json
{
  "descendant_alive_at_free": true,
  "descendant_alive_when_job_b_started": true,
  "descendant_alive_after_reaped_handle_terminate": true,
  "job_b_check_ok_while_descendant_alive": true,
  "job_b_process": {
    "cuda": "0"
  },
  "resource_pool_after_job_a_waiter": [0],
  "same_process_group": true,
  "waiter_freed_and_unregistered": true
}
```

Full output is saved at `repro/test_bugMC-8_process_group_resource_reuse.out`. `issue.json` validated with Specula.

## Recommendation
Tie resource release to the whole owned process group, not just the leader process. Capture the process group id before reap and use it for cleanup/liveness, or keep a backend-specific ownership guard so resources are not freed until all owned descendants are gone.

---

## Entry 9: Running-job abort can succeed while the final status is COMPLETED

- **Finding ID**: MC-9
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-9/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: Specula historical MC-E; fix-status: unfixed)
- **Location**: nvflare/private/fed/server/job_runner.py:798

## Description
`stop_run()` sends cleanup/abort work through `_stop_run()` before calling `mark_run_aborted()`. In that window, `_job_complete_process()` can observe a clean server-job exit with `job.run_aborted == False`, classify the job as `FINISHED:COMPLETED`, and publish that terminal status. The later abort marker succeeds but does not revise the already published completion.

## Trigger scenario
A running job receives a normal admin abort through `JobCommandModule.abort_job()`. The server app exits cleanly after the abort RPC, completion runs before `mark_run_aborted()`, and `job_manager.set_status()` records `FINISHED:COMPLETED`. The admin abort caller still receives success.

## Developer intent
Pinned git history contains related PR-linked fixes for aborted-job status publication races, including `#4604`, `#4613`, and `#4633`; the current pinned source still leaves this stop-before-marker interleaving unfixed. Existing unit coverage mocks `_stop_run()` and therefore misses completion interleaving between `_stop_run()` and `mark_run_aborted()`.

## Reproduction result
Repro test written and executed: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-9_stop_before_marker.py`

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

Persistent proposal validation now also passes:

```text
{
  "id": "MC-9",
  "status": "REPRODUCED",
  "valid": true
}
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? no.
2. Level 2 state injection was used only for the reachable running precondition: counterexample State 23/24 has `status=RUNNING`, `runningJobs={j1}`, `rp` present, and `runAborted=FALSE`; the real source reaches this via `JobRunner.run()` at `nvflare/private/fed/server/job_runner.py:703`.
3. Real consumer/caller observing the wrong outcome: `JobCommandModule.abort_job()` at `nvflare/private/fed/server/job_cmds.py:1072` returns abort success, while `job_manager.set_status()` is called from `nvflare/private/fed/server/job_runner.py:524` with `FINISHED:COMPLETED`.
4. The bad state is permanent for the published terminal job status in this run: completion removes the job from `running_jobs` after publishing, and the later in-memory `run_aborted` marker does not trigger a downstream correction.

## Recommendation
Mark the job aborted before or atomically with abort publication, or make completion re-check the abort decision under the same ordering before publishing a terminal status. Add a regression test that permits completion to run between `_stop_run()` and `mark_run_aborted()`.

---

## Entry 10: An authoritative client failure recorded after the completion outcome read can be published as success

- **Finding ID**: MC-10
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-10/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/job_runner.py:484

## Description
`_job_complete_process` can latch `FINISHED:COMPLETED` from the server outcome after a client failure report has already passed the pending-outcome check, but before `process_job_failure` calls `fail_run`. `fail_run` then records an authoritative `INFRASTRUCTURE_ERROR` while the job is still active, yet completion publishes its stale success latch.

## Trigger scenario
A normally exited server job remains in `running_jobs` while `run_processes` has been removed. A client terminal failure report passes `is_client_outcome_pending`; completion concurrently expires the outcome wait, reads no exception record, and latches success; the report then records failure via `fail_run`; completion publishes `FINISHED:COMPLETED`.

## Developer intent
The code comment at `job_runner.py:837` says `fail_run` establishes an authoritative terminal failure. Existing tests assert failure codes override clean SJ completion. PR #5072 and #5221 cover adjacent client-outcome ordering bugs, but I found no prior report for this exact stale-latch race.

## Reproduction result
Test: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-10_outcome_latch_race.py`

Command:
```bash
timeout 2m python /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-10_outcome_latch_race.py
```

Output:
```text
ESCALATION_LEVEL=2+1
LEVEL_0=not run: full local deployment race was replaced by the reachable post-SJ-exit state
LEVEL_1=timing assistance: report handler paused after pending check; completion paused after status latch
LEVEL_2_PRECONDITION=_start_run registers pending client outcomes, JobRunner.run inserts running_jobs, ServerEngine.wait_for_complete removes run_processes after clean SJ exit
REPORT_PENDING_CHECK job=job-mc10 client=site-1 result=True
COMPLETION_LATCHED job=job-mc10 status=FINISHED:COMPLETED
REPORT_REPLY rc=ok
FAIL_RUN_RECORDED job=job-mc10 code=104
PUBLISH_STATUS job=job-mc10 status=FINISHED:COMPLETED
EXPECTED_STATUS_IF_FAILURE_WINS=FINISHED:ABNORMAL
ACTUAL_PUBLISHED_STATUS=FINISHED:COMPLETED
EXCEPTION_RECORD_AFTER_COMPLETION=None
REMOVED_EXCEPTION_PROCESSES=['job-mc10']
BUG_TRIGGERED=true
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 precondition reachability: `_start_run` registers pending outcomes, `JobRunner.run` inserts `running_jobs`, and `ServerEngine.wait_for_complete` removes `run_processes` after clean SJ exit; this matches CE states 27, 31-37.
3. Real consumer/caller: `JobDefManager.set_status` persists the wrong status, observed by `FlareAPI.get_job_status` at `nvflare/fuel/flare_api/flare_api.py:1624` and admin list output at `nvflare/private/fed/server/job_cmds.py:1528`.
4. The bad state is **permanent** for the published job status; completion removes the exception record afterward, as shown by `EXCEPTION_RECORD_AFTER_COMPLETION=None`.

## Recommendation
Recompute or invalidate the completion latch after any accepted `fail_run`, or make completion hold a single synchronization boundary from outcome read through publish so an authoritative failure cannot be recorded between latch and `set_status`.

---

## Entry 11: A client failure accepted in the startup tracking gap can be lost before success is published

- **Finding ID**: MC-11
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-11/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: historical MC-U1; fix-status: unfixed)
- **Location**: nvflare/private/fed/server/job_runner.py:817

## Description
Confirmed. `_start_run()` creates `_pending_client_outcomes[job_id]` before `JobRunner.run()` inserts `running_jobs[job_id]`. If the server job exits cleanly in that interval, `run_processes` can also be gone, so an accepted client failure reaches `fail_run()` while both active maps are empty and is lost. Completion then publishes `FINISHED:COMPLETED`.

## Trigger scenario
Normal startup reaches the gap after `start_app_on_server()` and before `running_jobs` insertion. A fast/no-op server workflow exits, then a client reports `ProcessExitCode.EXCEPTION` through `FederatedServer.process_job_failure()`. The report is accepted because the client is pending, but no exception record is persisted.

## Developer intent
Local history and tests show client terminal failures are intended to affect final status: `#5072` waits for terminal outcomes, `#5221` preserves recorded server failures, and active `fail_run()` tests classify the same failure as `FINISHED:EXECUTION_EXCEPTION`. This exact pending-but-not-active startup gap is not covered.

## Reproduction result
Executed with timeout:

```bash
timeout 60s python /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-11_startup_gap.py | tee /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-11_startup_gap.out
```

```text
MC-11 startup-gap reproduction
worktree=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-11/worktree
repro.failure_reply_code=ok
repro.fail_run_inactive_log=True
repro.exception_record_present=False
repro.status_history=['DISPATCHED', 'RUNNING', 'FINISHED:COMPLETED']
active_control.failure_reply_code=ok
active_control.recorded_exception_code=101
active_control.classified_status=RunStatus.FINISHED_EXECUTION_EXCEPTION
active_control.pending_after_report=None
RESULT=REPRODUCED
```

Checklist answers:
1. Did Level 0 or Level 1 alone trigger it? no; this used a Level 2 harness around scheduler/deployment/process edges while exercising real `JobRunner.run`, `_start_run`, `process_job_failure`, and completion logic.
2. Reachable sequence: `job_runner.py:703-710` calls `_start_run()` before inserting `running_jobs`; `server_engine.py:321-328` inserts `run_processes`; `server_engine.py:203-233` can remove it after clean fast SJ exit; `fed_server.py:938-956` accepts/resolves the pending failure; `job_runner.py:817-836` drops it as inactive.
3. Real consumer/caller: `job_runner.py:523-524` persists the wrong terminal status; `nvflare/tool/job/job_cli.py:2611` reports it as `COMPLETED`.
4. The bad state is permanent: no exception record remains, pending is empty, and no later mechanism corrects `FINISHED:COMPLETED`.

The persistent `issue.json` now validates via `persistent_findings.validate_issue_proposal`: `VALIDATED MC-11 REPRODUCED model-checking`.

## Recommendation
Record failures for pending startup jobs even if active maps are temporarily empty, or move active tracking earlier so `fail_run()` cannot see an accepted pending failure as inactive. Do not resolve the reporting client until the failure is durably recorded.

---

## Entry 12: Stale delete authorization can strand a running job and its admission slot

- **Finding ID**: MC-12
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-12/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/job_cmds.py:516

## Description
Confirmed. `authorize_job_id` caches a `Job` object from storage, then the confirmed `delete_job` handler later checks that cached status instead of re-reading live status. If the job becomes `RUNNING` between authorization and confirmed execution, the stale `SUBMITTED` snapshot passes the guard and deletes the live job object.

On completion, `job_runner.py:524` retries terminal status publication against the missing object and continues before removing `running_jobs` or firing lifecycle completion. `DefaultJobScheduler` keeps the slot in `scheduled_jobs`, so later eligible work stays blocked under `max_jobs=1`.

## Trigger scenario
1. Authorize `delete_job` while `j1` is `SUBMITTED`.
2. Let the runner/scheduler start `j1` and publish `RUNNING`.
3. Execute the confirmed delete on the same connection using the stale snapshot.
4. Finish the server process for `j1`.
5. Completion retries fail; `j1` remains in `running_jobs` and `scheduled_jobs`; `j2` remains `SUBMITTED`.

## Developer intent
The public API states delete only removes a job “if the job is not currently running” (`nvflare/fuel/flare_api/flare_api.py:592`). The repro includes a fresh-running control that returns `job_running`, isolating the bug to the stale authorize/execute gap.

## Reproduction result
Executed and refreshed:
`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-12_stale_delete_slot.py`

```text
MC-12 reproduction: REPRODUCED
control_fresh_running_delete_response={"time": "2026-09-28 11:52:06.291554", "data": [{"type": "error", "data": "job: 33333333-3333-4333-8333-333333333333 is running, could not be deleted at this time."}], "meta": {"status": "job_running", "info": "33333333-3333-4333-8333-333333333333"}}
auth_snapshot_status=SUBMITTED
status_before_delete=RUNNING
delete_response={"time": "2026-09-28 11:52:06.346833", "data": [{"type": "string", "data": "Job 11111111-1111-4111-8111-111111111111 deleted. Submit records marked deleted: 0."}, {"type": "success", "data": ""}], "meta": {"status": "ok", "info": "", "job_id": "11111111-1111-4111-8111-111111111111", "submit_records_marked_deleted": 0}}
status_after_delete=None
completion_error_count=3
first_completion_error=Failed to publish finished status for job (11111111-1111-4111-8111-111111111111): StorageException: object jobs/11111111-1111-4111-8111-111111111111 does not exist
runner_running_jobs=['11111111-1111-4111-8111-111111111111']
scheduler_scheduled_jobs=['11111111-1111-4111-8111-111111111111']
j2_status=SUBMITTED
started_jobs=['11111111-1111-4111-8111-111111111111']
job_completed_events_for_j1=[]
job_aborted_events_for_j1=[]
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. The stale state is reached by the real `authorize_job` then runner start then `delete_job` sequence; only timing is controlled.
2. Level 2/3 precondition: not applicable.
3. Real consumer/caller observing wrong outcome: `DefaultJobScheduler._exceed_max_jobs` at `nvflare/app_common/job_schedulers/job_scheduler.py:263` blocks `j2`, which remains `SUBMITTED`.
4. Permanent or masked: permanent in the live process. The missing store object makes completion retry fail before lifecycle release; no downstream reconciliation removed the slot.

Persistent proposal was repaired and validated: `{"id":"MC-12","status":"REPRODUCED","valid":true}`.

## Recommendation
Re-read the live job/status inside `delete_job` immediately before deletion and reject if current status is `DISPATCHED` or `RUNNING`. Add a regression test for authorize-while-`SUBMITTED`, start-to-`RUNNING`, then confirmed delete execution, including scheduler slot retention.

---

## Entry 13: Accepted noncanonical min_clients can repeatedly starve a later eligible job

- **Finding ID**: MC-13
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-13/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/job_meta_validator.py:240

## Description
Confirmed. `JobMetaValidator` accepts `"min_clients": "1"` by converting it only for validation, but returns metadata with the original string. `SimpleJobDefManager` persists and reloads that metadata, `job_from_meta` preserves the string as `Job.min_sites`, and the scheduler then raises `TypeError` before trying later jobs.

## Trigger scenario
A valid uploaded job archive contains `"min_clients": "1"` and is submitted before a later valid job. Both are `SUBMITTED`, one client is online, and the later job is eligible. Each scheduler scan hits the older malformed job first, aborts candidate processing, and leaves the later job `SUBMITTED`.

## Developer intent
`MIN_CLIENTS` is treated as a dedicated validated constructor field, and `Job.__init__` annotates `min_sites` as `int`. The validator’s conversion helper also shows numeric normalization is intended, but the converted value is not stored back into `meta`.

## Reproduction result
Executed with timeout:

```text
MC-13 reproduction: numeric-string min_clients can starve a later eligible job
source_root=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-13/worktree
validator accepted numeric-string min_clients: type=str value='1'
job_def_manager/job_from_meta preserved min_sites: type=str value='1'
submitted_jobs_from_manager=['bad-oldest', 'good-later']
attempt=1 ready_job=None dispatch_info=None exceptions=1 exception_type=TypeError resource_checks=[] store_meta_updates=[] bad_schedule_count=0 good_schedule_count=0 good_status='SUBMITTED'
attempt=2 ready_job=None dispatch_info=None exceptions=2 exception_type=TypeError resource_checks=[] store_meta_updates=[] bad_schedule_count=0 good_schedule_count=0 good_status='SUBMITTED'
control_int_min_clients: ready_job='int-oldest' dispatch_sites=['server', 'site-1'] exceptions=0 resource_checks=[('int-oldest', ['site-1'])] schedule_count=1 store_meta_updates=[]
control_later_job_without_bad_oldest: ready_job='good-later-alone' dispatch_sites=['server', 'site-1'] exceptions=0 resource_checks=[('good-later-alone', ['site-1'])] schedule_count=1
BUG_REPRODUCED: older accepted string min_clients job aborts each scheduler scan before later eligible job
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. The repro uses real validator, real job manager create/scan, and real scheduler; only storage/engine surroundings are minimal harness components.
2. Level 2/3 used? **N/A**.
3. Real consumer/caller observing wrong outcome: `nvflare/private/fed/server/job_runner.py:656`; with `(None, None)`, deployment/status update at `job_runner.py:660-670` is skipped.
4. Bad state permanence/masking: not self-resolving under normal scheduler scans. Retry history and store metadata remain unchanged, so the same oldest job repeats until external removal or correction; no downstream mechanism masks it.

## Recommendation
Normalize `min_clients` back into metadata during validation, or defensively coerce/reject it in `job_from_meta` before constructing `Job.min_sites`. Add a regression for an accepted numeric-string older job followed by a later eligible submitted job.

---

## Entry 14: Malformed job metadata variants can block later jobs beyond the modeled numeric-string case

- **Finding ID**: CR-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/job_meta_validator.py:240

## Description

Confirmed. The remaining acceptance blocker was the persistent `issue.json` schema, not the CR-4 verdict. I fixed the proposal to include the required `cause`/persistent-finding fields, added the saved repro output as evidence, and validated it with the framework validator: `VALID / CR-4 REPRODUCED code-review`.

`JobMetaValidator` accepts malformed public job ZIP metadata variants, `job_from_meta` preserves the raw values, and `DefaultJobScheduler` later raises while scheduling the earlier malformed job. The bad job stays `SUBMITTED`, later valid jobs are not considered, and the same outcome repeats on later passes.

## Trigger scenario

Submit a malformed public job ZIP before a valid ZIP. Reproduced variants: `min_clients: null`, `min_clients: "2"`, and `resource_spec: {"site-1": {"process": "x"}}`.

Reachable sequence: uploaded ZIP through `submit_job` -> `JobMetaValidator.validate` at `job_cmds.py:1586` -> `job_def_manager.create` at `job_cmds.py:1665` -> `JobRunner.run` calls `schedule_job` at `job_runner.py:650`.

## Developer intent

The scheduler test at `tests/unit_test/app_common/job_schedulers/job_scheduler_test.py:455` asserts malformed metadata should not interrupt scheduling of a later valid job. It expects the bad job to become `FINISHED_CANT_SCHEDULE` and the later valid job to schedule. These variants miss that recovery path.

## Reproduction result

Escalation level reached: Level 2 component harness with real public job ZIPs and real validator/job-store/scheduler components; no source patch.

Command executed:

```bash
timeout 2m python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-4_malformed_metadata.py
```

Output:

```text
nvflare_import=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-4/worktree/nvflare/__init__.py
validator good_control: valid=True error='' min_clients=1 resource_spec={}

CASE good_control
observations=[{"candidates": ["good-control"], "dispatch_sites": ["server", "site-1", "site-2"], "pass": 0, "scheduled": "good-control"}]
validator bad_null-min-clients: valid=True error='' min_clients=None resource_spec={}
validator good_null-min-clients: valid=True error='' min_clients=1 resource_spec={}

CASE null-min-clients
observations=[{"candidates": ["bad-null-min-clients", "good-after-null-min-clients"], "dispatch_sites": [], "pass": 0, "scheduled": null}, {"candidates": ["bad-null-min-clients", "good-after-null-min-clients"], "dispatch_sites": [], "pass": 1, "scheduled": null}, {"candidates": ["bad-null-min-clients", "good-after-null-min-clients"], "dispatch_sites": [], "pass": 2, "scheduled": null}]
state={"bad_schedule_count": null, "bad_status": "SUBMITTED", "cancel_calls": 0, "check_calls_by_job": {"bad-null-min-clients": 3}, "good_schedule_count": null, "good_status": "SUBMITTED", "reservations_by_job": {"bad-null-min-clients": 6}, "uncancelled_tokens": 6}
validator bad_string-min-clients: valid=True error='' min_clients='2' resource_spec={}
validator good_string-min-clients: valid=True error='' min_clients=1 resource_spec={}

CASE string-min-clients
observations=[{"candidates": ["bad-string-min-clients", "good-after-string-min-clients"], "dispatch_sites": [], "pass": 0, "scheduled": null}, {"candidates": ["bad-string-min-clients", "good-after-string-min-clients"], "dispatch_sites": [], "pass": 1, "scheduled": null}]
state={"bad_schedule_count": null, "bad_status": "SUBMITTED", "cancel_calls": 0, "check_calls_by_job": {}, "good_schedule_count": null, "good_status": "SUBMITTED", "reservations_by_job": {}, "uncancelled_tokens": 0}
validator bad_legacy-process-string: valid=True error='' min_clients=1 resource_spec={'site-1': {'process': 'x'}}
validator good_legacy-process-string: valid=True error='' min_clients=1 resource_spec={}

CASE legacy-process-string
observations=[{"candidates": ["bad-legacy-process-string", "good-after-legacy-process-string"], "dispatch_sites": [], "pass": 0, "scheduled": null}, {"candidates": ["bad-legacy-process-string", "good-after-legacy-process-string"], "dispatch_sites": [], "pass": 1, "scheduled": null}]
state={"bad_schedule_count": null, "bad_status": "SUBMITTED", "cancel_calls": 0, "check_calls_by_job": {}, "good_schedule_count": null, "good_status": "SUBMITTED", "reservations_by_job": {}, "uncancelled_tokens": 0}

LOG_EXCERPT
[identity=server, run=cr4-repro]: error scheduling job
TypeError: '<' not supported between instances of 'int' and 'NoneType'
[identity=server, run=cr4-repro]: error scheduling job
TypeError: '<' not supported between instances of 'int' and 'NoneType'
[identity=server, run=cr4-repro]: error scheduling job
TypeError: '<' not supported between instances of 'int' and 'NoneType'
[identity=server, run=cr4-repro]: error scheduling job
TypeError: '<' not supported between instances of 'int' and 'str'
[identity=server, run=cr4-repro]: error scheduling job
TypeError: '<' not supported between instances of 'int' and 'str'
[identity=server, run=cr4-repro]: error scheduling job
ValueError: dictionary update sequence element #0 has length 1; 2 is required
[identity=server, run=cr4-repro]: error scheduling job
ValueError: dictionary update sequence element #0 has length 1; 2 is required

RESULT: PASS CR-4 reproduced: malformed validated ZIP metadata blocks later valid jobs; good control scheduled good-control.
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? no.
2. The Level 2 precondition is reachable by the real API sequence above: public job ZIP submission -> validator accepts metadata -> job record is created -> `JobRunner.run` calls the scheduler.
3. Real consumer/caller: `JobRunner.run` at `nvflare/private/fed/server/job_runner.py:650` receives no scheduled job, so the later valid job is not deployed.
4. Permanent or masked: persistent until manual operator action removes or aborts the malformed job. No downstream scheduler guard/backoff/status transition resolves it; client-side expiry may later release the null-case reservations, but it does not unblock scheduling.

## Recommendation

Reject or normalize `min_clients` during validation, including `null` and numeric strings, and type-check nested legacy `resource_spec.process` values before job creation. Also harden scheduler exception handling so malformed candidates are marked unschedulable and any reservations made before failure are canceled.

---

## Entry 15: Live dictionary iteration disrupts lifecycle services

- **Finding ID**: CR-6
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-6/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `nvflare/private/fed/server/fed_server.py:309`, `nvflare/private/fed/server/fed_server.py:1113`, `nvflare/private/fed/server/job_runner.py:856`, `nvflare/private/fed/server/training_cmds.py:164`

## Description
CR-6 is confirmed. Multiple lifecycle paths iterate live dictionaries while ordinary lifecycle callbacks can mutate those same dictionaries. The reproduced effects are cleanup-thread termination, stale-token crash, failed dead-client notification, incomplete `stop_all_runs`, and failed admin shutdown iteration.

## Trigger scenario
The reachable sequences are:

1. `FederatedServer.client_cleanup()` calls `remove_dead_clients()` over `ClientManager.clients`, while another logout path removes a client token.
2. `remove_dead_clients()` records a token as dead, then the token becomes stale before `logout_client()` calls `notify_dead_client(None)`.
3. `logout_client()` calls `notify_dead_client()` over `engine.run_processes`, while a job completion/removal mutates `run_processes`.
4. `ServerEngine.stop_all_jobs()` calls `JobRunner.stop_all_runs()`, and abort/completion removes a run during iteration.
5. `TrainingCommandModule.shutdown()` iterates `job_runner.running_jobs`, while job completion removes an entry.

## Developer intent
These lifecycle services are intended to tolerate normal overlap between cleanup, logout, job completion, shutdown, and admin commands. Nearby code already uses snapshot iteration in similar places, which supports the intent that these loops should not fail because the backing dictionaries changed mid-iteration.

## Reproduction result
Executed:

```bash
timeout 2m python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-6_live_dict_iteration.py
```

Output:

```text
remove_client: unknown token
SOURCE /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-6/worktree
NVFLARE /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-6/worktree/nvflare/__init__.py
{
  "cleanup_live_client_map": {
    "exception": "RuntimeError: dictionary changed size during iteration",
    "thread_alive_after_exception": false,
    "traceback_last": "RuntimeError: dictionary changed size during iteration"
  },
  "cleanup_stale_logout_token": {
    "exception": "AttributeError: 'NoneType' object has no attribute 'name'",
    "thread_alive_after_exception": false,
    "traceback_last": "AttributeError: 'NoneType' object has no attribute 'name'"
  },
  "notify_dead_client_live_run_processes": {
    "exception": "RuntimeError: dictionary changed size during iteration",
    "remaining_run_processes": [
      "job-1"
    ]
  },
  "stop_all_runs_live_run_processes": {
    "ask_to_stop": false,
    "exception": "RuntimeError: dictionary changed size during iteration",
    "remaining_run_processes": [
      "job-2"
    ],
    "run_aborted": {
      "job-1": true,
      "job-2": false
    }
  },
  "training_shutdown_running_jobs_iteration": {
    "exception": "RuntimeError: dictionary changed size during iteration",
    "remaining_running_jobs": [
      "job-1"
    ]
  }
}
BUG REPRODUCED: live dictionary iteration raises in lifecycle services
```

## Recommendation
Snapshot dictionary items/keys before lifecycle iteration and guard stale logout results before calling `notify_dead_client`. Apply this consistently across client cleanup, dead-client notification, `stop_all_runs`, and admin shutdown.

Checklist:
1. Did Level 0 or Level 1 alone trigger it? no.
2. Level 2 was used only to deterministically interleave reachable real sequences: cleanup/logout, logout/job-completion, stop-all/job-removal, and admin-shutdown/job-completion.
3. Real consumers observing wrong outcomes: `FederatedServer.client_cleanup`, `FederatedServer.logout_client`/`notify_dead_client`, `JobRunner.stop_all_runs`, and `TrainingCommandModule.shutdown`.
4. The bad state is not automatically masked: the cleanup thread terminates, `stop_all_runs` leaves a run un-aborted with `ask_to_stop` false, and the admin command fails rather than self-retrying.

---

## Entry 16: Fractional GPU accounting fails to restore eligible capacity

- **Finding ID**: CR-7
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-7/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/app_common/resource_managers/gpu_resource_manager.py:148

## Description
`GPUResourceManager` subtracts and restores fractional GiB requests with binary floats, then uses exact `>=` checks at `gpu_resource_manager.py:168` and `:191`. A normal allocate/free sequence can restore `1.0` GiB as `0.9999999999999999`, causing a later full-capacity request to be rejected.

## Trigger scenario
Using public resource-manager APIs only: configure one GPU with `1.0` GiB, allocate `0.1`, allocate `0.2`, free `0.2`, free `0.1`, then check a `1.0` GiB request. Fresh-capacity and exact-fraction controls both pass.

## Developer intent
NVFlare docs describe `check_resources`, `allocate_resources`, and `free_resources` as the normal scheduling lifecycle, and the scheduler assumes the resource manager’s answer. Local history shows float GPU memory was intentionally supported by `903567c7` / `#1073`. Upstream tracker and local history searches found no existing report/fix for this fractional restoration mechanism.

## Reproduction result
Executed `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-7_fractional_gpu_accounting.py`:

```text
{
  "bug_sequence": {
    "allocated": [
      {
        "0": 0.1
      },
      {
        "0": 0.2
      }
    ],
    "free_order": "reverse",
    "full_request_after_free_ok": false,
    "memory_after_final_check_repr": "0.9999999999999999",
    "restored_memory": 0.9999999999999999,
    "restored_memory_repr": "0.9999999999999999"
  },
  "exact_fraction_control": {
    "allocated": [
      {
        "0": 0.25
      },
      {
        "0": 0.5
      }
    ],
    "free_order": "reverse",
    "full_request_after_free_ok": true,
    "memory_after_final_check_repr": "1.0",
    "restored_memory": 1.0,
    "restored_memory_repr": "1.0"
  },
  "fresh_full_capacity_control": {
    "full_request_ok": true,
    "memory_after_cancel_repr": "1.0",
    "memory_after_check_repr": "0.0"
  },
  "nvflare_module": "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-7/worktree/nvflare/__init__.py",
  "same_values_fifo_control": {
    "allocated": [
      {
        "0": 0.1
      },
      {
        "0": 0.2
      }
    ],
    "free_order": "fifo",
    "full_request_after_free_ok": true,
    "memory_after_final_check_repr": "1.0",
    "restored_memory": 1.0,
    "restored_memory_repr": "1.0"
  },
  "source_root": "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-7/worktree"
}
BUG_TRIGGERED: after public check/allocate/free of 0.1 GiB and 0.2 GiB on a 1.0 GiB GPUResourceManager, reverse free order leaves memory 0.9999999999999999 and rejects a later 1.0 GiB request.
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? yes, Level 0 public API calls.
2. Level 2/3 used? no.
3. Real consumer/caller: `nvflare/private/fed/client/scheduler_cmds.py:83` returns the false resource answer; `nvflare/app_common/job_schedulers/job_scheduler.py:212` and `:229` can treat the site as not enough resource.
4. Permanent or masked? Permanent until restart/manual correction; no timeout or scheduler loop clamps the freed float back to `1.0`.

Persistent record validation also passed: `{"id":"CR-7","status":"REPRODUCED","valid":true}`.

## Recommendation
Store GPU memory in exact fixed units, such as MiB/bytes as integers, or normalize/clamp restored capacity to configured capacity before exact eligibility checks. Add a regression test for fractional allocate/free round-trips with same-capacity controls.

---

## Entry 17: Parent death leaves a child in notification retry

- **Finding ID**: CR-9
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-9/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/client/client_app_runner.py:171

## Description
`ClientAppRunner.notify_job_status` does not honor `retry_timeout`: after the timeout it only logs, then retries forever without sleeping. When the CP dies during CJ bootstrap, `monitor_parent_process` calls `ClientAppRunner.stop()`, but `stop()` only aborts `client_runner` and does not interrupt the active notification loop.

## Trigger scenario
A CP launches a CJ, the CJ enters the STARTED notification path, then the CP process exits before the notification succeeds. The CJ survives because local jobs are launched in a separate process/session, observes parent death, calls `stop()`, and still remains in the retry loop.

## Developer intent
The local docstring says the STARTED notification should retry until success “or the retry_timeout has been reached.” Upstream issue/PR and git-history searches found no existing report for this exact parent-death plus notification-retry mechanism.

## Reproduction result
Executed: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-9_parent_death_retry.py`

```json
{
  "child_pid_observed": 3051786,
  "child_survived_parent_death_during_retry": true,
  "control": {
    "captured_parent_pid": 3051765,
    "child_pid": 3051786,
    "control_notify_secs": 0.007,
    "monitor_abort_calls": 0,
    "phase": "control_done"
  },
  "final": {
    "attempts_1_4s_to_3_4s": 7726,
    "attempts_after_1_4s": 1281,
    "attempts_after_3_4s": 9007,
    "distinct_return_codes": ["comm_error"],
    "monitor_abort_calls": 1,
    "notify_returned_after_parent_death": false,
    "parent_pid_alive_when_retry_started": false,
    "retry_elapsed_secs": 3.401
  }
}
BUG_REPRODUCED: child notification retry continued after parent death and ClientAppRunner.stop().
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**.
2. Level 2/3 were not used.
3. Real caller observing wrong outcome: `worker_process.py:126` via `ClientAppRunner.start_run`; parent-death cleanup caller is `app/utils.py:45`.
4. The bad state is permanent until external kill; no CP heartbeat or restarted CP state can resolve the orphaned CJ.

## Recommendation
Make `notify_job_status` return or raise once `retry_timeout` is reached, and/or have `ClientAppRunner.stop()` set a stop flag checked by the retry loop before each send.

---

## Entry 18: Disable leaves pending outcomes and slots until the grace expires

- **Finding ID**: CR-10
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-10/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `nvflare/private/fed/server/server_engine.py:620`

## Description
Confirmed. `ServerEngine.disable_clients` removes active client sessions and admin bookkeeping, but it does not invoke the federated server’s dead-client outcome resolver. If the server-side job finishes while that disabled client still has a pending terminal outcome, `JobRunner._job_complete_process` waits until `client_outcome_wait_timeout` before publishing terminal status.

That delay is externally visible: `DefaultJobScheduler._exceed_max_jobs` continues counting the finished job against `max_jobs`.

## Trigger scenario
A job starts with `site-1`, creating `_pending_client_outcomes`. Before `site-1` reports its terminal outcome, an admin disables `site-1`. The token is removed, later terminal reports from that token are rejected as unauthenticated, and disabled heartbeat/reconnect paths cannot clear the pending outcome.

## Developer intent
The normal dead-client path calls `FederatedServer.notify_dead_client`, which resolves pending outcomes immediately. Disable-client documentation describes removing/blocking the active client identity, not holding completed jobs open. Local history plus upstream issue/PR metadata searches found no same-mechanism report or fix, so novelty remains `NEW`.

## Reproduction result
Executed with timeout:

```text
timeout 2m python /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-10_disable_pending_outcome.py
```

Output:

```text
Dropped unauthenticated Job Failure report from site-1
Timed out after 2.0 seconds waiting for client outcomes for job (job-cr10): ['site-1']. Finalizing from the server outcome.
source=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-10/worktree
level=2 reachable-state harness; product admin, job-runner, scheduler, and outcome handlers are real
reachable_sequence=JobRunner.run->_start_run creates _pending_client_outcomes; JOB_STARTED fills DefaultJobScheduler.scheduled_jobs; run() records running_jobs
pending_after_start=['site-1']
scheduled_jobs_after_start=['job-cr10']
disable_command_records=[('dict', {'clients': [{'client_name': 'site-1', 'state': 'disabled', 'already_disabled': False, 'active_session_removed': True, 'credential_revoked': False, 'rejoin_allowed': False}]})]
removed_client_data=['token-site-1']
admin_dead_tokens=['token-site-1']
authorized_after_disable=False
disabled_after_disable=True
pending_after_disable=['site-1']
disabled_old_token_terminal_report_return_code=unauthenticated
pending_after_rejected_terminal_report=['site-1']
first_completion_pass_status_updates=[]
outcome_deadline=2.0
slot_full_before_deadline=True
scheduled_jobs_before_deadline=['job-cr10']
timeout_completion_status_updates=[('job-cr10', 'FINISHED:COMPLETED')]
slot_full_after_deadline=False
scheduled_jobs_after_deadline=[]
pending_after_deadline=None
dead_client_control_pending_after_notify=[]
RESULT: BUG REPRODUCED
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 reachable precondition: `JobRunner.run -> _start_run` creates pending outcomes and fires `JOB_STARTED`; `JobRunner.run` records `running_jobs`; then the real admin command `TrainingCommandModule.disable_client -> ServerEngine.disable_clients` removes the active token.
3. Real consumer/caller observing wrong outcome: `DefaultJobScheduler._exceed_max_jobs` at `nvflare/app_common/job_schedulers/job_scheduler.py:263` returns true while the finished job is still counted.
4. The bad state is not permanent. `JobRunner._job_complete_process` resolves it after `client_outcome_wait_timeout`, but the scheduler-visible admission delay already occurs during that grace window.

## Recommendation
When `disable_clients` removes an active session, resolve pending outcomes through the same semantic path used for dead clients while preserving the disabled-client reconnect policy. Add a regression test covering disable during a finished server job with pending client outcome and `max_jobs=1`.

---

## Entry 19: Overlapping resource consumption changes another job's launch environment

- **Finding ID**: CR-11
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-11/debate.md

- **Source**: Code Review
- **Novelty**: NEW (permitted git-history/in-tree search found related GPU/launcher commits, but no exact prior report/fix for this overlap mechanism; external issue/PR discussion search was prohibited by the continuation instructions)
- **Location**: nvflare/app_common/resource_consumers/gpu_resource_consumer.py:33

## Description
Confirmed. `GPUResourceConsumer.consume` writes `CUDA_VISIBLE_DEVICES` into the long-lived client parent process environment, and `ProcessJobLauncher.launch_job` later copies `os.environ` for the child. The resource manager lock protects allocation bookkeeping, but not the consume-to-launch interval.

## Trigger scenario
Two START handlers overlap on a process-mode client with distinct GPU reservations. Job A consumes GPU 0, then pauses before child launch. Job B consumes GPU 1, overwriting the parent environment. When Job A resumes, its child inherits `CUDA_VISIBLE_DEVICES=1` despite being allocated GPU 0.

## Developer intent
The docs state the resource consumer sets `CUDA_VISIBLE_DEVICES` so concurrent jobs use different GPU devices. Process mode is documented as `ProcessJobLauncher` + `GPUResourceManager` + `GPUResourceConsumer`, relying on subprocess inheritance.

## Reproduction result
Checklist:
1. Level 0 or Level 1 alone triggered it: **yes**. Level 1 timing assistance triggered the overlap; Level 2/3 source/state patching was not used. The GPU-host stub only emulates a reachable two-GPU client on this non-GPU host.
2. N/A for the lifecycle race. Real API sequence: `CHECK_RESOURCE(job-A)`, `CHECK_RESOURCE(job-B)`, `START_JOB(job-A)`, overlapping `START_JOB(job-B)`.
3. Real observer: `ProcessJobLauncher.launch_job` copies the wrong env at `nvflare/app_common/job_launcher/process_launcher.py:68` and spawns at `:81`; normal executor path reaches this at `nvflare/private/fed/client/client_executor.py:309`.
4. Permanent for that child process environment; no downstream guard/resync masks or repairs it.

Executed `repro/test_bugCR-11_cuda_env_overlap.py`:

```text
SOURCE_IMPORT=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-11/worktree/nvflare/__init__.py
GPU_HOST_STUB=ids:[0,1] free_mib:[16384,16384]
LEVEL0 normal concurrent start: job-A allocated=0 child_cuda=0; job-B allocated=1 child_cuda=1; mismatch=False
LEVEL1 timing-assisted overlap: job-A allocated=0 child_cuda=1; job-B allocated=1 child_cuda=1; job-A_mismatch=True; job-B_matches=True
CONSUMER_RECORDS=[{"cuda":"0","resources":[0]},{"cuda":"1","resources":[1]}]
BUG TRIGGERED: job-A inherited job-B CUDA_VISIBLE_DEVICES through ProcessJobLauncher
ESCALATION: Level 1 timing assistance only; Level 2/3 not used
```

Wrote and validated `confirmation/CR-11/issue.json` via the persistent-finding validator: `{"id":"CR-11","status":"REPRODUCED","valid":true}`.

## Recommendation
Do not use process-global `os.environ` as the per-job GPU binding handoff. Build a per-job launch environment from `allocated_resources` and pass it directly to the launcher/spawn call, or serialize consume-to-launch and restore/verify the environment before spawning.

---

## Entry 20: Later empty-resource jobs inherit a stale device binding

- **Finding ID**: CR-12
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-12/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `nvflare/private/fed/client/scheduler_cmds.py:119`

## Description
Confirmed. `StartJobProcessor` skips `resource_consumer.consume(...)` when the allocated resources are `{}`, so a later zero/empty-GPU job does not clear the client parent’s previous `CUDA_VISIBLE_DEVICES`. `ProcessJobLauncher` then copies the stale parent environment into the later child process at `process_launcher.py:68`.

## Trigger scenario
A client runs a process-mode GPU job, which calls `GPUResourceConsumer.consume` and sets `CUDA_VISIBLE_DEVICES=0`. After that job exits and its GPU resources are freed, a later job with `num_of_gpus: 0` resolves to `{}` and starts without invoking the consumer, so its child process inherits `CUDA_VISIBLE_DEVICES=0`.

## Developer intent
Docs say the resource consumer sets `CUDA_VISIBLE_DEVICES` so concurrent jobs use different GPU devices. `GPUResourceConsumer.consume({})` itself sets the variable to `""`, but the real START_JOB path skips that call for `{}` allocations. GitHub issue/PR search and pinned git history found no prior report for this exact mechanism.

## Reproduction result
Executed:
`timeout 120s python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-12_stale_cuda_env.py`

```text
CR-12 reproduction output
{
  "empty_consume_control": "",
  "gpu_job": {
    "child": {
      "CUDA_VISIBLE_DEVICES": "0",
      "pid": 3109460
    },
    "parent_env_after": "0",
    "rm_spec": {
      "mem_per_gpu_in_GiB": 16,
      "num_of_gpus": 1
    },
    "start_reply": "Start the client app..."
  },
  "hardware_probe_stub": "2 GPUs, 16 GiB each",
  "resource_report_after": {
    "reserved_resources": {},
    "resources": [
      {
        "gpu_id": 0,
        "memory": 16
      },
      {
        "gpu_id": 1,
        "memory": 16
      }
    ]
  },
  "zero_after": {
    "child": {
      "CUDA_VISIBLE_DEVICES": "0",
      "pid": 3109462
    },
    "parent_env_after": "0",
    "rm_spec": {},
    "start_reply": "Start the client app..."
  },
  "zero_before": {
    "child": {
      "CUDA_VISIBLE_DEVICES": "<unset>",
      "pid": 3109458
    },
    "parent_env_after": "<unset>",
    "rm_spec": {},
    "start_reply": "Start the client app..."
  }
}
RESULT: REPRODUCED - later zero/empty-allocation job inherited stale CUDA_VISIBLE_DEVICES=0
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**. The host has no GPUs, so the repro used Level 2 hardware-edge injection for the GPU probe only.
2. Reachable sequence: real `CHECK_RESOURCE` + `START_JOB` for a positive GPU job, wait for child exit/free, then real `CHECK_RESOURCE` + `START_JOB` for `num_of_gpus: 0`, which resolves to `{}`.
3. Real consumer/caller observing wrong outcome: the child process launched by `ProcessJobLauncher.launch_job` after `os.environ.copy()` at `process_launcher.py:68`.
4. Bad state is not automatically masked. It persists in the client parent until another non-empty GPU allocation overwrites it, the parent restarts, or something externally clears it.

## Recommendation
Clear or scope `CUDA_VISIBLE_DEVICES` per launch. The narrow fix is to invoke the resource consumer for empty allocations too, or explicitly pass a per-job environment to the process launcher instead of mutating and reusing the client parent environment.

---

## Entry 21: Best-effort SJ status arrival loses an execution error

- **Finding ID**: CR-14
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-14/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/server_engine.py:203

## Description
`ServerEngine.wait_for_complete()` waits only 2 seconds for `UPDATE_RUN_STATUS`, then pops `run_processes[job_id]`. The SJ sends that status via `fire_and_forget`; if `execution_error=True` arrives after the pop, `fed_server._listen_command()` returns OK but records nothing because the run entry is gone. `JobRunner` then publishes `FINISHED:COMPLETED` instead of `FINISHED:EXECUTION_EXCEPTION`.

## Trigger scenario
A server job reaches `FATAL_SYSTEM_ERROR`, shuts down with process return code 0, and its `UPDATE_RUN_STATUS(execution_error=True)` delivery is delayed beyond the parent’s 2 second wait. The injected precondition is reachable via: `JobRunner._start_run()` -> `ServerEngine.start_app_on_server()` / `_start_runner_process()` inserts `run_processes[job]` and starts `wait_for_complete`; `ServerAppRunner.finally` sends `UPDATE_RUN_STATUS`.

## Developer intent
Nearby comments show the parent intends to wait for `UPDATE_RUN_STATUS`, but only for a bounded 2 seconds. Prior PR/history search found related status fixes (#4552, #4633, #5047, #5072), but no upstream issue or PR for this exact late best-effort `UPDATE_RUN_STATUS(execution_error=True)` loss.

## Reproduction result
Test: `repro/test_bugCR-14_late_update_run_status.py`

Command:
```bash
timeout 5m /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-14_late_update_run_status.py
```

Output:
```text
CR-14 late UPDATE_RUN_STATUS reproduction
nvflare_source=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-14/worktree
reachable_precondition=JobRunner._start_run -> ServerEngine.start_app_on_server/_start_runner_process inserts run_processes[job] and starts wait_for_complete; ServerAppRunner.finally sends UPDATE_RUN_STATUS.
RESULT case=on-time-control delayed=False wait_called=True run_process_present_after_wait=False exception_entry_after_wait=True exe_error_recorded=True process_finished_recorded=True late_reply=None published_status=FINISHED:EXECUTION_EXCEPTION
RESULT case=delayed-status delayed=True wait_called=True run_process_present_after_wait=False exception_entry_after_wait=False exe_error_recorded=False process_finished_recorded=False late_reply=ok published_status=FINISHED:COMPLETED
BUG_TRIGGERED late execution_error=True arrived after run_processes pop; handler returned OK but recorded no exception entry; completion published FINISHED:COMPLETED
```

## Recommendation
Make the execution-error status delivery reliable or preserve a terminal status record after `run_processes` is popped. A narrow fix would record late `UPDATE_RUN_STATUS(execution_error=True)` into `exception_run_processes` or another completion-owned terminal-status channel before publication.

## Checklist
1. Did Level 0 or Level 1 alone trigger it? **no**. This used Level 2 state injection for the already-started SJ state.
2. Reachable sequence: `JobRunner._start_run()` starts the server app; `ServerEngine._start_runner_process()` inserts `run_processes[job_id]` at `server_engine.py:321` and starts `wait_for_complete` at `server_engine.py:328`; `ServerAppRunner.finally` calls `update_job_run_status()` at `server_app_runner.py:89`.
3. Real consumer/caller: `JobRunner._job_complete_process()` publishes the wrong status via `job_manager.set_status()` at `nvflare/private/fed/server/job_runner.py:524`; status readers consume the persisted job meta.
4. Bad state permanence: **permanent**. The late handler returns OK but records no exception entry, and no downstream sync/resend/guard revisits the terminal status after publication.

---

## Entry 22: Ordinary local restart leaves persisted lifecycle state inconsistent

- **Finding ID**: CR-15
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-15/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/job_runner.py:779

## Description
Continued from the existing CR-15 work. I preserved the completed investigation/repro, corrected the stale dependency paths in the persistent `issue.json`, removed the stray verdict line from `investigation.md`, reran the repro, and validated the proposal: `VALID CR-15 REPRODUCED code-review`.

The bug remains confirmed: ordinary local restart can preserve a persisted `RUNNING` job while the fresh parent has empty process tables. `update_unfinished_jobs()` would reconcile it to `FINISHED:ABANDONED`, but ordinary startup does not call it.

## Trigger scenario
Checklist before `REPRODUCED`:

1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 was used only to seed a reachable persisted precondition: submit job -> scheduler writes `DISPATCHED`/`RUNNING` -> admin `abort_job` on `RUNNING` calls `JobRunner.stop_run` -> `shutdown server` is allowed because `job.run_aborted=True` -> `FederatedServer.fl_shutdown` calls `engine.stop_all_jobs` / `JobRunner.stop_all_runs` -> parent restarts with empty process tables and the same persisted store.
3. Real consumers observe the wrong outcome: `JobRunner.mark_run_aborted` at `nvflare/private/fed/server/job_runner.py:802` via `abort_job` at `nvflare/private/fed/server/job_cmds.py:1072`; `delete_job` rejects the stale `RUNNING` at `job_cmds.py:516`; CLI wait treats `RUNNING` as non-terminal via `nvflare/tool/job/job_cli.py:1926`.
4. The bad state is permanent across fresh parent startup unless an operator or new code path manually invokes reconciliation. The repro control shows `update_unfinished_jobs()` fixes it, but `external_reconciliation_callers=0`.

## Developer intent
Docs expose ordinary server shutdown/restart, and job CLI docs treat `ABANDONED` / `FINISHED:ABANDONED` as terminal. Git/PR history shows older related lifecycle work, including `9e1881da` and HA removal in `4e090892baa795362dca6ea6d142224d7778ec78`, but no current report or fix for this exact no-caller restart reconciliation mechanism.

## Reproduction result
Command executed:

```bash
timeout 120s python /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-15_restart_stale_running.py | tee /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-15_restart_stale_running.log
```

Output:

```text
source_commit=53ba7ee567468ea7971dad4faccef13c6cb35dc2
level=2_state_injection_with_reachable_precondition
reachable_sequence=submit job -> scheduler writes DISPATCHED/RUNNING -> admin abort_job on RUNNING job calls JobRunner.stop_run -> shutdown server is allowed because job.run_aborted=True -> FederatedServer.fl_shutdown calls engine.stop_all_jobs/JobRunner.stop_all_runs -> parent restarts with empty run_processes/running_jobs and same persisted store
external_reconciliation_callers=0
job_id=232642e4-0515-4825-9120-cb974c0035b3
abort_msg_before_shutdown=''
run_aborted_before_shutdown=True
status_after_shutdown=RUNNING
fresh_parent_run_processes=[]
fresh_parent_running_jobs=[]
status_after_fresh_parent_start=RUNNING
abort_after_restart_msg='Job 232642e4-0515-4825-9120-cb974c0035b3 is not running.'
delete_guard_would_reject_running=True
cli_wait_sees_terminal=False
jobs_by_running_or_dispatched_after_restart=['232642e4-0515-4825-9120-cb974c0035b3']
manual_helper_control_before=RUNNING
manual_helper_control_after=FINISHED:ABANDONED
RESULT=BUG_REPRODUCED
```

## Recommendation
Invoke unfinished-job reconciliation during ordinary local server startup before accepting job admin operations, or persist a terminal status before shutdown loses the in-memory runner tables. Add a regression test for aborted running job -> shutdown -> local restart -> status/delete/wait behavior.

---

## Entry 23: Cleanup pop races the waiter's return-code observation

- **Finding ID**: CR-16
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-16/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/server_engine.py:205

## Description
`ServerEngine.wait_for_complete()` only records a non-zero server-job process return code if `run_processes[job_id]` is still present when it reads it. Concurrent abort cleanup in `_remove_run_processes()` can terminate the same real local process handle and pop that entry first, so `JobRunner` later sees no exception record and can publish `FINISHED:COMPLETED` for the same non-zero exit.

## Trigger scenario
A server job is launched through the local process path, creating the normal `run_processes` entry and waiter thread. During the start window, a client terminal outcome such as `UNSAFE_COMPONENT` can call `JobRunner.stop_run()` before `running_jobs` insertion, causing `_stop_run()` -> `abort_app_on_server()` -> `_remove_run_processes()` to race the waiter’s return-code recording.

## Developer intent
Local tests show the intended pieces separately: non-zero server-job return codes should be recorded for completion classification, and cleanup should terminate/popup launcher-managed handles. I found no local git-history/test evidence, within the permitted search scope, reporting this exact cleanup-pop-before-waiter-read mechanism.

## Reproduction result
Test executed: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-16_cleanup_return_code_race.py`

Command:
```bash
timeout 2m python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-16_cleanup_return_code_race.py
```

Output:
```text
INFO:nvflare.utils.process_utils:Launch the job in process ID: 1566399 (posix_spawn)
INFO:cr16.engine:Abort the server app run.
INFO:nvflare.utils.process_utils:Launch the job in process ID: 1566401 (posix_spawn)
INFO:cr16.engine:Abort the server app run.
INFO:cr16.engine:Job: cr16-job child process exit with return code 1
LEVEL 2 state injection: normal post-_start_runner_process run_processes entry
Real reachable sequence: _start_runner_process records run_processes and starts wait_for_complete;
then JobRunner._stop_run/ServerEngine.abort_app_on_server starts cleanup after an abort/stop signal.
{
  "cleanup_first": {
    "case": "cleanup_popped_before_waiter_read",
    "completion_thread_classification": "FINISHED:COMPLETED",
    "exception_recorded": false,
    "mapped_job_return_code": "1",
    "raw_process_return_code": 1,
    "recorded_process_return_code": null,
    "run_processes_contains_job": false
  },
  "waiter_first": {
    "case": "waiter_read_before_cleanup_pop",
    "completion_thread_classification": "FINISHED:EXECUTION_EXCEPTION",
    "exception_recorded": true,
    "mapped_job_return_code": "1",
    "raw_process_return_code": 1,
    "recorded_process_return_code": "1",
    "run_processes_contains_job": false
  }
}
CR16_REPRODUCED: same real non-zero local-process exit is COMPLETED or EXECUTION_EXCEPTION depending on cleanup/read ordering
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? no.
2. Level 2 was used. The injected state is reachable via `_start_runner_process()` creating `run_processes` and starting `wait_for_complete`, then a start-window `UNSAFE_COMPONENT` outcome driving `JobRunner.stop_run()` -> `_stop_run()` -> `abort_app_on_server()`.
3. Real consumer/caller: `JobRunner._job_complete_process()` publishes the status at `nvflare/private/fed/server/job_runner.py:523`, using `_get_finished_job_status()` / `_classify_finished_job_status()` at `job_runner.py:543`.
4. The bad terminal classification is permanent for this start-window path; the normal `job.run_aborted` and `fail_run()` masks apply to other paths, but not before `running_jobs` insertion.

## Recommendation
Serialize or otherwise coordinate cleanup and waiter return-code recording so `_remove_run_processes()` cannot remove the only return-code observation point before `wait_for_complete()` records a non-zero exit. The start-window stop path should also get an authoritative terminal failure/abort marker before cleanup begins.

---

## Entry 24: Unsafe client failure during startup does not mark the job aborted

- **Finding ID**: CR-17
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-17/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `nvflare/private/fed/server/fed_server.py:952`

## Description
Confirmed. `UNSAFE_COMPONENT` client terminal reports are routed through `job_runner.stop_run(...)`, not `fail_run(...)`. During startup, `stop_run` can abort the server job while `mark_run_aborted` is still a no-op because the job has not yet been inserted into `running_jobs`; the completion loop later records `FINISHED:COMPLETED`.

## Trigger scenario
A client reports `UNSAFE_COMPONENT` after `_start_run` has started the server job and registered pending client outcomes, but before `JobRunner.run` inserts the job into `running_jobs`. The server aborts the run, misses the abort marker, then finalizes the cleanly-aborted server process as completed.

## Developer intent
Tests confirm the current intended split: `UNSAFE_COMPONENT` calls `stop_run`, while ordinary failures call `fail_run`. Comments in `fail_run` state it records an authoritative terminal failure. Local git-history search found related abort/failure-status PRs, but no prior report for this exact unsafe-startup marker miss.

## Reproduction result
Reproducer: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-17_unsafe_startup.py`

Command:
```bash
timeout 45s python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-17_unsafe_startup.py
```

Output:
```text
WARNING:nvflare.private.fed.server.job_runner.JobRunner:[identity=server, run=?]: Skipping unavailable workspace archive source for job job-cr17: /tmp/cr17-nvflare-8xe56ezu/job-cr17
WARNING:nvflare.private.fed.server.job_runner.JobRunner:[identity=server, run=?]: No workspace archive sources are available for finished job job-cr17
{
  "expected_status": "FINISHED:ABORTED",
  "final_status": "FINISHED:COMPLETED",
  "level": 1,
  "server_abort_calls": ["job-cr17"],
  "status_history": ["DISPATCHED", "RUNNING", "FINISHED:COMPLETED"],
  "unsafe_marker_missed_before_running_jobs": true,
  "unsafe_report_replies": [
    {"client": "site-1", "code": 102, "return_code": "ok"},
    {"client": "site-2", "code": 0, "return_code": "ok"}
  ],
  "wrong_status_observed_by": "JobRunner._job_complete_process -> job_manager.set_status"
}
CR-17 reproduced: unsafe startup abort finalized as FINISHED:COMPLETED
```

## Recommendation
Make the unsafe path record an authoritative terminal outcome during startup. The cleanest fix is likely to route `UNSAFE_COMPONENT` through a failure/abort recording path that survives the pre-`running_jobs` window, or make `stop_run` mark the job aborted based on active `run_processes` before/while aborting.

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**.
2. Level 2/3 injection used? **no**.
3. Real consumer/caller observing wrong outcome: `JobRunner._job_complete_process` publishes via `job_manager.set_status` at `nvflare/private/fed/server/job_runner.py:523`.
4. Bad state permanent or masked? **Permanent** for the job record: final status is `FINISHED:COMPLETED`; no downstream repair corrected it.

---

## Entry 25: Empty participants alias the live registered-client dictionary

- **Finding ID**: CR-19
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-19/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/server_engine.py:318

## Description
`ServerEngine._start_runner_process` treats an empty `job_clients` dict as falsy and stores the live `client_manager.clients` dictionary as `RunProcessKey.PARTICIPANTS`. Later client registration mutates that retained participant set, so unrelated clients can be observed as participants of an already-started job.

## Trigger scenario
A scheduled job reaches server-app startup after its selected clients are no longer registered, making `get_job_clients(...)` return `{}`. `start_app_on_server` then stores the live client registry. When another client later registers and is removed as dead, `FederatedServer.notify_dead_client` reports that non-participant to the SJ as a dead job participant.

## Developer intent
History shows `26d931cf` changed this area to “keep running clients for job,” replacing a TODO that used all clients. Docs/tests also show false dead-job reports are unwanted. I found no prior local pinned-history report for this exact empty-map aliasing mechanism.

## Reproduction result
Command:
```bash
timeout 120s /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-19_participants_alias.py
```

Output:
```text
notified SJ of dead-job: job_id='jobCR19alias'; client_name='site-never-started'; reason='client dead'
alias_case.participants_is_live_clients=True
alias_case.participants_initial=[]
alias_case.participants_after_register=['token-alien']
alias_case.dead_job_commands=[{'target': 'server.jobCR19alias', 'topic': 'handle_dead_job', 'client': 'site-never-started', 'reason': 'client dead'}]
control.participants_is_live_clients=False
control.participants_initial=['token-original']
control.participants_after_register=['token-original']
control.dead_job_commands=[]
RESULT: CR-19 reproduced - non-participant client observed as job participant
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? no.
2. Level 2 precondition reachability sequence: `JobRunner.run` schedules/deploys a job, selected clients disconnect before `job_runner.py:296`, `get_job_clients` returns `{}`, then `job_runner.py:304` calls `start_app_on_server`, reaching `server_engine.py:318-325`.
3. Real consumer observing wrong outcome: `FederatedServer.notify_dead_client` at `nvflare/private/fed/server/fed_server.py:1108-1113`, forwarded by `ServerEngine.notify_dead_job` at `server_engine.py:886-897`.
4. Permanent or masked? Not masked for the dead-client path; the stale alias remains until the run process is removed and causes a real `HANDLE_DEAD_JOB` notification. The heartbeat path has a default prior-report guard, but `notify_dead_client` does not.

## Recommendation
Store a snapshot copy for `PARTICIPANTS`. Empty `job_clients` should remain `{}` or be handled explicitly, not replaced with the live registry.

---

## Entry 26: Abort before client registration is dropped before a late start

- **Finding ID**: CR-20
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-20/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/client/client_engine.py:390

## Description

`ClientEngine.abort_app` can drop an ABORT that arrives before `JobExecutor.start_app` registers the pending `STARTING` handle. `get_job_launcher()` fires `BEFORE_JOB_LAUNCH` before that registration, so a normal event-hook delay can let ABORT return “already stopped” and then the late START still launches the client job.

## Trigger scenario

A client processes `START_JOB`, allocates/consumes resources, and reaches `BEFORE_JOB_LAUNCH`. Before `client_executor.py:299` inserts `run_processes[job_id]`, a normal client ABORT request for the same job is processed. Since no job is registered yet, the abort is not latched; the START path resumes, registers the job, launches a child, and the child remains alive.

## Developer intent

Local git history shows adjacent fixes: `cb784550` / PR `#4904` fixes registered `STARTING` aborts, and `a18489e4` / PR `#4910` preserves aborts during blocking `launch_job()`. Those establish intended abort preservation after registration, but current code still leaves the earlier `BEFORE_JOB_LAUNCH` pre-registration window uncovered. No exact prior report for this residual mechanism was found in local git history or in-tree tests.

## Reproduction result

Test: `repro/test_bugCR-20_abort_before_client_registration.py`  
Escalation: Level 1 timing assistance; Level 0 control did not trigger.

Command:
```bash
timeout 2m /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-20_abort_before_client_registration.py
```

Output:
```text
{
  "nvflare_import": "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-20/worktree/nvflare/__init__.py",
  "source": "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-20/worktree",
  "level0_control_no_timing": {
    "resource_check_ok": true,
    "start_reply": "Start the client app...",
    "abort_reply": "Abort signal has been sent to the client App.",
    "child_started": true,
    "child_alive_after_abort": false,
    "registered_after_abort": {},
    "rm_resources": {
      "resources": {
        "gpu": [
          0
        ]
      },
      "reserved_resources": {}
    }
  },
  "level1_abort_before_registration": {
    "resource_check_ok": true,
    "state_at_abort": {
      "registered": {},
      "rm_resources": {
        "resources": {
          "gpu": []
        },
        "reserved_resources": {}
      }
    },
    "abort_reply": "Client app already stopped.",
    "state_after_abort": {
      "registered": {}
    },
    "start_reply": "Start the client app...",
    "child_started_after_abort": true,
    "child_alive_after_late_start": true,
    "registered_after_late_start": {
      "job-l1-bug": 1
    },
    "cp_to_cj_messages": [],
    "after_cleanup": {
      "registered": {},
      "rm_resources": {
        "resources": {
          "gpu": [
            0
          ]
        },
        "reserved_resources": {}
      },
      "reports": [
        {
          "job_id": "job-l1-bug",
          "code": 1,
          "reason": null
        }
      ]
    }
  },
  "level1_control_abort_after_registration": {
    "resource_check_ok": true,
    "state_at_abort": {
      "registered": {
        "job-l1-control": 1
      },
      "rm_resources": {
        "resources": {
          "gpu": []
        },
        "reserved_resources": {}
      }
    },
    "abort_reply": "Abort signal has been sent to the client App.",
    "start_reply": "Start the client app...",
    "child_started": false,
    "child_alive_after_pending_abort": false,
    "registered_after_pending_abort": {},
    "rm_resources": {
      "resources": {
        "gpu": [
          0
        ]
      },
      "reserved_resources": {}
    }
  }
}
CR-20 REPRODUCED: Level 1 abort before registration was dropped and the late child stayed alive.
```

Bug-triggering lines are `abort_reply: "Client app already stopped."`, `child_started_after_abort: true`, and `child_alive_after_late_start: true`. The expected behavior is shown by the post-registration control: the pending-handle abort leaves `child_alive_after_pending_abort: false`.

Checklist:
1. Did Level 0 or Level 1 alone trigger it? yes, Level 1 timing assistance only.
2. Level 2/3 sequence: N/A.
3. Real consumer/caller observing wrong outcome: `AbortAppProcessor.process` at `nvflare/private/fed/client/training_cmds.py:41` returns the early “already stopped” result for the server ABORT path sent by `nvflare/private/fed/server/job_runner.py:395`, while the client child starts and remains alive.
4. Permanent or masked: the reproduced harm is a live child running after an acknowledged abort. Later heartbeat reconciliation can mitigate by sending `ABORT_JOBS`, but it is asynchronous and does not erase the observed wrong execution window.

## Recommendation

Register an abortable pending job entry before `get_job_launcher()` fires `BEFORE_JOB_LAUNCH`, or add a per-job abort-intent latch that `start_app` checks before launching.

---

## Entry 27: Client shutdown and restart lose ownership before child cleanup

- **Finding ID**: CR-21
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-21/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/client/client_engine.py:453

## Description
Client restart/shutdown is not ordered with client child cleanup. A STOPPED-but-still-owned child can remain alive while `_wait_child_process_finish()` has not yet freed its resources; if the client parent restarts in that window, the new parent/resource manager has empty in-memory ownership and can admit a later job for the same resource.

## Trigger scenario
A client job reports `STOPPED` before process-local cleanup, then the server-side restart gate is clear because it only checks active `running_jobs`. The client restart path starts shutdown without waiting for `JobExecutor._wait_child_process_finish()` to call `resource_manager.free_resources()`.

## Developer intent
Local history shows related lifecycle hardening in PR `#5097`, but not this exact CP restart/resource-ownership mechanism. Normal admin shutdown/restart blocks while jobs are running, but the STOPPED cleanup window remains outside that guard.

## Reproduction result
Test written and executed: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-21_restart_loses_child_resource.py`

Command:
```bash
timeout 2m /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-21_restart_loses_child_resource.py
```

Output:
```text
CR-21 reproduction
workdir=/tmp/cr21-bfdl85w6
level0_admin_guard=not_executed_full_cluster; source audit shows server restart/shutdown block only while running_jobs is non-empty
level1_restart_reply='Restart the client...'
level1_restart_calls=1
old_child_pid=3267374
old_child_alive=True
old_allocation={'gpu': ['gpu0']}
old_rm_report_after_allocation={'resources': {'gpu': []}, 'reserved_resources': {}}
new_check_resource_enough=True
new_check_resource_token_nonempty=True
BUG_TRIGGERED: CheckResourceProcessor accepted gpu0 for job-2 while job-1 child is still alive with gpu0
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 injected state is reachable: `ClientAppRunner` reports `STOPPED` before process cleanup, `_wait_child_process_finish()` frees later, server restart only gates on `running_jobs`, then the new parent runs `CheckResourceProcessor`.
3. Real consumer: `CheckResourceProcessor.process` at `nvflare/private/fed/client/scheduler_cmds.py:83`; `JobScheduler` consumes true resource replies at `nvflare/app_common/job_schedulers/job_scheduler.py:212`.
4. Not masked: heartbeat/parent monitors are cooperative and do not preserve old resource-manager ownership before the later resource admission.

## Recommendation
Make client shutdown/restart drain or force-terminate registered job handles before parent exit/restart, or persist/recover child ownership so a restarted parent cannot admit the same resource while an old child is still alive.

---

## Entry 28: Re-registration replaces tokens still used by running-job participants

- **Finding ID**: CR-22
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-22/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/client_manager.py:332

## Description
`ClientManager.authenticated_client()` removes the existing active token for a same-name client and issues a new token on re-registration. A running job keeps its participant map keyed by the old token, so later heartbeat/dead-client reconciliation from the re-registered site misses the running-job participant and does not notify the server runner.

## Trigger scenario
A site registers with token T1, starts `job-1`, and reports that job once. The same site then re-registers and receives T2 while `run_processes[job-1][PARTICIPANTS]` still contains T1. Heartbeats from the re-registered site with T2 and no local jobs fail to call `ServerEngine.notify_dead_job()`.

## Developer intent
Existing tests expect same-token missing-job heartbeat to notify after prior positive observation. Local git/PR history found related dead-job and outcome-barrier fixes, but no report for this exact re-registration/participant-token mismatch. Docs say token cleanup/reconnect does not stop the client process or prevent reconnect.

## Reproduction result
Escalation: Level 2. The injected precondition is reachable via normal job start: `ServerEngine.start_app_on_server()` records `RunProcessKey.PARTICIPANTS` from token-keyed `job_clients`.

Command:
```bash
timeout 5m /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-22_reregister_token_participants.py
```

Output:
```text
CR-22 reproduction: same-site re-registration leaves running-job participants keyed by old token
CONTROL same-token missing-job notifications: [('job-1', 'site-1', 'missing job on client')]
TRIGGER old token from first registration: 00000000-0000-0000-0000-000000000001
TRIGGER new token from re-registration: 00000000-0000-0000-0000-000000000002
TRIGGER job participant tokens: ['00000000-0000-0000-0000-000000000001']
TRIGGER active client-manager tokens: ['00000000-0000-0000-0000-000000000002']
TRIGGER notifications after 3 new-token no-job heartbeats: []
TRIGGER notifications after notify_dead_client(new client): []
BUG REPRODUCED: re-registered site is active, but token-keyed participant lookup suppresses dead-job notification
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 precondition sequence: register client T1 -> job start records `{T1: Client}` in `RunProcessKey.PARTICIPANTS` at `server_engine.py:321` -> prior heartbeat reports `job-1` -> same-site re-registration removes T1 and installs T2 -> T2 heartbeat reports no jobs.
3. Real consumer/caller: `ServerEngine.notify_dead_job()` (`nvflare/private/fed/server/server_engine.py:886`) and downstream `ServerRunner.handle_dead_job()` (`nvflare/private/fed/server/server_runner.py:431`) do not receive the dead-job notification.
4. The bad state persists for the running job entry in the exercised path; repeated T2 heartbeats and `notify_dead_client(new client)` did not resolve it. No downstream mask fired.

## Recommendation
Update job/client reconciliation to match running participants by stable client identity when tokens rotate, or transfer active job participant state from the old token to the new token during same-name re-registration before removing the old active token.

---

## Entry 29: Typed process failures change meaning across normalization and status mapping

- **Finding ID**: CR-23
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-23/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/app_common/job_launcher/process_launcher.py:51

## Description

Confirmed. A local job process can exit with `ProcessExitCode.UNSAFE_COMPONENT` (`102`) from `MainProcessMonitor`, but if `_process_rc.txt` is not written, `ProcessHandle.poll()` normalizes raw `102` to generic `JobReturnCode.EXECUTION_ERROR` (`1`). `ClientExecutor` then remaps that generic value by client status, so a `STARTED` unsafe-component failure is reported to the server as `EXCEPTION` (`101`) instead of `UNSAFE_COMPONENT` (`102`).

The real consumer is `FederatedServer.process_job_failure` at `nvflare/private/fed/server/fed_server.py:942`: preserved `102` calls `stop_run`, but the reproduced path reports `101` and calls `fail_run`.

## Trigger scenario

A local client job process is launched, reaches `STARTED`, raises `ComponentNotAuthorized`, and exits via `sys.exit(102)` without an rc file. The parent observes the raw process exit through the local launcher, normalizes it to `1`, remaps `STARTED + 1` to `101`, and reports `101` to the server.

## Developer intent

Existing tests show `UNSAFE_COMPONENT` is intended to be distinct: server tests assert `102 -> stop_run`, while `101/103/104/ABORTED -> fail_run`. Related PRs `#5047`, `#5194`, `#4986`, and `#4576` cover nearby return-code repairs, but targeted GitHub issue/PR searches found no report for this exact local no-rc-file unsafe-component loss.

## Reproduction result

Reproducer written and executed:

`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-23_typed_process_rc_mapping.py`

Command:

```bash
timeout 5m /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-23_typed_process_rc_mapping.py
```

Output:

```text
CR-23 typed process return-code matrix
MATRIX intended=102 rc_file=False status=1 launcher_poll=1 -> reported=104 reason=infrastructure error server_action=fail_run(104)
MATRIX intended=102 rc_file=False status=2 launcher_poll=1 -> reported=101 reason=exception server_action=fail_run(101)
MATRIX intended=102 rc_file=False status=3 launcher_poll=1 -> reported=1 reason=None server_action=no_failure_action
MATRIX intended=102 rc_file=True status=1 launcher_poll=1 -> reported=102 reason=unsafe component server_action=stop_run
MATRIX intended=102 rc_file=True status=2 launcher_poll=1 -> reported=102 reason=unsafe component server_action=stop_run
MATRIX intended=102 rc_file=True status=3 launcher_poll=1 -> reported=102 reason=unsafe component server_action=stop_run
CR-23 unsafe-component trigger
RAW_CHILD_EXIT=102
RC_FILE_EXISTS=False
CLIENT_REPORTED_CODE=101
CLIENT_REPORTED_REASON=exception
SERVER_ACTION=fail_run
SERVER_CALL_CODE=101
EXPECTED_IF_TYPED_UNSAFE_PRESERVED=stop_run
CHILD_STDERR_TAIL='    rc = main_func(**kwargs)\n         ^^^^^^^^^^^^^^^^^^^\n  File "<string>", line 18, in main\nnvflare.fuel.common.excepts.ComponentNotAuthorized: blocked component from normal job process'
BUG_TRIGGERED=True
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 1 timing only: the test delays the child failure until after normal `STARTED` notification.
2. Level 2/3 precondition sequence: N/A.
3. Real consumer observing wrong outcome: `FederatedServer.process_job_failure`, `nvflare/private/fed/server/fed_server.py:942-955`.
4. Permanent or masked: **permanent for this terminal path**. `_process_rc.txt` masks it when present, but the reproduced no-rc-file path does not fire that mask; the server calls `fail_run` and resolves the client outcome.

## Recommendation

Preserve deliberate NVFlare process exit codes in the local launcher path, or have `get_return_code()` recover raw `101/102/103` when no rc file exists, so `UNSAFE_COMPONENT` reaches the server as `102`.

---

## Entry 30: Fast SJ engine completion is overwritten by STARTED

- **Finding ID**: CR-24
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-24/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/fed_server.py:1148

## Description
`FederatedServer.start_run` starts `run_engine` in a thread, then unconditionally writes `MachineStatus.STARTED`. If `run_engine` completes first, its `MachineStatus.STOPPED` write at `fed_server.py:1209` is overwritten. The server-job process then remains in `start_run`'s polling loop instead of returning to `ServerAppRunner.start_server_app`.

## Trigger scenario
A valid fast server controller returns immediately. The engine thread runs to completion before the parent thread executes the next line after `Thread.start()`, so `STOPPED` is written first and then lost to `STARTED`.

## Developer intent
No matching existing report was found. I checked local git/blame plus GitHub issue/PR searches for this mechanism; nearby PRs #2235, #1023, #4209/#4288, #5072, #5194, and issue #1221 cover different mechanisms.

## Reproduction result
Repro written and executed: `repro/test_bugCR-24_start_run_status_race.py`

Command:
```bash
timeout 2m python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-24_start_run_status_race.py
```

Output:
```text
CASE control_real_threads
  forced_child_first=False
  returned_before_asked_to_stop=True
  engine_status_before_asked_to_stop=MachineStatus.STOPPED
  returned_after_asked_to_stop=True
  final_engine_status=MachineStatus.STOPPED
  result={'returned': True, 'error': None}
  events_before_stop=['_start_run', '_start_workflow', '_end_workflow', '_about_to_end_run', '_check_end_run_readiness', '_end_run']
  messages_before_stop=heartbeats:1 update_run_status:0
  messages_total=heartbeats:1 update_run_status:0

CASE forced_child_finishes_before_parent_started_write
  forced_child_first=True
  returned_before_asked_to_stop=False
  engine_status_before_asked_to_stop=MachineStatus.STARTED
  returned_after_asked_to_stop=True
  final_engine_status=MachineStatus.STOPPED
  result={'returned': True, 'error': None}
  events_before_stop=['_start_run', '_start_workflow', '_end_workflow', '_about_to_end_run', '_check_end_run_readiness', '_end_run']
  messages_before_stop=heartbeats:20 update_run_status:0
  messages_total=heartbeats:21 update_run_status:0

ASSERTIONS
  control_completed_after_cleanup=True
  forced_interleaving_stuck_until_asked_to_stop=True
  expected_correct_behavior=forced case should return once run_engine set STOPPED
```

## Recommendation
Set the parent-side `STARTED` status before starting the engine thread, or guard the post-start write so it cannot overwrite `STOPPED`. A simple recheck/lock around the `STARTED` write and loop condition would preserve the completed state.

Checklist:
1. Did Level 0 or Level 1 alone trigger it? yes, Level 1 timing assistance only.
2. Level 2/3 used? no.
3. Real consumer/caller: `nvflare/private/fed/server/server_app_runner.py:83` calls `start_run`; while stuck, it cannot reach `update_job_run_status()` at `server_app_runner.py:90`.
4. Permanent or masked? Permanent until an external `asked_to_stop` shutdown/parent-loss signal. No normal completion path resolves the overwritten `STARTED`.

---

## Entry 31: Delayed SJ heartbeat marks normal completion aborted

- **Finding ID**: CR-25
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-25/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `nvflare/private/fed/server/fed_server.py:605`

Checklist before `REPRODUCED`:
1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 reachable pre-condition sequence: `JobRunner.run` inserts `running_jobs` and writes `RUNNING` (`job_runner.py:703-711`); normal SJ exit lets `ServerEngine.wait_for_complete` remove `run_processes` (`server_engine.py:203-234`); before `_job_complete_process` publishes terminal status (`job_runner.py:441-538`), a delayed valid SJ `HEARTBEAT` reaches `FederatedServer._listen_command`.
3. Real consumer/caller observing wrong outcome: persisted job metadata read by status consumers; CLI maps `FINISHED:ABORTED` to `JOB_ABORTED` at `nvflare/tool/job/job_cli.py:2769`.
4. Bad state permanence: **permanent** terminal metadata; no downstream mechanism found that converts `FINISHED:ABORTED` back to `FINISHED:COMPLETED`.

## Description
A delayed server-job heartbeat for a job already removed from `engine.run_processes` calls `_set_job_aborted`, which marks the in-memory runner job as aborted if persisted metadata still says `RUNNING`. The completion thread then publishes `FINISHED:ABORTED` even when the SJ exited normally.

## Trigger scenario
A normal SJ completion removes `run_processes[job_id]` before `JobRunner._job_complete_process` publishes the terminal status. If an already-sent or delayed SJ `HEARTBEAT` is delivered in that window, `fed_server.py:605-608` treats the job as “should not be running” and flips `job.run_aborted`.

## Developer intent
Local pinned-history search found related fixes: `8bb1b84c` added SJ heartbeat handling, and `6d193a24` moved aborted-status publication into the completion path. Neither reported this exact delayed-normal-heartbeat mechanism. Docs distinguish successful completion from aborted terminal status.

## Reproduction result
Repro test written and executed:

`timeout 5m python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-25_delayed_sj_heartbeat.py`

Output:
```text
CONTROL final_status=FINISHED:COMPLETED run_aborted=False
TRIGGER final_status=FINISHED:ABORTED run_aborted_after_heartbeat=True
EXPECTED normal completion should remain FINISHED:COMPLETED.
BUG_TRIGGERED=True
```

Also wrote `confirmation/CR-25/investigation.md` and validated `confirmation/CR-25/issue.json`.

## Recommendation
Treat an SJ heartbeat for an untracked job as abort evidence only when the job is not already in the normal completion window, or gate `_set_job_aborted` on completion/exception state rather than only persisted `RUNNING`.

---

## Entry 32: Post-spawn setup or cleanup exceptions break resource ownership

- **Finding ID**: CR-26
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-26/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/client/client_executor.py:676

## Description
Confirmed the cleanup-exception branch of CR-26. `_wait_child_process_finish` calls `resource_manager.free_resources(...)` before removing the job from `run_processes`; if that public cleanup call raises, the waiter thread dies before registry removal and `JOB_COMPLETED`.

## Trigger scenario
Level 0 normal API path: `CHECK_RESOURCE` reserves a GPU, `START_JOB` allocates it and launches through a supported `JobLauncherSpec`, the child handle exits cleanly, then a supported `ResourceManagerSpec.free_resources` raises during waiter cleanup. No product source patch or private-method entry point was used.

## Developer intent
The client executor is expected to release allocated resources and forget the completed child after the job exits, so later eligible jobs can be admitted. The current ordering makes registry removal depend on cleanup succeeding.

## Reproduction result
Executed `repro/test_bugCR-26_cleanup_exception.py`; persistent proposal `confirmation/CR-26/issue.json` also validated as `valid: true`.

```text
first_check_is_resource_enough=True
first_reservation_token_present=True
start_reply_body=Start the client app...
launcher_launch_calls=1
handle_wait_calls=1
free_resources_calls=1
thread_exception=Thread-2 (_wait_child_process_finish):RuntimeError:CR-26 injected free_resources failure
run_processes_after_child_exit=['cr26-job-1']
second_check_is_resource_enough=False
second_reservation_token_present=False
resource_snapshot={'resources': {'gpu': []}, 'reserved_resources': {}}
CR26_REPRODUCED=yes: cleanup exception killed the waiter before registry removal and before the allocated GPU was returned
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? yes.
2. Level 2/3 precondition sequence: N/A.
3. Real consumer/caller observing wrong outcome: `CheckResourceProcessor.process` in `nvflare/private/fed/client/scheduler_cmds.py:83` denies the later eligible job; `ClientEngine.get_all_job_ids` in `nvflare/private/fed/client/client_engine.py:501` also still reports the ended job.
4. Permanent or masked? Permanent for the running client: no downstream retry removes the stale `run_processes` entry or retries `free_resources`; heartbeat abort cleanup terminates but does not pop this entry.

## Recommendation
Wrap waiter cleanup so registry removal and `JOB_COMPLETED` are not skipped when resource cleanup raises, and handle/report `free_resources` failure separately without losing executor ownership state.

---

## Entry 33: A pending restart or shutdown marker is removed by worker bootstrap

- **Finding ID**: CR-27
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-27/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/app/client/worker_process.py:209

## Description
`worker_process.main()` calls `remove_restart_file()` during client job-worker bootstrap, and that helper removes both `restart.fl` and `shutdown.fl` from the shared site workspace root. Those files are owned by the site lifecycle wrapper, not the job worker; `shutdown.fl` in particular tells the wrapper to exit instead of restarting a dead client process.

## Trigger scenario
A normal client shutdown reaches `ClientEngine.shutdown()` / `shutdown_client()` and touches `$WORKSPACE/shutdown.fl` at `nvflare/private/fed/client/client_engine.py:442` and `:512`. Concurrently, a client job process is launched with the same `args.workspace` at `nvflare/private/fed/client/client_executor.py:276`, enters `worker_process.main()`, and removes the marker before the provisioned wrapper checks `nvflare/lighter/templates/master_template.yml:723`.

## Developer intent
`nvflare/apis/fl_constant.py:444` says these two files are used by shell scripts to determine restart/shutdown. I found tests for creating `shutdown.fl`, and git-history searches for `restart.fl`, `shutdown.fl`, marker, and worker restart/shutdown terms, but no local prior report for this exact worker-bootstrap consumption mechanism.

## Reproduction result
Repro written and executed: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-27_worker_marker_consumption.py`

Command:
```bash
timeout 5m python /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-27_worker_marker_consumption.py
```

Output:
```text
CR-27 reproduction: worker bootstrap cleanup vs shell lifecycle markers
source repo: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-27/worktree
shutdown control before worker bootstrap: GRACEFUL_SHUTDOWN
shutdown marker exists after worker bootstrap cleanup: False
shutdown consumer decision after worker bootstrap: RESTART_DEAD_PROCESS
BUG_TRIGGERED shutdown.fl consumed; wrapper restarts instead of exiting
restart control before worker bootstrap: RESTART_LIVE_PROCESS
restart marker exists after worker bootstrap cleanup: False
restart consumer decision after worker bootstrap: KEEP_RUNNING
RESTART_MARKER_CONSUMED live wrapper misses restart request
RESULT: CR-27 reproduced
```

## Recommendation
Do not remove root `restart.fl` or `shutdown.fl` from the per-job worker bootstrap. Leave root lifecycle marker cleanup to the top-level site startup/wrapper owner, or scope worker cleanup to per-job state only.

## Checklist
1. Did Level 0 or Level 1 alone trigger it? **no**. The repro uses Level 2 state injection of a reachable workspace marker/pid state.
2. Reachable sequence: admin shutdown -> `server/training_cmds.py:180` sends client shutdown -> `client/training_cmds.py:75` calls `ClientEngine.shutdown()` -> `client_engine.py:512` touches `shutdown.fl`; concurrent job launch -> `client_executor.py:276` launches `worker_process` with the same workspace -> `worker_process.py:67` / `:209` removes it.
3. Real consumer/caller: provisioned `sub_start.sh` logic from `nvflare/lighter/templates/master_template.yml:723` and `:727`; the repro shows it observes `RESTART_DEAD_PROCESS` instead of `GRACEFUL_SHUTDOWN`.
4. Masking: `restart.fl` may be masked in the admin restart path by dead-process restart fallback, but the `shutdown.fl` case is not masked; marker loss changes shutdown into restart.

---

## Entry 34: Partial deployment leaves workspace state relevant to later operations

- **Finding ID**: CR-28
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-28/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: git:d3e32795/#492; fix-status: unfixed)
- **Location**: nvflare/private/fed/server/job_runner.py:713

## Description
Confirmed. `JobRunner._deploy_job` can create the server run workspace before client deployment replies are evaluated. If a later client deploy failure drops the job below `min_clients`, `run()` marks the job `FINISHED:FAILED_TO_RUN` but does not archive the live workspace into job storage and does not call `_delete_run`.

A later public `download_job` then succeeds for the terminal job but returns a partial bundle without `workspace.zip`, while the server workspace still exists on disk.

## Trigger scenario
Submit a normal job targeting `server`, `site-1`, and `site-2` with `min_clients=2`. Server deployment succeeds, `site-1` returns OK, and `site-2` returns a real deploy error reply. That reply is reachable from `DeployProcessor` client error paths.

## Developer intent
Docs say a finished job’s server workspace is saved into job storage and downloaded by `download_job`. Git history also shows prior intent in `d3e32795/#492`: “delete the workspace if job failed to run.” Current HEAD still leaves the workspace outside job storage and download omits it.

## Reproduction result
Executed: `repro/test_bugCR-28_partial_deploy_workspace.py`

```text
[identity=server, run=?]: Failed to run the Job (6473e718-c3d2-434d-98ed-52034858a058): RuntimeError: ('deploy failure', ['server: OK', 'site-1: OK', 'site-2: simulated reachable client deploy rejection', 'num_ok_sites 1 < required_min_sites 2'])
CR-28 reproduction: partial deploy vs finished-job workspace download
source repo: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-28/worktree
job_id=6473e718-c3d2-434d-98ed-52034858a058
deploy_request_tokens=['token-site-1', 'token-site-2']
final_status=FINISHED:FAILED_TO_RUN
server_run_dir_exists=True
server_app_dir_exists=True
server_run_dir=/tmp/cr28-partial-deploy-v6oxz7dx/server_workspace/6473e718-c3d2-434d-98ed-52034858a058
server_run_dir_files=['app_server/config/config_fed_client.json', 'app_server/config/config_fed_server.json', 'fl_app.txt', 'meta.json']
stored_workspace_component_exists=False
download_errors=[]
download_successes=[('captured download for 6473e718-c3d2-434d-98ed-52034858a058', None)]
downloaded_files=['job.zip', 'meta.json']
workspace_zip_in_download=False
reachable_client_error_reply=nvflare/private/fed/client/training_cmds.py DeployProcessor error_reply
wrong_consumer=nvflare/private/fed/server/job_cmds.py JobCommandModule.download_job
BUG_TRIGGERED=True
RESULT: CR-28 reproduced
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? no.
2. Level 2 precondition is reachable via: `SimpleJobDefManager.create` -> `JobRunner.run` -> server `AppDeployer.deploy` -> client `DeployProcessor` returns `error_reply` -> `_deploy_job` aborts below `min_clients` -> `run()` sets `FAILED_TO_RUN` -> public `JobCommandModule.download_job`.
3. Real consumer/caller observing wrong outcome: `JobCommandModule.download_job` at `nvflare/private/fed/server/job_cmds.py:1752`; packaging skips the absent workspace through `FilesystemStorage.get_data_for_download` at `nvflare/app_common/storages/filesystem_storage.py:377`.
4. Bad state is permanent for this job: `_job_complete_process/_save_workspace` never runs because the job was not registered in `running_jobs`; `_delete_run` has no active caller; disabled `DELETE_WORKSPACE` is not a normal downstream repair.

## Recommendation
On deploy/start failure after partial deployment, either archive the partial server workspace into job storage before marking the job terminal or actively delete server/client run workspaces. `download_job` should also fail or report missing mandatory default components instead of silently returning a partial finished-job bundle.

---

## Entry 35: CAN_NOT_SCHEDULE overwrites an acknowledged abort

- **Finding ID**: CR-29
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-29/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `nvflare/app_common/job_schedulers/job_scheduler.py:308`

## Description
`DefaultJobScheduler.schedule_job()` unconditionally writes `FINISHED:CAN_NOT_SCHEDULE` for blocked jobs after refreshing retry metadata. If the public admin `abort_job` command writes and acknowledges `FINISHED:ABORTED` in that window, the scheduler overwrites the terminal abort result with a different terminal status.

## Trigger scenario
A queued `SUBMITTED` job fails scheduling once, reaches `max_schedule_count`, and is processed as blocked. After the scheduler refreshes blocked-job metadata but before `job_scheduler.py:308`, an admin invokes `abort_job`; `job_cmds.py:1062` writes `FINISHED:ABORTED`, then the scheduler resumes and writes `FINISHED:CAN_NOT_SCHEDULE`.

## Developer intent
Docs and tests separately support both outcomes: exceeded scheduling attempts become `FINISHED:CAN_NOT_SCHEDULE`, while submitted/dispatched aborts are acknowledged as `FINISHED:ABORTED`. I found no test or allowed local-history report covering this overlap; local history search did not find this exact defect.

## Reproduction result
Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 1 timing assistance only; no state injection or source patch.
2. Level 2/3 sequence: not used.
3. Real consumer/caller observing wrong outcome: `JobCommandModule.list_jobs` reports the final status through `nvflare/private/fed/server/job_cmds.py:435`.
4. Bad state permanence/masking: permanent stored terminal overwrite; no downstream mechanism restored `FINISHED:ABORTED`.

Command:
```bash
timeout 120s /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-29_cant_schedule_overwrites_abort.py
```

Output:
```text
submitted status=SUBMITTED
after first scheduler pass status=SUBMITTED schedule_count=1
scheduler paused after refresh_meta; stored status before abort=SUBMITTED
abort command strings=[('Aborted the job 11111111-1111-4111-8111-111111111111 before running it.', None)]
abort command successes=[('', {'status': 'ok', 'info': 'Aborted the job 11111111-1111-4111-8111-111111111111 before running it.'})]
status immediately after acknowledged abort=FINISHED:ABORTED
status after scheduler resumes=FINISHED:CAN_NOT_SCHEDULE
set_status history=[('11111111-1111-4111-8111-111111111111', 'FINISHED:ABORTED'), ('11111111-1111-4111-8111-111111111111', 'FINISHED:CAN_NOT_SCHEDULE')]
list_jobs -d reported status=FINISHED:CAN_NOT_SCHEDULE
BUG_REPRODUCED: FINISHED:CAN_NOT_SCHEDULE overwrote acknowledged FINISHED:ABORTED
```

Repro file: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-29_cant_schedule_overwrites_abort.py`

Persistent issue proposal validated: `confirmation/CR-29/issue.json`.

## Recommendation
Before writing `FINISHED_CANT_SCHEDULE`, re-read the job status and skip the write if it is no longer `SUBMITTED`, especially if it is already `FINISHED:*`. A compare-and-set style status update would make the broader terminal-status contract harder to violate.

---

## Entry 36: An ordinary cleanup exception escapes completion's narrow catch

- **Finding ID**: CR-30
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-30/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/job_runner.py:408

## Description
`abort_client_run` catches only `RuntimeError` around `_send_to_clients`, but I did not find a reachable default NVFlare path that produces an ordinary non-`RuntimeError` at that site. Invalid targets become `RuntimeError`, empty optional fanout returns normally, server event handler failures are recorded in `FLContext`, and remote client exceptions become CellNet error replies.

## Trigger scenario
The completion path reaches `_get_finished_job_status` after a server job failure and calls `abort_client_run` for active participants. A synthetic `ValueError` from a substituted `admin_server.send_requests` escapes, but that producer is not reachable through the default local-process/admin/CellNet path.

## Developer intent
Local HEAD-reachable history and in-tree tests show fixes for abort reply handling, connected-client filtering, and lifecycle cleanup, but no same-site report for a non-`RuntimeError` cleanup fanout escape. External tracker/newer-commit browsing was not used because the continuation instructions prohibited it.

## Reproduction result
Test written and executed:
`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-30_cleanup_exception.py`

Command:
```bash
timeout 5m env PYTHONPATH=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-30/worktree python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-30_cleanup_exception.py
```

Output:
```text
[identity=server, run=?]: Exception when handling event "_before_send_admin_command": ValueError: component event failure
Traceback (most recent call last):
  File "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-30/worktree/nvflare/apis/utils/event.py", line 73, in fire_event_to_components
    h.handle_event(event, ctx)
  File "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-30_cleanup_exception.py", line 87, in handle_event
    raise ValueError("component event failure")
ValueError: component event failure

CR-30 cleanup fanout confirmation probe
Level 0: empty/default optional abort fanout returned normally; no exception escaped.
Level 1: disconnected/invalid target raised RuntimeError inside _send_to_clients and was caught.
Event path: a non-RuntimeError component handler failure was recorded in FLContext, not propagated.
Level 2: injected admin_server.send_requests ValueError escaped: ValueError: synthetic non-RuntimeError fanout failure
Level 3: no source patch used; forcing a default producer to emit this exception would create the symptom.
RESULT: FALSE_POSITIVE_UNREACHABLE_NON_RUNTIME_FANOUT
```

## Recommendation
Do not confirm CR-30 as stated. Optional defensive hardening could catch broader `Exception` around cleanup fanout, but the reported ordinary default exception source is unsupported.

---

## Entry 37: Global machine status differs from concurrent job state

- **Finding ID**: CR-31
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-31/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `nvflare/private/fed/server/fed_server.py:1148`

## Description
Confirmed a real lifecycle bug in the global `engine_info.status` handling. The parent multi-job `wait_for_complete()` mismatch is masked for admin status by `get_engine_info()`, but `FederatedServer.start_run()` has a live lost update: `run_engine()` can write `STOPPED` at `fed_server.py:1209`, then `start_run()` overwrites it with `STARTED` at `fed_server.py:1148`, causing the loop at `fed_server.py:1149` to keep the server-job process alive after the workload ended.

## Trigger scenario
A server job starts normally, `start_run()` starts the engine thread, and the scheduler runs that engine thread to completion before the caller reaches the next line. The engine thread writes `STOPPED`; the caller then writes `STARTED` and waits for a `STOPPED` value that already happened.

## Developer intent
In-tree docs describe NVFLARE as supporting concurrent jobs, and `check_status` has a TODO about displayed status semantics. Local git history/blame found related status fixes, including `9e1881da`, but no exact same-site report for the `start_run()` / `run_engine()` lost update. External tracker/PR discussion was not consulted due the explicit continuation prohibition.

## Reproduction result
Command:
```bash
timeout 2m python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-31_global_machine_status.py
```

Output:
```text
PARENT_WAIT_SNAPSHOT
  raw_after_wait_for_complete=stopped
  remaining_run_processes=['job-b']
  direct_stale_reader_abort_app_on_clients='Server app has not started.'
  admin_check_status_line='Engine status: started'
  derived_after_admin_check_status=started
START_RUN_CONTROL
  returned_before_release=True
  status_before_release=stopped
  history_before_release=['fed_server.py:1200:started', 'fed_server.py:1148:started', 'fed_server.py:1209:stopped', 'fed_server.py:1157:stopped']
  final_result={'returned': True}
START_RUN_FORCED_TIMING
  returned_before_release=False
  status_before_release=started
  history_before_release=['fed_server.py:1200:started', 'fed_server.py:1209:stopped', 'fed_server.py:1148:started']
  final_result={'returned': True}
BUG_TRIGGERED=True
BAD_OUTCOME=start_run loop at fed_server.py:1149 kept running after run_engine wrote STOPPED at fed_server.py:1209; fed_server.py:1148 overwrote it with STARTED.
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? no.
2. Level 2 precondition is reachable: `ServerAppRunner.run_serverapp()` -> `FederatedServer.start_run()` -> `engine_thread.start()` -> OS schedules `run_engine()` -> fast/empty/failing workload returns -> `run_engine()` writes `STOPPED` -> caller resumes and writes `STARTED`.
3. Real consumer: `FederatedServer.start_run()` loop at `nvflare/private/fed/server/fed_server.py:1149`.
4. Bad state is permanent until an external `asked_to_stop`/abort/parent-death path changes it; the test sets `asked_to_stop` only to clean up.

## Recommendation
Make `start_run()` avoid overwriting a terminal status after the engine thread starts. Prefer joining/observing the engine thread directly, or set `STARTED` before starting the thread and guard later writes with per-run state rather than a shared aggregate scalar.

---

## Entry 38: Lock/RPC ordering or late notifications affect cleanup progress

- **Finding ID**: CR-32
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-32/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: local-git:f2b0039e/#4613 and local-git:6d193a24/#4633; fix-status: fixed)
- **Location**: nvflare/private/fed/server/job_runner.py:798

## Description
Confirmed one concrete CR-32 mechanism: `JobRunner.stop_run` calls `_stop_run` first, which can block in the server abort RPC, and only later calls `mark_run_aborted`. If the server child exits cleanly during that window, `_job_complete_process` can publish `FINISHED:COMPLETED` before `job.run_aborted` becomes true.

## Trigger scenario
A running job receives public `abort_job`; the server child exits cleanly while `ServerEngine.abort_app_on_server` is still in progress; `wait_for_complete` removes `engine.run_processes`; completion sees `job.run_aborted == False` and records `FINISHED:COMPLETED`; then `abort_job` returns success.

Checklist:
1. Level 0/1 alone? **no**. The repro uses a Level 2 reachable running-job setup plus Level 1 timing around the child abort RPC.
2. Reachable sequence: `submit_job/start` -> `JobRunner._start_run` populates `running_jobs`/`engine.run_processes` -> normal completion watcher runs -> admin/API `abort_job` -> `JobRunner.stop_run` -> `ServerEngine.abort_app_on_server` -> clean child exit -> `ServerEngine.wait_for_complete` pops `run_processes` before `mark_run_aborted`.
3. Real consumer/caller: `JobCommandModule.abort_job` reports success at `nvflare/private/fed/server/job_cmds.py:1072`; job status consumers then observe the terminal status published by `job_manager.set_status` at `nvflare/private/fed/server/job_runner.py:524`.
4. Permanent or masked? **Permanent for that job lifecycle**. `_job_complete_process` deletes `running_jobs` at `job_runner.py:531`; no later mechanism revises the terminal status.

## Developer intent
Docs/API say `abort_job` aborts an executing job, and architecture docs distinguish `FINISHED:COMPLETED` from `FINISHED:ABORTED`. Existing tests cover simpler abort-marking paths, but not this interleaving.

## Reproduction result
Executed: `python repro/test_bugCR-32_stop_run_completion_race.py`

```text
[control_no_timing_delay]
admin_success=True
admin_strings=['Abort signal has been sent to the server app.']
final_status=FINISHED:ABORTED

[timed_child_abort_rpc_delay]
admin_success=True
admin_strings=['Abort signal has been sent to the server app.']
final_status=FINISHED:COMPLETED
job_run_aborted_after_admin_return=True
running_after_completion=False

REPRODUCED: accepted abort_job returned success, but the terminal job status was FINISHED:COMPLETED instead of FINISHED:ABORTED.
```

Wrote and executed `repro/test_bugCR-32_stop_run_completion_race.py`; saved output to `confirmation/CR-32/repro-output.txt`. Wrote `confirmation/CR-32/issue.json` and validated it successfully.

## Recommendation
Mark the run aborted before entering blocking abort RPC/cleanup paths, or make completion recognize an abort-in-progress state before classifying a clean child exit as completed. Add a regression test for the abort-RPC/completion interleaving.

---

## Entry 39: Retained SJ status reference can replace a newer failure record

- **Finding ID**: CR-33
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-33/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/fed_server.py:597

## Description
`UPDATE_RUN_STATUS` retains `engine.run_processes[job_id]` at `fed_server.py:597`, then for `execution_error=True` writes that same old object into `engine.exception_run_processes[job_id]` at `fed_server.py:601`. If `wait_for_complete` pops `run_processes` and `fail_run` creates a newer authoritative failure record first, the delayed update replaces the newer record and loses `PROCESS_RETURN_CODE=INFRASTRUCTURE_ERROR`.

The wrong state is consumed by `JobRunner._job_complete_process`: status is computed at `job_runner.py:489` and published through `job_manager.set_status` at `job_runner.py:524`.

## Trigger scenario
A normal launched job has `engine.run_processes[job]`, `running_jobs[job]`, and pending client outcomes. The SJ sends `UPDATE_RUN_STATUS(execution_error=True)` and the handler pauses after retaining the live run-process dict. `wait_for_complete` times out waiting for `PROCESS_FINISHED` and pops `run_processes`; then a client infrastructure failure reaches `process_job_failure -> fail_run`, which creates a separate exception record with return code `104`. When the delayed update resumes, it assigns the stale object back into `exception_run_processes`, causing completion to publish `FINISHED:EXECUTION_EXCEPTION` instead of `FINISHED:ABNORMAL`.

## Developer intent
The adjacent comments support preserving authoritative external failures: `server_engine.py:223-228` says an external path such as `fail_run` may already have recorded an authoritative return code, and `job_runner.py:837-840` says `fail_run` establishes an authoritative terminal failure. Local history and upstream issue/PR search found adjacent PR #4552, but no existing report for this retained-reference overwrite mechanism.

## Reproduction result
Test written and executed: `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-33_retained_update_status_reference.py`

Command:
```bash
timeout 60s python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-33_retained_update_status_reference.py
```

Output:
```text
nvflare_import=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-33/worktree/nvflare/__init__.py
pause_line=598
LEVEL0 {"bug_triggered": false, "exception_entry_after_fail_run": {"object": "old_live_run_process", "process_exe_error": true, "process_finished": true, "process_return_code": 104}, "exception_entry_after_update": {"object": "old_live_run_process", "process_exe_error": true, "process_finished": true, "process_return_code": 104}, "expected_status_from_fail_run": "FINISHED:ABNORMAL", "final_status_published": "FINISHED:ABNORMAL", "label": "level0_no_timing", "replacement_happened": false, "retained_update_paused": false}
LEVEL1 {"bug_triggered": true, "exception_entry_after_fail_run": {"object": "new_failure_record", "process_exe_error": null, "process_finished": null, "process_return_code": 104}, "exception_entry_after_update": {"object": "old_live_run_process", "process_exe_error": true, "process_finished": true, "process_return_code": null}, "expected_status_from_fail_run": "FINISHED:ABNORMAL", "final_status_published": "FINISHED:EXECUTION_EXCEPTION", "label": "level1_timing_pause", "replacement_happened": true, "retained_update_paused": true}
CR33_TRIGGERED retained UPDATE_RUN_STATUS object replaced the INFRASTRUCTURE_ERROR failure record; completion published FINISHED:EXECUTION_EXCEPTION instead of FINISHED:ABNORMAL
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 reachable precondition: `ServerEngine._start_runner_process` creates `engine.run_processes[job]`; `JobRunner.run` records `running_jobs[job]`; `_start_run` creates pending client outcomes; `ServerAppRunner.start_server_app -> ServerEngine.update_job_run_status` sends `UPDATE_RUN_STATUS`; `ClientExecutor._wait_child_process_finish -> FederatedServer.process_job_failure` can report `INFRASTRUCTURE_ERROR`.
3. Real consumer/caller: `JobRunner._job_complete_process` at `nvflare/private/fed/server/job_runner.py:489`, then `job_manager.set_status` at `job_runner.py:524`.
4. The bad state is **permanent as the published terminal status**; cleanup removes the exception entry afterward, but no downstream sync/resend corrects the already published status.

## Recommendation
Handle `UPDATE_RUN_STATUS` under `engine.lock` and preserve/merge any existing `exception_run_processes[job_id]` record instead of overwriting it with a retained `run_processes` object. In particular, external failure return codes such as `INFRASTRUCTURE_ERROR` should keep precedence over a later SJ execution-error marker.

---
