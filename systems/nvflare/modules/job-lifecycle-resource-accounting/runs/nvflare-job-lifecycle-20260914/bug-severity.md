# Severity Classification — nvflare-job-lifecycle

## Summary

- Total entries: 6
- Reproduced bugs: 5
- Severity-bearing findings: 0
- Critical: 2
- High: 3
- Medium: 0
- Low: 0
- No-severity dispositions: 1

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-2 | REPRODUCED | High | If client START_JOB spawns a child but cleanup-waiter installation fails, rollback exposes its GPU to a later CHECK_RESOURCE/START_JOB request, assigning the same GPU to two live children. This breaks resource isolation for the duration of their overlapping use. |
| 2 | MC-3 | REPRODUCED | High | A normal admin abort racing with a delayed deployment reply can be acknowledged and then overwritten, allowing the aborted job to start. This is an externally visible cancellation failure affecting that job. |
| 3 | MC-4 | REPRODUCED | Critical | A delayed startup status write can overwrite normal completion with RUNNING after completion bookkeeping is removed, persistently corrupting client-visible job metadata. The monitoring API times out and the report records no downstream correction; the timeout ends the call without restoring the completed job's terminal state. |
| 4 | CR-1 | REPRODUCED | High | Two legitimate overlapping START_JOB requests can cause children with distinct recorded allocations to inherit the same GPU binding through the shared parent environment. The wrong binding lasts for the child process's lifetime, breaking resource isolation for the affected jobs. |
| 5 | CR-4 | FALSE POSITIVE | — | The Phase 4 FALSE POSITIVE disposition is not severity-bearing; the report records existing ownership barriers blocking the suspected cleanup and outcome divergence. |
| 6 | CR-5 | REPRODUCED | Critical | During normal job startup, per-job storage failures in both RUNNING and FAILED_TO_RUN publication let error handling escape without notifying the scheduler of the abort. Stale accounting then blocks eligible later jobs at the scheduler's max-jobs gate until manual clearing or restart, with no automatic recovery recorded. |
