# Confirmation Report — nvflare-job-lifecycle

## Final Result

Reproduced bugs: 5 = 5 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 1
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 6
Dispositions: 6 total = 5 reproduced + 0 env-limited + 0 masked + 1 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-2 | REPRODUCED | yes |
| 2 | MC-3 | REPRODUCED | yes |
| 3 | MC-4 | REPRODUCED | yes |
| 4 | CR-1 | REPRODUCED | yes |
| 5 | CR-4 | FALSE POSITIVE | no |
| 6 | CR-5 | REPRODUCED | yes |

## Entry 1: Startup rollback frees a resource while the spawned child is still live

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: nvflare/private/fed/client/client_executor.py:337

## Description
`JobExecutor.start_app` can spawn and attach a live child process before the cleanup waiter is successfully started. If waiter installation fails, the exception propagates to `StartJobProcessor.process`, whose rollback frees the already allocated resource without checking that the child still owns it. `ListResourceManager` then exposes the unit as available, allowing a later job to receive the same GPU binding.

## Trigger scenario
`CHECK_RESOURCE(job-1)` reserves GPU 0, then `START_JOB(job-1)` allocates and consumes it. The launcher returns a live child handle, but the cleanup waiter fails to start, matching counterexample State 35: `MCJobExecutorWaiterInstallationException(s1,<<"job-1", 1>>)`, with attached handle, live child, and `waiter = FALSE`. `StartJobProcessor` catches the exception and frees GPU 0; a later `CHECK_RESOURCE/START_JOB(job-2)` observes and allocates GPU 0 while `job-1` is still alive.

## Developer intent
Searched upstream issues and recently closed/merged PRs. PR #5191 is open and covers server-side admission reservation cleanup, not this client post-spawn waiter gap. PR #4910 is adjacent launch-handoff work, but it preserves abort requests before launcher return; it does not report this resource rollback mechanism. Targeted searches for `StartJobProcessor free_resources`, `JobExecutor thread.start`, `can't start new thread`, and recent JobExecutor/resource cleanup PRs found no same-mechanism report.

## Reproduction result
Repro written and executed:

`/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/repro/test_bugMC-2_startup_cleanup_handoff.py`

Command:

```bash
timeout 5m python /home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/repro/test_bugMC-2_startup_cleanup_handoff.py
```

Actual output:

