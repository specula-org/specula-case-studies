# 5083: Add portable CPU and memory requirements with resource defaults

{'state': 'CLOSED', 'createdAt': '2026-08-11T01:52:26Z', 'updatedAt': '2026-08-12T22:43:30Z', 'closedAt': '2026-08-12T22:43:30Z'}

## Body
## Problem

`resource_spec` has a portable GPU count, but CPU and host-memory requirements are launcher-specific. Jobs must also repeat identical requirements for every target site.

## Proposal

Expose only these portable fields:

- `num_of_gpus`: integer greater than or equal to 0; whole GPU devices per job worker.
- `num_of_cpus`: integer greater than or equal to 1; whole schedulable CPU units per job worker.
- `memory`: positive integer followed by `Mi`, `Gi`, or `Ti`; host memory per job worker.

Add `resource_spec["@default"]`, shallow-merged with each site; site values override defaults:

```json
{
  "resource_spec": {
    "@default": {
      "num_of_gpus": 1,
      "num_of_cpus": 4,
      "memory": "8Gi"
    },
    "site-2": {
      "num_of_gpus": 8,
      "num_of_cpus": 16
    }
  }
}
```

`@default` avoids conflicting with a valid site named `default`.

## Backend translation

| Field | Docker | Kubernetes | Slurm |
|---|---|---|---|
| `num_of_gpus` | GPU device requests | `nvidia.com/gpu` request and limit | `--gres` |
| `num_of_cpus` | `nano_cpus` | CPU request and limit | `--cpus-per-task` |
| `memory` | `mem_limit` in bytes | Memory request and limit | `--mem` in MiB |

The scheduler and launcher must use the same resolved default-plus-site requirements.

## Compatibility and scope

- Existing per-site and launcher-native jobs remain valid.
- Reject portable CPU or memory combined with the equivalent launcher-native field.
- Keep topology, accelerator type, GPU memory, storage, wall time, and other backend-specific options in `launcher_spec` or site policy.
- GPU memory is deliberately excluded because Docker, Kubernetes, and Slurm do not share a portable, enforceable allocation by GPU-memory amount.

## Acceptance criteria

- Validate the three portable fields exactly as described above.
- Resolve `@default` with shallow site overrides and without mutating job metadata.
- Apply defaults to explicitly targeted sites that do not have a site entry.
- Translate CPU and memory consistently in Docker, Kubernetes, and Slurm.
- Preserve legacy flat and nested resource specifications.
- Cover default resolution, site overrides, target expansion, malformed values, conflicts, translations, and compatibility with focused tests.
