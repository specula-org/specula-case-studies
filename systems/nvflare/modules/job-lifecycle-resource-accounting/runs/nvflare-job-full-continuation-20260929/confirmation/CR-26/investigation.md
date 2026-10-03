# CR-26 Investigation Notes

## Scope

Finding source is code review. I investigated the local client process launch path only: resource reservation/allocation, `START_JOB`, `JobExecutor.start_app`, waiter cleanup, and later resource admission. I did not inspect `bug-report.md`, other findings, shared repair queues, or spec files.

## Code Facts

- `StartJobProcessor.process` allocates resources and then calls `engine.start_app`; if `engine.start_app` raises, it frees the already allocated resources in its outer exception path (`nvflare/private/fed/client/scheduler_cmds.py:114-133`).
- `ClientEngine.start_app` delegates to `JobExecutor.start_app` after verifying the deployed app exists (`nvflare/private/fed/client/client_engine.py:349-382`).
- `JobExecutor.start_app` registers a pending handle, wraps only `job_launcher.launch_job(...)` in a cleanup `try/except`, then attaches the returned handle and performs later setup (`nvflare/private/fed/client/client_executor.py:299-334`).
- The child waiter calls `job_handle.wait()`, reports a terminal outcome, then calls `resource_manager.free_resources(...)`; only after that does it remove the job from `run_processes` and fire `JOB_COMPLETED` (`nvflare/private/fed/client/client_executor.py:622-688`).
- `resource_manager.free_resources(...)` is a public `ResourceManagerSpec` operation. In the built-in `AutoCleanResourceManager`, reserved resources expire automatically, but allocated resources are removed from the reserved map and are only returned by `free_resources` (`nvflare/app_common/resource_managers/auto_clean_resource_manager.py:119-172`).
- Event handler exceptions for normal `FLComponent` handlers are caught by the event dispatcher, so `AFTER_JOB_LAUNCH` component failures are not a reproduced route for this finding. Thread creation failure after launch remains an unguarded post-spawn setup path but was not needed for this reproduction.

## Novelty Search

- Local history for `nvflare/private/fed/client/client_executor.py` includes related launch/cleanup commits such as `a18489e4` ("Preserve abort requests during client job launch"), `cb43eee8` ("Preserve successful Slurm results during heartbeat cleanup"), and `e4f8d417` ("Fixed the client_executor improper lock use"). Their commit messages cover pending launch visibility, heartbeat cleanup origin, and lock use, not exceptions between resource free and registry removal.
- Public issue/PR metadata searches against `NVIDIA/NVFlare` returned zero results for exact mechanism phrases:
  - `"client_executor" "free_resources"`
  - `"_wait_child_process_finish" "free_resources"`
  - `"thread.start" "JobExecutor" "launch_job"`
  - `"resource_manager.free_resources" "run_processes"`

## Reproduction Strategy

The executable reproduction uses the normal client request processors:

1. `CheckResourceProcessor.process` reserves one GPU through a supported `ResourceManagerSpec`.
2. `StartJobProcessor.process` allocates the reservation and starts the app through `ClientEngine.start_app`.
3. A supported `JobLauncherSpec` returns a handle whose job exits cleanly.
4. The waiter reaches `free_resources`, where the custom resource manager raises before deallocation.
5. Because the waiter has no `try/finally`, it dies before removing `run_processes[job_id]`; because free failed before deallocation, a later `CHECK_RESOURCE` for another job is denied.

No source patch or private-method entry point is required.