```text
LAUNCH job-control: pid=559194 CUDA_VISIBLE_DEVICES='0'
LEVEL0 normal-start control: child_alive=True free_gpus=[] result='Start the client app...'
LAUNCH job-1: pid=559196 CUDA_VISIBLE_DEVICES='0'
LEVEL2 injected CE step MCJobExecutorWaiterInstallationException: start_reply='NVFLARE_ERROR: Start job execution exception: RuntimeError: controlled waiter installation failure.' first_child_alive=True registered_status=1 free_gpus_after_rollback=[0]
OBSERVED WRONG AVAILABILITY: job2_check_enough=True token_present=True while_job1_child_alive=True
LAUNCH job-2: pid=559197 CUDA_VISIBLE_DEVICES='0'
OBSERVED DOUBLE ASSIGNMENT: job1_pid=559196 job1_cuda='0' job2_pid=559197 job2_cuda='0' both_children_alive=True
MC-2 reproduced: StartJobProcessor freed a resource while the launched child was still alive.
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**. Level 0 normal start kept `free_gpus=[]` while the child was alive.
2. Level 2 injection corresponds to CE State 35, `MCJobExecutorWaiterInstallationException`, after launch/attach and before waiter ownership.
3. Real consumer: `CheckResourceProcessor.process` observes enough capacity; `StartJobProcessor.process` allocates/consumes it for `job-2`.
4. The state is not masked while the first child is live. Natural child exit may end active use later, but no downstream guard prevents the demonstrated double assignment.

## Recommendation
Make post-spawn startup rollback ownership explicit. If waiter installation fails after a handle is attached, terminate/wait for the child before freeing resources, or transfer cleanup ownership before any exception can return to `StartJobProcessor`; do not let the generic start rollback free resources for a partially launched live child.

---

## Entry 2: A stale deployment write can undo an acknowledged pre-run abort

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `nvflare/private/fed/server/job_runner.py:685`

## Description
`JobRunner.run` checks that a job is `SUBMITTED` before deployment, but after deployment returns it unconditionally writes `DISPATCHED`. A concurrent admin `abort_job` can accept a pre-run abort, write `FINISHED:ABORTED`, and return success; the stale deployment path then overwrites that terminal status and proceeds to start the job.

## Trigger scenario
A delayed deploy reply leaves the runner between the `SUBMITTED` check and the `DISPATCHED` write. During that window, the normal admin abort command sees `SUBMITTED`, writes `FINISHED:ABORTED`, and acknowledges the abort. When deploy returns, the runner writes `DISPATCHED`, passes its `DISPATCHED` pre-start check at `job_runner.py:714`, and writes `RUNNING`.

## Developer intent
Prior-report search covered upstream issues and recently merged/closed PRs. Adjacent PRs exist, including [#4613](https://github.com/NVIDIA/NVFlare/pull/4613), [#4633](https://github.com/NVIDIA/NVFlare/pull/4633), [#5216](https://github.com/NVIDIA/NVFlare/pull/5216), and [#5191](https://github.com/NVIDIA/NVFlare/pull/5191), but they address different lifecycle/status-accounting paths and do not report or fix this exact deploy-overwrites-pre-run-abort mechanism.

## Reproduction result
Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 0 without controlled overlap did not trigger; Level 1 timing assistance via delayed deploy reply triggered it.
2. Level 2/3 precondition: N/A.
3. Real consumer/caller: `JobRunner.run` at `nvflare/private/fed/server/job_runner.py:714` observes the stale `DISPATCHED` status and proceeds to `_start_run`; the same run then writes `RUNNING` at `job_runner.py:729`.
4. Bad state permanence/masking: no downstream mechanism restored the acknowledged `FINISHED:ABORTED`; the reproduced final status is `RUNNING`, so the abort is not merely a transient snapshot.

Test: `/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/repro/test_bugMC-3_pre_run_abort.py`

Command:
```bash
timeout 60s /home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/repro/test_bugMC-3_pre_run_abort.py
```

Output:
```text
source_head=53ba7ee567468ea7971dad4faccef13c6cb35dc2
Level 0 pure normal sequence:
  status_writes=['SUBMITTED', 'FINISHED:ABORTED']
  final_status=FINISHED:ABORTED
  triggered=False
Level 1 delayed deploy reply:
  abort_ok=True
  abort_message=Aborted the job job-mc3 before running it.
  status_writes=['SUBMITTED', 'FINISHED:ABORTED', 'DISPATCHED', 'RUNNING']
  final_status=RUNNING
  started_after_abort=True
