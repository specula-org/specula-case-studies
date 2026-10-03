# NVFlare job lifecycle: Lite run

The 2026-09-25 experiment studied NVFlare `53ba7ee567468ea7971dad4faccef13c6cb35dc2`, using the default local-process launch path. It covered scheduling, reservations, deployment, startup, termination, and cleanup. Training aggregation, payload transfer, alternative launchers, and HA recovery were outside this run's scope.

## Results

The original [report](report.md) records seven reproduced items. MC-1 and MC-4a match earlier archived job-status findings; five items also appear in the companion [full run](../nvflare-job-full-continuation-20260929/README.md). See the [cross-run ledger](../nvflare-job-full-continuation-20260929/review/findings.md) before counting findings.

The strongest saved deployment evidence covers acknowledged cancellation being overwritten and ordinary queued deletion ending the scheduling thread. Other cases use controlled delays, bounded reservation retention, or unit-level configuration checks. No trace validation was performed; TLC traces are model evidence only.

## Artifacts and replay

- [Modeling brief](modeling-brief.md), [coverage](brief-coverage.md), and [lifecycle/resource models](models).
- [Reproduction sources](repro), [saved logs](repro/logs), and the [timing-only patch](repro/l3_src.patch).
- [Run metadata](run.json) and [.record/files.tsv](.record/files.tsv).

The scripts are the original experiment sources. To repeat the deployment tests, provision a fresh CPU-only POC with one server and two clients using `repro/project_custom.yml`, install the pinned source's dependencies, and adapt the workspace paths in `repro/env.sh` and the helper scripts. The original report supplies each command and its controls. The timing-assisted cases additionally require the preserved patch. The archive excludes the provisioned POC, its credentials, generated job workspaces, and workspace tarballs; it is not a ready-to-launch deployment image.
