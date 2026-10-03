# MC-8 Investigation

## Finding

- Source: model-checking counterexample `spec/output/continuation-H4-s3_groups/tlc.out` supplied by dispatcher.
- Invariant: `NoFreeWhileGroupAlive`.
- Title: Client resources can be freed while same-group descendants remain alive.
- Source checkout: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

## Step 1: Code Audit

Relevant client path:

- `nvflare/private/fed/client/scheduler_cmds.py:114-128` handles `START_JOB`: allocate reserved resources, consume them, and call `engine.start_app(...)`.
- `nvflare/private/fed/client/client_engine.py:349-382` accepts a deployed app and delegates to `JobExecutor.start_app(...)`.
- `nvflare/private/fed/utils/fed_utils.py:618-629` selects the configured launcher via the normal `BEFORE_JOB_LAUNCH` event.
- `nvflare/private/fed/client/client_executor.py:299-334` registers the job in `run_processes`, launches the process, attaches the handle, and starts `_wait_child_process_finish`.
- `nvflare/private/fed/client/client_executor.py:622-681` waits only for the launcher leader via `job_handle.wait()`, then calls `resource_manager.free_resources(...)` and removes `run_processes[job_id]`.
- `nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172` returns freed units to the resource pool.
- `nvflare/app_common/resource_consumers/list_resource_consumer.py:31-37` binds a list allocation to `CUDA_VISIBLE_DEVICES`; `nvflare/app_common/job_launcher/process_launcher.py:68-82` copies the current environment and spawns the process.
- `nvflare/utils/process_utils.py:333-349` creates a new session/process group for launched jobs (`posix_spawn(..., setsid=True)` or `Popen(..., preexec_fn=os.setsid)`).

Termination/cleanup safeguards:

- `nvflare/private/fed/client/client_executor.py:581-600` waits up to 10 seconds, but returns immediately if the job registration is already gone. If the waiter reaped the leader and popped the registration, no later abort/heartbeat cleanup calls `terminate()`.
- `nvflare/utils/process_utils.py:300-304` resolves the process group by calling `os.getpgid(self.pid)` and returns on `ProcessLookupError`. Once the leader PID has been reaped, the handle cannot rediscover the process group even if same-group descendants remain alive.

Reachability:

The path is reachable through normal client request processors: `CHECK_RESOURCE` reserves a unit, `START_JOB` allocates the unit, and the configured process launcher starts the job. User job code can start a subprocess without `start_new_session`; that subprocess remains in the job leader's process group. If the leader exits successfully without waiting for the descendant, `_wait_child_process_finish` treats the job as complete and releases resources while the descendant remains alive.

Trigger scenario:

1. A client has one list-managed GPU resource unit.
2. Job A reserves and starts through `CHECK_RESOURCE` / `START_JOB`.
3. The real process launcher starts job A in a new session/process group.
4. Job A's leader starts a same-process-group descendant and exits successfully.
5. The real waiter reaps the leader, sends a success report, frees the GPU unit, and removes job A's registration.
6. While job A's descendant is still alive and still bound to `CUDA_VISIBLE_DEVICES=0`, job B reserves the same unit and starts with `CUDA_VISIBLE_DEVICES=0`.
7. Calling `terminate()` on job A's reaped handle no longer kills the descendant, because `getpgid(leader_pid)` fails.

Observed safeguards do not prevent the trigger. The Client API external-process backend has a separate owner-monitoring contract for dedicated external trainers (`docs/design/client_api_execution_modes.md:342-360`), but the generic local-process `JobExecutor` path has no equivalent descendant tracking or group-lifetime accounting. The unit tests explicitly assert that `_terminate_job` does not signal the handle after the worker was reaped (`tests/unit_test/private/fed/client/client_executor_test.py:139-145`) and that `ProcessAdapter.terminate()` short-circuits on `getpgid` failure (`tests/unit_test/utils/process_utils_test.py:224-235`).

## Step 2: Developer-Knowledge Search

Local git history and comments/docs/tests searched:

- `git log --all --grep='process group|killpg|descendant|child process|worker process|client resources|free resources|resource.*free|resource.*release|abort_train|terminate' -i -- nvflare/private/fed/client/client_executor.py nvflare/utils/process_utils.py nvflare/app_common/job_launcher/process_launcher.py`
- `git log --all --date=short --format='%h %ad %s' -- nvflare/private/fed/client/client_executor.py nvflare/utils/process_utils.py nvflare/app_common/job_launcher/process_launcher.py`
- `rg -n 'known|TODO|FIXME|descendant|process group|killpg|terminate\\(\\)|worker resources freed|child worker resources freed|Client worker process|already finished gracefully|SIGKILL|setsid|start_new_session' nvflare/private/fed/client nvflare/utils nvflare/app_common/job_launcher tests docs`

Relevant developer evidence:

- `docs/design/job_launcher_and_job_handle.md:49-53` states `terminate()` means "Stop the job immediately"; `docs/design/job_launcher_and_job_handle.md:5-11` says upper layers program through `JobLauncherSpec`/`JobHandleSpec`.
- `nvflare/utils/process_utils.py:226-232` documents `ProcessAdapter.terminate()` as terminating the process group with SIGKILL.
- `tests/unit_test/utils/process_utils_test.py:206-222` asserts `terminate()` calls `killpg` with `SIGKILL`; `tests/unit_test/utils/process_utils_test.py:276-283` and `:332-344` assert launched jobs are placed in new sessions/process groups.
- `tests/unit_test/private/fed/client/client_executor_test.py:121-136` asserts a STOPPED worker may finish during cleanup grace without being signaled; `:139-145` asserts an already-reaped worker is not signaled. This explains the current implementation behavior but does not document a resource-reuse guarantee for surviving descendants.
- Commit `9b5dddfd` / PR `#5097` ("Harden Client API and Swarm abort cleanup") fixed an adjacent Client API/external trainer orphaning problem and states that an external trainer watches the owning CJ PID so abrupt CJ exit cannot orphan the trainer process group. That fix is Client API-specific, already present in this source, and does not report or fix the generic `JobExecutor` resource-free/reuse path reproduced for MC-8.
- Commit `52c966d1` / PR `#5194` classifies active client-worker exit failures; it does not mention descendant process groups or resource release while descendants are alive.
- Commit `03789dd9` / PR `#634` changed abort/retry/run-process pop behavior; it does not report this resource lifetime mechanism.

## Step 3: Known-Status / Precedent

No local git-history, docs, tests, or in-tree issue/PR message search found a report of this exact defect: generic client `JobExecutor` frees resources and removes registration after the leader exits while same-process-group descendants remain alive, enabling a later job to reserve/start on the same unit. The closest known precedent is Client API external trainer orphan handling in `#5097`, but it is a different subsystem/site and is already merged without covering this generic local process-launch path.

Known-status conclusion for this finding: `NEW` based on the allowed local git-history/tracker-message search for the pinned source. External/newer upstream issue discussion was not fetched because the continuation instructions forbid consulting newer upstream issue/PR discussions.

## Reproduction Artifact

- Test: `repro/test_bugMC-8_process_group_resource_reuse.py`
- Output log: `repro/test_bugMC-8_process_group_resource_reuse.out`
- Command: `timeout 2m python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-8_process_group_resource_reuse.py`

The test uses the normal client request processors and real `ProcessJobLauncher` / `ProcessAdapter`. It stubs only the network edge and provides a launcher command for tiny job scripts.