BUG_TRIGGERED=yes
Expected: once abort_job acknowledges a SUBMITTED pre-run abort, the job remains FINISHED:ABORTED and must not start.
Observed: JobRunner published DISPATCHED and RUNNING after the abort acknowledgement.
```

## Recommendation
Make the post-deploy status transition conditional: before writing `DISPATCHED`, reload status and only transition from `SUBMITTED`; never overwrite `FINISHED:*`. Prefer an expected-state/compare-and-set style job-manager update for lifecycle transitions.

---

## Entry 3: A delayed startup write can restore RUNNING after terminal publication

- **Finding ID**: MC-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/MC-4/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `nvflare/private/fed/server/job_runner.py:729`

## Description
MC-4 is reproduced. `JobRunner.run()` registers the job in `running_jobs` before writing `RUNNING`, and the completion thread can publish `FINISHED:COMPLETED` in between; the delayed startup write then overwrites terminal metadata back to `RUNNING`.

## Trigger scenario
A normal start path reaches `_start_run()`, registers `running_jobs`, then the `RUNNING` metadata write is delayed. During that delay the server process has exited and the client outcome has resolved, so `_job_complete_process()` publishes `FINISHED:COMPLETED` and removes bookkeeping. When the delayed startup write resumes, `JobDefManager.set_status()` accepts `RUNNING` with no terminal guard.

## Developer intent
I searched upstream issues/PRs and git history, including required PR https://github.com/NVIDIA/NVFlare/pull/5191 plus adjacent #5215/#5216/#5221. Those cover reservation cleanup, lifecycle event identity, and missing-client-outcome barriers, but not this exact terminal-status overwrite mechanism.

## Reproduction result
Test written and executed:  
`/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/repro/test_bugMC-4_terminal_resurrection.py`

Command:
```bash
timeout 30s env PYTHONPATH=/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/MC-4/worktree python /home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/repro/test_bugMC-4_terminal_resurrection.py
```

Output:
```text
MC-4 repro: delayed startup status write after terminal publication
level0_no_delay.history=['SUBMITTED->DISPATCHED', 'DISPATCHED->RUNNING', 'RUNNING->FINISHED:COMPLETED']
level0_no_delay.final_status=FINISHED:COMPLETED
level0_no_delay.monitor_return=JOB_FINISHED
level0_no_delay.monitor_meta_status=FINISHED:COMPLETED
level1_delayed_running_store.history=['SUBMITTED->DISPATCHED', 'DISPATCHED->FINISHED:COMPLETED', 'FINISHED:COMPLETED->RUNNING']
level1_delayed_running_store.final_status=RUNNING
level1_delayed_running_store.monitor_return=TIMEOUT
level1_delayed_running_store.monitor_meta_status=None
BUG_TRIGGERED: terminal FINISHED:COMPLETED was overwritten by RUNNING
OBSERVED_BY: nvflare/fuel/flare_api/flare_api.py:1674 monitor_job_and_return_job_meta
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 1 timing assistance only; Level 0 control did not trigger.
2. Level 2/3 used? **no**.
3. Real consumer/caller observing wrong outcome: `nvflare/fuel/flare_api/flare_api.py:1674`, `Session.monitor_job_and_return_job_meta()`, observed as `TIMEOUT`.
4. Permanent or masked? The bad status is persistent in job metadata after completion bookkeeping is removed; no downstream sync, resend, or guard corrected it in the repro.

## Recommendation
Make job status transitions monotonic or conditional. At minimum, prevent `RUNNING` from overwriting any `FINISHED:*` status, preferably with an atomic compare-and-set from `DISPATCHED` to `RUNNING` or by making `running_jobs` registration and `RUNNING` publication indivisible with respect to completion processing.

---

## Entry 4: Allocation identity crosses shared process environment

- **Finding ID**: CR-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/app_common/resource_consumers/list_resource_consumer.py:37

## Description
CR-1 is reproduced. `ListResourceConsumer` writes a job allocation into process-global `CUDA_VISIBLE_DEVICES`, and `ProcessJobLauncher` later snapshots that same parent environment for the worker process. With two legitimate `START_JOB` requests overlapping, job A can allocate GPU 0 but launch with job B’s later `CUDA_VISIBLE_DEVICES=1`.

## Trigger scenario
Job A and job B reserve distinct GPU list entries on the same client. Job A starts first, allocates GPU 0, and calls `resource_consumer.consume()`. Before job A’s launcher snapshots `os.environ`, job B starts, allocates GPU 1, and overwrites the parent process env. Job A’s child then inherits GPU 1 despite owning GPU 0.

## Developer intent
Docs say the resource consumer sets `CUDA_VISIBLE_DEVICES` so concurrent jobs use different GPU devices. I found no exact prior upstream issue/PR for this mechanism; PR #5191 is about admission/cancellation cleanup, and PRs #4563/#4595 are about initial visible-GPU scoping, not cross-job env overwrite before launch.

## Reproduction result
Test written and executed:
`/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/repro/test_bugCR-1_env_snapshot_race.py`

