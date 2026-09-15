# MC-2 Investigation

## Step 1: Code Audit

Source revision: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`; current `origin/HEAD` also resolves to this SHA.

Finding source is model checking. The named counterexample `spec/output/MC_hunt_s2_cleanup_handoff-bfs.out` reports `Invariant NoFreeWhileInUse is violated`; State 35 is `MCJobExecutorWaiterInstallationException(s1,<<"job-1", 1>>)`, with `waiterError |-> 1`, `client[s1,<<"job-1",1>>].handle = "attached"`, `alive = TRUE`, `spawned = TRUE`, `binding = <<0>>`, `waiter = FALSE`, and the resource manager showing the affected site resource as free while the child is still alive. State 36 records `rm.s1.free = <<0,1>>`, `rm.s1.payload[<<"job-1",1>>] = <<0>>`, and `client[s1,<<"job-1",1>>].alive = TRUE`.

Reachable call chain:

- `StartJobProcessor.process` is the normal client-side handler for `TrainingTopic.START_JOB`. It allocates the reserved resource at `nvflare/private/fed/client/scheduler_cmds.py:119-121`, consumes it at `scheduler_cmds.py:122-124`, then calls `engine.start_app(...)` at `scheduler_cmds.py:125-131`.
- On any exception from allocation, consumption, or start, `StartJobProcessor.process` catches `Exception` and, if `allocated_resources` is set, calls `resource_manager.free_resources(...)` at `scheduler_cmds.py:132-136`. There is no check that a child process already owns the allocation.
- `ClientEngine.start_app` delegates to `self.client_executor.start_app(...)` after the app-dir check at `nvflare/private/fed/client/client_engine.py:350-383`.
- `JobExecutor.start_app` registers a pending process row, calls `job_launcher.launch_job(...)`, attaches the returned handle, fires `AFTER_JOB_LAUNCH`, and only then creates and starts the cleanup waiter thread at `nvflare/private/fed/client/client_executor.py:301-342`.
- Normal cleanup ownership exists only in `_wait_child_process_finish`: it waits for the handle, then frees `allocated_resource` at `client_executor.py:634-699`. If the waiter is never started, that cleanup owner is absent.
- `AutoCleanResourceManager.allocate_resources` transfers a reservation to an allocation by popping `reserved_resources` at `nvflare/app_common/resource_managers/auto_clean_resource_manager.py:159-172`; `free_resources` immediately delegates to `_deallocate` at `auto_clean_resource_manager.py:174-181`.
- `ListResourceManager._deallocate` returns each unit to the front of the free deque without owner/liveness checks at `nvflare/app_common/resource_managers/list_resource_manager.py:52-55`.

Safeguards encountered:

- `AFTER_JOB_LAUNCH` component exceptions are caught by the event dispatcher and stored in `FLContextKey.EXCEPTIONS`, not propagated, at `nvflare/apis/utils/event.py:50-84`; therefore an ordinary event-handler exception is not the reproducing propagation path.
- The child waiter would normally free the resource after process exit and remove `run_processes`, but the finding is specifically about the gap before that waiter is installed.
- No checked guard in `StartJobProcessor.process` asks `JobExecutor` whether the launched child already owns the resource before rollback frees it.

Concrete trigger scenario:

1. A site reserves and allocates `{"gpu": 1}` for `job-1`.
2. The job launcher successfully spawns the child and returns a live handle.
3. `JobExecutor.start_app` attaches that handle, but cleanup-waiter installation fails before `thread.start()` succeeds. This matches counterexample State 35, `MCJobExecutorWaiterInstallationException`.
4. The exception propagates to `StartJobProcessor.process`, whose catch block frees `job-1`'s allocated resource.
5. A later `CHECK_RESOURCE` / `START_JOB` for `job-2` can observe GPU 0 as available and allocate it while the `job-1` child is still alive with `CUDA_VISIBLE_DEVICES=0`.

## Step 2: Developer-Knowledge Search

Local git history on the affected files shows adjacent lifecycle fixes, especially:

- `a18489e43 Preserve abort requests during client job launch (#4910)`: registers a pending handle before invoking the launcher and preserves early aborts while launch is synchronous. This is adjacent to launch handoff, but it addresses abort intent before the launcher returns; it does not report or fix post-spawn cleanup-waiter failure freeing resources.
- `a6616c8ae Harden resource admission failure handling (#5149)`, `5e2283fb6 Keep resource manager exceptions site-local (#5148)`, and `3bff31465 Surface resource manager admission errors (#5143)` touch resource admission/error behavior, not the post-spawn client waiter gap.

Required upstream reference checked:

- PR `https://github.com/NVIDIA/NVFlare/pull/5191` is open as of the GitHub API check. Its body covers server-side scheduler admission failures after resource-check reservations and cancellation/booking behavior, not client-side post-spawn waiter installation.
- Comment `https://github.com/NVIDIA/NVFlare/pull/5191#issuecomment-5432240101` discusses reservation-expiry as a backstop for unacknowledged cancels where no job is running against the reservation. That does not cover an already spawned client child holding the launch binding.

Issue/PR searches performed against `NVIDIA/NVFlare`:

- `"StartJobProcessor" "free_resources"`: 0 results.
- `"JobExecutor" "thread.start"`: 0 results.
- `"can't start new thread"`: 0 results.
- `"JobExecutor" "resource" "cleanup"`: 0 results.
- `"START_JOB" "free_resources"`: 0 results.
- `"JobExecutor" "cleanup" is:pr updated:>2026-08-01`: 0 results.
- `"resource manager" "client job launch" is:pr updated:>2026-08-01`: 0 results.
- Broader `"run_processes" "resource" "STARTING"` returned PR #4910, which is adjacent but not this defect.

## Step 3: Known-Status / Precedent

No public issue, closed/merged PR, open PR, or local git-history entry found that reports the same mechanism at the same site: `StartJobProcessor` freeing an allocated resource after `JobExecutor` has spawned/attached a live child but before a cleanup waiter owns process exit. The finding is MC-sourced with a real counterexample, so it proceeds to Phase 2 reproduction.
