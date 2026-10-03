# CR-12 Investigation

Finding: Later empty-resource jobs inherit a stale device binding.
Source: Code Review.
Pinned source: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

## Step 1: Code Audit

Affected source:

- `nvflare/app_common/resource_consumers/gpu_resource_consumer.py:25-33`: `GPUResourceConsumer.consume` validates the allocated GPU IDs, then writes `os.environ["CUDA_VISIBLE_DEVICES"] = ",".join([str(i) for i in resources.keys()])`. For an empty resource dictionary, this expression would set the variable to the empty string, but only if the consumer is called.
- `nvflare/private/fed/client/scheduler_cmds.py:114-121`: `StartJobProcessor.process` calls `resource_manager.allocate_resources(...)`, then calls the resource consumer only when `allocated_resources` is truthy. An empty allocation `{}` skips the consumer.
- `nvflare/app_common/job_launcher/process_launcher.py:66-83`: `ProcessJobLauncher.launch_job` snapshots `os.environ.copy()` and passes that environment to `spawn_process`, so the child job process inherits whatever the client parent currently has.
- `nvflare/utils/job_launcher_utils.py:311-323`: `get_resource_manager_spec` removes `num_of_gpus: 0` (and `mem_per_gpu_in_GiB`) from the resource-manager request, yielding `{}` for explicit zero-GPU jobs.
- `nvflare/app_common/resource_managers/gpu_resource_manager.py:152-186`: empty requirements and `num_of_gpus == 0` reserve/allocate `{}`.

Reachable call chain:

1. The server scheduler resolves the job resource requirement with `get_resource_manager_spec`.
2. The client handles `CHECK_RESOURCE` through `CheckResourceProcessor.process`, reserving resources.
3. The client handles `START_JOB` through `StartJobProcessor.process`.
4. `StartJobProcessor` allocates resources and, if the allocation is non-empty, calls `GPUResourceConsumer.consume`.
5. `ClientEngine.start_app` calls `JobExecutor.start_app`.
6. `JobExecutor.start_app` selects a process launcher and `ProcessJobLauncher.launch_job` copies the client parent environment into the child process.

Trigger scenario:

1. A client parent starts with `GPUResourceManager` + `GPUResourceConsumer` + `ProcessJobLauncher`, the process-mode default documented in `docs/design/docker_job_launcher_design.md:670-682`.
2. Job A requests a positive GPU allocation. The GPU consumer writes `CUDA_VISIBLE_DEVICES`, for example `"0"`, in the client parent process.
3. Job A finishes and the resource manager frees its GPU allocation at `client_executor.py:676-679`, but no code resets `CUDA_VISIBLE_DEVICES`.
4. Job B is submitted later with omitted or explicit zero-GPU resource requirements. `get_resource_manager_spec` / `GPUResourceManager` produce an empty allocation `{}`.
5. `StartJobProcessor` skips the consumer because `{}` is falsy, so the parent environment stays at Job A's device binding.
6. `ProcessJobLauncher` copies the stale parent environment to Job B's child process.

Safeguards / possible masks checked:

- The normal child-exit cleanup frees allocated resources but only calls `resource_manager.free_resources`; it does not restore or clear `CUDA_VISIBLE_DEVICES`.
- No other client-parent path found under `nvflare/` resets `CUDA_VISIBLE_DEVICES` after a job exits. Searches found only writes in the resource consumers, simulator/POC helpers, launcher-specific Slurm code, and deployment tooling.
- A later non-empty allocation overwrites the variable, but an empty allocation does not. A process restart or manual environment clearing would also remove the stale value; neither is part of ordinary per-job cleanup.

## Step 2: Developer-Knowledge Search

Developer intent / docs:

- `docs/user_guide/core_concepts/job.rst:290-295` says once a job is dispatched, the Resource Manager allocates resources, the Resource Consumer consumes them, and after the job finishes the Resource Manager frees them.
- `docs/user_guide/core_concepts/job.rst:313-316` describes the GPU consumer as setting `CUDA_VISIBLE_DEVICES` to allocated GPU IDs and says this ensures concurrent jobs use different GPU devices.
- `docs/design/docker_job_launcher_design.md:676-682` explicitly states that `GPUResourceConsumer` sets `CUDA_VISIBLE_DEVICES` in the SP/CP process environment and that this is correct for process mode because the subprocess inherits it.
- `docs/user_guide/core_concepts/job.rst:261-265` says resource-less jobs can omit resource specs and the client answers yes when no resources are required.
- `tests/unit_test/utils/job_launcher_utils_test.py:248-293` covers zero GPU normalization and `GPUResourceManager` empty allocations, but no test found that asserts `CUDA_VISIBLE_DEVICES` is cleared/reset for an empty allocation or after job completion.

Blame / commits:

- `gpu_resource_consumer.py:33` comes from `242d831b` ("Add GPU resource consumer (#763)") with the later memory check from `903567c7`.
- `scheduler_cmds.py:119-121` has long-standing truthiness gating around `resource_consumer.consume`.
- `process_launcher.py:68` copies `os.environ` in the process launcher path.
- `job_launcher_utils.py:311-323` zero-GPU normalization was added by `0d25aa9a` / `ce966f2d`.
- Local git-history searches for `CUDA_VISIBLE_DEVICES`, `GPUResourceConsumer`, `resource_consumer`, `empty resource`, `visible devices`, and related paths found no commit addressing this exact stale-empty-allocation mechanism. Closest related entries are `03b56e8b` / PR #4595 (GPU manager respecting `CUDA_VISIBLE_DEVICES`) and older consumer-introduction commits, not a reset/empty-allocation fix.

Prior handoff records:

- The relevant prior records identify the same mechanism as F13 / CL-2 and include a real-code client-parent harness result. I used those records as evidence to audit, not as a verdict.

## Step 3: Known-Status / Precedent

Public tracker / PR search:

- GitHub issue/PR search against `NVIDIA/NVFlare` returned zero results for:
  - `CUDA_VISIBLE_DEVICES GPUResourceConsumer empty resource`
  - `CUDA_VISIBLE_DEVICES resource_consumer inherited`
  - `"CUDA_VISIBLE_DEVICES" "GPUResourceConsumer"`
  - `"CUDA_VISIBLE_DEVICES" "resource_consumer"`
  - `"GPUResourceConsumer" "empty"`
- Local reachable git history at the pinned commit found no commit or merged PR reporting/fixing this exact defect at this site.

Known-status conclusion: no prior issue/PR/CVE/advisory or prior Specula dataset entry was found that reports this exact mechanism at this exact site. Proceeded to Phase 2 as a new code-review finding.