Command:
```bash
timeout 5m env PYTHONPATH=/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/CR-1/worktree python /home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/repro/test_bugCR-1_env_snapshot_race.py
```

Output:
```text
LEVEL0_NO_DELAY observation:
... job-A allocation [0], env '0'; job-B allocation [1], env '1'.
BUG_NOT_TRIGGERED at LEVEL0_NO_DELAY: job-A allocation [0], env '0'; job-B allocation [1], env '1'.
LEVEL1_DELAY_AFTER_CONSUME observation:
... job-A allocation [0], child CUDA_VISIBLE_DEVICES "1"; job-B allocation [1], child CUDA_VISIBLE_DEVICES "1".
BUG_TRIGGERED at LEVEL1_DELAY_AFTER_CONSUME: job-A child inherited CUDA_VISIBLE_DEVICES='1' despite allocation [0]; job-B allocation [1], job-B child env '1'.
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 1 timing assistance triggered it; Level 0 did not hit the window.
2. Level 2/3 used? **no**.
3. Real consumer/caller: `ProcessJobLauncher.launch_job()` snapshots the wrong env at `nvflare/app_common/job_launcher/process_launcher.py:68`, then `spawn_process()` launches the child at `process_launcher.py:81`.
4. Permanent or masked? The wrong env is fixed for the lifetime of the launched child process. Cleanup frees the recorded allocation later but does not correct the child’s inherited GPU binding, so this is not masked.

## Recommendation
Do not encode per-job resource allocations by mutating `os.environ` in the shared client parent process. Pass resource-derived env overrides through a job-local launch environment, then merge them directly into `new_env` inside `ProcessJobLauncher` before spawn. Add a concurrent-start regression test that asserts each child inherits the GPU ID allocated to its own token.

---

## Entry 5: Logical termination, outcome receipt and physical cleanup diverge

- **Finding ID**: CR-4
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/client/client_executor.py:634

## Description
CR-4 did not reproduce on pinned NVFlare `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. The suspected divergence is blocked by current ownership barriers: client resources are freed only from `_wait_child_process_finish` after child exit, registered `STOPPED` jobs remain abortable, and server terminal outcome handling is keyed by `(job_id, client_name)`.

Prior-report search covered upstream issues and recently merged/closed PRs. Related historical fixes exist in PRs #5072, #5117, #5194, #5221, and open PR #5191, but I found no exact current-head report for this remaining mechanism.

## Trigger scenario
I tested: job-1 reserves and allocates the only `ListResourceManager` GPU; scheduler receives logical `JOB_COMPLETED`; job-2 tries to schedule before job-1 physical cleanup; job-1 then exits through the real client cleanup waiter; delayed/duplicate terminal reports are sent against server outcome tracking.

## Developer intent
The current implementation separates logical scheduling state from physical resource ownership: `JobExecutor._wait_child_process_finish` waits, reports terminal outcome, frees resources, removes `run_processes`, then fires client `JOB_COMPLETED`. `JobRunner` tracks pending outcomes per job/client, and `FederatedServer.process_job_failure` ignores stale untracked reports.

## Reproduction result
Executed:
`/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/repro/test_bugCR-4_lifecycle_cleanup_divergence.py`

```text
NVFlare worktree: /home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/CR-4/worktree
LEVEL 0 PASS: scheduler logical JOB_COMPLETED removed job-1 from scheduled_jobs, but ListResourceManager kept gpu0 unavailable until free_resources; job-2 was not admitted early.
LEVEL 1 PASS: normal CHECK_RESOURCE/START_JOB plus STOPPED heartbeat abort kept gpu0 allocated until the child waiter returned; outcome was sent before the single free and JOB_COMPLETED event.
LEVEL 2 PASS: with the reachable pending-outcome state seeded by JobRunner._start_run, late duplicate and unknown job reports were ACKed but ignored and did not alter job-2.
LEVEL 3 PASS: no source patch applied; Level 1 already held the child at the exact waiter boundary and Level 2 injected only the pending-outcome state that JobRunner._start_run creates. Patching logic to remove those guards would manufacture the symptom.
RESULT: no early free, duplicate free, omitted free, or wrong-job outcome mutation reproduced
```

