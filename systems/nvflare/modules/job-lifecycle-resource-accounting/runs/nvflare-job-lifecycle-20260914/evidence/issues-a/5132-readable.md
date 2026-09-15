# 5132: Fix zero-GPU scheduling and portable default compatibility

{'state': 'CLOSED', 'createdAt': '2026-08-14T17:00:51Z', 'updatedAt': '2026-08-14T20:26:24Z', 'closedAt': '2026-08-14T20:26:24Z'}

## Body
## Description

Portable resource handling added in #5092 has two independent regressions in `resource_spec` resolution.

### Zero-GPU requests can remain submitted indefinitely

Given:

```json
{
  "resource_spec": {
    "site-1": {
      "num_of_gpus": 0,
      "mem_per_gpu_in_GiB": 8
    }
  }
}
```

`get_resource_manager_spec()` removes `num_of_gpus` but retains `mem_per_gpu_in_GiB`. The default `GPUResourceManager` rejects the resulting non-empty request because it has no GPU-count key. Resource checking then reports the site as unavailable, so the job can remain `SUBMITTED` even though it requests zero GPUs.

Expected behavior: a zero-GPU request must not fail resource admission. If other resource-manager fields remain, the request must retain the zero GPU count so it remains structurally valid.

### `@default` breaks matching legacy nested GPU specifications

This legacy nested specification is accepted:

```json
{
  "resource_spec": {
    "site-1": {
      "process": {"num_of_gpus": 2},
      "docker": {"num_of_gpus": 2}
    }
  }
}
```

Adding an unrelated default:

```json
"@default": {"num_of_cpus": 4}
```

causes validation to reject the matching GPU declarations as a portable/native conflict. The presence of `@default` skips the legacy value-consistency check while reinterpreting the nested process GPU count as portable.

Expected behavior: matching legacy process and launcher GPU counts remain accepted when `@default` is present. Genuine mismatches must still be rejected with the legacy consistency error.

## Impact

- Zero-GPU jobs can be silently unschedulable.
- Existing legacy nested jobs cannot incrementally adopt portable defaults.
- The validation error for matching values incorrectly reports a conflict.

## Acceptance criteria

- Zero-GPU resource-manager requests with non-zero sibling fields remain structurally valid and pass admission when resources are sufficient.
- Matching legacy nested GPU counts are accepted with and without `@default`.
- Mismatched legacy nested GPU counts remain rejected with and without `@default`.
- Regression tests cover the real `GPUResourceManager` boundary and Docker, Kubernetes, and Slurm legacy shapes.
