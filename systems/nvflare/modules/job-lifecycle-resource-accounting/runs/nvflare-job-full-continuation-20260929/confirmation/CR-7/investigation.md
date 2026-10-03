# CR-7 Investigation

## Finding

CR-7 is a code-review finding: `GPUResourceManager` stores per-GPU memory as Python `float` values when configured with fractional GiB. It reserves by subtracting the requested float and frees by adding the same float back. Later admission checks use exact `>=` comparisons.

## Source Audit

Primary implementation:

- `nvflare/app_common/resource_managers/gpu_resource_manager.py:144` initializes each `GPUResource` with the configured `mem_per_gpu_in_GiB` value.
- `nvflare/app_common/resource_managers/gpu_resource_manager.py:148-150` restores freed GPU memory with `self.resources[k].memory += v`.
- `nvflare/app_common/resource_managers/gpu_resource_manager.py:152-173` checks whether enough GPUs have `r.memory >= gpu_mem`.
- `nvflare/app_common/resource_managers/gpu_resource_manager.py:175-197` reserves resources by checking `r.memory >= gpu_mem`, subtracting `gpu_mem`, and storing the requested `gpu_mem` in the reserved resources map.

The code allows fractional GPU memory: the constructor accepts both `int` and `float` for `mem_per_gpu_in_GiB`, and the local history includes `903567c7 Allow GPUResourceManager/Consumer to handle float GPU memory (#1073)`.

The relevant arithmetic is ordinary binary floating-point arithmetic. With one GPU configured as `1.0` GiB, the public resource lifecycle can execute:

1. check/allocate `0.1` GiB,
2. check/allocate `0.2` GiB,
3. free `0.2` GiB,
4. free `0.1` GiB,
5. check a `1.0` GiB request.

The restored capacity becomes `0.9999999999999999`; the exact `>= 1.0` comparison then rejects a request that should be eligible after both prior allocations were freed.

## Call Chain and Reachability

This path is reachable through ordinary NVFlare resource-manager APIs:

- `AutoCleanResourceManager.check_resources` reserves on success and stores a token at `nvflare/app_common/resource_managers/auto_clean_resource_manager.py:119-138`.
- `AutoCleanResourceManager.allocate_resources` consumes that token at `nvflare/app_common/resource_managers/auto_clean_resource_manager.py:153-164`.
- `AutoCleanResourceManager.free_resources` calls the GPU manager's `_deallocate` at `nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172`.

The scheduler path observes the bad state:

- Client `CheckResourceProcessor.process` calls `resource_manager.check_resources` and returns `IS_RESOURCE_ENOUGH` at `nvflare/private/fed/client/scheduler_cmds.py:83-91`.
- `DefaultJobScheduler._try_job` treats false resource checks as sites without enough resources, and can return `SCHEDULE_RESULT_NO_RESOURCE` at `nvflare/app_common/job_schedulers/job_scheduler.py:212-237`.

No source patch, direct state injection, mocked peer behavior, or fabricated token is required. The repro uses only the same public lifecycle methods documented for resource managers.

## Safeguards and Masking

The auto-clean thread only releases still-reserved tokens. In the failing sequence, both reservations are allocated and then freed, so there is no remaining token for timeout cleanup to reconcile. `free_resources` does not clamp to configured capacity or normalize precision. `report_resources` reports the reduced floating value. Subsequent checks repeat the same exact comparison, so the bad state persists until resource-manager restart or an external/manual repair.

The documentation says resource checks determine scheduling eligibility: `docs/user_guide/core_concepts/job.rst:272-295` describes check, allocate, and free; `docs/programming_guide/resource_manager_and_consumer.rst:13-18` says the server assumes the ResourceManager's answer. The documented external-process caveat at `docs/programming_guide/resource_manager_and_consumer.rst:96-101` does not account for internally-created rounding drift after normal allocate/free.

## Existing Tests

`tests/unit_test/app_common/resource_managers/gpu_resource_manager_test.py` covers integer reservation, cancellation, free, and timeout restoration. In particular, `test_free_resource` checks that `reserved_resources` is empty after free, but it does not assert restored memory; `test_check_and_timeout` asserts integer memory returns to `16`. I found no existing fractional round-trip test or same-capacity control.

## Known-Status Search

Local git history at the pinned source revision was searched for matching GPUResourceManager float/fraction/rounding/precision reports and recent merged commit messages touching the resource-manager tests/source. The search found the float-memory feature commit `903567c7 Allow GPUResourceManager/Consumer to handle float GPU memory (#1073)` and unrelated resource-manager fixes such as `#5132/#5133`, but no prior report or fix for fractional restoration precision drift.

Narrow upstream tracker searches were also run for this mechanism using `gh search issues/prs --repo NVIDIA/NVFlare` with these queries:

- `GPUResourceManager float rounding`
- `fractional GPU memory precision`
- `GPUResourceManager float memory`
- `GPUResourceManager free_resources memory`
- `GPUResourceManager precision`

All returned `[]`. The search evidence supports marking this mechanism NEW.

## Phase 1 Conclusion

The finding is reachable through public resource-manager operations, has a scheduler-visible consequence, and is not explained by documented external GPU resource limitations. Proceeded to Phase 2 reproduction.
