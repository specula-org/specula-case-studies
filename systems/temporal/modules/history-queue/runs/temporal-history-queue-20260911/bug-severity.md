# Severity Classification — temporal-history-queue

## Summary

- Total entries: 5
- Reproduced bugs: 1
- Severity-bearing findings: 1
- Critical: 1
- High: 0
- Medium: 1
- Low: 0
- No-severity dispositions: 3

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | CR-1 | FALSE POSITIVE | — | Phase 4 classified the publication/read-boundary claim as a false positive after the tested schedules were blocked or recovered; this disposition is not severity-bearing. |
| 2 | CR-2 | REPRODUCED | Critical | A normal full-batch queue read followed by ACK and checkpoint shrink can strand later transfer work until reload or another cursor-resetting mutation, with repeated notification, checkpointing, and polling failing to restore submission to the scheduler. The higher tier reflects potentially persistent task-processing liveness impact without demonstrated automatic repair during live ownership; reconstruction recovers the retained data, and the reported reader test does not establish an end-to-end client failure. |
| 3 | CR-3 | FALSE POSITIVE | — | Phase 4 classified the checkpoint-divergence claim as a false positive because recovery preserves access to unfinished work; this disposition is not severity-bearing. |
| 4 | CR-4 | MASKED | Medium | After durable shard ownership changes, an old owner's checkpoint can still delete transfer rows without an ownership fence, violating ownership isolation and risking loss of downstream work if ACK does not imply durable or idempotently recoverable execution. The advanced local ACK boundary and downstream stale/duplicate-start guards mask that risk; the report establishes the stale-owner deletion but no wrong workflow or activity outcome. |
| 5 | CR-5 | DROPPED | — | Phase 4 dropped this entry because the same Matching backlog-drop mechanism was already reported upstream; the preserved disposition is not severity-bearing. |