## Recommendation
Close CR-4 as a false positive for the pinned head. The repro is useful as a regression probe for this lifecycle boundary, but no repair request is warranted.

---

## Entry 6: Per-job failure can escape a scheduling or completion service

- **Finding ID**: CR-5
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/private/fed/server/job_runner.py:742

## Description
CR-5 is reproduced on the startup-failure path. After `_start_run()` fires `JOB_STARTED`, a per-job job-store failure in the later `RUNNING` status write enters the startup exception handler; if `FAILED_TO_RUN` publication also raises at [job_runner.py:742](/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/CR-5/worktree/nvflare/private/fed/server/job_runner.py:742), the exception escapes before `JOB_ABORTED`, leaving scheduler accounting stale.

## Trigger scenario
Normal sequence: `JobRunner.run()` admits/deploys a job, `_start_run()` succeeds and emits `JOB_STARTED`, then `JobDefManager.set_status(RUNNING)` hits a per-job storage error. The failure handler removes runner-local maps but raises again while publishing `FAILED_TO_RUN`, so `DefaultJobScheduler` never receives the abort event and later blocks an eligible job at its max-jobs gate.

## Developer intent
Prior-report search covered upstream issues/PRs and git history. [PR #5191](https://github.com/NVIDIA/NVFlare/pull/5191) is an open, known scheduler-admission cleanup issue, but not this runner startup-failure handler escape. [#5215/#5216](https://github.com/NVIDIA/NVFlare/pull/5216) fixed stale accounting from sticky context event attribution, and [#5220/#5221](https://github.com/NVIDIA/NVFlare/pull/5221) fixed failed-job completion waiting on missing client outcomes. No existing report found for this exact `FAILED_TO_RUN` status-store escape after `JOB_STARTED`.

## Reproduction result
Repro written and executed: [test_bugCR-5_startup_failure_escapes_runner.py](/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/repro/test_bugCR-5_startup_failure_escapes_runner.py)

Command:
```bash
timeout 2m /home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/repro/test_bugCR-5_startup_failure_escapes_runner.py
```

Output:
```text
CR-5 startup failure escape reproduction
escaped_exception=ControlledStoreFailure: controlled per-job status-store failure for job-1 -> FINISHED:FAILED_TO_RUN
events=['_job_started']
status_calls=[('job-1', 'DISPATCHED'), ('job-1', 'RUNNING'), ('job-1', 'FINISHED:FAILED_TO_RUN')]
stale_scheduled_jobs_after_escape=['job-1']
later_candidate_with_stale_accounting=None
later_candidate_after_clearing_mask=job-2
dispatch_after_clearing_mask=['server', 'site-1']
RESULT=REPRODUCED
```

Checklist:
1. Level 0/1 alone triggered it: **no**.
2. Level 2 used: injected precondition is a reachable per-job job-store/status publication failure; `SimpleJobDefManager.set_status()` delegates to storage without catching `update_meta` failures, and the real sequence is `run -> _start_run/JOB_STARTED -> set_status(RUNNING) failure -> failure handler -> set_status(FAILED_TO_RUN) failure`.
3. Real consumer/caller: `DefaultJobScheduler.schedule_job()` via `_exceed_max_jobs()` at [job_scheduler.py:268](/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/confirmation/CR-5/worktree/nvflare/app_common/job_schedulers/job_scheduler.py:268); output shows `later_candidate_with_stale_accounting=None`.
4. Bad state: permanent until manual clear/restart; no downstream event/retry clears `scheduled_jobs` because `JOB_ABORTED` is skipped.

## Recommendation
Wrap startup failure cleanup in guarded/finally-style containment: preserve `JobRunner.run()` liveness, ensure scheduler accounting is cleared even when failed-status publication or metadata update fails, and retry/log status publication similarly to the completion path.

---
