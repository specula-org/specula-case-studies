# Severity Classification — asterinas-private-futex-requeue

## Summary

- Total entries: 5
- Reproduced bugs: 4
- Severity-bearing findings: 0
- Critical: 2
- High: 2
- Medium: 0
- Low: 0
- No-severity dispositions: 1

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | A public `FUTEX_REQUEUE` across buckets followed by a timeout leaves a dead entry that consumes a later migration quota, so a live untimed waiter remains on the wrong futex and misses the intended wake. The resulting application hang has no automatic recovery and the test released the waiter only with an explicit wake on the futex where it remained. |
| 2 | MC-2 | REPRODUCED | High | Public `FUTEX_REQUEUE` with zero wake and migration quotas wakes one blocked thread and returns 1 instead of 0, despite the unchanged futex word. The demonstrated external harm is bounded to the unwanted wake and incorrect result for that call. |
| 3 | MC-3 | REPRODUCED | Critical | A public `FUTEX_REQUEUE` with zero migration quota can move a waiter when the two futex words share a bucket, making subsequent wakes on the source miss it. An untimed waiter can then block indefinitely without automatic recovery if the application never wakes the unintended destination, although the reproduction used a 5-second timeout and an explicit destination wake for cleanup. |
| 4 | MC-4 | REPRODUCED | High | Public `FUTEX_REQUEUE` returns only the wake count instead of the total number of waiters woken and requeued, including when the source and destination addresses are identical. The reproduced external effect is an incorrect result for a completed operation, such as 1 instead of 2. |
| 5 | CR-1 | FALSE POSITIVE | — | The Phase 4 FALSE POSITIVE disposition is not severity-bearing and therefore receives no severity. |
