# OpenRaft

## Scope

Specula analyzed and tested OpenRaft's engine and runtime across vote handling and elections, replication progress and persistence, leader leases, snapshots and log consistency, joint membership changes, and restart recovery.

## Bugs

Specula found no bugs for this system in the recorded experiments.

## CI evaluation

The [2026-09-09 CI rerun](modules/core/runs/openraft-ci-rerun-20260909/README.md) retains zero reproduced findings, one false positive, and four dropped known findings. Confirmation evidence was inherited from the earlier acceptance run; the archive distinguishes reuse from fresh execution.
