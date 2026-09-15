# Specula Summary

## Result

- Run status: **Complete**

The report records 5 `REPRODUCED` bugs, 0 `MASKED` findings, 0 `ENV_LIMITED` findings, and 1 other disposition. The reproduced issues affect GPU allocation isolation, acknowledged cancellation, completion reporting, and continued scheduling after a job-store failure.

## Findings

- **MC-2 — Startup rollback frees a resource while the spawned child is still live** — Status: `REPRODUCED`. Impact: A later job can receive a GPU still in use by a live child after startup rollback. Evidence: A controlled cleanup-waiter failure demonstrated two live children assigned the same GPU.
- **MC-3 — A stale deployment write can undo an acknowledged pre-run abort** — Status: `REPRODUCED`. Impact: A job can start after its pre-run abort has already been acknowledged. Evidence: A delayed deployment reply overlapping a normal admin abort produced a final running status after the abort acknowledgement.
- **MC-4 — A delayed startup write can restore RUNNING after terminal publication** — Status: `REPRODUCED`. Impact: A completed job can remain recorded as running, causing the job-monitoring API to time out. Evidence: A delayed startup status write overwrote recorded completion, and the monitoring API returned a timeout.
- **CR-1 — Allocation identity crosses shared process environment** — Status: `REPRODUCED`. Impact: Concurrent jobs with distinct GPU allocations can launch children with the same GPU binding. Evidence: Controlled overlap between legitimate job starts produced the wrong inherited GPU setting in a launched child.
- **CR-5 — Per-job failure can escape a scheduling or completion service** — Status: `REPRODUCED`. Impact: A job-store failure can leave stale scheduler accounting that blocks eligible later jobs until manual clearing or restart. Evidence: Controlled status-storage failures skipped the abort notification, and the scheduler withheld a later eligible job.
- Other dispositions: 1.

## Validation limits

- MC-2 required a controlled failure to start the cleanup waiter; CR-5 required controlled per-job status-storage failures.
- MC-3, MC-4, and CR-1 were reproduced with controlled timing; their undelayed controls did not trigger the issues.
- MC-2's overlapping resource use may end when the first child exits naturally; CR-1's wrong inherited GPU binding lasts for the affected child's lifetime.
- No downstream correction was observed for MC-3's acknowledged abort or MC-4's persistent running status; CR-5's stale accounting requires manual clearing or restart.


## Run details

| Item | Value |
|---|---|
| Target | nvflare-job-lifecycle |
| Original source commit | 53ba7ee567468ea7971dad4faccef13c6cb35dc2 |
| Current attempt source commit | 53ba7ee567468ea7971dad4faccef13c6cb35dc2 |
| Agent / model | codex / Varies by task |
| Reasoning effort | xhigh |

## Detailed reports

- [Confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)

## Resource usage

| Phase | Runtime | Tokens | Estimated cost |
|---|---:|---:|---:|
| Phase 1 | 36m 16s | 30.5M total (29.3M cached) | $45.48 |
| Phase 2 | 49m 37s | 5.5M total (5.1M cached) | $12.11 |
| Phase 2.5 | 53m 34s | 14.2M total (13.9M cached) | $20.67 |
| Phase 3 | 2h 38m | 49.9M total (48.9M cached) | $66.40 |
| Phase 4a | 30m 47s | 38.0M total (36.3M cached) | $32.47 |
| Phase 4b | 5m 5s | 316.7K total (264.8K cached) | $1.14 |
| **Total** | 5h 33m | 138.4M total (133.7M cached) | $178.28 |

- Configured maximum parallelism: 4
- Configured TLC limits: 256G memory; 80 workers
